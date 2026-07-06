/// 命令安全等级
enum SafetyLevel {
  safe,    // 安全（只读命令）
  info,    // 仅提示（低风险修改）
  warn,    // 需二次确认（高风险修改）
  blocked, // 直接拦截（不可逆操作）
}

/// 安全规则：正则模式 + 人类可读的风险说明
class _SafetyRule {
  final RegExp pattern;
  final String reason;
  const _SafetyRule(this.pattern, this.reason);
}

class SafetyGuard {
  /// 静态缓存，避免对同一条命令重复正则匹配
  static final Map<String, SafetyLevel> _cache = {};
  /// 缓存命中的风险说明（含 null，表示已查过但未命中），避免重复匹配
  static final Map<String, String?> _reasonCache = {};

  // 直接拦截的命令模式（不可逆操作）
  static final List<_SafetyRule> _blockRules = [
    _SafetyRule(RegExp(r'^rm\s+-rf\s+/\s*$'), '递归删除根目录，将清空整个文件系统，完全不可恢复'),
    _SafetyRule(RegExp(r'^rm\s+-rf\s+\/\*?\s*$'), '递归删除根目录下所有内容，将清空整个文件系统，完全不可恢复'),
    _SafetyRule(RegExp(r'^dd\s+if=.*of=/dev/'), '直接写入块设备，将覆盖目标磁盘所有数据，不可恢复'),
    _SafetyRule(RegExp(r'^:\(\)\{\s*:\|\:&\s*\};:', caseSensitive: false), 'Fork 炸弹，将瞬间耗尽系统进程资源导致系统崩溃'),
    _SafetyRule(RegExp(r'chmod\s+-R\s+777\s+/'), '递归修改根目录权限为 777，将破坏所有文件权限，系统将无法正常运行'),
    _SafetyRule(RegExp(r'^init\s+0\s*$'), '立即关机，所有未保存数据将丢失'),
    _SafetyRule(RegExp(r'^shutdown\s+-h\s+now'), '立即关机，所有未保存数据将丢失'),
    _SafetyRule(RegExp(r'^rm\s+-rf\s+/etc/'), '删除 /etc 配置目录，系统将无法启动和运行'),
    _SafetyRule(RegExp(r'^rm\s+-rf\s+/boot/'), '删除 /boot 启动目录，系统将无法启动'),
    _SafetyRule(RegExp(r'^rm\s+-rf\s+~'), '递归删除用户主目录，所有用户数据将丢失'),
    _SafetyRule(RegExp(r'^mkfs\.'), '格式化磁盘，目标分区所有数据将被擦除，不可恢复'),
    _SafetyRule(RegExp(r'^>\s*/etc/'), '清空系统配置文件，相关服务将无法运行'),
  ];

