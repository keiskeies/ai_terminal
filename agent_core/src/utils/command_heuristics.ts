// utils/command_heuristics.ts - port of the isQueryCommand predicate from
// ai_terminal/lib/utils/command_heuristics.dart (lines 40-117). 1:1: same
// prefix table, same order, same interactive exclusions. The file's other
// helpers (isDescriptiveText / looksLikeCommand / completion keywords) have
// no Node call site yet and are deliberately NOT ported ahead of demand.

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
