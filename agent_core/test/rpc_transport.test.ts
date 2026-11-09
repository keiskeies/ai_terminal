// Hermetic tests for rpc/transport.ts (StdioChildTransport lifecycle) +
// rpc/server.ts (RpcServer routing: unknown_method + error-notification path).
// No real stdio process: the transport is exercised through its public API,
// and the server through an in-memory fake transport that records traffic.

import {describe, it, expect} from "vitest";
import {StdioChildTransport} from "../src/rpc/transport.js";
import type {RpcTransport} from "../src/rpc/transport.js";
import {JsonRpcRequest, JsonRpcResponse, JsonRpcNotification} from "../src/rpc/schema.js";
import {RpcServer} from "../src/rpc/server.js";

// ── StdioChildTransport lifecycle ─────────────────────────────────────────

describe("StdioChildTransport", () => {
  it("closed is false before close() and true after", () => {
    const t = new StdioChildTransport();
    expect(t.closed).toBe(false);
    t.close();
    expect(t.closed).toBe(true);
  });

  it("close() is idempotent (calling it twice does not throw)", () => {
    const t = new StdioChildTransport();
    t.close();
    expect(() => t.close()).not.toThrow();
    expect(t.closed).toBe(true);
  });

  it("request() after close() rejects with transport-closed error (no stdout write)", async () => {
    const t = new StdioChildTransport();
    t.close();
    const req: JsonRpcRequest = {jsonrpc: "2.0", id: "r1", method: "rpc:health"};
    await expect(t.request(req)).rejects.toThrow("transport closed");
  });

  it("notify() after close() is a no-op (no throw, no stdout write)", () => {
    const t = new StdioChildTransport();
    t.close();
    // Must not throw even though the guard returns early.
    expect(() => t.notify({jsonrpc: "2.0", method: "ev:ok", params: {}})).not.toThrow();
  });

  it("respond()/reject() after close() are no-ops (no throw)", () => {
    const t = new StdioChildTransport();
    t.close();
    expect(() => t.respond("id1", {ok: true})).not.toThrow();
    expect(() => t.reject("id1", -32000, "boom")).not.toThrow();
  });
});

// ── In-memory fake RpcTransport (records outgoing frames, replays incoming) ──

class InMemoryTransport implements RpcTransport {
  readonly sentResponses: JsonRpcResponse[] = [];
  readonly sentNotifications: JsonRpcNotification[] = [];
  private reqHandlers: Array<(r: JsonRpcRequest) => void> = [];
  private notifHandlers: Array<(n: JsonRpcNotification) => void> = [];
  private _closed = false;

  // Replay an incoming request to every registered onRequest handler.
  deliver(req: JsonRpcRequest): void {
    for (const h of this.reqHandlers) h(req);
  }
  deliverNotif(n: JsonRpcNotification): void {
    for (const h of this.notifHandlers) h(n);
  }

  request<T>(_msg: JsonRpcRequest): Promise<T> {
    return this._closed ? Promise.reject(new Error("transport closed")) : Promise.resolve(undefined as T);
  }
  notify(msg: JsonRpcNotification): void { if (!this._closed) this.sentNotifications.push(msg); }
  respond(id: string, result: unknown): void { if (!this._closed) this.sentResponses.push({jsonrpc: "2.0", id, result}); }
  reject(id: string, code: number, message: string, data?: unknown): void {
    if (!this._closed) this.sentResponses.push({jsonrpc: "2.0", id, error: {code, message, data}});
  }
  onNotification(h: (n: JsonRpcNotification) => void): void { this.notifHandlers.push(h); }
  onRequest(h: (r: JsonRpcRequest) => void): void { this.reqHandlers.push(h); }
  get closed(): boolean { return this._closed; }
  close(): void { this._closed = true; }
}

// ── RpcServer routing ────────────────────────────────────────────────────

