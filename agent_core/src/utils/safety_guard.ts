/**
 * Command and path safety classification for AI-generated shell commands.
 *
 * Port of lib/core/safety_guard.dart (512 lines). Rule order, per-rule polarity, the
 * case-insensitive flag on the fork-bomb rule, the Chinese reason strings and the
 * 500-entry cache eviction all mirror the Dart source on purpose: Dart is the side
 * that ships, so a Node rule that drifts silently changes which commands a user is
 * asked to confirm, and the two runtimes end up disagreeing about the very string
 * that is sitting on the screen. test/safety_guard.test.ts re-parses that Dart file
 * and compares the two rule tables entry by entry, in order.
 *
 * Two regex differences between the runtimes are handled explicitly.
 *
 * 1. Dart RegExp is RE2, where the whitespace shorthand matches ASCII whitespace
 *    only. In JavaScript the same shorthand is Unicode-aware. Every whitespace class
 *    below is therefore spelled out as the explicit ASCII set, so an input padded
 *    with a non-breaking space classifies identically on both sides. Written as the
 *    shorthand, "rm" + U+00A0 + "-rf /" would be blocked by Dart and waved through
 *    here. Do not replace these classes with the shorthand.
 *
 * 2. The command-name unquoting pattern has no matching backreference in Dart, so a
 *    mismatched quote pair also strips there. Kept as-is: this is a bug-for-bug copy
 *    of a security heuristic, and two runtimes disagreeing about it is worse than
 *    the flaw itself. See normalizeCommand.
 *
 * These rules are a denylist wrapped around an allow-by-default shell: a result of
 * "safe" means "no rule matched", never "proved harmless". Dart callers read it that
 * way today (services/agent_engine.dart:2523 and :2978,
 * services/local_exec_tool.dart:183, services/multi_host_executor.dart:121,
 * services/change_window_service.dart:139, services/change_record_service.dart:236,
 * widgets/agent_command_block.dart:95).
 *
 * STILL NOT WIRED: nothing in src/ calls this module yet, which is also a real gap -
 * utils/local_file_ops.ts reads files with no path gate at all, while
 * services/local_file_policy.dart:147 gates every lexical path through checkPath().
 * Wiring it up changes what the Node tools refuse to open, so it needs its own
 * increment rather than a silent switch.
 */

/**
 * The four safety levels in Dart declaration order.
 *
 * Declared here because the Dart side declares the enum in safety_guard.dart, and
 * that order plus these names are the protocol: the values are persisted into
 * AgentEvent.riskLevel and the UI compares the stored string. permission_policy.ts
 * re-exports them so the gate matrix stays readable as the standalone module it is.
 */
export const SAFETY_LEVELS = ["safe", "info", "warn", "blocked"] as const;

export type SafetyLevel = (typeof SAFETY_LEVELS)[number];

const SAFE: SafetyLevel = "safe";
const INFO: SafetyLevel = "info";
const WARN: SafetyLevel = "warn";
const BLOCKED: SafetyLevel = "blocked";

/**
 * Rank of a level; the highest rank wins when a chained command mixes levels.
 *
 * Dart computes the ranking from a literal array inside _compareLevel rather than
 * from the enum index, so ranking and declaration order are two separate facts over
 * there. They agree today; here SAFETY_LEVELS is the single source of both and the
 * test pins the tuple against the Dart enum plus the ranking it implies.
 */
function levelRank(level: SafetyLevel): number {
  return SAFETY_LEVELS.indexOf(level);
}

/** Port of _compareLevel: positive when a is more dangerous than b. */
function compareLevel(a: SafetyLevel, b: SafetyLevel): number {
  return levelRank(a) - levelRank(b);
}

function re(src: string, caseInsensitive = false): RegExp {
  return new RegExp(src, caseInsensitive ? "i" : "");
}

/**
 * A Dart RegExp used with replaceAll carries no flag - Dart has no global flag and
 * replaceAll is already all-here. JS replaceAll refuses a non-global pattern, so the
 * same pattern needs one. Deliberately not folded into re(): the rule patterns from re()
 * are matched with .test(), and a g-flagged RegExp is stateful through lastIndex, which
 * would make a shared rule pattern match intermittently.
 */
function reAll(src: string): RegExp {
  return new RegExp(src, "g");
}

/** A rule is a pattern plus the risk text shown to the human when it matches. */
export type SafetyRule = {
  readonly pattern: RegExp;
  readonly reason: string;
};

function rule(pattern: RegExp, reason: string): SafetyRule {
  return {pattern, reason};
}

