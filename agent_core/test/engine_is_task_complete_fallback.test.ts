// Round 127: the completion-sounding fallback of the action-less ladder, ported
// from Dart agent_engine.dart 2041-2055 (parser-side isTaskComplete) into the
// engine arm at react/engine.ts 558-616. A reply with NO action line that reads
// as done must finish the task successfully instead of spending the no-command
// retry budget (Dart _handleNoCommand 3622-3642), and it must run the round-126
// choice hijack and the round-125 anti-hallucination guard on a finish event
// that never reaches the wire. R9: exercised end-to-end through the REAL engine
// with a scripted LLM client. ASCII-pure: every CJK literal is a \uXXXX escape,
// byte-compared against the Dart oracle and the engine's own constants.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";
import type {PermissionMode} from "../src/rpc/schema.js";

// _taskCompleteKeywords[0] (command_heuristics.dart 120)
const KW_DONE = "\u4EFB\u52A1\u5B8C\u6210";
// _taskCompleteKeywords[3] (dart 121) - the ReAct parser keeps it as a thought
const KW_ALL = "\u5168\u90E8\u5B8C\u6210";
// the keyword in its end-of-line form (Dart oracle test 423)
const KW_INSTALL = "\u5B89\u88C5\u5DF2\u5B8C\u6210";
// ReAct field labels: si kao / hui da
const THINK = "\u601D\u8003";
const ANSWER = "\u56DE\u7B54";
// the two options the round-126 detector pulls out of a body (oracle case 1)
const OPT_A = "A. \u4F7F\u7528\u5B98\u65B9\u6E90\u5B89\u88C5";
const OPT_B = "B. \u4F7F\u7528\u6E05\u534E\u955C\u50CF\u5B89\u88C5";
const CHOICE_TAIL = "\u8BF7\u56DE\u590D\u9009\u62E9 A \u8FD8\u662F B\uFF0C\u6211\u7ACB\u5373\u6267\u884C\u3002";

// completion-sounding THOUGHT turn: parse() -> one thought event, no action
const THINK_DONE = THINK + ": " + KW_ALL + "\n";
// the keyword alone: parse() -> one text event, no thought, so the summary falls
// back to the raw response (engine.ts 567-570 ~ Dart 2048 thought ?? content)
const BARE_DONE = KW_DONE;
// answer-labelled keyword: parse() returns NO events at all (react/parser.ts
// 292-298 mints a finish only for an action-finish line), so the summary must be
// the untouched response, field label included
const ANSWER_DONE = ANSWER + ": " + KW_DONE;
// keyword-free prose: the very string r5_terminal_whitelist pins as NOCMD
const PROSE = "\u53EA\u662F\u4E00\u6BB5\u666E\u901A\u6587\u5B57";
// completion body that also begs the user for a decision, with NO action line
const CHOICE_BODY = KW_INSTALL + "\n" + OPT_A + "\n" + OPT_B + "\n" + CHOICE_TAIL + "\n";

// the terminal turn every other engine test uses (answer done + action finish)
const PLAIN_FINISH = "\u56DE\u7B54: done\n\u52A8\u4F5C: finish\n";
// guard refusal info event (Dart 1460 = engine.ts 119)
const GUARD_INFO = "\u26A0\uFE0F AI \u672A\u5B9E\u9645\u6267\u884C\u547D\u4EE4\u5C31\u58F0\u79F0\u5B8C\u6210\uFF0C\u8981\u6C42\u5B9E\u9645\u9A8C\u8BC1";
// guard warn line parts (engine.ts 116-118 = Dart 1452-1455)
const GUARD_WARN_A = "AI \u672A\u6267\u884C\u4EFB\u4F55\u547D\u4EE4\u5C31 finish\uFF0C\u5F3A\u5236\u7EE7\u7EED (\u91CD\u8BD5 ";
const GUARD_WARN_B = "/";
const GUARD_WARN_C = ")";
// head of the nudge user message the guard pushes into history (Dart 1461-1466)
const NUDGE_HEAD = "\u4f60\u5c1a\u672a\u6267\u884c\u4efb\u4f55\u547d\u4ee4\u5c31\u58f0\u660e\u4efb\u52a1\u5b8c\u6210";
// fallback terminal log line (Dart 1470 agentLogger.info = engine.ts 131-132)
const FINISH_INFO = "\u4EFB\u52A1\u5B8C\u6210 (AI \u8FD4\u56DE finish \u52A8\u4F5C)";
// choice hijack warn (engine.ts 126 = Dart 1429-1430)
const HIJACK_WARN_A = "finish \u6B63\u6587\u5305\u542B\u9009\u62E9\u8BF7\u6C42\uFF0C\u8F6C\u4E3A ask \u7B49\u5F85\u7528\u6237\u9009\u62E9: ";
// no-command retry notice (engine.ts 631-632) + hourglass info event (engine.ts 639)
const RETRY_A = "AI \u672A\u751F\u6210\u547D\u4EE4\uFF0C\u53D1\u9001\u7EE7\u7EED\u63D0\u793A (\u91CD\u8BD5 ";
const HOURGLASS = "\u23F3 \u7EE7\u7EED\u6267\u884C...";
// retry-exhaustion warn head (engine.ts 647)
const EXHAUST_A = "AI \u8FDE\u7EED ";
// r5_terminal_whitelist pins this exact summary for the exhausted budget
const TERMINAL_SUMMARY = "no-command retry exhaustion";

