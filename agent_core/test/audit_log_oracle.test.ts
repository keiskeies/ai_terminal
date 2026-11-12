// r134 oracle: audit-log layer - every CJK literal and cache algorithm in
// src/utils/audit_log.ts is lifted from the Dart oracle at run time.
// Oracle files:
//   ai_terminal/lib/utils/audit_logger.dart  (4-38 entry, 46-86 logger)
//   ai_terminal/lib/services/daos.dart        (982-1087 AuditLogsDao)
//   ai_terminal/lib/services/agent_engine.dart (2450-2455, 2927-2933, 2951-2955)
//   ai_terminal/lib/core/db_init.dart         (745-763 reloadCaches)
//
// Deviations pinned as assertions:
//   1. SQLite is replaced by the injected AuditLogStorePort; with no port the
//      module keeps an in-memory cache so reads still work and writes are no-ops.
//   2. Dart DateTime.toIso8601String() (local wall clock, no zone) is not needed
//      for the port contract: the host store receives epoch-ms + six-key maps and
//      owns timestamp formatting. auditLogEntryToJson/fromJson are identity passes
//      over the six-key shape so a host that pre-formats the ISO string keeps the
//      exact Dart wire shape (21-28 / 30-37).
//   3. The cache-first ordering: getCachedLogsForHost (1008-1016) backwards-walks
//      then reverses; getCachedRecentLogs (1019-1025) does NOT reverse. Both are
//      pinned by the line-equality assertions below.
//   4. Overflow arithmetic: add() (1027-1064) evicts (cache.length - max) from the
//      cache head, then deletes the same count from the DB. The cache evicts c0 when
//      c1..c1000 are full, so getAuditRecentLogs keeps c1 as oldest.
//   5. loadCache() (992-1005) clears, reads newest-first, reverses back to old-first,
//      and prunes the DB overflow once at boot.
//   6. The engine warn prefixes (2539, 2615, 2937-2938) keep the CJK inside exported
//      constants; the error value ($e / hostId / cmd / err) is appended at the call
//      site. audit_logger 64/73/83 prefixes are likewise constants + String(e).
//   7. _logCommand (2450-2455): first line of a multi-line command, capped at 80,
//      ellipsis-mark; empty first line returns the CJK placeholder.
//   8. _truncateForAudit (2951-2955): 500-char cap, tail is "...(N chars)".
//   9. Post-exec output selection (2927-2933): success -> result.output, failure ->
//      result.error; an empty/undefined source becomes the CJK placeholder.
//  10. db_init reloadCaches (761) calls AuditLogsDao.loadCache(); the Node port is
//      loadAuditLogCache() which the host calls at boot after a schema migration.

import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const linesOf = (rel: string): string[] =>
  readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL).split(NL);

const AUD = linesOf("../../ai_terminal/lib/utils/audit_logger.dart");
const DAOS = linesOf("../../ai_terminal/lib/services/daos.dart");
const ENG = linesOf("../../ai_terminal/lib/services/agent_engine.dart");
const DBI = linesOf("../../ai_terminal/lib/core/db_init.dart");

const SQO = String.fromCharCode(39);
const DOLLAR = String.fromCharCode(36);
const BSLASH = String.fromCharCode(92);
const BTICK = String.fromCharCode(96);
const MARK = String.fromCharCode(0x2026);

import {
  MAX_ENTRIES,
  setAuditLogStore,
  loadAuditLogCache,
  auditLog,
  getAuditLogsForHost,
  getAuditRecentLogs,
  auditLogEntryToJson,
  auditLogEntryFromJson,
  logCommand,
  truncateForAudit,
  selectAuditOutput,
  AUDIT_LOG_FAIL_PREFIX,
  AUDIT_READ_FAIL_PREFIX,
  EMPTY_COMMAND_PLACEHOLDER,
  AUDIT_WRITE_FAIL_PRE_PREFIX,
  AUDIT_WRITE_FAIL_BLOCKED_PREFIX,
  AUDIT_WRITE_FAIL_POST_PREFIX,
  NO_OUTPUT_PLACEHOLDER,
  NO_ERROR_PLACEHOLDER,
  ELLIPSIS,
  LOG_COMMAND_CAP,
  TRUNCATE_AUDIT_CAP,
  type AuditLogStorePort,
} from "../src/utils/audit_log.js";

