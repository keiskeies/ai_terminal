export {shouldUseNodeAgent, rolloutFraction} from "./rollout.js";
export type {RolloutOptions} from "./rollout.js";
export {fnv1a64DartCompat, stableId, stableHashOf} from "./stable_hash.js";
export {TailTextBuffer} from "./tail_buffer.js";
export {TaskGeneration, StaleTaskError, crossBoundary} from "./generation.js";
export {PendingRegistry, type CompleterLike} from "./pending_registry.js";
export {detectShell, wrapCommand, extractExitMarker, type ExitMarkerHit, detectOsInfoCommand} from "./shell_detect.js";
export {ExitMarkerScanner} from "./exit_marker_scanner.js";
export {FormValidators, type ValidatorResult} from "./form_validators.js";
export {extractLiveThought} from "./live_thought_text.js";
export {stableParagraphCut, unclosedFenceSplit} from "./streaming_markdown.js";
export {
  detectUrl, detectPath, looksLikeError, isMultiLine, looksLikeCommand,
  stripPromptPrefix, agentExplainPrompt, agentErrorPrompt, directoryOfPath,
} from "./terminal_text_actions.js";
export {
  parseSlashCommand, hasRest, matchModelNames, shouldRestorePermissionMode,
  kGoalSubCommands, parseGoalCommand,
} from "./slash_command.js";
export type {ParsedSlashCommand, GoalCommand} from "./slash_command.js";

export {LineDiff, type LineDiffResult} from "./line_diff.js";
export {
  decodeEscapedText, decodeContent, backupLocalFile, writeLocalFile,
  countOccurrences, patchLocalFile, TRASH_DIR_NAME,
  isTrashEntryDir, trashEntriesFromRestorePaths, measureTrashEntries,
  clearTrashEntries, formatByteSize, countPathsUnderEntries,
  looksLikeWindowsLocalPath, looksLikePosixRemotePath,
} from "./local_file_ops.js";
export type {LocalWriteOutcome, LocalPatchOutcome, TrashUsage, TrashClearResult, DecodedContent} from "./local_file_ops.js";
export {CheckpointStore} from "./checkpoint_store.js";
export type {TaskCheckpoint} from "./checkpoint_store.js";

export {ProcessSupervisor} from "./process_supervisor.js";

// Gate matrix ported from lib/core/permission_policy.dart (design doc §9 items 6-7).
// Called from the engine command gate (react/engine.ts) and from the tool layer
// (tools/orchestrator.ts, tools/builtin.ts) - the decision is acted on in both paths,
// so a reject never reaches an executor.
export {
  decideCommand,
  destructiveToolNeedsConfirm,
  SAFETY_LEVELS,
  GATE_DECISIONS,
  PERMISSION_DECISION_EXECUTE,
  PERMISSION_DECISION_CONFIRM,
  PERMISSION_DECISION_REJECT,
} from "./permission_policy.js";
export type {SafetyLevel, CommandGateDecision} from "./permission_policy.js";

export {
  checkSafety,
  checkPath,
  checkReadPath,
  getSafetyReason,
  getSafetyTip,
  getHomeDir,
  requireConfirm,
  PathSafetyResult,
  BLOCK_RULES,
  WARN_RULES,
  INFO_PATTERNS,
  SAFETY_TIPS,
  BLOCKED_PATH_PREFIXES,
  BLOCKED_FILE_PATTERNS,
  BLOCKED_DIR_NAMES,
  HOME_BLOCKED_SUFFIXES,
  type SafetyRule,
} from "./safety_guard.js";
export {LocalFilePolicy, LocalPathDecision, LocalPathVerdict, LOCAL_FILE_POLICY_SETTINGS_KEY, DEFAULT_MAX_READ_BYTES} from "./local_file_policy.js";
export type {LocalFilePolicyOptions, LocalFileSettingsReader} from "./local_file_policy.js";

export {
  AgentGoal,
  AGENT_GOAL_STATUSES,
  GoalDecision,
  GOAL_ACTIONS,
  GOAL_DONE_MARKER,
  GOAL_MARKER_STRIP_PATTERN,
  decideGoalContinuation,
  goalMarkedDone,
  isGoalMarkerOnlyCommand,
  shouldScheduleGoalRound,
  shouldKickGoalRound,
  buildGoalContinuationPrompt,
  type AgentGoalStatus,
  type GoalAction,
} from "./goal_continuation.js";

export type {ProcessHandle, SupervisorConfig} from "./process_supervisor.js";
export {
  estimateText,
  isCjk,
  estimateHistory,
  estimateMessage,
  MESSAGE_OVERHEAD_TOKENS,
  type TokenEstimateMessage,
} from "./token_estimator.js";
export {
  MAX_CONVERSATION_ROUNDS,
  MAX_MESSAGE_CHARS,
  DEFAULT_CONTEXT_WINDOW,
  CONTEXT_TOKEN_RATIO,
  effectiveContextWindow,
  truncateOneMessage,
  trimConversation,
  type TrimMessage,
} from "./context_trim.js";

export {compactOnce, buildCompactPrompt, parseCompactJson, type CompactSummary, type CompactMessage, type CompactLlmProvider} from "./compact.js";