/**
 * 直接拦截的命令模式（不可逆操作）
 *
 * Private underscore-prefixed tables in Dart. Exported here so the drift test can
 * compare the RegExp objects that actually run instead of re-reading this file as
 * text: a guard over source text still passes if a table were declared and then
 * never consulted. Treat them as read-only.
 */
export const BLOCK_RULES: readonly SafetyRule[] = [
  rule(re("^rm[\\t\\n\\f\\r ]+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)[\\t\\n\\f\\r ]+/[\\t\\n\\f\\r ]*$"), "递归删除根目录，将清空整个文件系统，完全不可恢复"),
  rule(re("^rm[\\t\\n\\f\\r ]+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)[\\t\\n\\f\\r ]+\\/\\*?[\\t\\n\\f\\r ]*$"), "递归删除根目录下所有内容，将清空整个文件系统，完全不可恢复"),
  rule(re("^dd[\\t\\n\\f\\r ]+if=.*of=/dev/"), "直接写入块设备，将覆盖目标磁盘所有数据，不可恢复"),
  rule(re("^:\\(\\)\\{[\\t\\n\\f\\r ]*:\\|\\:&[\\t\\n\\f\\r ]*\\};:", true), "Fork 炸弹，将瞬间耗尽系统进程资源导致系统崩溃"),
  rule(re("chmod[\\t\\n\\f\\r ]+-R[\\t\\n\\f\\r ]+777[\\t\\n\\f\\r ]+/"), "递归修改根目录权限为 777，将破坏所有文件权限，系统将无法正常运行"),
  rule(re("^init[\\t\\n\\f\\r ]+0[\\t\\n\\f\\r ]*$"), "立即关机，所有未保存数据将丢失"),
  rule(re("^shutdown[\\t\\n\\f\\r ]+-h[\\t\\n\\f\\r ]+now"), "立即关机，所有未保存数据将丢失"),
  rule(re("^rm[\\t\\n\\f\\r ]+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)[\\t\\n\\f\\r ]+/etc/"), "删除 /etc 下的系统配置文件，相关服务可能无法运行，且不可恢复"),
  rule(re("^rm[\\t\\n\\f\\r ]+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)[\\t\\n\\f\\r ]+/boot/"), "删除 /boot 启动目录，系统将无法启动"),
  rule(re("^rm[\\t\\n\\f\\r ]+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)[\\t\\n\\f\\r ]+~"), "递归删除用户主目录，所有用户数据将丢失"),
  rule(re("^mkfs\\."), "格式化磁盘，目标分区所有数据将被擦除，不可恢复"),
  rule(re("^>[\\t\\n\\f\\r ]*/etc/"), "清空系统配置文件，相关服务将无法运行"),
  rule(re("^crontab[\\t\\n\\f\\r ]+-r\\b"), "清空当前用户的所有定时任务，所有 cron 作业将丢失且不可恢复"),
  rule(re("^systemctl[\\t\\n\\f\\r ]+mask[\\t\\n\\f\\r ]+"), "屏蔽系统服务，被 mask 的服务将无法启动，需手动 unmask 恢复"),
  rule(re("iptables[\\t\\n\\f\\r ]+.*-P[\\t\\n\\f\\r ]+(INPUT|OUTPUT|FORWARD)[\\t\\n\\f\\r ]+DROP"), "设置防火墙默认策略为 DROP，将立即断开所有网络连接，可能导致远程无法访问"),
  rule(re("echo[\\t\\n\\f\\r ]+c[\\t\\n\\f\\r ]*>[\\t\\n\\f\\r ]*/proc/sysrq-trigger"), "触发 SysRq 崩溃，将导致系统立即崩溃重启"),
  rule(re("^pkill[\\t\\n\\f\\r ]+-9\\b"), "强制杀死所有匹配进程，可能导致数据损坏或服务异常"),
  rule(re("^killall[\\t\\n\\f\\r ]+-9\\b"), "强制杀死所有同名进程，可能导致数据损坏或服务异常"),
  rule(re("^kill[\\t\\n\\f\\r ]+-9[\\t\\n\\f\\r ]+-1\\b"), "杀死所有用户进程（kill -9 -1），将终止除 init 外的所有进程"),
  rule(re("^>[\\t\\n\\f\\r ]*/dev/sda"), "清空磁盘设备数据，将破坏磁盘分区表和所有数据"),
  rule(re("^swapoff[\\t\\n\\f\\r ]+-a\\b"), "关闭所有交换分区，内存不足时系统将直接 OOM 杀进程"),
];

