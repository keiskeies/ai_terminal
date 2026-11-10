// orchestrator.ts - Phase 2 (W5) multi-host orchestration tools.
//
// 1:1 port of the Dart MultiHostExecutor-driven tools in
// ai_terminal/lib/services/agent_tool.dart (ExecOnTool / ExecBatchTool /
// CheckConnectivityTool). In the Node port these tools execute against the
// Dart parent's SSH pool, so they are driven by an injected OrchestratorExecutor
// (the default ReverseRpcOrchestrator routes each command through
// ReverseRpcClient.invokeSsh back to Dart).
//
// AGENTS.md:
//   R8  - stdout/stderr are tail-truncated (2000 / 1000 / 200 chars) before the
//         text is folded back into conversation history.
//   R4  - batch results keep a per-host HostExecutionResult keyed by hostId.
//   R3  - hostId is passed explicitly to every executor call; activeHostId is
//         never substituted.
//   R9  - tool args are read ONLY through ToolArgs typed accessors.
//
// CJK literals are byte-faithful ports of the zh L10n templates
// (ai_terminal/lib/l10n/app_zh.arb).

import {AgentTool, AgentToolRegistry, ToolKind, ToolScope, ToolResult, ToolContext, HostExecutionResult} from "./builtin.js";
import type {ToolArgs} from "./tool_args.js";
import {ReverseRpcClient} from "../rpc/client.js";
import {checkSafety} from "../utils/safety_guard.js";

// failure kind (1:1 from pty_output_detector.dart CommandFailureKind)
export enum CommandFailureKind {
  none = "none",
  timeout = "timeout",
  syntaxError = "syntaxError",
  interactivePrompt = "interactivePrompt",
  disconnected = "disconnected",
  permissionDenied = "permissionDenied",
  cancelled = "cancelled",
  unknown = "unknown",
}

// result shapes (mirror Dart CommandResult / ConnectivityResult)
export interface OrchestratorResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  durationMs: number;
  timedOut?: boolean;
  failureKind?: CommandFailureKind | string;
  failureReason?: string;
  success: boolean;
}

export interface OrchestratorConnectivity {
  fromHostId: string;
  targetHost: string;
  port: number;
  reachable: boolean;
  detail?: string;
  elapsedMs: number;
  summary: string;
}

export interface ExecuteBatchOptions {
  timeoutMs?: number;
  stopOnFailure?: boolean;
  cancelled?: () => boolean;
  /**
   * Test seam for the second parallel gate: overrides the SafetyGuard classification
   * only, never the whitelist head check, so a test can prove the gate is live on
   * the batch path (a whitelist head plus a predicate that refuses it has to
   * serialise). Omitted in production, where checkSafety is used.
   */
  safetyCheckForTesting?: (command: string) => string;
}

export interface OrchestratorExecutor {
  executeOn(hostId: string, command: string, timeoutMs?: number, cancelled?: () => boolean): Promise<OrchestratorResult | null>;
  executeBatch(hostIds: string[], command: string, opts: ExecuteBatchOptions): Promise<Map<string, OrchestratorResult>>;
  checkConnectivity(o: {fromHostId: string; targetHost: string; port: number; timeoutMs?: number}): Promise<OrchestratorConnectivity>;
}

// reverse-RPC adapter (the production OrchestratorExecutor)
export class ReverseRpcOrchestrator implements OrchestratorExecutor {
  constructor(private readonly reverse: ReverseRpcClient) {}

  async executeOn(hostId: string, command: string, timeoutMs?: number, cancelled?: () => boolean): Promise<OrchestratorResult | null> {
    if (cancelled?.()) {
      return {stdout:"", stderr:"cancelled", exitCode:-1, durationMs:0, timedOut:false, failureKind:CommandFailureKind.cancelled, success:false};
    }
    try {
      const r = await this.reverse.invokeSsh({hostId, command, timeoutMs});
      const failureKind = (r.failureKind as CommandFailureKind | undefined) ?? CommandFailureKind.none;
      const timedOut = r.failureKind === "timeout" || failureKind === CommandFailureKind.timeout;
      return {
        stdout: r.output ?? "",
        stderr: r.error ?? "",
        exitCode: r.exitCode ?? -1,
        durationMs: r.durationMs ?? 0,
        timedOut,
        failureKind,
        success: r.exitCode === 0 && !timedOut,
      };
    } catch {
      // Host unconnected / RPC refused -> treat as "not connected" (null).
      return null;
    }
  }

