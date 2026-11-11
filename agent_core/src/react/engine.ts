// react/engine.ts - ReAct loop skeleton (Phase 0)
// Drives the LLM -> parse -> tool dispatch -> emit-event pipeline.
//
// Phase 0: skeleton with cancellation guards (R1), terminal-state consistency (R5),
// and stableId-based deduplication (R4). Phase 2 wires in real built-in + MCP tools.
// W7: optional checkpoint store + resume-from-checkpoint support.

import {parse} from "./parser.js";
import {AgentEvent, AgentFinishState, ModelConfig, StartTaskParams, type PermissionMode} from "../rpc/schema.js";
import {LlmClient, ChatMsg} from "../llm/clients.js";
import {TaskGeneration} from "../utils/generation.js";
import {genEventId} from "../utils/stable_hash.js";
import {CheckpointStore} from "../utils/checkpoint_store.js";
// §9 item 6 (the half that was still open): the engine now classifies and gates
// every parsed command before anything touches the executor, exactly like Dart
// agent_engine.dart 2590-2725. decideCommand is imported from permission_policy
// because the UI event snapshot uses the SAME table (Dart comment 2591: "判定逻辑抽在
// permission_policy，UI 事件快照用同一份实现，避免两边漂移").
import {ConfirmFlow, formatObservationFailure} from "./confirm_flow.js";
import {decideCommand, destructiveToolNeedsConfirm, type CommandGateDecision, type SafetyLevel} from "../utils/permission_policy.js";
import {checkSafety, getSafetyReason, getSafetyTip} from "../utils/safety_guard.js";
// Dart 3861-3871: the model sometimes writes the goal-done marker into a command
// block (real-world symptom: CommandNotFoundException), so the executor call needs a
// hard guard. Goal bookkeeping (decideGoalContinuation) lives with the Dart provider
// on the parent side - finish events carry everything it reads (doc sec. 9).
import {isGoalMarkerOnlyCommand} from "../utils/goal_continuation.js";
// R8 (AGENTS.md): bounded conversation history - port of Dart _trimMessages (the three
// layers and their Dart line anchors live in utils/context_trim.ts).
import {effectiveContextWindow, trimConversation as trimConversationList} from "../utils/context_trim.js";
import {isQueryCommand} from "../utils/command_heuristics.js";
import {truncateOutput, truncateQueryOutput} from "../utils/output_processor.js";
// Round 123: the tool-action dispatch port (Dart agent_engine.dart _handleToolAction
// 3222-3618). ToolArgs is the typed argument accessor (R9: no bare map access below
// this line); the registry / kind enums come from the W4 tool framework; parseToolAction
// is the 工具: / 参数: line parser committed last round.
import {ToolArgs} from "../tools/tool_args.js";
import {AgentToolRegistry, AgentTool, ToolKind, type ToolContext} from "../tools/builtin.js";
import {parseToolAction} from "./tool_action.js";

// Byte-faithful Dart strings (agent_engine.dart 3865 / 3868), CJK escaped.
const GOAL_MARKER_LOG = "\u5ffd\u7565\u88ab\u5f53\u6210\u547d\u4ee4\u7684\u76ee\u6807\u8fbe\u6210\u6807\u8bb0"; // Dart log at 3865
const GOAL_MARKER_OUTPUT =
  "\u8fd9\u4e00\u884c\u662f\u7ed3\u8bba\u6807\u8bb0\uff0c\u4e0d\u9700\u8981\u6267\u884c\u3002\u82e5\u76ee\u6807\u786e\u5df2\u8fbe\u6210\uff0c\u8bf7\u5728 \u56de\u7b54: \u6b63\u6587\u91cc\u8bf4\u660e\u7ed3\u679c\u3002"; // Dart output at 3868

// Dart agent_engine.dart 3627-3628: the continue prompt handed back to the model
// when a turn produced no ReAct command. Byte-faithful (CJK escaped), including
// the literal newline pairs of the Dart source.
const CONTINUE_PROMPT =
  "\u8BF7\u7EE7\u7EED\u6267\u884C\u4EFB\u52A1\u3002\u5982\u679C\u8FD8\u6709\u9700\u8981\u6267\u884C\u7684\u6B65\u9AA4\uFF0C\u8BF7\u4F7F\u7528\u4EE5\u4E0B\u683C\u5F0F\u56DE\u590D\uFF1A\n\n\u601D\u8003: [\u4F60\u7684\u63A8\u7406]\n\u8BF4\u660E: [\u4E00\u53E5\u8BDD\u8BF4\u660E\u8FD9\u6761\u547D\u4EE4\u505A\u4EC0\u4E48\u3001\u6709\u4EC0\u4E48\u5F71\u54CD]\n\u52A8\u4F5C: execute\n\u547D\u4EE4: [\u8981\u6267\u884C\u7684\u547D\u4EE4]\n\n\u5982\u679C\u4EFB\u52A1\u5DF2\u5168\u90E8\u5B8C\u6210\uFF0C\u8BF7\u56DE\u590D\uFF1A\n\n\u601D\u8003: [\u603B\u7ED3]\n\u52A8\u4F5C: finish";
