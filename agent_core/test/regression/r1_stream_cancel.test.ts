// Regression: docs §6.2 r1_stream_cancel.test.ts (AGENTS.md R1.2).
//
// cancel() / transport-close must release every pending waiter: a dangling await
// is the historical #1 cause of permanent _callAI hangs (Dart:
// StreamSubscription.cancel() does not fire onDone, so waiting Completers must
// be completed manually). Pins the Node equivalents - PendingRegistry.resolveAll,
// CompleterLike, and ReverseRpcClient over a transport that rejects its pending
// requests when it closes. The StdioChildTransport close() contract itself is
// already pinned in rpc_transport.test.ts and is intentionally not repeated.

import {describe, it, expect} from "vitest";
import {PendingRegistry, CompleterLike} from "../../src/utils/pending_registry.js";
import {ReverseRpcClient} from "../../src/rpc/client.js";
import type {RpcTransport, JsonRpcRequest} from "../../src/rpc/transport.js";

// Race a promise against a short timer to prove a waiter is (not) still pending.
function raced<T>(p: Promise<T>, ms = 25): Promise<T | "pending"> {
  return Promise.race([p, new Promise<"pending">((r) => setTimeout(() => r("pending"), ms))]);
}

// In-memory transport with the same pending-request semantics as
// StdioChildTransport: requests stay pending until the peer replies, and close()
// rejects everything still in flight (the Dart manual-complete() equivalence).
class FakeTransport {
  sent: Array<{id: string; method: string}> = [];
  private pending = new Map<string, {resolve: (v: unknown) => void; reject: (e: Error) => void}>();
  private closedFlag = false;
  request<T>(msg: JsonRpcRequest): Promise<T> {
    if (this.closedFlag) return Promise.reject(new Error("transport closed"));
    const id = String(msg.id);
    this.sent.push({id, method: msg.method});
    return new Promise<T>((resolve, reject) => this.pending.set(id, {resolve: resolve as (v: unknown) => void, reject}));
  }
  notify(): void {}
  respond(): void {}
  reject(): void {}
  onNotification(): void {}
  onRequest(): void {}
  get closed(): boolean { return this.closedFlag; }
  close(): void {
    this.closedFlag = true;
    for (const [, p] of this.pending) p.reject(new Error("stdin closed"));
    this.pending.clear();
  }
}
const asTransport = (t: FakeTransport): RpcTransport => t as unknown as RpcTransport;

describe("R1.2 PendingRegistry.resolveAll", () => {
  it("resolves every registered waiter exactly once and clears the set", () => {
    const reg = new PendingRegistry();
    let a = 0; let b = 0;
    reg.register(() => a++);
    reg.register(() => b++);
    expect(reg.size).toBe(2);
    reg.resolveAll("cancel");
    expect(a).toBe(1);
    expect(b).toBe(1);
    expect(reg.isEmpty).toBe(true);
    // Idempotent: a second resolveAll has nobody left to wake.
    reg.resolveAll();
    expect(a).toBe(1);
  });

  it("a waiter that throws does not block the remaining waiters", () => {
    const reg = new PendingRegistry();
    let b = 0;
    reg.register(() => { throw new Error("bad waiter"); });
    reg.register(() => b++);
    expect(() => reg.resolveAll()).not.toThrow();
    expect(b).toBe(1);
    expect(reg.isEmpty).toBe(true);
  });
});

describe("R1.2 CompleterLike", () => {
  it("resolve wins once; later reject is ignored (Dart Completer parity)", async () => {
    const c = new CompleterLike<string>();
    c.resolve("first");
    c.reject(new Error("late"));
    await expect(c.promise).resolves.toBe("first");
    expect(c.isDone).toBe(true);
  });
  it("reject wins once; later resolve is ignored", async () => {
    const c = new CompleterLike<string>();
    c.reject(new Error("boom"));
    c.resolve("late");
    await expect(c.promise).rejects.toThrow("boom");
  });
});

describe("R1.2 reverse-RPC waiters released when the transport closes", () => {
  it("invokeSsh hangs while open, settles the moment the transport closes", async () => {
    const t = new FakeTransport();
    const client = new ReverseRpcClient(asTransport(t));
    const inflight = client.invokeSsh({hostId: "web1", command: "uname -a"});
    // Map settle-outcome to a string so Promise.race never sees a rejection.
    const outcome = inflight.then(() => "resolved", (e: Error) => e.message);
    expect(await raced(outcome)).toBe("pending");
    t.close();
    // The rejection arrives on the next tick - never dangling forever.
    expect(await raced(outcome, 10)).toBe("stdin closed");
  });

  it("every concurrent reverse request is rejected by one close", async () => {
    const t = new FakeTransport();
    const client = new ReverseRpcClient(asTransport(t));
    const p1 = client.invokeSsh({hostId: "a", command: "id"});
    const p2 = client.invokeSftp({hostId: "b", op: "ls"});
    const p3 = client.queryKnowledge({query: "q"});
    p1.catch(() => {}); p2.catch(() => {}); p3.catch(() => {});
    expect(t.sent.length).toBe(3);
    t.close();
    const results = await Promise.all([
      p1.then(() => "ok", () => "rejected"),
      p2.then(() => "ok", () => "rejected"),
      p3.then(() => "ok", () => "rejected"),
    ]);
    expect(results).toEqual(["rejected", "rejected", "rejected"]);
  });

  it("a request issued after close rejects immediately (transport closed)", async () => {
    const t = new FakeTransport();
    const client = new ReverseRpcClient(asTransport(t));
    t.close();
    await expect(client.queryKnowledge({query: "x"})).rejects.toThrow("transport closed");
  });
});
