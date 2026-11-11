// Engine-side command gate, end to end (doc sec. 9 item 6/7).
//
// The gate lives in react/engine.ts: classify with checkSafety, decide with
// decideCommand, and only then touch the executor. Unit tests of the matrix cannot
// prove that ordering, nor that a reject really skips the executor, nor that the
// confirm wait is the SAME ConfirmFlow instance rpc:confirm answers (R9 demands the
// assembled pipeline, not three passing components).
//
// Two layers below: an in-process engine driven with an injected flow (exact control
// over mode / generation / cancellation), and the real RPC server, where the flow is
// armed BY THE ENGINE and answered over the wire.
import {describe, it, expect} from "vitest";
import {ReActEngine, CommandExecResult} from "../src/react/engine.js";
import {
  ConfirmFlow,
  formatObservationFailure,
  CONFIRM_REASON_TIMEOUT,
  CONFIRM_REASON_USER_REJECTED,
  CONFIRM_REASON_PERMISSION_CHANGED,
  CONFIRM_REASON_GENERATION_INVALID,
  CONFIRM_REASON_CANCELLED,
} from "../src/react/confirm_flow.js";
import {getSafetyReason} from "../src/utils/safety_guard.js";
import {startServer, confirmFlowForTesting} from "../src/index.js";
import {
  LlmClient,
  LlmResult,
  LlmResponseOptions,
  ChatMsg,
} from "../src/llm/clients.js";
import type {PermissionMode} from "../src/rpc/schema.js";

// CJK literals are escaped so this file stays byte-pure ASCII; the gloss in each
// comment is the text being matched, not a translation of the assertion.
const BT = String.fromCharCode(96);
const LOCK = String.fromCharCode(0xd83d, 0xdd12);   // lock glyph the reject info is prefixed with
const CROSS = String.fromCharCode(0x274c);          // refusal glyph the flow emits
const HOURGLASS = String.fromCharCode(0x23f1);      // timeout glyph the flow emits
const CHECK = String.fromCharCode(0x2705);          // proceed glyph the flow emits
const T_READONLY_ON = "\u53ea\u8bfb\u6a21\u5f0f\u5df2\u5f00\u542f";            // "read-only mode is on"
const T_READONLY_BLOCK = "\u53ea\u8bfb\u6a21\u5f0f\u62e6\u622a";                 // "blocked by read-only mode"
const T_DENIED_SUFFIX = "\uff0c\u6b64\u4ee4\u88ab\u62d2\u7edd\u6267\u884c: ";    // ", this command was refused: "
const T_LEVEL = "\u7b49\u7ea7: ";                              // "level: "
const T_REASON = "\u8bf4\u660e: ";                              // "detail: "
const T_USER_REJECT = "\u7528\u6237\u62d2\u7edd\u6267\u884c\u6b64\u547d\u4ee4"; // "user refused this command"
const T_TIMEOUT = "\u786e\u8ba4\u8d85\u65f6\uff0810 \u5206\u949f\u65e0\u54cd\u5e94\uff09\uff0c\u5df2\u81ea\u52a8\u62d2\u7edd"; // "confirm timed out, auto-rejected"
const T_MODE_SWITCH = "\u7b49\u5f85\u786e\u8ba4\u671f\u95f4\u6743\u9650\u6863\u4f4d\u5df2\u5207\u6362\u4e3a\u53ea\u8bfb\uff0c\u547d\u4ee4\u672a\u6267\u884c"; // "mode switched to read-only during the wait"
const T_CONFIRMED = "\u7528\u6237\u5df2\u786e\u8ba4\uff0c\u5f00\u59cb\u6267\u884c"; // "user confirmed, starting"
const T_UNWIRED = "\u786e\u8ba4\u901a\u9053\u672a\u63a5\u7ebf";                  // "confirm channel not wired"
const T_CMD_LINE = "\u547d\u4ee4: ";                              // "command: " (ReAct wire)
const T_THINK = "\u601d\u8003: ";                              // "thought: "
const T_ACTION_EXEC = "\u52a8\u4f5c: execute\n";               // "action: execute"
const T_ANSWER_FINISH = "\u56de\u7b54: done\n\u52a8\u4f5c: finish\n"; // finish turn

