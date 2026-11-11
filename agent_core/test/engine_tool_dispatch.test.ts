// Round 123: engine-side tool dispatch - the Dart _handleToolAction ladder
// (agent_engine.dart 3222-3618) exercised through the REAL engine, not a
// hand-called helper. Covers: the FC-text route end to end (R9), the tool own
// command event and the result pairing on it (R4), the empty-name / think /
// execute / placeholder routes, the registry miss, the read-only and session
// scope gates, the destructive confirm (reject, approve, unwired), the wire
// output cap (R8), the throw-to-observation translation and the retry budget
// with its reset (R5). ASCII-pure: every CJK literal is a \uXXXX escape.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {ConfirmFlow} from "../src/react/confirm_flow.js";
import {LlmClient, LlmResult, LlmResponseOptions, ChatMsg} from "../src/llm/clients.js";
import {
  AgentTool, AgentToolRegistry, ToolContext, ToolKind, ToolResult, ToolScope,
} from "../src/tools/builtin.js";
import {ToolArgs} from "../src/tools/tool_args.js";
import {ToolCallAccumulator} from "../src/react/tool_action.js";
import type {PermissionMode} from "../src/rpc/schema.js";

const BT = String.fromCharCode(96);
const HOURGLASS = String.fromCharCode(0x23f3);
const CROSS = String.fromCharCode(0x274c);
const T_ANSWER_FINISH = "\u56de\u7b54: done\n\u52a8\u4f5c: finish\n"; // "answer: done / action: finish"
const T_ACTION_TOOL = "\u52a8\u4f5c: tool\n";                  // "action: tool"
const T_TOOL_LINE = "\u5de5\u5177: ";                       // "tool: "
const T_ARGS_LINE = "\u53c2\u6570:";                        // "args:"
const T_READONLY_ON = "\u53ea\u8bfb\u6a21\u5f0f\u5df2\u5f00\u542f";    // "read-only mode is on"
const OBS_EMPTY_TOOL = "\u89c2\u6d4b: \u5de5\u5177\u8c03\u7528\u5931\u8d25 \u2014 \u672a\u6307\u5b9a\u5de5\u5177\u540d";
const OBS_THINK_DONE = "\u89c2\u6d4b: \u601d\u8003\u5df2\u8bb0\u5f55\uff0c\u8bf7\u7ed9\u51fa\u4e0b\u4e00\u6b65\u52a8\u4f5c\u3002";
const OBS_ALIAS_NO_CMD_A = "\u89c2\u6d4b: ";                  // "observation: "
const OBS_ALIAS_NO_CMD_B = " \u8c03\u7528\u7f3a\u5c11 command \u53c2\u6570\uff08\u8981\u6267\u884c\u7684\u547d\u4ee4\uff09\uff0c\u8bf7\u91cd\u8bd5\u3002";
const OBS_TOOL_MISSING_A = "\u89c2\u6d4b: \u5de5\u5177 ";      // "observation: tool "
const OBS_TOOL_MISSING_B = " \u4e0d\u5b58\u5728\u3002\u53ef\u7528\u5de5\u5177: "; // " does not exist. available tools: "
const OBS_READONLY_TOOL = "\u89c2\u6d4b: \u5f53\u524d\u4e3a\u53ea\u8bfb\u6a21\u5f0f\uff0c\u7981\u6b62\u8c03\u7528\u4f1a\u4ea7\u751f\u53d8\u66f4\u7684\u5de5\u5177\u3002\u8bf7\u6539\u7528\u53ea\u8bfb\u5de5\u5177/\u547d\u4ee4\u6536\u96c6\u4fe1\u606f\uff0c\u6216\u7528 finish \u544a\u77e5\u7528\u6237\u201c\u5f53\u524d\u4e3a\u53ea\u8bfb\u6a21\u5f0f\uff0c\u8bf7\u5173\u95ed\u540e\u91cd\u8bd5\u201d\u3002";
const OBS_OK_A = "\u89c2\u6d4b: \u547d\u4ee4 ";            // "observation: command "
const OBS_OK_B = " \u6267\u884c\u6210\u529f";             // " succeeded"
const TOOL_RETRY_SUMMARY = "\u5de5\u5177\u8c03\u7528\u91cd\u8bd5\u6b21\u6570\u8017\u5c3d\uff0c\u4efb\u52a1\u7ec8\u6b62"; // finish summary of the tool budget
const T_REFUSE_TOOL = "\u7528\u6237\u62d2\u7edd\u6267\u884c\u8be5\u64cd\u4f5c"; // "user refused this operation" (the "that operation" spelling, NOT "this command")

