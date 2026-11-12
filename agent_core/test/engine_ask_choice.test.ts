// Round 124: the ask-action / user-choice corridor ported from Dart
// _handleAskAction (agent_engine.dart 3052-3113) + selectChoice (1168-1174) +
// wake sites (708-712 / 940-944), exercised through the REAL engine with a
// parked Promise-completer. ASCII-pure: every CJK literal is a \uXXXX escape,
// the pointing-finger glyph is composed at runtime.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";
import type {PermissionMode} from "../src/rpc/schema.js";

const FINGER = String.fromCodePoint(0x1f449); // the "you chose" info prefix glyph
// "think: " / "options: " / "action: ask" / "answer: done + action: finish"
const T_THINK_A = "\u601d\u8003: ";
const T_OPTIONS_A = "\u9009\u9879: ";
const T_ACTION_ASK = "\u52a8\u4f5c: ask\n";
const T_ANSWER_FINISH = "\u56de\u7b54: done\n\u52a8\u4f5c: finish\n";
// gate info "you chose: " (Dart 3094) and the UI info "FINGER you chose: " (3098)
const USER_CHOSE_A = "\u7528\u6237\u9009\u62e9\u4e86: ";
const CHOSEN_INFO_A = FINGER + " \u4f60\u9009\u62e9\u4e86: ";
// observation head/tail: observation: user chose "  + choice +  "  (Dart 3101)
const OBS_CHOSEN_A = "\u89c2\u6d4b: \u7528\u6237\u9009\u62e9\u4e86 \"";
const OBS_CHOSEN_B = "\"";

class ScriptedClient implements LlmClient {
  readonly name = "scripted";
  readonly prompts: ChatMsg[][] = [];
  constructor(private readonly responses: string[]) {}
  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    this.prompts.push(opts.messages.map((m) => ({role: m.role, content: m.content})));
    const text = this.responses.shift() ?? "";
    return {text, reasoning: ""};
  }
}

interface Harness {
  engine: ReActEngine;
  client: ScriptedClient;
  events: any[];
  finished: Array<[string, string | undefined]>;
  userText: (turn: number) => string;
  run: () => Promise<string>;
}

function harness(responses: string[], mode: PermissionMode = "ask"): Harness {
  const ctx = {gen: 0, cancelled: false, mode};
  const events: any[] = [];
  const finished: Array<[string, string | undefined]> = [];
  const client = new ScriptedClient(responses);
  const engine = new ReActEngine(
    client,
    {model: "m"} as any,
    {onEvent: (e: any) => events.push(e), onFinished: (s: any, sum?: string) => finished.push([s, sum]), onError: () => {}},
    {
      permissionMode: () => ctx.mode,
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      isLocalSession: false,
      commandExecutor: (async (): Promise<CommandExecResult> => (
        {stdout: "ran", stderr: "", exitCode: 0, durationMs: 1, success: true}
      )) as any,
    } as any,
  );
  const task = {taskId: "t-ask", operationId: "op", hostId: "h", goal: "g",
    modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 10} as any;
  return {
    engine, client, events, finished,
    userText: (turn: number): string =>
      client.prompts[turn].filter((m) => m.role === "user").map((m) => m.content).join("\n====\n"),
    run: () => engine.run(task, 10) as Promise<string>,
  };
}

/** "think: Q / options: a|b / action: ask" - the parser mints an ask event with
 * question=Q and options=[a,b] for exactly this shape. */
function askTurn(question: string, opts: string): string {
  return T_THINK_A + question + "\n" + T_OPTIONS_A + opts + "\n" + T_ACTION_ASK;
}
const FINISH = T_ANSWER_FINISH;

async function settle(pred: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 400; i++) {
    if (pred()) return;
    await new Promise<void>((res) => setTimeout(res, 5));
  }
  throw new Error("timed out waiting for " + label);
}