  async executeBatch(hostIds: string[], command: string, opts: ExecuteBatchOptions): Promise<Map<string, OrchestratorResult>> {
    const results = new Map<string, OrchestratorResult>();
    const cancelled = opts.cancelled;
    if (cancelled?.()) {
      for (const h of hostIds) results.set(h, skippedResult());
      return results;
    }
    if (isParallelSafeCommand(command, opts.safetyCheckForTesting)) {
      // parallel: one host's failure does not affect the others
      await Promise.all(hostIds.map(async (h) => {
        results.set(h, await this.executeOn(h, command, opts.timeoutMs, cancelled) ?? skippedResult());
      }));
      return results;
    }
    // serial: stopOnFailure stops the remaining hosts
    for (let i = 0; i < hostIds.length; i++) {
      const h = hostIds[i];
      const r = await this.executeOn(h, command, opts.timeoutMs, cancelled);
      results.set(h, r ?? notConnectedResult(h));
      const stopNow = opts.stopOnFailure === true && !results.get(h)!.success;
      if (cancelled?.() || stopNow) {
        for (let j = i + 1; j < hostIds.length; j++) results.set(hostIds[j], skippedResult());
        break;
      }
    }
    return results;
  }

  async checkConnectivity(o: {fromHostId: string; targetHost: string; port: number; timeoutMs?: number}): Promise<OrchestratorConnectivity> {
    const t0 = Date.now();
    if (!isValidHost(o.targetHost)) {
      const detail = "targetHost 格式非法（仅允许 IP 或域名字符）";
      const elapsedMs = Date.now() - t0;
      return {fromHostId:o.fromHostId, targetHost:o.targetHost, port:o.port, reachable:false, detail, elapsedMs, summary:connectivitySummary(o.fromHostId,o.targetHost,o.port,false,elapsedMs,detail)};
    }
    // R6: /dev/tcp is a bash builtin -> most portable probe (no nc required).
    const probeCmd = "timeout 3 bash -c 'cat < /dev/tcp/"+o.targetHost+"/"+o.port+"' && echo 'CONNECT_OK' || echo 'CONNECT_FAIL'";
    const r = await this.executeOn(o.fromHostId, probeCmd, o.timeoutMs ?? 5000);
    const elapsedMs = Date.now() - t0;
    if (r === null) {
      const detail = "源主机 "+o.fromHostId+" 未连接";
      return {fromHostId:o.fromHostId, targetHost:o.targetHost, port:o.port, reachable:false, detail, elapsedMs, summary:connectivitySummary(o.fromHostId,o.targetHost,o.port,false,elapsedMs,detail)};
    }
    const reachable = r.stdout.includes("CONNECT_OK");
    const detail = reachable ? undefined : (r.stderr || "连接超时或被拒绝");
    return {fromHostId:o.fromHostId, targetHost:o.targetHost, port:o.port, reachable, detail, elapsedMs, summary:connectivitySummary(o.fromHostId,o.targetHost,o.port,reachable,elapsedMs,detail)};
  }
}