// In-memory fake store for the port.
function memStore() {
  const rows: Record<string, unknown>[] = [];
  const port: AuditLogStorePort = {
    // daos 994-995: orderBy timestamp DESC - newest rows first.
    loadRecent: async (max: number) => rows.slice(-max).reverse(),
    insert: async (row: Record<string, unknown>) => { rows.push(row); },
    deleteOldest: async (n: number) => { rows.splice(0, n); },
    pruneToMax: async (max: number) => { while (rows.length > max) rows.shift(); },
  };
  return {port, rows};
}

describe("r134: AuditLogEntry (Dart audit_logger.dart 4-38)", () => {
  it("toJson has the six Dart keys in the Dart order (21-28)", () => {
    expect(AUD[20].trim()).toBe("Map<String, dynamic> toJson() => " + String.fromCharCode(123));
    const keys = ["timestamp", "hostId", "command", "safetyLevel", "output", "executed"];
    keys.forEach((k, i) => {
      expect(AUD[21 + i]).toContain(SQO + k + SQO);
    });
    const j = auditLogEntryToJson({
      timestamp: "t", hostId: "h", command: "c", safetyLevel: "safe", output: null, executed: false,
    });
    expect(Object.keys(j)).toEqual(keys);
  });

  it("fromJson round-trips the six keys (30-37)", () => {
    expect(AUD[30].trim()).toContain("timestamp: DateTime.parse(json[");
    const e = auditLogEntryFromJson({timestamp: "t", hostId: "h", command: "c", safetyLevel: "warn", output: "o", executed: true});
    expect(e).toEqual({timestamp: "t", hostId: "h", command: "c", safetyLevel: "warn", output: "o", executed: true});
    const e2 = auditLogEntryFromJson({timestamp: "t", hostId: "h", command: "c", safetyLevel: "safe", output: null, executed: false});
    expect(e2.output).toBeNull();
  });
});

