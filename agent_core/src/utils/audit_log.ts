// utils/audit_log.ts - port of Dart ai_terminal/lib/utils/audit_logger.dart (4-88) +
// the AuditLogsDao cache semantics from services/daos.dart (982-1087), with the engine's
// two helper functions _logCommand (agent_engine.dart 2450-2455) and _truncateForAudit
// (2951-2955) folded in so that src/react/engine.ts can stay ASCII-only (pinned by
// test/regression/r5_terminal_whitelist.test.ts).
//
// Oracle: test/audit_log_oracle.test.ts re-reads the Dart files at run time and
// asserts every CJK literal below against the Dart source.
//
// Numbered deviations from the Dart original:
//   1. AuditLogsDao (SQLite) is replaced by an injected AuditLogStorePort (precedent:
//      ChangeWindowSettingsPort in change_window.ts). The in-memory cache of the Dart
//      DAO is reproduced here as the module-level cache that the port feeds; when no
//      port is injected, log() writes only to the in-memory cache and the readers
//      return from it, so behaviour stays observable and the host that never injects
//      a port never touches persistence.
//   2. dartIso8601Local: the timestamp written into a cache entry uses the local wall
//      clock with 6 fractional digits and no zone suffix - the same shape Dart's
//      DateTime.now().toIso8601String() produces on the machine that runs the app.
//      Precedent: agent_goal.ts @62-73.
//   3. Dart's AuditLogger.log is Future<void>; the cache write is synchronous and the
//      store write is awaited. Here log() is async and the cache write happens first,
//      the store write second - identical order, so the cache is never stale.
//   4. The overflow-eviction arithmetic (daos 1044-1047) is identical; the SQLite
//      DELETE half has no Node counterpart (deviation 1).
//   5. Dart's loadCache() (daos 992-1005) reads the DB on startup; here it reads the
//      injected port. With no port the cache is cleared and left empty (the default
//      no-port path).
//   6. The audit warn prefixes in agent_engine.dart are exported as constants so
//      that engine.ts can compose them without carrying CJK bytes.
//   7. _logCommand's 80-char cap + ellipsis and _truncateForAudit's 500-char cap are
//      exported as LOG_COMMAND_CAP / TRUNCATE_AUDIT_CAP for test pinning.
//   8. The post-exec audit warn (agent_engine 2937-2938) carries hostId + command +
//      error; the prefix constant excludes the trailing interpolation.

import type {SafetyLevel} from "./permission_policy.js";

// CJK literal constants (pinned against the Dart source by test/audit_log_oracle.test.ts).

// audit_logger.dart 64: debugPrint('[AuditLogger] 记录失败: $e');
export const AUDIT_LOG_FAIL_PREFIX = "[AuditLogger] 记录失败: ";

// audit_logger.dart 73 / 83: debugPrint('[AuditLogger] 读取失败: $e');
export const AUDIT_READ_FAIL_PREFIX = "[AuditLogger] 读取失败: ";

// agent_engine.dart 2453: if (firstLine.isEmpty) return '(空命令)';
export const EMPTY_COMMAND_PLACEHOLDER = "(空命令)";

// agent_engine.dart 2525: 步骤 N · 安全检查 LEVEL · CMD
export const STEP_CHECK_HEAD = "步骤 ";
export const STEP_CHECK_MID = " · 安全检查 ";
export const STEP_CHECK_TAIL = " · ";

// agent_engine.dart 2539: 审计日志写入失败(执行前): $e
export const AUDIT_WRITE_FAIL_PRE_PREFIX = "审计日志写入失败(执行前): ";

// agent_engine.dart 2615: 审计日志写入失败(拦截分支): $e
export const AUDIT_WRITE_FAIL_BLOCKED_PREFIX = "审计日志写入失败(拦截分支): ";

// agent_engine.dart 2937-2938: 审计日志写入失败(执行后): hostId=$hostId, cmd=$command, err=$e
export const AUDIT_WRITE_FAIL_POST_PREFIX = "审计日志写入失败(执行后): hostId=";

// agent_engine.dart 2929-2930: (无输出)
export const NO_OUTPUT_PLACEHOLDER = "(无输出)";

// agent_engine.dart 2933: (无错误信息)
export const NO_ERROR_PLACEHOLDER = "(无错误信息)";

// agent_engine.dart 2454: the ellipsis appended after the 80-char command cap
export const ELLIPSIS = "…";

// ---------------------------------------------------------------------------
// AuditLogEntry - Dart audit_logger.dart 4-38
// ---------------------------------------------------------------------------

export interface AuditLogEntry {
  timestamp: string;       // ISO-8601 local wall clock, 6 fractional digits, no zone
  hostId: string;
  command: string;
  safetyLevel: string;     // SafetyLevel value
  output: string | null;   // null before execution, truncated after
  executed: boolean;
}

