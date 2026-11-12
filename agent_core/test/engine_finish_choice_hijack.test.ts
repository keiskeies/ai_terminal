// Round 126: finish-body choice hijack, ported from Dart agent_engine.dart
// 1423-1448 + _choiceRequestFromFinish 3034-3048, exercised end-to-end through
// the REAL engine (R9): a scripted finish turn whose answer body asks the user
// to choose must convert into a real parked ask, NOT a terminal finish.
// ASCII-pure: every CJK literal is a \uXXXX escape.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";
import type {PermissionMode} from "../src/rpc/schema.js";

// answer-body that begs for a decision (Dart detector oracle case 1): the parser
// mints ONE finish event whose summary is the whole body, and the detector
// extracts the two letter options out of it.
const CHOICE_FINISH =
  "\u56de\u7b54: \u5b89\u88c5 Docker \u6709\u4e24\u79cd\u65b9\u5f0f\uff1a\nA. \u4f7f\u7528\u5b98\u65b9\u6e90\u5b89\u88c5\nB. \u4f7f\u7528\u6e05\u534e\u955c\u50cf\u5b89\u88c5\n\u8bf7\u56de\u590d\u9009\u62e9 A \u8fd8\u662f B\uff0c\u6211\u7acb\u5373\u6267\u884c\u3002\n\u52a8\u4f5c: finish"
