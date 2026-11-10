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

import {readFileSync, readdirSync, statSync, existsSync, mkdirSync, copyFileSync, cpSync, rmSync, renameSync, lstatSync} from "fs";
import {ToolArgs} from "./tool_args.js";
import {ShellType, wrapCommand, extractExitMarker} from "../utils/shell_detect.js";
import {basename, dirname, isAbsolute, join, normalize, relative, sep} from "path";
import {LineDiff} from "../utils/line_diff.js";
import {decodeEscapedText, decodeContent, writeLocalFile, patchLocalFile, TRASH_DIR_NAME} from "../utils/local_file_ops.js";
import {LocalFilePolicy, LocalPathDecision, LocalPathVerdict} from "../utils/local_file_policy.js";
import {looksLikePosixRemotePath} from "../utils/local_file_ops.js";

// One glob->RegExp implementation, shared by local_dir_list and local_file_search.
// Byte-faithful to Dart _globToRegExp (local_file_tools.dart:275 and :353, which are
// identical): trim, skip blanks, escape, then star->.* and question->dot.
//
// Case polarity comes from Dart "caseSensitive: !Platform.isWindows": the pattern
// matches case-INSENSITIVELY on Windows (NTFS lookups are case-insensitive) and
// case-SENSITIVELY elsewhere. With the flag backwards, glob filters silently admit
// names the user never asked for on Linux/macOS and refuse intended matches on
// Windows - a filter that drops files only yields a shorter list, so nothing fails
// loudly. Two copies used to exist: the dir-list one was case-sensitive on every OS
// and the search one had the flag inverted, so the two tools disagreed about the
// same glob. Keep exactly one implementation.
// ---- LocalFilePolicy wiring (Dart LocalFileTool._resolve, 1:1) ----
//
// Dart gates every local_* tool through LocalFileTool._resolve (local_file_tools.dart:29-46):
// it calls policy.decide(), and on !isAllowed returns a failure whose first line is a
// per-verdict Chinese prefix, then the reason and a fixed hint pointing the user at the
// settings page. The decision.resolved path (already symlink-collapsed by decide) replaces
// the AI-supplied raw path for every later IO - itself a hardening, since it is the
// post-realpath target rather than the string the model typed.

// Node-only seam, disclosed not invented. Dart re-reads the policy from SettingsDao on each
// call; agent_core is headless, so a provider is injectable. The default is a trustedHost
// policy: it keeps the historical "host trusted" posture (no allowlist prompt for ordinary
// paths) while still running the reserved-trash and checkPath blacklist gates FIRST, so a
// sensitive path is refused regardless of embedder. A caller wanting Dart desktop semantics
// injects a deny-all policy with an explicit allowlist.
export type LocalFilePolicyProvider = () => LocalFilePolicy;
const TRUSTED_HOST = (): LocalFilePolicy => new LocalFilePolicy({trustedHost: true});
let defaultPolicyProvider: LocalFilePolicyProvider = TRUSTED_HOST;
export function setDefaultLocalFilePolicy(provider: LocalFilePolicyProvider): void {
  defaultPolicyProvider = provider;
}
export function resetDefaultLocalFilePolicy(): void { defaultPolicyProvider = TRUSTED_HOST; }
export function defaultLocalFilePolicy(): LocalFilePolicy { return defaultPolicyProvider(); }

// verdict -> refusal prefix, byte-faithful to the Dart switch at local_file_tools.dart:32-38.
// The allowed arm is unreachable here (decide already admitted that path) but Dart spells it
// out, so the total mapping is kept rather than a partial one.
const REFUSE_PREFIX: Record<string, string> = {
  [LocalPathVerdict.sensitive]: "敏感路径禁止访问",
  [LocalPathVerdict.reserved]: "系统保留目录",
  [LocalPathVerdict.notInAllowlist]: "路径未获授权",
  [LocalPathVerdict.escape]: "路径跳出授权目录",
  [LocalPathVerdict.allowed]: "路径不可用",
};

// Dart _remotePathHint (local_file_tools.dart:52-57): fires only on notInAllowlist + Windows
// + a POSIX-looking path. For a sensitive/reserved refusal the hint is withheld on purpose -
// there it would nudge the AI around a denial that is correct.
function remotePathHint(rawPath: string, verdict: string): string {
  if (verdict !== LocalPathVerdict.notInAllowlist) return "";
  if (process.platform !== "win32" || !looksLikePosixRemotePath(rawPath)) return "";
  return "\n注意: 这看起来是远程主机的路径，而 local_* 工具只改这台电脑。要改服务器文件请用 file_write / file_patch / sftp_upload。";
}

// Dart _resolve: a LocalPathDecision on success, or a ready-to-return failure ToolResult.
function resolveLocalPath(rawPath: string, policy: LocalFilePolicy): LocalPathDecision | ToolResult {
  const decision = policy.decide(rawPath);
  if (!decision.isAllowed) {
    const prefix = REFUSE_PREFIX[decision.verdict];
    return ToolResult.failure(
      prefix + ": " + rawPath + "\n原因: " + (decision.reason ?? "未通过白名单判定") + "\n" + "若确需访问，请让用户在 设置 → Agent → 本地文件 中添加该目录。"
      + remotePathHint(rawPath, decision.verdict),
    );
  }
  return decision;
}