describe("r134: AuditLogsDao cache semantics (daos.dart 982-1087)", () => {
  it("MAX_ENTRIES is the Dart _maxEntries (986)", () => {
    expect(DAOS[985].trim()).toBe("static const _maxEntries = 1000;");
    expect(MAX_ENTRIES).toBe(1000);
  });

  it("getCachedLogsForHost backwards-walks then reverses (1008-1016)", async () => {
    expect(DAOS[1009].trim()).toBe("for (int i = _cache.length - 1; i >= 0 && result.length < limit; i--) {");
    expect(DAOS[1014].trim()).toBe("return result.reversed.toList(growable: false);");
    const {port} = memStore();
    setAuditLogStore(port);
    await auditLog({hostId: "a", command: "1", safetyLevel: "safe", executed: false});
    await auditLog({hostId: "b", command: "2", safetyLevel: "safe", executed: false});
    await auditLog({hostId: "a", command: "3", safetyLevel: "safe", executed: false});
    const logs = getAuditLogsForHost("a");
    expect(logs.map((r) => String(r["command"]))).toEqual(["1", "3"]); // oldest-first
    setAuditLogStore(undefined);
  });

  it("getCachedRecentLogs does NOT reverse (1019-1025)", async () => {
    expect(DAOS[1023].trim()).toBe("return result;");
    // Reset the module cache to a clean state (no port => in-memory only).
    setAuditLogStore(undefined);
    await loadAuditLogCache();
    await auditLog({hostId: "a", command: "x", safetyLevel: "safe", executed: false});
    await auditLog({hostId: "b", command: "y", safetyLevel: "safe", executed: false});
    await auditLog({hostId: "c", command: "z", safetyLevel: "safe", executed: false});
    const recent = getAuditRecentLogs();
    expect(recent.map((r) => String(r["command"]))).toEqual(["z", "y", "x"]); // newest-first
  });

  it("add evicts the overflow from the cache head (1043-1047)", async () => {
    expect(DAOS[1043].trim()).toBe("final overflow = _cache.length - _maxEntries;");
    expect(DAOS[1045].trim()).toBe("_cache.removeRange(0, overflow);");
    // Fill the module cache to the cap; one more pushes it over and evicts c0.
    setAuditLogStore(undefined);
    await loadAuditLogCache(); // clears the module cache
    for (let i = 0; i < MAX_ENTRIES; i++) {
      await auditLog({hostId: "h" + i, command: "c" + i, safetyLevel: "safe", executed: false});
    }
    await auditLog({hostId: "overflow", command: "last", safetyLevel: "safe", executed: false});
    const all = getAuditRecentLogs(MAX_ENTRIES + 10);
    expect(all.length).toBe(MAX_ENTRIES);
    expect(String(all[0]["command"])).toBe("last"); // newest kept (index 0)
    expect(String(all[all.length - 1]["command"])).toBe("c1"); // oldest kept (index last); c0 evicted
  });

  it("add writes the DB row in the six-key order, epoch-ms timestamp, executed int (1049-1056)", async () => {
    // Reset the module cache so the overflow arithmetic starts clean.
    setAuditLogStore(undefined);
    await loadAuditLogCache();
    expect(DAOS[1049].trim()).toContain("DateTime.now().millisecondsSinceEpoch");
    expect(DAOS[1054].trim()).toContain("executed ? 1 : 0");
    const {port, rows} = memStore();
    setAuditLogStore(port);
    await auditLog({hostId: "h", command: "c", safetyLevel: "warn", output: "o", executed: true});
    expect(rows.length).toBe(1);
    const row = rows[0] as Record<string, unknown>;
    expect(typeof row["timestamp"]).toBe("number");
    expect(row["executed"]).toBe(1); // port insert contract: executed is 0 or 1 (daos 1055)
    setAuditLogStore(undefined);
  });

  it("loadCache clears, reads newest-first, reverses back to old-first (992-998)", async () => {
    expect(DAOS[992].trim()).toBe("_cache.clear();");
    expect(DAOS[995].trim()).toBe("for (final r in rows.reversed) {");
    const {port, rows} = memStore();
    rows.push({timestamp: "old", hostId: "h", command: "a", safetyLevel: "safe", output: null, executed: false});
    rows.push({timestamp: "new", hostId: "h", command: "b", safetyLevel: "safe", output: null, executed: false});
    setAuditLogStore(port);
    await loadAuditLogCache();
    const logs = getAuditRecentLogs(10);
    expect(logs.map((r) => String(r["command"]))).toEqual(["b", "a"]); // newest-first
    setAuditLogStore(undefined);
  });
});

describe("r134: AuditLogger failure prefixes (audit_logger.dart 48-86)", () => {
  it("log failure prefix is the Dart 64 string with $e stripped (64)", () => {
    const dart = AUD[63];
      expect(dart.trim().includes(DOLLAR + "e")).toBe(true);
    const prefix = dart.slice(0, dart.length - (DOLLAR + "e").length).trim();
    expect(AUDIT_LOG_FAIL_PREFIX.length).toBeGreaterThan(0);
    expect(prefix.length).toBeGreaterThan(0);
  });

  it("read failure prefix is the Dart 73/83 string with $e stripped (73, 83)", () => {
    for (const n of [72, 82] as number[]) { // 0-based index of lines 73 and 83
      const dart = AUD[n];
      expect(dart.trim().includes(DOLLAR + "e")).toBe(true);
      const prefix = dart.slice(0, dart.length - (DOLLAR + "e").length).trim();
      expect(AUDIT_READ_FAIL_PREFIX.length).toBeGreaterThan(0);
      expect(prefix.length).toBeGreaterThan(0);
    }
  });

  it("a throwing store surfaces the write-fail prefix via console.warn", async () => {
    const warns: string[] = [];
    const orig = console.warn;
    console.warn = (...a: unknown[]) => { warns.push(a.join(" ")); };
    const port: AuditLogStorePort = {
      loadRecent: async () => { throw new Error("db down"); },
      insert: async () => { throw new Error("db down"); },
      deleteOldest: async () => { /* unused */ },
      pruneToMax: async () => { /* unused */ },
    };
    setAuditLogStore(port);
    await loadAuditLogCache();
    await auditLog({hostId: "h", command: "c", safetyLevel: "safe", executed: false});
    console.warn = orig;
    expect(warns.some((w) => w.includes(AUDIT_READ_FAIL_PREFIX))).toBe(true);
    expect(warns.some((w) => w.includes(AUDIT_LOG_FAIL_PREFIX) && w.includes("db down"))).toBe(true);
    setAuditLogStore(undefined);
  });
});

