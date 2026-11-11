// Engine-side R8 wiring (Dart 2809-2874): the model-facing texts are the
// CAPPED ones - query commands get the tail-20000 cap, everything else the
// 8-line/600-char cap; the wire event gains outputTotalChars /
// outputTruncated / outputTail (Dart 2871-2873). The empty placeholder
// stays Node's own ASCII "(no output)" (Dart uses the zh marker inside its
// truncators - a pinned, documented divergence).
// CJK uses \uXXXX escapes per project emit rules; ASCII-only file.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {ConfirmFlow} from "../src/react/confirm_flow.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";

const NL = String.fromCharCode(10);
const REACT_CAT = "\u601d\u8003: run\n\u52a8\u4f5c: execute\n\u547d\u4ee4: cat big.txt";
const REACT_DO = "\u601d\u8003: run\n\u52a8\u4f5c: execute\n\u547d\u4ee4: do_work --now";
const FINISH = "\u56de\u7b54: ok\n\u52a8\u4f5c: finish";
const NO_OUT = "(no output)";
const PRE = "...(\u8F93\u51FA\u8FC7\u957F\uFF0C\u5DF2\u622A\u65AD\u524D ";
const SUF_CHARS = " \u5B57\u7B26)";

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

const TASK = {taskId: "t-ocap", operationId: "op", hostId: "h", goal: "g",
  modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 30} as any;

function harness(responses: string[], executor: (cmd: string, ctx: any) => Promise<CommandExecResult>) {
  const ctx = {gen: 0, cancelled: false, mode: "auto"};
  const events: any[] = [];
  const finished: Array<[string, string | undefined]> = [];
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
      commandExecutor: executor,
    } as any,
  );
  const run = (): Promise<string> => engine.run(TASK, 30);
  return {client, events, finished, run};
}

const okExec = (stdout: string) => async (): Promise<CommandExecResult> =>
  ({stdout, stderr: "", exitCode: 0, durationMs: 1, success: true});

describe("engine R8 output capping (Dart 2809-2874 wiring)", () => {
  it("non-query command: 8-line/600-char cap, evidence tail for the wire", async () => {
    const out = "a".repeat(2000); // one line, no query prefix
    const h = harness([REACT_DO, FINISH], okExec(out));
    expect(await h.run()).toBe("success");
    const res = h.events.filter((e) => e.type === "result");
    expect(res.length).toBe(1);
    expect(res[0].output.startsWith(PRE + (2000 - 600) + SUF_CHARS + NL)).toBe(true);
    expect(res[0].output.endsWith("a".repeat(600))).toBe(true);
    expect(res[0].outputTotalChars).toBe(2000);
    expect(res[0].outputTruncated).toBe(true);
    expect(res[0].outputTail).toBe(out); // under 8000: the whole raw output
  });
  it("query command: tail-20000 cap and NO wire tail (already a tail)", async () => {
    const out = "b".repeat(25000);
    const h = harness([REACT_CAT, FINISH], okExec(out));
    expect(await h.run()).toBe("success");
    const res = h.events.filter((e) => e.type === "result");
    expect(res[0].output.startsWith(PRE + (25000 - 20000) + SUF_CHARS + NL)).toBe(true);
    expect(res[0].output.endsWith("b".repeat(20000))).toBe(true);
    expect(res[0].outputTotalChars).toBe(25000);
    expect(res[0].outputTruncated).toBe(true);
    expect(res[0].outputTail).toBeUndefined();
  });
  it("short output passes untouched: no counters tripped, no tail", async () => {
    const h = harness([REACT_CAT, FINISH], okExec("hello world"));
    expect(await h.run()).toBe("success");
    const res = h.events.filter((e) => e.type === "result");
    expect(res[0].output).toBe("hello world");
    expect(res[0].outputTotalChars).toBe(11);
    expect(res[0].outputTruncated).toBe(false);
    expect(res[0].outputTail).toBeUndefined();
  });
  it("empty output keeps the Node ASCII placeholder pin", async () => {
    const h = harness([REACT_CAT, FINISH], okExec(""));
    expect(await h.run()).toBe("success");
    const res = h.events.filter((e) => e.type === "result");
    expect(res[0].output).toBe(NO_OUT);
    expect(res[0].outputTruncated).toBe(false);
  });
  it("observation pushed to history is the CAPPED text (R8 context cap)", async () => {
    const h = harness([REACT_DO, FINISH], okExec("a".repeat(2000)));
    expect(await h.run()).toBe("success");
    expect(h.client.prompts.length).toBe(2);
    const zhHead = "\u547d\u4ee4\u6267\u884c\u7ed3\u679c:";
    const obs = h.client.prompts[1].filter((m) => m.role === "user" && m.content.startsWith(zhHead));
    expect(obs.length).toBe(1);
    expect(obs[0].content.length).toBeLessThan(800); // 2000-char raw is gone
    expect(obs[0].content.includes(SUF_CHARS + NL + "a".repeat(600))).toBe(true);
    expect(obs[0].content.includes("a".repeat(601))).toBe(false);
  });
});