/** 需二次确认的命令模式（高风险修改操作） */
export const WARN_RULES: readonly SafetyRule[] = [
  rule(re("^(sudo[\\t\\n\\f\\r ]+)?rm[\\t\\n\\f\\r ]+"), "删除文件或目录，操作不可恢复，请确认目标路径"),
  rule(re("^(sudo[\\t\\n\\f\\r ]+)?(unlink|shred)[\\t\\n\\f\\r ]+"), "删除/粉碎文件，操作不可恢复，请确认目标路径"),
  rule(re("\\bfind\\b.*[\\t\\n\\f\\r ]-delete\\b"), "批量删除匹配的文件，操作不可恢复，请确认匹配范围"),
  rule(re("^(sudo[\\t\\n\\f\\r ]+)?truncate[\\t\\n\\f\\r ]+.*-s[\\t\\n\\f\\r ]*0\\b"), "清空文件内容，原数据不可恢复，请确认目标文件"),
  rule(re("^sudo[\\t\\n\\f\\r ]+(reboot|shutdown|halt|poweroff|init[\\t\\n\\f\\r ]+)"), "关机/重启服务器，所有运行中的进程将终止，未保存数据丢失"),
  rule(re("^systemctl[\\t\\n\\f\\r ]+(stop|disable)[\\t\\n\\f\\r ]+ssh"), "停止/禁用 SSH 服务，将断开所有远程连接，可能导致无法再次远程登录"),
  rule(re("^(iptables|firewall-cmd|ufw).*(-F|--flush|--delete-chain)"), "清空防火墙规则，将影响网络安全策略"),
  rule(re("^fdisk[\\t\\n\\f\\r ]+/"), "分区操作，错误的分区表修改可能导致磁盘数据丢失"),
  rule(re("^mkfs\\.(ext4|xfs|btrfs)[\\t\\n\\f\\r ]+/dev/"), "格式化分区为文件系统，目标分区所有数据将被擦除"),
  rule(re("^dd[\\t\\n\\f\\r ]+if=.*of=/dev/"), "直接写入块设备，将覆盖目标磁盘数据"),
  rule(re("^rm[\\t\\n\\f\\r ]+-rf[\\t\\n\\f\\r ]+/"), "递归删除系统目录，可能影响系统运行，不可恢复"),
  rule(re("^sudo[\\t\\n\\f\\r ]+(apt|apt-get)[\\t\\n\\f\\r ]+(install|upgrade|dist-upgrade|remove|purge)[\\t\\n\\f\\r ]+"), "安装/升级/卸载软件包，可能改变系统依赖关系，影响其他服务"),
  rule(re("^sudo[\\t\\n\\f\\r ]+yum[\\t\\n\\f\\r ]+(install|update|remove|erase)[\\t\\n\\f\\r ]+"), "安装/更新/卸载软件包，可能改变系统依赖关系"),
  rule(re("^sudo[\\t\\n\\f\\r ]+dnf[\\t\\n\\f\\r ]+(install|upgrade|remove)[\\t\\n\\f\\r ]+"), "安装/升级/卸载软件包，可能改变系统依赖关系"),
  rule(re("^sudo[\\t\\n\\f\\r ]+apk[\\t\\n\\f\\r ]+add[\\t\\n\\f\\r ]+"), "安装软件包，可能改变系统配置"),
  rule(re("^sudo[\\t\\n\\f\\r ]+pacman[\\t\\n\\f\\r ]+-S[\\t\\n\\f\\r ]+"), "安装软件包，可能改变系统依赖关系"),
  rule(re("^sudo[\\t\\n\\f\\r ]+snap[\\t\\n\\f\\r ]+install[\\t\\n\\f\\r ]+"), "安装 Snap 软件包"),
  rule(re("(>>|>)[\\t\\n\\f\\r ]*(/etc/profile|/etc/environment|/etc/bashrc|~/\\.bashrc|~/\\.zshrc|~/\\.bash_profile|~/\\.profile)[\\t\\n\\f\\r ]*$"), "修改 Shell 环境配置文件，可能影响所有用户的登录环境"),
  rule(re("^sudo[\\t\\n\\f\\r ]+(tee|sed|echo.*>)[\\t\\n\\f\\r ]+.*(/etc/profile|/etc/environment|/etc/bashrc)[\\t\\n\\f\\r ]*$"), "修改系统级环境配置文件，可能影响所有用户"),
  rule(re("^sudo[\\t\\n\\f\\r ]+update-alternatives[\\t\\n\\f\\r ]+--set[\\t\\n\\f\\r ]+"), "修改系统默认程序指向，影响相关命令的默认版本"),
  rule(re("^sudo[\\t\\n\\f\\r ]+alternatives[\\t\\n\\f\\r ]+--set[\\t\\n\\f\\r ]+"), "修改系统默认程序指向"),
  rule(re("^sudo[\\t\\n\\f\\r ]+(apt|apt-get)[\\t\\n\\f\\r ]+(remove|purge|autoremove)[\\t\\n\\f\\r ]+"), "卸载软件包，依赖该包的其他服务可能无法运行；purge 会同时删除配置文件"),
  rule(re("^sudo[\\t\\n\\f\\r ]+yum[\\t\\n\\f\\r ]+remove[\\t\\n\\f\\r ]+"), "卸载软件包，依赖该包的其他服务可能无法运行"),
  rule(re("^sudo[\\t\\n\\f\\r ]+dnf[\\t\\n\\f\\r ]+remove[\\t\\n\\f\\r ]+"), "卸载软件包，依赖该包的其他服务可能无法运行"),
  rule(re("^sudo[\\t\\n\\f\\r ]+pacman[\\t\\n\\f\\r ]+-R[\\t\\n\\f\\r ]+"), "卸载软件包，依赖该包的其他服务可能无法运行"),
  rule(re("^sudo[\\t\\n\\f\\r ]+make[\\t\\n\\f\\r ]+install"), "源码编译安装到系统目录，可能覆盖系统已有的同名程序"),
  rule(re("^sudo[\\t\\n\\f\\r ]+cp[\\t\\n\\f\\r ]+.*[\\t\\n\\f\\r ]+/etc/"), "复制文件到系统配置目录，可能覆盖现有配置"),
  rule(re("^sudo[\\t\\n\\f\\r ]+mv[\\t\\n\\f\\r ]+.*[\\t\\n\\f\\r ]+/etc/"), "移动文件到系统配置目录，可能覆盖现有配置"),
];

