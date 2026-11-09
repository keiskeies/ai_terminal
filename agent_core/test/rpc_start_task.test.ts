// rpc:startTask / rpc:cancelTask / rpc:getState — RPC-surface e2e (doc §2.2).
// Drives startServer's registered handlers via the internal handlers Map
// (same pattern as health.test.ts), injecting a MockLlmClient through
// opts.llmFactory so no live LLM endpoint is required.
import {describe, it, expect} from "vitest";
import {startServer} from "../src/index.js";
import {MockLlmClient, LlmClient, LlmResult, LlmResponseOptions} from "../src/llm/clients.js";

// A mock LLM that delays each response by `delayMs` so the engine is
// deterministically mid-run when the test issues a cancel.
class SlowMockLlmClient implements LlmClient {
  name = "slow-mock";
  private responses: string[];
  private delayMs: number;
  constructor(responses: string[], delayMs = 50) { this.responses = responses; this.delayMs = delayMs; }
  async chatStream(_opts: LlmResponseOptions): Promise<LlmResult> {
    await new Promise((r) => setTimeout(r, this.delayMs));
    const text = this.responses.shift() ?? "";
    return {text, reasoning: ""} as LlmResult;
  }
}

function wire(llm: LlmClient): {start: any, cancel: any, getState: any, cap: {notifications: any[], responses: any[]}} {
  const server = startServer({verbose: false, llmFactory: () => llm} as any);
  const handlers = (server as any).handlers as Map<string, any>;
  const cap = {notifications: [] as any[], responses: [] as any[]};
  // Stub RpcServer.notify to capture outgoing notifications (StdioChildTransport
  // would write to real stdout).
  server.notify = (method: string, params: Record<string, unknown>) => {
    cap.notifications.push({jsonrpc: "2.0", method, params});
  };
  return {
    start: handlers.get("rpc:startTask")!,
    cancel: handlers.get("rpc:cancelTask")!,
    getState: handlers.get("rpc:getState")!,
    cap,
  };
}

const openaiMc = {provider: "openai" as const, model: "x", apiKey: "k"};

describe("rpc:startTask (doc §2.2 task-launch over RPC surface)", () => {
  it("emits evt:agentEvent + terminal evt:taskState=success on finish", async () => {
    const llm = new MockLlmClient(["动作: finish"]);
    const {start, cap} = wire(llm);
    const res = await start({taskId: "t-1", goal: "g", hostId: "h", modelConfig: openaiMc} as any);
    expect(res.ok).toBe(true);
    expect(res.runId).toBe("t-1");
    // MockLlmClient resolves instantly — poll until the taskState notification arrives.
    for (let i = 0; i < 50 && !cap.notifications.some((n: any) => n.method === "evt:taskState"); i++) {
      await new Promise((r) => setTimeout(r, 5));
    }
    const ts = cap.notifications.filter((n: any) => n.method === "evt:taskState");
    expect(ts.length).toBe(1);
    expect(ts[0].params.state).toBe("success");
    expect(ts[0].params.taskId).toBe("t-1");
    const evts = cap.notifications.filter((n: any) => n.method === "evt:agentEvent");
    expect(evts.length).toBeGreaterThanOrEqual(1);
  });

  it("rejects a concurrent startTask while one is running", async () => {
    const llm = new SlowMockLlmClient(Array(200).fill("命令: echo running"), 20);
    const {start, cap} = wire(llm);
    const r1 = await start({taskId: "t-a", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 50} as any);
    expect(r1.ok).toBe(true);
    // While the first task is running, a second startTask must be rejected.
    const r2 = await start({taskId: "t-b", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 50} as any);
    expect(r2.ok).toBe(false);
    expect(r2.error).toBe("task_running");
    expect(r2.runningTaskId).toBe("t-a");
    // Clean up: wait for the running task to finish (200 steps × 20ms = ~4s; cap at 30 steps).
    // Instead just cancel so the test is fast.
    await new Promise((r) => setTimeout(r, 100));
    const {cancel} = wire(llm);
    await cancel({} as any);
    for (let i = 0; i < 50; i++) {
      await new Promise((r) => setTimeout(r, 5));
    }
  });

  it("cancelTask emits terminal evt:taskState=cancelled (R5)", async () => {
    // Slow LLM ensures the engine is mid-run when cancel lands.
    const llm = new SlowMockLlmClient(Array(200).fill("命令: echo running"), 30);
    const {start, cancel, getState, cap} = wire(llm);
    const r = await start({taskId: "t-c", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 200} as any);
    expect(r.ok).toBe(true);
    // Give the engine a few steps so it is definitely mid-run.
    await new Promise((r) => setTimeout(r, 100));
    const cr = await cancel({} as any);
    expect(cr.ok).toBe(true);
    const ts = cap.notifications.filter((n: any) => n.method === "evt:taskState");
    expect(ts.length).toBe(1);
    expect(ts[0].params.state).toBe("cancelled");
    expect(ts[0].params.taskId).toBe("t-c");
    // After cancel, getState is idle.
    const gs = await getState({} as any);
    expect(gs.status).toBe("idle");
  });

  it("getState reflects running then idle (doc §2.2 getState contract)", async () => {
    const llm = new SlowMockLlmClient(Array(200).fill("命令: echo running"), 20);
    const {start, cancel, getState} = wire(llm);
    const r0 = await getState({} as any);
    expect(r0.status).toBe("idle");
    await start({taskId: "t-g", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 200} as any);
    const r1 = await getState({} as any);
    expect(r1.status).toBe("running");
    expect(r1.taskId).toBe("t-g");
    await cancel({} as any);
    const r2 = await getState({} as any);
    expect(r2.status).toBe("idle");
  });
});
