// rpc:confirm (doc §2.2 method, §9 item 6) - the wire-level confirm round-trip.
// The Dart UI calls the engine in-process, so no Dart test can cover this
// surface; the Node design turns the same state machine into three messages
// (evt:confirmRequest out, rpc:confirm in, the completer woken underneath).
// Driven through startServer's registered handlers like rpc_start_task.test.ts,
// with server.notify stubbed so the outgoing notifications are capturable.
import {describe, it, expect, afterEach} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {startServer, confirmFlowForTesting, CONFIRM_TIMEOUT_MS, ConfirmFlow} from "../src/index.js";
import {MockLlmClient, LlmClient, LlmResult, LlmResponseOptions} from "../src/llm/clients.js";

class SlowMockLlmClient implements LlmClient {
  name = "slow-mock";
  private responses: string[];
  private delayMs: number;
  constructor(responses: string[], delayMs = 20) { this.responses = responses; this.delayMs = delayMs; }
  async chatStream(_opts: LlmResponseOptions): Promise<LlmResult> {
    await new Promise((r) => setTimeout(r, this.delayMs));
    const text = this.responses.shift() ?? "";
    return {text, reasoning: ""} as LlmResult;
  }
}

type Cap = {notifications: Array<{jsonrpc: string; method: string; params: any}>};

function wire(llm: LlmClient): {
  start: (p: any) => Promise<any>;
  cancel: (p: any) => Promise<any>;
  confirm: (p: any) => Promise<any>;
  getState: (p: any) => Promise<any>;
  cap: Cap;
} {
  const server = startServer({verbose: false, llmFactory: () => llm} as any);
  const handlers = (server as any).handlers as Map<string, any>;
  const cap: Cap = {notifications: []};
  server.notify = (method: string, params: Record<string, unknown>) => {
    cap.notifications.push({jsonrpc: "2.0", method, params});
  };
  return {
    start: handlers.get("rpc:startTask")!,
    cancel: handlers.get("rpc:cancelTask")!,
    confirm: handlers.get("rpc:confirm")!,
    getState: handlers.get("rpc:getState")!,
    cap,
  };
}

const openaiMc = {provider: "openai" as const, model: "x", apiKey: "k"};

/** The flow lives in module scope and is rebuilt by every startServer, so it is
 * fetched after wire() and always refers to the most recent server. Handlers from an
 * older server would dispatch into this same instance - one flow per process, which
 * is exactly Dart's single _confirmCompleter invariant. */
function flow(): ConfirmFlow {
  const f = confirmFlowForTesting();
  if (f === null) throw new Error("startServer did not build the confirm flow");
  return f;
}

function arm(cmd: string, level: "warn" | "blocked" = "warn"): string {
  return flow().beginDangerousCommand(cmd, level).confirmId;
}

function okOf(res: unknown): {confirmId: string; woken: boolean} {
  const r = res as {ok: unknown; confirmId?: unknown; woken?: unknown};
  if (r.ok !== true) throw new Error("expected an ok confirm result, got " + JSON.stringify(res));
  return {confirmId: String(r.confirmId), woken: Boolean(r.woken)};
}

function errOf(res: unknown): {error: string; confirmId: string | null} {
  const r = res as {ok: unknown; error?: unknown; confirmId?: unknown};
  if (r.ok !== false) throw new Error("expected a failed confirm result, got " + JSON.stringify(res));
  return {error: String(r.error), confirmId: (r.confirmId ?? null) as string | null};
}

const CMD = "rm -rf ./build-cache";

afterEach(() => {
  // One pending confirm per process: never leak a waiter into the next test,
  // and never leak a resolved-but-unchecked timer either (R2).
  flow().wakeForCancelTask();
  flow().resetConfirmWaitSeconds();
  flow().resetTaskHadConfirmTimeout();
});

