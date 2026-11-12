// Round 130: what the answer/section split feeds into the engine. Ported chain:
// agent_engine.dart 2002-2004 (per-turn parseAnswerBlock / parseReportSections) ->
// 1476-1478 (report = sections, else the finish thought) -> 3729-3737
// (_composeFinishSummary) -> 3762-3765 (the finish EVENT carries it) plus the
// TailTextBuffer accumulator behind the 3733 fallback (Dart 61-71, 275, 660/1256,
// 1784) and the answer block as text source of the finish-to-ask hijack (3034-3048).
// ASCII-pure: every turn body is pulled out of the Dart sources at run time.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";
import {parse as parseStream} from "../src/react/parser.js";
import {parseAnswerBlock, parseReportSections} from "../src/utils/answer_block.js";
import {ChoiceRequestDetector} from "../src/utils/choice_request_detector.js";
import type {PermissionMode} from "../src/rpc/schema.js";

const NL = String.fromCharCode(10);
const BSN = String.fromCharCode(92) + "n";
const HERE = fileURLToPath(new URL(".", import.meta.url));
const dartLines = (rel: string): string[] =>
  readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL).split(NL);

// ---- turn bodies straight out of the Dart oracle ----------------------------
function e2eCaseLines(tag: string): string[] {
  const oracle = dartLines("../../ai_terminal/test/react_parse_e2e_test.dart");
  const start = oracle.findIndex((l) => l.indexOf("test('E2E-" + tag + ":") >= 0);
  if (start < 0) throw new Error("oracle case E2E-" + tag + " missing");
  let depth = 0;
  for (let i = start; i < oracle.length; i++) {
    for (const c of oracle[i]) {
      if (c === "{") depth++;
      else if (c === "}") depth--;
    }
    if (depth === 0 && i > start) return oracle.slice(start, i + 1);
  }
  throw new Error("oracle case E2E-" + tag + " never closes");
}

// the closing delimiter sits at the END of the last content line (where the action
// line is), so that foot must be kept or the finish line disappears
function tripleText(lines: string[]): string {
  const open = lines.findIndex((l) => l.indexOf("= '''") >= 0);
  if (open < 0) throw new Error("no triple-quoted response in the oracle case");
  const head = lines[open].split("'''")[1];
  let close = open + 1;
  while (close < lines.length && lines[close].indexOf("'''") < 0) close++;
  if (close >= lines.length) throw new Error("unterminated triple-quoted response");
  const foot = lines[close].split("'''")[0];
  const parts = head === "" ? lines.slice(open + 1, close) : [head].concat(lines.slice(open + 1, close));
  if (foot !== "") parts.push(foot);
  return parts.join(NL);
}

const E15 = tripleText(e2eCaseLines("15"));
const E15_LINES = E15.split(NL);

// ReAct field labels from the Dart parser's own keyword table, in Dart order
// (react_stream_parser.dart _keywords): a Dart-side rename follows automatically.
function dartKeywords(): string[] {
  const src = dartLines("../../ai_terminal/lib/utils/react_stream_parser.dart");
  const at = src.findIndex((l) => l.indexOf("_keywords = [") >= 0);
  if (at < 0) throw new Error("_keywords not found in the Dart parser");
  let close = at;
  while (close < src.length && src[close].indexOf("];") < 0) close++;
  const body = src.slice(at, close + 1).join(NL).split(NL).filter((l) => l.trim().indexOf("//") !== 0).join(NL);
  const re = /'((?:[^'\\]|\\.)*)'/g;
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(body)) !== null) out.push(m[1]);
  return out;
}
const KEYWORDS = dartKeywords();
const LABEL_THINK = KEYWORDS[0];   // si kao
const LABEL_ACTION = KEYWORDS[6];  // dong zuo
const LABEL_COMMAND = KEYWORDS[8]; // ming ling
const LABEL_ANSWER = KEYWORDS[16]; // hui da

// the four report fields from _sectionStartLine in agent_engine.dart
function dartSectionLabels(): string[] {
  const src = dartLines("../../ai_terminal/lib/services/agent_engine.dart").join(NL);
  const at = src.indexOf("_sectionStartLine");
  if (at < 0) throw new Error("_sectionStartLine not found");
  const m = /RegExp\(\s*r'\^\(([^)]*)\)/.exec(src.slice(at, at + 200));
  if (!m) throw new Error("_sectionStartLine alternation not found");
  return m[1].split("|");
}
const SECTION_LABELS = dartSectionLabels();
const SECTION_LINE = SECTION_LABELS.map((s) => s + ":");

// option lines + the ask tail of Dart choice oracle case 1
function dartChoiceLines(): string[] {
  const src = dartLines("../../ai_terminal/test/choice_request_detector_test.dart");
  const at = src.findIndex((l) => l.indexOf("ChoiceRequestDetector.detect(") >= 0);
  if (at < 0) throw new Error("choice oracle case 1 not found");
  let body = "";
  let seen = 0;
  for (let i = at + 1; i < src.length; i++) {
    const m = /^\s*'((?:[^'\\]|\\.)*)',?\s*$/.exec(src[i]);
    if (!m) break;
    seen++;
    body += m[1];
  }
  if (seen < 2) throw new Error("choice oracle literals not found");
  return body.split(BSN).filter((s) => s !== "");
}
const CHOICE_SEGS = dartChoiceLines();
const OPT_A = CHOICE_SEGS[1];
const OPT_B = CHOICE_SEGS[2];
const CHOICE_TAIL = CHOICE_SEGS[3];

