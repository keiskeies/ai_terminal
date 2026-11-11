// test/engine_no_command.test.ts - port of Dart _handleNoCommand (agent_engine.dart
// 3622-3642) into the engine no-command branch. Pins: (1) the continue prompt the
// model receives is byte-faithful to the Dart literal, (2) each within-budget retry
// emits exactly one hourglass info event with an occurrence id and logs the Dart
// retry line on the gate channel, (3) the prompt is pushed as a user turn and
// reaches the NEXT request, (4) exhaustion stays terminal: failed, exactly one
// finish event, the pinned summary, no third continue, (5) R5: a successful
// command resets the retry counter so an isolated later lapse is not terminal.
// CJK uses \uXXXX escapes per project emit rules.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {ConfirmFlow} from "../src/react/confirm_flow.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";

// hourglass notice (Dart UiText.t zh branch, 3629)
const HOURGLASS = "\u23F3 \u7EE7\u7EED\u6267\u884C...";
// Dart agentLogger.info copy (3626), interpolation positions spelled out below
const RETRY_LOG = "AI \u672a\u751f\u6210\u547d\u4ee4\uff0c\u53d1\u9001\u7ee7\u7eed\u63d0\u793a (\u91cd\u8bd5";
const EXHAUST_LOG_HEAD = "AI \u8FDE\u7EED ";
const EXHAUST_LOG_TAIL = " \u6B21\u672A\u751F\u6210\u547D\u4EE4\uFF0C\u4EFB\u52A1\u7EC8\u6B62 (failed)";
// Dart 3628 continue prompt, byte-faithful (identical escape sequence to engine.ts)
const CONTINUE_PROMPT =
  "\u8BF7\u7EE7\u7EED\u6267\u884C\u4EFB\u52A1\u3002\u5982\u679C\u8FD8\u6709\u9700\u8981\u6267\u884C\u7684\u6B65\u9AA4\uFF0C\u8BF7\u4F7F\u7528\u4EE5\u4E0B\u683C\u5F0F\u56DE\u590D\uFF1A\n\n\u601D\u8003: [\u4F60\u7684\u63A8\u7406]\n\u8BF4\u660E: [\u4E00\u53E5\u8BDD\u8BF4\u660E\u8FD9\u6761\u547D\u4EE4\u505A\u4EC0\u4E48\u3001\u6709\u4EC0\u4E48\u5F71\u54CD]\n\u52A8\u4F5C: execute\n\u547D\u4EE4: [\u8981\u6267\u884C\u7684\u547D\u4EE4]\n\n\u5982\u679C\u4EFB\u52A1\u5DF2\u5168\u90E8\u5B8C\u6210\uFF0C\u8BF7\u56DE\u590D\uFF1A\n\n\u601D\u8003: [\u603B\u7ED3]\n\u52A8\u4F5C: finish";

const NOCMD = "\u53ea\u662f\u4e00\u6bb5\u666e\u901a\u6587\u5b57"; // plain prose, no ReAct field
const FINISH = "\u56de\u7b54: ok\n\u52a8\u4f5c: finish";
const CMD = "\u601d\u8003: run\n\u52a8\u4f5c: execute\n\u547d\u4ee4: echo hi";

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

const TASK = {taskId: "t-ncmd", operationId: "op", hostId: "h", goal: "g",
  modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 30} as any;

function harness(responses: string[], maxSteps = 30) {
  const ctx = {gen: 0, cancelled: false, mode: "auto"};
  const events: any[] = [];
  const finished: Array<[string, string | undefined]> = [];
  const logs: string[] = [];
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
    {onEvent: (e: any) => events.push(e), onFinished: (s: string, sm?: string) => finished.push([s, sm]), onError: () => {}},
    {
      confirmFlow: flow,
      permissionMode: () => ctx.mode as any,
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      commandExecutor: async (): Promise<CommandExecResult> =>
        ({stdout: "ran", stderr: "", exitCode: 0, durationMs: 1, success: true}),
    } as any,
  );
  const write = process.stderr.write.bind(process.stderr);
  (process.stderr as any).write = (chunk: any, enc?: any, cb?: any): boolean => {
    const s = String(chunk);
    if (s.startsWith("[agent-core] gate ")) logs.push(s);
    else write(chunk, enc, cb);
    return true;
  };
  const run = async (): Promise<string> => {
    try {
      return await engine.run(TASK, maxSteps);
    } finally {
      (process.stderr as any).write = write;
    }
  };
  return {client, events, finished, logs, run};
}