  // 需二次确认的命令模式（高风险修改操作）
  static final List<_SafetyRule> _warnRules = [
    // 系统级操作
    _SafetyRule(RegExp(r'^sudo\s+(reboot|shutdown|halt|poweroff|init\s+)'), '关机/重启服务器，所有运行中的进程将终止，未保存数据丢失'),
    _SafetyRule(RegExp(r'^systemctl\s+(stop|disable)\s+ssh'), '停止/禁用 SSH 服务，将断开所有远程连接，可能导致无法再次远程登录'),
    _SafetyRule(RegExp(r'^(iptables|firewall-cmd|ufw).*(-F|--flush|--delete-chain)'), '清空防火墙规则，将影响网络安全策略'),
    _SafetyRule(RegExp(r'^fdisk\s+/'), '分区操作，错误的分区表修改可能导致磁盘数据丢失'),
    _SafetyRule(RegExp(r'^mkfs\.(ext4|xfs|btrfs)\s+/dev/'), '格式化分区为文件系统，目标分区所有数据将被擦除'),
    _SafetyRule(RegExp(r'^dd\s+if=.*of=/dev/'), '直接写入块设备，将覆盖目标磁盘数据'),
    _SafetyRule(RegExp(r'^rm\s+-rf\s+/'), '递归删除系统目录，可能影响系统运行，不可恢复'),
    // 安装/升级/替换软件包
    _SafetyRule(RegExp(r'^sudo\s+(apt|apt-get)\s+(install|upgrade|dist-upgrade|remove|purge)\s+'), '安装/升级/卸载软件包，可能改变系统依赖关系，影响其他服务'),
    _SafetyRule(RegExp(r'^sudo\s+yum\s+(install|update|remove|erase)\s+'), '安装/更新/卸载软件包，可能改变系统依赖关系'),
    _SafetyRule(RegExp(r'^sudo\s+dnf\s+(install|upgrade|remove)\s+'), '安装/升级/卸载软件包，可能改变系统依赖关系'),
    _SafetyRule(RegExp(r'^sudo\s+apk\s+add\s+'), '安装软件包，可能改变系统配置'),
    _SafetyRule(RegExp(r'^sudo\s+pacman\s+-S\s+'), '安装软件包，可能改变系统依赖关系'),
    _SafetyRule(RegExp(r'^sudo\s+snap\s+install\s+'), '安装 Snap 软件包'),
    // 修改环境配置
    _SafetyRule(RegExp(r'(>>|>)\s*(/etc/profile|/etc/environment|/etc/bashrc|~/\.bashrc|~/\.zshrc|~/\.bash_profile|~/\.profile)\s*$'), '修改 Shell 环境配置文件，可能影响所有用户的登录环境'),
    _SafetyRule(RegExp(r'^sudo\s+(tee|sed|echo.*>)\s+.*(/etc/profile|/etc/environment|/etc/bashrc)\s*$'), '修改系统级环境配置文件，可能影响所有用户'),
    // alternatives/update-alternatives
    _SafetyRule(RegExp(r'^sudo\s+update-alternatives\s+--set\s+'), '修改系统默认程序指向，影响相关命令的默认版本'),
    _SafetyRule(RegExp(r'^sudo\s+alternatives\s+--set\s+'), '修改系统默认程序指向'),
    // 卸载操作
    _SafetyRule(RegExp(r'^sudo\s+(apt|apt-get)\s+(remove|purge|autoremove)\s+'), '卸载软件包，依赖该包的其他服务可能无法运行；purge 会同时删除配置文件'),
    _SafetyRule(RegExp(r'^sudo\s+yum\s+remove\s+'), '卸载软件包，依赖该包的其他服务可能无法运行'),
    _SafetyRule(RegExp(r'^sudo\s+dnf\s+remove\s+'), '卸载软件包，依赖该包的其他服务可能无法运行'),
    _SafetyRule(RegExp(r'^sudo\s+pacman\s+-R\s+'), '卸载软件包，依赖该包的其他服务可能无法运行'),
    // 源码编译安装
    _SafetyRule(RegExp(r'^sudo\s+make\s+install'), '源码编译安装到系统目录，可能覆盖系统已有的同名程序'),
    // 覆盖写入系统文件
    _SafetyRule(RegExp(r'^sudo\s+cp\s+.*\s+/etc/'), '复制文件到系统配置目录，可能覆盖现有配置'),
    _SafetyRule(RegExp(r'^sudo\s+mv\s+.*\s+/etc/'), '移动文件到系统配置目录，可能覆盖现有配置'),
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

  /// 内部检查逻辑：对完整命令的所有子命令分别检查，取最高危险等级
  static SafetyLevel _checkInternal(String command) {
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
    for (final rule in _blockRules) {
      if (rule.pattern.hasMatch(command)) {
        return SafetyLevel.blocked;
      }
    }
    for (final rule in _warnRules) {
      if (rule.pattern.hasMatch(command)) {
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

  /// 获取命令的风险说明（人类可读的具体原因）
  /// 返回命中的第一条规则的说明；未命中返回 null
  static String? getReason(String command) {
    if (_reasonCache.containsKey(command)) {
      return _reasonCache[command];
    }
    String? reason;
    final subCommands = _splitCommands(command);
    for (final sub in subCommands) {
      final cleaned = _removeComments(sub).trim();
      if (cleaned.isEmpty) continue;
      // 先查 block 规则
      for (final rule in _blockRules) {
        if (rule.pattern.hasMatch(cleaned)) {
          reason = rule.reason;
          break;
        }
      }
      if (reason != null) break;
      // 再查 warn 规则
      for (final rule in _warnRules) {
        if (rule.pattern.hasMatch(cleaned)) {
          reason = rule.reason;
          break;
        }
      }
      if (reason != null) break;
    }
    _reasonCache[command] = reason;
    if (_reasonCache.length > 500) {
      _reasonCache.remove(_reasonCache.keys.first);
    }
    return reason;
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

  /// 获取提示文案（简短，用于状态标签）
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