const CMD_WARN = "rm -rf ./build-cache";            // classified warn by the real table
const CMD_BLOCKED = "rm -rf /";                     // classified blocked
const CMD_SAFE = "echo hello world";                // classified safe
const REASON_WARN = getSafetyReason(CMD_WARN) ?? "";

/** Records every prompt the engine sends, so "was this observation handed to the
 * model?" is answerable without poking at private state. */
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

function turn(cmd: string): string {
  return T_THINK + "run it\n" + T_ACTION_EXEC + T_CMD_LINE + cmd + "\n";
}

const TASK = {taskId: "t-gate", operationId: "op", hostId: "h", goal: "g",
  modelProvider: "openai", model: "m", temperature: 0.2, maxSteps: 10} as any;

async function settle(pred: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 400; i++) {
    if (pred()) return;
    await new Promise<void>((res) => setTimeout(res, 5));
  }
  throw new Error("timed out waiting for " + label);
}

interface Harness {
  engine: ReActEngine;
  flow: ConfirmFlow;
  client: ScriptedClient;
  events: any[];
  requests: string[];
  order: string[];
  ctx: {gen: number; cancelled: boolean; mode: PermissionMode};
  run: () => Promise<string>;
}

function harness(opts: {
  mode: PermissionMode;
  responses: string[];
  wireFlow?: boolean;
  safetyCheck?: (cmd: string) => any;
  executor?: (cmd: string) => Promise<CommandExecResult>;
}): Harness {
  const ctx = {gen: 0, cancelled: false, mode: opts.mode};
  const events: any[] = [];
  const requests: string[] = [];
  const order: string[] = [];
  const client = new ScriptedClient(opts.responses);
  let flow: ConfirmFlow | undefined;
  if (opts.wireFlow !== false) {
    flow = new ConfirmFlow({
      context: {
        currentGeneration: () => ctx.gen,
        permissionMode: () => ctx.mode,
        isCancelled: () => ctx.cancelled,
        bumpGeneration: () => { ctx.gen++; },
      },
      events: {
        onInfo: (t) => requests.push(t),
        onConfirmRequest: (r) => requests.push("request:" + r.confirmId + ":" + r.riskLevel),
        onWaitingConfirm: () => requests.push("waiting"),
        onLog: () => {},
      },
    });
  }
  const engine = new ReActEngine(
    client,
    {model: "m"} as any,
    {onEvent: (e: any) => events.push(e), onFinished: () => {}, onError: () => {}},
    {
      confirmFlow: flow,
      permissionMode: () => ctx.mode,
      generation: {current: () => ctx.gen, bump: () => { ctx.gen++; }},
      safetyCheck: opts.safetyCheck ?? undefined,
      commandExecutor: opts.executor ??
        (async (cmd: string): Promise<CommandExecResult> => {
          requests.push("exec:" + cmd);
          order.push("exec");
          return {stdout: "ran", stderr: "", exitCode: 0, durationMs: 1, success: true};
        }),
    } as any,
  );
  return {
    engine,
    flow: flow as unknown as ConfirmFlow,
    client,
    events,
    requests,
    order,
    ctx,
    run: () => engine.run(TASK, 10) as Promise<string>,
  };
}

const FINISH = [T_ANSWER_FINISH];
const ok = (h: Harness): Promise<string> => h.run();