describe("no-command retry is Dart _handleNoCommand (3622-3642)", () => {
  it("within budget pushes the byte-faithful continue prompt to the next request", async () => {
    const h = harness([NOCMD, FINISH]);
    expect(await h.run()).toBe("success");
    expect(h.client.prompts.length).toBe(2);
    const second = h.client.prompts[1];
    // conversation layout: [user goal turn? no - engine sends goal separately];
    // the continue prompt must appear verbatim as a user message in request 2
    const hits = second.filter((m) => m.role === "user" && m.content === CONTINUE_PROMPT);
    expect(hits.length).toBe(1);
  });

  it("within budget emits one hourglass info event with an occurrence id", async () => {
    const h = harness([NOCMD, FINISH]);
    expect(await h.run()).toBe("success");
    const info = h.events.filter((e) => e.type === "info" && e.text === HOURGLASS);
    expect(info.length).toBe(1);
    expect(String(info[0].id).startsWith("evt_")).toBe(true);
  });

  it("within budget logs the Dart retry line on the gate channel", async () => {
    const h = harness([NOCMD, FINISH]);
    expect(await h.run()).toBe("success");
    expect(h.logs.some((s) => s.startsWith("[agent-core] gate info: " + RETRY_LOG) &&
      s.includes("1/2)"))).toBe(true);
    expect(h.logs.some((s) => s.includes("gate warn"))).toBe(false);
  });

  it("exhaustion: two continues, then failed with the pinned summary and one finish", async () => {
    const h = harness([NOCMD, NOCMD, NOCMD]);
    expect(await h.run()).toBe("failed");
    expect(h.finished).toEqual([["failed", "no-command retry exhaustion"]]);
    expect(h.events.filter((e) => e.type === "finish").length).toBe(1);
    const info = h.events.filter((e) => e.type === "info" && e.text === HOURGLASS);
    expect(info.length).toBe(2); // retries 1 and 2 continue, retry 3 is terminal
    expect(info[0].id).not.toBe(info[1].id); // occurrence ids, R4
    // third request happened (retry 2 prompt was sent), fourth did not
    expect(h.client.prompts.length).toBe(3);
    const last = h.client.prompts[2];
    expect(last.filter((m) => m.content === CONTINUE_PROMPT).length).toBe(2); // both retries in history
  });

  it("exhaustion logs the Dart warn line naming the count", async () => {
    const h = harness([NOCMD, NOCMD, NOCMD]);
    expect(await h.run()).toBe("failed");
    expect(h.logs.some((s) => s.startsWith("[agent-core] gate warn: " + EXHAUST_LOG_HEAD) &&
      s.includes("3" + EXHAUST_LOG_TAIL))).toBe(true);
  });

  it("R5: a successful command resets the counter so a later lapse is not terminal", async () => {
    // without the reset, retry counts would be 1,2,3 -> terminal on the LAST NOCMD;
    // with the reset after CMD the trailing pair is retries 1 and 2, task survives
    const h = harness([NOCMD, CMD, NOCMD, NOCMD, FINISH]);
    expect(await h.run()).toBe("success");
    const hourglasses = h.events.filter((e) => e.type === "info" && e.text === HOURGLASS);
    expect(hourglasses.length).toBe(3);
    expect(h.logs.some((s) => s.includes("1/2)"))).toBe(true);
    expect(h.logs.some((s) => s.includes("2/2)"))).toBe(true);
    expect(h.logs.some((s) => s.startsWith("[agent-core] gate warn"))).toBe(false);
    expect(h.finished).toEqual([["success", "ok"]]); // summary = answer text
  });
});
