// builtin.ts - Phase 2 (W4) tool framework + pure-Node builtin tools.
//
// 1:1 port of the AgentTool/AgentToolRegistry/ToolResult framework from
// Dart ai_terminal/lib/services/agent_tool.dart. Concrete tools that run
// entirely in Node (local_file_read / local_dir_list / fetch_url) are
// implemented here; SSH/SFTP/orchestrator tools are W5 (they need the
// reverse-RPC bridge back to Dart + node-pty), so they are NOT stubbed as
// executable here to avoid pretending at the capability.
//
// AGENTS.md R9: tools read args ONLY through the typed ToolArgs accessors
// (see ./tool_args.ts); raw args[key] access in a tool body is banned.

import {readFileSync, readdirSync, statSync, existsSync} from "fs";
import {ToolArgs} from "./tool_args.js";
import {ShellType, wrapCommand} from "../utils/shell_detect.js";

// ── enums (aligned with agent_core/schema/tool.schema.json + rpc/schema.ts) ──
export enum ToolKind {
  read = "read",
  write = "write",
  destructive = "destructive",
  network = "network",
  orchestration = "orchestration",
}

export enum ToolSource {
  builtin = "builtin",
  mcpServer = "mcpServer",
}

export enum ToolScope {
  all = "all",
  sshSession = "sshSession",
  localSession = "localSession",
  orchestrator = "orchestrator",
}

// ── ToolResult (1:1 from Dart) ──
export interface HostExecutionResult {
  hostId: string;
  success: boolean;
  output?: string;
  error?: string;
  exitCode?: number;
  durationMs?: number;
  failureKind?: string;
}

export class ToolResult {
  readonly success: boolean;
  readonly output: string;
  readonly error?: string;
  readonly hostResults?: Record<string, HostExecutionResult>;
  readonly diffAdditions?: number;
  readonly diffDeletions?: number;
  readonly restoreFrom?: string;
  readonly restoreTo?: string;
  constructor(o: {success:boolean; output:string; error?:string; hostResults?:Record<string,HostExecutionResult>; diffAdditions?:number; diffDeletions?:number; restoreFrom?:string; restoreTo?:string;}) {
    this.success = o.success;
    this.output = o.output;
    this.error = o.error;
    this.hostResults = o.hostResults;
    this.diffAdditions = o.diffAdditions;
    this.diffDeletions = o.diffDeletions;
    this.restoreFrom = o.restoreFrom;
    this.restoreTo = o.restoreTo;
  }
  static success(output: string, extra: {hostResults?:Record<string,HostExecutionResult>; diffAdditions?:number; diffDeletions?:number; restoreFrom?:string; restoreTo?:string;} = {}): ToolResult {
    return new ToolResult({success: true, output, ...extra});
  }
  static failure(error: string, extra: {output?:string; hostResults?:Record<string,HostExecutionResult>} = {}): ToolResult {
    return new ToolResult({success: false, output: extra.output ?? "", error, hostResults: extra.hostResults});
  }
}

// ── AgentTool abstract (1:1 from Dart) ──
export abstract class AgentTool {
  abstract readonly name: string;
  abstract readonly description: string;
  /** Multi-line key:value param spec for the system prompt. */
  abstract readonly paramSpec: string;
  /** Side-effect class; default is conservative write. */
  get kind(): ToolKind { return ToolKind.write; }
  get source(): ToolSource { return ToolSource.builtin; }
  /** Scope; default all. */
  get scope(): ToolScope { return ToolScope.all; }
  /** Whether this tool records changes in the audit log. */
  get recordsChanges(): boolean { return this.kind === ToolKind.write || this.kind === ToolKind.destructive; }
  /** JSON Schema for OpenAI Function Calling. Return null to skip FC. */
  abstract toJsonSchema(): Record<string, unknown> | null;
  /** Execute the tool. executor is null for pure-Node tools. */
  abstract execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult>;
}