// the retry notice of pass n (maxNoCommandRetries is 2)
const retryLine = (n: number): string => RETRY_A + n + "/2)";

class ScriptedClient implements LlmClient {
  readonly name = "scripted";
  readonly prompts: ChatMsg[][] = [];
  constructor(private readonly responses: string[]) {}
  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    this.prompts.push(opts.messages.map((m) => ({role: m.role, content: m.content})));
    const text = this.responses.shift() ?? PLAIN_FINISH;
    return {text, reasoning: ""};
  }
}

interface Harness {
  engine: ReActEngine;
  client: ScriptedClient;
  events: any[];
  finished: Array<[string, string | undefined]>;
  gate: string[]; // every process.stderr.write chunk captured while a run lived
  execCount: () => number;
  userText: (turn: number) => string;
  run: () => Promise<string>;
}

function harness(responses: string[], guard: boolean): Harness {
  const ctx = {gen: 0, cancelled: false};
  const events: any[] = [];
  const finished: Array<[string, string | undefined]> = [];
  const gate: string[] = [];
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
  const task = {taskId: "t-fallback", operationId: "op", hostId: "h", goal: "g",
    modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 10} as any;
  return {
    engine, client, events, finished, gate,
    execCount: () => execs,
    userText: (turn: number): string =>
      client.prompts[turn].filter((m) => m.role === "user").map((m) => m.content).join("\n====\n"),
    // logGate writes straight to process.stderr - capture it for the run duration
    run: () => {
      const orig = process.stderr.write.bind(process.stderr);
      process.stderr.write = ((chunk: any): boolean => {
        gate.push(String(chunk));
        return true;
      }) as typeof process.stderr.write;
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

const gateText = (h: Harness): string => h.gate.join("");
const asks = (h: Harness): any[] => h.events.filter((e) => e.type === "ask");
const finishEvents = (h: Harness): any[] => h.events.filter((e) => e.type === "finish");
const hourglasses = (h: Harness): any[] =>
  h.events.filter((e) => e.type === "info" && e.text === HOURGLASS);
const guardInfos = (h: Harness): any[] =>
  h.events.filter((e) => e.type === "info" && String(e.text).includes(GUARD_INFO));
const countOf = (hay: string, needle: string): number => hay.split(needle).length - 1;

describe("isTaskComplete fallback in the action-less ladder (Dart 2041-2055)", () => {
  it("completion-sounding thought turn -> success terminal, retry budget untouched", async () => {
    const h = harness([THINK_DONE], false);
    expect(await h.run()).toBe("success");
    const f = finishEvents(h);
    expect(f).toHaveLength(1);
    // emitFinish is the ONLY finish that reaches the wire: the locally synthesized
    // event (engine.ts 571-576) carries no finishState, so the one on the wire
    // proves it came from the sanctioned terminal emit.
    expect(f[0].finishState).toBe("success");
    expect(f[0].summary).toBe(KW_ALL); // Dart 2048: thought wins over content
    expect(h.finished).toEqual([["success", KW_ALL]]);
    expect(h.client.prompts.length).toBe(1); // no retry turn consumed
    expect(hourglasses(h)).toEqual([]);
    expect(countOf(gateText(h), RETRY_A)).toBe(0);
    expect(gateText(h)).toContain(FINISH_INFO); // Dart 1470 info line
    expect(h.execCount()).toBe(0);
  });

  it("keyword alone: no thought event -> the raw response is the summary", async () => {
    const h = harness([BARE_DONE], false);
    expect(await h.run()).toBe("success");
    expect(h.events.filter((e) => e.type === "thought")).toEqual([]);
    expect(finishEvents(h)[0].summary).toBe(BARE_DONE); // fbThought empty -> response
    expect(h.finished).toEqual([["success", BARE_DONE]]);
    expect(gateText(h)).toContain(FINISH_INFO);
  });

  it("answer-labelled keyword: parser mints nothing, arm still finishes", async () => {
    // react/parser.ts 292-298 mints a finish ONLY for an action-finish line, so
    // this turn parses to ZERO events - Dart still asks isTaskComplete on the raw
    // content (2044) and finishes. The only event on the wire is the terminal one.
    const h = harness([ANSWER_DONE], false);
    expect(await h.run()).toBe("success");
    expect(h.events.filter((e) => e.type !== "finish")).toEqual([]);
    expect(finishEvents(h)).toHaveLength(1);
    expect(h.finished).toEqual([["success", ANSWER_DONE]]); // label included: no thought
    expect(hourglasses(h)).toEqual([]);
  });

  it("guard ON: the synthesized finish is refused twice, then allowed (Dart 1450-1468)", async () => {
    // R5: a green terminal needs evidence - the guard covers the finish the ENGINE
    // synthesized too (engine.ts 602), so zero commands + a completion claim is
    // force-continued until the retry budget (2) is spent.
    const h = harness([THINK_DONE, THINK_DONE, THINK_DONE], true);
    expect(await h.run()).toBe("success");
    expect(guardInfos(h)).toHaveLength(2);
    expect(countOf(gateText(h), GUARD_WARN_A)).toBe(2);
    expect(gateText(h)).toContain(GUARD_WARN_A + "1" + GUARD_WARN_B + "2" + GUARD_WARN_C);
    // Dart 1461-1466: the nudge comes back as a user message
    expect(h.userText(1)).toContain(NUDGE_HEAD);
    expect(h.userText(2)).toContain(NUDGE_HEAD);
    expect(countOf(gateText(h), RETRY_A)).toBe(0); // the finish path owns the turn
    expect(hourglasses(h)).toEqual([]);
    expect(finishEvents(h)).toHaveLength(1);
    expect(finishEvents(h)[0].summary).toBe(KW_ALL);
    expect(countOf(gateText(h), FINISH_INFO)).toBe(1); // only the allowed pass logs it
  });

  it("keyword-free reply: arm skipped, no-command contract intact (r5 row no-cmd)", async () => {
    // isTaskComplete(PROSE) is false - command_heuristics.test.ts pins that string
    // against the Dart oracle - so the budget is spent exactly as before r127.
    const h = harness([PROSE, PROSE, PROSE, PROSE], false);
    expect(await h.run()).toBe("failed");
    expect(h.client.prompts.length).toBe(3); // 2 retries + the exhausting pass
    expect(hourglasses(h)).toHaveLength(2);
    expect(gateText(h)).toContain(retryLine(1));
    expect(gateText(h)).toContain(retryLine(2));
    expect(countOf(gateText(h), EXHAUST_A)).toBe(1);
    expect(gateText(h)).not.toContain(FINISH_INFO);
    expect(h.finished).toEqual([["failed", TERMINAL_SUMMARY]]);
  });

  it("completion body that also asks for a choice -> ask, never a green terminal", async () => {
    const h = harness([CHOICE_BODY, PLAIN_FINISH], false);
    const run = h.run();
    await settle(() => h.engine.hasPendingChoice, "parked choice from the fallback arm");
    // the synthesized finish never reaches the wire (engine.ts 571-576 comment:
    // it exists only to feed the two helpers), while the extracted ask must
    expect(finishEvents(h)).toEqual([]);
    const a = asks(h);
    expect(a).toHaveLength(1);
    expect([...a[0].options]).toEqual([OPT_A, OPT_B]);
    expect(a[0].question).toBe(KW_INSTALL + "\n" + CHOICE_TAIL); // detector drops option lines
    expect(gateText(h)).toContain(HIJACK_WARN_A + "[" + OPT_A + ", " + OPT_B + "]");
    expect(gateText(h)).not.toContain(FINISH_INFO);
    expect(hourglasses(h)).toEqual([]);
    h.engine.selectChoice("A");
    expect(await run).toBe("success");
    expect(asks(h)[0].chosenAnswer).toBe("A"); // Dart 3095-3097
    expect(finishEvents(h)).toHaveLength(1); // only the NEXT turn's action finish
    expect(h.finished.map((f) => f[0])).toEqual(["success"]);
    expect(h.client.prompts.length).toBe(2); // hijack consumed no retry turn
    expect(h.execCount()).toBe(0);
  });

  it("hijack wins over the guard on a SYNTHESIZED finish (engine.ts 580 before 602)", async () => {
    // guard ON: this completion claim has zero commands, so the guard WOULD refuse
    // it - but the body asks the user to choose, so it becomes an ask and the
    // guard counter stays untouched (same order Dart uses at 1423 then 1450).
    const h = harness([CHOICE_BODY, PLAIN_FINISH, PLAIN_FINISH, PLAIN_FINISH], true);
    const run = h.run();
    await settle(() => h.engine.hasPendingChoice, "hijacked fallback ask under guard ON");
    expect(gateText(h)).toContain(HIJACK_WARN_A);
    expect(countOf(gateText(h), GUARD_WARN_A)).toBe(0);
    expect(guardInfos(h)).toEqual([]);
    expect(finishEvents(h)).toEqual([]);
    h.engine.selectChoice("A");
    expect(await run).toBe("success");
    expect(gateText(h)).toContain(GUARD_WARN_A + "1" + GUARD_WARN_B + "2" + GUARD_WARN_C);
    expect(guardInfos(h)).toHaveLength(2); // plain finish #2/#3 refused, #4 allowed
    expect(finishEvents(h)).toHaveLength(1);
    expect(h.client.prompts.length).toBe(4);
  });
});
