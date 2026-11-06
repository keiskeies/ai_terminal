import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../core/safety_guard.dart';
import '../models/change_record.dart';
import 'command_executor.dart';
import 'daos.dart';
import '../utils/audit_logger.dart' show AuditLogger;
import '../utils/tool_args_parser.dart';

/// 变更台账服务 — 记录每次修改性命令，支持查询和回滚
class ChangeRecordService {
  static const _uuid = Uuid();

  static final RegExp _sudoPrefixRegex = RegExp(
      r'^sudo\s+(?:-u\s+\S+\s+)?(?:-[A-Za-z]+\s+)*');
  static final RegExp _sudoAnywhereRegex = RegExp(r'^sudo\s+');
  static final RegExp _installRegex = RegExp(
      r'^(apt|apt-get|yum|dnf|apk|pacman|snap|brew)\s+(install|add|-S)');
  static final RegExp _uninstallRegex = RegExp(
      r'^(apt|apt-get|yum|dnf|apk|pacman)\s+(remove|purge|erase|-R|autoremove)');
  static final RegExp _systemctlStartRegex = RegExp(r'^systemctl\s+start');
  static final RegExp _systemctlStopRegex = RegExp(r'^systemctl\s+stop');
  static final RegExp _systemctlRestartRegex = RegExp(r'^systemctl\s+restart');
  static final RegExp _serviceStartRegex = RegExp(r'^service\s+\w+\s+start');
  static final RegExp _serviceStopRegex = RegExp(r'^service\s+\w+\s+stop');
  static final RegExp _serviceRestartRegex = RegExp(r'^service\s+\w+\s+restart');
  static final RegExp _permissionRegex = RegExp(r'chmod|chown');
  static final RegExp _fileOpRegex =
      RegExp(r'^(cp|mv|rm|mkdir|tee|sed|echo.*>)');
  static final RegExp _redirectRegex = RegExp(r'(>>|>)\s*(/etc/|~/)');
  static final RegExp _installWithPkgRegex = RegExp(
      r'^(apt|apt-get|yum|dnf|apk|pacman|snap|brew)\s+(install|add|-S)\s+(\S+)');
  static final RegExp _systemctlStartWithUnitRegex =
      RegExp(r'^systemctl\s+start\s+(\S+)');
  static final RegExp _serviceStartWithUnitRegex =
      RegExp(r'^service\s+(\w+)\s+start');
  static final RegExp _systemctlStopWithUnitRegex =
      RegExp(r'^systemctl\s+stop\s+(\S+)');
  static final RegExp _serviceStopWithUnitRegex =
      RegExp(r'^service\s+(\w+)\s+stop');

  /// 去除 sudo 前缀，便于统一匹配；保留原始命令用于生成回滚命令
  static String _stripSudo(String command) {
    return command.trim().replaceFirst(_sudoPrefixRegex, '');
  }

  static bool _hasSudo(String command) =>
      _sudoAnywhereRegex.hasMatch(command.trim());

  /// 文件工具没有 shell 命令原文，生成一条稳定的台账描述
  ///
  /// "哪些工具算变更"不再由这里枚举工具名 — 那会导致新增写类工具时
  /// 忘记登记、变更静默不进台账。判断改由 [AgentToolRegistry.isChangeRecordingTool]
  /// 从工具的 [AgentTool.kind] 派生（见 agent_tool.dart）。
  static String describeFileToolChange(String toolName, ToolArgs args) {
    final path = args.getString('path').trim();
    final remote = args.firstOf(const ['remote', 'remoteDir']).trim();
    final local = args.firstOf(const ['local', 'localDir']).trim();
    final targetHost = args.getString('hostId').trim();
    switch (toolName) {
      case 'file_write':
      case 'file_patch':
      case 'local_file_write':
      case 'local_file_patch':
        return path.isEmpty ? toolName : '$toolName $path';
      case 'sftp_upload':
        return 'sftp_upload $local -> $remote';
      case 'sftp_download':
        return 'sftp_download $remote -> $local';
      case 'upload_to':
        return 'upload_to ${targetHost.isEmpty ? '' : '$targetHost:'}$remote';
      case 'file_sync':
        return 'file_sync $local -> $remote';
      case 'local_file_delete':
        return 'local_file_delete $path';
      case 'local_file_move':
        return 'local_file_move $path -> ${args.getString('dst')}';
      default:
        return toolName;
    }
  }

