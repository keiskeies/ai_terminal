/// 判断文本是否是描述性文字（而非命令）
bool isDescriptiveText(String text) {
  // 中文字符占比过高
  final chineseCount = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
  if (text.length > 0 && chineseCount / text.length > 0.5) return true;
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