export interface ToolContext {
  /** Node executor (local PTY / shell). */
  executor?: (cmd: string, opts?: Record<string, unknown>) => Promise<{exitCode:number; stdout:string; stderr:string}>;
  /** Cancellation flag. */
  cancelled?: () => boolean;
  /** Host IDs in scope (for orchestration tools). */
  hostIds?: string[];
  /** Local session flag. */
  isLocalSession?: boolean;
}

// ── Registry (1:1 framework from Dart AgentToolRegistry) ──
interface RegisteredTool { tool: AgentTool; scope: ToolScope; }

export class AgentToolRegistry {
  private entries = new Map<string, RegisteredTool>();

  register(tool: AgentTool, scope: ToolScope = ToolScope.all): void { this.entries.set(tool.name, {tool, scope}); }
  unregister(name: string): void { this.entries.delete(name); }
  unregisterPrefix(prefix: string): void { for (const n of [...this.entries.keys()]) if (n.startsWith(prefix)) this.entries.delete(n); }
  get(name: string): AgentTool | undefined { return this.entries.get(name)?.tool; }
  has(name: string): boolean { return this.entries.has(name); }
  get all(): AgentTool[] { return [...this.entries.values()].map((e)=>e.tool); }

  /** Scope-filtered view: the single source for prompt + FC schema. */
  visibleFor(opts: {isLocalSession: boolean}): AgentTool[] {
    const out: AgentTool[] = [];
    for (const e of this.entries.values()) {
      switch (e.scope) {
        case ToolScope.all:
        case ToolScope.orchestrator: out.push(e.tool); break;
        case ToolScope.localSession: if (opts.isLocalSession) out.push(e.tool); break;
        case ToolScope.sshSession: if (!opts.isLocalSession) out.push(e.tool); break;
      }
    }
    return out;
  }

  isChangeRecordingTool(name: string): boolean { return this.get(name)?.recordsChanges ?? false; }

  /** OpenAI Function-Calling schema list; null-schema tools are skipped. */
  buildOpenAIToolsSchema(opts: {isLocalSession: boolean}): Record<string, unknown>[] {
    const out: Record<string, unknown>[] = [];
    for (const t of this.visibleFor(opts)) {
      const schema = t.toJsonSchema();
      if (!schema) continue;
      out.push({type: "function", function: {name: t.name, description: t.description, parameters: schema}});
    }
    return out;
  }

  /** MCP tool descriptor (schema/tool.schema.json shape) for the W5 MCP bridge. */
  mcpDescriptor(tool: AgentTool, source: string): Record<string, unknown> {
    return {
      name: tool.name,
      description: tool.description,
      inputSchema: tool.toJsonSchema() ?? {type: "object", properties: {}},
      kind: tool.kind,
      source,
      scope: tool.scope,
      idempotent: tool.kind !== ToolKind.write && tool.kind !== ToolKind.destructive,
    };
  }

  /** Build the tool-prompt text injected into the system prompt (CJK via \u escapes). */
  buildToolsPrompt(opts: {isLocalSession: boolean}): string {
    const tools = this.visibleFor(opts);
    if (tools.length === 0) return "";
    const L: string[] = [];
    L.push("\u3010\u53EF\u7528\u5DE5\u5177\u3011");
    L.push("\u5F53\u9700\u8981\u6267\u884C\u975E shell \u547D\u4EE4\u7684\u64CD\u4F5C\u65F6\uFF08\u5982\u4E0A\u4F20\u6587\u4EF6\u3001\u8DE8\u673A\u6267\u884C\uFF09\uFF0C\u4F7F\u7528 \"\u52A8\u4F5C: tool\" \u8C03\u7528\u5DE5\u5177\u3002");
    L.push("");
    for (const t of tools) {
      L.push("\u5DE5\u5177: " + t.name);
      L.push("  \u8BF4\u660E: " + t.description);
      L.push("  " + t.paramSpec);
      L.push("");
    }
    L.push("\u5DE5\u5177\u8C03\u7528\u683C\u5F0F\u793A\u4F8B\uFF08\u53C2\u6570\u5FC5\u987B\u7528\u591A\u884C key:value \u683C\u5F0F\uFF0C\u4E0D\u8981\u7528 JSON\uFF09:");
    L.push("\u601D\u8003: \u9700\u8981\u628A\u672C\u5730 dist \u76EE\u5F55\u4E0A\u4F20\u5230\u670D\u52A1\u5668");
    L.push("\u52A8\u4F5C: tool");
    L.push("\u5DE5\u5177: sftp_upload");
    L.push("\u53C2\u6570:");
    L.push("  local: /Users/x/proj/dist");
    L.push("  remote: /var/www/myapp");
    L.push("  recursive: true");
    L.push("  exclude: node_modules,.git");
    return L.join("\n").trimEnd();
  }
}

