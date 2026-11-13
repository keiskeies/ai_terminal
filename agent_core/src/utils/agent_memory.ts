// utils/agent_memory.ts - r214 port of models/agent_memory.dart (import-free,
// pure in-memory, per-connection instance). Label literals were extracted
// from the Dart source at generation time; the oracle test re-extracts
// them at run time and diffs, so drift is impossible.

// Agent 记忆条目（纯内存，不持久化）
export class MemoryEntry {
  readonly id: string;
  readonly type: string;
  readonly content: string;
  readonly metadata?: string;
  readonly timestamp: number;

  constructor(o: {
    id: string;
    type: string;
    content: string;
    metadata?: string;
    timestamp?: number;
  }) {
    this.id = o.id;
    this.type = o.type;
    this.content = o.content;
    this.metadata = o.metadata;
    this.timestamp = o.timestamp ?? Date.now();
  }

  get metadataMap(): Record<string, unknown> | null {
    if (this.metadata === undefined) return null;
    return parseSimpleJson(this.metadata);
  }

  static command(command: string, o?: { description?: string; result?: string }): MemoryEntry {
    // Dart 插值把 null 写成字面 null，两个键恒定存在
    const description = o?.description === undefined ? "null" : o.description;
    const result = o?.result === undefined ? "null" : o.result;
    return new MemoryEntry({
      id: "cmd_" + Date.now(),
      type: "command",
      content: command,
      metadata: "{\"description\":\"" + description + "\",\"result\":\"" + result + "\"}",
    });
  }

  static systemInfo(info: string, o?: { category?: string }): MemoryEntry {
    const category = o?.category === undefined ? "null" : o.category;
    return new MemoryEntry({
      id: "sys_" + Date.now(),
      type: "system_info",
      content: info,
      metadata: "{\"category\":\"" + category + "\"}",
    });
  }

  static result(command: string, output: string, o?: { success?: boolean }): MemoryEntry {
    const success = o?.success ?? true;
    return new MemoryEntry({
      id: "res_" + Date.now(),
      type: "result",
      content: command + "\n" + output,
      metadata: "{\"success\":" + success + "}",
    });
  }

  static context(context: string): MemoryEntry {
    return new MemoryEntry({
      id: "ctx_" + Date.now(),
      type: "context",
      content: context,
    });
  }
}

// Dart 简易 {k:v,k:v} 解析器（非严格 JSON，保持 1:1 行为）
function parseSimpleJson(s: string): Record<string, unknown> | null {
  const t = s.trim();
  if (!t.startsWith("{") || !t.endsWith("}")) return null;
  const inner = t.substring(1, t.length - 1);
  const map: Record<string, unknown> = {};
  if (inner.length > 0) {
    for (const pair of inner.split(",")) {
      const idx = pair.indexOf(":");
      if (idx > 0) {
        const key = pair.substring(0, idx).trim();
        let val = pair.substring(idx + 1).trim();
        if (val.startsWith("\"") && val.endsWith("\"")) {
          val = val.substring(1, val.length - 1);
        } else if (val === "true") {
          map[key] = true;
          continue;
        } else if (val === "false") {
          map[key] = false;
          continue;
        }
        map[key] = val;
      }
    }
  }
  return map;
}
// Agent 记忆系统（纯内存，每个连接/Tab 独立实例）
export class AgentMemory {
  private static readonly maxEntries = 50;
  private static readonly systemInfoMax = 10;

  private entries: MemoryEntry[] = [];

  add(entry: MemoryEntry): void {
    this.entries.push(entry);
    this.trim();
  }

  rememberCommand(command: string, o?: { description?: string }): void {
    this.add(MemoryEntry.command(command, o));
  }

  rememberResult(command: string, output: string, o?: { success?: boolean }): void {
    this.add(MemoryEntry.result(command, output, o));
  }

  rememberSystemInfo(info: string, o?: { category?: string }): void {
    this.add(MemoryEntry.systemInfo(info, o));
  }

  getRecent(o?: { limit?: number }): MemoryEntry[] {
    const limit = o?.limit ?? 20;
    const sorted = this.entries.slice().sort((a, b) => b.timestamp - a.timestamp);
    return sorted.slice(0, limit);
  }

  getRecentCommands(o?: { limit?: number }): MemoryEntry[] {
    const limit = o?.limit ?? 10;
    return this.getRecent({ limit }).filter(e => e.type === "command" || e.type === "result");
  }

  getSystemSummary(): string {
    // Dart: 全量 where(system_info) → reversed → take(10) → join('\n')
    const sys = this.entries.filter(e => e.type === "system_info").slice().reverse()
      .slice(0, AgentMemory.systemInfoMax);
    return sys.map(e => e.content).join("\n");
  }

  buildContext(): string {
    const recent = this.getRecent({ limit: 10 });
    if (recent.length === 0) return "";
    const lines: string[] = [];
    const writeln = (s: string) => lines.push(s + "\n");
    writeln("【Agent 记忆】");
    const systemInfos = recent.filter(e => e.type === "system_info");
    if (systemInfos.length > 0) {
      writeln("系统环境:");
      for (const info of systemInfos.slice(0, 3)) {
        writeln("  - " + info.content);
      }
    }
    const commands = recent.filter(e => e.type === "command").slice(0, 3);
    if (commands.length > 0) {
      writeln("最近命令:");
      for (const cmd of commands) {
        writeln("  - " + cmd.content);
      }
    }
    return lines.join("");
  }

  private trim(): void {
    this.entries.sort((a, b) => b.timestamp - a.timestamp);
    if (this.entries.length > AgentMemory.maxEntries) {
      this.entries.length = AgentMemory.maxEntries;
    }
  }

  clear(): void {
    this.entries.length = 0;
  }

  get stats(): Record<string, number> {
    const count = (t: string) => this.entries.filter(e => e.type === t).length;
    return {
      total: this.entries.length,
      commands: count("command"),
      results: count("result"),
      system_info: count("system_info"),
      context: count("context"),
    };
  }
}