// ── local_exec cwd gate (Dart local_exec_tool.dart:108-151, 1:1) ──
//
// Dart gates the working directory, not just file paths: sensitive / reserved / escape
// refuse outright, notInAllowlist asks the user through an injected authorization request
// and RE-READS the policy afterwards (the settings dialog writes back), and a cancellation
// check sits after the (possibly long) dialog so a user cancel cannot still create
// directories or run commands. The Node port mirrors all four steps. The dialog seam is
// injectable because agent_core is headless: with no callback wired, notInAllowlist
// refuses with the same guidance text Dart shows when request == null. The default
// trustedHost provider admits ordinary cwds at decide() - the historical posture - while
// the blacklist still blocks sensitive directories before anything spawns.
export type LocalDirAuthorizationRequest = (dir: string, reason: string) => Promise<boolean>;
let defaultDirAuthRequest: LocalDirAuthorizationRequest | null = null;
export function setLocalDirAuthorizationRequest(cb: LocalDirAuthorizationRequest | null): void {
  defaultDirAuthRequest = cb;
}

// Dart _expandHome (local_exec_tool.dart:259-267): tilde + backslash-tilde on Windows.
function expandHome(rawPath: string): string {
  if (rawPath === "~" || rawPath.startsWith("~/") || rawPath.startsWith("~" + String.fromCharCode(92))) {
    const home = process.env.USERPROFILE ?? process.env.HOME;
    if (home !== undefined && home !== "") {
      let rest = rawPath.slice(1);
      if (rest.startsWith("/") || rest.startsWith(String.fromCharCode(92))) rest = rest.slice(1);
      return normalize(join(home, rest));
    }
  }
  return rawPath;
}

// Dart _clipForProgress (local_exec_tool.dart:288-291): collapse whitespace, 160 chars + ellipsis.
function clipForProgress(command: string): string {
  const oneLine = command.replace(new RegExp("\\s+", "g"), " ").trim();
  return oneLine.length <= 160 ? oneLine : oneLine.slice(0, 160) + "…";
}

// The full Dart verdict switch over the cwd. Returns the post-decide resolved cwd (the
// string every later mkdir/spawn must use), or a ready-to-return failure ToolResult.
async function resolveExecCwd(cwd: string, command: string, ctx: ToolContext): Promise<string | ToolResult> {
  let policy = defaultLocalFilePolicy();
  const decision = policy.decide(cwd);
  if (decision.verdict === LocalPathVerdict.sensitive || decision.verdict === LocalPathVerdict.reserved || decision.verdict === LocalPathVerdict.escape) {
    return ToolResult.failure("本机目录被安全策略拒绝: " + decision.resolved + "\n原因: " + (decision.reason ?? "敏感路径"));
  }
  if (decision.verdict === LocalPathVerdict.notInAllowlist) {
    const request = defaultDirAuthRequest;
    if (request === null) {
      return ToolResult.failure(
        "本机目录未授权: " + decision.resolved + "\n"
        + "原因: " + (decision.reason ?? "不在授权目录内") + "\n"
        + "请让用户在 设置 → Agent → 本地文件 中添加该目录，或改用远程 execute。",
      );
    }
    const willCreate = !(existsSync(decision.resolved) && statSync(decision.resolved).isDirectory());
    const approved = await request(
      decision.resolved,
      "local_exec 需要在该目录执行本机命令：" + clipForProgress(command)
      + (willCreate ? "（目录不存在，允许后将创建）" : ""),
    );
    if (!approved) {
      return ToolResult.failure(
        "用户拒绝授权本机目录: " + decision.resolved + "，命令未执行。"
        + "请用 ask 询问用户是否授权，或改用远程 execute；不要反复重试同一目录。",
      );
    }
    // Dart:136-138 - the dialog wrote the allowlist back; re-read THEN re-decide.
    policy = defaultLocalFilePolicy();
    const after = policy.decide(cwd);
    if (!after.isAllowed) {
      return ToolResult.failure(
        "授权后仍无法访问本机目录: " + after.resolved + "\n"
        + "原因: " + (after.reason ?? "未通过白名单判定"),
      );
    }
    // fall through with the freshly decided path
    return cancelGuard(after.resolved, ctx);
  }
  return cancelGuard(decision.resolved, ctx);
}

// Dart:148-151 - the approval dialog can sit open for a long time; a cancel meanwhile
// must stop before any mkdir/spawn. ctx.cancelled mirrors Dart isTaskActive: only an
// explicit "not active" refuses (a host that wires no callback behaves like Dart null).
function cancelGuard(resolvedCwd: string, ctx: ToolContext): string | ToolResult {
  if (ctx.cancelled !== undefined && ctx.cancelled()) {
    return ToolResult.failure("任务已取消，本机命令未执行。");
  }
  return resolvedCwd;
}