// small L10n / formatting helpers (zh, byte-faithful)
function notConnectedResult(hostId: string): OrchestratorResult {
  return {stdout:"", stderr:"主机 "+hostId+" 未连接或不存在", exitCode:-1, durationMs:0, success:false};
}
function skippedResult(): OrchestratorResult {
  return {stdout:"", stderr:"已跳过（前序主机失败）", exitCode:-1, durationMs:0, success:false};
}
function connectivitySummary(from:string,target:string,port:number,reachable:boolean,elapsedMs:number,detail?:string): string {
  const mark = reachable ? "✓" : "✗";
  return reachable
    ? from+" → "+target+":"+port+" "+mark+" ("+elapsedMs+"ms)"
    : from+" → "+target+":"+port+" "+mark+" ("+(detail ?? "不可达")+" ("+elapsedMs+"ms))";
}
function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return s.slice(0, max)+"...("+s.length+" chars)";
}
function formatBatchResult(command: string, results: Map<string, OrchestratorResult>): string {
  const total = results.size;
  const success = [...results.values()].filter((r) => r.success).length;
  const lines: string[] = ["结果: "+success+"/"+total+" 成功"];
  for (const [hostId, r] of results) {
    const mark = r.success ? "✓" : "✗";
    const detail = r.success
      ? (r.stdout.trim() !== "" ? truncate(r.stdout, 200) : "(无输出)")
      : "错误: "+truncate((r.stderr.trim() !== "" ? r.stderr : "未知"), 200);
    lines.push("["+hostId+"] "+mark+" "+detail);
  }
  return lines.join("\n");
}

// Conservative read-only classifier mirroring SafetyGuard.check -> safe.
// Used only to pick the parallel vs serial batch path. Conservative rule:
// a command is read-only (parallel-safe) ONLY when its head matches a known
// read-only phrase AND no mutating subcommand/flag is present. A false-negative
// just means we run serially, which is always correct (never a correctness issue).
//
// READ_ONLY_HEADS: command heads (1- or 2-word phrases) that are safe to run in
// parallel. Matching is done on the first 1-2 tokens of the command. Multi-word
// heads like "docker ps" / "systemctl status" / "kubectl get" are recognized as
// read-only, while their mutating siblings ("docker rm", "systemctl stop") are
// rejected because their head-phrase is not in this set AND their subcommand is
// in MUTATING_SUBCOMMANDS.
const READ_ONLY_HEADS = new Set([
  // single-word heads
  "ls","cat","df","du","ps","top","tail","head","grep","find","stat","free",
  "uptime","which","whereis","date","whoami","hostname","echo","pwd","env","type",
  "journalctl","netstat","ifconfig","mount","uname","ip","ss","docker","kubectl","git","systemctl",
  // two-word read-only subcommand phrases
  "systemctl status","systemctl show","systemctl is-active","systemctl is-enabled",
  "docker ps","docker images","docker logs","docker inspect","docker port","docker top","docker history",
  "kubectl get","kubectl describe","kubectl logs","kubectl top",
  "git log","git status","git diff","git show","git branch","git tag",
  "ip addr","ip route","ip link","ip a",
]);

// Per-head mutating subcommands / flags. Keyed by the first token (lowercase).
// If any token in the command (after the head) matches this denylist, the
// command is treated as mutating and runs serially. This is the R7 security
// fix: find -delete, mount -o remount, docker rm, kubectl delete, git push,
// systemctl stop, etc. must NOT be run in parallel across hosts.
const MUTATING_SUBCOMMANDS: Record<string, readonly string[]> = {
  find:     ["-delete","-ok","-exec","-execdir","-fls","-fprint","-fprintf"],
  mount:    ["-o","--options","-t","--type","-u","--update","--bind","--remount","-a","--all","-r","--read-only","-L","-l","--noauto"],
  docker:   ["rm","rmi","run","create","start","stop","restart","kill","pause","unpause","prune","build","push","pull","load","save","commit","cp","exec","attach","update"],
  kubectl:  ["apply","delete","create","patch","replace","scale","rollout","cordon","drain","uncordon","expose","label","annotate","taint","set","edit","cp","autoscale","wait","promote"],
  systemctl:["enable","disable","start","stop","restart","reload","reload-or-restart","mask","unmask","daemon-reload","daemon-reexec","isolate","preset","set-property","kill","reset-failed"],
  git:      ["add","commit","push","pull","fetch","merge","rebase","checkout","switch","reset","revert","stash","clean","am","cherry-pick","init","clone","remote","submodule","gc","repack","filter-branch","bisect","worktree"],
};

