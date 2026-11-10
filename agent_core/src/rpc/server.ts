// RPC server - routes incoming parent->child requests to handlers
// Each handler is wrapped in try/catch; uncaught errors are reported via err:uncaught.

import {StdioChildTransport, RpcTransport} from "./transport.js";
import {JsonRpcRequest, JsonRpcNotification} from "./schema.js";

export type RpcHandler = (
  params: any,
  notify: (n: JsonRpcNotification) => void,
  transport: RpcTransport,
) => Promise<any>;

export class RpcServer {
  private transport: RpcTransport;
  private handlers = new Map<string, RpcHandler>();

  constructor(transport?: RpcTransport) {
    this.transport = transport ?? new StdioChildTransport();
    this.wire();
  }

  register(method: string, handler: RpcHandler): void {
    this.handlers.set(method, handler);
  }

  private wire(): void {
    const t = this.transport;
    t.onRequest(async (req: JsonRpcRequest) => {
      const handler = this.handlers.get(req.method);
      if (!handler) {
        t.respond(req.id, {ok: false, error: "unknown_method", method: req.method});
        return;
      }
      try {
        const result = await handler(req.params ?? {}, (n: JsonRpcNotification) => t.notify(n), t);
        t.respond(req.id, result ?? {ok: true});
      } catch (e: unknown) {
        // R1.1/R5: a caught error must still carry its diagnostic. A non-Error
        // throwable (string / null / plain object thrown by a handler) used to hit
        // `e as Error` and land as {ok:false, error:undefined} + an err:uncaught
        // with message:undefined - a failure with no diagnostic at all.
        const err = e instanceof Error ? e : new Error(toThrowableText(e));
        t.respond(req.id, {ok: false, error: err.message, stack: err.stack});
        // Also emit uncaught for crash reporting
        t.notify({jsonrpc: "2.0", method: "err:uncaught", params: {message: err.message, stack: err.stack, taskId: undefined}});
      }
    });
  }

  /** Convenience: emit a notification to parent */
  notify(method: string, params: Record<string, unknown>): void {
    this.transport.notify({jsonrpc: "2.0", method, params});
  }

}


/** Describe a non-Error throwable without ever throwing from the describer itself. */
function toThrowableText(e: unknown): string {
  if (typeof e === "string") return "non-Error thrown (string): " + e;
  try {
    const j = JSON.stringify(e);
    return "non-Error thrown: " + (j === undefined ? String(e) : j);
  } catch {
    // circular / BigInt / exotic -> type name only, never a second throw
    return "non-Error thrown (unserializable " + typeof e + ")";
  }
}