describe("engine gate: classification decides before the executor is touched", () => {
  it("ask + warn arms the flow and an ok answer lets the command run", async () => {
    const h = harness({mode: "ask", responses: [turn(CMD_WARN), ...FINISH]});
    const run = ok(h);
    await settle(() => h.flow.hasPendingConfirm, "the engine armed the confirm wait");
    // The engine armed it - not the test. This is the injection, proven by behaviour.
    expect(h.requests.some((r) => r.startsWith("request:confirm_") && r.endsWith(":warn"))).toBe(true);
    expect(h.flow.pendingConfirmCommand).toBe(CMD_WARN);
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    h.flow.confirmDangerousCommand();
    expect(await run).toBe("success");
    expect(h.requests.filter((r) => r === "exec:" + CMD_WARN).length).toBe(1);
    expect(h.requests.some((r) => r.includes(CHECK) && r.includes(T_CONFIRMED))).toBe(true);
    const result = h.events.find((e) => e.type === "result");
    expect(result.command).toBe(CMD_WARN);
    expect(result.success).toBe(true);
    // A confirmed run hands the model the real output, not a refusal.
    const last = h.client.prompts[h.client.prompts.length - 1];
    expect(last.some((m) => m.content.includes("ran"))).toBe(true);
  });

  it("the gate order is classify -> decide -> execute, in that order", async () => {
    const seen: string[] = [];
    const h = harness({
      mode: "ask",
      responses: [turn(CMD_WARN), ...FINISH],
      safetyCheck: (cmd: string) => { seen.push("classify:" + cmd); return "warn" as any; },
    });
    const run = ok(h);
    await settle(() => h.flow.hasPendingConfirm, "confirm armed after classification");
    // Dart classifies twice for one command: once for the event snapshot (2978),
    // once at the gate. Both reads hit the same pure table, so the double call is
    // parity, not waste - and both happen BEFORE the executor, which is the ordering
    // this test exists to protect.
    // Both classifications (snapshot + gate) have already happened at this point;
    // what must NOT have happened is any executor call while the box was up.
    expect(seen.length).toBe(2);
    expect(seen).toStrictEqual(["classify:" + CMD_WARN, "classify:" + CMD_WARN]);
    expect(h.order).toStrictEqual([]);            // not one executor call yet
    h.flow.confirmDangerousCommand();
    expect(await run).toBe("success");
    expect(seen.length).toBe(2);                  // snapshot + gate, Dart parity
    expect(seen[0]).toBe(seen[1]);                // same command both times
    expect(h.order).toStrictEqual(["exec"]);      // and execution is still last
  });

  it("reject skips the executor entirely and hands the model a refusal observation", async () => {
    const h = harness({mode: "ask", responses: [turn(CMD_WARN), ...FINISH]});
    const run = ok(h);
    await settle(() => h.flow.hasPendingConfirm, "confirm armed");
    h.flow.rejectDangerousCommand();
    expect(await run).toBe("success");
    expect(h.requests.some((r) => r.startsWith("exec:"))).toBe(false);
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    expect(h.requests.some((r) => r.includes(CROSS) && r.includes(T_USER_REJECT))).toBe(true);
    expect(h.requests.some((r) => r.includes(T_TIMEOUT))).toBe(false);
    const last = h.client.prompts[h.client.prompts.length - 1];
    expect(last.some((m) => m.content === formatObservationFailure(CMD_WARN, T_USER_REJECT))).toBe(true);
    expect(h.client.prompts.length).toBe(2);      // the loop kept going after a refusal
  });

  it("timeout is reported as a timeout, never as a user refusal", async () => {
    const h = harness({mode: "ask", responses: [turn(CMD_WARN), ...FINISH]});
    const run = ok(h);
    await settle(() => h.flow.hasPendingConfirm, "confirm armed");
    h.flow.expireConfirmTimeoutForTesting(CMD_WARN);
    expect(await run).toBe("success");
    expect(h.requests.some((r) => r.startsWith("exec:"))).toBe(false);
    expect(h.requests.some((r) => r.includes(HOURGLASS) && r.includes(T_TIMEOUT))).toBe(true);
    const last = h.client.prompts[h.client.prompts.length - 1];
    expect(last.some((m) => m.content.includes(T_TIMEOUT))).toBe(true);
    expect(last.some((m) => m.content.includes(T_USER_REJECT))).toBe(false);
  });

  it("readOnly refuses a warn command with no confirm prompt and no result event", async () => {
    const h = harness({mode: "readOnly", responses: [turn(CMD_WARN), ...FINISH]});
    expect(await ok(h)).toBe("success");
    expect(h.requests.some((r) => r.startsWith("exec:"))).toBe(false);
    expect(h.requests.some((r) => r.startsWith("request:"))).toBe(false);
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    const info = h.events.filter((e) => e.type === "info");
    expect(info.length).toBe(1);
    expect(info[0].text).toBe(
      LOCK + " " + T_READONLY_ON + T_DENIED_SUFFIX + BT + CMD_WARN + BT +
      "\n" + T_LEVEL + "warn\n" + T_REASON + REASON_WARN);
    const last = h.client.prompts[h.client.prompts.length - 1];
    expect(last.some((m) => m.content === formatObservationFailure(CMD_WARN, T_READONLY_BLOCK))).toBe(true);
  });

  it("readOnly still runs a safe command", async () => {
    const h = harness({mode: "readOnly", responses: [turn(CMD_SAFE), ...FINISH]});
    expect(await ok(h)).toBe("success");
    expect(h.requests.filter((r) => r === "exec:" + CMD_SAFE).length).toBe(1);
    expect(h.events.some((e) => e.type === "result")).toBe(true);
  });

  it("ask confirms a blocked command instead of refusing it outright", async () => {
    const h = harness({mode: "ask", responses: [turn(CMD_BLOCKED), ...FINISH]});
    const run = ok(h);
    await settle(() => h.flow.hasPendingConfirm, "blocked confirm armed");
    expect(h.requests.some((r) => r.endsWith(":blocked"))).toBe(true);
    h.flow.confirmDangerousCommand();
    expect(await run).toBe("success");
    expect(h.requests.some((r) => r === "exec:" + CMD_BLOCKED)).toBe(true);
  });

  it("the command event carries the risk/decision snapshot the parent UI renders", async () => {
    // Dart 2971-2983 enriches every command event before onEvent, and
    // agent_command_block.dart branches on permissionDecision: it is a wire contract,
    // not a debug extra. The snapshot is taken at emit time, so it says what the gate
    // was about to do with this very command under the live mode.
    const probe = async (mode: PermissionMode, cmd: string): Promise<any> => {
      const h = harness({mode, responses: [turn(cmd), ...FINISH]});
      const run = ok(h);
      // Whatever the mode decided, the engine has reached a stable point once a
      // confirm is armed, a refusal / execution has happened, or the run ended.
      await settle(() =>
        h.flow.hasPendingConfirm || h.order.length > 0 ||
        h.events.some((e) => e.type === "finish") ||
        h.requests.some((r) => r.startsWith("exec:")), "gate settled");
      // R1: an armed wait must be answered, or the await never returns.
      if (h.flow.hasPendingConfirm) h.flow.confirmDangerousCommand();
      await run;
      const ce = h.events.find((e) => e.type === "command");
      expect(ce).toBeDefined();
      return ce;
    };
    const askWarn = await probe("ask", CMD_WARN);
    expect(askWarn.riskLevel).toBe("warn");
    expect(askWarn.permissionDecision).toBe("confirm");
    expect(askWarn.toolName).toBe("exec_command");
    expect(askWarn.hostId).toBe(TASK.hostId);
    expect((await probe("readOnly", CMD_WARN)).permissionDecision).toBe("reject");
    expect((await probe("fullAuto", CMD_WARN)).permissionDecision).toBe("execute");
    expect((await probe("readOnly", CMD_SAFE)).permissionDecision).toBe("execute");
  });

  it("fullAuto runs warn and blocked with no confirmation at all", async () => {
    for (const cmd of [CMD_WARN, CMD_BLOCKED]) {
      const h = harness({mode: "fullAuto", responses: [turn(cmd), ...FINISH]});
      expect(await ok(h)).toBe("success");
      expect(h.requests.some((r) => r.startsWith("request:"))).toBe(false);
      expect(h.requests.filter((r) => r === "exec:" + cmd).length).toBe(1);
    }
  });

  it("a caller that wires no flow executes the warn command and says so loudly", async () => {
    const writes: string[] = [];
    const original = process.stderr.write.bind(process.stderr);
    (process.stderr as any).write = (chunk: any): boolean => {
      writes.push(String(chunk));
      return true;
    };
    try {
      const h = harness({mode: "ask", responses: [turn(CMD_WARN), ...FINISH], wireFlow: false});
      expect(await ok(h)).toBe("success");
      expect(h.requests.filter((r) => r === "exec:" + CMD_WARN).length).toBe(1);
    } finally {
      (process.stderr as any).write = original;
    }
    const noise = writes.join("");
    expect(noise.includes("[agent-core] gate warn")).toBe(true);
    expect(noise.includes(T_UNWIRED)).toBe(true);
  });
});