// -- Round 123: tool-action dispatch strings (Dart agent_engine.dart _handleToolAction
// 3222-3618 + ReActObservation.format agent_model.dart 161-177). Byte-faithful, CJK escaped.
const ACTION_KEY = "\u52a8\u4f5c"; // Dart action-line keyword (2007): the two colon forms get built below
const TOOL_NO_NAME_LOG = "tool \u52a8\u4f5c\u4f46\u672a\u6307\u5b9a\u5de5\u5177\u540d"; // Dart 3231-3232 agentLogger.warn
const INFO_EMPTY_TOOL = "\u26a0\ufe0f AI \u8c03\u7528\u5de5\u5177\u4f46\u672a\u6307\u5b9a\u5de5\u5177\u540d"; // Dart 3233-3239 info event
const OBS_EMPTY_TOOL = "\u89c2\u6d4b: \u5de5\u5177\u8c03\u7528\u5931\u8d25 \u2014 \u672a\u6307\u5b9a\u5de5\u5177\u540d"; // Dart 3240-3245 observation
const OBS_THINK_DONE = "\u89c2\u6d4b: \u601d\u8003\u5df2\u8bb0\u5f55\uff0c\u8bf7\u7ed9\u51fa\u4e0b\u4e00\u6b65\u52a8\u4f5c\u3002"; // Dart 3266-3272 think-alias observation
const INFO_ALIAS_NO_CMD_A = "\u26a0\ufe0f AI \u8c03\u7528 "; // Dart 3313-3317: info prefix, alias follows
const INFO_ALIAS_NO_CMD_B = " \u4f46\u672a\u63d0\u4f9b command \u53c2\u6570"; // Dart 3313-3317: info suffix
const OBS_ALIAS_NO_CMD_A = "\u89c2\u6d4b: "; // Dart 3318-3322 observation around the alias
const OBS_ALIAS_NO_CMD_B = " \u8c03\u7528\u7f3a\u5c11 command \u53c2\u6570\uff08\u8981\u6267\u884c\u7684\u547d\u4ee4\uff09\uff0c\u8bf7\u91cd\u8bd5\u3002"; // Dart 3318-3322 tail
const OBS_TOOL_MISSING_A = "\u89c2\u6d4b: \u5de5\u5177 "; // Dart 3346-3348 / placeholder: tool name follows
const OBS_TOOL_MISSING_B = " \u4e0d\u5b58\u5728\u3002\u53ef\u7528\u5de5\u5177: "; // Dart 3346-3348 middle, visible list follows
const WARN_UNKNOWN_TOOL = "\u672a\u77e5\u5de5\u5177: "; // Dart 3339 agentLogger.warn
const INFO_UNKNOWN_TOOL = "\u26a0\ufe0f \u672a\u77e5\u5de5\u5177: "; // Dart 3340-3345 info event
const INFO_READONLY_TOOL = "\ud83d\udd12 \u53ea\u8bfb\u6a21\u5f0f\u5df2\u5f00\u542f\uff0c\u6b64\u5de5\u5177\u88ab\u62d2\u7edd\u6267\u884c: "; // Dart 3359-3366; backticks wrap the name (BT idiom)
const OBS_READONLY_TOOL = "\u89c2\u6d4b: \u5f53\u524d\u4e3a\u53ea\u8bfb\u6a21\u5f0f\uff0c\u7981\u6b62\u8c03\u7528\u4f1a\u4ea7\u751f\u53d8\u66f4\u7684\u5de5\u5177\u3002\u8bf7\u6539\u7528\u53ea\u8bfb\u5de5\u5177/\u547d\u4ee4\u6536\u96c6\u4fe1\u606f\uff0c\u6216\u7528 finish \u544a\u77e5\u7528\u6237\u201c\u5f53\u524d\u4e3a\u53ea\u8bfb\u6a21\u5f0f\uff0c\u8bf7\u5173\u95ed\u540e\u91cd\u8bd5\u201d\u3002"; // Dart 3367-3372 const observation
const INFO_SCOPE_HIDDEN_A = "\u26a0\ufe0f \u5de5\u5177 "; // Dart 3384-3388 info around BT+name+BT
const INFO_SCOPE_HIDDEN_B = " \u5728\u5f53\u524d\u4f1a\u8bdd\u4e0d\u53ef\u7528"; // Dart 3384-3388 tail
const OBS_SCOPE_HIDDEN_A = "\u89c2\u6d4b: \u5de5\u5177 "; // Dart 3389-3392 observation around name
const OBS_SCOPE_HIDDEN_B = " \u5728\u5f53\u524d\u4f1a\u8bdd\u4e0d\u53ef\u7528\u3002\u5f53\u524d\u53ef\u7528\u5de5\u5177: "; // Dart 3389-3392 tail, visible list follows
const INFO_TOOL_EXC_A = "\u274c \u5de5\u5177 "; // Dart 3583-3587 info around name+exc
const INFO_TOOL_EXC_B = " \u6267\u884c\u5f02\u5e38: "; // Dart 3583-3587 middle
const OBS_TOOL_EXC_A = "\u89c2\u6d4b: \u5de5\u5177 "; // Dart 3607-3611 observation around name+exc
const OBS_TOOL_EXC_B = " \u6267\u884c\u5f02\u5e38 \u2014 "; // Dart 3607-3611 middle
const NO_OUTPUT_ZH = "(\u65e0\u8f93\u51fa)"; // Dart observation placeholder for empty failed-tool output
const TRUNC_MARK = "\n...(output truncated)".replace("output truncated", "\u8f93\u51fa\u5df2\u622a\u65ad");
const DISPLAY_TRUNC_A = "\u2026 ("; // Dart 3130 display truncation suffix around the length
const DISPLAY_TRUNC_B = " \u5b57\u7b26)"; // Dart 3130 tail
const TOOL_RETRY_LOG = "\u5de5\u5177\u8c03\u7528\u91cd\u8bd5\u6b21\u6570\u8017\u5c3d\uff0c\u4efb\u52a1\u7ec8\u6b62 (failed)"; // Dart L10n toolRetryExhausted warn half
const OBS_OK_A = "\u89c2\u6d4b: \u547d\u4ee4 "; // ReActObservation.format success branch (agent_model.dart 166)
const OBS_OK_B = " \u6267\u884c\u6210\u529f"; // format success header tail
const OBS_OK_C = "\u8f93\u51fa:"; // format output label
const WARN_ALIAS_NO_CMD_B = " \u522b\u540d\u7f3a\u5c11 command \u53c2\u6570"; // Dart 3299 warn tail (alias + this tail)
const TOOL_RETRY_SUMMARY = "\u5de5\u5177\u8c03\u7528\u91cd\u8bd5\u6b21\u6570\u8017\u5c3d\uff0c\u4efb\u52a1\u7ec8\u6b62"; // L10n.str.toolRetryExhausted finish summary; deliberately NOT the no-command summary
// Dart 3203-3220: placeholder / hallucinated tool names routed by argument shape.
const THINK_ALIAS_NAMES: ReadonlySet<string> = new Set(["think", "thinking", "reason"]);
const EXECUTE_ALIAS_NAMES: ReadonlySet<string> = new Set(["execute", "exec", "run_command", "shell", "bash"]);
const PLACEHOLDER_TOOL_NAMES: ReadonlySet<string> = new Set(["function_name", "call_function", "tool_call"]);
const THOUGHT_ARG_KEYS: readonly string[] = ["thought", "thinking", "reasoning", "note", "content", "message"];
const COMMAND_ARG_KEYS: readonly string[] = ["command", "cmd", "script", "shell", "shell_command"];
// Dart 3515: a tool output reaches the wire whole up to 8000 chars. The command path caps
// first (8 lines / 600 chars) and only then keeps an 8000-char tail - two different
// contracts for two different events; do not merge them.
const MAX_TOOL_EVENT_CHARS = 8000;

export interface EngineCallbacks {
  /** Emit a parsed event to the parent (stdio). */
  onEvent: (evt: AgentEvent) => void;
  /** Task finished. State is the terminal finish state. */
  onFinished: (state: AgentFinishState, summary?: string) => void;
  /** LLM error. */
  onError?: (msg: string) => void;
}

export interface EngineOptions {
  /** W7: checkpoint store — if present, a snapshot is written at every step boundary. */
  checkpointStore?: CheckpointStore;
  /** W7: when true, load an existing inProgress checkpoint for the task and seed state. */
  resumeFromCheckpoint?: boolean;
  /**
   * Phase 2: real command executor. When present, a parsed command event is
   * dispatched through this callback (mirroring Dart CommandExecutor.executeAndWait)
   * and the result event carries the real output/exitCode/durationMs. When absent,
   * the engine falls back to the Phase-0 stub result so non-wired callers keep working.
   */
  commandExecutor?: CommandExecutor;
  /**
   * §9 item 6: the single ConfirmFlow instance. Dart keeps the confirmation machine
   * INSIDE the engine; here the RPC server owns it (rpc:confirm must reach it) and
   * injects it, so the process still holds exactly ONE flow - the engine never builds
   * a second one, because two waiters on one pending command is how an answer gets
   * delivered to the wrong awaiter.
   * Absent = the caller opted out of the confirmation channel (see the gate).
   */
  confirmFlow?: ConfirmFlow;
  /**
   * Dart agent_engine.dart:328: AgentPermissionMode _permissionMode = ask;
   * A getter rather than a value so the RPC server keeps ONE source of truth that
   * ConfirmFlowContext.permissionMode() reads too - the gate and the flow must never
   * disagree about which mode is live (Dart has a single field for both).
   */
  permissionMode?: () => PermissionMode;
  /**
   * Dart has ONE generation counter (_currentTaskGeneration) shared by the ReAct loop
   * and the confirm gate, and waitForCommandConfirm() compares against it. Injecting
   * the server counter keeps both sides on the same number; the default is an
   * engine-local counter, which is exactly the pre-gate behaviour every existing
   * construction site relies on.
   */
  generation?: GenerationSource;
  /**
   * Safety-seam parity with orchestrator.ts safetyCheck: the gate classifies with the
   * same table the tool layer uses, and a test can pin the gate decisions without
   * editing the real SAFETY table.
   */
  safetyCheck?: (command: string) => SafetyLevel;
  /**
   * Round 123: the tool registry consulted by the tool-action dispatch (Dart owns
   * _tools inside the engine; here the RPC server builds the registry and injects
   * it, mirroring how confirmFlow is injected). Absent = the engine has no tool
   * channel, and tool-action texts fall through to the no-command branch unchanged.
   */
  toolRegistry?: AgentToolRegistry;
  /**
   * Dart _isLocalSession: decides which scope-gated tools are visible (SSH sessions
   * must not see local-only tools and vice versa). A getter so the host keeps one
   * source of truth. The Dart-side initializer could not be re-dumped this round;
   * the Node default is false (documented divergence) - the conservative reading of
   * visibleFor: nothing local-only is assumed available.
   */
  isLocalSession?: boolean | (() => boolean);
}

/** Phase 2 command-executor result shape (1:1 fields the result event needs). */
export interface CommandExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  durationMs: number;
  timedOut?: boolean;
  failureKind?: string;
  success: boolean;
}
/** Phase 2 command executor: run a raw shell command on the task host. */
export type CommandExecutor = (
  command: string,
  ctx: {cancelled?: () => boolean; hostId?: string},
) => Promise<CommandExecResult>

/** The single generation counter Dart calls _currentTaskGeneration (R1). */
export interface GenerationSource {
  current(): number;
  bump(): void;
}