function globToRegExp(glob: string): RegExp | null {
  const trimmed = glob.trim();
  if (trimmed === "") return null;
  let re = trimmed
    .replace(/[.+^$\{\}\(\)\|\[\]\\]/g, "\\$&")
    .replace(/\*/g, ".*")
    .replace(/\?/g, ".");
  try { return new RegExp("^" + re + "$", process.platform === "win32" ? "i" : undefined); }
  catch { return null; }
}


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
    const policy = defaultLocalFilePolicy();
    const resolved = resolveLocalPath(rawPath, policy);
    if (resolved instanceof ToolResult) return resolved;
    const fp = resolved.resolved;
    const startLine = args.getInt("start_line", 1);
    const maxLines = args.getInt("max_lines", 400);
    if (!existsSync(fp)) return ToolResult.failure("file not found: " + rawPath);
    const st = statSync(fp);
    if (st.isDirectory()) return ToolResult.failure("path is a directory, use local_dir_list: " + rawPath);
    const text = readFileSync(fp, "utf-8");
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
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const rawPath = args.getString("path");
    if (rawPath === "") return ToolResult.failure("missing required param: path");
    const depth = Math.min(3, args.getInt("depth", 1));
    const includeHidden = args.getBool("include_hidden", false);
    const glob = args.getStringList("glob", []);
    const patterns = glob.map((g) => globToRegExp(g)).filter((r): r is RegExp => r !== null);
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
  get scope(): ToolScope { return ToolScope.all; }
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        url: {type: "string", description: "\u8981\u6293\u53D6\u7684 URL"},
        max_chars: {type: "integer", description: "\u6B63\u6587\u6700\u5927\u5B57\u7B26\u6570\uFF08\u9ED8\u8BA4 20000\uFF09"},
      },
      required: ["url"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const url = args.getString("url").trim();
    const maxChars = args.getInt("max_chars", 0);
    if (url === "") return ToolResult.failure("\u53C2\u6570\u7F3A\u5931: url \u4E3A\u5FC5\u586B\u9879");
    if (!url.startsWith("http://") && !url.startsWith("https://")) {
      return ToolResult.failure("\u53C2\u6570\u9519\u8BEF: url \u5FC5\u987B\u4EE5 http:// \u6216 https:// \u5F00\u5934");
    }
    if (ctx.cancelled && ctx.cancelled()) return ToolResult.failure("\u6293\u53D6\u5DF2\u88AB\u53D6\u6D88", {output: ""});
    const cap = maxChars > 0 ? maxChars : 20000;
    // Bridge ctx.cancelled() to an AbortSignal so the in-flight fetch aborts on cancel
    const ctrl = new AbortController();
    const checkTimer = setInterval(() => { if (ctx.cancelled?.()) ctrl.abort(); }, 250);
    try {
      const resp = await fetch(url, {
        signal: AbortSignal.timeout(30000),
        headers: {
          "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
          "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
      });
      const respBody = await resp.text();
            if (resp.status === 404) {
        return ToolResult.failure("URL \u4E0D\u5B58\u5728 (HTTP 404)\uFF1A\u8BF7\u786E\u8BA4\u94FE\u63A5\u662F\u5426\u6B63\u786E");
      }
      if (resp.status === 403) {
        return ToolResult.failure("\u76EE\u6807\u7AD9\u70B9\u62D2\u7EDD\u8BBF\u95EE (HTTP 403)\uFF1A\u53EF\u80FD\u9700\u8981\u767B\u5F55\u6216\u6709\u53CD\u722C\u673A\u5236");
      }
      if (resp.status >= 400) {
        return ToolResult.failure("HTTP " + resp.status + " for " + url);
      }
      if (respBody === "") {
        return ToolResult.success("\u6293\u53D6\u6210\u529F\uFF0C\u4F46\u9875\u9762\u5185\u5BB9\u4E3A\u7A7A\u3002");
      }
      const isHtml = /text\/html|text\/x-html/i.test(resp.headers.get("content-type") ?? "") || respBody.trimStart().startsWith("<");
      const title = isHtml ? _extractTitle(respBody) : "";
      const text = isHtml ? _htmlToText(respBody) : respBody;
      const lines: string[] = [];
      if (title !== "") { lines.push("\u6807\u9898: " + title); lines.push(""); }
      lines.push("URL: " + url);
      lines.push("");
      lines.push("\u6B63\u6587:");
      if (text.length <= cap) {
        lines.push(text);
      } else {
        lines.push(text.substring(0, cap));
        lines.push("");
        lines.push("(\u6B63\u6587\u5DF2\u622A\u65AD\uFF0C\u5171 " + text.length + " \u5B57\u7B26\uFF0C\u4EC5\u663E\u793A\u524D " + cap + " \u5B57\u7B26)");
      }
      return ToolResult.success(lines.join("\n").trimEnd());
} catch (e: unknown) {
      if (ctrl.signal.aborted) return ToolResult.failure("\u6293\u53D6\u5DF2\u88AB\u53D6\u6D88", {output: ""});
      if (e instanceof TypeError && /fetch failed|network|ECONN|ETIMEDOUT/i.test(e.message)) {
        return ToolResult.failure("\u7F51\u7EDC\u9519\u8BEF\uFF1A" + e.message);
      }
      // resp.status check: re-fetch is not possible; use a lightweight status probe via a second request only when needed.
      const msg = e instanceof Error ? e.message : String(e);
      return ToolResult.failure("\u6293\u53D6\u5931\u8D25: " + msg);
    } finally {
      clearInterval(checkTimer);
    }
  }
}

