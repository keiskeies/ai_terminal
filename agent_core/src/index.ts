// index.ts - main entry for the agent-core Node subprocess
// Phase 0: wire up stdio JSONL RPC server + rpc:ping handler.

import {RpcServer} from "./rpc/server.js";
import {runLocalCommand} from "./tools/builtin.js";
import type {CommandExecutor} from "./react/engine.js";
import {ConfirmFlow} from "./react/confirm_flow.js";

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
export {
  AgentGoal,
  AGENT_GOAL_STATUSES,
  GoalDecision,
  GOAL_ACTIONS,
  GOAL_DONE_MARKER,
  decideGoalContinuation,
  goalMarkedDone,
  isGoalMarkerOnlyCommand,
  shouldScheduleGoalRound,
  shouldKickGoalRound,
  buildGoalContinuationPrompt,
} from "./utils/goal_continuation.js";
export type {AgentGoalStatus, GoalAction} from "./utils/goal_continuation.js";

// ─── Task state (Phase 0 minimal) ───────────────────────────────
// ─── Confirm flow wiring (doc §9 item 6 / 7) ──────────────────────────
// The dangerous-command / destructive-tool state machine lives in
// react/confirm_flow.ts. TWO callers drive it now: the ReAct engine’s
// command gate (rpc:startTask injects the instance) and rpc:confirm, which
// answers whatever wait is outstanding. The server still owns the single
// instance - Dart has one _confirmCompleter, and two flows would let a
// confirmation be answered by the wrong one.
//
// The generation / cancellation counters below are the SINGLE source both
// callers read: the flow’s ConfirmFlowContext closes over them, and the
// engine is injected with accessors onto the same variables, so the gate’s
// "still mine?" check after its await compares against the very number the
// flow reports (R1 - a parallel counter would always look current).
let serverGeneration = 0;
let serverCancelled = false;
let serverPermissionMode: import("./rpc/schema.js").PermissionMode = "ask";
let confirmEventSeq = 0;

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
// One confirm flow per server, created in startServer() so its notify
// hooks close over the server. It stays null until startServer runs.
let confirmFlow: ConfirmFlow | null = null;

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

  // A throwing notify sink must never abort the confirm flow (mirrors the
  // engine callback discipline at react/engine.ts). Every hook below is
  // fire-and-forget and guarded for exactly that reason.
  const safeNotify = (method: string, params: Record<string, unknown>): void => {
    try {
      server.notify(method, params);
    } catch (e: unknown) {
      if (opts.verbose) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[agent-core] confirm notify failed (" + method + "): " + msg);
      }
    }
  };
  const infoEvent = (text: string): import("./rpc/schema.js").AgentEvent => {
    return {
      id: "confirm-info-" + ++confirmEventSeq,
      type: "info",
      timestamp: Date.now(),
      text,
    };
  };
  confirmFlow = new ConfirmFlow({
    context: {
      currentGeneration: () => serverGeneration,
      permissionMode: () => serverPermissionMode,
      isCancelled: () => serverCancelled,
      bumpGeneration: () => {
        serverGeneration++;
      },
    },
    events: {
      onInfo: (text) => {
        safeNotify("evt:agentEvent", {taskId: taskState.taskId, event: infoEvent(text)});
      },
      onWaitingConfirm: () => {
        safeNotify("evt:taskState", {taskId: taskState.taskId, state: "waiting_confirm"});
      },
      onConfirmRequest: (req) => {
        safeNotify("evt:confirmRequest", {
          taskId: taskState.taskId,
          confirmId: req.confirmId,
          prompt: req.prompt,
          timeoutMs: req.timeoutMs,
          riskLevel: req.riskLevel,
        });
      },
      onLog: (level, message) => {
        if (opts.verbose) console.error("[agent-core] confirm " + level + ": " + message);
      },
    },
  });

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
      // §9 item 6/7: the engine-side permission gate needs the SAME flow the
      // rpc:confirm handler answers, the SAME permission mode ConfirmFlowContext
      // reports, and the SAME generation counter. Injecting accessors (not values)
      // is what keeps Dart’s single-counter invariant true here - the gate must
      // notice a supersede that lands while it awaits, and a snapshot could not.
      confirmFlow: confirmFlow ?? undefined,
      permissionMode: (): import("./rpc/schema.js").PermissionMode => serverPermissionMode,
      generation: {current: () => serverGeneration, bump: () => { serverGeneration++; }},
    });
    activeEngine = engine;
    // The parent's permission mode used to be dropped here; confirm_flow reads
    // it back through ConfirmFlowContext.permissionMode(), so it must be
    // captured (Dart default is "ask": agent_engine.dart:328).
    serverPermissionMode = params.permissionMode ?? "ask";
    serverCancelled = false;
    // Dart bumps _currentTaskGeneration exactly once per startTask (770). That single
    // bump happens inside engine.run() on the generation source injected above, so the
    // server and the engine cannot each advance a counter of their own: the gate’s
    // post-await "still mine?" has to compare against the very number
    // ConfirmFlowContext.currentGeneration() reports (R1). rpc:cancelTask’s bump is
    // delegated to engine.cancel() for the same reason, matching Dart 931.
    // The per-task confirm counters still restart here (Dart resets them at :784 / :789).
    if (confirmFlow !== null) {
      if (confirmFlow.hasPendingConfirm) {
        // Cannot normally happen: a startTask while a task runs is rejected
        // above. If a previous teardown ever left a waiter behind, WAKE it
        // rather than drop it (R1: a dropped awaiter is a permanent hang).
        confirmFlow.wakeForCancelTask();
      }
      confirmFlow.resetConfirmWaitSeconds();
      confirmFlow.resetTaskHadConfirmTimeout();
    }
    taskState.taskId = params.taskId;
    taskState.status = "running";
    taskState.startedAt = Date.now();
    const maxSteps = params.maxSteps ?? 20;
    activeRun = engine.run(params, maxSteps).finally(() => {
      activeEngine = null;
      activeRun = null;
      taskState.status = "idle";
      taskState.startedAt = null;
      // Dart _finishTask (3809-3811): finish clears the confirm timeout timer
      // only - never the completer. The wait has already been exited by now,
      // and completing it here would fake a user answer nobody gave.
      confirmFlow?.finishCleanup();
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
    confirmFlow?.wakeForCancelTask();
    if (activeEngine !== null && taskState.status === "running") {
      // Cancellation must be visible to the confirm continuation that resumes
      // after its await (Dart 701-707). No generation bump: cancel is not a
      // supersede, the flow reports "cancelled_during_confirm" itself.
      serverCancelled = true;
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

  // rpc:confirm - doc §2.2 / §9 item 6: deliver the parent's decision on a
  // pending confirmation. schema/request.schema.json requires
  // taskId + confirmId + decision, decision in ok|reject|timeout. The wire
  // carries a confirmId that Dart's UI never needed (it calls the engine
  // directly), so it is validated here: a stale or foreign confirmId must
  // never resolve somebody else's wait.
  server.register(
    "rpc:confirm",
    async (params: import("./rpc/schema.js").ConfirmParams): Promise<
      | {ok: true; confirmId: string; woken: boolean}
      | {ok: false; error: string; confirmId: string | null}
    > => {
      const confirmId = params.confirmId ?? null;
      const decision = params.decision;
      if (decision !== "ok" && decision !== "reject" && decision !== "timeout") {
        return {ok: false, error: "invalid_decision: " + String(decision), confirmId};
      }
      const flow = confirmFlow;
      if (flow === null) {
        return {ok: false, error: "confirm_flow_unavailable", confirmId};
      }
      if (taskState.taskId !== null && params.taskId !== undefined && params.taskId !== taskState.taskId) {
        return {ok: false, error: "task_id_mismatch: " + taskState.taskId, confirmId};
      }
      const pendingId = flow.pendingConfirmId;
      if (pendingId === null) {
        return {ok: false, error: "no_pending_confirm", confirmId};
      }
      if (confirmId !== pendingId) {
        return {ok: false, error: "confirm_id_mismatch: " + pendingId, confirmId};
      }
      const wasPending = flow.hasPendingConfirm;
      if (decision === "ok") {
        flow.confirmDangerousCommand();
      } else if (decision === "reject") {
        flow.rejectDangerousCommand();
      } else {
        // The parent's own timeout. Dart reaches the same closing logic from
        // its 10-minute timer; expireConfirmTimeoutForTesting() is that shared
        // closing logic, so "timeout is not a user refusal" stays true on the
        // wire path too (the label is only used for the log line).
        flow.expireConfirmTimeoutForTesting(flow.pendingConfirmCommand ?? "");
      }
      return {ok: true, confirmId: pendingId, woken: wasPending};
    },
  );

  if (opts.verbose) {
    console.error("[agent-core] server started on stdio");
  }
  return server;
}

// Dart exposes the same seam (pendingConfirmForTesting /
// expireConfirmTimeoutForTesting, agent_engine.dart:483 / :450): the parent
// app drives the flow through rpc:confirm, tests reach the instance here.
export function confirmFlowForTesting(): ConfirmFlow | null {
  return confirmFlow;
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

export {
  ConfirmFlow,
  CONFIRM_TIMEOUT_MS,
  BLOCKED_COMMAND_REASONS,
  isBlockedCommandReason,
  CONFIRM_REASON_GENERATION_INVALID,
  CONFIRM_REASON_CANCELLED,
  CONFIRM_REASON_TIMEOUT,
  CONFIRM_REASON_USER_REJECTED,
  CONFIRM_REASON_PERMISSION_CHANGED,
  formatObservationFailure,
} from "./react/confirm_flow.js";
export type {
  BlockedCommandReason,
  ConfirmOutcomeKind,
  CommandConfirmOutcome,
  ConfirmRequestShape,
  ConfirmFlowContext,
  ConfirmFlowEvents,
  ConfirmTimerHandle,
  ConfirmFlowOptions,
} from "./react/confirm_flow.js";

export {ReActEngine} from "./react/engine.js";
export {buildDefaultToolRegistry} from "./tools/index.js";
export type {HealthParams, HealthResult, ToolHealth, LlmHealth} from "./rpc/schema.js";
export type {PlatformProfile} from "./tools/platform.js";
export {MOBILE_SAFE_TOOLS, DESKTOP_ONLY_TOOLS, toolsForPlatform} from "./tools/platform.js";
export {shouldUseNodeAgent, rolloutFraction} from "./utils/rollout.js";
export type {RolloutOptions} from "./utils/rollout.js";