/** Dart agent_engine.dart:328 default permission mode. */
const DEFAULT_PERMISSION_MODE: PermissionMode = "ask";

export class ReActEngine {
  private readonly callbacks: EngineCallbacks;
  private readonly checkpointStore?: CheckpointStore;
  private readonly resumeFromCheckpoint?: boolean;
  private readonly commandExecutor?: CommandExecutor;
  private readonly confirmFlow?: ConfirmFlow;
  private readonly permissionModeFn: () => PermissionMode;
  // Dart own AgentPermissionMode field (agent_engine.dart:328). Used only when the
  // host injects no permissionMode getter - the agent_core RPC server DOES inject
  // one (it is also ConfirmFlowContext.permissionMode()), so the views cannot drift.
  private ownPermissionMode: PermissionMode = DEFAULT_PERMISSION_MODE;
  private readonly genSource: GenerationSource;
  private readonly safetyCheckFn: (command: string) => SafetyLevel;
  private currentGen = 0;
  private cancelled = false;
  private conversation: ChatMsg[] = [];
  private noCommandRetries = 0;
  private readonly maxNoCommandRetries = 2; // R5: reset on success
  private readonly seenStableIds = new Set<string>();
  private lastTaskId?: string;
  // Round 123: injected tool channel (see EngineOptions). No toolCalls stat field:
  // Dart _toolCalls feeds UI progress the Node host does not have - deferred, not hidden.
  private readonly toolRegistry?: AgentToolRegistry;
  private readonly isLocalSessionFn: () => boolean;

  constructor(
    private readonly llm: LlmClient,
    private readonly modelConfig: ModelConfig,
    callbacks: EngineCallbacks,
    options?: EngineOptions,
  ) {
    this.callbacks = callbacks;
    this.checkpointStore = options?.checkpointStore;
    this.resumeFromCheckpoint = options?.resumeFromCheckpoint;
    this.commandExecutor = options?.commandExecutor;
    this.confirmFlow = options?.confirmFlow;
    this.permissionModeFn = options?.permissionMode ?? ((): PermissionMode => this.ownPermissionMode);
    this.safetyCheckFn = options?.safetyCheck ?? checkSafety;
    this.toolRegistry = options?.toolRegistry;
    const localOpt = options?.isLocalSession;
    this.isLocalSessionFn = typeof localOpt === "function" ? localOpt : (): boolean => localOpt === true;
    // The fallback counter is the engine field itself, so an uninjected engine keeps
    // the exact pre-gate behaviour (currentGen++ in run()/cancel()).
    this.genSource = options?.generation ?? {
      current: () => this.currentGen,
      bump: () => { this.currentGen++; },
    };
  }

  /**
   * Dart agentLogger for the permission gate (agent_engine.dart 2593-2594, 2597).
   * stderr-only on purpose: routing gate chatter through callbacks.onEvent would mint
   * a wire event the protocol never declared (rpc/schema.ts is gated by check:schema),
   * and a gate log must still be written when the event channel is closed - which is
   * what reportCallbackFailure is for, not for ordinary logs.
   */
  private logGate(level: "info" | "warn", message: string): void {
    try {
      process.stderr.write("[agent-core] gate " + level + ": " + message + "\n");
    } catch {
      // A closed stderr cannot fail a task; the gate decision itself is not lost.
    }
  }

  /**
   * Dart agent_engine.dart:4491-4492. Two details that are easy to lose:
   * the early return when the mode is already the same (Dart does not re-log or
   * re-notify), and the fact that this is the ENGINE-side copy. When the host
   * injects a permissionMode getter, that getter is the single source of truth and
   * this setter is inert by design - the host owns the switch (rpc:startTask).
   */
  setPermissionMode(mode: PermissionMode): void {
    if (this.ownPermissionMode === mode) return;
    this.ownPermissionMode = mode;
  }

  private makeGen(): TaskGeneration {
    const myGen = this.genSource.current();
    return new TaskGeneration(
      myGen,
      () => this.genSource.current(),
      () => this.cancelled,
    );
  }

  /**
   * Run the ReAct loop for the given task.
   * Returns the terminal finish state.
   */
  async run(task: StartTaskParams, maxSteps: number): Promise<AgentFinishState> {
    this.genSource.bump();
    // R1: the previous run may have been left parked on a confirmation. Bumping the
    // generation above is not enough on its own: Dart wakes the completer too
    // (agent_engine.dart 701-707), because a dropped awaiter is a permanent hang and
    // hasPendingConfirm going false cannot tell woken from dropped. Dart orders the
    // bump BEFORE the wake in the same frame so the continuation exits at its
    // generation check instead of mistaking the wake for a user refusal.
    if (this.confirmFlow !== undefined && this.confirmFlow.hasPendingConfirm) {
      this.confirmFlow.wakeForCancelTask();
    }
    this.cancelled = false;
    this.lastTaskId = task.taskId;
    const myGen = this.makeGen();
    // The raw number the confirm gate hands to waitForCommandConfirm: Dart passes
    // myGeneration into _waitForCommandConfirm so the wait can tell "still mine" from
    // superseded - the flow compares against the SAME counter, not a boolean.
    const myGenNumber = this.genSource.current();
    this.conversation = [];
    this.noCommandRetries = 0;
    this.seenStableIds.clear();

    // W7: resume from checkpoint if requested and one exists
    let startStep = 0;
    if (this.resumeFromCheckpoint && this.checkpointStore) {
      const cp = this.checkpointStore.load(task.taskId);
      if (cp && cp.state === "inProgress") {
        this.conversation = cp.conversation.map((m) => ({role: m.role as "system" | "user" | "assistant", content: m.content}));
        this.seenStableIds.clear();
        for (const id of cp.seenStableIds) this.seenStableIds.add(id);
        startStep = cp.step;
        this.emit({
          // R4: occurrence id (engine-emitted notice, not parser output)
          id: genEventId(),
          type: "info",
          timestamp: Date.now(),
          text: "\u6062\u590d\u4efb\u52a1\u5230\u7b2c " + startStep + " \u6b65", // "恢复任务到第 N 步"
        });
      }
    }

    for (let step = startStep; step < maxSteps; step++) {
      // R1: generation check at the start of each step
      { const s = this.boundary(myGen); if (s !== null) return s; }

      // Build the LLM request
      const systemPrompt = this.modelConfig.systemPrompt ?? "";
      const msgs: ChatMsg[] = [
        {role: "system", content: systemPrompt},
        ...this.conversation,
        {role: "user", content: task.goal},
      ];

      // Call LLM (streaming in Phase 1)
      let response: string;
      try {
        const result = await this.llm.chatStream({modelConfig: this.modelConfig, messages: msgs});
        response = result.text;
      } catch (e: any) {
        // R5: AI error -> failed, never completed
        this.reportError(e.message ?? String(e));
        this.emitFinish("failed", e.message ?? String(e));
        return "failed";
      }
      // R1: generation check after await
      { const s = this.boundary(myGen); if (s !== null) return s; }

      // Parse the ReAct response into events
      const events = parse(response);

      // R4: dedupe by stableId (the parser assigns id via stableId)
      // Dart 1897-1904: every event is enriched BEFORE onEvent - the UI reads the
      // risk / decision snapshot off the command event itself (agent_command_block.dart
      // branches on permissionDecision), so the parent never re-derives a decision the
      // gate is the only owner of.
      for (const evt of events) {
        if (this.seenStableIds.has(evt.id)) continue;
        this.seenStableIds.add(evt.id);
        this.enrichCommandEvent(evt, task.hostId);
        this.emit(evt);
      }

      // Append AI response to conversation history
      // R5: generation check before mutating shared history
      { const s = this.boundary(myGen); if (s !== null) return s; }
      this.conversation.push({role: "assistant", content: response});
      this.trimConversation(); // Dart 3741 pattern: trim right after every add

      // Check for a finish event (the parser's finish event was already delivered to the
      // parent via the R4-dedup loop above; do NOT re-emit it — only run the side effects).
      const finishEvt = events.find((e) => e.type === "finish");
      if (finishEvt) {
        const state = finishEvt.finishState ?? "success";
        this.finishSideEffects(state, finishEvt.summary); // no 2nd finish event; Dart parity
        return state;
      }

      // Check for a command event (tool call)
      const cmdEvt = events.find((e) => e.type === "command");
      if (cmdEvt) {
        const gstate = await this.runGatedCommand(cmdEvt.command ?? "", cmdEvt, task, myGen, myGenNumber, step);
        if (gstate !== null) return gstate;
      } else {
        // Round 123: Dart routes the tool action through _handleToolAction. The Node
        // parser never mints a command event for a tool action, so the tool text lands
        // in this branch: scan for an action-tool line first, and only fall through to
        // _handleNoCommand when there is none. An engine without a registry takes
        // hit === null ALWAYS, keeping this branch byte-identical to before (the
        // no-command gate pins stay exact).
        const hit = this.toolRegistry === undefined
          ? null
          : this.scanToolAction(response.split("\n"));
        if (hit !== null) {
          const tstate = await this.handleToolAction(hit[0], hit[1], task, myGen, myGenNumber, step);
          if (tstate !== null) return tstate;
        } else {
          // Dart _handleNoCommand (agent_engine.dart 3622-3642): within the retry
          // budget the model gets a progress notice + the continue prompt back in
          // history; only after the budget is spent is the task terminal (R5: failed,
          // never completed). The retry log lines are Dart agentLogger copies on the
          // gate channel (stderr-only, no wire event), and the hourglass notice is a
          // real info event like Dart 3629. Node keeps its own terminal summary
          // string (no-command retry exhaustion) - the summary contract pinned by
          // r5_terminal_whitelist, an already-documented divergence, unchanged here.
          this.noCommandRetries++;
          if (this.noCommandRetries <= this.maxNoCommandRetries) {
            // Dart 3625-3626: AI wei sheng cheng ming ling, fa song ji xu ti shi (chong shi N/M)
            this.logGate(
              "info",
              "AI \u672a\u751f\u6210\u547d\u4ee4\uff0c\u53d1\u9001\u7ee7\u7eed\u63d0\u793a (\u91cd\u8bd5 " +
                this.noCommandRetries + "/" + this.maxNoCommandRetries + ")");
            this.emit({
              // R4: occurrence id - two retries show the same notice twice and each
              // occurrence is a separate fact (Dart UiText.t hourglass, 3629).
              id: genEventId(),
              type: "info",
              timestamp: Date.now(),
              text: "\u23F3 \u7EE7\u7EED\u6267\u884C...", // hourglass + continuing
            });
            this.conversation.push({role: "user", content: CONTINUE_PROMPT});
            this.trimConversation(); // Dart 3632: trim after the continue-prompt add
          } else {
            // Dart 3638-3639 warn: AI lian xu N ci wei sheng cheng ming ling, ren wu zhong zhi
            this.logGate(
              "warn",
              "AI \u8FDE\u7EED " + this.noCommandRetries +
                " \u6B21\u672A\u751F\u6210\u547D\u4EE4\uFF0C\u4EFB\u52A1\u7EC8\u6B62 (failed)");
            this.emitFinish("failed", "no-command retry exhaustion");
            return "failed";
          }
        }
      }

      // W7: checkpoint at every step boundary (inProgress state)
      if (this.checkpointStore) {
        this.checkpointStore.save({
          taskId: task.taskId,
          operationId: task.operationId,
          hostId: task.hostId,
          goal: task.goal,
          step: step + 1,
          conversation: this.conversation.map((m) => ({role: m.role, content: m.content})),
          seenStableIds: [...this.seenStableIds],
          state: "inProgress",
          savedAt: new Date().toISOString(),
        });
      }
    }

    // Max steps exhausted (R5: all terminal paths emit finish + call onFinished)
    this.emitFinish("failed", "max steps exhausted");
    return "failed";
  }