describe("engine gate: what crosses the confirm await (R1)", () => {
  it("a supersede during the wait leaves no result, no observation and no finish", async () => {
    const h = harness({mode: "ask", responses: [turn(CMD_WARN), ...FINISH]});
    const run = ok(h);
    await settle(() => h.flow.hasPendingConfirm, "confirm armed");
    const mine = h.ctx.gen;
    h.ctx.gen = mine + 1;                    // a new task bumped the shared counter
    h.flow.wakeForCancelTask();              // woken, never orphaned (R1)
    expect(await run).toBe("interrupted");
    expect(h.requests.some((r) => r.startsWith("exec:"))).toBe(false);
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    expect(h.events.some((e) => e.type === "finish")).toBe(false);
    expect(h.client.prompts.length).toBe(1);  // the loop exited before asking again
  });

  it("cancel during the wait ends the task as cancelled with a finish event", async () => {
    const h = harness({mode: "ask", responses: [turn(CMD_WARN), ...FINISH]});
    const run = ok(h);
    await settle(() => h.flow.hasPendingConfirm, "confirm armed");
    h.engine.cancel();
    expect(await run).toBe("cancelled");
    expect(h.flow.hasPendingConfirm).toBe(false);
    expect(h.requests.some((r) => r.startsWith("exec:"))).toBe(false);
    const finish = h.events.filter((e) => e.type === "finish");
    expect(finish.length).toBe(1);
    expect(finish[0].finishState).toBe("cancelled");
  });

  it("a host that reports cancellation without a bump exits silently", async () => {
    const h = harness({mode: "ask", responses: [turn(CMD_WARN), ...FINISH]});
    const run = ok(h);
    await settle(() => h.flow.hasPendingConfirm, "confirm armed");
    h.ctx.cancelled = true;                  // isCancelled() true, generation unchanged
    h.flow.rejectDangerousCommand();
    expect(await run).toBe("interrupted");
    expect(h.events.some((e) => e.type === "finish")).toBe(false);
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    expect(h.client.prompts.length).toBe(1);
  });

  it("a mode switch during the wait re-decides and refuses a confirmed command", async () => {
    const h = harness({mode: "ask", responses: [turn(CMD_WARN), ...FINISH]});
    const run = ok(h);
    await settle(() => h.flow.hasPendingConfirm, "confirm armed");
    h.ctx.mode = "readOnly";                 // the user moved the dial while the box was up
    h.flow.confirmDangerousCommand();        // and still pressed ok
    expect(await run).toBe("success");
    expect(h.requests.some((r) => r.startsWith("exec:"))).toBe(false);
    expect(h.events.some((e) => e.type === "result")).toBe(false);
    const last = h.client.prompts[h.client.prompts.length - 1];
    expect(last.some((m) => m.content.includes(T_MODE_SWITCH))).toBe(true);
    expect(h.client.prompts.length).toBe(2);  // the loop continued, the run is not dead
  });
});