// ── HTML→text helpers (private; 1:1 from Dart web_tools.dart _extractTitle/_htmlToText/_decodeEntities) ──
function _extractTitle(html: string): string {
  const m = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
  if (m === null) return "";
  return _decodeEntities(m[1] ?? "").trim();
}
function _htmlToText(html: string): string {
  let s = html;
  // 1. strip non-content blocks (script/style/nav/head/header/footer/noscript/svg/iframe)
  s = s.replace(/<(script|style|nav|head|header|footer|noscript|svg|iframe)[^>]*>[\s\S]*?<\/\1>/gi, "");
  // 2. block-level closing tags -> newline
  s = s.replace(/<\/(p|div|section|article|li|h[1-6]|tr|br|blockquote|pre)>/gi, "\n");
  // 3. <br> single tag
  s = s.replace(/<br\s*\/?>/gi, "\n");
  // 4. strip remaining tags
  s = s.replace(/<[^>]+>/g, "");
  // 5. decode entities
  s = _decodeEntities(s);
  // 6. compress 3+ newlines to 2, trim line edges
  const lines = s.split("\n").map(l => l.trim());
  s = lines.join("\n").replace(/\n{3,}/g, "\n\n");
  return s.trim();
}
function _decodeEntities(s: string): string {
  return s
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&apos;/g, "'").replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (m, code) => { const c = parseInt(code,10); return isNaN(c) ? m : String.fromCharCode(c); })
    .replace(/&#x([0-9a-fA-F]+);/g, (m, hex) => { const c = parseInt(hex,16); return isNaN(c) ? m : String.fromCharCode(c); });
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
    const rawCwd = args.getString("cwd").trim();
    if (command === "") return ToolResult.failure("missing required param: command");
    if (rawCwd === "") return ToolResult.failure("missing required param: cwd");
    // Dart :103-106 - home expansion happens BEFORE the absolute-path check, and the
    // refusal still quotes the string the model sent.
    const expandedCwd = expandHome(rawCwd);
    if (!isAbsolute(expandedCwd)) {
      return ToolResult.failure("cwd 必须是绝对路径（收到: " + rawCwd + "）。不要使用 . 或相对路径。");
    }
    const gated = await resolveExecCwd(expandedCwd, command, ctx);
    if (gated instanceof ToolResult) return gated;
    const cwd = gated;
    const timeoutSec = Math.min(600, args.getInt("timeout", 120));
    const shellArg = args.getString("shell", "").toLowerCase();
    const shell: ShellType = shellArg !== "" ? (shellArg as ShellType) : (process.platform === "win32" ? "powershell" : "bash");
    const marker = "EXITCODE_LOCAL:"; // Dart convention: marker ends with ':' (donePattern = marker + digits)
    const wrapped = wrapCommand(command, shell, marker);
    // Dart:153-161 - create the approved working directory when it does not exist yet.
    if (!existsSync(cwd)) {
      try { mkdirSync(cwd, {recursive: true}); }
      catch (e: unknown) {
        return ToolResult.failure("无法创建工作目录 " + cwd + ": " + (e instanceof Error ? e.message : String(e)));
      }
    }
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
export async function runLocalCommand(wrapped: string, cwd: string, shell: ShellType, timeoutSec: number, marker: string = "EXITCODE_LOCAL:"): Promise<{stdout:string;stderr:string;exitCode:number}> {
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
    child.on("close", (code) => {
      clearTimeout(timer);
      // Tail retained (R8.2) - the exit marker is the last line the wrapper
      // prints, so the tail cap always preserves it. R8.1: resolve the REAL
      // exit code from the marker pattern (marker + digits), stripping the
      // marker line from stdout. The child close code is only a fallback for
      // paths where the echo never ran (early `exit`, shell syntax error,
      // spawn failure) - the pipeline tail would otherwise be the marker
      // command's own status (0) and every failure would look successful.
      const outFull = out.slice(-MAX);
      const errFull = err.slice(-MAX);
      const hit = extractExitMarker(outFull, marker);
      if (hit !== null) {
        resolve({stdout: outFull.slice(0, hit.before.length).replace(/\r?\n$/, ""), stderr: errFull, exitCode: hit.exitCode});
        return;
      }
      resolve({stdout: outFull, stderr: errFull, exitCode: code ?? -1});
    });
    child.on("error", (e) => { clearTimeout(timer); reject(e); });
  });
}


// \u2500\u2500 W4 local-file write/patch/move/delete tools (Dart local_file_tools.dart) \u2500\u2500
// Each of the six local_* tools below routes its path through resolveLocalPath ->
// LocalFilePolicy.decide() (the Dart LocalFileTool._resolve gate): the reserved-trash
// and checkPath blacklist run first, and every later fs call uses decision.resolved -
// the post-realpath target, not the string the model typed. The default provider is a
// trustedHost policy (wide allowlist, because a headless host has no Settings page);
// embedders that want Dart desktop semantics inject a strict allowlist via
// setDefaultLocalFilePolicy.

// Dart utf8Decode(List<int>): utf8.decode with a lossy fallback.
function utf8decodeBytes(bytes: Buffer): string {
  try { return Buffer.from(bytes).toString("utf-8"); }
  catch { return Buffer.from(bytes).toString("latin1"); }
}