/**
 * 仅高亮提示的命令模式. Patterns only, on purpose: getSafetyReason() never consults
 * these, so an info-level command has no reason text and callers fall back to
 * getSafetyTip(). Pinned by the Dart case expecting a null reason for curl.
 */
export const INFO_PATTERNS: readonly RegExp[] = [
  re("curl[\\t\\n\\f\\r ]+http"),
  re("wget[\\t\\n\\f\\r ]+http"),
  re("git[\\t\\n\\f\\r ]+clone"),
  re("^(firewall-cmd|ufw|iptables).*port"),
  re("^systemctl[\\t\\n\\f\\r ]+(start|restart|reload)[\\t\\n\\f\\r ]+"),
  re("^service[\\t\\n\\f\\r ]+\\w+[\\t\\n\\f\\r ]+(start|restart|reload)"),
  re("^npm[\\t\\n\\f\\r ]+install[\\t\\n\\f\\r ]+-g"),
  re("^pip[\\t\\n\\f\\r ]+install[\\t\\n\\f\\r ]+"),
  re("^brew[\\t\\n\\f\\r ]+install[\\t\\n\\f\\r ]+"),
  re("^sudo[\\t\\n\\f\\r ]+(apt|apt-get)[\\t\\n\\f\\r ]+update[\\t\\n\\f\\r ]*$"),
  re("^sudo[\\t\\n\\f\\r ]+yum[\\t\\n\\f\\r ]+makecache"),
  re("^update-alternatives[\\t\\n\\f\\r ]+--(list|display)[\\t\\n\\f\\r ]+"),
  re("^export[\\t\\n\\f\\r ]+"),
];

export const BLOCKED_PATH_PREFIXES: readonly string[] = [
  "/etc",
  "/root",
  "/var/log",
  "/proc",
  "/sys",
  "/dev",
  "/boot",
  "/srv",
  "/run",
  "/usr/local/etc",
];

/** 敏感文件名模式（黑名单，永远禁止读取） */
export const BLOCKED_FILE_PATTERNS: readonly RegExp[] = [
  re("^id_rsa$"),
  re("^id_rsa\\.pub$"),
  re("^id_ed25519$"),
  re("^id_ed25519\\.pub$"),
  re("^id_ecdsa$"),
  re("^id_dsa$"),
  re("\\.key$"),
  re("\\.pem$"),
  re("^credentials(\\.json|\\.yaml|\\.yml)?$"),
  re("^\\.env$"),
  re("^\\.env\\..+$"),
  re("^shadow$"),
  re("^passwd$"),
  re("^\\.netrc$"),
  re("^\\.htpasswd$"),
];