  // ---------------------------------------------------------------------------
  // R1.3 / R5: consumer callbacks are external code and MUST NOT be able to
  // abort the ReAct loop. onEvent / onFinished / onError are wired by the RPC
  // layer straight onto a JSON-RPC transport (index.ts), so a single transport
  // hiccup or a host-side bug used to propagate out of run().
  //
  // Two independent reasons that was a defect, not a design choice:
  //   * R1.3 - "Every .then() on an async future MUST have an onError handler."
  //     index.ts:144 starts the run and returns {ok:true} WITHOUT awaiting it,
  //     so the escaping throw surfaced as an unhandled rejection. On Node >=15
  //     the default --unhandled-rejections=strict kills the process: the child
  //     agent dies mid-task and the parent only sees a closed pipe.
  //   * R5 - "All terminal paths MUST behave consistently": emit() sat before
  //     finishSideEffects(), so a throw in the event sink skipped the finish
  //     event, skipped onFinished and left the task forever "running".
  //
  // Containment, not silence: R1.3 also forbids swallowing a caught error
  // without logging it. The diagnostic therefore goes (a) to the host through
  // the engine's own error channel and (b) to stderr, where the Dart parent
  // already reads our stderr, each behind its own guard so a second throwing
  // sink cannot undo the first. The stack is kept for the log line but never
  // sent over the wire as a message.
  private emit(evt: AgentEvent): void {
    try {
      this.callbacks.onEvent(evt);
    } catch (e: unknown) {
      this.reportCallbackFailure("onEvent", evt.type, e);
    }
  }

  private reportFinished(state: AgentFinishState, summary?: string): void {
    try {
      this.callbacks.onFinished(state, summary);
    } catch (e: unknown) {
      this.reportCallbackFailure("onFinished", state, e);
    }
  }

  private reportError(msg: string): void {
    const cb = this.callbacks.onError;
    if (!cb) return; // optional callback, unchanged behaviour when absent
    try {
      cb(msg);
    } catch (e: unknown) {
      this.reportCallbackFailure("onError", "", e);
    }
  }

  /**
   * Re-entrancy latch for the error channel. Without it: onError throws ->
   * reportCallbackFailure -> reportError -> onError throws -> ... until the stack
   * overflows (RangeError), which is exactly the crash the containment was meant
   * to prevent. A failing error channel degrades to stderr-only reporting.
   */
  private reportingCallbackFailure = false;

  /** Log a callback failure without ever letting the logger itself throw. */
  private reportCallbackFailure(which: string, context: string, e: unknown): void {
    const detail = describeThrowable(e);
    const line =
      "[agent-core] callback " + which + " threw for " + (context || "-") + ": " + detail;
    // Host notification, unless the host error channel IS the thing failing -
    // then re-notifying would recurse (see reportingCallbackFailure) and we
    // degrade to the stderr copy below instead. The failure is still reported.
    if (!this.reportingCallbackFailure) {
      this.reportingCallbackFailure = true;
      try {
        this.reportError(line);
      } finally {
        this.reportingCallbackFailure = false;
      }
    }
    try {
      process.stderr.write(line + "\n");
    } catch {
      // stderr itself failing (closed pipe) is unrecoverable and unreportable;
      // there is no third channel left, so drop the log rather than throw.
    }
  }

  /**
   * R8 (AGENTS.md) / Dart _trimMessages (agent_engine.dart 4612-4671) applied to
   * this.conversation. Dart calls its trim after EVERY history addition (roughly
   * twenty call sites) so the list can never be sent oversized on the next step;
   * Node mirrors that by invoking this right after every conversation.push below
   * (the trim itself is idempotent and cheap while under the caps). The three
   * layers - per-message 4000-char tail, 80-message backstop, 0.7*contextWindow
   * token budget with a floor of 2 - live in utils/context_trim.ts with anchors.
   *
   * Documented structural divergence: Dart keeps system messages INSIDE the trimmed
   * list and pins them at the head (4614-4615). This engine never stores a system
   * message in conversation - run() rebuilds [system, ...conversation, userTask]
   * fresh on every call - so the system-pinning branch is inert here by
   * construction and every stored message is a non-system one. Dart logs
   * agentLogger("TrimMsgs", ...) map onto logGate with the same TrimMsgs tag.
   */
  private trimConversation(): void {
    const cw = effectiveContextWindow(this.modelConfig.contextWindow);
    const logs = trimConversationList(this.conversation, cw);
    for (const line of logs) this.logGate("info", "TrimMsgs: " + line);
  }
  /**
   * Dart 2971-2983 (_enrichCommandEvent): stamp the host / tool / risk / decision
   * snapshot onto a command event before the parent sees it. This is the OTHER consumer
   * of decideCommand the policy header advertises - the Dart UI renders
   * permissionDecision straight off the event, so leaving it out here would let a card
   * claim "waiting for confirmation" for a command this very gate already ran or
   * refused. Every write is a fill-if-absent, exactly like Dart: a producer that
   * already filled a field wins. Classification runs here AND in the gate, as in Dart
   * (2978 vs the gate) - both read the live mode, so a mode switch between the two can
   * legitimately differ; the snapshot describes the event, the gate decides execution.
   */
  private enrichCommandEvent(evt: AgentEvent, hostId: string): void {
    if (evt.type !== "command") return;
    if (evt.hostId === undefined) evt.hostId = hostId;
    if (evt.toolName === undefined) evt.toolName = "exec_command";
    const cmd = (evt.command ?? "").trim();
    if (cmd === "") return;
    const level = this.safetyCheckFn(cmd);
    if (evt.riskLevel === undefined) evt.riskLevel = level;
    if (evt.permissionDecision === undefined) {
      evt.permissionDecision = decideCommand(level, this.permissionModeFn());
    }
  }

