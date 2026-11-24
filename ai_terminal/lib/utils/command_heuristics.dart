import '../core/safety_guard.dart';
import '../services/daos.dart';

/// 判断文本是否是描述性文字（而非命令）
bool isDescriptiveText(String text) {
  // 中文字符占比过高
  final chineseCount = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
  if (text.isNotEmpty && chineseCount / text.length > 0.5) return true;
  // 常见的说明性开头
  final descriptiveStarts = [
    '请',
    '可以',
    '需要',
    '应该',
    '将',
    '这个',
    '该',
    '命令',
    '说明',
    '例如',
    '如下',
    '包括',
    '用于',
    '表示',
    '输出',
    '结果',
    '检查',
    '查看',
    '确认',
    '注意',
    '提示',
    '警告',
    '步骤'
  ];
  for (final s in descriptiveStarts) {
    if (text.startsWith(s)) return true;
  }
  return false;
}

bool looksLikeCommand(String text) {
  // 检查文本是否看起来像命令
  if (text.length < 3 || text.length > 500) return false;
  // 不应该包含太多中文
  final chineseCount = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
  if (chineseCount > text.length * 0.3) return false;
  // 应该包含至少一个常见命令关键词
  final cmdKeywords = [
    // Unix
    'sudo', 'yum', 'apt', 'dnf', 'apk', 'curl', 'wget', 'tar',
    'cat', 'echo', 'export', 'cd', 'mkdir', 'chmod', 'java',
    'rm', 'cp', 'mv', 'ln', 'systemctl', 'service', 'install',
    'download', 'extract', 'set', 'export', 'source', 'update',
    // Windows
    'dir', 'del', 'copy', 'move', 'rmdir', 'md', 'cls', 'chdir',
    'setx', 'tasklist', 'taskkill', 'ipconfig', 'systeminfo',
    'powershell', 'pwsh', 'winget', 'choco', 'scoop', 'dism',
    'netsh', 'sc ', 'reg ', 'wmic', 'where', 'ftype', 'assoc',
  ];
  return cmdKeywords.any((k) => text.toLowerCase().contains(k));
}

/// 拆出非空子命令（引号/heredoc 感知，与安全层同一套拆分逻辑）
List<String> _subCommands(String command) =>
    SafetyGuard.splitSubCommands(command)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

/// 判断命令是否是查询/只读类命令（输出不应截断，agent 需要完整结果定位问题）
///
/// 组合命令（管道/链式）要求所有子命令均为查询才算查询。
/// 注意：交互式命令（top/htop/less/more/tail -f/man）不视为只读，
/// 因为它们会阻塞 PTY 等待输入，导致 agent 卡死到超时。
/// 这些命令应走默认 60s 超时让 watchdog 中断。
bool isQueryCommand(String command) {
  final subs = _subCommands(command);
  if (subs.length > 1) return subs.every(_isSingleQueryCommand);
  return _isSingleQueryCommand(command);
}

enum _ExitCodeReliability { reliable, background, pipe }