/** 敏感目录名（路径分段匹配，黑名单） */
export const BLOCKED_DIR_NAMES: readonly string[] = [
  ".ssh",
  ".gnupg",
  ".aws",
  ".docker",
  ".kube",
];

/** 用户主目录下的敏感路径（运行时拼接 $HOME） */
export const HOME_BLOCKED_SUFFIXES: readonly string[] = [
  ".ssh",
  ".gnupg",
  ".aws",
  ".docker",
  ".kube",
  ".config/google-chrome",
  ".config/Code",
  ".password-store",
];

/**
 * 获取提示文案（简短，用于状态标签）
 *
 * Exhaustive over SafetyLevel, mirroring the Dart switch that has no default branch:
 * Record<SafetyLevel, string> cannot be constructed with a missing key, so adding a
 * fifth level is a compile error on both sides instead of a silent fallthrough.
 */
export const SAFETY_TIPS: Record<SafetyLevel, string> = {
  safe: "安全命令",
  info: "此操作涉及系统配置或网络下载，请确认操作",
  warn: "危险操作，请仔细确认后再执行",
  blocked: "高危操作，已被安全策略拦截",
};

/**
 * Memoisation for the two regex sweeps. Same 500-entry FIFO eviction as Dart,
 * including its shape: the limit is checked after the insert, so the map settles at
 * exactly 500 entries. reasonCache deliberately caches null ("looked, found
 * nothing") so a safe command is never swept again, which is also why lookups must
 * use has() and get() separately rather than get() alone - get() cannot tell a
 * cached null from an absent key.
 */
const CACHE_LIMIT = 500;
const levelCache = new Map<string, SafetyLevel>();
const reasonCache = new Map<string, string | null>();

function evictOldest(map: Map<string, unknown>): void {
  if (map.size > CACHE_LIMIT) {
    const oldest = map.keys().next();
    if (!oldest.done) map.delete(oldest.value);
  }
}

function firstMatch(rules: readonly SafetyRule[], value: string): string | null {
  for (const r of rules) {
    if (r.pattern.test(value)) return r.reason;
  }
  return null;
}

function anyMatch(patterns: readonly RegExp[], value: string): boolean {
  for (const pattern of patterns) {
    if (pattern.test(value)) return true;
  }
  return false;
}

function anyMatchRule(rules: readonly SafetyRule[], value: string): boolean {
  return firstMatch(rules, value) !== null;
}

/**
 * Port of SafetyGuard.check - classify a command string.
 *
 * Chained commands take the MOST dangerous sub-command, and one match on the whole
 * string short-circuits to blocked before any splitting happens. That pre-split
 * pass is load-bearing rather than an optimisation: a fork bomb is built out of the
 * very characters used to split commands, so splitting first would shred it past
 * recognition. Reproduced exactly; see the Dart comment in _checkInternal.
 */
export function checkSafety(command: string): SafetyLevel {
  const cached = levelCache.get(command);
  if (cached !== undefined) return cached;

  const result = checkInternal(command);
  levelCache.set(command, result);
  evictOldest(levelCache);
  return result;
}

/** 内部检查逻辑：对完整命令的所有子命令分别检查，取最高危险等级 */
function checkInternal(command: string): SafetyLevel {
  // 先对完整命令做一次检查（处理 fork 炸弹等本身含 | ; 字符的单条命令，
  // 这类命令会被 _splitCommands 拆分导致无法匹配整体模式）
  const fullLevel = checkSingle(command);
  if (fullLevel === BLOCKED) return fullLevel;

  const subCommands = splitCommands(command);
  let maxLevel: SafetyLevel = SAFE;

  for (const sub of subCommands) {
    const cleaned = removeComments(sub).trim();
    if (cleaned.length === 0) continue;

    const level = checkSingle(cleaned);
    if (compareLevel(level, maxLevel) > 0) maxLevel = level;
    // 如果已经是 blocked，直接返回
    if (maxLevel === BLOCKED) return maxLevel;
  }

  return maxLevel;
}

/** 检查单条命令（不含链式操作符）: block, then warn, then info, else safe. */
function checkSingle(command: string): SafetyLevel {
  // 命令规范化：防止通过空格变化、引号包裹等绕过安全检查
  const normalized = normalizeCommand(command);
  if (anyMatchRule(BLOCK_RULES, normalized)) return BLOCKED;
  if (anyMatchRule(WARN_RULES, normalized)) return WARN;
  if (anyMatch(INFO_PATTERNS, normalized)) return INFO;
  return SAFE;
}