// Dart toJson (21-28): six keys in that exact order.
export function auditLogEntryToJson(entry: AuditLogEntry): Record<string, unknown> {
  return {
    timestamp: entry.timestamp,
    hostId: entry.hostId,
    command: entry.command,
    safetyLevel: entry.safetyLevel,
    output: entry.output,
    executed: entry.executed,
  };
}

// Dart fromJson (30-37).
export function auditLogEntryFromJson(json: Record<string, unknown>): AuditLogEntry {
  return {
    timestamp: json["timestamp"] as string,
    hostId: json["hostId"] as string,
    command: json["command"] as string,
    safetyLevel: json["safetyLevel"] as string,
    output: json["output"] as string | null | undefined ?? null,
    executed: json["executed"] as boolean,
  };
}

// dartIso8601Local (deviation 2): mirrors Dart DateTime.now().toIso8601String().
function dartIso8601Local(d: Date): string {
  const pad = (n: number, w: number) => String(n).padStart(w, "0");
  return (
    pad(d.getFullYear(), 4) + "-" +
    pad(d.getMonth() + 1, 2) + "-" +
    pad(d.getDate(), 2) + "T" +
    pad(d.getHours(), 2) + ":" +
    pad(d.getMinutes(), 2) + ":" +
    pad(d.getSeconds(), 2) + "." +
    pad(d.getMilliseconds() * 1000, 6)
  );
}

// ---------------------------------------------------------------------------
// AuditLogStorePort - deviation 1 (injected persistence)
// ---------------------------------------------------------------------------

/**
 * Port for the SQLite half of AuditLogsDao. The Dart DAO's loadCache() (daos 992-1005)
 * reads up to MAX_ENTRIES rows in timestamp DESC order, reverses them into the cache,
 * and prunes the table to MAX_ENTRIES. A host that injects a port gets persistence;
 * a host that injects none stays in-memory only (deviation 1).
 */
export interface AuditLogStorePort {
  /** Read up to maxEntries rows, timestamp DESC (daos 994-996). */
  loadRecent(maxEntries: number): Promise<Record<string, unknown>[]>;
  /** Insert one row; timestamp is epoch milliseconds, executed is 0 or 1 (daos 1049-1056). */
  insert(row: {
    timestamp: number;
    hostId: string;
    command: string;
    safetyLevel: string;
    output: string | null;
    executed: number;
  }): Promise<void>;
  /** Delete the oldest overflow rows (daos 1058-1063). */
  deleteOldest(overflow: number): Promise<void>;
  /** Startup prune: keep only the newest maxEntries rows (daos 1000-1004). */
  pruneToMax(maxEntries: number): Promise<void>;
}

// ---------------------------------------------------------------------------
// Module-level cache - the Dart _cache from daos 990
// ---------------------------------------------------------------------------

export const MAX_ENTRIES = 1000; // daos 986

let cache: Record<string, unknown>[] = [];
let port: AuditLogStorePort | undefined;

export function setAuditLogStore(next: AuditLogStorePort | undefined): void {
  port = next;
}

/**
 * Port of AuditLogsDao.loadCache (daos 992-1005): clear the cache, read up to
 * MAX_ENTRIES rows (newest first), reverse to oldest-first order, prune the table.
 * With no port injected the cache is cleared and left empty.
 */
export async function loadAuditLogCache(): Promise<void> {
  cache = [];
  if (port === undefined) return;
  try {
    const rows = await port.loadRecent(MAX_ENTRIES);
    // daos 996: rows.reversed -> add each to the cache (oldest-first).
    for (let i = rows.length - 1; i >= 0; i--) {
      cache.push(rows[i]);
    }
    await port.pruneToMax(MAX_ENTRIES); // daos 1000-1004
  } catch {
    // R8: persistence failures must surface, not be silently swallowed.
    console.warn(AUDIT_READ_FAIL_PREFIX + "loadCache");
  }
}

// ---------------------------------------------------------------------------
// AuditLogger - Dart audit_logger.dart 46-87
// ---------------------------------------------------------------------------

export interface AuditLogInput {
  hostId: string;
  command: string;
  safetyLevel: SafetyLevel;
  output?: string | null;
  executed: boolean;
}

/**
 * Dart AuditLogger.log (48-66). The cache write is synchronous and always first
 * (deviation 3); the store write is awaited and its failures are logged with the
 * Dart prefix (audit_logger.dart 64).
 */
