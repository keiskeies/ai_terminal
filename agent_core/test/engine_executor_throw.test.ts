// test/engine_executor_throw.test.ts - Dart _executeCommand 3918-3965 parity:
// a throwing command executor must NOT escape the ReAct loop. Dart wraps
// executor.executeAndWait in a try/catch that turns the throw into a failed
// AgentResult (error = e.toString(), failureKind unknown, exitCode stays null);
// the loop then follows the ordinary failed-result path - result event, observation
// pushed to history with trim, another LLM turn. R5: only a finish decides the
// terminal state, an executor exception never becomes failed on its own.
// CJK uses \uXXXX escapes per project emit rules; ASCII-only file.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {ConfirmFlow} from "../src/react/confirm_flow.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";

const REACT_CMD = "\u601d\u8003: run\n\u52a8\u4f5c: execute\n\u547d\u4ee4: echo hi";
const FINISH = "\u56de\u7b54: ok\n\u52a8\u4f5c: finish";

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

const TASK = {taskId: "t-ethrow", operationId: "op", hostId: "h", goal: "g",
  modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 30} as any;

function harness(responses: string[], executor: (cmd: string, ctx: any) => Promise<CommandExecResult>) {
  const ctx = {gen: 0, cancelled: false, mode: "auto"};
  const events: any[] = [];
  const finished: Array<[string, string | undefined]> = [];
  let errors = 0;
  const client = new ScriptedClient(responses);
  const flow = new ConfirmFlow({
    context: {
      currentGeneration: () => ctx.gen,
      permissionMode: () => ctx.mode as any,
      isCancelled: () => ctx.cancelled,
      bumpGeneration: () => { ctx.gen++; },
    },
    events: {onInfo: () => {}, onConfirmRequest: () => {}, onWaitingConfirm: () => {}, onLog: () => {}},
  });
  const engine = new ReActEngine(
    client,
    {provider: "openai", model: "m"} as any,
    {onEvent: (e: any) => events.push(e), onFinished: (s: string, sm?: string) => finished.push([s, sm]), onError: () => { errors++; }},
    {
      confirmFlow: flow,
      permissionMode: () => ctx.mode as any,
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      commandExecutor: executor,
    } as any,
  );
  const run = (): Promise<string> => engine.run(TASK, 30);
  return {client, events, finished, errors: () => errors, run};
}

describe("executor throw mirrors Dart _executeCommand catch (3918-3965)", () => {
  it("throw becomes a failed result event: error verbatim, exitCode absent, unknown kind", async () => {
    const h = harness([REACT_CMD, FINISH], async () => { throw new Error("pty exploded"); });
    expect(await h.run()).toBe("success"); // loop survived the throw
    const res = h.events.filter((e) => e.type === "result");
    expect(res.length).toBe(1);
    expect(res[0].success).toBe(false);
    expect(res[0].error).toBe("Error: pty exploded"); // Dart e.toString() mirror
    expect(res[0].exitCode).toBeUndefined(); // Dart exitCode stays null -> wire omits it
    expect(res[0].failureKind).toBe("unknown"); // Dart CommandFailureKind.unknown.name
    expect(h.errors()).toBe(0); // R5: never routed to onError
  });

  it("observation still lands in history and reaches the next request", async () => {
    const h = harness([REACT_CMD, FINISH], async () => { throw new Error("pty exploded"); });
    expect(await h.run()).toBe("success");
    expect(h.client.prompts.length).toBe(2);
    const second = h.client.prompts[1];
    // Dart 3565-3567: observation add + trim on the failed-result path too.
    // Node observation shape: the escaped Chinese header below + output (here the
    // "no output" placeholder) + newline [error] + the exception string.
    const needle = " (no output)\n[error] Error: pty exploded";
    const zhHead = "\u547d\u4ee4\u6267\u884c\u7ed3\u679c:";
    const hits = second.filter((m) => m.role === "user" &&
      m.content.startsWith(zhHead) && m.content.includes(needle));
    expect(hits.length).toBe(1);
  });

  it("success result keeps no error sentence and carries exitCode", async () => {
    const ok: (c: string, x: any) => Promise<CommandExecResult> = async () =>
      ({stdout: "hi", stderr: "", exitCode: 0, durationMs: 1, success: true});
    const h = harness([REACT_CMD, FINISH], ok);
    expect(await h.run()).toBe("success");
    const res = h.events.filter((e) => e.type === "result");
    expect(res.length).toBe(1);
    expect(res[0].success).toBe(true);
    expect(res[0].error).toBeUndefined();
    expect(res[0].exitCode).toBe(0);
  });

  it("exit-code failure path is untouched: sentence error + real exitCode", async () => {
    const bad: (c: string, x: any) => Promise<CommandExecResult> = async () =>
      ({stdout: "", stderr: "nope", exitCode: 7, durationMs: 2, success: false});
    const h = harness([REACT_CMD, FINISH], bad);
    expect(await h.run()).toBe("success");
    const res = h.events.filter((e) => e.type === "result");
    expect(res[0].error).toContain("command exited with code 7");
    expect(res[0].exitCode).toBe(7);
    expect(res[0].failureKind).toBeUndefined();
  });
});
