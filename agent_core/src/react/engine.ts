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
// r133: the change-window (frozen-window) arm. utils/change_window.ts ported the Dart
// service in r132 with its refusal texts exported as constants, so this file - pinned
// ASCII-only by test/regression/r5_terminal_whitelist.test.ts - can compose the wire
// texts without carrying a single CJK byte of its own.
import {
  checkChangeWindowCommand,
  WINDOW_LOG_WARN,
  WINDOW_INFO_HEAD,
  WINDOW_INFO_TAIL,
  WINDOW_FALLBACK_REASON,
  type ChangeWindowCheck,
} from "../utils/change_window.js";
// r134: the audit-log layer. utils/audit_log.ts (this round) ports Dart's
// AuditLogger (audit_logger.dart 46-87) + the AuditLogsDao cache semantics
// (daos 982-1087) + the engine's _logCommand / _truncateForAudit helpers
// (agent_engine.dart 2450-2455, 2951-2955). CJK wire texts are exported
// constants, so this file stays ASCII-only; the store is injected by the
// host - an uninjected engine never touches persistence.
import {
  auditLog,
  selectAuditOutput,
  setAuditLogStore,
  AUDIT_WRITE_FAIL_PRE_PREFIX,
  AUDIT_WRITE_FAIL_BLOCKED_PREFIX,
  AUDIT_WRITE_FAIL_POST_PREFIX,
  type AuditLogStorePort,
} from "../utils/audit_log.js";
// block (real-world symptom: CommandNotFoundException), so the executor call needs a
// hard guard. Goal bookkeeping (decideGoalContinuation) lives with the Dart provider
// on the parent side - finish events carry everything it reads (doc sec. 9).
import {parseAnswerBlock, parseReportSections} from "../utils/answer_block.js";
import {TailTextBuffer} from "../utils/tail_buffer.js";
import {isGoalMarkerOnlyCommand} from "../utils/goal_continuation.js";
// R8 (AGENTS.md): bounded conversation history - port of Dart _trimMessages (the three
// layers and their Dart line anchors live in utils/context_trim.ts).
import {effectiveContextWindow, trimConversation as trimConversationList} from "../utils/context_trim.js";
import {isQueryCommand, isTaskComplete} from "../utils/command_heuristics.js";
import {truncateOutput, truncateQueryOutput} from "../utils/output_processor.js";
import {looksLikeLocalWindowsCommand} from "../utils/local_command_detector.js";
// Round 123: the tool-action dispatch port (Dart agent_engine.dart _handleToolAction
// 3222-3618). ToolArgs is the typed argument accessor (R9: no bare map access below
// this line); the registry / kind enums come from the W4 tool framework; parseToolAction
// is the 工具: / 参数: line parser committed last round.
import {ToolArgs} from "../tools/tool_args.js";
import {AgentToolRegistry, AgentTool, ToolKind, type ToolContext} from "../tools/builtin.js";
import {parseToolAction} from "./tool_action.js";
// Round 126: finish-body choice hijack (Dart agent_engine.dart 1423-1448 +
// _choiceRequestFromFinish 3034-3048). The detector is the 1:1 port of
// utils/choice_request_detector.dart that finds "please pick A or B" text the
// model wrote into the finish answer instead of a proper ask + options turn.
import {ChoiceRequestDetector, ChoiceRequest} from "../utils/choice_request_detector.js";
import {RollbackAdvisor} from "../utils/rollback_advisor.js";
import {agentLogger} from "../utils/agent_logger.js";
import {agentTracer, TraceEvent, TraceEventType} from "../utils/agent_tracer.js";

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
// Round 124: the ask-action / user-choice strings (Dart agent_engine.dart
// _handleAskAction 3052-3113 + wake sites 708-712 / 940-944 + selectChoice
// 1168-1174). Byte-faithful, CJK escaped. The waitingConfirm / thinking phase
// notify strings are NOT ported: Node has no AgentStatus task channel (commit).
const ASK_NO_OPTIONS_WARN = "ask \u52a8\u4f5c\u4f46\u65e0\u9009\u9879\uff0c\u89c6\u4e3a finish"; // Dart 3056 warn
const ASK_DETECTED_A = "\u68c0\u6d4b\u5230\u9009\u9879\uff0c\u6682\u505c\u7b49\u5f85\u7528\u6237\u9009\u62e9: "; // Dart 3062 info, options list follows
const USER_CANCEL_CHOICE_LOG = "\u7528\u6237\u53d6\u6d88\u9009\u62e9"; // Dart 3089 info (user cancelled the choice)
const USER_CHOSE_A = "\u7528\u6237\u9009\u62e9\u4e86: "; // Dart 3094 gate info prefix
const CHOSEN_INFO_A = "\ud83d\udc49 \u4f60\u9009\u62e9\u4e86: "; // Dart 3098 info (zh side only; no UiText.t in Node)
const OBS_CHOSEN_A = "\u89c2\u6d4b: \u7528\u6237\u9009\u62e9\u4e86 \""; // Dart 3101 observation head
const OBS_CHOSEN_B = "\""; // Dart 3101 observation tail
// Round 125: Dart anti-hallucination finish guard (agent_engine.dart 1450-1468).
// The guard is OFF by default (EngineOptions.hallucinationGuard) - the frozen
// r1_generation_check regression pins a bare finish with zero commands to
// success, so the Dart contract is opt-in. Strings byte-faithful to Dart:
// 1457-1458 warn, 1460 info, 1461-1466 user nudge.
const GUARD_WARN_A = 'AI \u672a\u6267\u884c\u4efb\u4f55\u547d\u4ee4\u5c31 finish\uff0c\u5f3a\u5236\u7ee7\u7eed (\u91cd\u8bd5 ';
const GUARD_WARN_B = '/';
const GUARD_WARN_C = ')';
const GUARD_INFO = '\u26a0\ufe0f AI \u672a\u5b9e\u9645\u6267\u884c\u547d\u4ee4\u5c31\u58f0\u79f0\u5b8c\u6210\uff0c\u8981\u6c42\u5b9e\u9645\u9a8c\u8bc1';
const GUARD_NUDGE = '\u4f60\u5c1a\u672a\u6267\u884c\u4efb\u4f55\u547d\u4ee4\u5c31\u58f0\u660e\u4efb\u52a1\u5b8c\u6210\uff0c\u8fd9\u4e0d\u88ab\u5141\u8bb8\u3002\u8bf7\u7acb\u5373\u4f7f\u7528 \u52a8\u4f5c: execute \u5b9e\u9645\u6267\u884c\u547d\u4ee4\u9a8c\u8bc1\u4f60\u7684\u5224\u65ad\uff0c\u6240\u6709\u7ed3\u8bba\u5fc5\u987b\u6709\u547d\u4ee4\u8f93\u51fa\u4f5c\u4e3a\u4f9d\u636e\u3002\u5982\u679c\u4efb\u52a1\u786e\u5b9e\u65e0\u9700\u6267\u884c\u547d\u4ee4\uff08\u5982\u7eaf\u89e3\u91ca/\u5206\u6790\uff09\uff0c\u8bf7\u5728\u601d\u8003\u4e2d\u660e\u786e\u8bf4\u660e\u4e3a\u4ec0\u4e48\u65e0\u9700\u6267\u884c\u547d\u4ee4\u3002';

// Dart agent_engine.dart 1429-1430 warn: finish-body choice hijack. The Dart
// interpolation prints a List.toString ("[a, b]" - bare, comma-space), so join
// with ", " inside brackets, same as ASK_DETECTED_A above.
const FINISH_CHOICE_WARN_A =
  "finish \u6b63\u6587\u5305\u542b\u9009\u62e9\u8bf7\u6c42\uff0c\u8f6c\u4e3a ask \u7b49\u5f85\u7528\u6237\u9009\u62e9: ";