describe("engine gate: the reason codes the gate can hand back", () => {
  it("the flow names every reason the gate distinguishes", () => {
    // Pinned as constants because the parent logs them: a rename is a wire change.
    expect(CONFIRM_REASON_GENERATION_INVALID).toBe("generation_invalid_during_confirm");
    expect(CONFIRM_REASON_CANCELLED).toBe("cancelled_during_confirm");
    expect(CONFIRM_REASON_TIMEOUT).toBe("confirm_timeout");
    expect(CONFIRM_REASON_USER_REJECTED).toBe("user_rejected");
    expect(CONFIRM_REASON_PERMISSION_CHANGED).toBe("permission_changed_during_confirm");
  });
});

// --- the same gate over the wire (rpc:startTask -> gate -> rpc:confirm) ---
// rpc_confirm.test.ts arms the flow BY HAND and only checks the answer path.
// These tests never arm anything: if the engine had not been injected with the
// server flow, no evt:confirmRequest would ever leave the process, and these fail.
const openaiMc = {provider: "openai" as const, model: "x", apiKey: "k"};

function wire(responses: string[]): {
  start: (p: any) => Promise<any>;
  cancel: (p: any) => Promise<any>;
  confirm: (p: any) => Promise<any>;
  notifications: Array<{method: string; params: any}>;
} {
  const server = startServer({verbose: false, llmFactory: () => ({
    name: "wire-mock",
    async chatStream(_opts: LlmResponseOptions): Promise<LlmResult> {
      await new Promise((r) => setTimeout(r, 2));
      const text = responses.shift() ?? "";
      return {text, reasoning: ""};
    },
  } as LlmClient)} as any);
  const handlers = (server as any).handlers as Map<string, any>;
  const notifications: Array<{method: string; params: any}> = [];
  server.notify = (method: string, params: Record<string, unknown>) => {
    notifications.push({method, params});
  };
  return {
    start: handlers.get("rpc:startTask")!,
    cancel: handlers.get("rpc:cancelTask")!,
    confirm: handlers.get("rpc:confirm")!,
    notifications,
  };
}