/** local_file_search - content search over a local file/dir (Dart walker, no shell). */
export class LocalFileSearchTool extends AgentTool {
  readonly name = "local_file_search";
  readonly description: string = "\u5728**\u672C\u673A**\u6587\u4EF6\u6216\u76EE\u5F55\u91CC\u6309\u5185\u5BB9\u641C\u7D22\uFF0C\u8FD4\u56DE path:line: \u5185\u5BB9\u3002\u7528 Dart \u904D\u5386\u5B9E\u73B0\uFF0C\u8DE8\u5E73\u53F0\u4E14\u4E0D\u53D7 shell/locale \u5F71\u54CD\uFF08\u670D\u52A1\u5668\u4E0A\u8BF7\u4ECD\u7528\u8FDC\u7A0B grep\uFF09\u3002";
  readonly paramSpec: string = "\u53C2\u6570\u5217\u8868\uFF08\u591A\u884C key:value \u683C\u5F0F\uFF09\uFF1A\n  path: \u672C\u673A\u6587\u4EF6\u6216\u76EE\u5F55\u7EDD\u5BF9\u8DEF\u5F84\uFF08\u5FC5\u586B\uFF09\n  query: \u8981\u641C\u7D22\u7684\u6587\u672C\uFF08\u5FC5\u586B\uFF0C\u6309\u5B57\u9762\u91CF\u5339\u914D\uFF09\n  glob: \u6587\u4EF6\u540D\u8FC7\u6EE4\uFF0C\u9017\u53F7\u5206\u9694\uFF0C\u5982 *.dart\uFF08\u53EF\u9009\uFF09\n  ignore_case: \u5FFD\u7565\u5927\u5C0F\u5199\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 false\uFF09\n  max_matches: \u6700\u591A\u8FD4\u56DE\u547D\u4E2D\u884C\u6570\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 100\uFF09";
  get kind(): ToolKind { return ToolKind.read; }
  get recordsChanges(): boolean { return false; }
  static readonly SKIPPED_DIRS = new Set([".git","node_modules","build","dist",".dart_tool","__pycache__","target"]);
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        path: {type: "string"},
        query: {type: "string"},
        glob: {type: "string"},
        ignore_case: {type: "boolean"},
        max_matches: {type: "integer"},
      },
      required: ["path", "query"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const rawPath = args.getString("path");
    const query = args.getString("query");
    if (rawPath === "") return ToolResult.failure("missing required param: path");
    if (query === "") return ToolResult.failure("\u53C2\u6570\u7F3A\u5931: query \u5FC5\u586B");
    const policy = defaultLocalFilePolicy();
    const resolved = resolveLocalPath(rawPath, policy);
    if (resolved instanceof ToolResult) return resolved;
    const fp = resolved.resolved;
    if (!existsSync(fp)) return ToolResult.failure("\u8DEF\u5F84\u4E0D\u5B58\u5728: " + rawPath);
    const rootIsFile = statSync(fp).isFile();
    const ignoreCase = args.getBool("ignore_case", false);
    const maxMatches = Math.max(1, Math.min(1000, args.getInt("max_matches", 100)));
    const needle = ignoreCase ? query.toLowerCase() : query;
    const patterns = args.getStringList("glob", [])
      .map(globToRegExp).filter((r): r is RegExp => r !== null);
    const files: string[] = [];
    let walkCapped = false;
    if (rootIsFile) {
      files.push(fp);
    } else {
      const collect = (dir: string): void => {
        let ents: string[];
        try { ents = readdirSync(dir); } catch { return; }
        for (const en of ents) {
          if (files.length >= 5000) { walkCapped = true; return; }
          const full = dir + sep + en;
          let cs;
          try { cs = lstatSync(full); } catch { continue; }
          if (cs.isSymbolicLink()) continue; // followLinks: false
          if (cs.isDirectory()) {
            if (LocalFileSearchTool.SKIPPED_DIRS.has(en)) continue;
            collect(full);
          } else if (cs.isFile()) {
            const segs = full.split(/[\\/]/);
            if (segs.some((s) => LocalFileSearchTool.SKIPPED_DIRS.has(s))) continue;
            if (patterns.length > 0 && !patterns.some((r) => r.test(en))) continue;
            files.push(full);
          }
        }
      };
      collect(fp);
    }
    const hits: string[] = [];
    for (const f of files) {
      if (hits.length >= maxMatches) break;
      this.scanFile(f, needle, ignoreCase, rawPath, rootIsFile, hits, maxMatches);
    }
    const walkNote = walkCapped ? "\n\u6CE8\u610F: \u6587\u4EF6\u6570\u5DF2\u8FBE 5000 \u4E0A\u9650\uFF0C\u672A\u7EE7\u7EED\u904D\u5386\uFF0C\u8BF7\u7528 glob \u6216\u66F4\u7A84\u7684 path \u7F29\u5C0F\u8303\u56F4" : "";
    if (hits.length === 0) {
      return ToolResult.success("\u672A\u547D\u4E2D\u3002\u641C\u7D22 \"" + query + "\uFF0C\u626B\u63CF " + files.length + " \u4E2A\u6587\u4EF6\uFF08" + rawPath + "\uFF09" + walkNote);
    }
    const more = hits.length >= maxMatches ? "\n...\u5DF2\u8FBE " + maxMatches + " \u6761\u4E0A\u9650\uFF0C\u7528 glob \u7F29\u5C0F\u8303\u56F4" : "";
    return ToolResult.success(hits.length + " \u5904\u547D\u4E2D\uFF08\u626B\u63CF " + files.length + " \u4E2A\u6587\u4EF6\uFF09\n" + hits.join("\n") + more + walkNote);
  }
  private scanFile(file: string, needle: string, ignoreCase: boolean, root: string, rootIsFile: boolean, hits: string[], maxMatches: number): void {
    try {
      const fstat = statSync(file);
      if (fstat.size > 2 * 1024 * 1024) return; // binary/oversize: skip, don't fail
      const text = readFileSync(file, "utf-8");
      const lines = text.split("\n");
      for (let i = 0; i < lines.length && hits.length < maxMatches; i++) {
        const line = lines[i];
        const hay = ignoreCase ? line.toLowerCase() : line;
        if (!hay.includes(needle)) continue;
        const shown = line.length > 200 ? line.slice(0, 200) + "\u2026" : line;
        const rel = rootIsFile ? file : relative(root, file);
        hits.push(rel + ":" + (i + 1) + ": " + shown);
      }
    } catch { /* no permission / non-utf8: skip this file */ }
  }
}