export function isReadOnlyCommand(command: string): boolean {
  const c = command.trim();
  if (c === "") return false;
  // Compound / redirect / backtick / subshell -> never read-only.
  if (/[;|&>$(`]/.test(c)) return false;
  const tokens = c.split(/\s+/);
  const head1 = tokens[0].toLowerCase();
  const head2 = tokens.length >= 2 ? head1 + " " + tokens[1].toLowerCase() : head1;
  // Head must be a known read-only phrase (1 or 2 tokens).
  if (!READ_ONLY_HEADS.has(head1) && !READ_ONLY_HEADS.has(head2)) return false;
  // R7: reject if any subsequent token is a mutating subcommand/flag for this head.
  const deny = MUTATING_SUBCOMMANDS[head1];
  if (deny) {
    for (let i = 1; i < tokens.length; i++) {
      if (deny.includes(tokens[i].toLowerCase())) return false;
    }
  }
  return true;
}

/**
 * The batch parallel/serial gate: a command may run in parallel across hosts only
 * when BOTH dimensions agree that it cannot write anywhere - the conservative
 * whitelist head check AND the Dart SafetyGuard classification. Dart asks the same
 * question at multi_host_executor.dart:121, comparing SafetyGuard.check(command)
 * against SafetyLevel.safe, and that comparison is what this function wires up.
 * Until it existed the Node batch path consulted only its own whitelist and never
 * went through src/utils/safety_guard.ts at all, so the two classifiers could drift
 * apart in silence - the same failure mode as the permission-mode values in 6.3.7.
 *
 * Why both and not just the Dart one: the Dart gate alone is weaker here, and that
 * is a measured number rather than rhetoric. Of the 87 commands asserted in
 * test/orchestrator.test.ts, 34 classify as safe under SafetyGuard while the
 * whitelist refuses them: docker rm/stop/kill/exec/build/push, kubectl
 * delete/apply/create/scale, systemctl enable/stop, git
 * push/commit/checkout/reset/clean/rebase/merge/stash, find -exec and -ok, mount
 * -o remount and --bind, plus every command chained with semicolon, pipe,
 * ampersand, redirect, dollar-paren or backtick, and the empty command. The Dart
 * rule tables name destructive shapes (rm -rf against the root, mkfs, fork bombs)
 * and simply have no opinion about a git push, so swapping the whitelist out for
 * the Dart check would run all of those in parallel across hosts. The whitelist
 * stays the primary gate; SafetyGuard is added as a second gate, so that anything
 * the Dart tables learn to flag also stops the parallel path here.
 *
 * On today rule tables the second gate happens to be implied by the first: no
 * command the whitelist admits classifies as anything but safe. That is a property
 * of the current tables, not an invariant, which is precisely why the conjunction
 * lives in code rather than in a comment.
 *
 * test/orchestrator_safety_gate.test.ts pins both halves: the implication over the
 * whole whitelist vocabulary plus the Dart batch gate parsed out of the Dart source,
 * and a fake predicate that refuses a whitelist head so that the batch path has to
 * serialise - which is the only way to show the second gate is live on the path.
 * [safetyCheck] is injectable for exactly that; production callers pass nothing and
 * get checkSafety.
 */
export function isParallelSafeCommand(
  command: string,
  safetyCheck: (command: string) => string = checkSafety,
): boolean {
  if (!isReadOnlyCommand(command)) return false;
  // Dart compares against SafetyLevel.safe only. info is a highlight rather than a
  // gate elsewhere (PathSafetyResult.isAllowed lets it through), but the batch path
  // mirrors Dart and asks for the single level Dart asks for.
  return safetyCheck(command) === "safe";
}

// Validate target host (IP/domain, no shell metachars) - R7.
export function isValidHost(host: string): boolean {
  if (host.length === 0 || host.length > 255) return false;
  return /^[a-zA-Z0-9.\-]+$/.test(host);
}

// ExecOnTool (exec_on)
export class ExecOnTool extends AgentTool {
  readonly name = "exec_on";
  readonly description = "【多机编排】在指定主机上执行命令。用于跨主机调度操作。仅在编排模式下可用；非编排模式请用普通 execute。";
  readonly paramSpec: string = "参数列表（多行 key:value 格式）：\n  hostId: 目标主机 ID（必填）\n  command: 要执行的命令（必填）\n  timeout: 超时秒数（可选，默认 60）";
  get kind(): ToolKind { return ToolKind.orchestration; }
  get scope(): ToolScope { return ToolScope.orchestrator; }
  constructor(private readonly executor: OrchestratorExecutor) { super(); }
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        hostId: {type: "string", description: "target host id"},
        command: {type: "string", description: "command to run on that host"},
        timeout: {type: "integer", description: "timeout seconds (default 60)"},
      },
      required: ["hostId", "command"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const hostId = args.getString("hostId");
    const command = args.getString("command");
    const timeoutSec = args.getInt("timeout", 60);
    if (hostId === "" || command === "") {
      return ToolResult.failure("参数缺失: hostId 和 command 为必填项");
    }
    const result = await this.executor.executeOn(hostId, command, timeoutSec * 1000, ctx.cancelled);
    if (result === null) {
      return ToolResult.failure("主机 "+hostId+" 未连接或不存在");
    }
    const mark = result.success ? "✓" : "✗";
    const output = truncate(result.stdout, 2000);
    const err = truncate(result.stderr, 1000);
    const kindLabel = result.failureKind && result.failureKind !== CommandFailureKind.none
      ? " ["+String(result.failureKind).toUpperCase()+"]"
      : (result.timedOut ? " [TIMEOUT]" : "");
    const summary = "["+hostId+"] "+mark+" (exit="+result.exitCode+")"+kindLabel;
    const detail = result.success
      ? (output.trim() !== "" ? output : "(无输出)")
      : (output.trim() !== ""
          ? (err.trim() !== "" ? "stdout: "+output+"\nstderr: "+err : "output: "+output)
          : (err.trim() !== "" ? "stderr: "+err : "(无输出)"));
    const reasonLine = result.failureReason ? "\nreason: "+result.failureReason : "";
    if (result.success) {
      return ToolResult.success(summary+"\n"+detail);
    }
    const fail = "主机 "+hostId+" 命令失败 (exit="+result.exitCode+")"+(result.failureKind && result.failureKind !== CommandFailureKind.none ? " kind="+result.failureKind : "");
    return ToolResult.failure(fail, {output: summary+"\n"+detail+reasonLine});
  }
}

// ExecBatchTool (exec_batch)
export class ExecBatchTool extends AgentTool {
  readonly name = "exec_batch";
  readonly description = "【多机编排】批量执行同一命令到多台主机（只读命令并行执行，修改性命令串行执行）。适用于时间同步、日志清理、配置检查等批量运维场景。一台失败不影响其他主机（除非 stopOnFailure=true）。";
  readonly paramSpec: string = "参数列表（多行 key:value 格式）：\n  hostIds: 主机 ID 列表（必填，逗号分隔，如 web1,web2,db1）\n  command: 要执行的命令（必填）\n  timeout: 超时秒数（可选，默认 60）\n  stopOnFailure: 某台失败是否停止后续（true/false，默认 false）";
  get kind(): ToolKind { return ToolKind.orchestration; }
  get scope(): ToolScope { return ToolScope.orchestrator; }
  constructor(private readonly executor: OrchestratorExecutor) { super(); }
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        hostIds: {type: "string", description: "comma-separated host ids"},
        command: {type: "string", description: "command to run on each host"},
        timeout: {type: "integer", description: "timeout seconds (default 60)"},
        stopOnFailure: {type: "boolean", description: "stop subsequent hosts on first failure (default false)"},
      },
      required: ["hostIds", "command"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const command = args.getString("command");
    const timeoutSec = args.getInt("timeout", 60);
    const stopOnFailure = args.getBool("stopOnFailure");
    const hostIds = args.getStringList("hostIds");
    if (hostIds.length === 0 || command === "") {
      return ToolResult.failure("参数缺失: hostIds 和 command 为必填项");
    }
    const results = await this.executor.executeBatch(hostIds, command, {
      timeoutMs: timeoutSec * 1000,
      stopOnFailure,
      cancelled: ctx.cancelled,
    });
    const summary = formatBatchResult(command, results);
    const allSuccess = [...results.values()].every((r) => r.success);
    const hostResults: Record<string, HostExecutionResult> = {};
    for (const [hostId, r] of results) {
      const out = r.stdout.length > 2000 ? r.stdout.slice(0, 2000)+"…" : r.stdout;
      const err = r.stderr.length > 1000 ? r.stderr.slice(0, 1000)+"…" : r.stderr;
      hostResults[hostId] = {
        hostId,
        success: r.success,
        output: out.trim() === "" ? undefined : out,
        error: err.trim() === "" ? undefined : err,
        exitCode: r.exitCode,
        durationMs: r.durationMs,
        failureKind: r.failureKind && r.failureKind !== CommandFailureKind.none ? String(r.failureKind) : undefined,
      };
    }
    if (allSuccess) return ToolResult.success(summary, {hostResults});
    const failedCount = [...results.values()].filter((r) => !r.success).length;
    return ToolResult.failure(failedCount+"/"+hostIds.length+" 台主机执行失败", {output: summary, hostResults});
  }
}

// CheckConnectivityTool (check_connectivity)
export class CheckConnectivityTool extends AgentTool {
  readonly name = "check_connectivity";
  readonly description = "【多机编排】从一台主机测试到目标主机的端口连通性。用于部署前验证网络依赖（如 web→db:3306、web→redis:6379）。源主机必须是已连接的编排参与者。";
  readonly paramSpec: string = "参数列表（多行 key:value 格式）：\n  fromHostId: 源主机 ID（必填，命令从这台机执行）\n  targetHost: 目标主机 IP 或域名（必填）\n  port: 目标端口（必填）\n  timeout: 超时秒数（可选，默认 5）";
  get kind(): ToolKind { return ToolKind.read; }
  get scope(): ToolScope { return ToolScope.orchestrator; }
  constructor(private readonly executor: OrchestratorExecutor) { super(); }
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        fromHostId: {type: "string", description: "source host id (probe runs here)"},
        targetHost: {type: "string", description: "target IP or hostname"},
        port: {type: "integer", description: "target port"},
        timeout: {type: "integer", description: "timeout seconds (default 5)"},
      },
      required: ["fromHostId", "targetHost", "port"],
    };
  }
  async execute(args: ToolArgs, _ctx: ToolContext): Promise<ToolResult> {
    const fromHostId = args.getString("fromHostId");
    const targetHost = args.getString("targetHost");
    const port = args.getInt("port");
    const timeoutSec = args.getInt("timeout", 5);
    if (fromHostId === "" || targetHost === "" || port <= 0) {
      return ToolResult.failure("参数缺失或无效: fromHostId、targetHost、port(正整数) 为必填项");
    }
    const result = await this.executor.checkConnectivity({fromHostId, targetHost, port, timeoutMs: timeoutSec * 1000});
    if (result.reachable) {
      return ToolResult.success(result.summary);
    }
    return ToolResult.failure(result.detail ?? "不可达", {output: result.summary});
  }
}

// factory: register the orchestration trio under ToolScope.orchestrator
export function buildOrchestratorTools(executor: OrchestratorExecutor): AgentTool[] {
  return [new ExecOnTool(executor), new ExecBatchTool(executor), new CheckConnectivityTool(executor)];
}
export function registerOrchestratorTools(registry: AgentToolRegistry, executor: OrchestratorExecutor): void {
  for (const t of buildOrchestratorTools(executor)) registry.register(t, ToolScope.orchestrator);
}