/// 扫描命令里是否有「裸 |」（管道）或「结尾裸 &」（后台），跳过引号/转义/heredoc。
_ExitCodeReliability _scanExitCodeReliability(String command) {
  var inSingle = false;
  var inDouble = false;
  var arithDepth = 0; // $(( ... )) 算术展开内的 | 是位运算，不是管道
  String? heredocTag;
  final heredocStart = RegExp(r'''<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1''');

  for (final line in command.split('\n')) {
    if (heredocTag != null) {
      if (line.trim() == heredocTag) heredocTag = null;
      continue;
    }
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == "'" && !inDouble) {
        inSingle = !inSingle;
        continue;
      }
      if (c == '"' && !inSingle) {
        inDouble = !inDouble;
        continue;
      }
      if (c == '\\' && i + 1 < line.length) {
        i++;
        continue;
      }
      if (inSingle || inDouble) continue;

      // $(( ... )) 算术展开：内部 | & 是位运算，不是管道/后台
      if (c.codeUnitAt(0) == 0x24 &&
          i + 2 < line.length &&
          line[i + 1] == '(' &&
          line[i + 2] == '(') {
        arithDepth++;
        i += 2;
        continue;
      }
      if (arithDepth > 0) {
        if (c == '(' && i + 1 < line.length && line[i + 1] == ')') {
          arithDepth--;
          i++;
        }
        continue;
      }

      // heredoc 起始行：整段 body 跳过，避免 body 里的 | / & 误判
      if (c == '<' && i + 1 < line.length && line[i + 1] == '<') {
        final m = heredocStart.matchAsPrefix(line, i);
        if (m != null) {
          heredocTag = m.group(2);
          i = m.end - 1;
          continue;
        }
      }
      if (c == '|') {
        // 排除 ||（逻辑或）与 | 紧邻 | 的情况
        if ((i > 0 && line[i - 1] == '|') ||
            (i + 1 < line.length && line[i + 1] == '|')) {
          continue;
        }
        return _ExitCodeReliability.pipe;
      }
      if (c == '&') {
        // 排除 &&（逻辑与）、2>&1（重定向）、&>file（重定向）
        if ((i > 0 && (line[i - 1] == '&' || line[i - 1] == '>')) ||
            (i + 1 < line.length &&
                (line[i + 1] == '&' || line[i + 1] == '>'))) {
          continue;
        }
        return _ExitCodeReliability.background;
      }
    }
  }
  return _ExitCodeReliability.reliable;
}

/// 命令的退出码是否不可靠（wrapper 的 `$?` 取最后一段，不能反映真实结果）。
///
/// - 后台命令（`&`）：启动成功 ≠ 进程跑完，状态未知，一律拦截。
/// - 管道（`|`）：纯查询管道（如 `ps aux | head`）只关心输出、无假成功风险，
///   放行；含修改类子命令的管道（如 `apt install | tee`、`curl | sh`）前段
///   失败可能被后段的成功码掩盖，拦截并提示。
String? unreliableExitCodeReason(String command) {
  switch (_scanExitCodeReliability(command)) {
    case _ExitCodeReliability.background:
      return '后台命令（&）的退出码只表示启动成功，无法确认进程最终状态';
    case _ExitCodeReliability.pipe:
      final subs = _subCommands(command);
      if (subs.every(_isReadOnlyPipeStage)) return null;
      return '管道（|）的退出码取最后一段，前段命令失败可能被掩盖';
    case _ExitCodeReliability.reliable:
      return null;
  }
}

/// 纯格式化/拼接类尾段：只消费 stdin、不改系统状态，前段失败仍会体现在输出里。
const _pipeFormatters = <String>[
  'jq',
  'yq',
  'column',
  'fmt',
  'fold',
  'paste',
  'join',
  'expand',
  'unexpand',
  'rev',
  'base64',
  'iconv',
  'strings',
  'numfmt',
  'echo',
  'printf',
];

/// 管道某一段是否只读（查询命令、纯格式化命令、或 xargs 调用只读命令）。
///
/// 这里不能简单套用 [isQueryCommand]：`curl … | jq`、`cat … | tr`、
/// `find … | xargs grep` 都是纯读取，前段失败只影响输出、不会产生假成功；
/// 全部按"非查询"拦掉会让 agent 连最常用的诊断管道都发不出去。
bool _isReadOnlyPipeStage(String stage) {
  final s = stage.trim().toLowerCase();
  if (s.isEmpty) return true;
  if (_isSingleQueryCommand(s)) return true;
  final head = s.split(RegExp(r'\s+')).first;
  if (_pipeFormatters.contains(head)) return true;
  if (head == 'xargs') {
    // xargs 的退出码会传播子命令失败，只要子命令本身只读就无需拦
    final words = s
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && !w.startsWith('-'))
        .toList();
    return words.length > 1 && _isSingleQueryCommand(words[1]);
  }
  return false;
}