// ── pure-Node builtin tools (W4). Read-only + network; no Dart reverse-RPC. ──

/** local_file_read - read a local text file with line numbers. */
export class LocalFileReadTool extends AgentTool {
  readonly name = "local_file_read";
  readonly description: string = "\u8BFB\u53D6**\u672C\u673A**\uFF08\u8FD0\u884C App \u7684\u8FD9\u53F0\u673A\u5668\uFF09\u6587\u672C\u6587\u4EF6\uFF0C\u6309\u884C\u53F7\u8FD4\u56DE\u3002\u8981\u770B\u670D\u52A1\u5668\u4E0A\u7684\u6587\u4EF6\u8BF7\u7528 cat/sed \u8D70 SSH \u547D\u4EE4\uFF0C\u4E0D\u8981\u7528\u672C\u5DE5\u5177\u3002";
  readonly paramSpec: string = "\u53C2\u6570\u5217\u8868\uFF08\u591A\u884C key:value \u683C\u5F0F\uFF09\uFF1A\n  path: \u672C\u673A\u6587\u4EF6\u7EDD\u5BF9\u8DEF\u5F84\uFF08\u5FC5\u586B\uFF09\n  start_line: \u8D77\u59CB\u884C\uFF0C\u4ECE 1 \u5F00\u59CB\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 1\uFF09\n  max_lines: \u6700\u591A\u8FD4\u56DE\u884C\u6570\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 400\uFF09";
  get kind(): ToolKind { return ToolKind.read; }
  get recordsChanges(): boolean { return false; }
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        path: {type: "string", description: "absolute path on the local machine"},
        start_line: {type: "integer", description: "1-based start line"},
        max_lines: {type: "integer", description: "max lines to return"},
      },
      required: ["path"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const rawPath = args.getString("path");
    if (rawPath === "") {
      return ToolResult.failure("missing required param: path");
    }
    const startLine = args.getInt("start_line", 1);
    const maxLines = args.getInt("max_lines", 400);
    if (!existsSync(rawPath)) return ToolResult.failure("file not found: " + rawPath);
    const st = statSync(rawPath);
    if (st.isDirectory()) return ToolResult.failure("path is a directory, use local_dir_list: " + rawPath);
    const text = readFileSync(rawPath, "utf-8");
    const lines = text.split("\n");
    const start = Math.max(1, startLine);
    const end = Math.min(lines.length, start + maxLines - 1);
    const out: string[] = [];
    for (let i = start - 1; i < end; i++) out.push((i + 1) + "\t" + lines[i]);
    const header = "file: " + rawPath + " (" + lines.length + " lines, showing " + start + "-" + end + ")";
    const tail = end < lines.length ? "\n...more, use start_line: " + (end + 1) : "";
    return ToolResult.success(header + "\n" + out.join("\n") + tail);
  }
}

