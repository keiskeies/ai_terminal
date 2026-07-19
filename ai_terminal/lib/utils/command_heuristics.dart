import '../services/daos.dart';

/// 判断文本是否是描述性文字（而非命令）
bool isDescriptiveText(String text) {
  // 中文字符占比过高
  final chineseCount = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
  if (text.isNotEmpty && chineseCount / text.length > 0.5) return true;
  // 常见的说明性开头
  final descriptiveStarts = ['请', '可以', '需要', '应该', '将', '这个', '该',
    '命令', '说明', '例如', '如下', '包括', '用于', '表示', '输出', '结果',
    '检查', '查看', '确认', '注意', '提示', '警告', '步骤'];
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

/// 判断命令是否是查询/只读类命令（输出不应截断，agent 需要完整结果定位问题）
///
/// 注意：交互式命令（top/htop/less/more/tail -f/man）不视为只读，
/// 因为它们会阻塞 PTY 等待输入，导致 agent 卡死到超时。
/// 这些命令应走默认 60s 超时让 watchdog 中断。
bool isQueryCommand(String command) {
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
    'docker ps', 'docker images', 'docker logs', 'docker inspect', 'docker search',
    'docker stats', 'docker top', 'docker history', 'docker version', 'docker info',
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
    'tail -f', 'tail --follow', 'tailf',
    'top ', 'top\n', 'htop',
    'less ', 'less\n', 'more ', 'more\n',
    'man ', 'vim ', 'vi ', 'nano ',
  ];
  if (cmdLower == 'top' || cmdLower == 'less' || cmdLower == 'more' ||
      cmdLower == 'vi' || cmdLower == 'vim' || cmdLower == 'nano') {
    return false;
  }
  for (final p in interactivePrefixes) {
    if (cmdLower.startsWith(p)) return false;
  }
  return queryPrefixes.any((prefix) => cmdLower.startsWith(prefix));
}

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

  const keywords = [
    '任务完成', '任务已完成',
    '已全部完成', '全部完成', '所有步骤已完成',
    '操作完成', '安装完成', '配置完成', '部署完成',
    '已完成',
  ];
  // 行首允许的前缀（emoji / markdown / 中文标点）
  final startRegex = RegExp(
    r'^[\s✅❌🎉🏁【\[*#\-•>]*(' +
        keywords.join('|') +
        r')[\s。！!？?】\]*·…]*$',
  );
  // 行尾模式：前文允许少量说明（≤ 30 字符），关键词后只允许标点
  final endRegex = RegExp(
    '^.{0,30}?(' + keywords.join('|') + r')[\s。！!？?】\]*·…]*$',
  );

  final lines = response.split(RegExp(r'\r?\n'));
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    // 长行不考虑匹配，避免 AI 长篇思考中偶然出现关键词被误判
    if (trimmed.length > 60) continue;
    if (startRegex.hasMatch(trimmed)) return true;
    if (endRegex.hasMatch(trimmed)) return true;
  }
  return false;
}

/// 按命令类型返回合适的执行超时。
/// - 长时间运行类（安全扫描/包管理/系统信息/大文件操作）：10 分钟
/// - 中等耗时类（服务状态/日志/进程/编译/下载）：3 分钟
/// - 默认：60 秒
/// 用户可通过设置 `commandTimeoutMultiplier` 调整超时倍数（如 2.0 = 所有超时翻倍）
Duration getCommandTimeout(String command) {
  final cmd = command.trim().toLowerCase();

  // 读取用户配置的超时倍数（默认 1.0，clamp 到 [0.5, 10.0]）
  // 下限 0.5：低于此值时 (3 * multiplier).round() 会归零，导致 medium 命令瞬间超时
  double multiplier = 1.0;
  try {
    final saved = SettingsDao.getCached('commandTimeoutMultiplier');
    if (saved != null) {
      multiplier = (double.tryParse(saved.toString()) ?? 1.0).clamp(0.5, 10.0);
    }
  } catch (_) {}

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
    'systemctl status', 'systemctl restart', 'systemctl start', 'systemctl stop',
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