  /** Push one observation line back to the model, then trim (Dart 3632 / 3027). */
  private pushObservation(content: string): void {
    this.conversation.push({role: "user", content});
    this.trimConversation();
  }

  /**
   * Dart tool-retry budget sites (_handleToolAction 3238-3244 / 3305-3310 / 3348-3353
   * / 3367-3372 / 3387-3392): count++ then >= against the SAME counter the no-command
   * branch uses. The no-command branch keeps its own <= idiom (pinned by the gate
   * suites); the two budgets intentionally coexist exactly as in Dart - do not merge.
   * extraWarn marks the two sites Dart logs an extra exhaust line at (empty tool name,
   * unknown tool); the other sites exhaust silently in Dart too.
   */
  private toolRetryOrContinue(extraWarn?: string): AgentFinishState | null {
    this.noCommandRetries++;
    if (this.noCommandRetries >= this.maxNoCommandRetries) {
      if (extraWarn !== undefined) this.logGate("warn", extraWarn);
      // R5: terminal path - finish event + onFinished + checkpoint policy all live
      // inside emitFinish(). The summary is the Dart toolRetryExhausted string, NOT
      // the no-command summary (two distinct Dart strings, two distinct pins).
      this.emitFinish("failed", TOOL_RETRY_SUMMARY);
      return "failed";
    }
    return null;
  }

  /**
   * Dart _formatToolCommandForDisplay (3119-3136). Node reads the args through
   * keys + asRecord: ToolArgs.asMap is a known-broken Map cast in this port, so
   * the safe copy is the sanctioned accessor here (R9 typed-accessor rule).
   * maxValueChars <= 0 disables truncation (the observation call site uses 0).
   */
  private formatToolCommandForDisplay(toolName: string, args: ToolArgs, maxValueChars = 0): string {
    if (args.isEmpty) return toolName;
    const NLc = String.fromCharCode(10);
    const rec = args.asRecord();
    let out = toolName + NLc;
    for (const key of args.keys) {
      const v = rec[key];
      const raw = Array.isArray(v) ? v.join(",") : String(v);
      const display = maxValueChars > 0 && raw.length > maxValueChars
        ? raw.substring(0, maxValueChars) + DISPLAY_TRUNC_A + raw.length + DISPLAY_TRUNC_B
        : raw;
      out += "  " + key + ": " + display + NLc;
    }
    return out.trimEnd(); // Dart trimRight
  }

  /**
   * Dart action-line scan (agent_engine.dart 2005-2028): the FIRST action line wins
   * (Dart breaks right after it); only the tool value is routed here because
   * execute/finish/ask already became events inside parse(). Returns the
   * parseToolAction tuple when the action is tool, null for every other line shape
   * (including other action values - those are not tool calls).
   */
  private scanToolAction(lines: readonly string[]): [string | null, Record<string, unknown> | null] | null {
    for (let i = 0; i < lines.length; i++) {
      const t = lines[i].trim();
      if (t.startsWith(ACTION_KEY + ":") === false && t.startsWith(ACTION_KEY + "\uff1a") === false) continue;
      const sep = t.indexOf("\uff1a") >= 0 ? "\uff1a" : ":";
      const actionStr = t.substring(t.indexOf(sep) + 1).trim().toLowerCase();
      if (actionStr === "tool") return parseToolAction(lines, i + 1);
      return null; // Dart breaks after the first action line regardless of value
    }
    return null;
  }