/** Records every prompt the engine sends, so "was this observation handed to the
 * model?" stays answerable without poking at private state (same idiom as the
 * command-gate suite). */
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

class StubTool extends AgentTool {
  readonly name: string;
  readonly description = "stub";
  readonly paramSpec = "k: value";
  executed = 0;
  lastArgs?: ToolArgs;
  private readonly kindValue?: ToolKind;
  private readonly fn?: (args: ToolArgs, ctx: ToolContext) => Promise<ToolResult>;
  constructor(
    name: string,
    kind?: ToolKind,
    fn?: (args: ToolArgs, ctx: ToolContext) => Promise<ToolResult>,
  ) {
    super();
    this.name = name;
    this.kindValue = kind;
    this.fn = fn;
  }
  override get kind(): ToolKind { return this.kindValue ?? super.kind; }
  toJsonSchema(): Record<string, unknown> { return {type: "object", properties: {}}; }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    this.executed++;
    this.lastArgs = args;
    return this.fn ? this.fn(args, ctx) : ToolResult.success("ok");
  }
}

interface Harness {
  engine: ReActEngine;
  flow?: ConfirmFlow;
  client: ScriptedClient;
  events: any[];
  execs: string[];
  finished: Array<[string, string | undefined]>;
  userText: (turn: number) => string;
  run: () => Promise<string>;
}

function harness(opts: {
  mode: PermissionMode;
  responses: string[];
  tools?: (r: AgentToolRegistry) => void;
  isLocalSession?: boolean;
  wireFlow?: boolean;
  executor?: (cmd: string) => Promise<CommandExecResult>;
}): Harness {
  const ctx = {gen: 0, cancelled: false, mode: opts.mode};
  const events: any[] = [];
  const execs: string[] = [];
  const finished: Array<[string, string | undefined]> = [];
  const client = new ScriptedClient(opts.responses);
  const registry = new AgentToolRegistry();
  if (opts.tools !== undefined) opts.tools(registry);
  let flow: ConfirmFlow | undefined;
  if (opts.wireFlow !== false) {
    flow = new ConfirmFlow({
      context: {
        currentGeneration: () => ctx.gen,
        permissionMode: () => ctx.mode,
        isCancelled: () => ctx.cancelled,
        bumpGeneration: () => { ctx.gen++; },
      },
      events: {onInfo: () => {}, onConfirmRequest: () => {}, onWaitingConfirm: () => {}, onLog: () => {}},
    });
  }
  const engine = new ReActEngine(
    client,
    {model: "m"} as any,
    {onEvent: (e: any) => events.push(e), onFinished: (s: any, sum?: string) => finished.push([s, sum]), onError: () => {}},
    {
      confirmFlow: flow,
      permissionMode: () => ctx.mode,
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      toolRegistry: opts.tools !== undefined ? registry : undefined,
      isLocalSession: opts.isLocalSession ?? false,
      commandExecutor: opts.executor ??
        (async (cmd: string): Promise<CommandExecResult> => {
          execs.push(cmd);
          return {stdout: "ran", stderr: "", exitCode: 0, durationMs: 1, success: true};
        }),
    } as any,
  );
  const task = {taskId: "t-dsp", operationId: "op", hostId: "h", goal: "g",
    modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 10} as any;
  return {
    engine, flow, client, events, execs, finished,
    userText: (turn: number): string =>
      client.prompts[turn].filter((m) => m.role === "user").map((m) => m.content).join("\n====\n"),
    run: () => engine.run(task, 10) as Promise<string>,
  };
}

const FINISH = [T_ANSWER_FINISH];

/** "action: tool / tool: NAME / args: / two-space key:value lines" - the shape
 * parseToolAction accepts, same grammar toReActText emits. */
