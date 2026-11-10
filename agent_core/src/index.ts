// index.ts - main entry for the agent-core Node subprocess
// Phase 0: wire up stdio JSONL RPC server + rpc:ping handler.

import {RpcServer} from "./rpc/server.js";
import {runLocalCommand} from "./tools/builtin.js";
import type {CommandExecutor} from "./react/engine.js";

// ─── Re-exports for convenience ─────────────────────────────────
export {parse} from "./react/index.js";
export {fnv1a64DartCompat, stableId} from "./utils/stable_hash.js";
export {TailTextBuffer} from "./utils/tail_buffer.js";
export {TaskGeneration, StaleTaskError} from "./utils/generation.js";
export {PendingRegistry} from "./utils/pending_registry.js";
export {detectShell, wrapCommand, extractExitMarker} from "./utils/shell_detect.js";
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
export {
  decideCommand,
  destructiveToolNeedsConfirm,
  SAFETY_LEVELS,
  GATE_DECISIONS,
} from "./utils/permission_policy.js";
export type {SafetyLevel, CommandGateDecision} from "./utils/permission_policy.js";
export {
  checkSafety,
  checkPath,
  checkReadPath,
  getSafetyReason,
  getSafetyTip,
  PathSafetyResult,
  requireConfirm,
} from "./utils/safety_guard.js";

// ─── Task state (Phase 0 minimal) ───────────────────────────────
interface TaskState {
  taskId: string | null;
  status: "idle" | "running";
  startedAt: number | null;
}

const taskState: TaskState = {taskId: null, status: "idle", startedAt: null};

/**
 * Doc §2.2 rpc:startTask / rpc:cancelTask live engine wiring. A single engine
 * runs at a time; a concurrent startTask is rejected with {ok:false,error:"task_running"}
 * so the parent cancels first (doc §2.4 supersede semantics enforced by R1
 * generation checks in the engine).
 */
let activeEngine: import("./react/engine.js").ReActEngine | null = null;
let activeRun: Promise<import("./rpc/schema.js").AgentFinishState> | null = null;

/**
 * Build a streaming LLM client from a ModelConfig (doc §2.2 W2). Exported so
 * tests can override the client (mock / fake) without a live endpoint.
 */
export async function makeLlmClient(mc: import("./rpc/schema.js").ModelConfig): Promise<import("./llm/clients.js").LlmClient> {
  if (mc.provider === "anthropic") {
    const {AnthropicStreamClient} = await import("./llm/anthropic_stream.js");
    return new AnthropicStreamClient({apiKey: mc.apiKey ?? "", model: mc.model, baseUrl: mc.baseUrl, maxTokens: mc.maxTokens, temperature: mc.temperature});
  }
  if (mc.provider === "ollama") {
    const {OllamaStreamClient} = await import("./llm/ollama_stream.js");
    return new OllamaStreamClient({model: mc.model, baseUrl: mc.baseUrl, maxTokens: mc.maxTokens, temperature: mc.temperature});
  }
  // openai | openai_compatible | deepseek
  const {OpenAiStreamClient} = await import("./llm/openai_stream.js");
  return new OpenAiStreamClient({apiKey: mc.apiKey ?? "", model: mc.model, baseUrl: mc.baseUrl, maxTokens: mc.maxTokens, temperature: mc.temperature});
}

/**
 * Start the agent-core RPC server on stdio.
 * Blocks forever; parent communicates via JSONL lines on stdin/stdout.
 */
/**
 * Phase 2 live command executor: routes a raw shell command through the W4
 * runLocalCommand runner (local_exec). Returns a CommandExecResult so the
 * engine can emit a real result event (output/exitCode/durationMs).
 */
function buildLocalCommandExecutor(): CommandExecutor {
  const defaultCwd = process.cwd();
  const timeoutSec = 120;
  return async (command, _ctx): Promise<import("./react/engine.js").CommandExecResult> => {
    const {wrapCommand} = await import("./utils/shell_detect.js");
    const marker = "EXITCODE_LOCAL:"; // Dart convention: marker ends with ':'
    const shell = process.platform === "win32" ? ("powershell" as const) : ("bash" as const);
    const wrapped = wrapCommand(command, shell, marker);
    const t0 = Date.now();
    try {
      const {stdout, stderr, exitCode} = await runLocalCommand(wrapped, defaultCwd, shell, timeoutSec);
      const durationMs = Date.now() - t0;
      if (exitCode === 0) {
        return {stdout, stderr, exitCode, durationMs, success: true};
      }
      return {stdout, stderr, exitCode, durationMs, success: false, failureKind: "non_zero_exit"};
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      const timedOut = /timeout/i.test(msg);
      return {stdout: "", stderr: msg, exitCode: -1, durationMs: Date.now() - t0, success: false, timedOut, failureKind: timedOut ? "timeout" : "exec_error"};
    }
  };
}

