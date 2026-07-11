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
bool isQueryCommand(String command) {
  final queryPrefixes = [
    // 文件搜索与内容查找
    'grep', 'egrep', 'fgrep', 'find', 'locate', 'which', 'where', 'type',
    // 文件查看
    'cat', 'head', 'tail', 'less', 'more', 'file', 'stat', 'diff',
    // 目录列表
    'ls', 'tree', 'du', 'df',
    // 系统信息
    'uname', 'hostname', 'uptime', 'free', 'env', 'printenv', 'pwd',
    'whoami', 'id', 'date', 'cal',
    // 进程与服务
    'ps', 'top', 'htop', 'lsof', 'ss', 'netstat', 'vmstat', 'iostat',
    // 系统管理（只读子命令）
    'systemctl status', 'systemctl list', 'systemctl is-',
    'service status',
    // 日志查看
    'journalctl', 'dmesg', 'last', 'lastb', 'w', 'who',
    // 容器/编排（只读子命令）
    'docker ps', 'docker images', 'docker logs', 'docker inspect', 'docker search',
    'kubectl get', 'kubectl describe', 'kubectl logs', 'kubectl top',
    // 包管理（只读子命令）
    'apt list', 'apt show', 'apt-cache', 'yum list', 'yum info',
    'dnf list', 'dnf info', 'rpm -q', 'dpkg -l', 'dpkg -s',
    // 网络（只读）
    'ping', 'traceroute', 'dig', 'nslookup', 'host', 'curl', 'wget',
    'ip addr', 'ip route', 'ip link', 'ifconfig',
    // 文本统计
    'wc', 'sort', 'uniq', 'awk', 'sed -n',
    // Windows 只读命令
    'dir', 'type', 'where', 'systeminfo', 'ipconfig', 'tasklist',
    'wmic', 'netstat', 'get-process', 'get-childitem', 'get-content',
    'get-service', 'get-item', 'test-path', 'select-string',
  ];

  final cmdLower = command.trim().toLowerCase();
  return queryPrefixes.any((prefix) => cmdLower.startsWith(prefix));
}

bool isTaskComplete(String response) {
  final keywords = [
    '任务完成', '任务已完成', '✅ 任务完成', '✅任务完成',
    '已完成', '已全部完成', '全部完成', '所有步骤已完成',
    '操作完成', '安装完成', '配置完成', '部署完成',
  ];
  for (final k in keywords) {
    if (response.contains(k)) return true;
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
    // 进程查看（top/htop 交互式，但 agent 用时通常快速）
    'ps aux', 'ps -ef', 'top -', 'htop',
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