/**
 * Port of SafetyGuard.getReason: the risk text for the FIRST rule that matches,
 * block rules ahead of warn rules, or null.
 *
 * Two properties callers depend on. Info patterns are never consulted, so an
 * info-level command legitimately has no reason and the caller falls back to
 * getSafetyTip() - the Dart test asserts a null reason for curl. And a command that
 * matches nothing caches that null, so the answer is stable across calls.
 */
export function getSafetyReason(command: string): string | null {
  if (reasonCache.has(command)) return reasonCache.get(command) ?? null;

  // 先对完整命令做一次检查（与 _checkInternal 同样的整体匹配策略）
  const normalized = normalizeCommand(command);
  let reason: string | null = firstMatch(BLOCK_RULES, normalized);
  if (reason === null) reason = firstMatch(WARN_RULES, normalized);

  if (reason === null) {
    for (const sub of splitCommands(command)) {
      const cleaned = normalizeCommand(removeComments(sub).trim());
      if (cleaned.length === 0) continue;
      reason = firstMatch(BLOCK_RULES, cleaned);
      if (reason !== null) break;
      reason = firstMatch(WARN_RULES, cleaned);
      if (reason !== null) break;
    }
  }

  reasonCache.set(command, reason);
  evictOldest(reasonCache);
  return reason;
}

/**
 * Port of _normalizeCommand - strip the common bypass tricks.
 * - 合并多余空格
 * - 去除命令名周围的引号
 * - 去除命令名里的反斜杠转义
 *
 * The unquoting step is copied with the missing backreference of the original: the
 * closing quote does not have to match the opening one, so a quote-then-apostrophe
 * prefix also strips. That is deliberate. The Dart comment above the pattern explains
 * that replaceFirst cannot express a backreference, which is why replaceFirstMapped
 * is used there, and no one ever fixed the pattern itself. Tightening it only here
 * would leave the two runtimes classifying the same displayed command differently -
 * the worse failure, because the UI would show one verdict while the Node side acts
 * on another. Fix it upstream in Dart first, then mirror it here in the same change.
 */
function normalizeCommand(command: string): string {
  let cmd = command.trim();
  // 去除命令名周围的引号：匹配开头的 "xxx" 或 'xxx' 并去除引号
  cmd = cmd.replace(re("^[\"\\']([a-zA-Z_][\\w.-]*)[\"\\']"), (_all, name) => name);
  // 去除反斜杠转义：r\m → rm（仅命令名部分）
  cmd = cmd.replace(re("^([a-zA-Z])(\\\\)([a-zA-Z])"), (_all, head, _slash, tail) => head + tail);
  // 合并多余空格
  cmd = cmd.replaceAll(reAll("[\\t\\n\\f\\r ]{2,}"), " ");
  return cmd;
}

/**
 * Port of _splitCommands: split on newlines and then on &&, ||, ; and |.
 *
 * Deliberately does NOT try to parse $() or backtick subshells - the Dart comment
 * says it plainly: 宁可误报也不漏报, better to over-flag than to miss. Consequence:
 * "echo ok && rm -rf /" inside a subshell still gets classified by its pieces, which
 * is the conservative direction.
 */
function splitCommands(command: string): string[] {
  const results: string[] = [];
  const lines = command.split("\n");
  for (const line of lines) {
    const parts = line.split(re("&&|\\|\\||;|\\|"));
    for (const part of parts) results.push(part);
  }
  return results;
}

/**
 * Port of _removeComments: drop a trailing # comment, but only when the # is
 * unquoted and the character immediately before it is a space.
 *
 * The space requirement is a literal 0x20 comparison in Dart, not whitespace - a tab
 * before # does not start a comment there, and this keeps that. It is a single
 * left-to-right scan that returns at the first qualifying #, so the first unquoted
 * one wins. Quote tracking is per-command (the caller splits lines first) and a
 * quote that is never closed simply suppresses stripping for the rest of the string.
 */
function removeComments(command: string): string {
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (c === "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (c === "\"" && !inSingle) {
      inDouble = !inDouble;
    } else if (c === "#" && !inSingle && !inDouble && (i === 0 || command[i - 1] === " ")) {
      return command.slice(0, i);
    }
  }
  return command;
}

/**
 * 路径安全检查结果
 *
 * Dart declares a const class with two final fields; the nullability of reason is
 * part of the contract - a safe result carries null, and checkReadPath() returns a
 * fresh instance rather than mutating one when it upgrades a warn to safe.
 */