  /// 根据 SafetyGuard 规则推断变更类型
  static ChangeType inferType(String command) {
    final c = _stripSudo(command);
    if (_installRegex.hasMatch(c)) return ChangeType.install;
    if (_uninstallRegex.hasMatch(c)) return ChangeType.uninstall;
    if (_systemctlStartRegex.hasMatch(c)) return ChangeType.startService;
    if (_systemctlStopRegex.hasMatch(c)) return ChangeType.stopService;
    if (_systemctlRestartRegex.hasMatch(c)) return ChangeType.restartService;
    if (_serviceStartRegex.hasMatch(c)) return ChangeType.startService;
    if (_serviceStopRegex.hasMatch(c)) return ChangeType.stopService;
    if (_serviceRestartRegex.hasMatch(c)) return ChangeType.restartService;
    if (_permissionRegex.hasMatch(c)) return ChangeType.permission;
    if (_fileOpRegex.hasMatch(c) || _redirectRegex.hasMatch(c)) {
      return ChangeType.fileOperation;
    }
    return ChangeType.other;
  }

  /// 生成回滚命令（基于命令类型）
  static String? buildRollbackCommand(String command, ChangeType type) {
    final c = _stripSudo(command);
    final prefix = _hasSudo(command) ? 'sudo ' : '';
    switch (type) {
      case ChangeType.install:
        // apt install nginx → apt remove nginx
        final match = _installWithPkgRegex.firstMatch(c);
        if (match != null) {
          final pm = match.group(1)!;
          final pkg = match.group(3)!;
          if (pm == 'apt' || pm == 'apt-get') return '${prefix}$pm remove $pkg';
          if (pm == 'yum' || pm == 'dnf') return '${prefix}$pm remove $pkg';
          if (pm == 'apk') return '${prefix}$pm del $pkg';
          if (pm == 'pacman') return '${prefix}$pm -R $pkg';
          if (pm == 'snap') return '${prefix}snap remove $pkg';
          if (pm == 'brew') return 'brew uninstall $pkg';
        }
        return null;
      case ChangeType.uninstall:
        // 卸载的逆操作无法准确推断（需重装），返回 null
        return null;
      case ChangeType.startService:
        // systemctl start nginx → systemctl stop nginx
        final match = _systemctlStartWithUnitRegex.firstMatch(c);
        if (match != null) return '${prefix}systemctl stop ${match.group(1)}';
        final m2 = _serviceStartWithUnitRegex.firstMatch(c);
        if (m2 != null) return '${prefix}service ${m2.group(1)} stop';
        return null;
      case ChangeType.stopService:
        final match = _systemctlStopWithUnitRegex.firstMatch(c);
        if (match != null) return '${prefix}systemctl start ${match.group(1)}';
        final m2 = _serviceStopWithUnitRegex.firstMatch(c);
        if (m2 != null) return '${prefix}service ${m2.group(1)} start';
        return null;
      case ChangeType.restartService:
        // 重启不可逆，返回 null
        return null;
      case ChangeType.fileOperation:
        // cp/mv/rm 的回滚需要快照，这里无法准确推断
        // 实际回滚依赖 RollbackAdvisor 的快照
        return null;
      case ChangeType.permission:
        // chmod/chown 回滚需要原始权限，无法推断
        return null;
      case ChangeType.modifyConfig:
        return null;
      case ChangeType.other:
        return null;
    }
  }

  /// 记录一条变更
  static Future<ChangeRecord> record({
    required String hostId,
    required String command,
    required bool success,
    String? username,
    String? conversationId,
    ChangeType? forceType,
    String? localRestoreFrom,
    String? localRestoreTo,
  }) async {
    final type = forceType ?? inferType(command);
    final rollbackCmd =
        forceType != null ? null : buildRollbackCommand(command, type);
    final hasLocalRestore =
        localRestoreFrom != null && localRestoreFrom.isNotEmpty;
    final record = ChangeRecord(
      id: _uuid.v4(),
      hostId: hostId,
      command: command,
      type: type,
      rollbackCommand: rollbackCmd,
      rollbackDescription: hasLocalRestore
          ? '本机文件还原'
          : (rollbackCmd != null ? '可自动回滚' : null),
      localRestoreFrom: localRestoreFrom,
      localRestoreTo: localRestoreTo,
      timestamp: DateTime.now(),
      success: success,
      username: username,
      conversationId: conversationId,
    );
    await ChangeRecordsDao.upsert(record);
    return record;
  }

  /// 标记某条记录已回滚
  static Future<void> markRolledBack(String recordId) async {
    final record = ChangeRecordsDao.getCachedById(recordId);
    if (record != null) {
      record.rolledBack = true;
      await ChangeRecordsDao.upsert(record);
    }
  }

  /// 查询某主机的变更历史（按时间倒序）
  static List<ChangeRecord> getHistory(String hostId, {int limit = 100}) {
    return ChangeRecordsDao.getCachedByHost(hostId, limit: limit);
  }

  /// 查询所有主机的变更历史（按时间倒序）
  static List<ChangeRecord> getAllHistory({int limit = 200}) {
    final all = ChangeRecordsDao.cachedAll;
    return all.take(limit).toList();
  }