/// 判定命令是否会持续阻塞 PTY、永不自行返回（top/vim/tail -f/REPL 等）。
///
/// 与 [isQueryCommand] 里的排除列表不同：那里只把它们排除出"只读"分类，
/// 命令仍会下发并卡到超时。这里是执行前的硬判定，供引擎在写入终端前拦截。
///
/// 保守原则：只拦首词是明确交互程序、且没有把它变成一次性命令的 flag 的场景；
/// 拿不准的（git log 的 pager 会自行退出、python -c 等）一律放行，交给下游兜底。
bool isBlockingInteractiveCommand(String command) =>
    _subCommands(command).any(_isBlockingInteractiveSingle);

bool _isBlockingInteractiveSingle(String command) {
  final parts =
      command.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return false;

  // 跳过前置 env 赋值（FOO=bar top）与 sudo/nice 及其参数
  var i = 0;
  while (i < parts.length &&
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(parts[i])) {
    i++;
  }
  if (i < parts.length && (parts[i] == 'sudo' || parts[i] == 'nice')) {
    i++;
    while (i + 1 < parts.length && (parts[i] == '-u' || parts[i] == '-n')) {
      i += 2;
    }
  }
  if (i >= parts.length) return false;

  final cmd = parts[i].toLowerCase();
  final rest = parts.sublist(i + 1);

  // 明确的交互式 TUI / 分页器：通常任何调用形式都阻塞
  const alwaysBlocking = {
    // man 保留在内：本地会话只设了 GIT_PAGER，未设 MANPAGER，仍会进 less 等待输入
    'top', 'htop', 'vim', 'vi', 'nano', 'less', 'more', 'man', 'watch', 'stern',
  };
  if (alwaysBlocking.contains(cmd)) {
    // top -b（batch 模式）一次性输出后退出，放行
    if (cmd == 'top' && rest.any((a) => a == '-b' || a.startsWith('-b'))) {
      return false;
    }
    return true;
  }

  // 容器/日志的 follow 模式：docker logs -f、kubectl logs -f、journalctl -f、
  // dmesg -w 与 tail -f 同构（永不返回），但首词不是交互程序，需按子命令 + flag 判定。
  // man/git log 不在此列：会话已 export PAGER=cat / GIT_PAGER=cat，它们会直接输出退出。
  const followSubcommands = [
    'docker logs',
    'kubectl logs',
    'journalctl',
    'dmesg',
  ];
  final lower = command.trim().toLowerCase();
  final isFollowScope =
      followSubcommands.any((p) => lower == p || lower.startsWith('$p '));
  if (isFollowScope &&
      rest.any((a) =>
          a == '-f' ||
          a == '-F' ||
          a == '-w' ||
          a == '--follow' ||
          a.startsWith('--follow='))) {
    return true;
  }

  // tail 的 follow 模式（tailf 本身就是 follow）；-n 50 等非 follow 放行
  if (cmd == 'tailf') return true;
  if (cmd == 'tail') {
    return rest.any((a) =>
        a == '-f' || a == '-F' || a == '--follow' || a.startsWith('--follow='));
  }

  // 无参数的交互式 REPL / shell；带 -c 或脚本参数则是一次性执行，放行
  if (rest.isEmpty) {
    const repls = {
      'python',
      'python2',
      'python3',
      'node',
      'ruby',
      'php',
      'lua',
      'mysql',
      'psql',
      'sqlite3',
      'redis-cli',
      'mongo',
      'irb',
      'sh',
      'bash',
      'zsh',
      'dash',
    };
    return repls.contains(cmd);
  }
  return false;
}