export class PathSafetyResult {
  readonly level: SafetyLevel;
  readonly reason: string | null;

  constructor(level: SafetyLevel, reason: string | null = null) {
    this.level = level;
    this.reason = reason;
  }

  /** info counts as allowed: it is a highlight, not a gate. */
  get isAllowed(): boolean {
    return this.level === SAFE || this.level === INFO;
  }
}

/**
 * Port of SafetyGuard.checkPath - 检查路径安全性
 *
 * [path] 待检查的路径（绝对路径）
 * [projectRoot] 可选：用户授权的项目根目录，在项目内视为安全
 * [isWrite] 是否为写操作（写操作更严格）
 *
 * isWrite is accepted and never read, exactly as Dart declares and never reads it.
 * The parameter is documented as making writes stricter and no step consults it.
 * Inventing a stricter Node-only branch would make the same path acceptable to Dart
 * and refused here, which is the divergence that hurts; the gap belongs upstream.
 *
 * Order is load-bearing. The projectRoot whitelist comes first and can still refuse
 * a sensitive name inside the project, so a projectRoot of "/" blocks .ssh and then
 * waves everything else through. A bare "/" normalises to "/" and matches no prefix
 * rule, landing on the final warn rather than being treated as the root of the
 * blacklist - a quirk of the prefix comparison, kept as-is and pinned by tests.
 * Traversal is folded before matching, so /usr/../etc/passwd is still blocked.
 */
export function checkPath(
  path: string,
  opts: {projectRoot?: string | undefined; isWrite?: boolean} = {},
): PathSafetyResult {
  if (path.length === 0) {
    return new PathSafetyResult(WARN, "路径为空");
  }

  // 规范化路径（去尾斜杠、合并重复斜杠）
  const normalized = normalizePath(path);
  if (normalized.length === 0) {
    return new PathSafetyResult(WARN, "路径规范化后为空");
  }

  // 1. 检查是否在项目根目录内（最高优先级白名单）
  const projectRoot = opts.projectRoot;
  if (projectRoot != null && projectRoot.length > 0) {
    const root = normalizePath(projectRoot);
    if (isPathWithin(normalized, root)) {
      // 项目内：检查是否命中文件名/目录黑名单
      const fileName = normalized.split('/').pop() ?? '';
      for (const pattern of BLOCKED_FILE_PATTERNS) {
        if (pattern.test(fileName)) {
          return new PathSafetyResult(BLOCKED, `敏感文件: ${fileName}（即使项目内也禁止访问）`);
        }
      }
      // 检查路径分段是否含敏感目录名
      for (const segment of normalized.split('/')) {
        if (BLOCKED_DIR_NAMES.includes(segment)) {
          return new PathSafetyResult(BLOCKED, `敏感目录: ${segment}（禁止访问）`);
        }
      }
      return new PathSafetyResult(SAFE, null);
    }
  }

  // 2. 检查全局路径黑名单前缀
  for (const prefix of BLOCKED_PATH_PREFIXES) {
    if (normalized === prefix || normalized.startsWith(prefix + '/')) {
      return new PathSafetyResult(BLOCKED, `系统目录 ${prefix} 禁止访问`);
    }
  }

  // 3. 检查用户主目录下的敏感路径
  const home = getHomeDir();
  if (home != null) {
    for (const suffix of HOME_BLOCKED_SUFFIXES) {
      const sensitivePath = home + "/" + suffix;
      if (normalized === sensitivePath || normalized.startsWith(sensitivePath + "/")) {
        return new PathSafetyResult(BLOCKED, `敏感目录 ~/${suffix} 禁止访问`);
      }
    }
    // 直接读 ~/.ssh/id_rsa 这种情况已被上面覆盖
  }

  // 4. 检查文件名黑名单（项目外也要查）
  const outsideFileName = normalized.split('/').pop() ?? '';
  for (const pattern of BLOCKED_FILE_PATTERNS) {
    if (pattern.test(outsideFileName)) {
      return new PathSafetyResult(BLOCKED, `敏感文件: ${outsideFileName}`);
    }
  }

  // 5. 检查路径分段中的敏感目录
  for (const segment of normalized.split('/')) {
    if (BLOCKED_DIR_NAMES.includes(segment)) {
      return new PathSafetyResult(BLOCKED, `敏感目录: ${segment} 禁止访问`);
    }
  }

  // 6. 项目外的路径需确认（防止 AI 乱跑）
  return new PathSafetyResult(WARN, `路径不在授权的项目目录内: ${normalized}`);
}