/** local_file_write - write/append a local file (Dart direct I/O, no shell escaping). */
export class LocalFileWriteTool extends AgentTool {
  readonly name = "local_file_write";
  readonly description: string = "\u5199\u5165\u6216\u8FFD\u52A0**\u672C\u673A**\u6587\u4EF6\uFF08Dart \u76F4\u63A5 I/O\uFF0C\u7ED5\u8FC7 shell \u8F6C\u4E49\uFF09\u3002\u8986\u76D6\u5DF2\u6709\u6587\u4EF6\u524D\u81EA\u52A8\u5907\u4EFD\u4E3A .bak.{\u65F6\u95F4\u623C}\uFF0C\u5199\u5931\u8D25\u81EA\u52A8\u56DE\u6EDA\u3002\u8981\u5199\u670D\u52A1\u5668\u4E0A\u7684\u6587\u4EF6\u8BF7\u7528 file_write\u3002";
  readonly paramSpec: string = "\u53C2\u6570\u5217\u8868\uFF08\u591A\u884C key:value \u683C\u5F0F\uFF09\uFF1A\n  path: \u672C\u673A\u6587\u4EF6\u7EDD\u5BF9\u8DEF\u5F84\uFF08\u5FC5\u586B\uFF09\n  content: \u6587\u672C\u5185\u5BB9\uFF0C\u6362\u884C\u7528 \n \u8868\u793A\uFF08\u4E0E content_b64 \u4E8C\u9009\u4E00\uFF09\n  content_b64: base64 \u5185\u5BB9\uFF0C\u4E8C\u8FDB\u5236\u6216\u9700\u9010\u5B57\u8282\u4FDD\u771F\u65F6\u7528\n  mode: write | append\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 write\uFF09\n  backup: \u8986\u76D6\u524D\u662F\u5426\u5907\u4EFD\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 true\uFF09\n\u6CE8\u610F\uFF1A\u5355\u5757 content \u539F\u6587\u4E0D\u8D85\u8FC7 8KB\uFF1B\u66F4\u5927\u7684\u6587\u4EF6\u5206\u591A\u6B21 mode=append\u3002";
  static readonly _maxChunkBytes = 8 * 1024;
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        path: {type: "string"},
        content: {type: "string"},
        content_b64: {type: "string"},
        mode: {type: "string", enum: ["write", "append"]},
        backup: {type: "boolean"},
      },
      required: ["path"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const rawPath = args.getString("path");
    if (rawPath === "") return ToolResult.failure("missing required param: path");
    const mode = args.getString("mode", "write");
    if (mode !== "write" && mode !== "append") {
      return ToolResult.failure("\u672A\u77E5 mode: " + mode + "\uFF08\u652F\u6301 write/append\uFF09");
    }
    const policy = defaultLocalFilePolicy();
    const resolved = resolveLocalPath(rawPath, policy);
    if (resolved instanceof ToolResult) return resolved;
    const fp = resolved.resolved;
    const content = decodeContent(decodeEscapedText(args.getString("content")), args.getString("content_b64"));
    if (content.error !== undefined) return ToolResult.failure(content.error);
    if (content.bytes.length === 0 && mode === "write" && !args.containsKey("content") && !args.containsKey("content_b64")) {
      return ToolResult.failure("\u53C2\u6570\u7F3A\u5931: content \u6216 content_b64 \u5FC5\u987B\u63D0\u4F9B\u4E00\u4E2A\u3002\u591A\u884C\u5185\u5BB9\u8BF7\u5199\u5728\u540C\u4E00\u884C\u5E76\u7528 \n \u8868\u793A\u6362\u884C\u3002");
    }
    if (content.bytes.length > LocalFileWriteTool._maxChunkBytes) {
      return ToolResult.failure("\u5355\u5757\u5185\u5BB9 " + content.bytes.length + " \u5B57\u8282\uFF0C\u8D85\u8FC7 " + LocalFileWriteTool._maxChunkBytes + "B \u4E0A\u9650\u3002\n\u8BF7\u5206\u5757\uFF1A\u7B2C\u4E00\u6B21 mode=write \u5199\u524D 8KB\uFF0C\u4E4B\u540E\u7528 mode=append \u7EED\u5199\u3002");
    }
    const outcome = writeLocalFile({path: fp, bytes: content.bytes, append: mode === "append", backup: args.getBool("backup", true)});
    if (!outcome.success) return ToolResult.failure(outcome.error ?? "\u5199\u5165\u5931\u8D25");
    const backupLine = outcome.backupPath !== undefined ? "\n\u539F\u6587\u4EF6\u5DF2\u5907\u4EFD: " + outcome.backupPath : "";
    return ToolResult.success("\u672C\u673A\u6587\u4EF6" + (mode === "append" ? "\u8FFD\u52A0" : "\u5199\u5165") + "\u6210\u529F: " + rawPath + "\uFF08" + outcome.bytesWritten + " \u5B57\u8282\uFF09" + backupLine, {
      restoreFrom: outcome.backupPath,
      restoreTo: outcome.backupPath !== undefined ? rawPath : undefined,
    });
  }
}