describe("rpc:confirm - outgoing confirm request (doc §2.2 evt:confirmRequest)", () => {
  it("arming a dangerous command emits evt:confirmRequest + waiting_confirm + info", async () => {
    const {start, cancel, cap} = wire(new SlowMockLlmClient(Array(200).fill("命令: echo x"), 20));
    const r = await start({taskId: "t-arm", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 200, permissionMode: "ask"} as any);
    expect(r.ok).toBe(true);
    const id = arm(CMD);

    const req = cap.notifications.filter((n) => n.method === "evt:confirmRequest");
    expect(req.length).toBe(1);
    expect(req[0].params.confirmId).toBe(id);
    expect(req[0].params.taskId).toBe("t-arm");
    expect(req[0].params.timeoutMs).toBe(CONFIRM_TIMEOUT_MS);
    expect(req[0].params.riskLevel).toBe("warn");

    // warn + ask 是"高风险命令 / 询问模式"，不是"高危命令"
    const prompt = String(req[0].params.prompt);
    expect(prompt.startsWith("\u26a0\ufe0f 高风险命令需要确认（询问模式）")).toBe(true);
    expect(prompt.includes("风险说明: ")).toBe(true);
    expect(prompt.includes(CMD)).toBe(true);

    const st = cap.notifications.filter((n) => n.method === "evt:taskState");
    expect(st.some((n) => n.params.state === "waiting_confirm" && n.params.taskId === "t-arm")).toBe(true);

    const infos = cap.notifications
      .filter((n) => n.method === "evt:agentEvent")
      .map((n) => n.params.event as {type: string; text?: string; id?: string});
    const info = infos.filter((e) => e.type === "info");
    expect(info.length).toBeGreaterThanOrEqual(1);
    expect(String(info[0].text).includes("需要确认")).toBe(true);
    // info events are addressable: the parent dedups by id, so each needs one.
    expect(typeof info[0].id).toBe("string");
    expect(String(info[0].id).startsWith("confirm-info-")).toBe(true);

    await cancel({} as any);
    expect(flow().hasPendingConfirm).toBe(false);
  });

  it("a blocked command is labelled 高危命令 in the prompt", async () => {
    const {cancel, cap} = wire(new MockLlmClient(["动作: finish"]));
    const id = arm("rm -rf /", "blocked");
    const req = cap.notifications.filter((n) => n.method === "evt:confirmRequest");
    expect(req[0].params.confirmId).toBe(id);
    expect(req[0].params.riskLevel).toBe("blocked");
    expect(String(req[0].params.prompt).startsWith("\u26d4 高危命令需要确认")).toBe(true);
    await cancel({} as any);
  });
});

describe("rpc:confirm - the three decisions", () => {
  it("ok wakes the awaiter with true and clears the pending state", async () => {
    const {confirm} = wire(new MockLlmClient(["动作: finish"]));
    const f = flow();
    const id = arm(CMD);
    const pending = f.pendingConfirmForTesting!;
    expect(f.hasPendingConfirm).toBe(true);

    const res = okOf(await confirm({taskId: null, confirmId: id, decision: "ok"} as any));
    expect(res.confirmId).toBe(id);
    expect(res.woken).toBe(true);
    // R1: the waiter is woken, not dropped - isDone plus the value prove it.
    expect(pending.isDone).toBe(true);
    expect(await pending.promise).toBe(true);
    expect(f.hasPendingConfirm).toBe(false);
    expect(f.pendingConfirmCommand).toBe(null);
    expect(f.confirmTimedOut).toBe(false);
  });

  it("reject wakes the awaiter with false", async () => {
    const {confirm} = wire(new MockLlmClient(["动作: finish"]));
    const f = flow();
    const id = arm(CMD);
    const pending = f.pendingConfirmForTesting!;
    const res = okOf(await confirm({confirmId: id, decision: "reject"} as any));
    expect(res.woken).toBe(true);
    expect(await pending.promise).toBe(false);
    expect(f.confirmTimedOut).toBe(false);
  });

  it("timeout collapses the wait as a timeout, not a user refusal", async () => {
    const {confirm} = wire(new MockLlmClient(["动作: finish"]));
    const f = flow();
    const id = arm(CMD);
    const pending = f.pendingConfirmForTesting!;
    expect(f.taskHadConfirmTimeout).toBe(false);
    const res = okOf(await confirm({confirmId: id, decision: "timeout"} as any));
    expect(res.woken).toBe(true);
    expect(await pending.promise).toBe(false);
    // The wire timeout reuses the same closing logic as the 10-minute timer.
    expect(f.confirmTimedOut).toBe(true);
    expect(f.taskHadConfirmTimeout).toBe(true);
  });

  it("woken is false when the wait had already been resolved", async () => {
    const {confirm} = wire(new MockLlmClient(["动作: finish"]));
    const id = arm(CMD);
    flow().confirmDangerousCommand();
    const second = await confirm({confirmId: id, decision: "ok"} as any);
    // The id survives the wake-up only until teardown; here the completer is still
    // pending-id-wise, so the second call must report woken=false rather than lie.
    if (second.ok === true) {
      expect(second.woken).toBe(false);
    } else {
      expect(errOf(second).error).toBe("no_pending_confirm");
    }
  });
});

