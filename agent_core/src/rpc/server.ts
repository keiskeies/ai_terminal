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
        const err = e as Error;
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
