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
export {spawnLocalPty, resolvePtyShell, buildPtyEnv, buildPtyConfig} from "./pty/index.js";
export type {PtySession, PtyOptions, PtyConfig, PtyShellResolution, ShellKind, ExistCheck} from "./pty/index.js";
export {StreamAccumulator} from "./llm/stream.js";
export {MockLlmClient, OpenAiClient} from "./llm/clients.js";
export {OpenAiStreamClient} from "./llm/openai_stream.js";
export type {OpenAiStreamConfig} from "./llm/openai_stream.js";
export {AnthropicStreamClient} from "./llm/anthropic_stream.js";
export type {AnthropicStreamConfig} from "./llm/anthropic_stream.js";
export {OllamaStreamClient} from "./llm/ollama_stream.js";
export type {OllamaStreamConfig} from "./llm/ollama_stream.js";
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

  // rpc:health - W7 rollback probe: Dart side calls before committing to Node engine
  server.register("rpc:health", async (params: Record<string, unknown>) => {
    const {buildDefaultToolRegistry} = await import("./tools/index.js");
    const registry = buildDefaultToolRegistry();
    const allTools: import("./tools/builtin.js").AgentTool[] = registry.all;
    const requested: string[] = Array.isArray(params.tools) ? params.tools as string[] : allTools.map((t: import("./tools/builtin.js").AgentTool) => t.name);
    const tools = requested.map(name => {
      const t = allTools.find((x: import("./tools/builtin.js").AgentTool) => x.name === name);
      return { name, registered: !!t, kind: t?.kind, scope: t?.scope };
    });
    return {
      ok: true,
      protocolVersion: "1.0",
      nodeVersion: process.version,
      tools,
      errors: [] as string[],
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
export {CheckpointStore} from "./utils/checkpoint_store.js";
export type {TaskCheckpoint} from "./utils/checkpoint_store.js";
export {ProcessSupervisor} from "./utils/process_supervisor.js";
export type {ProcessHandle, SupervisorConfig} from "./utils/process_supervisor.js";

export {ReActEngine} from "./react/engine.js";
export {buildDefaultToolRegistry} from "./tools/index.js";
export type {HealthParams, HealthResult, ToolHealth, LlmHealth} from "./rpc/schema.js";