const ANSWER_LINE = String(E15_LINES.find((l) => l.indexOf(LABEL_ANSWER) === 0));
const SECT_LINES = E15_LINES.filter((l) => SECTION_LINE.some((s) => l.indexOf(s) === 0));
const ACTION_FINISH = LABEL_ACTION + " finish" + NL;
// the terminal turn the parked-choice continuation needs
const PLAIN = LABEL_ANSWER + " done" + NL + ACTION_FINISH;
// a finish with neither thought nor answer: Dart 3733 falls back to the accumulator
const BARE_FINISH = ACTION_FINISH;

// options pushed BELOW the first section line: the parser's raw body sees them,
// the Dart answer block does not (the extractor stops at the first section line) - Dart 3041-3047
const TURN_OUTSIDE = [ANSWER_LINE, SECT_LINES[0], OPT_A, OPT_B, CHOICE_TAIL, ACTION_FINISH.trim()].join(NL) + NL;
// options INSIDE the answer block: the answer block carries them, so the hijack fires
const TURN_INSIDE = [ANSWER_LINE, OPT_A, OPT_B, CHOICE_TAIL, SECT_LINES[0], ACTION_FINISH.trim()].join(NL) + NL;

const composedOf = (text: string): string => {
  const lines = text.split(NL);
  const sections = parseReportSections(lines) ?? "";
  const answer = parseAnswerBlock(lines) ?? "";
  const report = sections !== "" ? sections : "";
  if (report === "") return answer;
  if (answer === "") return report;
  return report + NL + NL + answer;
};

const parserFinish = (text: string): {id: string; summary?: string} => {
  const f = parseStream(text).filter((e) => e.type === "finish");
  if (f.length !== 1) throw new Error("the ported parser must mint exactly one finish for this turn");
  return {id: String(f[0].id), summary: f[0].summary ?? undefined};
};

// ---- engine harness (scripted LLM, fullAuto, guard off) --------------------
class ScriptedClient implements LlmClient {
  readonly name = "scripted";
  turns = 0;
  last: ChatMsg[] = [];
  constructor(private readonly responses: string[]) {}
  push(turn: string): void {
    this.responses.push(turn);
  }
  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    this.turns++;
    this.last = opts.messages.map((m) => ({role: m.role, content: m.content}));
    return {text: this.responses.shift() ?? PLAIN, reasoning: ""};
  }
}

type Harness = {
  engine: ReActEngine;
  client: ScriptedClient;
  events: any[];
  finished: Array<[string, string | undefined]>;
  execCount: () => number;
  run: () => Promise<string>;
};

function harness(responses: string[], guard: boolean): Harness {
  const ctx = {gen: 0, cancelled: false};
  const events: any[] = [];
  const finished: Array<[string, string | undefined]> = [];
  const client = new ScriptedClient(responses);
  let execs = 0;
  const engine = new ReActEngine(
    client,
    {model: "m"} as any,
    {onEvent: (e: any) => events.push(e),
     onFinished: (s: any, sum?: string) => finished.push([s, sum]), onError: () => {}},
    {
      permissionMode: (): PermissionMode => "fullAuto",
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      isLocalSession: true,
      hallucinationGuard: guard,
      commandExecutor: (async (): Promise<CommandExecResult> => {
        execs++;
        return {stdout: "ran", stderr: "", exitCode: 0, durationMs: 1, success: true};
      }) as any,
    } as any,
  );
  const task = {taskId: "t-answer-sections", operationId: "op", hostId: "h", goal: "g",
    modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 10} as any;
  return {
    engine, client, events, finished, execCount: () => execs,
    // logGate writes to stderr; keep the vitest report clean
    run: () => {
      const orig = process.stderr.write.bind(process.stderr);
      process.stderr.write = ((): boolean => true) as typeof process.stderr.write;
      const p = engine.run(task, 10) as Promise<string>;
      return p.finally(() => { process.stderr.write = orig; });
    },
  };
}

async function settle(pred: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 400; i++) {
    if (pred()) return;
    await new Promise<void>((res) => setTimeout(res, 5));
  }
  throw new Error("timed out waiting for " + label);
}

const finishEvents = (h: Harness): any[] => h.events.filter((e) => e.type === "finish");
const asks = (h: Harness): any[] => h.events.filter((e) => e.type === "ask");

