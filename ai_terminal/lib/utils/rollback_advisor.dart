// 纯 Dart 工具类，无 Flutter 依赖

/// 修改目标类型
enum ModifyTargetType {
  /// 配置文件（如 nginx.conf）
  configFile,
  /// 系统服务（如 nginx/mysql）
  service,
  /// 包安装（如 apt install）
  package,
  /// 用户/权限（如 useradd/chmod）
  permission,
  /// 普通文件写入（如 echo > file）
  fileWrite,
  /// 无法识别的修改
  unknown,
}

/// 修改目标信息
class ModifyTarget {
  final ModifyTargetType type;
  /// 目标名称（文件路径 / 服务名 / 包名）
  final String name;
  /// 原始命令
  final String command;

  const ModifyTarget({
    required this.type,
    required this.name,
    required this.command,
  });

  @override
  String toString() => 'ModifyTarget(type=$type, name=$name)';
}

/// 快照结果 — 修改前的状态记录
class PreSnapshot {
  final ModifyTarget target;
  /// 快照命令（用于执行并收集输出）
  final String snapshotCommand;
  /// 快照输出（修改前状态）
  final String? snapshotOutput;
  /// 回滚建议命令（失败时供 AI 参考）
  final String? rollbackSuggestion;

  const PreSnapshot({
    required this.target,
    required this.snapshotCommand,
    this.snapshotOutput,
    this.rollbackSuggestion,
  });
}

/// 失败回滚顾问 — 在修改类命令执行前做快照，失败时生成回滚建议
///
/// 设计原则：
/// - 不改 CommandExecutor 接口（底层稳定）
/// - 完全在 agent_engine 层用"预跑只读命令"实现快照
/// - 失败时把快照信息注入观测，AI 自然会看到并建议回滚
/// - 不自动执行回滚（R5：危险动作需人工确认）
class RollbackAdvisor {
  /// 分析命令，识别是否为修改类操作及其目标
  /// 返回 null 表示非修改类命令，不需要快照
  static ModifyTarget? analyze(String command) {
    final cmd = command.trim();
    final cmdLower = cmd.toLowerCase();

    // 跳过纯查询命令
    if (_isQueryCommand(cmdLower)) return null;

    // 1. 配置文件修改：sed -i / cp / mv / rm / tee / cat > / echo > / write
    final configFileMatch = _detectConfigFileModify(cmd, cmdLower);
    if (configFileMatch != null) return configFileMatch;

    // 2. 服务管理：systemctl restart/stop/start/disable
    final serviceMatch = _detectServiceModify(cmdLower);
    if (serviceMatch != null) return serviceMatch;

    // 3. 包安装：apt install / yum install / pip install / npm install
    final packageMatch = _detectPackageModify(cmdLower);
    if (packageMatch != null) return packageMatch;

    // 4. 用户/权限：useradd / chmod / chown
    final permMatch = _detectPermissionModify(cmdLower);
    if (permMatch != null) return permMatch;

    return null;
  }

  /// 为修改目标生成快照命令（修改前执行，收集当前状态）
  /// 注意：快照命令必须是只读的，不能有副作用（不创建备份文件、不修改系统）
  /// 回滚建议由 AI 基于快照信息生成，如需备份应由 AI 显式执行
  static String? buildSnapshotCommand(ModifyTarget target) {
    switch (target.type) {
      case ModifyTargetType.configFile:
        final path = target.name;
        return 'echo "=== 修改前快照 ===" && '
            'ls -la "$path" 2>/dev/null && '
            'echo "--- 内容前5行 ---" && '
            'head -5 "$path" 2>/dev/null && '
            'echo "--- 行数/大小 ---" && '
            'wc -lc "$path" 2>/dev/null || echo "文件不存在或无法读取"';
      case ModifyTargetType.service:
        // update-alternatives 快照
        if (target.command.contains('update-alternatives')) {
          return 'update-alternatives --display ${target.name} 2>/dev/null | head -10 || '
              'echo "alternatives 状态未知"';
        }
        return 'systemctl status ${target.name} 2>/dev/null | head -10 || '
            'service ${target.name} status 2>/dev/null | head -10 || '
            'echo "服务状态未知"';
      case ModifyTargetType.package:
        final pkg = target.name;
        return 'dpkg -l "$pkg" 2>/dev/null | tail -1 || '
            'rpm -q "$pkg" 2>/dev/null || '
            'echo "包 $pkg 当前未安装"';
      case ModifyTargetType.permission:
        return 'ls -la "${target.name}" 2>/dev/null || echo "目标不存在"';
      case ModifyTargetType.fileWrite:
        return 'ls -la "${target.name}" 2>/dev/null && '
            'wc -l "${target.name}" 2>/dev/null || echo "文件不存在"';
      case ModifyTargetType.unknown:
        return null;
    }
  }