/**
 * Port of _normalizePath - 路径规范化：合并重复斜杠、去尾斜杠、解析 . 和 ..
 *
 * The leading separator comes from the ORIGINAL path, tested before any folding, so
 * an absolute path stays absolute even when it folds to nothing ("/" and "/.." both
 * keep the root) and a relative path stays relative. Lexical only: nothing touches
 * the filesystem, so a symlink escaping the project root is invisible here, which is
 * the same contract as the Dart caller that deliberately feeds it a lexical path
 * (services/local_file_policy.dart:147).
 */
function normalizePath(path: string): string {
  const backslash = new RegExp("\\\\", "g");
  let pth = path.replaceAll(backslash, "/"); // Windows 路径转 POSIX
  pth = pth.replaceAll(reAll("/+"), "/"); // 合并重复斜杠
  // 简单解析 . 和 ..
  const segments: string[] = [];
  for (const seg of pth.split('/')) {
    if (seg.length === 0 || seg === ".") continue;
    if (seg === "..") {
      if (segments.length > 0) segments.pop();
      continue;
    }
    segments.push(seg);
  }
  const result = segments.join('/');
  // 绝对路径保留开头的 /：判断依据是原始路径，不是折叠结果
  return path.startsWith('/') ? "/" + result : result;
}

/** Port of _isPathWithin: 判断 path 是否在 root 目录内（规范化后的路径） */
function isPathWithin(path: string, root: string): boolean {
  if (path === root) return true;
  return path.startsWith(root + '/');
}

/**
 * Port of _getHomeDir - 获取用户主目录（用于检查 ~/.ssh 等）
 *
 * Dart reads Platform.environment; the equivalent here is process.env with the same
 * key order (HOME, then USERPROFILE) and the same normalisation, which is what lets a
 * Windows USERPROFILE of C:\Users\me compare equal to a forward-slashed input. Null
 * when neither key is set - including under a test runner, so tests that exercise the
 * home rules must pin HOME themselves. env is a parameter for that reason; Dart has
 * no such hook and never reads it twice in one call.
 */
export function getHomeDir(env: Record<string, string | undefined> = process.env): string | null {
  const home = env["HOME"] ?? env["USERPROFILE"];
  return home !== undefined ? normalizePath(home) : null;
}

/**
 * Port of SafetyGuard.getTip - 获取状态标签文案（简短，用于 UI 标签）
 *
 * Public wrapper over SAFETY_TIPS so callers never index the record themselves and
 * silently invent a label for a level that does not exist.
 */
export function getSafetyTip(level: SafetyLevel): string {
  return SAFETY_TIPS[level];
}

/**
 * Port of SafetyGuard.requireConfirm - 是否需要用户确认
 *
 * warn and blocked both put a human in the loop, irrespective of permission mode.
 * This is deliberately NOT the same question decideCommand() answers: requireConfirm
 * asks "can this level ever need asking", the gate matrix asks "does this level need
 * asking under this mode", and under fullAuto the second one says no for both. The
 * UI label uses requireConfirm, the execution gate uses decideCommand; collapsing
 * them would silently auto-approve what the Dart UI still shows as needing a tap.
 */
export function requireConfirm(level: SafetyLevel): boolean {
  return level === WARN || level === BLOCKED;
}

/**
 * Port of SafetyGuard.checkReadPath - 检查路径是否允许读取（综合判断，给工具层用）
 *
 * [path] 待读取路径
 * [projectRoot] 项目根目录
 * [sourceCodeGranted] 是否已获得源码读取授权（会话级）
 *
 * The warn-to-safe upgrade returns a NEW result rather than mutating, so the original
 * warn reason survives for a caller that logged it - and it is why PathSafetyResult
 * fields are readonly. blocked is passed through untouched: sourceCodeGranted never
 * overrides a block, which is the whole point of separating the two levels.
 */
export function checkReadPath(
  path: string,
  opts: {projectRoot?: string | undefined; sourceCodeGranted?: boolean} = {},
): PathSafetyResult {
  const result = checkPath(path, {projectRoot: opts.projectRoot, isWrite: false});
  // blocked 永远不允许
  if (result.level === BLOCKED) return result;
  // safe 直接放行
  if (result.level === SAFE) return result;
  // warn：若已授权则放行，否则需确认
  if (opts.sourceCodeGranted === true) {
    return new PathSafetyResult(SAFE, null);
  }
  return result;
}