describe("rpc:confirm - rejected requests leave the pending wait alone", () => {
  it("an unknown decision is refused with invalid_decision", async () => {
    const {confirm} = wire(new MockLlmClient(["动作: finish"]));
    const id = arm(CMD);
    const res = errOf(await confirm({confirmId: id, decision: "yolo"} as any));
    expect(res.error).toBe("invalid_decision: yolo");
    expect(res.confirmId).toBe(id);
    expect(flow().hasPendingConfirm).toBe(true);
  });

  it("no pending confirm is refused, and answers nothing else", async () => {
    const {confirm} = wire(new MockLlmClient(["动作: finish"]));
    const res = errOf(await confirm({confirmId: "confirm_none", decision: "ok"} as any));
    expect(res.error).toBe("no_pending_confirm");
    expect(res.confirmId).toBe("confirm_none");
  });

  it("a stale confirmId cannot answer a newer wait", async () => {
    const {confirm} = wire(new MockLlmClient(["动作: finish"]));
    const f = flow();
    const first = arm("rm -rf ./one");
    await confirm({confirmId: first, decision: "reject"} as any);
    const second = arm("rm -rf ./two");
    const res = errOf(await confirm({confirmId: first, decision: "ok"} as any));
    expect(res.error.startsWith("confirm_id_mismatch")).toBe(true);
    expect(res.error.includes(second)).toBe(true);
    expect(res.confirmId).toBe(first);
    // The live wait is untouched and still answerable by its own id.
    expect(f.hasPendingConfirm).toBe(true);
    expect(okOf(await confirm({confirmId: second, decision: "reject"} as any)).woken).toBe(true);
  });

  it("a taskId that does not own the running task cannot answer for it", async () => {
    const {start, cancel, confirm} = wire(new SlowMockLlmClient(Array(200).fill("命令: echo x"), 20));
    const f = flow();
    await start({taskId: "t-own", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 200, permissionMode: "ask"} as any);
    const id = arm(CMD);
    const res = errOf(await confirm({taskId: "t-other", confirmId: id, decision: "ok"} as any));
    expect(res.error.startsWith("task_id_mismatch")).toBe(true);
    expect(res.error.includes("t-own")).toBe(true);
    expect(f.hasPendingConfirm).toBe(true);
    // Absent taskId is allowed: the wire marks it optional in practice for a parent
    // that only ever has one task in flight.
    expect(okOf(await confirm({confirmId: id, decision: "reject"} as any)).woken).toBe(true);
    await cancel({} as any);
  });

  it("confirm_flow_unavailable is a defensive guard, unreachable from a live server", () => {
    // Every rpc:confirm handler is registered after the flow is built, so a parent
    // can never observe this branch; it exists for a future teardown path. Pinned
    // statically so it is not silently deleted while the branch stays untested.
    const src = readFileSync(fileURLToPath(new URL("../src/index.ts", import.meta.url)), "utf-8");
    const at = src.indexOf("confirm_flow_unavailable");
    expect(at).toBeGreaterThan(-1);
    const before = src.slice(Math.max(0, at - 240), at);
    expect(before.includes("confirmFlow")).toBe(true);
    expect(before.includes("null")).toBe(true);
  });
});

describe("rpc:confirm - R1 wake paths on the wire", () => {
  it("cancelTask wakes a pending confirm instead of dropping it", async () => {
    const {start, cancel, getState} = wire(new SlowMockLlmClient(Array(200).fill("命令: echo x"), 20));
    const f = flow();
    await start({taskId: "t-wk", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 200, permissionMode: "ask"} as any);
    const id = arm(CMD);
    const pending = f.pendingConfirmForTesting!;
    expect(f.pendingConfirmId).toBe(id);

    const cr = await cancel({} as any);
    expect(cr.ok).toBe(true);
    // hasPendingConfirm going false cannot tell "woken" from "dropped"; the
    // captured awaiter can, and this is the whole R1 point.
    expect(pending.isDone).toBe(true);
    expect(await pending.promise).toBe(false);
    expect(f.hasPendingConfirm).toBe(false);
    expect(f.pendingConfirmId).toBe(null);
    expect((await getState({} as any)).status).toBe("idle");
  });

  it("a new startTask clears a stale wait and the per-task counters (Dart 784/789)", async () => {
    const {start, cancel, confirm} = wire(new SlowMockLlmClient(Array(200).fill("命令: echo x"), 20));
    const f = flow();
    const id = arm(CMD);
    const stale = f.pendingConfirmForTesting!;
    okOf(await confirm({confirmId: id, decision: "timeout"} as any));
    expect(f.taskHadConfirmTimeout).toBe(true);

    const r = await start({taskId: "t-fresh", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 200, permissionMode: "fullAuto"} as any);
    expect(r.ok).toBe(true);
    // R1: the leftover wait is woken, not dropped, when a task boundary crosses it.
    expect(stale.isDone).toBe(true);
    expect(await stale.promise).toBe(false);
    // Dart 784 / 789: wait seconds and the sticky timeout flag are per task.
    expect(f.confirmWaitSeconds).toBe(0);
    expect(f.taskHadConfirmTimeout).toBe(false);
    expect(f.hasPendingConfirm).toBe(false);
    await cancel({} as any);
    expect(f.hasPendingConfirm).toBe(false);
  });

  it("fullAuto does not disarm the flow: an armed wait still answers on the wire", async () => {
    const {start, cancel, confirm} = wire(new SlowMockLlmClient(Array(200).fill("命令: echo x"), 20));
    const f = flow();
    await start({taskId: "t-fa", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 200, permissionMode: "fullAuto"} as any);
    const id = arm(CMD);
    expect(okOf(await confirm({confirmId: id, decision: "ok"} as any)).woken).toBe(true);
    await cancel({} as any);
  });
});