export async function auditLog(input: AuditLogInput): Promise<void> {
  const entry: Record<string, unknown> = {
    timestamp: dartIso8601Local(new Date()),
    hostId: input.hostId,
    command: input.command,
    safetyLevel: input.safetyLevel,
    output: input.output ?? null,
    executed: input.executed,
  };
  cache.push(entry);
  const overflow = cache.length - MAX_ENTRIES; // daos 1044
  if (overflow > 0) {
    cache.splice(0, overflow); // daos 1045-1047
  }
  if (port === undefined) return; // deviation 1: no port -> in-memory only
  try {
    await port.insert({
      timestamp: Date.now(), // daos 1050: epoch milliseconds
      hostId: input.hostId,
      command: input.command,
      safetyLevel: input.safetyLevel,
      output: input.output ?? null,
      executed: input.executed ? 1 : 0, // daos 1055
    });
    if (overflow > 0) {
      await port.deleteOldest(overflow); // daos 1058-1063
    }
  } catch (e) {
    console.warn(AUDIT_LOG_FAIL_PREFIX + String(e)); // audit_logger.dart 64
  }
}

/**
 * Dart AuditLogger.getLogsForHost (69-76): synchronous cache read, oldest-first,
 * limited to limit entries. The backwards walk + reverse is daos 1008-1016.
 */
export function getAuditLogsForHost(hostId: string, limit: number = 100): Record<string, unknown>[] {
  try {
    const result: Record<string, unknown>[] = [];
    for (let i = cache.length - 1; i >= 0 && result.length < limit; i--) {
      if (cache[i]["hostId"] === hostId) {
        result.push(cache[i]);
      }
    }
    return result.reverse(); // daos 1015: result.reversed.toList()
  } catch {
    console.warn(AUDIT_READ_FAIL_PREFIX + "getLogsForHost");
    return [];
  }
}

/**
 * Dart AuditLogger.getRecentLogs (79-86): newest-first, no reverse (daos 1019-1025).
 */
export function getAuditRecentLogs(limit: number = 100): Record<string, unknown>[] {
  try {
    const result: Record<string, unknown>[] = [];
    for (let i = cache.length - 1; i >= 0 && result.length < limit; i--) {
      result.push(cache[i]);
    }
    return result; // daos 1024: no reverse
  } catch {
    console.warn(AUDIT_READ_FAIL_PREFIX + "getRecentLogs");
    return [];
  }
}

// ---------------------------------------------------------------------------
// Engine helpers - agent_engine.dart 2450-2455 (_logCommand) and 2951-2955
// ---------------------------------------------------------------------------

export const LOG_COMMAND_CAP = 80; // agent_engine.dart 2454

/**
 * agent_engine.dart 2450-2455: first line of a possibly multi-line command, capped
 * at LOG_COMMAND_CAP, with an ellipsis when truncated. Empty first line returns
 * EMPTY_COMMAND_PLACEHOLDER.
 */
export function logCommand(command: string): string {
  const firstLine = command.split("\n")[0].trim();
  if (firstLine.length === 0) return EMPTY_COMMAND_PLACEHOLDER;
  if (firstLine.length <= LOG_COMMAND_CAP) return firstLine;
  return firstLine.substring(0, LOG_COMMAND_CAP) + ELLIPSIS;
}

export const TRUNCATE_AUDIT_CAP = 500; // agent_engine.dart 2953

/**
 * agent_engine.dart 2951-2955: cap audit output at TRUNCATE_AUDIT_CAP; when longer,
 * keep the head and append "...(N chars)".
 */
export function truncateForAudit(s: string): string {
  if (s.length <= TRUNCATE_AUDIT_CAP) return s;
  return s.substring(0, TRUNCATE_AUDIT_CAP) + "...(" + s.length + " chars)";
}

// ---------------------------------------------------------------------------
// Post-exec output selection - agent_engine.dart 2927-2933
// ---------------------------------------------------------------------------

export interface CommandExecResultLike {
  success: boolean;
  /** The model-facing combined output (stdout + stderr). The audit source on success.
   *  Dart result.output (agent_engine 2928-2929). */
  output?: string | null;
  /** The executor error string (exit-code sentence or exception). The audit source
   *  on failure. Dart result.error (agent_engine 2931-2932). */
  error?: string | null;
}

/**
 * agent_engine.dart 2927-2933: pick the audit output string. The source is
 * result.output on success and result.error on failure (the SAME fields the
 * wire result event carries - Node's execRes.stdout/stderr are folded into
 * result.output/result.error by the executor before this point, so the
 * placeholders fire on exactly the Dart conditions: an empty/undefined source
 * becomes the CJK placeholder, a non-empty one is truncated to 500 chars).
 * success ? (output non-empty ? truncate(output) : NO_OUTPUT_PLACEHOLDER)
 *         : (error  non-empty ? truncate(error)  : NO_ERROR_PLACEHOLDER)
 */
export function selectAuditOutput(result: CommandExecResultLike): string {
  if (result.success) {
    return result.output !== undefined && result.output !== null && result.output.length > 0
      ? truncateForAudit(result.output)
      : NO_OUTPUT_PLACEHOLDER;
  }
  return result.error !== undefined && result.error !== null && result.error.length > 0
    ? truncateForAudit(result.error)
    : NO_ERROR_PLACEHOLDER;
}
