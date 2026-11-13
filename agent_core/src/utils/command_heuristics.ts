// utils/command_heuristics.ts - port of the isQueryCommand predicate from
// ai_terminal/lib/utils/command_heuristics.dart (lines 40-117). 1:1: same
// prefix table, same order, same interactive exclusions. Round 127 adds the
// completion-sounding fallback isTaskComplete (Dart 119-163): same keyword
// table, same two anchored per-line patterns, same 60-char line cap. The
// Round 205: isDescriptiveText + looksLikeCommand (Dart 4-38) added as the
// command_extractor.ts call site arrived. _unwrapCommand remains Dart-only.

/// 判断命令是否是查询/只读类命令（输出不应截断，agent 需要完整结果定位问题）
///
/// 注意：交互式命令（top/htop/less/more/tail -f/man）不视为只读，
/// 因为它们会阻塞 PTY 等待输入，导致 agent 卡死到超时。
/// 这些命令应走默认 60s 超时让 watchdog 中断。
// R8: "查询命令不截断" is a lie the old comment told - the engine now caps
// query output too (truncateQueryOutput, 20000 tail); this predicate only
// decides WHICH cap applies (tail-20000 vs the 8-line/600-char default).
export const QUERY_PREFIXES: string[] = [
  // 文件搜索与内容查找
  "grep", "egrep", "fgrep", "find", "locate", "which", "where", "type",
  // 文件查看（不含 less/more — 交互式分页器，agent 不应使用）
  "cat", "head", "tail", "file", "stat", "diff", "readlink", "realpath",
  "xxd", "od", "nl", "cut", "tr",
  // 目录列表
  "ls", "tree", "du", "df",
  // 系统信息（扩充硬件/资源查看）
  "uname", "hostname", "uptime", "free", "env", "printenv", "pwd",
  "whoami", "id", "date", "cal", "arch", "nproc",
  "lscpu", "lsblk", "lspci", "lsusb", "lsmem", "lsns", "lsmod",
  // 进程与资源（不含 top/htop — 交互式）
  "ps", "lsof", "ss", "netstat", "vmstat", "iostat", "sar", "iotop", "atop",
  "pidof", "pgrep",
  // 系统管理（只读子命令，扩充 show/is-active/is-enabled）
  "systemctl status", "systemctl list", "systemctl is-", "systemctl show",
  "systemctl cat", "systemctl help",
  "service status",
  // 日志查看
  "journalctl", "dmesg", "last", "lastb", "w", "who",
  // 容器/编排（只读子命令，扩充 stats/top/history/version/info）
  "docker ps", "docker images", "docker logs", "docker inspect", "docker search",
  "docker stats", "docker top", "docker history", "docker version", "docker info",
  "kubectl get", "kubectl describe", "kubectl logs", "kubectl top",
  "kubectl explain", "kubectl version", "kubectl cluster-info",
  // 包管理（只读子命令）
  "apt list", "apt show", "apt-cache", "yum list", "yum info",
  "dnf list", "dnf info", "rpm -q", "dpkg -l", "dpkg -s",
  // 网络（只读）
  "ping", "traceroute", "dig", "nslookup", "host", "curl", "wget",
  "ip addr", "ip route", "ip link", "ifconfig",
  // 防火墙规则查看（只读）
  "iptables -l", "iptables -s", "iptables -n", "iptables -nl",
  "ufw status", "firewall-cmd",
  // Git 只读子命令
  "git status", "git log", "git diff", "git show", "git branch", "git remote",
  "git rev-parse", "git config --get", "git ls-files",
  // 计划任务查看
  "crontab -l",
  // 用户/组查询
  "getent", "groups", "finger",
  // 文本统计
  "wc", "sort", "uniq", "awk", "sed -n",
  // Windows 只读命令
  "dir", "type", "where", "systeminfo", "ipconfig", "tasklist",
  "wmic", "netstat", "get-process", "get-childitem", "get-content",
  "get-service", "get-item", "test-path", "select-string",
  "get-ciminstance", "get-wmiobject",
];

// 显式排除交互式分页/跟踪命令
// - tail -f / tail --follow / tailf：持续跟踪日志，永不结束
// - top / htop：交互式进程监控
// - less / more / man / vim / vi / nano：交互式编辑器或分页器
// 这些命令会让 agent 卡住到超时，不应作为只读
export const INTERACTIVE_PREFIXES: string[] = [
  "tail -f", "tail --follow", "tailf",
  "top ", "top\n", "htop",
  "less ", "less\n", "more ", "more\n",
  "man ", "vim ", "vi ", "nano ",
];

export function isQueryCommand(command: string): boolean {
  const cmdLower = command.trim().toLowerCase();
  if (cmdLower == "top" || cmdLower == "less" || cmdLower == "more" ||
      cmdLower == "vi" || cmdLower == "vim" || cmdLower == "nano") {
    return false;
  }
  for (const p of INTERACTIVE_PREFIXES) {
    if (cmdLower.startsWith(p)) return false;
  }
  return QUERY_PREFIXES.some((prefix) => cmdLower.startsWith(prefix));
}

