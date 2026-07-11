import 'package:flutter/foundation.dart';
import '../services/daos.dart';

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

  static AuditLogEntry fromJson(Map<dynamic, dynamic> json) => AuditLogEntry(
    timestamp: DateTime.parse(json['timestamp'] as String),
    hostId: json['hostId'] as String,
    command: json['command'] as String,
    safetyLevel: json['safetyLevel'] as String,
    output: json['output'] as String?,
    executed: json['executed'] as bool,
  );
}

/// 审计日志记录器
///
/// 使用 SQLite audit_logs 表 + 内存缓存（AuditLogsDao）。
/// - log() 异步写入数据库并同步更新缓存
/// - getLogsForHost()/getRecentLogs() 从缓存同步读取
/// - 自动限制最大条数（1000 条），超过时删除最早的
class AuditLogger {
  /// 记录命令执行（追加模式，O(1)）
  static Future<void> log({
    required String hostId,
    required String command,
    required String safetyLevel,
    String? output,
    required bool executed,
  }) async {
    try {
      await AuditLogsDao.add(
        hostId: hostId,
        command: command,
        safetyLevel: safetyLevel,
        output: output,
        executed: executed,
      );
    } catch (e) {
      debugPrint('[AuditLogger] 记录失败: $e');
    }
  }

  /// 获取主机的审计日志（最近的 limit 条，正序：最早到最新）
  static List<Map<String, dynamic>> getLogsForHost(String hostId, {int limit = 100}) {
    try {
      return AuditLogsDao.getCachedLogsForHost(hostId, limit: limit);
    } catch (e) {
      debugPrint('[AuditLogger] 读取失败: $e');
      return [];
    }
  }

  /// 获取最近的审计日志（倒序：最新在前）
  static List<Map<String, dynamic>> getRecentLogs({int limit = 100}) {
    try {
      return AuditLogsDao.getCachedRecentLogs(limit: limit);
    } catch (e) {
      debugPrint('[AuditLogger] 读取失败: $e');
      return [];
    }
  }
}