/** local_dir_list - list a local directory (files + size, dirs + / suffix). */
export class LocalDirListTool extends AgentTool {
  readonly name = "local_dir_list";
  readonly description: string = "\u5217\u51FA**\u672C\u673A**\u76EE\u5F55\u5185\u5BB9\uFF08\u6587\u4EF6\u5E26\u5927\u5C0F\uFF0C\u76EE\u5F55\u5E26 / \u540E\u7F00\uFF09\u3002\u9ED8\u8BA4\u8DF3\u8FC7 .git / node_modules / build \u7B49\u566A\u97F3\u76EE\u5F55\u3002";
  readonly paramSpec: string = "\u53C2\u6570\u5217\u8868\uFF08\u591A\u884C key:value \u683C\u5F0F\uFF09\uFF1A\n  path: \u672C\u673A\u76EE\u5F55\u7EDD\u5BF9\u8DEF\u5F84\uFF08\u5FC5\u586B\uFF09\n  depth: \u9012\u5F52\u5C42\u6570\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 1\uFF0C\u6700\u5927 3\uFF09\n  glob: \u53EA\u4FDD\u7559\u5339\u914D\u7684\u6587\u4EF6\u540D\uFF0C\u9017\u53F7\u5206\u9694\uFF0C\u5982 *.dart,*.yaml\uFF08\u53EF\u9009\uFF09\n  include_hidden: \u662F\u5426\u5305\u542B\u9690\u85CF\u6587\u4EF6\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 false\uFF09";
  get kind(): ToolKind { return ToolKind.read; }
  get recordsChanges(): boolean { return false; }
  static readonly SKIPPED_DIRS = new Set([".git","node_modules","build","dist",".dart_tool","__pycache__","target"]);
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        path: {type: "string", description: "absolute directory path"},
        depth: {type: "integer", description: "recursion depth, 1-3"},
        glob: {type: "string", description: "comma-separated glob patterns"},
        include_hidden: {type: "boolean", description: "include hidden files"},
      },
      required: ["path"],
    };
  }
  private static globToRe(glob: string): RegExp | null {
    let re = glob
      .replace(/[.+^${}()|[\]\\]/g, "\\$&")
      .replace(/\*/g, ".*")
      .replace(/\?/g, ".");
    try { return new RegExp("^" + re + "$"); } catch { return null; }
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const rawPath = args.getString("path");
    if (rawPath === "") return ToolResult.failure("missing required param: path");
    const depth = Math.min(3, args.getInt("depth", 1));
    const includeHidden = args.getBool("include_hidden", false);
    const glob = args.getStringList("glob", []);
    const patterns = glob.map((g) => LocalDirListTool.globToRe(g)).filter((r): r is RegExp => r !== null);
    if (!existsSync(rawPath)) return ToolResult.failure("directory not found: " + rawPath);
    const lines: string[] = [];
    const walk = (dir: string, d: number, indent: string) => {
      let entries: string[];
      try { entries = readdirSync(dir); } catch { return; }
      for (const entry of entries) {
        if (!includeHidden && entry.startsWith(".")) continue;
        if (LocalDirListTool.SKIPPED_DIRS.has(entry) && d >= depth) continue;
        if (patterns.length > 0 && !patterns.some((r) => r.test(entry))) continue;
        const full = dir + "/" + entry;
        let isDir = false;
        try { isDir = statSync(full).isDirectory(); } catch {}
        const suffix = isDir ? "/" : "";
        let sizeStr = "";
        if (!isDir) {
          try { sizeStr = "  " + statSync(full).size.toLocaleString() + " B"; } catch {}
        }
        lines.push(indent + entry + suffix + sizeStr);
        if (isDir && d < depth) walk(full, d + 1, indent + "  ");
      }
    };
    walk(rawPath, 1, "");
    const header = "directory: " + rawPath + " (depth=" + depth + ")";
    return ToolResult.success(header + "\n" + (lines.length ? lines.join("\n") : "(empty)"));
  }
}