// Round 127: completion-sounding finish fallback, Dart 119-163. The keyword
// table, the alternation order and both anchored patterns are transcribed
// from the Dart source; test/command_heuristics.test.ts locks them against
// drift and replays the Dart isTaskComplete corpus (16 cases, 385-451).
export const TASK_COMPLETE_KEYWORDS: string[] = [
  '任务完成', '任务已完成',
  '已全部完成', '全部完成', '所有步骤已完成',
  '操作完成', '安装完成', '配置完成', '部署完成',
  '已完成',
];

// 行首允许的前缀（emoji / markdown / 中文标点）
// Dart 127-131 builds the pattern by concatenating raw string fragments with
// join('|'); the JS construction below produces a .source-identical RegExp
// (the concatenation introduces no metacharacter), locked in the drift test.
export const TASK_COMPLETE_START: RegExp = new RegExp(
  '^[\\s✅❌🎉🏁【\\[*#\\-•>]*(' +
    TASK_COMPLETE_KEYWORDS.join('|') +
    ')[\\s。！!？?】\\]*·…]*$',
);

// 行尾模式：前文允许少量说明（≤ 30 字符），关键词后只允许标点
export const TASK_COMPLETE_END: RegExp = new RegExp(
  '^.{0,30}?(' + TASK_COMPLETE_KEYWORDS.join('|') +
    ')[\\s。！!？?】\\]*·…]*$',
);

// Dart 136 (_lineBreakRegex = RegExp(r'\r?\n')) is inlined at the split
// below: the engine hands us its raw response, which may carry CRLF.
export function isTaskComplete(response: string): boolean {
  // 仅在关键词作为"独立行/标题"或"短句末尾"出现时才视为任务完成。
  // 早期实现用 response.contains(k) 会在 AI 思考过程中误触发：
  //   - "我会检查任务完成情况"（关键词后跟其他文字）
  //   - "如果安装完成则继续"（关键词后跟条件）
  //   - "已完成了上述步骤"（关键词后跟动词）
  //
  // 收紧规则（每行单独判断）：
  // 1. 行较短（≤ 60 字符），避免长思考段落中偶然出现关键词
  // 2. 关键词出现在行首（允许 emoji/markdown 前缀，行尾只允许标点/emoji）
  // 3. 或关键词出现在行尾（前文允许 ≤ 30 字符说明，后跟仅标点）
  // 这样 "任务完成"、"✅ 任务完成"、"安装已完成。" 都视为完成，
  // 而 "我会检查任务完成情况"、"如果安装完成则继续" 不视为完成。
  if (response.trim().length === 0) return false;

  const lines = response.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;
    // 长行不考虑匹配，避免 AI 长篇思考中偶然出现关键词被误判
    if (trimmed.length > 60) continue;
    if (TASK_COMPLETE_START.test(trimmed)) return true;
    if (TASK_COMPLETE_END.test(trimmed)) return true;
  }
  return false;
}


/// 判断文本是否是描述性文字（而非命令）
// Dart command_heuristics.dart 4-16, 1:1: same CJK-ratio gate (0.5),
// same 22-entry descriptive-starts table, same order.
export function isDescriptiveText(text: string): boolean {
  // 中文字符占比过高
  const chineseCount = (text.match(/[\u4e00-\u9fa5]/g) ?? []).length;
  if (text.length > 0 && chineseCount / text.length > 0.5) return true;
  // 常见的说明性开头
  const descriptiveStarts = ["请", "可以", "需要", "应该", "将", "这个", "该", "命令", "说明", "例如", "如下", "包括", "用于", "表示", "输出", "结果", "检查", "查看", "确认", "注意", "提示", "警告", "步骤"];
  for (const s of descriptiveStarts) {
    if (text.startsWith(s)) return true;
  }
  return false;
}

// Dart command_heuristics.dart 18-38, 1:1: same length gate (3..500),
// same CJK-ratio gate (0.3), same keyword table (Unix + Windows,
// including the duplicate 'export' entry and the trailing-space
// 'sc '/'reg ' entries), same lowercase-contains matching.
export function looksLikeCommand(text: string): boolean {
  // 检查文本是否看起来像命令
  if (text.length < 3 || text.length > 500) return false;
  // 不应该包含太多中文
  const chineseCount = (text.match(/[\u4e00-\u9fa5]/g) ?? []).length;
  if (chineseCount > text.length * 0.3) return false;
  // 应该包含至少一个常见命令关键词
  const cmdKeywords = [
    // Unix
    "sudo", "yum", "apt", "dnf", "apk", "curl", "wget", "tar",
    "cat", "echo", "export", "cd", "mkdir", "chmod", "java",
    "rm", "cp", "mv", "ln", "systemctl", "service", "install",
    "download", "extract", "set", "export", "source", "update",
    // Windows
    "dir", "del", "copy", "move", "rmdir", "md", "cls", "chdir",
    "setx", "tasklist", "taskkill", "ipconfig", "systeminfo",
    "powershell", "pwsh", "winget", "choco", "scoop", "dism",
    "netsh", "sc ", "reg ", "wmic", "where", "ftype", "assoc",
  ];
  return cmdKeywords.some((k) => text.toLowerCase().includes(k));
}
