/// 命令安全等级
enum SafetyLevel {
  safe,    // 安全（只读命令）
  info,    // 仅提示（低风险修改）
  warn,    // 需二次确认（高风险修改）
  blocked, // 直接拦截（不可逆操作）
}

class SafetyGuard {
  /// 静态缓存，避免对同一条命令重复正则匹配
  static final Map<String, SafetyLevel> _cache = {};

  // 直接拦截的命令模式
  static final List<RegExp> _blockPatterns = [
    RegExp(r'^rm\s+-rf\s+/\s*$'),
    RegExp(r'^rm\s+-rf\s+\/\*?\s*$'),
    RegExp(r'^dd\s+if=.*of=/dev/'),
    RegExp(r'^:\(\)\{\s*:\|\:&\s*\};:', caseSensitive: false),
    RegExp(r'chmod\s+-R\s+777\s+/'),
    RegExp(r'^init\s+0\s*$'),
    RegExp(r'^shutdown\s+-h\s+now'),
    RegExp(r'^rm\s+-rf\s+/etc/'),
    RegExp(r'^rm\s+-rf\s+/boot/'),
    RegExp(r'^rm\s+-rf\s+~'),
    RegExp(r'^mkfs\.'),
    RegExp(r'^>\s*/etc/'),
  ];

  // 需二次确认的命令模式（高风险修改操作）
  static final List<RegExp> _warnPatterns = [
    // 系统级操作
    RegExp(r'^sudo\s+(reboot|shutdown|halt|poweroff|init\s+)'),
    RegExp(r'^systemctl\s+(stop|disable)\s+ssh'),
    RegExp(r'^(iptables|firewall-cmd|ufw).*(-F|--flush|--delete-chain)'),
    RegExp(r'^fdisk\s+/'),
    RegExp(r'^mkfs\.(ext4|xfs|btrfs)\s+/dev/'),
    RegExp(r'^dd\s+if=.*of=/dev/'),
    RegExp(r'^rm\s+-rf\s+/'),
    // 安装/升级/替换软件包
    RegExp(r'^sudo\s+(apt|apt-get)\s+(install|upgrade|dist-upgrade|remove|purge)\s+'),
    RegExp(r'^sudo\s+yum\s+(install|update|remove|erase)\s+'),
    RegExp(r'^sudo\s+dnf\s+(install|upgrade|remove)\s+'),
    RegExp(r'^sudo\s+apk\s+add\s+'),
    RegExp(r'^sudo\s+pacman\s+-S\s+'),
    RegExp(r'^sudo\s+snap\s+install\s+'),
    // 修改环境配置
    RegExp(r'(>>|>)\s*(/etc/profile|/etc/environment|/etc/bashrc|~/\.bashrc|~/\.zshrc|~/\.bash_profile|~/\.profile)\s*$'),
    RegExp(r'^sudo\s+(tee|sed|echo.*>)\s+.*(/etc/profile|/etc/environment|/etc/bashrc)\s*$'),
    // alternatives/update-alternatives
    RegExp(r'^sudo\s+update-alternatives\s+--set\s+'),
    RegExp(r'^sudo\s+alternatives\s+--set\s+'),
    // 卸载操作
    RegExp(r'^sudo\s+(apt|apt-get)\s+(remove|purge|autoremove)\s+'),
    RegExp(r'^sudo\s+yum\s+remove\s+'),
    RegExp(r'^sudo\s+dnf\s+remove\s+'),
    RegExp(r'^sudo\s+pacman\s+-R\s+'),
    // 源码编译安装
    RegExp(r'^sudo\s+make\s+install'),
    // 覆盖写入系统文件
    RegExp(r'^sudo\s+cp\s+.*\s+/etc/'),
    RegExp(r'^sudo\s+mv\s+.*\s+/etc/'),
  ];

