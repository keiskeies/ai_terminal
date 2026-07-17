import 'dart:io' show Platform;

/// 命令安全等级
enum SafetyLevel {
  safe,    // 安全（只读命令）
  info,    // 仅提示（低风险修改）
  warn,    // 需二次确认（高风险修改）
  blocked, // 直接拦截（不可逆操作）
}

/// 路径安全检查结果
class PathSafetyResult {
  final SafetyLevel level;
  final String? reason;

  const PathSafetyResult(this.level, this.reason);

  bool get isAllowed => level == SafetyLevel.safe || level == SafetyLevel.info;
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
    _SafetyRule(RegExp(r'^rm\s+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)\s+/\s*$'), '递归删除根目录，将清空整个文件系统，完全不可恢复'),
    _SafetyRule(RegExp(r'^rm\s+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)\s+\/\*?\s*$'), '递归删除根目录下所有内容，将清空整个文件系统，完全不可恢复'),
    _SafetyRule(RegExp(r'^dd\s+if=.*of=/dev/'), '直接写入块设备，将覆盖目标磁盘所有数据，不可恢复'),
    _SafetyRule(RegExp(r'^:\(\)\{\s*:\|\:&\s*\};:', caseSensitive: false), 'Fork 炸弹，将瞬间耗尽系统进程资源导致系统崩溃'),
    _SafetyRule(RegExp(r'chmod\s+-R\s+777\s+/'), '递归修改根目录权限为 777，将破坏所有文件权限，系统将无法正常运行'),
    _SafetyRule(RegExp(r'^init\s+0\s*$'), '立即关机，所有未保存数据将丢失'),
    _SafetyRule(RegExp(r'^shutdown\s+-h\s+now'), '立即关机，所有未保存数据将丢失'),
    _SafetyRule(RegExp(r'^rm\s+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)\s+/etc/'), '删除 /etc 配置目录，系统将无法启动和运行'),
    _SafetyRule(RegExp(r'^rm\s+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)\s+/boot/'), '删除 /boot 启动目录，系统将无法启动'),
    _SafetyRule(RegExp(r'^rm\s+(-[a-z]*r[a-z]*f*|-[a-z]*f[a-z]*r*)\s+~'), '递归删除用户主目录，所有用户数据将丢失'),
    _SafetyRule(RegExp(r'^mkfs\.'), '格式化磁盘，目标分区所有数据将被擦除，不可恢复'),
    _SafetyRule(RegExp(r'^>\s*/etc/'), '清空系统配置文件，相关服务将无法运行'),
    // 新增：常见高危操作
    _SafetyRule(RegExp(r'^crontab\s+-r\b'), '清空当前用户的所有定时任务，所有 cron 作业将丢失且不可恢复'),
    _SafetyRule(RegExp(r'^systemctl\s+mask\s+'), '屏蔽系统服务，被 mask 的服务将无法启动，需手动 unmask 恢复'),
    _SafetyRule(RegExp(r'iptables\s+.*-P\s+(INPUT|OUTPUT|FORWARD)\s+DROP'), '设置防火墙默认策略为 DROP，将立即断开所有网络连接，可能导致远程无法访问'),
    _SafetyRule(RegExp(r'echo\s+c\s*>\s*/proc/sysrq-trigger'), '触发 SysRq 崩溃，将导致系统立即崩溃重启'),
    _SafetyRule(RegExp(r'^pkill\s+-9\b'), '强制杀死所有匹配进程，可能导致数据损坏或服务异常'),
    _SafetyRule(RegExp(r'^killall\s+-9\b'), '强制杀死所有同名进程，可能导致数据损坏或服务异常'),
    _SafetyRule(RegExp(r'^kill\s+-9\s+-1\b'), '杀死所有用户进程（kill -9 -1），将终止除 init 外的所有进程'),
    _SafetyRule(RegExp(r'^>\s*/dev/sda'), '清空磁盘设备数据，将破坏磁盘分区表和所有数据'),
    _SafetyRule(RegExp(r'^swapoff\s+-a\b'), '关闭所有交换分区，内存不足时系统将直接 OOM 杀进程'),
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
    // 先对完整命令做一次检查（处理 fork 炸弹等本身含 | ; 字符的单条命令，
    // 这类命令会被 _splitCommands 拆分导致无法匹配整体模式）
    final fullLevel = _checkSingle(command);
    if (fullLevel == SafetyLevel.blocked) return fullLevel;

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
    // 命令规范化：防止通过空格变化、引号包裹等绕过安全检查
    final normalized = _normalizeCommand(command);
    for (final rule in _blockRules) {
      if (rule.pattern.hasMatch(normalized)) {
        return SafetyLevel.blocked;
      }
    }
    for (final rule in _warnRules) {
      if (rule.pattern.hasMatch(normalized)) {
        return SafetyLevel.warn;
      }
    }
    for (final pattern in _infoPatterns) {
      if (pattern.hasMatch(normalized)) {
        return SafetyLevel.info;
      }
    }
    return SafetyLevel.safe;
  }

  /// 命令规范化：去除常见绕过手法
  /// - 合并多余空格
  /// - 去除命令名周围的引号（如 "rm" → rm）
  /// - 去除反斜杠转义（如 r\m → rm）
  static String _normalizeCommand(String command) {
    var cmd = command.trim();
    // 去除命令名周围的引号：匹配开头的 "xxx" 或 'xxx" 并去除引号
    // 注意：replaceFirst 不支持 $1 反向引用，必须用 replaceFirstMapped
    cmd = cmd.replaceFirstMapped(
      RegExp(r'''^["\']([a-zA-Z_][\w.-]*)["\']'''),
      (m) => m.group(1)!,
    );
    // 去除反斜杠转义：r\m → rm（仅命令名部分）
    cmd = cmd.replaceFirstMapped(
      RegExp(r'^([a-zA-Z])(\\)([a-zA-Z])'),
      (m) => '${m.group(1)}${m.group(3)}',
    );
    // 合并多余空格
    cmd = cmd.replaceAll(RegExp(r'\s{2,}'), ' ');
    return cmd;
  }

  /// 获取命令的风险说明（人类可读的具体原因）
  /// 返回命中的第一条规则的说明；未命中返回 null
  static String? getReason(String command) {
    if (_reasonCache.containsKey(command)) {
      return _reasonCache[command];
    }
    String? reason;

    // 先对完整命令做一次检查（处理 fork 炸弹等本身含 | ; 字符的单条命令）
    final fullNormalized = _normalizeCommand(command);
    for (final rule in _blockRules) {
      if (rule.pattern.hasMatch(fullNormalized)) {
        reason = rule.reason;
        break;
      }
    }
    if (reason == null) {
      for (final rule in _warnRules) {
        if (rule.pattern.hasMatch(fullNormalized)) {
          reason = rule.reason;
          break;
        }
      }
    }

    // 如果完整命令未命中，再逐条检查拆分后的子命令
    if (reason == null) {
      final subCommands = _splitCommands(command);
      for (final sub in subCommands) {
        final cleaned = _removeComments(sub).trim();
        if (cleaned.isEmpty) continue;
        final normalized = _normalizeCommand(cleaned);
        // 先查 block 规则
        for (final rule in _blockRules) {
          if (rule.pattern.hasMatch(normalized)) {
            reason = rule.reason;
            break;
          }
        }
        if (reason != null) break;
        // 再查 warn 规则
        for (final rule in _warnRules) {
          if (rule.pattern.hasMatch(normalized)) {
            reason = rule.reason;
            break;
          }
        }
        if (reason != null) break;
      }
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
    // 简化处理：扫描 # 之前的内容，跳过引号内的 #
    final chars = command.codeUnits;
    bool inSingle = false;
    bool inDouble = false;
    for (int i = 0; i < chars.length; i++) {
      final c = chars[i];
      if (c == 0x27 && !inDouble) {
        inSingle = !inSingle;  // '
      } else if (c == 0x22 && !inSingle) {
        inDouble = !inDouble;  // "
      } else if (c == 0x23 && !inSingle && !inDouble) {  // #
        // # 前需有空格或位于行首才算注释
        if (i == 0 || chars[i - 1] == 0x20) {
          return command.substring(0, i);
        }
      }
    }
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

  // ════════════════════════════════════════════════════════════════
  // 路径安全检查（用于本地项目分析/构建/打包工具）
  // ════════════════════════════════════════════════════════════════

  /// 全局路径黑名单（绝对路径前缀，永远禁止访问）
  /// 用于防止 AI 读取 SSH 私钥、系统配置、root 目录等敏感位置
  static const List<String> _blockedPathPrefixes = [
    '/etc',
    '/root',
    '/var/log',
    '/proc',
    '/sys',
    '/dev',
    '/boot',
    '/srv',
    '/run',
    '/usr/local/etc',
  ];

  /// 敏感文件名模式（黑名单，永远禁止读取）
  static final List<RegExp> _blockedFilePatterns = [
    RegExp(r'^id_rsa$'),
    RegExp(r'^id_rsa\.pub$'),
    RegExp(r'^id_ed25519$'),
    RegExp(r'^id_ed25519\.pub$'),
    RegExp(r'^id_ecdsa$'),
    RegExp(r'^id_dsa$'),
    RegExp(r'^\.pem$'),
    RegExp(r'\.key$'),
    RegExp(r'^credentials(\.json|\.yaml|\.yml)?$'),
    RegExp(r'^\.env\.production$'),
    RegExp(r'^\.env\.prod$'),
    RegExp(r'^\.env\.local$'),
    RegExp(r'^shadow$'),
    RegExp(r'^passwd$'),
    RegExp(r'^\.netrc$'),
    RegExp(r'^\.htpasswd$'),
  ];

  /// 敏感目录名（路径分段匹配，黑名单）
  static const List<String> _blockedDirNames = [
    '.ssh',
    '.gnupg',
    '.aws',
    '.docker',
    '.kube',
  ];

  /// 用户主目录下的敏感路径（运行时拼接 $HOME）
  static const List<String> _homeBlockedSuffixes = [
    '.ssh',
    '.gnupg',
    '.aws',
    '.docker',
    '.kube',
    '.config/google-chrome',
    '.config/Code',
    '.password-store',
  ];

  /// 检查路径安全性
  ///
  /// [path] 待检查的路径（绝对路径）
  /// [projectRoot] 可选：用户授权的项目根目录，在项目内视为安全
  /// [isWrite] 是否为写操作（写操作更严格）
  ///
  /// 返回 PathSafetyResult，包含等级和说明
  static PathSafetyResult checkPath(String path, {String? projectRoot, bool isWrite = false}) {
    if (path.isEmpty) {
      return const PathSafetyResult(SafetyLevel.warn, '路径为空');
    }

    // 规范化路径（去尾斜杠、合并重复斜杠）
    final normalized = _normalizePath(path);
    if (normalized.isEmpty) {
      return const PathSafetyResult(SafetyLevel.warn, '路径规范化后为空');
    }

    // 1. 检查是否在项目根目录内（最高优先级白名单）
    if (projectRoot != null && projectRoot.isNotEmpty) {
      final root = _normalizePath(projectRoot);
      if (_isPathWithin(normalized, root)) {
        // 项目内：检查是否命中文件名/目录黑名单
        final fileName = normalized.split('/').last;
        for (final pattern in _blockedFilePatterns) {
          if (pattern.hasMatch(fileName)) {
            return PathSafetyResult(SafetyLevel.blocked, '敏感文件: $fileName（即使项目内也禁止访问）');
          }
        }
        // 检查路径分段是否含敏感目录名
        for (final segment in normalized.split('/')) {
          if (_blockedDirNames.contains(segment)) {
            return PathSafetyResult(SafetyLevel.blocked, '敏感目录: $segment（禁止访问）');
          }
        }
        return const PathSafetyResult(SafetyLevel.safe, null);
      }
    }

    // 2. 检查全局路径黑名单前缀
    for (final prefix in _blockedPathPrefixes) {
      if (normalized == prefix || normalized.startsWith('$prefix/')) {
        return PathSafetyResult(SafetyLevel.blocked, '系统目录 $prefix 禁止访问');
      }
    }

    // 3. 检查用户主目录下的敏感路径
    final home = _getHomeDir();
    if (home != null) {
      for (final suffix in _homeBlockedSuffixes) {
        final sensitivePath = '$home/$suffix';
        if (normalized == sensitivePath || normalized.startsWith('$sensitivePath/')) {
          return PathSafetyResult(SafetyLevel.blocked, '敏感目录 ~/$suffix 禁止访问');
        }
      }
      // 直接读 ~/.ssh/id_rsa 这种情况已被上面覆盖
    }

    // 4. 检查文件名黑名单（项目外也要查）
    final fileName = normalized.split('/').last;
    for (final pattern in _blockedFilePatterns) {
      if (pattern.hasMatch(fileName)) {
        return PathSafetyResult(SafetyLevel.blocked, '敏感文件: $fileName');
      }
    }

    // 5. 检查路径分段中的敏感目录
    for (final segment in normalized.split('/')) {
      if (_blockedDirNames.contains(segment)) {
        return PathSafetyResult(SafetyLevel.blocked, '敏感目录: $segment 禁止访问');
      }
    }

    // 6. 项目外的路径需确认（防止 AI 乱跑）
    return PathSafetyResult(
      SafetyLevel.warn,
      '路径不在授权的项目目录内: $normalized',
    );
  }

  /// 路径规范化：合并重复斜杠、去尾斜杠、解析 . 和 ..
  static String _normalizePath(String path) {
    var p = path.replaceAll(RegExp(r'\\'), '/'); // Windows 路径转 POSIX
    p = p.replaceAll(RegExp(r'/+'), '/'); // 合并重复斜杠
    // 简单解析 . 和 ..
    final segments = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(seg);
    }
    final result = segments.join('/');
    return path.startsWith('/') ? '/$result' : result;
  }

  /// 判断 path 是否在 root 目录内（规范化后的路径）
  static bool _isPathWithin(String path, String root) {
    if (path == root) return true;
    return path.startsWith('$root/');
  }

  /// 获取用户主目录（用于检查 ~/.ssh 等）
  static String? _getHomeDir() {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return home != null ? _normalizePath(home) : null;
  }

  /// 检查路径是否允许读取（综合判断，给工具层用）
  /// [path] 待读取路径
  /// [projectRoot] 项目根目录
  /// [sourceCodeGranted] 是否已获得源码读取授权（会话级）
  static PathSafetyResult checkReadPath(String path, {
    String? projectRoot,
    bool sourceCodeGranted = false,
  }) {
    final result = checkPath(path, projectRoot: projectRoot, isWrite: false);
    // blocked 永远不允许
    if (result.level == SafetyLevel.blocked) return result;
    // safe 直接放行
    if (result.level == SafetyLevel.safe) return result;
    // warn：若已授权则放行，否则需确认
    if (sourceCodeGranted) {
      return const PathSafetyResult(SafetyLevel.safe, null);
    }
    return result;
  }
}