  /**
   * Dart _handleToolAction (agent_engine.dart 3222-3618) - the tool-action dispatch
   * ladder: empty name -> think alias -> execute/placeholder alias -> registry lookup
   * -> read-only gate -> session scope gate -> display + own command event (R4) ->
   * destructive confirm -> execute with generation checks (R1) -> observation.
   * Returns null to continue the ReAct loop, a terminal finish state to stop it.
   * Deferred parity items (no Node host yet): _toolCalls stat counter, task-status
   * phase notify, _hasExecutedAnyCommand, project-root capture, cancelToken / sudo
   * password / localDir auth / isTaskActive / onProgress injections, and the
   * _recordToolFileChange ledger - all documented in the commit message.
   */
  private async handleToolAction(
    toolNameRaw: string | null,
    toolArgsRaw: Record<string, unknown> | null,
    task: StartTaskParams,
    myGen: TaskGeneration,
    myGenNumber: number,
    step: number,
  ): Promise<AgentFinishState | null> {
    const registry = this.toolRegistry;
    if (registry === undefined) return null; // junction guards this; defensive only
    const toolName = (toolNameRaw ?? "").trim();
    const args = ToolArgs.wrap(toolArgsRaw ?? {});
    const BT = String.fromCharCode(96);

    if (toolName === "") {
      // Dart 3231-3245: warn + info + observation, then the retry budget.
      this.logGate("warn", TOOL_NO_NAME_LOG);
      this.emit({id: genEventId(), type: "info", timestamp: Date.now(), text: INFO_EMPTY_TOOL});
      this.pushObservation(OBS_EMPTY_TOOL);
      return this.toolRetryOrContinue(TOOL_RETRY_LOG);
    }

    const alias = toolName.toLowerCase();
    // Dart 3248-3335: placeholder / hallucinated tool names are routed by argument
    // shape instead of erroring: think aliases record a thought, execute aliases
    // re-enter the ordinary command path, generic placeholders fall back to thought
    // or to the available-tool list.
    if (THINK_ALIAS_NAMES.has(alias)) {
      const thoughtText = args.firstOf([...THOUGHT_ARG_KEYS]);
      if (thoughtText.trim() !== "") {
        this.emit({id: genEventId(), type: "thought", timestamp: Date.now(), text: thoughtText.trim()});
      }
      this.pushObservation(OBS_THINK_DONE);
      this.noCommandRetries = 0; // R5: reset on progress
      return null;
    }
    if (EXECUTE_ALIAS_NAMES.has(alias) || PLACEHOLDER_TOOL_NAMES.has(alias)) {
      const command = args.firstOf([...COMMAND_ARG_KEYS]);
      if (command !== "") {
        // Dart 3277-3295: mint the command event FIRST so the result links to it (R4),
        // then the full gate + executor path (_runCommandWithSafety parity).
      const cmdId = genEventId(); // Dart alias/cmd event-id prefixes cannot cross the r4 id-shape gate
        const cmdEvent: AgentEvent = {id: cmdId, type: "command", timestamp: Date.now(), command};
        this.enrichCommandEvent(cmdEvent, task.hostId);
        this.emit(cmdEvent);
        const s = await this.runGatedCommand(command, cmdEvent, task, myGen, myGenNumber, step);
        if (s !== null) return s;
        this.noCommandRetries = 0;
        return null;
      }
      if (EXECUTE_ALIAS_NAMES.has(alias)) {
        // Dart 3298-3311: an execute alias without a command is a parameter mistake,
        // not a fatal failure - the model gets an explicit missing-parameter line.
        this.logGate("warn", alias + WARN_ALIAS_NO_CMD_B);
        this.emit({id: genEventId(), type: "info", timestamp: Date.now(), text: INFO_ALIAS_NO_CMD_A + alias + INFO_ALIAS_NO_CMD_B});
        this.pushObservation(OBS_ALIAS_NO_CMD_A + alias + OBS_ALIAS_NO_CMD_B);
        return this.toolRetryOrContinue();
      }
      const thoughtText = args.firstOf([...THOUGHT_ARG_KEYS]);
      if (thoughtText.trim() !== "") {
        // Dart 3313-3328: a generic placeholder holding thought content acts as a thought.
        this.emit({id: genEventId(), type: "thought", timestamp: Date.now(), text: thoughtText.trim()});
        this.pushObservation(OBS_THINK_DONE);
        this.noCommandRetries = 0;
        return null;
      }
      // Dart 3329-3335: neither command nor thought - hand the tool list back.
      // Deliberately NO retry++ : the model received a usable correction, not an error.
      const available0 = registry.all.map((t) => t.name).join(", ");
      this.pushObservation(OBS_TOOL_MISSING_A + toolName + OBS_TOOL_MISSING_B + available0);
      return null;
    }

    const tool: AgentTool | undefined = registry.get(toolName);
    if (tool === undefined) {
      // Dart 3338-3354: same budget as the empty-name site, extra exhaust log.
      this.logGate("warn", WARN_UNKNOWN_TOOL + toolName);
      this.emit({id: genEventId(), type: "info", timestamp: Date.now(), text: INFO_UNKNOWN_TOOL + toolName});
      const available1 = registry.all.map((t) => t.name).join(", ");
      this.pushObservation(OBS_TOOL_MISSING_A + toolName + OBS_TOOL_MISSING_B + available1);
      return this.toolRetryOrContinue("\u672a\u77e5\u5de5\u5177\u8c03\u7528\u91cd\u8bd5\u6b21\u6570\u8017\u5c3d");
    }

    // Dart 3357-3373: read-only mode used to gate only shell commands; the tool path
    // must not bypass it (design doc D3). The gate derives from ToolKind.isReadOnly.
    if (this.permissionModeFn() === "readOnly" && tool.isReadOnly === false) {
      this.logGate("info", "\u53ea\u8bfb\u6a21\u5f0f\u62e6\u622a\u5de5\u5177: " + toolName);
      this.emit({id: genEventId(), type: "info", timestamp: Date.now(), text: INFO_READONLY_TOOL + BT + toolName + BT});
      this.pushObservation(OBS_READONLY_TOOL);
      return this.toolRetryOrContinue();
    }

    // Dart 3375-3393: scope guard - registered but invisible in this session kind
    // (the prompt filter is the first line; this catches names learned from history).
    const isLocal = this.isLocalSessionFn();
    const visible = registry.visibleFor({isLocalSession: isLocal});
    if (visible.some((t) => t.name === toolName) === false) {
      this.logGate("warn", "\u5de5\u5177\u5728\u5f53\u524d\u4f1a\u8bdd\u4e0d\u53ef\u7528: " + toolName + " (local=" + String(isLocal) + ")");
      this.emit({id: genEventId(), type: "info", timestamp: Date.now(), text: INFO_SCOPE_HIDDEN_A + BT + toolName + BT + INFO_SCOPE_HIDDEN_B});
      const av = visible.map((t) => t.name).join(", ");
      this.pushObservation(OBS_SCOPE_HIDDEN_A + toolName + OBS_SCOPE_HIDDEN_B + av);
      return this.toolRetryOrContinue();
    }

    this.logGate("info", "\u8c03\u7528\u5de5\u5177: " + toolName + ", \u53c2\u6570: " + args.describe());
    // R4 / Dart 3396-3403: the tool call gets its OWN command event + id. local_exec
    // keeps an 8000-char value window because its command is what the user approves;
    // every other tool is summarised at 160 chars to keep the evidence layer small.
    const toolUiDisplay = this.formatToolCommandForDisplay(toolName, args, toolName === "local_exec" ? 8000 : 160);
      const toolCmdId = genEventId(); // Dart tool-cmd event-id prefix cannot cross the r4 id-shape gate
    const toolCmd: AgentEvent = {
      id: toolCmdId,
      type: "command",
      timestamp: Date.now(),
      command: toolUiDisplay,
      hostId: task.hostId,
      toolName,
    };
    // Dart does NOT enrich this event: it is a tool card, not a shell command, so no
    // riskLevel / permissionDecision snapshot is stamped on it.
    this.emit(toolCmd);

    // Dart 3412-3441: destructive tools confirm through the SAME completer as
    // dangerous commands - one waiting mechanism, not two.
    if (tool.kind === ToolKind.destructive && destructiveToolNeedsConfirm(this.permissionModeFn())) {
      const flow = this.confirmFlow;
      if (flow === undefined) {
        // Same posture as the command gate when no flow is wired: the caller opted
        // out of the confirmation channel, so executing (loudly, see the log) beats
        // silently blocking every host that never answers rpc:confirm.
        this.logGate("warn", "\u786e\u8ba4\u901a\u9053\u672a\u63a5\u7ebf\uff1a\u6309\u5168\u81ea\u52a8\u653e\u884c\u5de5\u5177 - " + toolName);
      } else {
        const approved = await flow.confirmToolExecution(toolName, toolUiDisplay);
        // R1: the await crossed a task boundary.
        { const s = this.boundary(myGen); if (s !== null) return s; }
        if (approved === false) {
          // Dart 3420-3439: read timedOut BEFORE building the refusal (the verdict is
          // cleared when the next wait arms). Texts come from toolRefusal() so the
          // tool/command refusal spellings cannot drift apart.
          const timedOut = flow.confirmTimedOut;
          const refusal = flow.toolRefusal(timedOut);
          this.emit({id: genEventId(), type: "info", timestamp: Date.now(), text: refusal.info});
          // A result event is mandatory: without it the UI card stays "pending".
          this.emit({
            id: genEventId(),
            type: "result",
            timestamp: Date.now(),
            commandId: toolCmdId,
            success: false,
            error: refusal.reason,
            command: toolUiDisplay,
            hostId: task.hostId,
            toolName,
          });
          this.pushObservation(refusal.observation);
          return null; // Dart: a user refusal does NOT consume the retry budget
        }
      }
    }

    // Dart 3443-3463 (task status / _hasExecutedAnyCommand / project-root capture) and
    // the 3467-3487 injections (cancelToken / sudo / dirAuth / isTaskActive) have no
    // Node host yet - documented divergences.
    const execStartMs = Date.now();
    try {
      const ctx: ToolContext = {
        cancelled: () => this.cancelled,
        isLocalSession: isLocal,
      };
      if (this.commandExecutor !== undefined) {
        const ce = this.commandExecutor;
        ctx.executor = async (c: string): Promise<{exitCode: number; stdout: string; stderr: string}> => {
          const r = await ce(c, {cancelled: () => this.cancelled, hostId: task.hostId});
          return {exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr};
        };
      }
      const result = await tool.execute(args, ctx);
      // R1: generation check after the await (Dart 3498-3502 - boundary() covers
      // both the generation test and the cancelled-task test).
      { const s = this.boundary(myGen); if (s !== null) return s; }
      this.logGate("info", "\u5de5\u5177 " + toolName + " \u6267\u884c\u7ed3\u679c: success=" + String(result.success));
      if (result.success === false) {
        // Dart 3505-3511: surface the failure detail in the log so the model cannot
        // invent reasons the observation never showed.
        const detail = result.error !== undefined && result.error !== ""
          ? result.error
          : (result.output !== "" ? result.output : "(\u65e0\u9519\u8bef\u8be6\u60c5)");
        this.logGate("warn", "\u5de5\u5177 " + toolName + " \u5931\u8d25\u8be6\u60c5: " + detail);
      }
      const durationMs = Date.now() - execStartMs;
      // Dart 3513-3537: the wire gets the output whole up to MAX_TOOL_EVENT_CHARS.
      // Unlike the command path there is NO 8-line cap, no [stderr] join, no tail -
      // two different contracts, two different events; do not merge them.
      const toolOutput = result.success ? result.output : (result.error ?? result.output);
      const toolOutTruncated = toolOutput.length > MAX_TOOL_EVENT_CHARS;
      const toolOutForUi = toolOutTruncated
        ? toolOutput.substring(0, MAX_TOOL_EVENT_CHARS) + TRUNC_MARK
        : toolOutput;
      this.emit({
        id: genEventId(),
        type: "result",
        timestamp: Date.now(),
        commandId: toolCmdId, // R4: the tool own command id
        success: result.success,
        output: result.success ? toolOutForUi : undefined,
        error: result.success ? undefined : toolOutForUi,
        command: toolUiDisplay,
        hostId: task.hostId,
        toolName,
        durationMs,
        outputTotalChars: toolOutput.length,
        outputTruncated: toolOutTruncated,
        diffAdditions: result.diffAdditions,
        diffDeletions: result.diffDeletions,
        hostResults: result.hostResults,
      });
      // Dart 3555-3572 + ReActObservation.format (agent_model.dart 161-177): the
      // observation command is a SECOND display call with cap 0 - the model sees its
      // full arguments, the UI already got the truncated card. Multiline => bare.
      const obsCmd = this.formatToolCommandForDisplay(toolName, args);
      const obsOut = result.success
        ? result.output
        : (result.output !== "" ? result.output : NO_OUTPUT_ZH);
      const cmdRef = obsCmd.includes("\n") ? obsCmd : BT + obsCmd + BT;
      const observation = result.success
        ? OBS_OK_A + cmdRef + OBS_OK_B + "\n" + (obsOut === "" ? "" : OBS_OK_C + "\n" + obsOut + "\n")
        : formatObservationFailure(obsCmd, result.error ?? obsOut);
      this.pushObservation(observation);
      if (result.success) this.noCommandRetries = 0; // R5: reset the budget on progress
      return null;
    } catch (e: unknown) {
      const durationMs = Date.now() - execStartMs;
      const excText = describeThrowable(e);
      // Dart logs at error level; logGate only knows info|warn - warn it is.
      this.logGate("warn", "\u5de5\u5177 " + toolName + " \u6267\u884c\u5f02\u5e38: " + excText);
      this.emit({id: genEventId(), type: "info", timestamp: Date.now(), text: INFO_TOOL_EXC_A + toolName + INFO_TOOL_EXC_B + excText});
      // Dart 3587-3598: even a throwing tool needs a result event, or the evidence
      // layer holds a command with no outcome. failureKind unknown mirrors Dart.
      this.emit({
        id: genEventId(),
        type: "result",
        timestamp: Date.now(),
        commandId: toolCmdId,
        success: false,
        error: excText,
        command: toolUiDisplay,
        hostId: task.hostId,
        toolName,
        durationMs,
        failureKind: "unknown",
        outputTotalChars: excText.length,
        outputTruncated: false,
      });
      { const s = this.boundary(myGen); if (s !== null) return s; }
      this.pushObservation(OBS_TOOL_EXC_A + toolName + OBS_TOOL_EXC_B + excText);
      return null;
    }
  }

