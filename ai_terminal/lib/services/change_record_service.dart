import 'package:uuid/uuid.dart';
import '../core/hive_init.dart';
import '../core/safety_guard.dart';
import '../models/change_record.dart';
import 'command_executor.dart';
import '../utils/audit_logger.dart' show AuditLogger;

/// 变更台账服务 — 记录每次修改性命令，支持查询和回滚
class ChangeRecordService {
  static const _uuid = Uuid();

  /// 根据 SafetyGuard 规则推断变更类型
  static ChangeType inferType(String command) {
    final c = command.trim();
    if (RegExp(r'^sudo\s+(apt|apt-get|yum|dnf|apk|pacman|snap|brew)\s+(install|add|-S)').hasMatch(c)) {
      return ChangeType.install;
    }
    if (RegExp(r'^sudo\s+(apt|apt-get|yum|dnf|apk|pacman)\s+(remove|purge|erase|-R|autoremove)').hasMatch(c)) {
      return ChangeType.uninstall;
    }
    if (RegExp(r'^systemctl\s+start').hasMatch(c)) return ChangeType.startService;
    if (RegExp(r'^systemctl\s+stop').hasMatch(c)) return ChangeType.stopService;
    if (RegExp(r'^systemctl\s+restart').hasMatch(c)) return ChangeType.restartService;
    if (RegExp(r'^service\s+\w+\s+start').hasMatch(c)) return ChangeType.startService;
    if (RegExp(r'^service\s+\w+\s+stop').hasMatch(c)) return ChangeType.stopService;
    if (RegExp(r'^service\s+\w+\s+restart').hasMatch(c)) return ChangeType.restartService;
    if (RegExp(r'chmod|chown').hasMatch(c)) return ChangeType.permission;
    if (RegExp(r'^sudo\s+(cp|mv|rm|mkdir|tee|sed|echo.*>)').hasMatch(c) ||
        RegExp(r'(>>|>)\s*(/etc/|~/)').hasMatch(c)) {
      return ChangeType.fileOperation;
    }
    return ChangeType.other;
  }

  /// 生成回滚命令（基于命令类型）
  static String? buildRollbackCommand(String command, ChangeType type) {
    final c = command.trim();
    switch (type) {
      case ChangeType.install:
        // apt install nginx → apt remove nginx
        final match = RegExp(r'^sudo\s+(apt|apt-get|yum|dnf|apk|pacman|snap|brew)\s+(install|add|-S)\s+(\S+)').firstMatch(c);
        if (match != null) {
          final pm = match.group(1)!;
          final pkg = match.group(3)!;
          if (pm == 'apt' || pm == 'apt-get') return 'sudo $pm remove $pkg';
          if (pm == 'yum' || pm == 'dnf') return 'sudo $pm remove $pkg';
          if (pm == 'apk') return 'sudo $pm del $pkg';
          if (pm == 'pacman') return 'sudo $pm -R $pkg';
          if (pm == 'snap') return 'sudo snap remove $pkg';
          if (pm == 'brew') return 'brew uninstall $pkg';
        }
        return null;
      case ChangeType.uninstall:
        // 卸载的逆操作无法准确推断（需重装），返回 null
        return null;
      case ChangeType.startService:
        // systemctl start nginx → systemctl stop nginx
        final match = RegExp(r'^systemctl\s+start\s+(\S+)').firstMatch(c);
        if (match != null) return 'systemctl stop ${match.group(1)}';
        final m2 = RegExp(r'^service\s+(\w+)\s+start').firstMatch(c);
        if (m2 != null) return 'service ${m2.group(1)} stop';
        return null;
      case ChangeType.stopService:
        final match = RegExp(r'^systemctl\s+stop\s+(\S+)').firstMatch(c);
        if (match != null) return 'systemctl start ${match.group(1)}';
        final m2 = RegExp(r'^service\s+(\w+)\s+stop').firstMatch(c);
        if (m2 != null) return 'service ${m2.group(1)} start';
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
  }) async {
    final type = inferType(command);
    final rollbackCmd = buildRollbackCommand(command, type);
    final record = ChangeRecord(
      id: _uuid.v4(),
      hostId: hostId,
      command: command,
      type: type,
      rollbackCommand: rollbackCmd,
      rollbackDescription: rollbackCmd != null ? '可自动回滚' : null,
      timestamp: DateTime.now(),
      success: success,
      username: username,
      conversationId: conversationId,
    );
    await HiveInit.changeRecordsBox.put(record.id, record);
    return record;
  }

  /// 标记某条记录已回滚
  static Future<void> markRolledBack(String recordId) async {
    final record = HiveInit.changeRecordsBox.get(recordId);
    if (record != null) {
      record.rolledBack = true;
      await record.save();
    }
  }

  /// 查询某主机的变更历史（按时间倒序）
  static List<ChangeRecord> getHistory(String hostId, {int limit = 100}) {
    final records = HiveInit.changeRecordsBox.values
        .where((r) => r.hostId == hostId)
        .toList();
    records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return records.take(limit).toList();
  }

  /// 查询所有主机的变更历史（按时间倒序）
  static List<ChangeRecord> getAllHistory({int limit = 200}) {
    final records = HiveInit.changeRecordsBox.values.toList();
    records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return records.take(limit).toList();
  }

  /// 执行回滚
  ///
  /// 回滚命令本身也是修改性命令，需要：
  /// 1. 通过安全检查（不可逆操作仍拒绝）
  /// 2. 记入审计日志（保证审计链完整）
  /// 3. 不再走封网期/只读模式检查（用户已显式确认回滚，回滚是修复手段）
  ///
  /// 返回回滚命令的执行结果；返回 null 表示参数错误或连接断开
  static Future<CommandResult?> executeRollback(
    ChangeRecord record,
    CommandExecutor executor, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (record.rollbackCommand == null) {
      return null;
    }
    if (!executor.isConnected) {
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
}