describe("RpcServer routing", () => {
  it("unknown method -> respond with {ok:false, error:'unknown_method'} + method echo", async () => {
    const t = new InMemoryTransport();
    const server = new RpcServer(t);
    // Deliver a request for a method that was never registered.
    t.deliver({jsonrpc: "2.0", id: "m1", method: "rpc:doesNotExist"});
    // allow the async onRequest handler to settle
    await new Promise((r) => setTimeout(r, 0));
    expect(t.sentResponses.length).toBe(1);
    const resp = t.sentResponses[0];
    expect(resp.id).toBe("m1");
    expect(resp.result).toEqual({ok: false, error: "unknown_method", method: "rpc:doesNotExist"});
  });

  it("registered handler success -> respond with its return value", async () => {
    const t = new InMemoryTransport();
    const server = new RpcServer(t);
    server.register("rpc:ping", async () => ({pong: true}));
    t.deliver({jsonrpc: "2.0", id: "m2", method: "rpc:ping"});
    await new Promise((r) => setTimeout(r, 0));
    expect(t.sentResponses[0].result).toEqual({pong: true});
  });

  it("registered handler that returns undefined -> respond with {ok:true} default", async () => {
    const t = new InMemoryTransport();
    const server = new RpcServer(t);
    server.register("rpc:noop", async () => undefined);
    t.deliver({jsonrpc: "2.0", id: "m3", method: "rpc:noop"});
    await new Promise((r) => setTimeout(r, 0));
    expect(t.sentResponses[0].result).toEqual({ok: true});
  });

  it("handler throw -> respond with {ok:false, error: msg} AND emit an err:uncaught notification", async () => {
    const t = new InMemoryTransport();
    const server = new RpcServer(t);
    server.register("rpc:boom", async () => { throw new Error("kaboom"); });
    t.deliver({jsonrpc: "2.0", id: "m4", method: "rpc:boom", params: {}});
    await new Promise((r) => setTimeout(r, 0));
    // response with the error message
    const resp = t.sentResponses[0];
    expect((resp.result as {ok: boolean; error: string}).ok).toBe(false);
    expect((resp.result as {error: string}).error).toBe("kaboom");
    // and an err:uncaught notification for crash reporting (R1/R5 crash-report path)
    const uncaught = t.sentNotifications.find((n) => n.method === "err:uncaught");
    expect(uncaught).toBeDefined();
    expect((uncaught!.params as {message: string}).message).toBe("kaboom");
  });

  it("handler receives params (default {} when omitted) + working notify() callback", async () => {
    const t = new InMemoryTransport();
    const server = new RpcServer(t);
    server.register("rpc:echo", async (params, notify) => {
      // prove the injected notify() routes back through the transport
      notify({jsonrpc: "2.0", method: "ev:side", params: {x: 1}});
      return {gotParams: params};
    });
    t.deliver({jsonrpc: "2.0", id: "m5", method: "rpc:echo", params: {a: 42}});
    await new Promise((r) => setTimeout(r, 0));
    expect((t.sentResponses[0].result as {gotParams: {a: number}}).gotParams).toEqual({a: 42});
    // the side notification was emitted through the same transport
    expect(t.sentNotifications.find((n) => n.method === "ev:side")).toBeDefined();
    // and when params is omitted, the handler gets {} (req.params ?? {})
    t.deliver({jsonrpc: "2.0", id: "m6", method: "rpc:echo"});
    await new Promise((r) => setTimeout(r, 0));
    expect((t.sentResponses[1].result as {gotParams: unknown}).gotParams).toEqual({});
  });

  it("convenience notify() forwards to the transport as a JsonRpcNotification", () => {
    const t = new InMemoryTransport();
    const server = new RpcServer(t);
    server.notify("ev:hello", {n: 1});
    expect(t.sentNotifications[0]).toEqual({jsonrpc: "2.0", method: "ev:hello", params: {n: 1}});
  });

  it("multiple registered handlers: each method routes to its own handler", async () => {
    const t = new InMemoryTransport();
    const server = new RpcServer(t);
    server.register("rpc:a", async () => ({who: "a"}));
    server.register("rpc:b", async () => ({who: "b"}));
    t.deliver({jsonrpc: "2.0", id: "i1", method: "rpc:a"});
    t.deliver({jsonrpc: "2.0", id: "i2", method: "rpc:b"});
    await new Promise((r) => setTimeout(r, 0));
    expect((t.sentResponses.find((s) => s.id === "i1")!.result as {who: string}).who).toBe("a");
    expect((t.sentResponses.find((s) => s.id === "i2")!.result as {who: string}).who).toBe("b");
  });
});