function toolTurn(name: string, args?: Array<[string, string]>): string {
  let t = T_ACTION_TOOL + T_TOOL_LINE + name + "\n";
  if (args !== undefined && args.length > 0) {
    t += T_ARGS_LINE + "\n";
    for (const [k, v] of args) t += "  " + k + ": " + v + "\n";
  }
  return t;
}

async function settle(pred: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 400; i++) {
    if (pred()) return;
    await new Promise<void>((res) => setTimeout(res, 5));
  }
  throw new Error("timed out waiting for " + label);
}
const OBS_OK_C = "\u8f93\u51fa:"; // "output:"
const OBS_TOOL_EXC_A = "\u89c2\u6d4b: \u5de5\u5177 ";        // "observation: tool "
const OBS_TOOL_EXC_B = " \u6267\u884c\u5f02\u5e38 \u2014 ";      // " threw during execution - "
const TRUNC_MARK_RT = String.fromCharCode(10) + "...(" +
  String.fromCharCode(0x8f93, 0x51fa, 0x5df2, 0x622a, 0x65ad) + ")"; // runtime form of the engine truncation mark

describe("round 123: tool dispatch through the real engine (R9 end-to-end)", () => {
  it("FC text from toReActText routes to the tool executor, R4 ids pair up, budget resets", async () => {
    // R9 mandates the REAL generated text here, not a hand-written lookalike:
    // ToolCallAccumulator.toReActText -> engine action scan -> parseToolAction ->
    // dispatch -> executor. The historical bugs were exactly in the seams: a glued
    // the action keyword line and a premature parser break on the tool keyword
    const t = new StubTool("lookup");
    const fcText = ToolCallAccumulator.toReActText([{id: "fc1", name: "lookup", arguments: "{\"k\": \"v\"}"}]);
    expect(fcText.startsWith("\n")).toBe(true);
    expect(fcText).toContain(T_ACTION_TOOL.trim());
    expect(fcText).toContain(T_TOOL_LINE + "lookup");
    const h = harness({mode: "fullAuto", responses: [fcText, ...FINISH], tools: (r) => r.register(t)});
    const state = await h.run();
    expect(state).toBe("success");
    expect(t.executed).toBe(1);
    expect(t.lastArgs!.getString("k")).toBe("v");
    // R5: the successful call reset the retry budget, so the loop stayed alive
    // long enough for the finish turn to land (the Dart budget is >= 2).
    expect(h.finished).toEqual([["success", "done"]]);
    const cmdEvts = h.events.filter((e) => e.type === "command");
    const resEvts = h.events.filter((e) => e.type === "result");
    expect(cmdEvts.length).toBe(1);
    expect(resEvts.length).toBe(1);
    expect(cmdEvts[0].toolName).toBe("lookup");
    // The tool card is NOT enriched: no risk level, no permission decision.
    expect(cmdEvts[0].riskLevel === undefined).toBe(true);
    expect(cmdEvts[0].permissionDecision === undefined).toBe(true);
    // R4: the result pairs with the tool command event id and with nothing else.
    expect(resEvts[0].commandId).toBe(cmdEvts[0].id);
    expect(resEvts[0].commandId).toMatch(/^evt_\d+_\d+$/);
    expect(resEvts[0].success).toBe(true);
    expect(resEvts[0].output).toBe("ok");
    expect(resEvts[0].toolName).toBe("lookup");
    // Wire contract: full text up to 8000 chars - no line cap, no tail field.
    expect(resEvts[0].outputTruncated).toBe(false);
    expect(resEvts[0].outputTotalChars).toBe(2);
    expect(resEvts[0].outputTail === undefined).toBe(true);
    // The observation is the SECOND display call, cap 0: the model sees its full
    // arguments. Multi-line (args present) => bare, no backticks (format rule).
    const turn1 = h.userText(1);
    expect(turn1).toContain(OBS_OK_A + "lookup" + "\n  k: v" + OBS_OK_B);
    expect(turn1).toContain(OBS_OK_C);
    expect(turn1).toContain("\nok" + "\n");
  }, 20000);

  it("no-argument call: the observation command reference is backtick-wrapped", async () => {
    const t = new StubTool("ping");
    const h = harness({mode: "fullAuto", responses: [toolTurn("ping"), ...FINISH], tools: (r) => r.register(t)});
    expect(await h.run()).toBe("success");
    expect(t.executed).toBe(1);
    expect(h.userText(1)).toContain(OBS_OK_A + BT + "ping" + BT + OBS_OK_B);
    // Empty args => the bare name display (no "args:" header line at all).
    expect(h.events.filter((e) => e.type === "command")[0].command).toBe("ping");
  }, 20000);

  it("registry-less engine: a tool action behaves exactly like a command-less reply", async () => {
    // The junction gates the scan on toolRegistry === undefined, so with no
    // registry the old no-command branch runs byte for byte: hourglass info,
    // the continue prompt, zero tool machinery, and the <= budget idiom.
    const h = harness({mode: "fullAuto", responses: [toolTurn("lookup", [["k", "v"]]), ...FINISH]});
    const state = await h.run();
    expect(state).toBe("success");
    const infos = h.events.filter((e) => e.type === "info");
    expect(infos.some((e) => String(e.text).startsWith(HOURGLASS))).toBe(true);
    expect(h.events.some((e) => e.type === "command")).toBe(false);
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    expect(h.userText(1)).not.toContain("k: v");
  }, 20000);

  it("execute alias routes through the full gate: own event first, result links to it", async () => {
    const h = harness({mode: "fullAuto", responses: [toolTurn("execute", [["command", "whoami"]]), ...FINISH],
      tools: (r) => r.register(new StubTool("unused_anchor"))});
    expect(await h.run()).toBe("success");
    expect(h.execs).toEqual(["whoami"]);
    const cmdEvts = h.events.filter((e) => e.type === "command");
    const resEvts = h.events.filter((e) => e.type === "result");
    expect(cmdEvts.length).toBe(1);
    expect(resEvts.length).toBe(1);
    // The alias event is a shell command: enriched like any other, no toolName.
    // Enrichment fill-if-absent: the alias event had no toolName, so the gate
    // stamps the shell default exec_command; the tool card above keeps its own name.
    expect(cmdEvts[0].toolName).toBe("exec_command");
    expect(cmdEvts[0].riskLevel !== undefined).toBe(true);
    expect(resEvts[0].commandId).toBe(cmdEvts[0].id);
    // Plain-command success observation is the shared "command execution
    // result: <output>" format (NOT the tool-path format) - the alias re-entered
    // the ordinary gate, observations and all.
    expect(h.userText(1)).toContain("\u547d\u4ee4\u6267\u884c\u7ed3\u679c: ran");
  }, 20000);

  it("execute alias with no command: parameter-miss observation then budget death", async () => {
    // Dart budget sites share one counter with >= maxNoCommandRetries (2): the
    // first miss continues, the second is terminal with the tool retry summary.
    const h = harness({mode: "fullAuto", responses: [toolTurn("execute"), toolTurn("exec")],
      tools: (r) => r.register(new StubTool("unused_anchor"))});
    expect(await h.run()).toBe("failed");
    expect(h.execs).toEqual([]);
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    expect(h.finished).toEqual([["failed", TOOL_RETRY_SUMMARY]]);
    expect(h.userText(1)).toContain(OBS_ALIAS_NO_CMD_A + "execute" + OBS_ALIAS_NO_CMD_B);
  }, 20000);

  it("think alias records the thought and resets the retry budget", async () => {
    // Three think aliases in a row must not die: each one resets the counter to
    // zero. Under the Dart >= rule the second consecutive alias would already
    // be terminal if the reset were missing.
    const h = harness({mode: "fullAuto", responses: [
      toolTurn("think", [["thought", "step one plan"]]),
      toolTurn("thinking", [["reasoning", "step two plan"]]),
      toolTurn("reason", [["content", "step three plan"]]),
      ...FINISH,
    ], tools: (r) => r.register(new StubTool("unused_anchor"))});
    expect(await h.run()).toBe("success");
    const thoughts = h.events.filter((e) => e.type === "thought");
    expect(thoughts.map((e) => e.text)).toEqual(["step one plan", "step two plan", "step three plan"]);
    for (let turn = 1; turn <= 3; turn++) expect(h.userText(turn)).toContain(OBS_THINK_DONE);
  }, 20000);

  it("placeholder with thought content behaves as a thought; bare placeholder lists tools", async () => {
    // Two faces of the placeholder fallback (Dart 3313-3335): thought-shaped
    // args become a thought (no retry), empty args hand back the inventory
    // (also no retry - the model got a usable correction, not an error).
    const reg = new StubTool("lookup");
    const h = harness({mode: "fullAuto", responses: [
      toolTurn("tool_call", [["thinking", "placeholder thought"]]),
      toolTurn("call_function"),
      ...FINISH,
    ], tools: (r) => r.register(reg)});
    expect(await h.run()).toBe("success");
    const thoughts = h.events.filter((e) => e.type === "thought");
    expect(thoughts.map((e) => e.text)).toEqual(["placeholder thought"]);
    expect(h.userText(1)).toContain(OBS_THINK_DONE);
    expect(h.userText(2)).toContain(OBS_TOOL_MISSING_A + "call_function" + OBS_TOOL_MISSING_B + "lookup");
  }, 20000);

  it("empty tool name: warn/info/observation then the budget", async () => {
    const h = harness({mode: "fullAuto", responses: [
      toolTurn(""),
      toolTurn(""),
    ], tools: (r) => r.register(new StubTool("unused_anchor"))});
    expect(await h.run()).toBe("failed");
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    expect(h.finished).toEqual([["failed", TOOL_RETRY_SUMMARY]]);
    expect(h.events.some((e) => e.type === "info" && String(e.text).indexOf("AI") >= 0 &&
      String(e.text).includes("\u5de5\u5177"))) // "tool" appears in the info text
      .toBe(true);
    expect(h.userText(1)).toContain(OBS_EMPTY_TOOL);
  }, 20000);

  it("unknown tool name: available-list observation, one retry consumed", async () => {
    const reg = new StubTool("lookup");
    const h = harness({mode: "fullAuto", responses: [
      toolTurn("nosuch_tool"),
      ...FINISH,
    ], tools: (r) => r.register(reg)});
    expect(await h.run()).toBe("success");
    expect(h.events.filter((e) => e.type === "result").length).toBe(0);
    expect(h.userText(1)).toContain(OBS_TOOL_MISSING_A + "nosuch_tool" + OBS_TOOL_MISSING_B + "lookup");
  }, 20000);

  it("readOnly mode refuses a write tool before execute, name backtick-wrapped", async () => {
    const w = new StubTool("write_tool", ToolKind.write);
    const h = harness({mode: "readOnly", responses: [toolTurn("write_tool", [["path", "/tmp/x"]]), ...FINISH],
      tools: (r) => r.register(w)});
    expect(await h.run()).toBe("success");
    expect(w.executed).toBe(0);
    expect(h.execs).toEqual([]);
    const infos = h.events.filter((e) => e.type === "info");
    const lockInfo = infos.filter((e) => String(e.text).includes(BT + "write_tool" + BT));
    expect(lockInfo.length).toBe(1);
    // The refusal info carries the read-only sentence and the backticked name.
    expect(String(lockInfo[0].text)).toContain("\u53ea\u8bfb");
    expect(h.userText(1)).toContain(OBS_READONLY_TOOL);
  }, 20000);

  it("readOnly mode still lets a read tool through", async () => {
    const r = new StubTool("read_tool", ToolKind.read);
    const h = harness({mode: "readOnly", responses: [toolTurn("read_tool"), ...FINISH],
      tools: (reg) => reg.register(r)});
    expect(await h.run()).toBe("success");
    expect(r.executed).toBe(1);
  }, 20000);

  it("session scope: a local-session tool is invisible on an SSH session", async () => {
    const local = new StubTool("local_only", ToolKind.write);
    const shared = new StubTool("shared_tool", ToolKind.read);
    const h = harness({mode: "fullAuto", isLocalSession: false, responses: [
      toolTurn("local_only"),
      ...FINISH,
    ], tools: (r) => { r.register(local, ToolScope.localSession); r.register(shared); }});
    expect(await h.run()).toBe("success");
    expect(local.executed).toBe(0);
    const infos = h.events.filter((e) => e.type === "info");
    expect(infos.some((e) => String(e.text).includes(BT + "local_only" + BT))).toBe(true);
    const turn1 = h.userText(1);
    expect(turn1).toContain("\u5de5\u5177 local_only \u5728\u5f53\u524d\u4f1a\u8bdd\u4e0d\u53ef\u7528\u3002");
    // The available list in the observation only contains visible tools.
    expect(turn1).toContain("shared_tool");
  }, 20000);

  it("destructive + user refusal: no execute, refusal trio, result pairs, budget intact", async () => {
    const w = new StubTool("rm_rf", ToolKind.destructive);
    const h = harness({mode: "ask", responses: [toolTurn("rm_rf"), ...FINISH], tools: (r) => r.register(w)});
    const p = h.run();
    await settle(() => h.flow !== undefined && h.flow.hasPendingConfirm, "tool confirm armed");
    h.flow!.rejectDangerousCommand();
    expect(await p).toBe("success");
    expect(w.executed).toBe(0);
    const infos = h.events.filter((e) => e.type === "info");
    expect(infos.some((e) => String(e.text).startsWith(CROSS) && String(e.text).includes(T_REFUSE_TOOL))).toBe(true);
    const resEvts = h.events.filter((e) => e.type === "result");
    expect(resEvts.length).toBe(1);
    // Refusal result: links to the tool command event, carries the reason, and
    // has NO durationMs (nothing was ever executed).
    const cmdEvts = h.events.filter((e) => e.type === "command");
    expect(resEvts[0].commandId).toBe(cmdEvts[0].id);
    expect(resEvts[0].success).toBe(false);
    expect(resEvts[0].error).toBe(T_REFUSE_TOOL);
    expect(resEvts[0].durationMs === undefined).toBe(true);
    expect(h.userText(1)).toContain("\u89c2\u6d4b: " + T_REFUSE_TOOL + "\u3002");
    // A user refusal is not the AI stumbling: the retry budget stays untouched,
    // proven by the finish turn still arriving (state success above).
  }, 20000);

  it("destructive + user approval: the tool runs after the wait", async () => {
    const w = new StubTool("rm_rf", ToolKind.destructive);
    const h = harness({mode: "ask", responses: [toolTurn("rm_rf"), ...FINISH], tools: (r) => r.register(w)});
    const p = h.run();
    await settle(() => h.flow !== undefined && h.flow.hasPendingConfirm, "tool confirm armed");
    h.flow!.confirmDangerousCommand();
    expect(await p).toBe("success");
    expect(w.executed).toBe(1);
  }, 20000);

  it("destructive in fullAuto skips the wait; unwired flow executes loudly", async () => {
    // Two locked postures: fullAuto never asks (permission policy), and a missing
    // ConfirmFlow executes too - callers that never answer rpc:confirm must not
    // see every destructive tool deadlocked. The warn goes to stderr (logGate).
    const a = new StubTool("rm_a", ToolKind.destructive);
    const h1 = harness({mode: "fullAuto", responses: [toolTurn("rm_a"), ...FINISH], tools: (r) => r.register(a)});
    expect(await h1.run()).toBe("success");
    expect(a.executed).toBe(1);
    const b = new StubTool("rm_b", ToolKind.destructive);
    const h2 = harness({mode: "ask", wireFlow: false, responses: [toolTurn("rm_b"), ...FINISH],
      tools: (r) => r.register(b)});
    expect(await h2.run()).toBe("success");
    expect(b.executed).toBe(1);
  }, 20000);

  it("wire output caps at 8000 chars + mark; the R8 trim keeps the observation tail", async () => {
    // Row-numbered payload so head and tail are distinguishable:
    // wire card = head 8000 + mark, model observation = the engine trim's TAIL.
    let big = "";
    for (let i = 1; i <= 1500; i++) big += "row" + i + ";";
    expect(big.length).toBeGreaterThan(8000);
    const t = new StubTool("bigtool", ToolKind.read, async () => ToolResult.success(big));
    const h = harness({mode: "fullAuto", responses: [toolTurn("bigtool"), ...FINISH], tools: (r) => r.register(t)});
    expect(await h.run()).toBe("success");
    const resEvts = h.events.filter((e) => e.type === "result");
    expect(resEvts[0].outputTruncated).toBe(true);
    expect(resEvts[0].outputTotalChars).toBe(big.length);
    expect(String(resEvts[0].output).length).toBe(8000 + TRUNC_MARK_RT.length);
    expect(String(resEvts[0].output).endsWith(TRUNC_MARK_RT)).toBe(true);
    expect(String(resEvts[0].output).startsWith("row1;")).toBe(true);
    // The tool path has NO outputTail - unlike the command path cap.
    expect(resEvts[0].outputTail === undefined).toBe(true);
    // The observation is pushed uncapped, but the R8 per-message conversation
    // trim (MAX_MESSAGE_CHARS) then keeps the TAIL: the model sees the END of
    // the output (row1500;) and loses its head (row1;) - R8 semantics: the tail
    // is what the next action needs. If either layer regressed, this fails.
    const turn1 = h.userText(1);
    expect(turn1).toContain("row1500;");
    expect(turn1).not.toContain("row1;");
  }, 20000);

  it("throwing tool becomes a failed result + observation, never a crashed loop", async () => {
    const boom = new StubTool("crasher", ToolKind.write,
      async (): Promise<ToolResult> => { throw new Error("kaput inside"); });
    const h = harness({mode: "fullAuto", responses: [toolTurn("crasher"), ...FINISH], tools: (r) => r.register(boom)});
    expect(await h.run()).toBe("success");
    const resEvts = h.events.filter((e) => e.type === "result");
    expect(resEvts.length).toBe(1);
    expect(resEvts[0].success).toBe(false);
    expect(resEvts[0].failureKind).toBe("unknown");
    expect(String(resEvts[0].error)).toContain("kaput inside");
    expect(resEvts[0].outputTruncated).toBe(false);
    expect(String(resEvts[0].error).length).toBe(resEvts[0].outputTotalChars);
    expect(h.userText(1)).toContain(OBS_TOOL_EXC_A + "crasher" + OBS_TOOL_EXC_B);
  }, 20000);

  it("failed ToolResult feeds the failure observation; success resets the shared budget", async () => {
    // Mixed ladder proves R5 reset across sites: empty-name retry (+1), failed
    // tool (no reset), successful tool (reset), empty-name retry (+1) - still
    // alive because the success wiped the counter between the two misses.
    const failTool = new StubTool("flaky", ToolKind.read,
      async (): Promise<ToolResult> => ToolResult.failure("disk hiccapped"));
    const okTool = new StubTool("sturdy", ToolKind.read);
    const h = harness({mode: "fullAuto", responses: [
      toolTurn(""),
      toolTurn("flaky"),
      toolTurn("sturdy"),
      toolTurn(""),
      ...FINISH,
    ], tools: (r) => { r.register(failTool); r.register(okTool); }});
    expect(await h.run()).toBe("success");
    expect(failTool.executed).toBe(1);
    expect(okTool.executed).toBe(1);
    // Failed-tool observation follows the shared failure format: error block.
    const turn2 = h.userText(2);
    expect(turn2).toContain("\u9519\u8bef:");
    expect(turn2).toContain("disk hiccapped");
  }, 25000);

  it("tool context adapter: executor proxy and session flag reach the tool", async () => {
    let sawCtx: ToolContext | undefined;
    const t = new StubTool("ctx_probe", ToolKind.read, async (_a: ToolArgs, ctx: ToolContext): Promise<ToolResult> => {
      sawCtx = ctx;
      const out = await ctx.executor!("probe_cmd", {});
      return ToolResult.success("exec:" + out.exitCode + ":" + out.stdout);
    });
    const h = harness({mode: "fullAuto", responses: [toolTurn("ctx_probe"), ...FINISH], tools: (r) => r.register(t)});
    expect(await h.run()).toBe("success");
    expect(sawCtx !== undefined).toBe(true);
    expect(sawCtx!.isLocalSession).toBe(false);
    expect(h.execs).toEqual(["probe_cmd"]);
    const resEvts = h.events.filter((e) => e.type === "result");
    expect(resEvts[0].output).toContain("exec:0:ran");
  }, 20000);
});