  /// 根据快照输出和失败命令，生成回滚建议
  static String? buildRollbackSuggestion(ModifyTarget target, String? snapshotOutput) {
    switch (target.type) {
      case ModifyTargetType.configFile:
        // crontab 特殊处理
        if (target.name == 'crontab') {
          return '回滚建议: crontab 已被修改。如需恢复，参考快照中的原 crontab 内容，'
              '用 crontab < backup_file 恢复';
        }
        return '回滚建议: ${target.name} 修改前快照见上方输出。'
            '若需恢复，请从版本控制(git)、包管理器重装或同环境节点拷贝原文件';
      case ModifyTargetType.service:
        // update-alternatives 特殊回滚
        if (target.command.contains('update-alternatives --set')) {
          return '回滚建议: sudo update-alternatives --auto ${target.name} '
              '(恢复自动模式，或用 --set 指向原版本)';
        }
        // systemctl enable/disable 特殊回滚
        if (target.command.contains('systemctl enable ')) {
          return '回滚建议: sudo systemctl disable ${target.name} (撤销 enable)';
        }
        if (target.command.contains('systemctl disable ')) {
          return '回滚建议: sudo systemctl enable ${target.name} (撤销 disable)';
        }
        return '回滚建议: 参考快照中的修改前状态，'
            'sudo systemctl start ${target.name} (如原为运行) 或 stop (如原为停止)';
      case ModifyTargetType.package:
        return '回滚建议: sudo apt remove ${target.name} 或 sudo yum remove ${target.name}  '
            '(回滚安装操作)';
      case ModifyTargetType.permission:
        // 解析原权限并生成具体回滚命令
        final cmd = target.command;
        final chmodMatch = RegExp(r'chmod\s+(\S+)\s+(.+)').firstMatch(cmd);
        if (chmodMatch != null) {
          return '回滚建议: 参考快照中的原权限，用以下命令恢复: '
              'chmod <原权限> ${chmodMatch.group(2)} (原权限见 ls -la 输出)';
        }
        final chownMatch = RegExp(r'chown\s+(\S+)\s+(.+)').firstMatch(cmd);
        if (chownMatch != null) {
          return '回滚建议: 参考快照中的原属主，用以下命令恢复: '
              'chown <原属主:原组> ${chownMatch.group(2)} (原属主见 ls -la 输出)';
        }
        if (cmd.contains('useradd')) {
          final userMatch = RegExp(r'useradd\s+(?:.*?\s+)?(\S+)\s*$').firstMatch(cmd);
          final user = userMatch?.group(1) ?? '新用户';
          return '回滚建议: sudo userdel -r $user (删除刚创建的用户及家目录)';
        }
        return '回滚建议: 参考快照中的原权限(ls -la 输出)，用 chmod/chown 恢复';
      case ModifyTargetType.fileWrite:
        // mv 命令可以生成具体的回滚命令
        final mvMatch = RegExp(r'^mv\s+(\S+)\s+(\S+)').firstMatch(target.command);
        if (mvMatch != null) {
          final src = mvMatch.group(1)!;
          final dst = mvMatch.group(2)!;
          return '回滚建议: mv $dst $src (将文件移回原位置)';
        }
        // ln -s 可以生成具体的回滚命令（兼容 -sf / -snf 等 flag 变体）
        final lnMatch = RegExp(r'^ln\s+-\w*s\w*\s+\S+\s+(\S+)').firstMatch(target.command);
        if (lnMatch != null) {
          final linkPath = lnMatch.group(1)!;
          return '回滚建议: rm $linkPath (删除刚创建的符号链接)';
        }
        return '回滚建议: 参考快照中的原文件信息，从备份或版本控制恢复 ${target.name}';
      case ModifyTargetType.unknown:
        return null;
    }
  }

  // ═══════════════════════════════════════════════════════
  // 私有：识别各种修改类命令
  // ═══════════════════════════════════════════════════════

  static bool _isQueryCommand(String cmdLower) {
    // 复用 command_heuristics 的逻辑（这里简化，避免循环依赖）
    final queryPrefixes = [
      'grep', 'find', 'cat', 'head', 'tail', 'ls', 'stat', 'diff',
      'ps', 'top', 'systemctl status', 'docker ps', 'kubectl get',
      'ping', 'curl', 'wget', 'uname', 'whoami', 'pwd',
    ];
    return queryPrefixes.any((prefix) => cmdLower.startsWith(prefix));
  }