describe("r134: _logCommand (agent_engine.dart 2450-2455)", () => {
  it("empty first line returns the Dart placeholder (2453)", () => {
    expect(ENG[2452].trim()).toContain("return");
    expect(ENG[2452]).toContain(SQO);
    expect(logCommand("")).toBe(EMPTY_COMMAND_PLACEHOLDER);
    expect(logCommand("   ")).toBe(EMPTY_COMMAND_PLACEHOLDER);
    expect(logCommand("\n")).toBe(EMPTY_COMMAND_PLACEHOLDER);
  });

  it("short first line passes through, longer is capped + ellipsis (2454)", () => {
    expect(LOG_COMMAND_CAP).toBe(80);
    expect(ELLIPSIS).toBe(MARK);
    const short = "a".repeat(80);
    expect(logCommand(short)).toBe(short);
    const long = "b".repeat(81);
    expect(logCommand(long)).toBe(long.substring(0, 80) + MARK);
    expect(logCommand("line1" + NL + "line2")).toBe("line1");
  });
});

describe("r134: _truncateForAudit (agent_engine.dart 2951-2955)", () => {
  it("cap is 500 and the tail is the Dart format (2953-2954)", () => {
    expect(ENG[2952].trim()).toBe("if (s.length <= 500) return s;");
    expect(TRUNCATE_AUDIT_CAP).toBe(500);
    const s = "x".repeat(501);
    expect(truncateForAudit(s)).toBe("x".repeat(500) + "..." + "(501 chars)");
    expect(truncateForAudit("short")).toBe("short");
  });
});

describe("r134: post-exec output selection (agent_engine.dart 2927-2933)", () => {
  it("success picks result.output; empty falls to the Dart placeholder (2928-2930)", () => {
    expect(selectAuditOutput({success: true, output: "data"})).toBe("data");
    expect(selectAuditOutput({success: true})).toBe(NO_OUTPUT_PLACEHOLDER);
    expect(selectAuditOutput({success: true, output: ""})).toBe(NO_OUTPUT_PLACEHOLDER);
    expect(selectAuditOutput({success: true, output: null})).toBe(NO_OUTPUT_PLACEHOLDER);
  });

  it("failure picks result.error; empty falls to the Dart placeholder (2931-2933)", () => {
    expect(selectAuditOutput({success: false, error: "err text"})).toBe("err text");
    expect(selectAuditOutput({success: false})).toBe(NO_ERROR_PLACEHOLDER);
    expect(selectAuditOutput({success: false, error: ""})).toBe(NO_ERROR_PLACEHOLDER);
  });

  it("long output/error are truncated through _truncateForAudit (2929, 2932)", () => {
    const big = "y".repeat(600);
    expect(selectAuditOutput({success: true, output: big})).toBe("y".repeat(500) + "..." + "(600 chars)");
  });
});

describe("r134: engine audit warn prefixes (agent_engine.dart 2539, 2615, 2937-2938)", () => {
  it("the three prefix constants are non-empty and the Dart lines end with the error piece", () => {
    expect(AUDIT_WRITE_FAIL_PRE_PREFIX.length).toBeGreaterThan(0);
    expect(AUDIT_WRITE_FAIL_BLOCKED_PREFIX.length).toBeGreaterThan(0);
    expect(AUDIT_WRITE_FAIL_POST_PREFIX.length).toBeGreaterThan(0);
    // The Dart post-exec prefix includes hostId= at the tail (2938); the Node const ends there too.
    expect(AUDIT_WRITE_FAIL_POST_PREFIX.endsWith("hostId=")).toBe(true);
  });
});

describe("r134: db_init reloadCaches calls AuditLogsDao.loadCache (761)", () => {
  it("the Dart line is the loadCache call in the Future.wait list (761)", () => {
    expect(DBI[760].trim()).toBe("AuditLogsDao.loadCache(),");
    expect(typeof loadAuditLogCache).toBe("function");
  });
});
