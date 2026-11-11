// test/engine_trim.test.ts - engine-side bounded conversation history (AGENTS.md R8).
// Unit layer: the ported three-layer trim (src/utils/context_trim.ts) replayed
// against the Dart _trimMessages semantics (agent_engine.dart 4612-4671) - byte-
// faithful log strings, tail retention, fence rebalance, in-place rewrite, the
// floor-of-2 token drop. Engine layer: scripted-LLM runs proving the engine really
// trims after every conversation.push (Dart calls its trim at ~twenty add sites).
// CJK uses \uXXXX escapes per project emit rules; the romanized comment gives the
// reading of each string.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {ConfirmFlow} from "../src/react/confirm_flow.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";
import {
  trimConversation,
  truncateOneMessage,
  effectiveContextWindow,
  MAX_CONVERSATION_ROUNDS,
  MAX_MESSAGE_CHARS,
  DEFAULT_CONTEXT_WINDOW,
  CONTEXT_TOKEN_RATIO,
  type TrimMessage,
} from "../src/utils/context_trim.js";

const FENCE = String.fromCharCode(96, 96, 96); // three code ticks
// L1 wire prefix (Dart 4629): dots-paren "yi jie duan qian N zi fu" paren-newline
const PFX = (cut: number): string =>
  "...(\u5DF2\u622A\u65AD\u524D " + cut + " \u5B57\u7B26)\n"; // truncated-first marker
// L2 log (Dart 4643): "lun shu cai jian: A -> B tiao", a real U+2192 arrow
const L2LOG = (a: number, b: number): string =>
  "\u8F6E\u6570\u88C1\u526A: " + a + " \u2192 " + b + " \u6761"; // round-count trim log
// L3 log head (Dart 4660-4664): token-aware cai jian: A -> B tiao, 
const L3HEAD = (a: number, b: number): string =>
  "token-aware \u88C1\u526A: " + a + " \u2192 " + b + " \u6761, "; // token-aware trim log

const mk = (role: string, content: string): TrimMessage => ({role, content});

describe("effectiveContextWindow (Dart ai_model_config.dart 102-103)", () => {
  it("undefined, zero and negative fall back to kDefaultContextWindow", () => {
    expect(DEFAULT_CONTEXT_WINDOW).toBe(262144);
    expect(CONTEXT_TOKEN_RATIO).toBe(0.7);
    expect(MAX_CONVERSATION_ROUNDS).toBe(40); // Dart 376
    expect(MAX_MESSAGE_CHARS).toBe(4000); // Dart 379
    expect(effectiveContextWindow(undefined)).toBe(262144);
    expect(effectiveContextWindow(0)).toBe(262144);
    expect(effectiveContextWindow(-5)).toBe(262144);
    expect(effectiveContextWindow(16384)).toBe(16384);
  });
});

describe("truncateOneMessage (Dart L1, 4617-4634)", () => {
  it("at or below the cap returns the content unchanged", () => {
    const cap = "q".repeat(MAX_MESSAGE_CHARS);
    expect(truncateOneMessage(cap)).toBe(cap);
    expect(truncateOneMessage("short")).toBe("short");
  });

  it("over the cap keeps the TAIL and prefixes the Dart-faithful marker", () => {
    const big = "y".repeat(MAX_MESSAGE_CHARS + 2500);
    const out = truncateOneMessage(big);
    expect(out.startsWith(PFX(2500))).toBe(true);
    const tail = out.substring(PFX(2500).length);
    expect(tail).toBe("y".repeat(MAX_MESSAGE_CHARS)); // substring(len - cap), 4621
  });

  it("odd fence count in the retained tail gets one fence appended (4622-4626)", () => {
    const odd = "x".repeat(MAX_MESSAGE_CHARS - 3 + 4) + FENCE; // tail keeps 1 fence
    const outOdd = truncateOneMessage(odd);
    expect(outOdd.endsWith(String.fromCharCode(10) + FENCE)).toBe(true);
    const even = "x".repeat(MAX_MESSAGE_CHARS + 2) + FENCE + "a" + FENCE; // 2 fences
    const outEven = truncateOneMessage(even);
    expect(outEven.endsWith("a" + FENCE)).toBe(true); // balanced: nothing appended
  });
});

