import '../core/hive_init.dart';

class AuditLogEntry {
  final DateTime timestamp;
  final String hostId;
  final String command;
  final String safetyLevel;
  final String? output;
  final bool executed;

  AuditLogEntry({
    required this.timestamp,
    required this.hostId,
    required this.command,
    required this.safetyLevel,
    this.output,
    required this.executed,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'hostId': hostId,
    'command': command,
    'safetyLevel': safetyLevel,
    'output': output,
    'executed': executed,
  };
}

class AuditLogger {
  static const _boxName = 'auditLogs';

  /// 记录命令执行
  static Future<void> log({
    required String hostId,
    required String command,
    required String safetyLevel,
    String? output,
    required bool executed,
  }) async {
    final entry = AuditLogEntry(
      timestamp: DateTime.now(),
      hostId: hostId,
      command: command,
      safetyLevel: safetyLevel,
      output: output,
      executed: executed,
    );

    final logs = HiveInit.settingsBox.get(_boxName, defaultValue: <Map>[]);
    logs.add(entry.toJson());
    await HiveInit.settingsBox.put(_boxName, logs);
  }

  /// 获取主机的审计日志
  static List<Map<String, dynamic>> getLogsForHost(String hostId, {int limit = 100}) {
    final logs = HiveInit.settingsBox.get(_boxName, defaultValue: <Map>[]);
    return logs
        .where((log) => log['hostId'] == hostId)
        .take(limit)
        .toList()
        .cast<Map<String, dynamic>>();
  }

  /// 获取最近的审计日志
  static List<Map<String, dynamic>> getRecentLogs({int limit = 100}) {
    final logs = HiveInit.settingsBox.get(_boxName, defaultValue: <Map>[]);
    final allLogs = logs.cast<Map<String, dynamic>>().toList();
    allLogs.sort((a, b) {
      final aTime = DateTime.parse(a['timestamp']);
      final bTime = DateTime.parse(b['timestamp']);
      return bTime.compareTo(aTime);
    });
    return allLogs.take(limit).toList();
  }
}