/** fetch_url - fetch a URL body as plain text. */
export class FetchUrlTool extends AgentTool {
  readonly name = "fetch_url";
  readonly description: string = "\u6293\u53D6\u6307\u5B9A URL \u7684\u7F51\u9875\u6B63\u6587\uFF08\u7EAF\u6587\u672C\u683C\u5F0F\uFF09\u3002\u914D\u5408 web_search \u5DE5\u5177\u4F7F\u7528\uFF1A\u641C\u7D22\u5F97\u5230 URL \u540E\uFF0C\u53EF\u8C03\u672C\u5DE5\u5177\u8BFB\u53D6\u8BE6\u7EC6\u5185\u5BB9\u3002\u4E5F\u53EF\u72EC\u7ACB\u7528\u4E8E\u5DF2\u77E5 URL \u7684\u6587\u6863/\u9875\u9762\u6293\u53D6\u3002";
  readonly paramSpec: string = "\u53C2\u6570\u5217\u8868\uFF08\u591A\u884C key:value \u683C\u5F0F\uFF09\uFF1A\n  url: \u8981\u6293\u53D6\u7684 URL\uFF08\u5FC5\u586B\uFF0C\u9700\u4EE5 http:// \u6216 https:// \u5F00\u5934\uFF09\n  max_chars: \u6B63\u6587\u6700\u5927\u5B57\u7B26\u6570\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 20000\uFF09";
  get kind(): ToolKind { return ToolKind.network; }
  get recordsChanges(): boolean { return false; }
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        url: {type: "string", description: "full URL to fetch"},
        max_chars: {type: "integer", description: "max body chars (default 20000)"},
      },
      required: ["url"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const url = args.getString("url").trim();
    if (url === "") return ToolResult.failure("missing required param: url");
    const maxChars = args.getInt("max_chars", 20000);
    if (ctx.cancelled && ctx.cancelled()) return ToolResult.failure("fetch was cancelled");
    try {
      const resp = await fetch(url, {signal: AbortSignal.timeout(30000)});
      if (!resp.ok) {
        if (resp.status === 404) return ToolResult.failure("URL not found (HTTP 404): " + url);
        if (resp.status === 403) return ToolResult.failure("access denied (HTTP 403): " + url);
        return ToolResult.failure("HTTP " + resp.status + " for " + url);
      }
      const body = await resp.text();
      const cap = Math.max(1, maxChars);
      if (body.length <= cap) return ToolResult.success(body);
      const truncated = body.substring(0, cap) + "\n...[truncated, total " + body.length + " chars, showing first " + cap + "]";
      return ToolResult.success(truncated);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      return ToolResult.failure("fetch failed: " + msg);
    }
  }
}

