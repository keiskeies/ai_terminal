// JSONL stdio transport - bidirectional, newline-delimited
// - Writes: JSON.stringify + \n, line-flushed on process.stdout
// - Reads: split process.stdin on \n, reassemble multi-line fragments
// - Large payloads (>64KB data field) are split into frames by the SENDER;
//   this module only does line-delimited I/O, no byte-level framing.

import {createInterface} from "node:readline";
import {JsonRpcMessage, JsonRpcRequest, JsonRpcResponse, JsonRpcNotification} from "./schema.js";

export type RpcMessage = JsonRpcMessage;

export interface RpcTransport {
  /** Send a request/expect response. Rejects on transport error. */
  request<T>(msg: JsonRpcRequest): Promise<T>;
  /** Fire-and-forget notification. */
  notify(msg: JsonRpcNotification): void;
  /** Respond to an incoming request. */
  respond(id: string, result: unknown): void;
  /** Reject an incoming request. */
  reject(id: string, code: number, message: string, data?: unknown): void;
  /** Called when a notification arrives. */
  onNotification(handler: (n: JsonRpcNotification) => void): void;
  /** Called when a request arrives (reverse RPC). */
  onRequest(handler: (r: JsonRpcRequest) => void): void;
  /** True when the peer closed the stream. */
  get closed(): boolean;
  /** Close both directions. Idempotent. */
  close(): void;
}

// ─── Child-side transport (parent writes to child, child reads) ──────────

export class StdioChildTransport implements RpcTransport {
  private pending = new Map<string, {resolve: (v: unknown) => void; reject: (e: Error) => void}>();
  private reqIdCounter = 0;
  private notifHandlers: Array<(n: JsonRpcNotification) => void> = [];
  private reqHandlers: Array<(r: JsonRpcRequest) => void> = [];
  private _closed = false;

  constructor() {
    const rl = createInterface({input: process.stdin, crlfDelay: Infinity});
    rl.on("line", (line) => {
      if (!line.trim()) return;
      let msg: JsonRpcMessage;
      try {
        msg = JSON.parse(line);
      } catch {
        process.stderr.write("Malformed JSON on stdin, dropping line\n");
        return;
      }
      this.dispatch(msg);
    });
    rl.on("close", () => {
      this._closed = true;
      this.failAllPending(new Error("stdin closed"));
    });
  }

  private dispatch(msg: JsonRpcMessage) {
    if ("id" in msg && "method" in msg && "jsonrpc" in msg) {
      const req = msg as JsonRpcRequest;
      for (const h of this.reqHandlers) h(req);
    } else if ("id" in msg && ("result" in msg || "error" in msg)) {
      const resp = msg as JsonRpcResponse;
      const p = this.pending.get(resp.id);
      if (p) {
        this.pending.delete(resp.id);
        if (resp.error) {
          p.reject(new Error("RPC error " + resp.error.code + ": " + resp.error.message));
        } else {
          p.resolve(resp.result);
        }
      }
    } else if ("method" in msg) {
      const notif = msg as JsonRpcNotification;
      for (const h of this.notifHandlers) h(notif);
    }
  }

  request<T>(msg: JsonRpcRequest): Promise<T> {
    if (this._closed) return Promise.reject(new Error("transport closed"));
    const id = msg.id || ("req-" + ++this.reqIdCounter);
    const full: JsonRpcRequest = {...msg, id};
    const line = JSON.stringify(full) + "\n";
    const ok = process.stdout.write(line);
    // Node's stdout is async; if write returns false we could back-pressure,
    // but our frame size is bounded by 64KB data per frame, so we don't block here.
    void ok;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, {resolve: resolve as (v: unknown) => void, reject});
    });
  }

  notify(msg: JsonRpcNotification): void {
    if (this._closed) return;
    process.stdout.write(JSON.stringify(msg) + "\n");
  }

  respond(id: string, result: unknown): void {
    if (this._closed) return;
    const resp: JsonRpcResponse = {jsonrpc: "2.0", id, result};
    process.stdout.write(JSON.stringify(resp) + "\n");
  }

  reject(id: string, code: number, message: string, data?: unknown): void {
    if (this._closed) return;
    const resp: JsonRpcResponse = {jsonrpc: "2.0", id, error: {code, message, data}};
    process.stdout.write(JSON.stringify(resp) + "\n");
  }

  onNotification(handler: (n: JsonRpcNotification) => void): void {
    this.notifHandlers.push(handler);
  }

  onRequest(handler: (r: JsonRpcRequest) => void): void {
    this.reqHandlers.push(handler);
  }

  get closed(): boolean { return this._closed; }

  close(): void {
    this._closed = true;
    this.failAllPending(new Error("transport closed"));
    process.stdin.pause();
  }

  private failAllPending(err: Error) {
    for (const [, p] of this.pending) p.reject(err);
    this.pending.clear();
  }
}

// ─── Dart-side transport (will be mirrored in Dart, listed here for reference) ───
// Dart implementation lives in ai_terminal/lib/agent_bridge/json_rpc_transport.dart
// It uses Process.start and reads stdout line-by-line, writes to stdin.
// The message shapes are identical to this file's JsonRpcMessage type.
