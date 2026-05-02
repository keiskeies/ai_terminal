/// 命令安全等级
enum SafetyLevel {
  safe,    // 安全（只读命令）
  info,    // 仅提示（低风险修改）
  warn,    // 需二次确认（高风险修改）
  blocked, // 直接拦截（不可逆操作）
}

class SafetyGuard {
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
    // 安装/升级/替换软件包（可能改变系统状态）
    RegExp(r'^sudo\s+(apt|apt-get)\s+(install|upgrade|dist-upgrade|remove|purge)\s+'),
    RegExp(r'^sudo\s+yum\s+(install|update|remove|erase)\s+'),
    RegExp(r'^sudo\s+dnf\s+(install|upgrade|remove)\s+'),
    RegExp(r'^sudo\s+apk\s+add\s+'),
    RegExp(r'^sudo\s+pacman\s+-S\s+'),
    RegExp(r'^sudo\s+snap\s+install\s+'),
    // 修改环境配置
    RegExp(r'(>>|>)\s*(/etc/profile|/etc/environment|/etc/bashrc|~/\.bashrc|~/\.zshrc|~/\.bash_profile|~/\.profile)\s*$'),
    RegExp(r'^sudo\s+(tee|sed|echo.*>)\s+.*(/etc/profile|/etc/environment|/etc/bashrc)\s*$'),
    // alternatives/update-alternatives 切换默认版本
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

  // 仅高亮提示的命令模式（低风险修改或网络操作）
  static final List<RegExp> _infoPatterns = [
    RegExp(r'curl\s+http'),
    RegExp(r'wget\s+http'),
    RegExp(r'git\s+clone'),
    RegExp(r'^(firewall-cmd|ufw|iptables).*port'),
    RegExp(r'^systemctl\s+(start|restart|reload)\s+'),
    RegExp(r'^service\s+\w+\s+(start|restart|reload)'),
    // 非sudo的安装（用户空间）
    RegExp(r'^npm\s+install\s+-g'),
    RegExp(r'^pip\s+install\s+'),
    RegExp(r'^brew\s+install\s+'),
    // update 软件源索引（不安装）
    RegExp(r'^sudo\s+(apt|apt-get)\s+update\s*$'),
    RegExp(r'^sudo\s+yum\s+makecache'),
    // 查看类 update-alternatives（仅列表）
    RegExp(r'^update-alternatives\s+--(list|display)\s+'),
    // 低风险环境变量 export（当前会话）
    RegExp(r'^export\s+'),
  ];

  /// 检查命令安全等级
  static SafetyLevel check(String command) {
    final cleaned = _cleanCommand(command);

    if (cleaned.isEmpty) return SafetyLevel.safe;

    // 先检查 block 模式
    for (final pattern in _blockPatterns) {
      if (pattern.hasMatch(cleaned)) {
        return SafetyLevel.blocked;
      }
    }

    // 再检查 warn 模式
    for (final pattern in _warnPatterns) {
      if (pattern.hasMatch(cleaned)) {
        return SafetyLevel.warn;
      }
    }

    // 检查 info 模式
    for (final pattern in _infoPatterns) {
      if (pattern.hasMatch(cleaned)) {
        return SafetyLevel.info;
      }
    }

    return SafetyLevel.safe;
  }

  /// 清理命令：移除注释和管道符后的部分
  static String _cleanCommand(String command) {
    // 移除 # 注释
    var cleaned = command.split('#').first.trim();
    // 移除管道符后的部分
    cleaned = cleaned.split('|').first.trim();
    // 移除 && || 后的部分
    cleaned = cleaned.split(RegExp(r'&&|\|\|')).first.trim();
    return cleaned;
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