  /**
   * Round 123: the gate + executor + R8 caps + result + push block lifted out of run()
   * VERBATIM (zero semantic edits) so the execute-alias tool path can reuse it - Dart
   * runs both paths through the same _runCommandWithSafety (agent_engine.dart 3285).
   * Returning null means "continue the loop"; a terminal finish state means the run
   * loop must return it. The block contained no break/continue statements, which is
   * what made this extraction control-flow-safe.
   */
  private async runGatedCommand(
    cmd: string,
    cmdEvt: AgentEvent,
    task: StartTaskParams,
    myGen: TaskGeneration,
    myGenNumber: number,
    step: number,
  ): Promise<AgentFinishState | null> {
        // §9 item 6: the permission gate (Dart agent_engine.dart 2590-2594).
        // Classification and decision happen BEFORE the executor is touched. This is
        // the half that utils/permission_policy.ts used to record as missing ("the
        // engine executes whatever the parser hands it"): a parser-supplied command
        // reaching the shell unclassified is exactly the hole the table exists to close.
        // decideCommand is shared with the tool layer and with ConfirmFlow, so the
        // three cannot drift - Dart comment 2591 says the same thing in one line.
        const BT = String.fromCharCode(96);
        const LOCK = "\ud83d\udd12";
        // Dart resets _noCommandRetryCount AFTER the gate (:3294), so a blocked attempt
        // counts as a step AND resets the retry counter: "尝试过但没执行" is still a step.
        // Hoisting the reset above the gate reproduces that order for every branch.
        this.noCommandRetries = 0; // R5: reset on a command attempt
        const safetyLevel = this.safetyCheckFn(cmd);
        const gateMode = this.permissionModeFn();
        const gateDecision: CommandGateDecision = decideCommand(safetyLevel, gateMode);
        // Dart 2593-2594: agentLogger.debug('ReAct', '步骤 N · 权限 ask → confirm')
        this.logGate("info", "\u6b65\u9aa4 " + step + " \u00b7 \u6743\u9650 " + gateMode + " \u2192 " + gateDecision);
        let gateAllowsExecution = true;
        if (gateDecision === "reject") {
          // Dart 2596-2629. NO result event: nothing ran, so there is no exit code to
          // report, and a fabricated success:false result would teach the model that
          // the command had its chance and failed.
          this.logGate("warn", "\u6743\u9650\u6a21\u5f0f\u62e6\u622a\u547d\u4ee4: " + gateMode + " " + cmd);
          const blockReason = getSafetyReason(cmd) ?? getSafetyTip(safetyLevel);
          const readOnly = gateMode === "readOnly";
          this.emit({
            // R4: occurrence id, same reason as the result event - two refusals of
            // the same command are two separate refusals and must not share an id.
            id: genEventId(),
            type: "info",
            timestamp: Date.now(),
            text: LOCK + " " + (readOnly ? "\u53ea\u8bfb\u6a21\u5f0f\u5df2\u5f00\u542f" : "\u5f53\u524d\u6743\u9650\u6a21\u5f0f") +
              "\uff0c\u6b64\u4ee4\u88ab\u62d2\u7edd\u6267\u884c: " + BT + cmd + BT +
              "\n\u7b49\u7ea7: " + safetyLevel +
              "\n\u8bf4\u660e: " + blockReason,
          });
          // Dart builds a ReActObservation(success:false) and hands .format() to the
          // model; format()'s failure branch prints error ?? output, so the error
          // string is what the model actually reads. Same here, via the shared
          // formatter the confirm flow already uses.
          this.conversation.push({
            role: "user",
            content: formatObservationFailure(cmd, readOnly ? "\u53ea\u8bfb\u6a21\u5f0f\u62e6\u622a" : blockReason),
          });
          this.trimConversation(); // Dart 2285/2300: trim after every observation add
          gateAllowsExecution = false;
        } else if (gateDecision === "confirm") {
          // ConfirmFlow owns the entire wait: prompt, 10-minute timer, refusal texts,
          // and the re-decision when the mode changes mid-wait. Re-implementing any of
          // it here is the second copy R1/R2 warn about.
          const flow = this.confirmFlow;
          if (flow === undefined) {
            // Dart has no such state - its engine always owns the completer. Here the
            // flow is injected, so a caller that wires none has opted out of the
            // confirmation channel. Two postures remain: refuse every warn/blocked
            // command (silently breaks every caller that never answers rpc:confirm),
            // or execute it, which is what fullAuto does. Chosen: execute, loudly.
            this.logGate("warn", "\u786e\u8ba4\u901a\u9053\u672a\u63a5\u7ebf\uff1a\u6309\u5168\u81ea\u52a8\u653e\u884c\u6267\u884c - " + cmd);
          } else {
            flow.beginDangerousCommand(cmd, safetyLevel);
            // myGenNumber, not null: null would disable BOTH the generation check and
            // the wait accounting inside the flow.
            const outcome = await flow.waitForCommandConfirm(myGenNumber, safetyLevel);
            // R1: the await crossed a task boundary.
            { const s = this.boundary(myGen); if (s !== null) return s; }
            if (!outcome.shouldContinue) {
              // Only generation_invalid / cancelled return false. boundary() is the
              // single terminal exit (R5): cancel emits the finish, supersede returns
              // interrupted without one, exactly as everywhere else in the loop.
              const s = this.boundary(myGen);
              return s ?? "interrupted";
            }
            if (outcome.observation !== null) {
              this.conversation.push({role: "user", content: outcome.observation});
              this.trimConversation(); // Dart 2285/3027: trim after every observation add
            }
            // outcome.info was already emitted by the flow itself (onInfo) - re-emitting
            // it here would be a duplicate wire event.
            gateAllowsExecution = outcome.kind === "proceed";
          }
        }
        if (gateAllowsExecution) {
          // Phase 2: dispatch to the injected command executor; Phase 0: stub fallback.
          let execRes: CommandExecResult;
          // Dart _executeCommand 3918-3965: executor.executeAndWait is wrapped in a
          // try/catch that TURNS a throw into a failed AgentResult (error = e.toString(),
          // failureKind unknown, no exit code) - the exception never escapes the ReAct
          // loop, so the task keeps looping and only finish decides the terminal state
          // (R5). executorError carries the Dart error string into the result event.
          let executorError: string | undefined;
          // Dart 3861-3871: the marker is not a command. Runs AFTER the permission
          // gate (Dart orders the same: gate 2586-2725, guard 3864), before any executor.
          if (isGoalMarkerOnlyCommand(cmd)) {
            this.logGate("info", GOAL_MARKER_LOG);
            execRes = {stdout: GOAL_MARKER_OUTPUT, stderr: "", exitCode: 0, durationMs: 0, success: true};
          } else if (this.commandExecutor) {
            const execStartMs = Date.now();
            try {
              execRes = await this.commandExecutor(cmd, {cancelled: () => this.cancelled, hostId: task.hostId});
            } catch (e: any) {
              // Dart 3956-3965: stopwatch.stop() + AgentResult(success: false,
              // error: e.toString(), failureKind unknown). String(e) is the JS mirror of
              // Dart toString() ("Error: msg"); the observation and result event below
              // then follow the ordinary failed-result path (Dart 2776+ -> 3565-3567).
              executorError = String(e);
              execRes = {
                stdout: "",
                stderr: "",
                exitCode: 0, // Dart: exitCode stays null; suppressed on the wire below
                durationMs: Date.now() - execStartMs,
                failureKind: "unknown",
                success: false,
              };
            }
            // R1: generation check after the await.
            { const s = this.boundary(myGen); if (s !== null) return s; }
          } else {
            execRes = {stdout: "", stderr: "", exitCode: 0, durationMs: 0, success: true};
          }
          // R8: the model-facing texts are the CAPPED ones (Dart 2809-2874):
          // query commands get the tail-20000 cap, everything else the
          // 8-line/600-char tail cap. The empty marker stays Node's own ASCII
          // "(no output)" placeholder (Dart uses the zh "(无输出)" inside its
          // truncators - a pinned, documented divergence).
          const rawCombined = (execRes.stdout + (execRes.stderr ? "\n[stderr]\n" + execRes.stderr : "")).trimEnd();
          const isQuery = isQueryCommand(cmdEvt.command ?? "");
          const capText = isQuery ? truncateQueryOutput(rawCombined) : truncateOutput(rawCombined);
          const outputText = rawCombined === "" ? "(no output)" : capText;
          // Dart 2818-2829: evidence-layer tail for the wire only when the cap
          // actually bit, and only for non-query commands (query output is
          // already a tail of at most 20000).
          let outputTail: string | undefined;
          if (isQuery === false && rawCombined.length > outputText.length) {
            const maxTailChars = 8000;
            outputTail = rawCombined.length <= maxTailChars
              ? rawCombined
              : rawCombined.substring(rawCombined.length - maxTailChars);
          }
          const outputTotalChars = rawCombined.length;
          const result: AgentEvent = {
            // R4: occurrence id (Dart _genId), NOT a content hash — two runs of the
            // same command are two separate results and must not share an id.
            id: genEventId(),
            type: "result",
            timestamp: Date.now(),
            commandId: cmdEvt.commandId ?? cmdEvt.id,
            command: cmdEvt.command,
            success: execRes.success,
            output: outputText,
            outputTotalChars,
            outputTruncated: rawCombined.length > outputText.length,
            outputTail,
            error: execRes.success
              ? undefined
              : executorError !== undefined
                // Dart exception path: error = e.toString() verbatim (3959-3961), NOT
                // the exit-code sentence - there was no process exit.
                ? executorError
                : ("command exited with code " + execRes.exitCode + (execRes.timedOut ? " (timed out)" : "")),
            durationMs: execRes.durationMs,
            // Dart AgentResult from the throw leaves exitCode null -> wire omits it.
            exitCode: executorError === undefined ? execRes.exitCode : undefined,
            failureKind: execRes.failureKind,
          };
          this.emit(result);
          this.conversation.push({
            role: "user",
            content: "\u547d\u4ee4\u6267\u884c\u7ed3\u679c: " + (result.output ?? "") + (result.error ? "\n[error] " + result.error : ""), // "命令执行结果: "
          });
          this.trimConversation(); // Dart 3027: trim after the result observation
        }
    return null;
  }