/** local_file_patch - unique string replacement in a local file. */
export class LocalFilePatchTool extends AgentTool {
  readonly name = "local_file_patch";
  readonly description: string = "\u6539**\u672C\u673A**\u6587\u4EF6\u7684\u5C11\u91CF\u5185\u5BB9\uFF1A\u53EA\u63D0\u4F9B old/new\uFF0C\u5DE5\u5177\u505A\u5B57\u7B26\u4E32\u66FF\u6362\u3002old \u5FC5\u987B\u5728\u6587\u4EF6\u4E2D\u552F\u4E00\u51FA\u73B0\uFF0C\u5426\u5219\u62A5\u9519\u8981\u4F60\u7ED9\u66F4\u957F\u4E0A\u4E0B\u6587\u3002\u5199\u524D\u4F1A\u6821\u9A8C\u6587\u4EF6\u672A\u88AB\u5916\u90E8\u6539\u52A8\u3002\u8981\u6539\u670D\u52A1\u5668\u4E0A\u7684\u6587\u4EF6\u8BF7\u7528 file_patch\u3002";
  readonly paramSpec: string = "\u53C2\u6570\u5217\u8868\uFF08\u591A\u884C key:value \u683C\u5F0F\uFF09\uFF1A\n  path: \u672C\u673A\u6587\u4EF6\u7EDD\u5BF9\u8DEF\u5F84\uFF08\u5FC5\u586B\uFF09\n  old: \u88AB\u66FF\u6362\u7684\u539F\u6587\uFF08\u4E0E old_b64 \u4E8C\u9009\u4E00\uFF09\n  new: \u66FF\u6362\u540E\u7684\u5185\u5BB9\uFF08\u4E0E new_b64 \u4E8C\u9009\u4E00\uFF1B\u5220\u9664\u5185\u5BB9\u65F6\u7559\u7A7A\uFF09\n  old_b64 / new_b64: \u591A\u884C\u6216\u542B\u7279\u6B8A\u5B57\u7B26\u65F6\u6539\u7528 base64\n  backup: \u662F\u5426\u5907\u4EFD\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 true\uFF09";
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        path: {type: "string"},
        old: {type: "string"},
        new: {type: "string"},
        old_b64: {type: "string"},
        new_b64: {type: "string"},
        backup: {type: "boolean"},
      },
      required: ["path"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const rawPath = args.getString("path");
    if (rawPath === "") return ToolResult.failure("missing required param: path");
    const policy = defaultLocalFilePolicy();
    const resolved = resolveLocalPath(rawPath, policy);
    if (resolved instanceof ToolResult) return resolved;
    const fp = resolved.resolved;
    const oldPlain = decodeEscapedText(args.getString("old"));
    const newPlain = decodeEscapedText(args.getString("new"));
    const oldB64 = args.getString("old_b64");
    const newB64 = args.getString("new_b64");
    const oldDecoded = decodeContent(oldPlain, oldB64);
    const newDecoded = decodeContent(newPlain, newB64);
    if (oldDecoded.error !== undefined) return ToolResult.failure(oldDecoded.error);
    if (newDecoded.error !== undefined) return ToolResult.failure(newDecoded.error);
    if (oldPlain === "" && oldB64 === "") {
      return ToolResult.failure("\u53C2\u6570\u7F3A\u5931: old \u6216 old_b64 \u5FC5\u987B\u63D0\u4F9B");
    }
    const outcome = patchLocalFile({
      path: fp,
      oldText: utf8decodeBytes(oldDecoded.bytes),
      newText: utf8decodeBytes(newDecoded.bytes),
      backup: args.getBool("backup", true),
    });
    if (!outcome.success) return ToolResult.failure(outcome.error ?? "\u66FF\u6362\u5931\u8D25");
    const diff = LineDiff.compute(outcome.oldText ?? "", outcome.newText ?? "");
    const diffText = diff === null ? "" : "\uFF08+" + diff.additions + " -" + diff.deletions + " \u884C\uFF09";
    const backupLine = outcome.backupPath !== undefined ? "\n\u539F\u6587\u4EF6\u5DF2\u5907\u4EFD: " + outcome.backupPath : "";
    return ToolResult.success("\u672C\u673A\u6587\u4EF6\u5DF2\u4FEE\u6539: " + rawPath + diffText + backupLine, {
      diffAdditions: diff === null ? undefined : diff.additions,
      diffDeletions: diff === null ? undefined : diff.deletions,
      restoreFrom: outcome.backupPath,
      restoreTo: outcome.backupPath !== undefined ? rawPath : undefined,
    });
  }
}

/** local_file_move - move/rename a local file or dir (cross-device fallback). */
export class LocalFileMoveTool extends AgentTool {
  readonly name = "local_file_move";
  readonly description: string = "\u79FB\u52A8\u6216\u91CD\u547D\u540D**\u672C\u673A**\u6587\u4EF6/\u76EE\u5F55\u3002\u6E90\u548C\u76EE\u6807\u90FD\u5FC5\u987B\u5728\u6388\u6743\u76EE\u5F55\u5185\u3002\u9ED8\u8BA4\u4E0D\u8986\u76D6\u5DF2\u5B58\u5728\u7684\u76EE\u6807\u3002";
  readonly paramSpec: string = "\u53C2\u6570\u5217\u8868\uFF08\u591A\u884C key:value \u683C\u5F0F\uFF09\uFF1A\n  path: \u6E90\u6587\u4EF6\u7EDD\u5BF9\u8DEF\u5F84\uFF08\u5FC5\u586B\uFF09\n  dst: \u76EE\u6807\u7EDD\u5BF9\u8DEF\u5F84\uFF08\u5FC5\u586B\uFF09\n  overwrite: \u76EE\u6807\u5DF2\u5B58\u5728\u65F6\u662F\u5426\u8986\u76D6\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 false\uFF09";
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        path: {type: "string"},
        dst: {type: "string"},
        overwrite: {type: "boolean"},
      },
      required: ["path", "dst"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const srcPath = args.getString("path");
    const dstPath = args.getString("dst");
    if (srcPath === "" || dstPath === "") return ToolResult.failure("missing required param: path/dst");
    const policy = defaultLocalFilePolicy();
    const srcRes = resolveLocalPath(srcPath, policy);
    if (srcRes instanceof ToolResult) return srcRes;
    const srcFp = srcRes.resolved;
    const dstRes = resolveLocalPath(dstPath, policy);
    if (dstRes instanceof ToolResult) return dstRes;
    const dstFp = dstRes.resolved;
    if (!existsSync(srcFp)) return ToolResult.failure("\u6E90\u4E0D\u5B58\u5728: " + srcPath);
    const isDir = statSync(srcFp).isDirectory();
    const dstExists = existsSync(dstFp);
    if (dstExists && !args.getBool("overwrite", false)) {
      return ToolResult.failure("\u76EE\u6807\u5DF2\u5B58\u5728: " + dstPath + "\n\u786E\u8BA4\u8981\u8986\u76D6\u8BF7\u4F20 overwrite: true\u3002");
    }
    if (dstExists) {
      try { rmSync(dstFp, {recursive: true, force: true}); }
      catch (e: unknown) {
        return ToolResult.failure("\u65E0\u6CD5\u6E05\u7406\u76EE\u6807: " + (e instanceof Error ? e.message : String(e)));
      }
    }
    const dstParent = dirname(dstFp);
    if (dstParent !== "" && dstParent !== ".") mkdirSync(dstParent, {recursive: true});
    try {
      renameSync(srcFp, dstFp);
      return ToolResult.success("\u672C\u673A\u79FB\u52A8\u6210\u529F: " + srcPath + " -> " + dstPath, {restoreFrom: dstPath, restoreTo: srcPath});
    } catch (e: unknown) {
      // rename across devices fails; fall back to copy + delete
      const m1 = e instanceof Error ? e.message : String(e);
      try {
        if (isDir) { cpSync(srcFp, dstFp, {recursive: true}); rmSync(srcFp, {recursive: true, force: true}); }
        else { copyFileSync(srcFp, dstFp); rmSync(srcFp, {force: true}); }
        return ToolResult.success("\u672C\u673A\u79FB\u52A8\u6210\u529F\uFF08\u8DE8\u76D8\uFF0C\u5DF2\u7528\u590D\u5236+\u5220\u9664\uFF09: " + srcPath + " -> " + dstPath, {restoreFrom: dstPath, restoreTo: srcPath});
      } catch (e2: unknown) {
        const m2 = e2 instanceof Error ? e2.message : String(e2);
        return ToolResult.failure("\u79FB\u52A8\u5931\u8D25: " + m1 + "\n\u9000\u5316\u590D\u5236\u4E5F\u5931\u8D25: " + m2);
      }
    }
  }
}