;
// plain terminal turn (answer done + action finish)
const PLAIN_FINISH = "\u56de\u7b54: done\n\u52a8\u4f5c: finish\n";
// long summary that must NOT be hijacked (Dart oracle case 4: a trailing hint
// "suggest A or B" is not a choice request)
const SAFE_FINISH = "\u56de\u7b54: \u7ed3\u8bba: \u5df2\u5b8c\u6210\u68c0\u67e5\n\u73b0\u72b6: \u670d\u52a1\u8fd0\u884c\u6b63\u5e38\n\u53d8\u66f4: \u65e0\n\u5efa\u8bae: \u540e\u7eed\u53ef\u4ee5\u8003\u8651 A \u6216 B \u4e24\u79cd\u4f18\u5316\u65b9\u5f0f\u3002\n\u52a8\u4f5c: finish\n";
// protocol turn: an options line AND action finish in one turn - the parser
// mints BOTH an ask event (options + last question) and a finish event
const PROTO_TURN = "\u601d\u8003: \u9700\u8981\u7528\u6237\u51b3\u5b9a\n\u9009\u9879: \u5feb\u901f|\u7a33\u59a5\n\u56de\u7b54: \u4f60\u60f3\u8d70\u54ea\u4e2a\u65b9\u6848\uff1f\n\u52a8\u4f5c: finish\n";
// the two options the detector extracts from the choice body
const OPT_A = "A. \u4f7f\u7528\u5b98\u65b9\u6e90\u5b89\u88c5";
const OPT_B = "B. \u4f7f\u7528\u6e05\u534e\u955c\u50cf\u5b89\u88c5";
const PROTO_OPTS = ["\u5feb\u901f", "\u7a33\u59a5"];
// gate warn (Dart 1429-1430): finish body contains a choice request ...
const HIJACK_WARN_A = "finish \u6b63\u6587\u5305\u542b\u9009\u62e9\u8bf7\u6c42\uff0c\u8f6c\u4e3a ask \u7b49\u5f85\u7528\u6237\u9009\u62e9: ";
// round-125 guard refusal info (Dart 1460) + the warn line with count 1/2
const GUARD_INFO = "\u26a0\ufe0f AI \u672a\u5b9e\u9645\u6267\u884c\u547d\u4ee4\u5c31\u58f0\u79f0\u5b8c\u6210\uff0c\u8981\u6c42\u5b9e\u9645\u9a8c\u8bc1";
const GUARD_WARN_1 = "AI \u672a\u6267\u884c\u4efb\u4f55\u547d\u4ee4\u5c31 finish\uff0c\u5f3a\u5236\u7ee7\u7eed (\u91cd\u8bd5 1/2)";
const FINGER = String.fromCodePoint(0x1f449);
const CHOSEN_INFO_A = FINGER + " \u4f60\u9009\u62e9\u4e86: ";

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
  const task = {taskId: "t-hijack", operationId: "op", hostId: "h", goal: "g",
    modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 10} as any;
  return {
    engine, client, events, finished, gate, execCount: () => execs,
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

describe("finish-to-ask hijack (Dart 1423-1448 + 3034-3048)", () => {
  it("choice body in the finish answer -> synthesized ask, no terminal finish", async () => {
    const h = harness([CHOICE_FINISH, PLAIN_FINISH], false);
    const run = h.run();
    await settle(() => h.engine.hasPendingChoice, "parked choice from the hijacked finish");
    // the finish must NOT reach the wire (SAME helper as the branch decides),
    // while the synthesized ask MUST (Dart 1431-1437: body-extracted options
    // need an event of their own; a protocol ask would already be on the wire)
    expect(finishEvents(h)).toEqual([]);
    const a = asks(h);
    expect(a).toHaveLength(1);
    expect([...a[0].options]).toEqual([OPT_A, OPT_B]);
    expect(a[0].question).toContain("\u5b89\u88c5 Docker \u6709\u4e24\u79cd\u65b9\u5f0f");
    expect(gateText(h)).toContain(HIJACK_WARN_A + "[" + OPT_A + ", " + OPT_B + "]");
    h.engine.selectChoice("A");
    expect(await run).toBe("success");
    // chosenAnswer rides on the ask event the engine minted (Dart 3095-3097)
    expect(asks(h)[0].chosenAnswer).toBe("A");
    expect(finishEvents(h)).toHaveLength(1); // only the NEXT turn's plain finish
    expect(h.finished.map((f) => f[0])).toEqual(["success"]);
    expect(h.events.some((e) => e.type === "info" && typeof e.text === "string" &&
      e.text.startsWith(CHOSEN_INFO_A))).toBe(true);
    expect(h.client.prompts.length).toBe(2); // hijack consumed no extra turn
    expect(h.execCount()).toBe(0); // no command was ever run
  });

  it("repeating the same choice body hijacks again (stableId stays unclaimed)", async () => {
    // all three finish turns share one answer body -> one stableId; the two
    // suppressed finishes must NOT claim it or the wire finish gets swallowed
    const h = harness([CHOICE_FINISH, CHOICE_FINISH, PLAIN_FINISH], false);
    const run = h.run();
    await settle(() => h.engine.hasPendingChoice, "first hijack ask");
    h.engine.selectChoice("B");
    await settle(() => asks(h).length === 2, "second hijack ask");
    expect(finishEvents(h)).toEqual([]);
    h.engine.selectChoice("A");
    expect(await run).toBe("success");
    expect(asks(h)).toHaveLength(2);
    expect(finishEvents(h)).toHaveLength(1);
    expect(gateText(h).split(HIJACK_WARN_A).length - 1).toBe(2);
  });

  it("protocol options + finish in one turn: parser ask reused, no double ask", async () => {
    const h = harness([PROTO_TURN, PLAIN_FINISH], false);
    const run = h.run();
    await settle(() => h.engine.hasPendingChoice, "protocol-options hijack");
    const a = asks(h);
    expect(a).toHaveLength(1); // the parser's ask event, NOT a second one
    expect([...a[0].options]).toEqual(PROTO_OPTS);
    expect(a[0].question).toBe("\u9700\u8981\u7528\u6237\u51b3\u5b9a"); // parser lastQuestion on the wire
    expect(finishEvents(h)).toEqual([]); // suppressed on the wire (hijacked)
    // Dart 3035-3039: protocol options win without calling the detector; the
    // question handed to the loop is the finish answer body, not the thought
    expect(gateText(h)).toContain(HIJACK_WARN_A + "[" + PROTO_OPTS.join(", ") + "]");
    h.engine.selectChoice(PROTO_OPTS[0]);
    expect(await run).toBe("success");
    expect(asks(h)[0].chosenAnswer).toBe(PROTO_OPTS[0]);
    expect(finishEvents(h)).toHaveLength(1);
  });

  it("hijack runs BEFORE the anti-hallucination guard (Dart 1427 vs 1450)", async () => {
    // guard ON: the command-less FIRST finish would be refused - but it asks for
    // a choice, so it turns into an ask instead: no refusal info, no counter burn
    const h = harness([CHOICE_FINISH, PLAIN_FINISH, PLAIN_FINISH, PLAIN_FINISH], true);
    const run = h.run();
    await settle(() => h.engine.hasPendingChoice, "hijacked ask under guard ON");
    expect(gateText(h)).not.toContain(GUARD_INFO);
    expect(gateText(h)).toContain(HIJACK_WARN_A);
    expect(finishEvents(h)).toEqual([]);
    h.engine.selectChoice("A");
    expect(await run).toBe("success");
    // the counter was NOT burned by the hijack: the first plain refusal shows 1/2
    expect(gateText(h)).toContain(GUARD_WARN_1);
    const infos = h.events.filter((e) => e.type === "info" && typeof e.text === "string" &&
      e.text.includes(GUARD_INFO));
    expect(infos).toHaveLength(2); // plain finish #2 and #3 refused, #4 allowed
    expect(finishEvents(h)).toHaveLength(1);
    expect(h.client.prompts.length).toBe(4);
  });

  it("hint-like summary finishes normally - no hijack, no suppression", async () => {
    const h = harness([SAFE_FINISH], false);
    expect(await h.run()).toBe("success");
    expect(asks(h)).toEqual([]);
    expect(finishEvents(h)).toHaveLength(1);
    expect(gateText(h)).not.toContain(HIJACK_WARN_A);
  });
});