bool _isSingleQueryCommand(String command) {
  final queryPrefixes = [
    // 文件搜索与内容查找
    'grep', 'egrep', 'fgrep', 'find', 'locate', 'which', 'where', 'type',
    // 文件查看（不含 less/more — 交互式分页器，agent 不应使用）
    'cat', 'head', 'tail', 'file', 'stat', 'diff', 'readlink', 'realpath',
    'xxd', 'od', 'nl', 'cut', 'tr',
    // 目录列表
    'ls', 'tree', 'du', 'df',
    // 系统信息（扩充硬件/资源查看）
    'uname', 'hostname', 'uptime', 'free', 'env', 'printenv', 'pwd',
    'whoami', 'id', 'date', 'cal', 'arch', 'nproc',
    'lscpu', 'lsblk', 'lspci', 'lsusb', 'lsmem', 'lsns', 'lsmod',
    // 进程与资源（不含 top/htop — 交互式）
    'ps', 'lsof', 'ss', 'netstat', 'vmstat', 'iostat', 'sar', 'iotop', 'atop',
    'pidof', 'pgrep',
    // 系统管理（只读子命令，扩充 show/is-active/is-enabled）
    'systemctl status', 'systemctl list', 'systemctl is-', 'systemctl show',
    'systemctl cat', 'systemctl help',
    'service status',
    // 日志查看
    'journalctl', 'dmesg', 'last', 'lastb', 'w', 'who',
    // 容器/编排（只读子命令，扩充 stats/top/history/version/info）
    'docker ps', 'docker images', 'docker logs', 'docker inspect',
    'docker search',
    'docker stats', 'docker top', 'docker history', 'docker version',
    'docker info',
    'kubectl get', 'kubectl describe', 'kubectl logs', 'kubectl top',
    'kubectl explain', 'kubectl version', 'kubectl cluster-info',
    // 包管理（只读子命令）
    'apt list', 'apt show', 'apt-cache', 'yum list', 'yum info',
    'dnf list', 'dnf info', 'rpm -q', 'dpkg -l', 'dpkg -s',
    // 网络（只读）
    'ping', 'traceroute', 'dig', 'nslookup', 'host', 'curl', 'wget',
    'ip addr', 'ip route', 'ip link', 'ifconfig',
    // 防火墙规则查看（只读）
    'iptables -l', 'iptables -s', 'iptables -n', 'iptables -nl',
    'ufw status', 'firewall-cmd',
    // Git 只读子命令
    'git status', 'git log', 'git diff', 'git show', 'git branch', 'git remote',
    'git rev-parse', 'git config --get', 'git ls-files',
    // 计划任务查看
    'crontab -l',
    // 用户/组查询
    'getent', 'groups', 'finger',
    // 文本统计
    'wc', 'sort', 'uniq', 'awk', 'sed -n',
    // Windows 只读命令
    'dir', 'type', 'where', 'systeminfo', 'ipconfig', 'tasklist',
    'wmic', 'netstat', 'get-process', 'get-childitem', 'get-content',
    'get-service', 'get-item', 'test-path', 'select-string',
    'get-ciminstance', 'get-wmiobject',
  ];

  // 显式排除交互式分页/跟踪命令
  // - tail -f / tail --follow / tailf：持续跟踪日志，永不结束
  // - top / htop：交互式进程监控
  // - less / more / man / vim / vi / nano：交互式编辑器或分页器
  // 这些命令会让 agent 卡住到超时，不应作为只读
  final cmdLower = command.trim().toLowerCase();
  const interactivePrefixes = [
    'tail -f',
    'tail --follow',
    'tailf',
    'top ',
    'top\n',
    'htop',
    'less ',
    'less\n',
    'more ',
    'more\n',
    'man ',
    'vim ',
    'vi ',
    'nano ',
  ];
  if (cmdLower == 'top' ||
      cmdLower == 'less' ||
      cmdLower == 'more' ||
      cmdLower == 'vi' ||
      cmdLower == 'vim' ||
      cmdLower == 'nano') {
    return false;
  }
  for (final p in interactivePrefixes) {
    if (cmdLower.startsWith(p)) return false;
  }
  return queryPrefixes.any((prefix) => cmdLower.startsWith(prefix));
}

