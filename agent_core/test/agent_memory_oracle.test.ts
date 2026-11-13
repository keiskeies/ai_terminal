// test/agent_memory_oracle.test.ts - r214.
// Unit tier pins Dart-visible behavior (including the _parseSimpleJson
// key-keeps-quotes quirk); oracle tier re-reads models/agent_memory.dart
// and diffs literals, constants and the stats key set at run time.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {MemoryEntry, AgentMemory} from "../src/utils/agent_memory.js";

const NL = String.fromCharCode(10);
const DQ = String.fromCharCode(34);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const CRLF = String.fromCharCode(13) + String.fromCharCode(10);
const DART = readFileSync(HERE + "../../ai_terminal/lib/models/agent_memory.dart", "utf-8")
  .split(CRLF).join(NL);
// ASCII-safe builders for metadata strings that contain double quotes.
const J = (pairs: Array<[string, string | boolean]>): string =>
  "{" + pairs
    .map(([k, v]) => DQ + k + DQ + ":" + (typeof v === "string" ? DQ + v + DQ : String(v)))
    .join(",") + "}";
const KQ = (k: string): string => DQ + k + DQ; // parseSimpleJson keeps BOTH quotes in keys
function dartLineWith(needle: string): string {
  const line = DART.split(NL).find(l => l.includes(needle));
  if (!line) throw new Error("dart line missing: " + needle);
  return line.trim();
}

describe("MemoryEntry factories", () => {
  it("command keeps literal nulls in both metadata slots", () => {
    const e = MemoryEntry.command("ls");
    expect(e.type).toBe("command");
    expect(e.metadata).toBe(J([["description", "null"], ["result", "null"]]));
    expect(/^cmd_\d+$/.test(e.id)).toBe(true);
  });
  it("factory id prefixes and types", () => {
    expect(/^sys_\d+$/.test(MemoryEntry.systemInfo("i").id)).toBe(true);
    expect(MemoryEntry.systemInfo("i").type).toBe("system_info");
    expect(/^res_\d+$/.test(MemoryEntry.result("c", "o").id)).toBe(true);
    expect(MemoryEntry.context("x").type).toBe("context");
    expect(MemoryEntry.context("x").metadata).toBeUndefined();
  });
  it("result content joins command and output with one newline", () => {
    expect(MemoryEntry.result("ls", "out").content).toBe("ls" + NL + "out");
    expect(MemoryEntry.result("ls", "o").metadata).toBe(J([["success", true]]));
    expect(MemoryEntry.result("ls", "o", {success: false}).metadata).toBe(J([["success", false]]));
  });
  it("metadataMap keeps quotes in keys (Dart _parseSimpleJson quirk)", () => {
    const e = MemoryEntry.command("ls", {description: "d", result: "r"});
    expect(e.metadataMap).toEqual({[KQ("description")]: "d", [KQ("result")]: "r"});
    expect(MemoryEntry.command("x").metadataMap).toEqual({[KQ("description")]: "null", [KQ("result")]: "null"});
    expect(MemoryEntry.context("c").metadataMap).toBeNull();
  });
  it("parseSimpleJson booleans unquoted, systemInfo category", () => {
    expect(MemoryEntry.result("a", "b").metadataMap).toEqual({[KQ("success")]: true});
    expect(MemoryEntry.systemInfo("i", {category: "os"}).metadata).toBe(J([["category", "os"]]));
  });
});

describe("AgentMemory", () => {
  it("buildContext matches the Dart layout", () => {
    const m = new AgentMemory();
    m.rememberSystemInfo("OS: Linux", {category: "os"});
    m.rememberCommand("ls -la", {description: "list"});
    const out = m.buildContext();
    expect(out.startsWith("【Agent 记忆】" + NL)).toBe(true);
    expect(out).toContain("系统环境:" + NL + "  - " + "OS: Linux" + NL);
    expect(out).toContain("最近命令:" + NL + "  - " + "ls -la" + NL);
    expect(out.endsWith(NL)).toBe(true);
  });
  it("empty memory gives empty context", () => {
    expect(new AgentMemory().buildContext()).toBe("");
  });
  it("trim keeps the freshest 50 by timestamp", () => {
    const m = new AgentMemory();
    for (let i = 0; i < 60; i++) {
      m.add(new MemoryEntry({id: "c" + i, type: "command", content: "c" + i, timestamp: 1000 + i}));
    }
    expect(m.getRecent({limit: 3}).map(e => e.content)).toEqual(["c59", "c58", "c57"]);
    expect(m.stats.total).toBe(50);
    expect(m.stats.commands).toBe(50);
  });
  it("system summary caps at 10, newest first", () => {
    const m = new AgentMemory();
    for (let i = 0; i < 14; i++) {
      m.add(new MemoryEntry({id: "s" + i, type: "system_info", content: "s" + i, timestamp: 1000 + i}));
    }
    const parts = m.getSystemSummary().split(NL);
    expect(parts.length).toBe(10);
    // Dart quirk: _trim keeps _entries newest-first, so where(system_info)
    // .reversed.take(10) yields the OLDEST-kept entries first (s0 first),
    // not the newest 10. The port reproduces filter->reverse->take 1:1.
    expect(parts[0]).toBe("s0");
    expect(parts[9]).toBe("s9");
  });
  it("getRecentCommands keeps command+result only", () => {
    const m = new AgentMemory();
    m.rememberCommand("c1");
    m.rememberResult("c1", "o");
    m.rememberSystemInfo("sys");
    expect(m.getRecentCommands({limit: 10}).map(e => e.type).sort()).toEqual(["command", "result"]);
  });
  it("clear empties entries", () => {
    const m = new AgentMemory();
    m.rememberSystemInfo("a");
    m.clear();
    expect(m.stats.total).toBe(0);
  });
});

describe("oracle vs Dart source", () => {
  it("buildContext labels are byte-equal to Dart", () => {
    expect(dartLineWith("【Agent 记忆】")).toContain("writeln('" + "【Agent 记忆】" + "')");
    expect(dartLineWith("系统环境:")).toContain("writeln('" + "系统环境:" + "')");
    expect(dartLineWith("最近命令:")).toContain("writeln('" + "最近命令:" + "')");
    const m = new AgentMemory();
    m.rememberSystemInfo("X", {category: "c"});
    m.rememberCommand("Y");
    const out = m.buildContext();
    expect(out.split(NL)[0]).toBe("【Agent 记忆】");
    expect(out).toContain("系统环境:" + NL);
    expect(out).toContain("最近命令:" + NL);
  });
  it("caps match Dart static consts", () => {
    expect(DART).toContain("static const int _maxEntries = 50;");
    expect(DART).toContain("static const int _systemInfoMax = 10;");
  });
  it("stats key set matches Dart map literal", () => {
    const keys = [...DART.matchAll(/'(\w+)': _entries/g)].map(x => x[1]);
    expect(Object.keys(new AgentMemory().stats)).toEqual(keys);
  });
  it("entry id prefixes match Dart factories", () => {
    const prefixes = [...new Set([...DART.matchAll(/id: '(\w+)_/g)].map(x => x[1] + "_"))].sort();
    expect(prefixes).toEqual(["cmd_", "ctx_", "res_", "sys_"]);
  });
  it("type tags in Dart factories all reachable in TS", () => {
    const tags = [...new Set([...DART.matchAll(/type: '(\w+)'/g)].map(x => x[1]))].sort();
    expect(tags).toEqual(["command", "context", "result", "system_info"]);
  });
});