// ── local_exec (W4): run a command on the local machine via child_process. ──
// Destructive kind; recordsChanges=false (local shell cannot be file-rolled-back
// like a remote edit, mirroring Dart LocalExecTool). Shell wrapper branches by
// shell type (R6) using shell_detect.wrapCommand.
export class LocalExecTool extends AgentTool {
  readonly name = "local_exec";
  readonly description: string = "\u5728**\u8FD0\u884C App \u7684\u8FD9\u53F0\u7535\u8111**\u4E0A\u6267\u884C\u672C\u5730\u547D\u4EE4\uFF08\u4E0D\u662F\u5F53\u524D SSH \u670D\u52A1\u5668\uFF09\u3002Windows \u9ED8\u8BA4 PowerShell\uFF0CmacOS/Linux \u9ED8\u8BA4 bash\uFF1B\u7528\u4E8E\u672C\u673A Docker Desktop\u3001\u76D8\u7B26\u8DEF\u5F84\uFF08D:\\...\uFF09\u3001\u672C\u673A\u6587\u4EF6/\u670D\u52A1\u3002\u670D\u52A1\u5668\u4E0A\u7684\u547D\u4EE4\u8BF7\u76F4\u63A5\u7528 execute\uFF0C\u4E0D\u8981\u7528\u672C\u5DE5\u5177\u3002cwd \u5FC5\u987B\u5728\u5DF2\u6388\u6743\u7684\u672C\u5730\u76EE\u5F55\u5185\uFF1B\u672A\u6388\u6743\u65F6\u4F1A\u8BF7\u6C42\u7528\u6237\u786E\u8BA4\u3002\u547D\u4EE4\u9700\u8981\u4EA4\u4E92\u8F93\u5165\uFF08\u5982\u767B\u5F55\uFF09\u65F6\u8BF7\u6539\u7528\u7EC8\u7AEF\u3002";
  readonly paramSpec: string = "\u53C2\u6570\u5217\u8868\uFF08\u591A\u884C key:value \u683C\u5F0F\uFF09\uFF1A\n  command: \u8981\u6267\u884C\u7684\u672C\u5730\u547D\u4EE4\uFF08\u5FC5\u586B\uFF1B\u591A\u884C\u547D\u4EE4 PowerShell/bash \u7528 ; \u8FDE\u63A5\uFF0Ccmd \u7528 &\uFF0C\u4E0D\u8981\u76F4\u63A5\u6362\u884C\uFF09\n  cwd: \u5DE5\u4F5C\u76EE\u5F55\u7EDD\u5BF9\u8DEF\u5F84\uFF08\u5FC5\u586B\uFF0C\u5FC5\u987B\u5728\u5DF2\u6388\u6743\u7684\u672C\u5730\u76EE\u5F55\u5185\uFF09\n  timeout: \u8D85\u65F6\u79D2\u6570\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 120\uFF0C\u6700\u5927 600\uFF1B\u5927\u578B docker save/\u6784\u5EFA\u53EF\u8BBE 300\u2013600\uFF09\n  shell: powershell | cmd | bash | sh\uFF08\u53EF\u9009\uFF0C\u4E0D\u586B\u6309\u5E73\u53F0\u9ED8\u8BA4\uFF09";
  get kind(): ToolKind { return ToolKind.destructive; }
  get recordsChanges(): boolean { return false; }
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        command: {type: "string", description: "local command to run"},
        cwd: {type: "string", description: "working dir (must be an authorized local dir)"},
        timeout: {type: "integer", description: "timeout seconds (default 120, max 600)"},
        shell: {type: "string", description: "powershell | cmd | bash | sh (default: platform)"},
      },
      required: ["command", "cwd"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const command = args.getString("command").trim();
    const cwd = args.getString("cwd").trim();
    if (command === "") return ToolResult.failure("missing required param: command");
    if (cwd === "") return ToolResult.failure("missing required param: cwd");
    const timeoutSec = Math.min(600, args.getInt("timeout", 120));
    const shellArg = args.getString("shell", "").toLowerCase();
    const shell: ShellType = shellArg !== "" ? (shellArg as ShellType) : (process.platform === "win32" ? "powershell" : "bash");
    const marker = "EXITCODE_LOCAL";
    const wrapped = wrapCommand(command, shell, marker);
    const t0 = Date.now();
    try {
      const {stdout, stderr, exitCode} = await runLocalCommand(wrapped, cwd, shell, timeoutSec);
      const durationMs = Date.now() - t0;
      const output = stdout + (stderr ? "\n[stderr]\n" + stderr : "");
      if (exitCode === 0) return ToolResult.success(output.trimEnd() + "\n[exit 0, " + durationMs + "ms]");
      return ToolResult.failure("command exited with code " + exitCode, {output: output.trimEnd()});
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      if (/timeout/i.test(msg)) return ToolResult.failure("command timed out after " + timeoutSec + "s: " + command);
      return ToolResult.failure("exec failed: " + msg);
    }
  }
}

/** Spawn a wrapped command in the chosen shell; bounded buffers, tail-retained (R8). */
export async function runLocalCommand(wrapped: string, cwd: string, shell: ShellType, timeoutSec: number): Promise<{stdout:string;stderr:string;exitCode:number}> {
  const cp = await import("child_process");
  const args = shell === "powershell" ? ["-NoProfile","-Command", wrapped] : shell === "cmd" ? ["/c", wrapped] : ["-c", wrapped];
  const bin = shell === "powershell" ? "powershell" : shell === "cmd" ? "cmd" : (shell === "sh" ? "sh" : "bash");
  const MAX = 20000; // bounded buffer (R8)
  return await new Promise((resolve, reject) => {
    const child = cp.spawn(bin, args, {cwd, shell: false});
    let out = "", err = "";
    const timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("timeout after " + timeoutSec + "s")); }, timeoutSec * 1000);
    child.stdout.on("data", (d) => { out += d.toString(); if (out.length > MAX * 4) out = out.slice(-MAX); });
    child.stderr.on("data", (d) => { err += d.toString(); if (err.length > MAX * 4) err = err.slice(-MAX); });
    child.on("close", (code) => { clearTimeout(timer); resolve({stdout: out.slice(-MAX), stderr: err.slice(-MAX), exitCode: code ?? -1}); });
    child.on("error", (e) => { clearTimeout(timer); reject(e); });
  });
}