const _taskCompleteKeywords = [
  '任务完成',
  '任务已完成',
  '已全部完成',
  '全部完成',
  '所有步骤已完成',
  '操作完成',
  '安装完成',
  '配置完成',
  '部署完成',
  '已完成',
];

// 行首允许的前缀（emoji / markdown / 中文标点）
final RegExp _taskCompleteStartRegex = RegExp(
  r'^[\s✅❌🎉🏁【\[*#\-•>]*(' +
      _taskCompleteKeywords.join('|') +
      r')[\s。！!？?】\]*·…]*$',
);
// 行尾模式：前文允许少量说明（≤ 30 字符），关键词后只允许标点
final RegExp _taskCompleteEndRegex = RegExp(
  '^.{0,30}?(' + _taskCompleteKeywords.join('|') + r')[\s。！!？?】\]*·…]*$',
);
final RegExp _lineBreakRegex = RegExp(r'\r?\n');

bool isTaskComplete(String response) {
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
  if (response.trim().isEmpty) return false;

  final lines = response.split(_lineBreakRegex);
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    // 长行不考虑匹配，避免 AI 长篇思考中偶然出现关键词被误判
    if (trimmed.length > 60) continue;
    if (_taskCompleteStartRegex.hasMatch(trimmed)) return true;
    if (_taskCompleteEndRegex.hasMatch(trimmed)) return true;
  }
  return false;
}

/// 去掉命令开头的提权/环境包装，返回"真正的命令"用于超时档位匹配。
///
/// 必要性（AGENTS.md R6）：`getCommandTimeout` 用 `startsWith` 匹配档位，
/// `sudo apt update` 原串匹配不到 `apt update`，落到 60s 默认值——
/// 而 apt 在慢网络上远超 60s，必然假失败并触发重试循环。
///
/// 已知局限：带值选项（`sudo -u postgres apt update`）剥到 `-u` 即停，
/// 剩下 `postgres apt update` 匹配不到档位，行为与修复前一致。
String _unwrapCommand(String cmd) {
  const wrappers = {'sudo', 'env', 'nohup', 'time', 'exec'};
  final envAssign = RegExp(r'^[a-z_][a-z0-9_]*=');
  final tokens = cmd.split(RegExp(r'\s+'));
  var i = 0;
  var stripped = false;
  while (i < tokens.length) {
    final token = tokens[i];
    if (!wrappers.contains(token) && !envAssign.hasMatch(token)) break;
    i++;
    stripped = true;
    // 吃掉紧随其后的选项(-S/-E)与环境变量赋值，遇到第一个实义命令词停止
    while (i < tokens.length &&
        (tokens[i].startsWith('-') || envAssign.hasMatch(tokens[i]))) {
      i++;
    }
  }
  if (!stripped) return cmd;
  final unwrapped = tokens.sublist(i).join(' ');
  return unwrapped.isEmpty ? cmd : unwrapped;
}

/// 按命令类型返回合适的执行超时。
/// - 长时间运行类（安全扫描/包管理/系统信息/大文件操作）：10 分钟
/// - 中等耗时类（服务状态/日志/进程/编译/下载）：3 分钟
/// - 默认：60 秒
/// 组合命令（管道/链式）取所有子命令档位的最大值。
/// 用户可通过设置 `commandTimeoutMultiplier` 调整超时倍数（如 2.0 = 所有超时翻倍）
Duration getCommandTimeout(String command) {
  // 读取用户配置的超时倍数（默认 1.0，clamp 到 [0.5, 10.0]）
  // 下限 0.5：低于此值时 (3 * multiplier).round() 会归零，导致 medium 命令瞬间超时
  double multiplier = 1.0;
  try {
    final saved = SettingsDao.getCached('commandTimeoutMultiplier');
    if (saved != null) {
      multiplier = (double.tryParse(saved.toString()) ?? 1.0).clamp(0.5, 10.0);
    }
  } catch (_) {}

  final subs = _subCommands(command);
  if (subs.length > 1) {
    var maxTimeout = Duration.zero;
    for (final sub in subs) {
      final t = _singleCommandTimeout(sub, multiplier);
      if (t > maxTimeout) maxTimeout = t;
    }
    return maxTimeout;
  }
  return _singleCommandTimeout(command, multiplier);
}

