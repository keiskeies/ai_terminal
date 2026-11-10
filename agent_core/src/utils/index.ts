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
export type {ProcessHandle, SupervisorConfig} from "./process_supervisor.js";