describe("finish summary = report sections + answer block (Dart 2002-2004, 1476-1478, 3729-3737)", () => {
  it("oracle labels are the Dart ones (structural guard)", () => {
    expect(KEYWORDS).toHaveLength(18);
    for (let i = 0; i < KEYWORDS.length; i += 2) {
      expect(KEYWORDS[i + 1].slice(0, KEYWORDS[i + 1].length - 1)).toBe(KEYWORDS[i].slice(0, -1));
    }
    expect(SECTION_LABELS).toHaveLength(4);
    expect(CHOICE_SEGS).toHaveLength(4);
    expect(OPT_A.slice(0, 2)).toBe("A.");
    expect(OPT_B.slice(0, 2)).toBe("B.");
    expect(E15_LINES[E15_LINES.length - 1]).toBe(ACTION_FINISH.trim());
  });

  it("the E2E-15 reply finishes in ONE turn with report above answer", async () => {
    const h = harness([E15], false);
    expect(await h.run()).toBe("success");
    expect(h.client.turns).toBe(1);
    expect(asks(h)).toEqual([]);
    const wire = finishEvents(h);
    expect(wire).toHaveLength(1);
    const composed = composedOf(E15);
    const raw = parserFinish(E15);
    // the parser alone only offers the raw answer-body (Dart 3736 keeps BOTH)
    expect(raw.summary).not.toBe(composed);
    expect(String(raw.summary)).toContain(
      String(parseAnswerBlock(E15_LINES)).split(NL)[0],
    );
    expect(wire[0].summary).toBe(composed);
    expect(h.finished).toEqual([["success", composed]]);
    // R4: the dedup key stays the parser's content hash, not the composed text
    expect(wire[0].id).toBe(raw.id);
    // the four-field report wins over the thought (Dart 1476-1478)
    expect(String(wire[0].summary).split(NL)[0]).toBe(SECT_LINES[0]);
  });

  it("options below the first section line do NOT hijack (Dart 3041-3047)", async () => {
    const h = harness([TURN_OUTSIDE], false);
    expect(await h.run()).toBe("success");
    expect(asks(h)).toEqual([]);
    expect(h.engine.hasPendingChoice).toBe(false);
    const wire = finishEvents(h);
    expect(wire).toHaveLength(1);
    expect(wire[0].summary).toBe(composedOf(TURN_OUTSIDE));
    // negative control: the parser's raw body WOULD have hijacked, the answer block
    // (the Dart text source) does not - that is exactly the 3041-3047 chain
    const raw = parserFinish(TURN_OUTSIDE);
    expect(ChoiceRequestDetector.detect(String(raw.summary))).not.toBeNull();
    expect(ChoiceRequestDetector.detect(String(parseAnswerBlock(TURN_OUTSIDE.split(NL))))).toBeNull();
  });

  it("options inside the answer block hijack, question from the answer block", async () => {
    const h = harness([TURN_INSIDE, PLAIN], false);
    const run = h.run();
    await settle(() => h.engine.hasPendingChoice, "parked choice from the answer block");
    expect(finishEvents(h)).toEqual([]);
    const a = asks(h);
    expect(a).toHaveLength(1);
    const block = String(parseAnswerBlock(TURN_INSIDE.split(NL)));
    const want = ChoiceRequestDetector.detect(block);
    expect(want).not.toBeNull();
    expect([...a[0].options]).toEqual([...((want as any) as {options: string[]}).options]);
    expect(a[0].question).toBe((want as any).question);
    // Dart 3038/3041: the section line beyond the answer block never reaches the ask
    expect(a[0].question).not.toContain(SECT_LINES[0]);
    h.engine.selectChoice("A");
    expect(await run).toBe("success");
    expect(finishEvents(h)).toHaveLength(1);
  });

  it("bare finish with no thought and no answer -> the turn text (Dart 3733)", async () => {
    const h = harness([BARE_FINISH], false);
    expect(await h.run()).toBe("success");
    expect(h.finished).toEqual([["success", BARE_FINISH]]);
  });

  it("the accumulator is a tail-capped buffer, not an unbounded string (R8)", async () => {
    const long = LABEL_THINK + " " + "x".repeat(25000) + NL + LABEL_COMMAND + " ls" + NL;
    const h = harness([long, BARE_FINISH], false);
    expect(await h.run()).toBe("success");
    expect(h.execCount()).toBe(1);
    const summary = String(h.finished[0][1]);
    expect(summary.length).toBe(20000);
    expect(summary.endsWith(BARE_FINISH)).toBe(true);
    // the head of the first turn was evicted - the tail is what a user reads
    expect(summary.indexOf(LABEL_THINK)).toBe(-1);
    expect(summary).toContain(LABEL_COMMAND);
  });

  it("a new task starts with an empty accumulator (Dart 660/1256 clear)", async () => {
    const h = harness([BARE_FINISH], false);
    expect(await h.run()).toBe("success");
    h.client.push(BARE_FINISH);
    expect(await h.run()).toBe("success");
    expect(h.finished).toEqual([["success", BARE_FINISH], ["success", BARE_FINISH]]);
  });
});