  // 仅高亮提示的命令模式
  static final List<RegExp> _infoPatterns = [
    RegExp(r'curl\s+http'),
    RegExp(r'wget\s+http'),
    RegExp(r'git\s+clone'),
    RegExp(r'^(firewall-cmd|ufw|iptables).*port'),
    RegExp(r'^systemctl\s+(start|restart|reload)\s+'),
    RegExp(r'^service\s+\w+\s+(start|restart|reload)'),
    RegExp(r'^npm\s+install\s+-g'),
    RegExp(r'^pip\s+install\s+'),
    RegExp(r'^brew\s+install\s+'),
    RegExp(r'^sudo\s+(apt|apt-get)\s+update\s*$'),
    RegExp(r'^sudo\s+yum\s+makecache'),
    RegExp(r'^update-alternatives\s+--(list|display)\s+'),
    RegExp(r'^export\s+'),
  ];

  /// 检查命令安全等级（带缓存）
  static SafetyLevel check(String command) {
    if (_cache.containsKey(command)) {
      return _cache[command]!;
    }

    final result = _checkInternal(command);
    _cache[command] = result;
    if (_cache.length > 500) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  /// 内部检查逻辑：对完整命令的所有子命令分别检查
  static SafetyLevel _checkInternal(String command) {
    // 拆分链式命令，对每个子命令分别检查，取最高危险等级
    final subCommands = _splitCommands(command);
    var maxLevel = SafetyLevel.safe;

    for (final sub in subCommands) {
      final cleaned = _removeComments(sub).trim();
      if (cleaned.isEmpty) continue;

      final level = _checkSingle(cleaned);
      if (_compareLevel(level, maxLevel) > 0) {
        maxLevel = level;
      }
      // 如果已经是 blocked，直接返回
      if (maxLevel == SafetyLevel.blocked) return maxLevel;
    }

    return maxLevel;
  }

  /// 检查单条命令（不含链式操作符）
  static SafetyLevel _checkSingle(String command) {
    for (final pattern in _blockPatterns) {
      if (pattern.hasMatch(command)) {
        return SafetyLevel.blocked;
      }
    }
    for (final pattern in _warnPatterns) {
      if (pattern.hasMatch(command)) {
        return SafetyLevel.warn;
      }
    }
    for (final pattern in _infoPatterns) {
      if (pattern.hasMatch(command)) {
        return SafetyLevel.info;
      }
    }
    return SafetyLevel.safe;
  }

  /// 拆分链式命令：按 && || ; | 分割，返回所有子命令
  /// 注意：不处理 $() 和反引号内的内容（保守处理，宁可误报也不漏报）
  static List<String> _splitCommands(String command) {
    // 先按换行符拆分（多行命令的每行可能是独立命令）
    final lines = command.split('\n');
    final results = <String>[];

    for (final line in lines) {
      // 按 && || ; | 拆分
      // 使用正则匹配这些操作符，保留操作符之间的内容
      final parts = line.split(RegExp(r'&&|\|\||;|\|'));
      results.addAll(parts);
    }

    return results;
  }

  /// 移除行内注释（# 之后的内容，但不是 #! 且不在引号内）
  static String _removeComments(String command) {
    // 简化处理：取第一个 # 之前的内容（# 前有空格或行首才算注释）
    final hashIdx = command.indexOf(' #');
    if (hashIdx >= 0) {
      return command.substring(0, hashIdx);
    }
    if (command.startsWith('#')) return '';
    return command;
  }

  /// 比较安全等级：blocked > warn > info > safe
  static int _compareLevel(SafetyLevel a, SafetyLevel b) {
    const order = [SafetyLevel.safe, SafetyLevel.info, SafetyLevel.warn, SafetyLevel.blocked];
    return order.indexOf(a) - order.indexOf(b);
  }

  /// 获取提示文案
  static String getTip(SafetyLevel level) {
    switch (level) {
      case SafetyLevel.safe:
        return '安全命令';
      case SafetyLevel.info:
        return '此操作涉及系统配置或网络下载，请确认操作';
      case SafetyLevel.warn:
        return '危险操作，请仔细确认后再执行';
      case SafetyLevel.blocked:
        return '高危操作，已被安全策略拦截';
    }
  }

  /// 是否需要二次确认
  static bool requireConfirm(SafetyLevel level) {
    return level == SafetyLevel.warn || level == SafetyLevel.blocked;
  }
}