// Round 127: terminal log line of the completion-sounding fallback. Dart 1470
// writes it through agentLogger.info('ReAct', ...); the engine's only log sink
// is logGate (stderr), so it maps to a gate info line.
const FINISH_INFO =
  "\u4EFB\u52A1\u5B8C\u6210 (AI \u8FD4\u56DE finish \u52A8\u4F5C)";

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
   * r135: the remote OS string for SSH executors (Dart executor.osInfo).
   * When set, the local-command-on-remote guard is active.
   */
  sshOsInfo?: string;
  /**
   * r138: connection checker - Dart 3876-3901 (_currentExecutor.isConnected +
   * _consecutiveConnFailures). When set, the engine checks connectivity before each
   * raw command execution. Disconnected + >= maxRetries returns a
   * CommandFailureKind.disconnected result without calling the executor.
   */
  connectionChecker?: (hostId: string) => boolean | Promise<boolean>;
  /** r138: max consecutive connection failures (Dart _maxConnFailRetries = 3). */
  maxConnFailRetries?: number;
  /**
   * r141: enable pre-snapshot rollback advisor (Dart 2740-2771).
   * When enabled, modification-type commands trigger a read-only snapshot
   * command before execution. Default: true.
   */
  enableRollbackSnapshot?: boolean;
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
   * r133: the change-window / frozen-window gate - Dart ChangeWindowService.checkCommand
   * (services/change_window_service.dart 135-153), called from agent_engine.dart 2573-2575.
   * Dart reads its own static cache; the Node default is the module store of
   * utils/change_window.ts, which is DISABLED until a settings port is injected
   * (setChangeWindowStore), so wiring the arm changes nothing for a host that never
   * configures a window. The seam also lets a test inject a window without touching the
   * module store - the same reason safetyCheck above exists.
   */
  changeWindowCheck?: (command: string) => ChangeWindowCheck;
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
  /**
   * Round 125: Dart _hasExecutedAnyCommand anti-hallucination finish guard
   * (agent_engine.dart 1450-1468, counters 251-252, reset 662-663, set sites
   * 2388/3452). When true, a finish action is REFUSED up to
   * maxFinishWithoutExecRetries (2) times unless at least one command or tool
   * has actually executed; the model gets a nudge user message demanding real
   * verification and the refused finish event is suppressed on the wire (Dart
   * only ever emits finish through _finishTask). Default false: the frozen
   * r1_generation_check regression pins a command-less finish to success, so
   * enabling the guard is a host decision, not an engine default.
   */
  /**
   * r134: the audit-log store seam - Dart AuditLogsDao (daos 982-1087) is a
   * static cache + SQLite DAO; the Node host injects a port that owns the
   * persistence half. With no port the engine keeps the in-memory cache and
   * the audit warns never fire from persistence - identical to the r133
   * change-window posture. setAuditLogStore is the module-level setter the
   * host calls at boot; EngineOptions.auditLogStore wires the same port
   * into this engine instance.
   */
  auditLogStore?: AuditLogStorePort;
  /**
   * Round 125: the anti-hallucination finish guard (Dart _hasExecutedAnyCommand
   * 1450-1468). Off by default: the frozen r1_generation_check regression pins
   * a command-less finish to success, so enabling the guard is a host decision.
   */
  hallucinationGuard?: boolean;
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
private readonly sshOsInfo?: string; // r135: remote OS for local-command guard
private readonly connectionChecker?: (hostId: string) => boolean | Promise<boolean>;
private readonly maxConnFailRetries: number; // r138: Dart _maxConnFailRetries = 3
private consecutiveConnFailures = 0; // r138: Dart _consecutiveConnFailures
  private readonly enableRollbackSnapshot: boolean; // r141: Dart 2740-2771
  private readonly confirmFlow?: ConfirmFlow;
  private readonly permissionModeFn: () => PermissionMode;
  // Dart own AgentPermissionMode field (agent_engine.dart:328). Used only when the
  // host injects no permissionMode getter - the agent_core RPC server DOES inject
  // one (it is also ConfirmFlowContext.permissionMode()), so the views cannot drift.
  private ownPermissionMode: PermissionMode = DEFAULT_PERMISSION_MODE;
  private readonly genSource: GenerationSource;
  private readonly safetyCheckFn: (command: string) => SafetyLevel;
  private readonly changeWindowCheckFn: (command: string) => ChangeWindowCheck;
  private cancelled = false;
  private conversation: ChatMsg[] = [];
  private noCommandRetries = 0;
  private currentGen = 0; // r134: generation counter the default genSource closes over
  // Dart 275 (_maxAccumulatedChars) + 61-65: the whole-task accumulator behind
  // _accumulatedMessage, the last-resort finish text (3733). Dart appends every
  // streamed chunk (1784); Node writes each whole turn. TailTextBuffer evicts
  // the head past the cap (R8). Dart's setter (67-71, used by the error path
  // 1354) has no Node counterpart: the error paths pass their own message.
  private readonly maxAccumulatedChars = 20000;
  private readonly accumulatedBuffer = new TailTextBuffer(this.maxAccumulatedChars);

  // Dart 65: `_accumulatedMessage => _accumulatedMessageBuffer.tail()`.
  private get accumulatedMessage(): string {
    return this.accumulatedBuffer.tail();
  }

  private readonly maxNoCommandRetries = 2; // R5: reset on success
  private readonly seenStableIds = new Set<string>();
  private lastTaskId?: string;
  // Round 123: injected tool channel (see EngineOptions). No toolCalls stat field:
  // Dart _toolCalls feeds UI progress the Node host does not have - deferred, not hidden.
  private readonly toolRegistry?: AgentToolRegistry;
  private readonly isLocalSessionFn: () => boolean;
  // Round 124: the choice-wait state (Dart _pendingOptions 3064 / _choiceCompleter
  // 3065 / _pendingAskEvent 1906 / _lastResponseHadAskEvent 1879). No Completer in
  // Node: a Promise plus its captured resolve - resolve settles once by spec, so
  // the wake sites below need no isCompleted guard.
  private pendingOptionsList: string[] = [];
  private choiceCompleter: {resolve: (v: string) => void} | null = null;
  private pendingAskEvent: AgentEvent | null = null;
  private lastResponseHadAskEvent = false;
  // Round 125: anti-hallucination finish-guard state (Dart _hasExecutedAnyCommand
  // 251 / _finishWithoutExecCount 252 / reset 662-663, guard 1450-1468).
  private readonly hallucinationGuardEnabled: boolean;
  private hasExecutedAnyCommand = false;
  private finishWithoutExecCount = 0;
  private readonly maxFinishWithoutExecRetries = 2; // Dart _maxFinishWithoutExecRetries

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
this.sshOsInfo = options?.sshOsInfo;
    this.connectionChecker = options?.connectionChecker;
    this.maxConnFailRetries = options?.maxConnFailRetries ?? 3; // Dart 272
    this.enableRollbackSnapshot = options?.enableRollbackSnapshot ?? true; // Dart default: enabled
    this.confirmFlow = options?.confirmFlow;
    this.permissionModeFn = options?.permissionMode ?? ((): PermissionMode => this.ownPermissionMode);
    this.safetyCheckFn = options?.safetyCheck ?? checkSafety;
    // Dart calls ChangeWindowService.checkCommand with no seam at all; the seam here is for
    // the host store and for tests, mirroring how safetyCheck / toolRegistry arrive.
    this.changeWindowCheckFn = options?.changeWindowCheck ??
      ((command: string): ChangeWindowCheck => checkChangeWindowCommand(command));
    // r134: the host injects the store (Dart has no seam - its DAO is static);
    // the setter updates the module cache used by the auditLog() calls below.
    if (options?.auditLogStore !== undefined) setAuditLogStore(options.auditLogStore);
    this.toolRegistry = options?.toolRegistry;
    const localOpt = options?.isLocalSession;
    this.isLocalSessionFn = typeof localOpt === "function" ? localOpt : (): boolean => localOpt === true;
    this.hallucinationGuardEnabled = options?.hallucinationGuard === true;
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
  /** r143: Dart agentLogger.info('ReAct', msg) - the ReAct step logger. */
  private logReAct(message: string): void { agentLogger.info('ReAct', message); }
  /** r143: Dart agentLogger.info('AgentEngine', msg). */
  private logEngine(message: string): void { agentLogger.info('AgentEngine', message); }
  /** r143: Dart agentLogger.warn('ReAct', msg). */
  private logReActWarn(message: string): void { agentLogger.warn('ReAct', message); }
  /** r143: Dart agentLogger.error('ReAct', msg). */
  private logReActError(message: string): void { agentLogger.error('ReAct', message); }
  /** r143: Dart agentLogger.debug('ReAct', msg). */
  private logReActDebug(message: string): void { agentLogger.debug('ReAct', message); }

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
    // R1: the same wake precedent covers a choice wait left parked by the previous
    // run (Dart 708-712): resolve('') and clear the state, WITHOUT bumping the
    // generation again - the bump at the top of run() already invalidates the old
    // loop; the wake only frees its awaiter so it exits at its boundary check.
    this.wakeChoiceCompleterForCancel();
    this.cancelled = false;
    this.lastTaskId = task.taskId;
    this.logEngine("=== \u5f00\u59cb\u4efb\u52a1 ==="); // Dart 751: === 开始任务 ===
    agentTracer.emitSync(new TraceEvent({taskId: task.taskId, type: TraceEventType.taskStart, step: 0, payload: {goal: task.goal}}));
    const myGen = this.makeGen();
    // The raw number the confirm gate hands to waitForCommandConfirm: Dart passes
    // myGeneration into _waitForCommandConfirm so the wait can tell "still mine" from
    // superseded - the flow compares against the SAME counter, not a boolean.
    const myGenNumber = this.genSource.current();
    this.conversation = [];
    this.noCommandRetries = 0;
    // Round 125: Dart _resetTransientState 662-663 counterpart (the flag + retry
    // counters reset at every fresh task). Node has no pause/restore corridor, so
    // run-entry reset is the only reset site.
    this.hasExecutedAnyCommand = false;
    this.finishWithoutExecCount = 0;
    // Dart 660 (_resetTransientState) / 1256 (startTask): the accumulator is
    // transient state - each task starts empty, so the 3733 fallback can only
    // ever see THIS task's text.
    this.accumulatedBuffer.clear();
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

    this.logReAct("=== \u5f00\u59cb ReAct \u81ea\u52a8\u6267\u884c ==="); // Dart 1178
    for (let step = startStep; step < maxSteps; step++) {
      // R1: generation check at the start of each step
    this.logReAct("--- \u6b65\u9aa4 " + (step + 1) + " ---"); // Dart 1263
    agentTracer.emitSync(new TraceEvent({taskId: task.taskId, type: TraceEventType.step, step: step + 1}));
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
    agentTracer.emitSync(new TraceEvent({taskId: task.taskId, type: TraceEventType.aiCallStart, step: step + 1}));
    this.logReAct("\u8c03\u7528 AI \u6a21\u578b..."); // Dart 1595
    this.logReActDebug("\u6d88\u606f\u5386\u53f2: " + this.conversation.length + " \u6761"); // Dart 1596
      try {
        const result = await this.llm.chatStream({modelConfig: this.modelConfig, messages: msgs});
        response = result.text;
      } catch (e: any) {
        // R5: AI error -> failed, never completed
    this.logReActError("AI \u8c03\u7528\u5f02\u5e38: " + (e.message ?? String(e))); // Dart 1342
        this.reportError(e.message ?? String(e));
    agentTracer.emitSync(new TraceEvent({taskId: this.lastTaskId ?? '', type: TraceEventType.taskEnd}));
        this.emitFinish("failed", e.message ?? String(e));
        return "failed";
      }
    agentTracer.emitSync(new TraceEvent({taskId: task.taskId, type: TraceEventType.aiCallEnd, step: step + 1, payload: {prompt_tokens: 0, completion_tokens: 0}}));
      // R1: generation check after await

      // Dart 1782-1784: every streamed chunk also lands in the accumulator that
      // backs _accumulatedMessage. Node resolves the whole turn at once, so one
      // write holds the same characters; TailTextBuffer keeps the TAIL past the
      // cap (R8). After the generation check on purpose (R5: no shared-state
      // mutation before the check) - Dart appends inside the stream listener.
      this.accumulatedBuffer.write(response);
      { const s = this.boundary(myGen); if (s !== null) return s; }

      // Parse the ReAct response into events
      const events = parse(response);
      // Dart 2002-2004: the answer block and the operation-report four-field block
      // are cut from the RAW turn text once per turn, before the action scan.
      // Dart stores them on the ReActStep (2091-2092); Node keeps the same three
      // values turn-local, and the finish paths read them exactly like 1471-1482.
      const respLines = response.split("\n");
      const turnAnswer = parseAnswerBlock(respLines) ?? "";
      const turnSections = parseReportSections(respLines) ?? "";
      // Dart 2084: the NORMAL step's thought is `thought ?? ''` (only the
      // no-action fallbacks use `thought ?? content`, 2076/2048).
      const turnThought = events.find((e) => e.type === "thought")?.text ?? "";
      // Dart 1476-1478 + _composeFinishSummary 3729-3737: finish text = the
      // four-field block, else the thought, composed with the answer body.
      const turnFinishSummary = this.composeFinishSummary(
        turnSections !== "" ? turnSections : turnThought,
        turnAnswer,
      );
      // Dart 1879: did THIS parse produce an ask event? Dart guards its event-
      // synthesis fallback (1488-1498) with the flag. The Node parser mints an ask
      // event whenever options exist, so the fallback is dead code against it (not
      // ported, see the handleAskAction docs); the flag is kept for the accessor.
      this.lastResponseHadAskEvent = events.some((e) => e.type === "ask");

      // R4: dedupe by stableId (the parser assigns id via stableId)
      // Dart 1897-1904: every event is enriched BEFORE onEvent - the UI reads the
      // risk / decision snapshot off the command event itself (agent_command_block.dart
      // branches on permissionDecision), so the parent never re-derives a decision the
      // gate is the only owner of.
      for (const evt of events) {
        if (this.seenStableIds.has(evt.id)) continue;
        this.enrichCommandEvent(evt, task.hostId);
        // Dart 1904-1906: remember THIS turn's ask event - the user's choice is
        // written back onto the very question that was asked (handleAskAction),
        // never onto whatever arrived while the loop was parked. Only EMITTED
        // events qualify: the dedup guard above is part of the Dart shape.
        if (evt.type === "ask") this.pendingAskEvent = evt;
        // Round 125: guard ON and this finish WOULD be refused below (no command/
        // tool executed, retries not exhausted) -> suppress it on the wire.
        // Dart only ever emits finish through _finishTask (agent_engine.dart
        // 3762) - its parser never mints a finish event at all, so every refused
        // finish simply never existed there. Here the dedup decision and the
        // force-continue call the SAME helper in the SAME iteration (no await),
        // so suppression and refusal always agree. A SUPPRESSED finish must not
        // claim its stableId: the retried finish carries the same answerBody and
        // therefore the same stableId - marking it seen would silently swallow
        // the allowed finish on the wire (R5: every terminal path emits finish).
        // Round 126: a finish whose body asks the user to choose is NOT terminal -
        // the finish branch below hijacks it into an ask (Dart 1427-1448). Dart's
        // parser never mints finish events at all (finish only leaves through
        // _finishTask), so the wire suppression is Node-only, mirroring the
        // round-125 guard suppression exactly: SAME helper as the finish branch,
        // no await between the two call sites, and a suppressed finish must not
        // claim its stableId (the retried/allowed finish shares the id).
        if (this.finishChoiceHijack(evt, events, turnAnswer, response) !== null) continue;
        if (this.guardWillRefuseThisFinish(evt)) continue;
        if (evt.type === "finish" && (evt.finishState ?? "success") === "success") {
          // Dart 3751-3765: the ONE finish event on the wire carries the composed
          // summary (four-field block else thought, plus the answer body). Node's
          // parser mints the event itself (Dart's never does, so Dart has nothing
          // to rewrite), hence the in-place rewrite. The stableId was already
          // hashed from the parser text - R4's dedup key is untouched.
          evt.summary = turnFinishSummary;
        }
        this.seenStableIds.add(evt.id);
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
        // Round 126: Dart 1423-1448, BEFORE the anti-hallucination guard (1450).
        // The protocol says questions go through ask + options, but some models
        // write "please answer A or B" into the finish body: no buttons in the UI,
        // task ends before the user decides. Convert it into a real ask and keep
        // the loop alive after the choice. The dedup loop already suppressed this
        // finish on the wire via the SAME helper, so no half-terminal flicker.
        const hijack = this.finishChoiceHijack(finishEvt, events, turnAnswer, response);
        if (hijack !== null) {
          this.logGate("warn", FINISH_CHOICE_WARN_A + "[" + Array.from(hijack.choice.options).join(", ") + "]");
          if (!hijack.fromProtocol) {
            // Dart 1431-1437: the options: line made the streaming parser emit the
            // ask event already; options extracted from the BODY need a new event.
            const askEvent: AgentEvent = {
              id: genEventId(), // occurrence id like every engine-minted event (R4)
              type: "ask",
              timestamp: Date.now(),
              question: hijack.choice.question,
              options: Array.from(hijack.choice.options),
            };
            this.pendingAskEvent = askEvent; // Dart 1435 - pin it, then onEvent
            this.emit(askEvent);
          }
          const hstate = await this.handleAskAction(
            hijack.choice.options, hijack.choice.question, myGen);
          if (hstate !== null) return hstate; // Dart 1447: !shouldContinue -> return
          // Dart 1448: continue to the next ReAct step - NOT terminal, so no
          // finishSideEffects and (Node-only) no checkpoint save, same shape as
          // the round-125 forced-continue.
          continue;
        }
        // Round 125: Dart 1450-1468 anti-hallucination guard, first in the finish
        // case. Refused turns force-continue WITHOUT the checkpoint save (Dart's
        // continue skips it too) and without the finish event on the wire (the
        // dedup loop above already suppressed it).
        if (this.guardWillRefuseThisFinish(finishEvt)) {
          this.applyFinishGuard();
          continue; // force-continue: no checkpoint, no finish side effects
        }
        const state = finishEvt.finishState ?? "success";
        // Dart 3751-3765: onFinished gets the composed finish text, not the
        // parser's answer body (a duplicate finish skipped by the dedup loop
        // never reaches the rewrite below, so pass the composed value here).
        const composedFinish = state === "success" ? turnFinishSummary : finishEvt.summary;
        this.finishSideEffects(state, composedFinish); // no 2nd finish event; Dart parity
        return state;
      }

      // Round 124: Dart routes ActionType.ask through _handleAskAction, and the ask
      // case sits BEFORE execute in the switch (1422-1537) - an ask event short-
      // circuits the command / tool / no-command ladder for this iteration, then
      // Dart continues to the next step (1502). The Node equivalent lets control
      // fall through to the W7 checkpoint save below (checkpointing is Node-only).
      // A bare ask action line with NO options never reaches here: the parser
      // mints no event for it - scanAskAction routes it in the else ladder below.
      const askEvt = events.find((e) => e.type === "ask");
      if (askEvt !== undefined) {
        const astate = await this.handleAskAction(
          askEvt.options ?? [], askEvt.question ?? "", myGen);
        if (astate !== null) return astate;
      }
      // Check for a command event (tool call). An ask turn skips the search: Dart
      // took the ask case, never the execute case (switch-order parity).
      const cmdEvt = askEvt !== undefined
        ? undefined
        : events.find((e) => e.type === "command");
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
          : this.scanToolAction(respLines);
        if (hit !== null) {
          const tstate = await this.handleToolAction(hit[0], hit[1], task, myGen, myGenNumber, step);
          if (tstate !== null) return tstate;
        } else if (askEvt === undefined && this.scanAskAction(respLines)) {
          // Dart 2016-2017 routes a bare ask action line to the ask case even with
          // no options; _handleAskAction turns the empty options into finish-as-ask
          // (3055-3059) - a SUCCESS terminal, NOT the no-command budget below.
          const thoughtEvt = events.find((e) => e.type === "thought");
          const astate = await this.handleAskAction([], thoughtEvt?.text ?? "", myGen);
          if (astate !== null) return astate;
        } else if (askEvt === undefined && isTaskComplete(response)) {
          // Round 127: Dart 2041-2055. With no action found the Dart parser
          // asks isTaskComplete(content) and turns a completion-sounding reply
          // into ActionType.finish BEFORE _handleNoCommand (3622-3642) spends
          // the retry budget. The Node parser mints no finish event without an
          // action-finish line (react/parser.ts 292-298), so this arm IS that
          // synthesis. The local event below is never emitted and mints no
          // stableId (R4: the engine must not hash finish text); it exists only
          // to feed the two helpers that consume a finish event.
          const fbThought = events.find((e) => e.type === "thought")?.text ?? "";
          // Dart 2048 thought: thought ?? content - the parsed thought when the
          // parser found one, else the raw response.
          const fbSummary = fbThought !== "" ? fbThought : response;
          const fbEvt: AgentEvent = {
            id: genEventId(), // occurrence id, never on the wire
            type: "finish",
            timestamp: Date.now(),
            summary: fbSummary,
          };
          // Dart routes the finish case through the choice hijack (1423-1448)
          // BEFORE the guard (1450): a choice request in the body must become a
          // real ask, never a green terminal. Same order, same helpers.
          const fbHijack = this.finishChoiceHijack(fbEvt, events, turnAnswer, response);
          if (fbHijack !== null) {
            this.logGate("warn", FINISH_CHOICE_WARN_A + "[" + Array.from(fbHijack.choice.options).join(", ") + "]");
            if (!fbHijack.fromProtocol) {
              const fbAsk: AgentEvent = {
                id: genEventId(), // occurrence id like every engine-minted event
                type: "ask",
                timestamp: Date.now(),
                question: fbHijack.choice.question,
                options: Array.from(fbHijack.choice.options),
              };
              this.pendingAskEvent = fbAsk; // Dart 1435 - pin it, then onEvent
              this.emit(fbAsk);
            }
            const fbAskState = await this.handleAskAction(
              fbHijack.choice.options, fbHijack.choice.question, myGen);
            if (fbAskState !== null) return fbAskState; // Dart 1447
            continue; // Dart 1448: not terminal, next ReAct step
          }
          // Dart 1450-1468: the guard covers a finish the ENGINE synthesized too
          // - claiming completion with zero commands executed is force-
          // continued, never turned green (R5: a green terminal needs evidence).
          if (this.guardWillRefuseThisFinish(fbEvt)) {
            this.applyFinishGuard();
            continue;
          }
          this.logGate("info", FINISH_INFO); // Dart 1470 agentLogger.info -> gate info
          // Dart 1479-1483: _finishTask(success: true) then return. Deviations:
          // (1) _emitOperationReport 3755-3760 has no Node counterpart yet (D3
          // backlog). (2) emitFinish is the only sanctioned terminal emit and
          // already runs the W7 side effects, so the checkpoint save below is
          // skipped exactly like Dart's return. (3) The summary split IS ported
          // now (answer_block.ts + composeFinishSummary), matching Dart 1476-1478.
          // Dart 1476-1478 + 3751-3752 with the fallback step's thought (2048
          // thought: thought ?? content): the four-field block wins, else the
          // fb thought, composed with the answer body.
          const fbFinishSummary = this.composeFinishSummary(
            turnSections !== "" ? turnSections : fbSummary,
            turnAnswer,
          );
    agentTracer.emitSync(new TraceEvent({taskId: this.lastTaskId ?? '', type: TraceEventType.taskEnd}));
          this.emitFinish("success", fbFinishSummary);
          return "success";
        } else if (askEvt === undefined) {
          // Dart _handleNoCommand (agent_engine.dart 3622-3642): within the retry
          // budget the model gets a progress notice + the continue prompt back in
          // history; only after the budget is spent is the task terminal (R5: failed,
          // never completed). The retry log lines are Dart agentLogger copies on the
          // gate channel (stderr-only, no wire event), and the hourglass notice is a
          // real info event like Dart 3629. Node keeps its own terminal summary
          // string (no-command retry exhaustion) - the summary contract pinned by
          // r5_terminal_whitelist, an already-documented divergence, unchanged here.
          this.noCommandRetries++;
    this.logReAct("\u76ee\u6807\u8fbe\u6210\u6807\u8bb0\u4f4e\u89c2: AI \u672a\u8fd4\u56de\u6709\u6548\u52a8\u4f5c"); // Dart 1533 (approx)
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
    agentTracer.emitSync(new TraceEvent({taskId: this.lastTaskId ?? '', type: TraceEventType.taskEnd}));
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
    this.logReActWarn("\u8fbe\u5230\u6700\u5927\u6267\u884c\u6b65\u6570 " + maxSteps + " (\u4efb\u52a1\u7ec8\u6b62)"); // Dart 1562
    agentTracer.emitSync(new TraceEvent({taskId: this.lastTaskId ?? '', type: TraceEventType.taskEnd}));
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
    agentTracer.emitSync(new TraceEvent({taskId: this.lastTaskId ?? '', type: TraceEventType.taskEnd}));
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
   * Dart action-word scan for the ask value (agent_engine.dart 2005-2028, the
   * value dispatch at 2016-2017). The Node parser never mints an event for a bare
   * ask action line without options, so scan for the word here. Same first-line-
   * wins shape as scanToolAction (Dart breaks after the first action line).
   */
  private scanAskAction(lines: readonly string[]): boolean {
    for (let i = 0; i < lines.length; i++) {
      const t = lines[i].trim();
      if (t.startsWith(ACTION_KEY + ":") === false && t.startsWith(ACTION_KEY + "\uff1a") === false) continue;
      const sep = t.indexOf("\uff1a") >= 0 ? "\uff1a" : ":";
      const actionStr = t.substring(t.indexOf(sep) + 1).trim().toLowerCase();
      return actionStr === "ask";
    }
    return false;
  }

  /**
   * Dart selectChoice (agent_engine.dart 1168-1174): resolve the parked wait with
   * the user's pick. Dart guards re-entry with !isCompleted; the JS resolve settles
   * once by spec AND the completer reference is cleared here, so a second call is
   * a no-op too. Dart clears _pendingOptions here and nulls the completer only
   * when the awaiter resumes (3079-3080); Node nulls immediately so
   * hasPendingChoice goes false the moment the answer is in - behaviourally
   * identical (the continuation was already queued), just no stale accessor window.
   */
  selectChoice(choice: string): void {
    const c = this.choiceCompleter;
    this.pendingOptionsList = [];
    if (c === null) return;
    this.choiceCompleter = null;
    c.resolve(choice);
  }

  /** Host-facing accessors for the pending question (rpc layer / tests). */
  get hasPendingChoice(): boolean {
    return this.choiceCompleter !== null;
  }

  get pendingOptions(): readonly string[] {
    return this.pendingOptionsList;
  }

  /** Dart _lastResponseHadAskEvent parity accessor (see the guard note in run()). */
  get lastAskEventSeen(): boolean {
    return this.lastResponseHadAskEvent;
  }

  /**
   * Dart 708-712 / 940-944: wake a parked choice wait with an empty string so the
   * awaiter resumes and exits at its own boundary check. resolve('') on an already
   * settled Promise is a spec-level no-op, so wake racing selectChoice is safe;
   * nulling first makes every later wake / selectChoice a no-op as well.
   */
  private wakeChoiceCompleterForCancel(): void {
    const c = this.choiceCompleter;
    if (c === null) return;
    this.choiceCompleter = null;
    this.pendingOptionsList = [];
    c.resolve("");
  }

  /**
   * Round 124: Dart _handleAskAction (agent_engine.dart 3052-3113). The parked
   * wait is a Promise plus its captured resolve; the answer rides back onto the
   * captured ask event (chosenAnswer - rpc/schema.ts already carries the field,
   * no schema change) and a ReAct observation goes back to the model. Returns
   * null to continue the ReAct loop, a terminal finish state to stop it. Documented
   * divergences (see the commit message):
   *  - the waitingConfirm / thinking task-status notify pair (3070-3075 and
   *    3106-3110) has no Node channel and is skipped;
   *  - the cancelled-status re-check (3083-3086) is owned by boundary() in Node;
   *  - an empty choice is terminal as "cancelled" (R5: every Node terminal path
   *    emits finish + onFinished) where Dart returns with no finish event;
   *  - the chosen-choice info line is the zh string only (no UiText.t in Node);
   *  - the event-synthesis fallback (1488-1498) is dead code against the Node
   *    parser (it mints an ask event whenever options exist) and is not ported.
   */
  private async handleAskAction(
    options: readonly string[],
    thought: string,
    myGen: TaskGeneration,
  ): Promise<AgentFinishState | null> {
    if (options.length === 0) {
      // Dart 3055-3059: ask WITHOUT options is a finish-as-ask and a SUCCESS
      // terminal (Dart _finishTask defaults success = true at 3740) - it does
      // NOT touch the no-command / tool retry budget.
      this.logGate("warn", ASK_NO_OPTIONS_WARN);
    this.logReActWarn("ask \u52a8\u4f5c\u4f46\u65e0\u9009\u9879\uff0c\u89c6\u4e3a finish"); // Dart 3056
      const t = thought.trim();
      // Dart 3052-3060 + 3751-3752: the no-options ask ends through _finishTask,
      // which ALWAYS composes - an empty thought therefore falls to the 3733
      // accumulator (this turn's text), never to an empty/undefined summary.
    agentTracer.emitSync(new TraceEvent({taskId: this.lastTaskId ?? '', type: TraceEventType.taskEnd}));
      this.emitFinish("success", this.composeFinishSummary(t, ""));
      return "success";
    }
    // Dart 3062 interpolates a Dart List.toString ("[a, b]" - bare elements, no
    // quotes); JSON.stringify would quote them, so join instead.
    this.logGate("info", ASK_DETECTED_A + "[" + options.join(", ") + "]");
    this.logReAct("\u68c0\u6d4b\u5230\u9009\u9879\uff0c\u6682\u505c\u7b49\u5f85\u7528\u6237\u9009\u62e9: " + options.join(", ")); // Dart 3062
    let resolveChoice: (v: string) => void = (): void => {};
    const promise = new Promise<string>((res): void => { resolveChoice = res; });
    this.choiceCompleter = {resolve: resolveChoice};
    this.pendingOptionsList = [...options];
    // Dart 3066-3068: pin the ask event NOW - new events may arrive while the
    // loop is parked; the answer must not land on a different question.
    const pendingAsk = this.pendingAskEvent;
    const choice = await promise;
    this.logReAct("\u7528\u6237\u9009\u62e9\u4e86: " + (choice || "(\u53d6\u6d88)")); // Dart 3094
    this.choiceCompleter = null;
    this.pendingOptionsList = [];
    // Dart 3082-3086 (generation / cancelled-status checks) belongs to boundary()
    // in Node: a user cancel emits the cancelled finish, a superseded generation
    // exits silently with "interrupted" (no finish - the new task owns the state).
    { const s = this.boundary(myGen); if (s !== null) return s; }
    if (choice === "") {
      // Dart 3088-3091 logs and returns with no finish event; the Node run()
      // contract needs a terminal state, and a wake-with-empty is cancel-shaped.
      this.logGate("info", USER_CANCEL_CHOICE_LOG);
    agentTracer.emitSync(new TraceEvent({taskId: this.lastTaskId ?? '', type: TraceEventType.cancel}));
      this.emitFinish("cancelled", "task cancelled by user");
      return "cancelled";
    }
    this.logGate("info", USER_CHOSE_A + choice);
    // Dart 3095-3097: chosenAnswer rides on the ask event itself - the parent
    // holds the same object, so the question carries its answer with no re-emit.
    if (pendingAsk !== null) pendingAsk.chosenAnswer = choice;
    this.emit({
      // R4: occurrence id - the choice notice is a one-shot fact (Dart 3098).
      id: genEventId(),
      type: "info",
      timestamp: Date.now(),
      text: CHOSEN_INFO_A + choice,
    });
    // Dart 3100-3104: ReAct observation back to the model + trim - exactly the
    // pushObservation pair.
    this.pushObservation(OBS_CHOSEN_A + choice + OBS_CHOSEN_B);
    // Dart 3106-3110 thinking-phase notify: no Node task channel, skipped.
    return null; // Dart 3112: continue the ReAct loop
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
    this.logReAct("\u8c03\u7528\u5de5\u5177: " + toolName + ", \u53c2\u6570: " + JSON.stringify(toolArgsRaw ?? {})); // Dart 3395
    const BT = String.fromCharCode(96);

    if (toolName === "") {
      // Dart 3231-3245: warn + info + observation, then the retry budget.
      this.logGate("warn", TOOL_NO_NAME_LOG);
      this.emit({id: genEventId(), type: "info", timestamp: Date.now(), text: INFO_EMPTY_TOOL});
    this.logReActWarn("tool \u52a8\u4f5c\u4f46\u672a\u6307\u5b9a\u5de5\u5177\u540d"); // Dart 3232
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
    this.logReActWarn("\u4e2a\u522b\u540d\u7f3a\u5c11 command \u53c2\u6570"); // Dart 3299
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
    this.logReActWarn("\u672a\u77e5\u5de5\u5177: " + toolName); // Dart 3340
      const available1 = registry.all.map((t) => t.name).join(", ");
      this.pushObservation(OBS_TOOL_MISSING_A + toolName + OBS_TOOL_MISSING_B + available1);
      return this.toolRetryOrContinue("\u672a\u77e5\u5de5\u5177\u8c03\u7528\u91cd\u8bd5\u6b21\u6570\u8017\u5c3d");
    }

    // Dart 3357-3373: read-only mode used to gate only shell commands; the tool path
    // must not bypass it (design doc D3). The gate derives from ToolKind.isReadOnly.
    if (this.permissionModeFn() === "readOnly" && tool.isReadOnly === false) {
      this.logGate("info", "\u53ea\u8bfb\u6a21\u5f0f\u62e6\u622a\u5de5\u5177: " + toolName);
      this.emit({id: genEventId(), type: "info", timestamp: Date.now(), text: INFO_READONLY_TOOL + BT + toolName + BT});
    this.logReAct("\u53ea\u8bfb\u6a21\u5f0f\u62e6\u622a\u5de5\u5177: " + toolName); // Dart 3360
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
      // Dart 3452: the anti-hallucination flag is set UNCONDITIONALLY before
      // running the tool - a failed tool still proves the AI acted.
      this.hasExecutedAnyCommand = true;
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
    this.logReActError("\u5de5\u5177 " + toolName + " \u6267\u884c\u5f02\u5e38: " + String(e)); // Dart 3584
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
        // r134: the pre-execution audit write, Dart agent_engine.dart 2527-2541.
        // Order is Dart order: it sits between the safety-check debug log
        // (2524-2525, the gate info line below in Node) and the change-window
        // arm - a command the window rejects still gets its pre-exec audit row
        // (executed: false). Dart's hostId != null guard has no Node counterpart:
        // StartTaskParams.hostId is required (rpc/schema.ts 143), so every task
        // has an audit host. output is null here - nothing ran yet.
        try {
          await auditLog({hostId: task.hostId, command: cmd, safetyLevel, output: null, executed: false});
        } catch (e) {
          // Dart 2539: agentLogger.warn('Audit', '\u5ba1\u8ba1\u65e5\u5fd7\u5199\u5165\u5931\u8d25(\u6267\u884c\u524d): $e').
          // The prefix constant carries the CJK; the error value is appended here.
          console.warn(AUDIT_WRITE_FAIL_PRE_PREFIX + String(e));
        }
        // r133: the change-window arm, Dart agent_engine.dart 2573-2588. Order is Dart
        // order: classify first (the level is already in hand at 2523), then the window
        // (2573-2575), then the permission gate (2592). A command the freeze rejects never
        // reaches decideCommand, never reaches the executor, and never logs the
        // "step N - permission" line: Dart returns its _EarlyExecutionResult (2586-2587)
        // before the gate is consulted. Even a fullAuto session therefore refuses writes
        // during the freeze - the window is not a permission tier, it is a calendar-level
        // policy that sits above every tier: it exits the gate instead of deferring to it.
        // r135: local-command-on-remote guard (Dart agent_engine.dart 2543-2571).
        // Before the change-window check: a local Windows command sent to a remote
        // Unix host should get a readable observation, not a freeze-period refusal.
        if (
          this.sshOsInfo !== undefined &&
          this.sshOsInfo !== null &&
          !this.sshOsInfo.toLowerCase().includes("windows") &&
          !this.sshOsInfo.toLowerCase().includes("mingw") &&
          !this.sshOsInfo.toLowerCase().includes("cygwin") &&
          looksLikeLocalWindowsCommand(cmd)
        ) {
          const lcReason =
            "\u68c7\u6d4b\u5230 Windows \u76d8\u7b26\u6216 PowerShell \u8bed\u6cd5\uff0c\u4f46\u5f53\u524d execute \u8fd0\u884c\u5728\u8fdc\u7a0b\u670d\u52a1\u5668\u3002";
          this.emit({
            id: genEventId(),
            type: "info",
            timestamp: Date.now(),
            text: "\ud83d\udc59 " + lcReason +
              "\n\u672c\u673a\u547d\u4ee4\u8bf7\u6539\u7528 local_exec \u5de5\u5177: `" + cmd + "`",
          });
          const lcObs =
            lcReason +
            "\n\u5982\u679c\u76ee\u6807\u5728\u8fd0\u884c App \u7684\u672c\u673a\uff0c\u8bf7\u6539\u7528 local_exec \u5de5\u5177\uff08\u53c2\u6570 command/cwd\uff09\uff1b" +
            "\u5982\u679c\u76ee\u6807\u786e\u5b9e\u662f\u8fdc\u7a0b\u670d\u52a1\u5668\uff0c\u8bf7\u6539\u7528\u670d\u52a1\u5668\u652f\u6301\u7684 shell \u8bed\u6cd5\u3002";
          this.conversation.push({
            role: "user",
            content: "\u89c2\u5bdf: " + cmd + "\n\u8f93\u51fa: " + lcObs + "\n\u72b6\u6001: \u5931\u8d25",
          });
    this.logReActWarn("\u7591\u4f3c\u672c\u673a Windows \u547d\u4ee4\u53d1\u5f80\u8fdc\u7a0b Unix: " + cmd); // Dart 2555
          // Dart 2568: onSuccess(false, 'local_command_on_remote', 0)
    agentTracer.emitSync(new TraceEvent({taskId: this.lastTaskId ?? '', type: TraceEventType.taskEnd}));
          this.emitFinish("failed", "local_command_on_remote");
          return "failed";
        }
        const windowCheck = this.changeWindowCheckFn(cmd);
        if (windowCheck.allowed === false) {
          // Dart 2577: agentLogger.warn(ReAct, the frozen-window line + the command).
          this.logGate("warn", WINDOW_LOG_WARN + cmd);
    this.logReActWarn("\u5c01\u7f51\u671f\u62e6\u622a\u4fee\u6539\u6027\u547d\u4ee4: " + cmd); // Dart 2577
          // Dart 2578: onEvent?.call(AgentEvent.info(...)). One info event and NO result
          // event - nothing ran, so there is no exit code to report, the same posture as
          // the permission-reject arm below. Occurrence id per R4.
          this.emit({
            id: genEventId(),
            type: "info",
            timestamp: Date.now(),
            text: WINDOW_INFO_HEAD + cmd + WINDOW_INFO_TAIL + windowCheck.reason,
          });
          // Dart 2579-2584: ReActObservation(output: ..., success: false,
          // error: windowReason ?? fallback).format(). format() prints error ?? output on
          // the failure branch, and the union guarantees reason is non-null exactly when
          // allowed is false, so the observation output text never reaches the model here
          // (WINDOW_OBS_OUTPUT is exported for parity and pinned against 2581 by the oracle
          // test).
          this.conversation.push({
            role: "user",
            content: formatObservationFailure(cmd, windowCheck.reason ?? WINDOW_FALLBACK_REASON),
          });
          this.trimConversation(); // Dart 2285/2300: trim after every observation add
          // Dart 2585 onSuccess(false, window_blocked, 0) has NO Node counterpart: the RPC
          // process has no metrics sink, so the block is observable only through the info
          // event and the observation above. Disclosed divergence.
          // Dart does not touch _hasExecutedAnyCommand on this path (2388 is inside the
          // executed branch), so hasExecutedAnyCommand stays untouched here too.
          // Dart 2586-2587 returns _EarlyExecutionResult(shouldContinue: true) from inside
          // the gate helper, so nothing below it runs: no decideCommand, no mode log line,
          // no confirm arming, no executor. A null return is this helper's "continue the
          // loop", so the freeze cannot be talked past by an ask-mode confirmation or by
          // fullAuto - which is exactly the point of a calendar-level policy.
          return null;
        }
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
    this.logReActWarn("\u6743\u9650\u6a21\u5f0f\u62e6\u622a\u547d\u4ee4: " + gateMode + " " + cmd); // Dart 2597
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
          // r134: the blocked-only audit, Dart agent_engine.dart 2604-2617. Only a
          // SAFETY-level-blocked command gets a post-refusal audit row (output = the
          // refusal reason, executed: false); a readOnly-mode refusal of a merely-
          // warn command does not. Dart's guard is hostId != null && blocked; Node's
          // hostId is always present, so only the level is tested.
          if (safetyLevel === "blocked") {
            try {
              await auditLog({hostId: task.hostId, command: cmd, safetyLevel, output: blockReason ?? null, executed: false});
            } catch (e) {
              // Dart 2615: agentLogger.warn('Audit', '\u5ba1\u8ba1\u65e5\u5fd7\u5199\u5165\u5931\u8d25(\u62e6\u622a\u5206\u652f): $e').
              console.warn(AUDIT_WRITE_FAIL_BLOCKED_PREFIX + String(e));
            }
          }
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
    this.logReAct("\u7528\u6237\u786e\u8ba4\u6267\u884c\u5371\u9669\u547d\u4ee4: " + cmd); // Dart 2723
            if (!outcome.shouldContinue) {
              // Only generation_invalid / cancelled return false. boundary() is the
    this.logReActWarn("\u7528\u6237\u62d2\u7edd\u6267\u884c: " + cmd); // Dart 2692
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
          // Dart 2388: any command that clears the permission gate counts as
          // executed (gate refusals do not); the goal marker inside this block
          // still counts, matching Dart's body-entry placement.
          this.hasExecutedAnyCommand = true;
          // Phase 2: dispatch to the injected command executor; Phase 0: stub fallback.
          let execRes: CommandExecResult = {stdout: "", stderr: "", exitCode: 0, durationMs: 0, success: true};
          let snapshotOutput: string | null = null; // r141: Dart 2832-2838
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
            // r138: connection check (Dart 3876-3901) - before the executor call.
            let connOk = true;
            if (this.connectionChecker !== undefined) {
              connOk = await this.connectionChecker(task.hostId);
              if (!connOk) {
                this.consecutiveConnFailures++;
                const hint = this.consecutiveConnFailures >= this.maxConnFailRetries
                  ? "\uff08\u5df2\u8fde\u7eed\u5931\u8d25" + this.consecutiveConnFailures + "\u6b21\uff0c\u8bf7\u7acb\u5373\u4f7f\u7528 \u52a8\u4f5c: ask \u8be2\u95ee\u7528\u6237\u662f\u5426\u5df2\u91cd\u8fde\uff0c\u4e0d\u8981\u518d\u5c1d\u8bd5\u6267\u884c\u547d\u4ee4\uff09"
                  : "\uff08\u8bf7\u4f7f\u7528 \u52a8\u4f5c: ask \u8be2\u95ee\u7528\u6237\u662f\u5426\u5df2\u91cd\u8fde\uff0c\u6216\u7b49\u5f85\u7528\u6237\u91cd\u8fde\u540e\u7ee7\u7eed\uff09";
                execRes = {stdout: "", stderr: "\u8fde\u63a5\u5df2\u65ad\u5f00\uff0c\u8bf7\u91cd\u8fde\u540e\u91cd\u8bd5" + hint, exitCode: -1, durationMs: Date.now() - execStartMs, failureKind: "disconnected", success: false};
              }
            }
            if (connOk) {
              this.consecutiveConnFailures = 0;
              // r141: pre-snapshot rollback advisor (Dart 2740-2771).
              if (this.enableRollbackSnapshot) {
                const modifyTarget = RollbackAdvisor.analyze(cmd);
                if (modifyTarget !== null) {
                  const snapshotCmd = RollbackAdvisor.buildSnapshotCommand(modifyTarget);
                  if (snapshotCmd !== null) {
                    this.logGate("info", "Rollback: detected modification (" + modifyTarget.type + "), running pre-snapshot");
                    try {
                      const snapRes = await this.commandExecutor(snapshotCmd, {cancelled: () => this.cancelled, hostId: task.hostId});
                      // R1: generation check after snapshot (Dart 2750-2755).
                      { const s = this.boundary(myGen); if (s !== null) return s; }
                      if (snapRes.success && (snapRes.stdout.length > 0)) {
                        snapshotOutput = snapRes.stdout;
                        this.logGate("info", "Rollback: snapshot recorded (" + snapRes.stdout.length + " chars)");
                      }
                    } catch (e: any) {
                      this.logGate("warn", "Rollback: snapshot execution failed (ignored): " + String(e));
                    }
                  }
                }
              }
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
            }
            // R1: generation check after the await.
            { const s = this.boundary(myGen); if (s !== null) return s; }
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
          // r141: Dart 2832-2847: inject rollback hint into the error text on failure
          const rawError = executorError !== undefined
            ? executorError
            : ("command exited with code " + execRes.exitCode + (execRes.timedOut ? " (timed out)" : ""));
          const errorText = !execRes.success && snapshotOutput !== null
            ? (() => {
                const mt = RollbackAdvisor.analyze(cmd);
                if (mt !== null) {
                  const hint = RollbackAdvisor.buildRollbackSuggestion(mt, snapshotOutput);
                  if (hint !== null) {
                    this.logGate("info", "Rollback: command failed, generated rollback suggestion");
                    return rawError + "\n\n" + hint;
                  }
                }
                return rawError;
              })()
            : rawError;
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
            error: execRes.success ? undefined : errorText,
            durationMs: execRes.durationMs,
            // Dart AgentResult from the throw leaves exitCode null -> wire omits it.
            exitCode: executorError === undefined ? execRes.exitCode : undefined,
            failureKind: execRes.failureKind,
          };
    this.logReAct("\u6b65\u9aa4 " + step + " \u00b7 " + (execRes.success ? "\u6210\u529f" : "\u5931\u8d25") + " \u00b7 exit " + execRes.exitCode + " \u00b7 " + execRes.durationMs + "ms"); // Dart 2785
          this.emit(result);
          this.conversation.push({
            role: "user",
            content: "\u547d\u4ee4\u6267\u884c\u7ed3\u679c: " + (result.output ?? "") + (result.error ? "\n[error] " + result.error : ""), // "命令执行结果: "
          });
          this.trimConversation(); // Dart 3027: trim after the result observation
          // r134: the post-execution audit write, Dart agent_engine.dart 2919-2940.
          // Lands AFTER the result event emit and the observation push (Dart lands it
          // after the emit and before onSuccess - both are after the wire event, so
          // the relative order of the audit and the model observation is unchanged:
          // the model reads its observation, then the host persistence sees the row).
          // output is selected by selectAuditOutput (Dart 2927-2933: truncated stdout
          // on success, truncated stderr on failure, the CJK placeholders otherwise).
          const auditOutput = selectAuditOutput({
            success: execRes.success,
            output: result.output ?? "",
            error: result.error ?? "",
          });
          try {
            await auditLog({hostId: task.hostId, command: cmd, safetyLevel, output: auditOutput, executed: true});
          } catch (e) {
            // Dart 2937-2938: agentLogger.warn('Audit', '\u5ba1\u8ba1\u65e5\u5fd7\u5199\u5165\u5931\u8d25(\u6267\u884c\u540e):
            // hostId=$hostId, cmd=$command, err=$e'). The hostId/cmd pieces are
            // composed here because they are engine locals, not constants.
            console.warn(
              AUDIT_WRITE_FAIL_POST_PREFIX + task.hostId + ", cmd=" + cmd + ", err=" + String(e)
            );
          }
        }
    return null;
  }

  /**
   * Round 125: single source of truth for the anti-hallucination finish-guard
   * decision. BOTH the dedup emit loop and the finish branch call this, so the
   * wire suppression can never drift from the force-continue decision. Returns
   * true when this finish event would be REFUSED (forced continue) by the guard.
   * No await between the two call sites, so the result cannot change mid-turn.
   */
  private guardWillRefuseThisFinish(evt: AgentEvent): boolean {
    return (
      evt.type === "finish" &&
      this.hallucinationGuardEnabled &&
      !this.hasExecutedAnyCommand &&
      this.finishWithoutExecCount < this.maxFinishWithoutExecRetries
    );
  }

  /**
   * Round 127: the force-continue half of the anti-hallucination guard (Dart
   * 1451-1467) extracted so the parsed-finish branch and the round-127
   * isTaskComplete fallback arm run one implementation. No await, and
   * deliberately NO continue here: the CALLER keeps loop control, because a
   * refused finish is not a terminal path (no finish event on the wire, no
   * checkpoint, no side effects - R5 keeps the terminal corridor emitFinish).
   */
  private applyFinishGuard(): void {
    this.finishWithoutExecCount++; // Dart 1451
    this.logGate("warn", GUARD_WARN_A + this.finishWithoutExecCount + GUARD_WARN_B +
      this.maxFinishWithoutExecRetries + GUARD_WARN_C);
    this.emit({
      id: genEventId(),
      type: "info",
      timestamp: Date.now(),
      text: GUARD_INFO, // Dart 1460: onEvent(AgentEvent.info(...))
    });
    // Dart 1461-1467: the nudge as a user message, then _trimMessages.
    this.conversation.push({role: "user", content: GUARD_NUDGE});
    this.trimConversation();
  }

  /**
   * Round 126: single source of truth for the finish-to-ask hijack (Dart
   * _choiceRequestFromFinish 3034-3048). BOTH the dedup emit loop (wire
   * suppression) and the finish branch call this in the SAME iteration with no
   * await between, mirroring the round-125 guard pattern, so suppression and
   * conversion can never drift. Node mapping of the Dart ReActStep fields:
   *   step.options  -> the coexisting ask event's options (the parser folds the
   *                    options: line into an ask event, Dart stream parser did)
   *   step.answer   -> parseAnswerBlock(turn text), passed in as answerText
   *   step.thought  -> this turn's first thought event text (Dart step.thought
   *                    is the last-parsed thought; for single-thought turns -
   *                    the hijack corpus in practice - the two coincide)
   *   step.rawResponse -> this turn's raw response text (live whenever answer
   *                    and thought are both empty, Dart 3045-3046)
   * fromProtocol=true means the options came from the protocol ask event itself
   * (Dart: step.options non-empty -> the parser already put an ask on the wire);
   * false = extracted from the body by the detector -> the finish branch must
   * synthesize the ask event (Dart 1431-1437).
   */
  private finishChoiceHijack(
    evt: AgentEvent,
    events: readonly AgentEvent[],
    answerText: string,
    turnText: string,
  ): {choice: ChoiceRequest; fromProtocol: boolean} | null {
    if (evt.type !== "finish") return null;
    const thoughtText = events.find((x) => x.type === "thought")?.text ?? "";
    // Dart 3037: step.answer?.trim() ?? '' - ONE trimmed answer value, used by
    // both arms (the protocol-options question and the detector text).
    const answerTrim = answerText.trim();
    const protocolOpts = events.find((x) => x.type === "ask")?.options;
    if (protocolOpts !== undefined && protocolOpts.length >= 2) {
      // Dart 3035-3039: protocol options >= 2 win outright, no detector call;
      // question = answer.trim() when non-empty else thought.trim().
      const question = answerTrim !== "" ? answerTrim : thoughtText.trim();
      return {choice: new ChoiceRequest(question, protocolOpts), fromProtocol: true};
    }
    // Dart 3041-3047: answer else thought else rawResponse. Dart reads
    // step.answer (the parseAnswerBlock value), NOT the parser's answer body:
    // the two differ whenever the body carries a four-field block or an inline
    // stop word. The rawResponse arm IS live - step.thought is non-nullable, so
    // an empty thought falls through to it (round 126 called it dead: wrong).
    const text = answerTrim !== "" ? answerTrim : (thoughtText !== "" ? thoughtText : turnText);
    const choice = ChoiceRequestDetector.detect(text);
    if (choice === null) return null;
    // Dart 1431 re-emits only when step.options was null/empty; a protocol ask
    // with a single option counts as non-empty there (keep that edge byte-close).
    return {
      choice,
      fromProtocol: protocolOpts !== undefined && protocolOpts.length > 0,
    };
  }

  /**
   * Round 128: Dart 3729-3737 (_composeFinishSummary). `report` is Dart's
   * reportSummary (the four-field block else the thought, 1476-1478), `body` the
   * answer block; an empty pair falls back to the whole-task accumulator (3733) -
   * which is what accumulatedBuffer below exists for.
   */
  private composeFinishSummary(report: string, body: string): string {
    const thought = report.trim();
    const answer = body.trim();
    if (thought === "") return answer !== "" ? answer : this.accumulatedMessage;
    if (answer === "") return thought;
    return thought + "\n\n" + answer;
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
    agentTracer.emitSync(new TraceEvent({taskId: this.lastTaskId ?? '', type: TraceEventType.cancel}));
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
    // R1: the choice wait must be woken exactly like the confirm wait (Dart
    // 940-944): resolve('') so the parked awaiter resumes and exits at its
    // generation / boundary check. Same idempotence reasoning as the wake above,
    // and the same no-bang convention for the R5 checkpoint-whitelist scan corridor.
    this.wakeChoiceCompleterForCancel();
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
