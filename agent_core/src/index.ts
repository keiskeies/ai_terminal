// index.ts - main entry for the agent-core Node subprocess
// Phase 0: wire up stdio JSONL RPC server + rpc:ping handler.

import {RpcServer} from "./rpc/server.js";

// ─── Re-exports for convenience ─────────────────────────────────
export {parse} from "./react/index.js";
export {fnv1a64DartCompat, stableId} from "./utils/stable_hash.js";
export {TailTextBuffer} from "./utils/tail_buffer.js";
export {TaskGeneration, StaleTaskError} from "./utils/generation.js";
export {PendingRegistry} from "./utils/pending_registry.js";
export {detectShell, wrapCommand} from "./utils/shell_detect.js";
export {StreamAccumulator} from "./llm/stream.js";
export {MockLlmClient, OpenAiClient} from "./llm/clients.js";
export type {LlmClient, LlmResult, ChatMsg} from "./llm/clients.js";
export {StdioChildTransport} from "./rpc/transport.js";
export {RpcServer} from "./rpc/server.js";
export {ReverseRpcClient} from "./rpc/client.js";

// ─── Task state (Phase 0 minimal) ───────────────────────────────
interface TaskState {
  taskId: string | null;
  status: "idle" | "running";
  startedAt: number | null;
}

const taskState: TaskState = {taskId: null, status: "idle", startedAt: null};

/**
 * Start the agent-core RPC server on stdio.
 * Blocks forever; parent communicates via JSONL lines on stdin/stdout.
 */
export function startServer(opts: {verbose?: boolean} = {}): RpcServer {
  const server = new RpcServer();

  // rpc:ping - handshake / liveness check (parent -> child)
  server.register("rpc:ping", async (params: Record<string, unknown>) => {
    return {
      ok: true,
      protocolVersion: "1.0",
      ts: Date.now(),
      echo: params.echo ?? null,
    };
  });

  // rpc:getState - return current task state
  server.register("rpc:getState", async () => {
    return {
      ok: true,
      ...taskState,
    };
  });

  // rpc:cancelTask - cancel the running task (Phase 0: just clears state)
  server.register("rpc:cancelTask", async () => {
    taskState.taskId = null;
    taskState.status = "idle";
    taskState.startedAt = null;
    return {ok: true};
  });

  // rpc:confirm - placeholder, Phase 2
  server.register("rpc:confirm", async (params: Record<string, unknown>) => {
    return {ok: false, error: "confirm not yet implemented - Phase 2", confirmId: params.confirmId ?? null};
  });

  if (opts.verbose) {
    console.error("[agent-core] server started on stdio");
  }
  return server;
}

// Auto-start when run as the main module
const isMain = process.argv[1]?.endsWith("index.js") || process.argv[1]?.endsWith("index.ts");
if (isMain) {
  startServer();
}