  static ModifyTarget? _detectConfigFileModify(String cmd, String cmdLower) {
    // sed -i
    final sedMatch = RegExp(r'sed\s+-i.*?\s+(\S+)$').firstMatch(cmd);
    if (sedMatch != null) {
      return ModifyTarget(type: ModifyTargetType.configFile, name: sedMatch.group(1)!, command: cmd);
    }
    // cp / mv / rm 涉及配置目录
    if (cmdLower.startsWith('cp ') || cmdLower.startsWith('mv ') || cmdLower.startsWith('rm ')) {
      final configPaths = ['/etc/', '/usr/local/etc/', '/opt/', '/var/www/', 'nginx.conf', '.conf'];
      for (final pathPrefix in configPaths) {
        if (cmd.contains(pathPrefix)) {
          // 提取最后一个路径参数
          final parts = cmd.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            return ModifyTarget(type: ModifyTargetType.configFile, name: parts.last, command: cmd);
          }
        }
      }
    }
    // mv 命令（任何位置）— 记录源和目标用于回滚
    // 跳过明显的备份操作（目标以 .bak/.old/.backup/.orig 结尾），这类操作风险低
    final mvMatch = RegExp(r'^mv\s+(\S+)\s+(\S+)').firstMatch(cmd);
    if (mvMatch != null) {
      final dst = mvMatch.group(2)!;
      final isBackup = RegExp(r'\.(bak|old|backup|orig)$', caseSensitive: false).hasMatch(dst);
      if (!isBackup) {
        return ModifyTarget(type: ModifyTargetType.fileWrite, name: dst, command: cmd);
      }
    }
    // ln -s 创建符号链接（兼容 -sf / -snf 等 flag 变体）
    final lnMatch = RegExp(r'^ln\s+-\w*s\w*\s+(\S+)\s+(\S+)').firstMatch(cmd);
    if (lnMatch != null) {
      return ModifyTarget(type: ModifyTargetType.fileWrite, name: lnMatch.group(2)!, command: cmd);
    }
    // cat > / echo > / tee 写入文件
    final writeMatch = RegExp(r'(?:cat|echo|tee)\s+>?\\?\s*(\S+)').firstMatch(cmd);
    if (writeMatch != null) {
      final path = writeMatch.group(1)!;
      if (path.startsWith('/') || path.contains('.conf') || path.contains('.sh')) {
        return ModifyTarget(type: ModifyTargetType.fileWrite, name: path, command: cmd);
      }
    }
    // heredoc: cat > file << 'EOF'
    final heredocMatch = RegExp(r"cat\s*>\s*(\S+)\s*<<").firstMatch(cmd);
    if (heredocMatch != null) {
      return ModifyTarget(type: ModifyTargetType.fileWrite, name: heredocMatch.group(1)!, command: cmd);
    }
    // crontab 操作（替换/编辑）
    if (cmdLower.startsWith('crontab ') && !cmdLower.contains('-l')) {
      return ModifyTarget(type: ModifyTargetType.configFile, name: 'crontab', command: cmd);
    }
    return null;
  }

  static ModifyTarget? _detectServiceModify(String cmdLower) {
    final serviceMatch = RegExp(r'systemctl\s+(restart|stop|start|disable|enable)\s+(\S+)').firstMatch(cmdLower);
    if (serviceMatch != null) {
      return ModifyTarget(
        type: ModifyTargetType.service,
        name: serviceMatch.group(2)!,
        command: cmdLower,
      );
    }
    final oldServiceMatch = RegExp(r'service\s+(\S+)\s+(restart|stop|start)').firstMatch(cmdLower);
    if (oldServiceMatch != null) {
      return ModifyTarget(
        type: ModifyTargetType.service,
        name: oldServiceMatch.group(1)!,
        command: cmdLower,
      );
    }
    // update-alternatives --set
    final altMatch = RegExp(r'update-alternatives\s+--set\s+(\S+)').firstMatch(cmdLower);
    if (altMatch != null) {
      return ModifyTarget(
        type: ModifyTargetType.service,
        name: altMatch.group(1)!,
        command: cmdLower,
      );
    }
    return null;
  }

  static ModifyTarget? _detectPackageModify(String cmdLower) {
    final patterns = [
      RegExp(r'apt(?:-get)?\s+install\s+(\S+)'),
      RegExp(r'yum\s+install\s+(\S+)'),
      RegExp(r'dnf\s+install\s+(\S+)'),
      RegExp(r'apk\s+add\s+(\S+)'),
      RegExp(r'pip\s+install\s+(\S+)'),
      RegExp(r'pip3\s+install\s+(\S+)'),
      RegExp(r'npm\s+install\s+(?:-g\s+)?(\S+)'),
      RegExp(r'npm\s+i\s+(?:-g\s+)?(\S+)'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(cmdLower);
      if (m != null) {
        return ModifyTarget(type: ModifyTargetType.package, name: m.group(1)!, command: cmdLower);
      }
    }
    return null;
  }

  static ModifyTarget? _detectPermissionModify(String cmdLower) {
    final chmodMatch = RegExp(r'chmod\s+\S+\s+(\S+)').firstMatch(cmdLower);
    if (chmodMatch != null) {
      return ModifyTarget(type: ModifyTargetType.permission, name: chmodMatch.group(1)!, command: cmdLower);
    }
    final chownMatch = RegExp(r'chown\s+\S+\s+(\S+)').firstMatch(cmdLower);
    if (chownMatch != null) {
      return ModifyTarget(type: ModifyTargetType.permission, name: chownMatch.group(1)!, command: cmdLower);
    }
    if (cmdLower.startsWith('useradd') || cmdLower.startsWith('usermod') || cmdLower.startsWith('userdel')) {
      return ModifyTarget(type: ModifyTargetType.permission, name: 'user', command: cmdLower);
    }
    return null;
  }
}
