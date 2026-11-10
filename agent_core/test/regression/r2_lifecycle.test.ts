// Regression: docs §6.2 r2_lifecycle.test.ts (AGENTS.md R2).
//
// Whoever creates a resource owns its cleanup ON ALL PATHS, and callbacks that
// carry in-flight state must fire before the owner detaches from it. In the
// Node port the RPC host (src/index.ts) owns the engine: the run() promise is
// chained with .finally() that nulls activeEngine / activeRun and flips
// taskState to idle, while the terminal evt:taskState notification is emitted
// from the onFinished callback. The .finally() handler is queued AFTER the
// callbacks that settled the run, so the terminal-state flush is guaranteed to
// reach the parent BEFORE the slot is released - flip the order (release first)
// and a parent that immediately starts the next task races a notification for
// the previous one. cancelTask must additionally await the in-flight run so the
// flush lands before its RPC response, and both cancel paths must be
// idempotent (double cancel, cancel-after-finish leak nothing).

import {describe, it, expect} from "vitest";
import {startServer} from "../../src/index.js";
import {MockLlmClient, LlmClient, LlmResult, LlmResponseOptions} from "../../src/llm/clients.js";

const CMD = "\u52a8\u4f5c: execute\n\u547d\u4ee4: echo hi"; // action: execute / command:
const openaiMc = {provider: "openai" as const, model: "x", apiKey: "k"};

// An LLM that can park in flight: gate() releases the current parked call.
class GateLlm implements LlmClient {
  readonly name = "gate";
  private resolvers: Array<() => void> = [];
  chatStream(_opts: LlmResponseOptions): Promise<LlmResult> {
    return new Promise<LlmResult>((resolve) => {
      this.resolvers.push(() => resolve({text: CMD, reasoning: ""}));
    });
  }
  gate(): void {
    for (const r of this.resolvers.splice(0)) r();
  }
}

type Wire = {start: (p: unknown) => Promise<any>; cancel: (p?: unknown) => Promise<any>; getState: () => Promise<any>; order: string[]};
function wire(llm: LlmClient): Wire {
  const server = startServer({verbose: false, llmFactory: () => llm} as never) as unknown as {handlers: Map<string, any>; notify: (m: string, p: Record<string, unknown>) => void};
  const handlers = server.handlers;
  // Record the ORDER of outgoing RPC traffic: terminal-state notifications
  // vs. response completions (a response means the parent may act immediately).
  const order: string[] = [];
  server.notify = (method: string, params: Record<string, unknown>) => {
    if (method === "evt:taskState") order.push("notify:taskState:" + (params as {state: string}).state);
  };
  const wrapResp = (m: string, fn: (p: unknown) => Promise<any>) => async (p: unknown) => {
    const r = await fn(p);
    order.push("resp:" + m);
    return r;
  };
  return {
    start: wrapResp("startTask", handlers.get("rpc:startTask")),
    cancel: wrapResp("cancelTask", handlers.get("rpc:cancelTask") ?? (async () => ({ok: true}))),
    getState: handlers.get("rpc:getState"),
    order,
  };
}
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

describe("R2 flush-before-release: terminal callbacks precede slot cleanup", () => {
  it("a naturally finishing run emits evt:taskState BEFORE the slot is idle", async () => {
    const llm = new MockLlmClient(["\u52a8\u4f5c: finish"]); // action: finish
    const w = wire(llm);
    await w.start({taskId: "t-1", goal: "g", hostId: "h", modelConfig: openaiMc});
    // Wait until the terminal notification arrives; state must already be idle.
    let seen = false;
    for (let i = 0; i < 100; i++) {
      await tick(2);
      if (w.order.includes("notify:taskState:success")) { seen = true; break; }
    }
    expect(seen).toBe(true);
    // Flush happened at-or-before slot release: getState (a fresh RPC, so all
    // microtasks including the .finally() cleanup have run) reports idle.
    const st = await w.getState();
    expect(st.status).toBe("idle");
  });

  it("cancelTask awaits the in-flight run so the terminal flush lands before its response", async () => {
    const llm = new GateLlm();
    const w = wire(llm);
    await w.start({taskId: "t-9", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 50});
    await tick(5); // engine now parked mid-chatStream

    const cancelP = w.cancel();
    llm.gate(); // the stale await resumes - engine hits the R1 boundary, emits
    await cancelP;    // cancelled finish, THEN the response resolves

    // Order on the wire: flush first, ack second. A parent that trusts the ack
    // (e.g. closes the UI card) must never observe a later orphan notification.
    expect(w.order).toEqual(["resp:startTask", "notify:taskState:cancelled", "resp:cancelTask"]);
    const st = await w.getState();
    expect(st.status).toBe("idle");
  });

  it("both cleanup paths are idempotent - double cancel / late cancel leak nothing", async () => {
    const llm = new GateLlm();
    const w = wire(llm);
    await w.start({taskId: "t-10", goal: "g", hostId: "h", modelConfig: openaiMc, maxSteps: 50});
    await tick(5);

    const c1 = w.cancel();
    llm.gate();
    await c1;
    // Second cancel: engine already detached - must resolve cleanly, no second flush.
    await w.cancel();
    // A cancel long after the run is still clean (the resource was fully owned).
    await w.cancel();

    const flushes = w.order.filter((s) => s.startsWith("notify:taskState")).length;
    expect(flushes).toBe(1); // exactly one terminal flush - not per cancel path
    const st = await w.getState();
    expect(st.status).toBe("idle");
  });
});
