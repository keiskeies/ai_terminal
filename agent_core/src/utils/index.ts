export {shouldUseNodeAgent, rolloutFraction} from "./rollout.js";
export type {RolloutOptions} from "./rollout.js";
export {fnv1a64DartCompat, stableId, stableHashOf} from "./stable_hash.js";
export {TailTextBuffer} from "./tail_buffer.js";
export {TaskGeneration, StaleTaskError, crossBoundary} from "./generation.js";
export {PendingRegistry, type CompleterLike} from "./pending_registry.js";
export {detectShell, wrapCommand, extractExitMarker, type ExitMarkerHit, detectOsInfoCommand} from "./shell_detect.js";

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
// Intentionally not called from anywhere yet: SafetyGuard classification and the
// rpc:confirm round-trip are both still missing, and wiring only the decision would
// mean computing a gate nobody acts on.
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

export type {ProcessHandle, SupervisorConfig} from "./process_supervisor.js";