/** local_file_delete - delete a local file/dir (default: move to trash, not hard). */
export class LocalFileDeleteTool extends AgentTool {
  readonly name = "local_file_delete";
  readonly description: string = "\u5220\u9664**\u672C\u673A**\u6587\u4EF6/\u76EE\u5F55\u3002\u9ED8\u8BA4\u4E0D\u771F\u5220\uFF1A\u79FB\u5165\u6388\u6743\u76EE\u5F55\u4E0B\u7684 .ai_terminal_trash/ \u56DE\u6536\u533A\uFF0C\u53EF\u4ECE\u53F0\u8D26\u8FD8\u539F\u3002\u9700\u8981\u771F\u5220\u65F6\u7528\u6237\u4F1A\u663E\u5F0F\u4F20 hard: true\u3002";
  readonly paramSpec: string = "\u53C2\u6570\u5217\u8868\uFF08\u591A\u884C key:value \u683C\u5F0F\uFF09\uFF1A\n  path: \u8981\u5220\u9664\u7684\u672C\u673A\u8DEF\u5F84\uFF08\u5FC5\u586B\uFF09\n  recursive: \u76EE\u5F55\u662F\u5426\u9012\u5F52\u5220\u9664\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 false\uFF09\n  hard: true \u5219\u771F\u5220\u4E0D\u53EF\u6062\u590D\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 false \u2014\u2014 \u79FB\u5165\u56DE\u6536\u533A\uFF09";
  get kind(): ToolKind { return ToolKind.destructive; }
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        path: {type: "string"},
        recursive: {type: "boolean"},
        hard: {type: "boolean"},
      },
      required: ["path"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const rawPath = args.getString("path");
    if (rawPath === "") return ToolResult.failure("missing required param: path");
    const policy = defaultLocalFilePolicy();
    const resolved = resolveLocalPath(rawPath, policy);
    if (resolved instanceof ToolResult) return resolved;
    const fp = resolved.resolved;
    if (!existsSync(fp)) return ToolResult.failure("\u8DEF\u5F84\u4E0D\u5B58\u5728: " + rawPath);
    const isDir = statSync(fp).isDirectory();
    const recursive = args.getBool("recursive", false);
    if (isDir && !recursive) {
      return ToolResult.failure(rawPath + " \u662F\u76EE\u5F55\u3002\u786E\u8BA4\u8981\u8FDE\u5185\u5BB9\u4E00\u8D77\u5220\u9664\u8BF7\u4F20 recursive: true\u3002");
    }
    if (args.getBool("hard", false)) {
      try {
        rmSync(fp, {recursive: true, force: true});
        return ToolResult.success("\u5DF2\u6C38\u4E45\u5220\u9664: " + rawPath);
      } catch (e: unknown) {
        return ToolResult.failure("\u5220\u9664\u5931\u8D25: " + (e instanceof Error ? e.message : String(e)));
      }
    }
    // move into trash: keep relative structure so restore can put it back.
    const parent = dirname(fp);
    const base = basename(fp);
    const stamp = Date.now();
    const trashRoot = parent + sep + TRASH_DIR_NAME;
    const target = trashRoot + sep + stamp + sep + base;
    try {
      mkdirSync(trashRoot + sep + stamp, {recursive: true});
      renameSync(fp, target);
    } catch (e: unknown) {
      return ToolResult.failure("\u79FB\u5165\u56DE\u6536\u533A\u5931\u8D25: " + (e instanceof Error ? e.message : String(e)) + "\n\u786E\u8BA4\u8981\u8DF3\u8FC7\u56DE\u6536\u533A\u76F4\u63A5\u5220\u9664\u65F6\uFF0C\u8BF7\u8BA9\u7528\u6237\u540C\u610F\u540E\u7528 hard: true \u91CD\u8BD5\u3002");
    }
    return ToolResult.success("\u5DF2\u79FB\u5165\u56DE\u6536\u533A\uFF08\u672A\u771F\u5220\uFF0C\u53EF\u8FD8\u539F\uFF09: " + rawPath + "\n\u56DE\u6536\u4F4D\u7F6E: " + target, {restoreFrom: target, restoreTo: rawPath});
  }
}