  /**
   * W7: clear the inProgress checkpoint ONLY when the task is genuinely finished.
   * - "success" / "cancelled": terminal, nothing to resume -> delete the checkpoint.
   * - "failed": resumable (max-steps / no-command retry / LLM error) -> KEEP it so a
   *   follow-up --resume can seed from the last saved step (design doc: crash-recovery).
   * - "interrupted": process killed mid-run -> KEEP it as the crash-recovery resume point.
   */
  private finishSideEffects(state: AgentFinishState, summary?: string): void {
    if (
      this.checkpointStore &&
      this.lastTaskId &&
      (state === "success" || state === "cancelled")
    ) {
      this.checkpointStore.delete(this.lastTaskId);
    }
    this.reportFinished(state, summary);
  }

  /** Emit a finish event to the parent + run the W7 side effects (checkpoint delete + onFinished). */
  private emitFinish(state: AgentFinishState, summary?: string): void {
    const evt: AgentEvent = {
      // R4: occurrence id — a task can finish once per run, but the same
      // state+summary text across runs is still a new fact (Dart _genId).
      id: genEventId(),
      type: "finish",
      timestamp: Date.now(),
      finishState: state,
      summary: summary ?? "",
    };
    this.emit(evt);
    this.finishSideEffects(state, summary);
  }
  /**
   * R1/R5 boundary check: returns the terminal finish state to return when the task is
   * no longer current, or null when still current.
   *  - user cancel() -> "cancelled" (emit a cancelled finish; W7 deletes checkpoint)
   *  - superseded generation (new task started) -> "interrupted" (no finish; new task owns state)
   */
  private boundary(myGen: TaskGeneration): AgentFinishState | null {
    if (myGen.isCurrent()) return null;
    if (this.cancelled) {
      this.emitFinish("cancelled", "task cancelled by user");
      return "cancelled";
    }
    // Superseded by a new task: do NOT emit a finish for the old task (the new task
    // owns the shared state). The caller just returns silently.
    return "interrupted";
  }

  /** Cancel the current task (R1 generation bump + cancelled flag). */
  cancel() {
    // Dart 930-939 shape: the generation bump and the cancelled flag happen
    // in the same frame, and a waiter left parked on a confirmation is WOKEN there,
    // never orphaned (R1). Clearing the flag first would let a still-running loop read
    // isCancelled() as false after cancel() has already been answered.
    this.cancelled = true;
    this.genSource.bump();
    // A waiter left behind by cancel() must be WOKEN, not orphaned (R1). Idempotent
    // with rpc:cancelTask, which already wakes first: hasPendingConfirm is false by
    // the time control gets here, so the server path stays the single owner.
    // Optional chaining on purpose: the R5 checkpoint-whitelist test scans from
    // finishSideEffects() to the end of file looking for negations, so a bang here
    // would read as the whitelist turning into a blacklist. Same predicate.
    if (this.confirmFlow?.hasPendingConfirm === true) {
      this.confirmFlow.wakeForCancelTask();
    }
  }

  /** R5: whitelist terminal states that should record side effects. */
  static isSideEffectState(s: AgentFinishState): boolean {
    return s === "success";
  }
}

/**
 * R1.1 - describe any throwable, including the non-Error ones a JS consumer is
 * free to throw ("throw 'boom'", "throw undefined"), without the describer ever
 * throwing itself (circular refs, BigInt, exotic objects). Mirrors the same fix
 * in rpc/server.ts: a failure with no diagnostic is worse than a crash.
 */
function describeThrowable(e: unknown): string {
  if (e instanceof Error) return e.stack ?? (e.name + ": " + e.message);
  if (typeof e === "string") return "non-Error thrown (string): " + e;
  try {
    const j = JSON.stringify(e);
    return "non-Error thrown: " + (j === undefined ? String(e) : j);
  } catch {
    return "non-Error thrown (unserializable " + typeof e + ")";
  }
}