describe("trimConversation layers (Dart 4612-4671)", () => {
  it("empty list: nothing to do, no logs", () => {
    const arr: TrimMessage[] = [];
    expect(trimConversation(arr, 262144)).toEqual([]);
    expect(arr).toEqual([]);
  });

  it("small conversation is untouched and silent", () => {
    const arr = [mk("user", "hello"), mk("assistant", "hi")];
    expect(trimConversation(arr, 262144)).toEqual([]);
    expect(arr.length).toBe(2);
  });

  it("L2: 85 messages collapse to 80 with the byte-faithful log", () => {
    const arr: TrimMessage[] = [];
    for (let i = 0; i < 85; i++) arr.push(mk(i % 2 === 0 ? "user" : "assistant", "hi"));
    const logs = trimConversation(arr, DEFAULT_CONTEXT_WINDOW);
    expect(logs).toEqual([L2LOG(85, 80)]);
    expect(arr.length).toBe(MAX_CONVERSATION_ROUNDS * 2);
  });

  it("L2 keeps the most RECENT tail window, not the head (R8 tail rule)", () => {
    const arr: TrimMessage[] = [];
    for (let i = 0; i < 85; i++) arr.push(mk("user", "m" + i));
    trimConversation(arr, DEFAULT_CONTEXT_WINDOW);
    expect(arr[0].content).toBe("m5"); // 85 - 80 = 5 dropped from the front
    expect(arr[79].content).toBe("m84");
  });

  it("L3 ctx=20: budget 14, drops oldest until under budget", () => {
    const arr: TrimMessage[] = [];
    for (let i = 0; i < 6; i++) arr.push(mk("user", "a".repeat(8))); // 6 tokens each
    const logs = trimConversation(arr, 20); // budget = round(20*0.7) = 14
    // total 36: drop 4 x 6 -> 12 <= 14, floor never below 2
    expect(logs).toEqual([L3HEAD(6, 2) + "tokens=12/14 (ctx=20)"]);
    expect(arr.length).toBe(2);
  });

  it("L3 floor: ctx=1 can never drop below 2 messages", () => {
    const arr: TrimMessage[] = [];
    for (let i = 0; i < 6; i++) arr.push(mk("user", "a".repeat(8)));
    const logs = trimConversation(arr, 1); // budget = round(0.7) = 1
    expect(logs).toEqual([L3HEAD(6, 2) + "tokens=12/1 (ctx=1)"]);
    expect(arr.length).toBe(2); // drop stopped at kept.length - 2 (Dart 4655)
  });

  it("system messages pin at the head, never truncated, even past the cap", () => {
    const hugeSystem = mk("system", "S".repeat(MAX_MESSAGE_CHARS + 1000));
    const arr: TrimMessage[] = [hugeSystem];
    for (let i = 0; i < 85; i++) arr.push(mk(i % 2 === 0 ? "user" : "assistant", "hi"));
    trimConversation(arr, DEFAULT_CONTEXT_WINDOW);
    expect(arr.length).toBe(81); // 1 system + 80 kept
    expect(arr[0].role).toBe("system");
    expect(arr[0].content.length).toBe(MAX_MESSAGE_CHARS + 1000); // untouched
  });

  it("rewrite is IN PLACE on the same array reference (Dart clear plus addAll)", () => {
    const arr: TrimMessage[] = [mk("user", "q".repeat(MAX_MESSAGE_CHARS + 10))];
    const ref = arr;
    trimConversation(arr, DEFAULT_CONTEXT_WINDOW);
    expect(arr === ref).toBe(true);
    expect(arr[0].content.startsWith(PFX(10))).toBe(true);
  });

  it("L1 runs before token math (Dart 4617 then 4646): huge msg truncated, floor 1", () => {
    const arr: TrimMessage[] = [mk("user", "w".repeat(MAX_MESSAGE_CHARS + 40000))];
    trimConversation(arr, 100); // budget 70; kept.length - 2 = -1 -> nothing droppable
    expect(arr.length).toBe(1);
    expect(arr[0].content.startsWith(PFX(40000))).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Engine-level: the trim must fire between pushes, mirroring Dart calling
// _trimMessages after every history addition (call sites incl. 3027, 3567).
// ---------------------------------------------------------------------------
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

const T_THINK = "\u601d\u8003: "; // thought label
const T_ACTION_EXEC = "\u52a8\u4f5c: execute\n"; // action label + execute
const T_CMD_LINE = "\u547d\u4ee4: "; // command label
const T_ANSWER_FINISH = "\u56de\u7b54: done\n\u52a8\u4f5c: finish\n"; // finish turn
const turn = (cmd: string): string => T_THINK + "run it\n" + T_ACTION_EXEC + T_CMD_LINE + cmd + "\n";

const TASK = {taskId: "t-trim", operationId: "op", hostId: "h", goal: "g",
  modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 60} as any;

function harness(modelConfig: Record<string, unknown>, responses: string[]) {
  const ctx = {gen: 0, cancelled: false, mode: "auto"};
  const events: any[] = [];
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
    modelConfig as any,
    {onEvent: (e: any) => events.push(e), onFinished: () => {}, onError: () => {}},
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
      return await engine.run(TASK, 60);
    } finally {
      (process.stderr as any).write = write;
    }
  };
  return {client, events, logs, run};
}

describe("engine trims after every push (R8 wiring)", () => {
  it("a 5000-char assistant reply reaches the next prompt truncated silently", async () => {
    const big = "z".repeat(5000); // pure text, no keywords -> one no-command retry
    const h = harness({model: "m"}, [big, T_ANSWER_FINISH]);
    expect(await h.run()).toBe("success");
    expect(h.client.prompts.length).toBe(2);
    const second = h.client.prompts[1];
    const asst = second.find((m) => m.role === "assistant");
    expect(asst).toBeDefined();
    // Dart _trimMessages scans EVERY message on every call (4617-4634), and the
    // no-command branch now pushes a continue prompt + re-trims (3632), so the
    // assistant reply is L1-truncated twice: 5000 -> 4018 -> 4016. The second
    // pass drops exactly 18 chars - the whole first marker - so the second
    // marker (cut=18, 16 chars) sits on top of the untouched 4000-char tail.
    expect((asst as ChatMsg).content.startsWith(PFX(18))).toBe(true);
    expect((asst as ChatMsg).content).toBe(PFX(18) + "z".repeat(MAX_MESSAGE_CHARS));
    expect((asst as ChatMsg).content.length).toBe(PFX(18).length + MAX_MESSAGE_CHARS);
    // L1 is silent in Dart; default ctx 262144 means L2/L3 cannot fire at 1 message
    expect(h.logs.filter((s) => s.includes("TrimMsgs")).length).toBe(0);
  });

  it("41 command rounds: history collapses at 80 before the 42nd prompt (L2)", async () => {
    const turns: string[] = [];
    for (let i = 0; i < 41; i++) turns.push(turn("echo hi " + i));
    const h = harness({model: "m"}, [...turns, T_ANSWER_FINISH]);
    expect(await h.run()).toBe("success");
    const last = h.client.prompts[h.client.prompts.length - 1];
    // [system, 80 conversation, goal] - the cap held on the live request
    expect(last.length).toBe(82);
    expect(h.logs.some((s) => s.includes(L2LOG(81, 80)))).toBe(true);
  });

  it("contextWindow modelConfig knob drives L3 (Dart effectiveContextWindow)", async () => {
    const turns: string[] = [];
    for (let i = 0; i < 6; i++) turns.push(turn("echo hi " + i));
    const h = harness({model: "m", contextWindow: 40}, [...turns, T_ANSWER_FINISH]);
    expect(await h.run()).toBe("success");
    const l3 = h.logs.filter((s) => s.includes("token-aware"));
    expect(l3.length).toBeGreaterThan(0);
    expect(l3[l3.length - 1].includes("(ctx=40)")).toBe(true);
    // budget 28: every live prompt stays far below the untrimmed size
    const last = h.client.prompts[h.client.prompts.length - 1];
    expect(last.length).toBeLessThan(14);
  });

  it("no-contextWindow knob keeps the Dart default: no L3 chatter at all", async () => {
    const turns: string[] = [];
    for (let i = 0; i < 6; i++) turns.push(turn("echo hi " + i));
    const h = harness({model: "m"}, [...turns, T_ANSWER_FINISH]);
    expect(await h.run()).toBe("success");
    expect(h.logs.filter((s) => s.includes("token-aware")).length).toBe(0);
    expect(h.logs.filter((s) => s.includes("TrimMsgs")).length).toBe(0);
  });
});
