// Round 125: the anti-hallucination finish guard ported from Dart
// agent_engine.dart 1450-1468 (counters 251-252, reset 662-663, set sites
// 2388/3452). Opt-in via EngineOptions.hallucinationGuard - the frozen
// r1_generation_check regression pins a command-less finish to success, so the
// guard must default OFF. ASCII-pure: CJK literals are \uXXXX escapes.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";

// "answer: done / action: finish"
const FINISH = "\u56de\u7b54: done\n\u52a8\u4f5c: finish\n";
// "think: x / command: ls" -> a real command event through the gate
const CMD = "\u601d\u8003: x\n\u547d\u4ee4: ls\n";
// guard refusal info (Dart 1460)
const GUARD_INFO = "\u26a0\ufe0f AI \u672a\u5b9e\u9645\u6267\u884c\u547d\u4ee4\u5c31\u58f0\u79f0\u5b8c\u6210\uff0c\u8981\u6c42\u5b9e\u9645\u9a8c\u8bc1";
// head of the nudge user message (Dart 1461-1466)
const NUDGE_HEAD = "\u4f60\u5c1a\u672a\u6267\u884c\u4efb\u4f55\u547d\u4ee4\u5c31\u58f0\u660e\u4efb\u52a1\u5b8c\u6210";

class ScriptedClient implements LlmClient {
  readonly name = "scripted";
  readonly prompts: ChatMsg[][] = [];
  calls = 0;
  constructor(private readonly responses: string[]) {}
  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    this.calls++;
    this.prompts.push(opts.messages.map((m) => ({role: m.role, content: m.content})));
    const text = this.responses.shift() ?? FINISH;
    return {text, reasoning: ""};
  }
}

interface Harness {
  engine: ReActEngine;
  client: ScriptedClient;
  events: any[];
  finished: Array<[string, string | undefined]>;
  execCount: () => number;
  userText: (turn: number) => string;
  run: () => Promise<string>;
}

function harness(responses: string[], guard: boolean): Harness {
  const ctx = {gen: 0, cancelled: false};
  const events: any[] = [];
  const finished: Array<[string, string | undefined]> = [];
  let execs = 0;
  const client = new ScriptedClient(responses);
  const engine = new ReActEngine(
    client,
    {model: "m"} as any,
    {onEvent: (e: any) => events.push(e), onFinished: (s: any, sum?: string) => finished.push([s, sum]), onError: () => {}},
    {
      permissionMode: () => "fullAuto",
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      isLocalSession: true,
      hallucinationGuard: guard,
      commandExecutor: (async (): Promise<CommandExecResult> => {
        execs++;
        return {stdout: "ran", stderr: "", exitCode: 0, durationMs: 1, success: true};
      }) as any,
    } as any,
  );
  const task = {taskId: "t-guard", operationId: "op", hostId: "h", goal: "g",
    modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 10} as any;
  return {
    engine, client, events, finished,
    execCount: () => execs,
    userText: (turn: number): string =>
      client.prompts[turn].filter((m) => m.role === "user").map((m) => m.content).join("\n====\n"),
    run: () => engine.run(task, 10) as Promise<string>,
  };
}

describe("anti-hallucination finish guard (Dart 1450-1468)", () => {
  it("guard ON: a command-less finish is refused twice then allowed on the third", async () => {
    const h = harness([FINISH, FINISH, FINISH], true);
    const r = await h.run();
    expect(r).toBe("success");
    // three model turns: two refusals + the third finish that passes
    expect(h.client.calls).toBe(3);
    // the refusal info fires once per refused turn (Dart 1460)
    const infos = h.events.filter((e) => e.type === "info" && e.text === GUARD_INFO);
    expect(infos.length).toBe(2);
    // no finish event on the wire for the two refused turns (Dart only emits
    // finish via _finishTask); exactly one finish reaches the parent
    expect(h.events.filter((e) => e.type === "finish").length).toBe(1);
    // the nudge user message reached the NEXT model turn after each refusal
    expect(h.userText(1)).toContain(NUDGE_HEAD);
    expect(h.userText(2)).toContain(NUDGE_HEAD);
    expect(h.finished.length).toBe(1);
    expect(h.finished[0][0]).toBe("success");
  });

  it("guard ON: a command before finish satisfies the guard immediately", async () => {
    const h = harness([CMD, FINISH], true);
    const r = await h.run();
    expect(r).toBe("success");
    // one command turn + one finish turn, no refusals
    expect(h.client.calls).toBe(2);
    expect(h.execCount()).toBe(1);
    expect(h.events.filter((e) => e.type === "info" && e.text === GUARD_INFO).length).toBe(0);
    expect(h.events.filter((e) => e.type === "finish").length).toBe(1);
  });

  it("guard OFF (default): a command-less finish succeeds on the first turn", async () => {
    const h = harness([FINISH], false);
    const r = await h.run();
    expect(r).toBe("success");
    expect(h.client.calls).toBe(1);
    expect(h.events.filter((e) => e.type === "info" && e.text === GUARD_INFO).length).toBe(0);
    expect(h.events.filter((e) => e.type === "finish").length).toBe(1);
  });

  it("guard counters reset per run(): a second run refuses twice again", async () => {
    const h = harness([FINISH, FINISH, FINISH, FINISH, FINISH, FINISH], true);
    expect(await h.run()).toBe("success"); // consumed 3 (2 refusals + 1 allow)
    expect(h.client.calls).toBe(3);
    expect(await h.run()).toBe("success"); // reset at run entry: 3 more
    expect(h.client.calls).toBe(6);
    // 2 refusals per run -> 4 total
    expect(h.events.filter((e) => e.type === "info" && e.text === GUARD_INFO).length).toBe(4);
  });
});