const SCRATCH = "rm -rf ./confirm-gate-scratch-does-not-exist";  // warn shape, nothing to delete

function agentEvents(w: {notifications: Array<{method: string; params: any}>}): any[] {
  return w.notifications.filter((x) => x.method === "evt:agentEvent").map((x) => x.params.event);
}

describe("rpc e2e: the engine arms the confirmation the parent answers", () => {
  it("ask + warn: engine-armed evt:confirmRequest, then rpc:confirm ok runs it", async () => {
    const w = wire([turn(SCRATCH), T_ANSWER_FINISH]);
    const r = await w.start({taskId: "g-ok", goal: "g", hostId: "h", modelConfig: openaiMc,
      maxSteps: 10, permissionMode: "ask"} as any);
    expect(r.ok).toBe(true);
    const flow = confirmFlowForTesting()!;
    await settle(() => flow.hasPendingConfirm, "the engine armed the server flow");
    const req = w.notifications.filter((x) => x.method === "evt:confirmRequest");
    expect(req.length).toBe(1);
    expect(req[0].params.taskId).toBe("g-ok");
    expect(req[0].params.riskLevel).toBe("warn");
    expect(req[0].params.confirmId).toBe(flow.pendingConfirmId);
    expect(w.notifications.some((x) => x.method === "evt:taskState" && x.params.state === "waiting_confirm")).toBe(true);
    // The snapshot rides out over the wire too (Dart 1897-1904 enrichment): the parent
    // renders the card from these fields and must not re-derive them itself.
    const cmdEvt = agentEvents(w).find((e) => e.type === "command");
    expect(cmdEvt.command).toBe(SCRATCH);
    expect(cmdEvt.riskLevel).toBe("warn");
    expect(cmdEvt.permissionDecision).toBe("confirm");
    expect(cmdEvt.toolName).toBe("exec_command");

    const c = await w.confirm({taskId: "g-ok", confirmId: flow.pendingConfirmId, decision: "ok"} as any);
    expect(c.ok).toBe(true);
    await settle(() => agentEvents(w).some((e) => e.type === "finish"), "the task finished");
    expect(agentEvents(w).some((e) => e.type === "result")).toBe(true);   // the gate let it through
    await w.cancel({} as any);
  });

  it("ask + warn: rpc:confirm reject yields no result event and the refusal is visible", async () => {
    const w = wire([turn(SCRATCH), T_ANSWER_FINISH]);
    await w.start({taskId: "g-no", goal: "g", hostId: "h", modelConfig: openaiMc,
      maxSteps: 10, permissionMode: "ask"} as any);
    const flow = confirmFlowForTesting()!;
    await settle(() => flow.hasPendingConfirm, "confirm armed");
    const c = await w.confirm({taskId: "g-no", confirmId: flow.pendingConfirmId, decision: "reject"} as any);
    expect(c.ok).toBe(true);
    await settle(() => agentEvents(w).some((e) => e.type === "finish"), "the task finished");
    expect(agentEvents(w).some((e) => e.type === "result")).toBe(false);
    expect(agentEvents(w).some((e) => e.type === "info" && String(e.text).includes(T_USER_REJECT))).toBe(true);
    const finish = agentEvents(w).filter((e) => e.type === "finish");
    expect(finish.length).toBe(1);
    // The parsed finish turn ends the task; its terminal state reaches the parent as
    // evt:taskState (doc sec. 2.4). The parsed finish event carries no state field -
    // the engine deliberately does not re-emit one (Dart parity, engine.ts:270).
    const doneStates = w.notifications.filter((x) => x.method === "evt:taskState").map((x) => x.params.state);
    expect(doneStates[doneStates.length - 1]).toBe("success");
    await w.cancel({} as any);
  });

  it("readOnly refuses without ever asking - the mode reached the engine gate", async () => {
    const w = wire([turn(SCRATCH), T_ANSWER_FINISH]);
    await w.start({taskId: "g-ro", goal: "g", hostId: "h", modelConfig: openaiMc,
      maxSteps: 10, permissionMode: "readOnly"} as any);
    await settle(() => agentEvents(w).some((e) => e.type === "finish"), "the task finished");
    // Under the old "ask" default this command would have raised a confirm prompt.
    expect(w.notifications.filter((x) => x.method === "evt:confirmRequest").length).toBe(0);
    expect(confirmFlowForTesting()!.hasPendingConfirm).toBe(false);
    expect(agentEvents(w).some((e) => e.type === "result")).toBe(false);
    const info = agentEvents(w).filter((e) => e.type === "info" && String(e.text).startsWith(LOCK));
    expect(info.length).toBe(1);
    expect(String(info[0].text).includes(T_READONLY_ON)).toBe(true);
    expect(String(info[0].text).includes(T_LEVEL + "warn")).toBe(true);
    await w.cancel({} as any);
  });

  it("fullAuto never asks and produces a result event", async () => {
    const w = wire([turn(SCRATCH), T_ANSWER_FINISH]);
    await w.start({taskId: "g-fa", goal: "g", hostId: "h", modelConfig: openaiMc,
      maxSteps: 10, permissionMode: "fullAuto"} as any);
    await settle(() => agentEvents(w).some((e) => e.type === "finish"), "the task finished");
    expect(w.notifications.filter((x) => x.method === "evt:confirmRequest").length).toBe(0);
    expect(agentEvents(w).some((e) => e.type === "result")).toBe(true);
    await w.cancel({} as any);
  });

  it("rpc:cancelTask wakes the engine-armed wait instead of hanging the handler", async () => {
    const w = wire([turn(SCRATCH), T_ANSWER_FINISH]);
    await w.start({taskId: "g-cancel", goal: "g", hostId: "h", modelConfig: openaiMc,
      maxSteps: 10, permissionMode: "ask"} as any);
    const flow = confirmFlowForTesting()!;
    await settle(() => flow.hasPendingConfirm, "confirm armed");
    const awaited = flow.pendingConfirmForTesting!;
    const cr = await w.cancel({} as any);        // resolves: the awaiter was woken (R1)
    expect(cr.ok).toBe(true);
    expect(await awaited.promise).toBe(false);
    expect(flow.hasPendingConfirm).toBe(false);
    expect(agentEvents(w).some((e) => e.type === "result")).toBe(false);
    const states = w.notifications.filter((x) => x.method === "evt:taskState").map((x) => x.params.state);
    expect(states).toContain("waiting_confirm");
    // engine.cancel() -> boundary() -> emitFinish("cancelled") -> onFinished, so the
    // terminal notification the parent sees is "cancelled", not the housekeeping
    // "idle" that rpc:cancelTask only writes into its own taskState record.
    expect(states[states.length - 1]).toBe("cancelled");
  });
});