  /// 执行回滚
  ///
  /// 回滚命令本身也是修改性命令，需要：
  /// 1. 通过安全检查（不可逆操作仍拒绝）
  /// 2. 记入审计日志（保证审计链完整）
  /// 3. 不再走封网期/只读模式检查（用户已显式确认回滚，回滚是修复手段）
  ///
  /// 返回回滚命令的执行结果；返回 null 表示参数错误或连接断开
  /// [executor] 只在执行远程回滚命令时需要；本机文件还原不经过 executor，可传 null
  static Future<CommandResult?> executeRollback(
    ChangeRecord record,
    CommandExecutor? executor, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    // 本机文件还原走 Dart I/O，绝不能丢给 executor：
    // 在 SSH 会话里执行 `mv` 会打到远端机器，而文件其实在本机。
    if (record.isLocalFileRestore) {
      return _restoreLocalFile(record);
    }
    if (record.rollbackCommand == null) {
      return null;
    }
    if (executor == null || !executor.isConnected) {
      return null;
    }
    // 安全检查：回滚命令本身不能是 blocked 级（如 rm -rf /）
    final rollbackSafety = SafetyGuard.check(record.rollbackCommand!);
    if (rollbackSafety == SafetyLevel.blocked) {
      return CommandResult(
        stdout: '',
        stderr: '回滚命令被安全系统拦截: ${record.rollbackCommand}',
        exitCode: -1,
        duration: Duration.zero,
      );
    }
    final result = await executor.executeAndWait(record.rollbackCommand!, timeout: timeout);
    // 审计日志：记录回滚命令的执行（无论成败）
    try {
      await AuditLogger.log(
        hostId: record.hostId,
        command: record.rollbackCommand!,
        safetyLevel: rollbackSafety.name,
        output: result.success
            ? (result.stdout.isNotEmpty ? result.stdout.substring(0, result.stdout.length.clamp(0, 500)) : null)
            : result.stderr,
        executed: true,
      );
    } catch (_) {}
    if (result.success) {
      await markRolledBack(record.id);
    }
    return result;
  }

  /// 把本机文件从备份 / 回收区放回原位
  ///
  /// 语义差别是有意保留的：
  /// - 文件用 copy —— 副本留在原地，同一条记录可以反复还原
  /// - 目录用 rename —— 整体放回，避免复制大目录时把回收区留成半空状态
  /// 目标已存在时先把它另存为 `.displaced.{时间戳}` 再还原：还原动作本身也不能
  /// 悄悄覆盖用户在两次操作之间改出来的内容。
  static Future<CommandResult> _restoreLocalFile(ChangeRecord record) async {
    final from = record.localRestoreFrom!;
    final to = record.localRestoreTo!;
    const stage = '本机文件还原';

    try {
      final srcIsDir = Directory(from).existsSync();
      final srcIsFile = !srcIsDir && File(from).existsSync();
      if (!srcIsDir && !srcIsFile) {
        return _restoreFailure(
            '$stage失败：副本已不存在（$from），无法还原');
      }

      final parent = p.dirname(to);
      if (parent.isNotEmpty && !Directory(parent).existsSync()) {
        Directory(parent).createSync(recursive: true);
      }

      String? displaced;
      final targetExists = srcIsDir
          ? Directory(to).existsSync()
          : File(to).existsSync();
      if (targetExists) {
        displaced = '$to.displaced.${DateTime.now().millisecondsSinceEpoch}';
        if (srcIsDir) {
          Directory(to).renameSync(displaced);
        } else {
          File(to).renameSync(displaced);
        }
      }

      if (srcIsDir) {
        Directory(from).renameSync(to);
      } else {
        File(from).copySync(to);
      }

      final message = displaced == null
          ? '$stage完成：$from → $to'
          : '$stage完成：$from → $to（还原前的现有文件已另存为 $displaced）';
      await markRolledBack(record.id);
      await _auditRestore(record, message, ok: true);
      return CommandResult(
        stdout: message,
        stderr: '',
        exitCode: 0,
        duration: Duration.zero,
      );
    } catch (e) {
      final msg = '$stage失败：$e';
      await _auditRestore(record, msg, ok: false);
      return _restoreFailure(msg);
    }
  }

  static CommandResult _restoreFailure(String message) => CommandResult(
        stdout: '',
        stderr: message,
        exitCode: -1,
        duration: Duration.zero,
        failureKind: CommandFailureKind.unknown,
        failureReason: message,
      );

  /// 还原动作必须留痕：它改的是本机文件，远程审计里看不到
  static Future<void> _auditRestore(
      ChangeRecord record, String message, {required bool ok}) async {
    try {
      await AuditLogger.log(
        hostId: record.hostId,
        command: 'RESTORE LOCAL ${record.command}',
        safetyLevel: ok ? 'info' : 'warn',
        output: message,
        executed: true,
      );
    } catch (_) {
      // 审计写失败不该阻断已经成功的还原
    }
  }
}