describe("ask / choice corridor (Dart _handleAskAction 3052-3113)", () => {
  it("parked ask: choice resumes the loop, observation + info + chosenAnswer", async () => {
    const h = harness([askTurn("why pick?", "opt-a|opt-b"), FINISH]);
    const runP = h.run();
    await settle(() => h.engine.hasPendingChoice, "parked choice");
    expect([...h.engine.pendingOptions]).toEqual(["opt-a", "opt-b"]);
    // Dart 1168-1174: second selectChoice is a no-op (completer nulled, resolve
    // settles once) - the queued continuation must still see only opt-a.
    h.engine.selectChoice("opt-a");
    h.engine.selectChoice("ignored-second-call");
    expect(h.engine.hasPendingChoice).toBe(false);
    expect(await runP).toBe("success");
    const askEvent = h.events.find((e) => e.type === "ask");
    expect(askEvent).toBeDefined();
    expect(askEvent.options).toEqual(["opt-a", "opt-b"]);
    // Dart 3095-3097: chosenAnswer rides on the SAME object that was emitted.
    expect(askEvent.chosenAnswer).toBe("opt-a");
    const chosen = h.events.filter((e) => e.type === "info" && typeof e.text === "string" &&
      e.text.startsWith(CHOSEN_INFO_A));
    expect(chosen.length).toBe(1); // one-shot notice (Dart 3098), no double from the idempotent select
    expect(chosen[0].text).toBe(CHOSEN_INFO_A + "opt-a");
    // Dart 3100-3104: the ReAct observation reached the NEXT model turn.
    expect(h.userText(1)).toContain(OBS_CHOSEN_A + "opt-a" + OBS_CHOSEN_B);
    expect(h.finished.length).toBe(1);
    expect(h.finished[0][0]).toBe("success");
    // the USER_CHOSE_A string is gate-channel only - never a wire event
    expect(h.events.some((e) => e.type === "info" && typeof e.text === "string" &&
      e.text.includes(USER_CHOSE_A))).toBe(false);
  });

  it("cancel while parked: cancelled terminal, no chosen info, no chosenAnswer", async () => {
    const h = harness([askTurn("pick now?", "x|y")]);
    const runP = h.run();
    await settle(() => h.engine.hasPendingChoice, "parked choice");
    h.engine.cancel(); // wakes the completer with "" (Dart 940-944)
    expect(h.engine.hasPendingChoice).toBe(false);
    expect(await runP).toBe("cancelled");
    expect(h.events.filter((e) => e.type === "finish").map((e) => e.finishState)).toEqual(["cancelled"]);
    expect(h.events.some((e) => e.type === "info" && typeof e.text === "string" &&
      e.text.startsWith(CHOSEN_INFO_A))).toBe(false);
    expect(h.events.find((e) => e.type === "ask").chosenAnswer).toBeUndefined();
    expect(h.finished.length).toBe(1);
    expect(h.finished[0][0]).toBe("cancelled");
  });

  it("explicit empty choice: cancelled terminal without the finger info", async () => {
    // Dart 3088-3091 returns with NO finish event; Node needs a terminal state
    // (R5) and emits "cancelled" - documented divergence, pinned here.
    const h = harness([askTurn("pick fast?", "x|y"), FINISH]);
    const runP = h.run();
    await settle(() => h.engine.hasPendingChoice, "parked choice");
    h.engine.selectChoice("");
    expect(await runP).toBe("cancelled");
    expect(h.events.some((e) => e.type === "info" && typeof e.text === "string" &&
      e.text.startsWith(CHOSEN_INFO_A))).toBe(false);
    expect(h.finished.map((f) => f[0])).toEqual(["cancelled"]);
    expect(h.client.prompts.length).toBe(1); // loop STOPPED: no second model turn
  });

  it("bare action:ask with no options is finish-as-ask SUCCESS (Dart 3055-3059)", async () => {
    const h = harness([T_THINK_A + "concluding thought\n" + T_ACTION_ASK]);
    expect(await h.run()).toBe("success");
    expect(h.finished).toEqual([["success", "concluding thought"]]);
    expect(h.events.filter((e) => e.type === "finish").map((e) => e.finishState)).toEqual(["success"]);
    expect(h.engine.hasPendingChoice).toBe(false);
    // the no-command retry budget was NOT consumed (terminal SUCCESS, not failed)
    expect(h.finished[0][0]).not.toBe("failed");
  });

  it("bare action:ask with no thought: finish text falls back to the accumulated turn", async () => {
    const h = harness([T_ACTION_ASK]);
    expect(await h.run()).toBe("success");
    expect(h.finished.length).toBe(1);
    expect(h.finished[0][0]).toBe("success");
    // Round 128: _finishTask ALWAYS runs _composeFinishSummary (3751-3752), so an
    // empty thought + empty answer body falls to _accumulatedMessage (3733, fed by
    // 1784) = this turn's raw text. The old undefined / "" pair was the Node-only
    // gap this round retires; the wire summary and onFinished now agree.
    expect(h.finished[0][1]).toBe(T_ACTION_ASK);
    expect(h.events.filter((e) => e.type === "finish")[0].summary).toBe(T_ACTION_ASK);
  });

  it("a second run() wakes the parked choice: first task interrupted, no extra finish", async () => {
    // Dart 708-712 transient clear on entry (no generation bump there; Node bumps
    // at the top of every run()). The woken awaiter exits through boundary() as
    // "interrupted" - NO finish event for the superseded task (new task owns state).
    const h = harness([askTurn("stale question?", "p|q"), FINISH]);
    const run1 = h.run();
    await settle(() => h.engine.hasPendingChoice, "parked choice");
    const task2 = {taskId: "t-ask2", operationId: "op2", hostId: "h", goal: "g2",
      modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 10} as any;
    const run2 = h.engine.run(task2, 10) as Promise<string>;
    expect(await run1).toBe("interrupted");
    expect(h.engine.hasPendingChoice).toBe(false);
    expect(await run2).toBe("success");
    // the parser's finish event carries no finishState field - the engine
    // defaults it to "success" (run() uses ?? "success"), so normalize here too.
    const finishStates = h.events.filter((e) => e.type === "finish").map((e) => e.finishState ?? "success");
    expect(finishStates).toEqual(["success"]); // only the NEW task ever finishes
    expect(h.finished.map((f) => f[0])).toEqual(["success"]);
    expect(h.events.some((e) => e.type === "info" && typeof e.text === "string" &&
      e.text.startsWith(CHOSEN_INFO_A))).toBe(false);
  });

});