Duration _singleCommandTimeout(String command, double multiplier) {
  final cmd = _unwrapCommand(command.trim().toLowerCase());

  // 10 分钟：长时间运行类
  final longTimeout = Duration(minutes: (10 * multiplier).round());
  const longPrefixes = <String>[
    // 安全扫描
    'lynis', 'nikto', 'nmap', 'clamscan', 'rkhunter', 'chkrootkit', 'aide',
    // 包管理（安装/升级/更新/卸载）
    'apt install', 'apt-get install', 'apt upgrade', 'apt-get upgrade',
    'apt update', 'apt-get update', 'apt dist-upgrade',
    'apt autoremove', 'apt remove', 'apt purge',
    'yum install', 'yum update', 'yum upgrade',
    'dnf install', 'dnf update', 'dnf upgrade',
    'apk add', 'pacman -S', 'pacman -Syu',
    'pip install', 'pip3 install', 'npm install', 'npm ci',
    'yarn install', 'gem install', 'cargo install',
    'go install', 'composer install',
    'brew install', 'brew upgrade', 'winget install', 'choco install',
    'scoop install',
    // 系统信息/补丁
    'systeminfo', 'wmic', 'get-ciminstance', 'get-wmiobject',
    'dism /online', 'dism /image',
    // 大文件/全盘操作
    'find /', 'find ~', 'locate ', 'updatedb',
    'dd if=', 'rsync', 'tar -', 'zip -r', 'unzip',
    // 编译构建（可能较长）
    'make', 'cmake', 'cargo build', 'npm run build', 'yarn build',
    'gradle build', 'mvn ', 'mvn clean',
    // 基础设施编排（可达数十分钟）
    'terraform apply', 'terraform plan', 'terraform destroy',
    'ansible-playbook', 'ansible-galaxy',
    'helm install', 'helm upgrade', 'helm template',
    // 磁盘检查/修复
    'fsck', 'e2fsck', 'xfs_repair', 'btrfs check',
    'restorecon', 'setfiles',
    // 容器镜像推送/构建
    'docker push', 'docker build', 'docker compose',
    'docker-compose',
    // 包配置修复
    'dpkg --configure',
  ];
  for (final p in longPrefixes) {
    if (cmd.startsWith(p)) return longTimeout;
  }

  // 3 分钟：中等耗时类
  final mediumTimeout = Duration(minutes: (3 * multiplier).round());
  const mediumPrefixes = <String>[
    // 服务/进程状态
    'systemctl status', 'systemctl restart', 'systemctl start',
    'systemctl stop',
    'service ', 'journalctl', 'dmesg',
    // 进程查看
    'ps aux', 'ps -ef',
    // 网络诊断
    'ping ', 'traceroute', 'tracepath', 'curl ', 'wget ',
    'nslookup', 'dig ', 'host ',
    // 下载（小文件）
    'git clone', 'git pull', 'git fetch',
    // 容器操作
    'docker build', 'docker pull', 'docker run', 'docker exec',
    'kubectl apply', 'kubectl delete', 'kubectl exec',
    // 编译运行
    'go build', 'go test', 'go run', 'cargo run', 'cargo test',
    'python ', 'python3 ', 'node ', 'ruby ',
  ];
  for (final p in mediumPrefixes) {
    if (cmd.startsWith(p)) return mediumTimeout;
  }

  // 默认 60 秒
  return Duration(seconds: (60 * multiplier).round());
}