export function startServer(opts: {verbose?: boolean; llmFactory?: () => import("./llm/clients.js").LlmClient} = {}): RpcServer {
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

  // rpc:startTask - doc §2.2 core task-launch method. Builds a ReActEngine
  // (W2 streaming LLM client + W7 checkpoint store) and streams parsed events
  // to the parent as evt:agentEvent; the terminal state is emitted as
  // evt:taskState (doc §2.4 consistency invariant).
  server.register("rpc:startTask", async (params: import("./rpc/schema.js").StartTaskParams) => {
    if (taskState.status === "running") {
      return {ok: false, error: "task_running", runningTaskId: taskState.taskId};
    }
    const mc = params.modelConfig;
    const llm = opts.llmFactory !== undefined ? opts.llmFactory() : await makeLlmClient(mc);
    const {ReActEngine} = await import("./react/engine.js");
    const {CheckpointStore} = await import("./utils/checkpoint_store.js");
    const engine = new ReActEngine(llm, mc, {
      onEvent: (evt) => { server.notify("evt:agentEvent", {taskId: params.taskId, event: evt}); },
      onFinished: (state, _summary) => {
        server.notify("evt:taskState", {taskId: params.taskId, state: state as import("./rpc/schema.js").TaskState});
      },
      onError: (msg) => { server.notify("err:uncaught", {message: msg, taskId: params.taskId}); },
    }, {
      checkpointStore: new CheckpointStore(),
      resumeFromCheckpoint: params.resumeFromCheckpoint === true,
      // Phase 2: real command execution. The engine parses a raw shell command and
      // dispatches it through this executor (W4 runLocalCommand, the same runner
      // local_exec uses). Default cwd = process.cwd(); platform shell is auto-detected
      // inside runLocalCommand via wrapCommand + the chosen shell (R6 branch).
      commandExecutor: buildLocalCommandExecutor(),
    });
    activeEngine = engine;
    taskState.taskId = params.taskId;
    taskState.status = "running";
    taskState.startedAt = Date.now();
    const maxSteps = params.maxSteps ?? 20;
    activeRun = engine.run(params, maxSteps).finally(() => {
      activeEngine = null;
      activeRun = null;
      taskState.status = "idle";
      taskState.startedAt = null;
    });
    return {ok: true, runId: params.taskId};
  });
  // rpc:health - W7 rollback probe: Dart side calls before committing to Node engine
  // rpc:health - W7 rollback probe: Dart side calls before committing to Node engine.
  // Reports the FULL Node tool surface (W4 pure-Node + W5 orchestrator trio) so that
  // Dart's rollback decision sees exec_on/exec_batch/check_connectivity as available.
  server.register("rpc:health", async (params: Record<string, unknown>) => {
    const {buildDefaultToolRegistry} = await import("./tools/index.js");
    const {buildOrchestratorTools} = await import("./tools/orchestrator.js");
    // No-op executor stub for enumeration only (the probe reads .name/.kind/.scope).
    const noopExecutor = {
      executeOn: async () => ({stdout:"", stderr:"probe", exitCode:-1, durationMs:0, success:false}),
      executeBatch: async () => new Map(),
      checkConnectivity: async () => ({fromHostId:"-", targetHost:"-", port:0, reachable:false, elapsedMs:0, summary:"probe"}),
    } as any;
    const registry = buildDefaultToolRegistry();
    const w4Tools: import("./tools/builtin.js").AgentTool[] = registry.all;
    const w5Tools: import("./tools/builtin.js").AgentTool[] = buildOrchestratorTools(noopExecutor);
    const allTools = [...w4Tools, ...w5Tools];
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

  // rpc:cancelTask - doc §2.2: cancel the running task. The engine marks it
  // "cancelled" (R1 generation + R5 terminal-state matrix). A pending run is
  // awaited so the final evt:taskState notification is emitted before resolve.
  server.register("rpc:cancelTask", async () => {
    if (activeEngine !== null && taskState.status === "running") {
      activeEngine.cancel();
      if (activeRun !== null) await activeRun.catch(() => {});
    }
    taskState.taskId = null;
    taskState.status = "idle";
    taskState.startedAt = null;
    activeEngine = null;
    activeRun = null;
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
export type {PlatformProfile} from "./tools/platform.js";
export {MOBILE_SAFE_TOOLS, DESKTOP_ONLY_TOOLS, toolsForPlatform} from "./tools/platform.js";
export {shouldUseNodeAgent, rolloutFraction} from "./utils/rollout.js";
export type {RolloutOptions} from "./utils/rollout.js";
