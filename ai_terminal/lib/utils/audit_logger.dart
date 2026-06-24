import 'package:flutter/foundation.dart';
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
/// 性能优化要点：
/// 1. 使用独立 Hive box（auditLogs），避免污染 settingsBox
/// 2. 使用 `box.add()` 追加模式（O(1)），不再每次 get/put 整个列表（O(n) 序列化）
/// 3. 自动限制最大条数（1000 条），超过时删除最早的
/// 4. 读取时按需扫描，避免启动时全量加载
class AuditLogger {
  static const _maxEntries = 1000;

  /// 记录命令执行（追加模式，O(1)）
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

    try {
      final box = HiveInit.auditLogsBox;
      await box.add(entry.toJson());

      // 容量控制：超过上限时删除最早的条目
      if (box.length > _maxEntries) {
        final deleteCount = box.length - _maxEntries;
        final keysToDelete = box.keys.take(deleteCount).toList();
        await box.deleteAll(keysToDelete);
      }
    } catch (e) {
      debugPrint('[AuditLogger] 记录失败: $e');
    }
  }

  /// 获取主机的审计日志（最近的 limit 条）
  static List<Map<String, dynamic>> getLogsForHost(String hostId, {int limit = 100}) {
    try {
      final box = HiveInit.auditLogsBox;
      final result = <Map<String, dynamic>>[];

      // 从最新往前扫描，匹配 hostId
      final allKeys = box.keys.toList();
      for (int i = allKeys.length - 1; i >= 0 && result.length < limit; i--) {
        final raw = box.get(allKeys[i]);
        if (raw is Map && raw['hostId'] == hostId) {
          result.add(Map<String, dynamic>.from(raw));
        }
      }
      // 反转为正序（最早到最新）
      return result.reversed.toList(growable: false);
    } catch (e) {
      debugPrint('[AuditLogger] 读取失败: $e');
      return [];
    }
  }

  /// 获取最近的审计日志（倒序：最新在前）
  static List<Map<String, dynamic>> getRecentLogs({int limit = 100}) {
    try {
      final box = HiveInit.auditLogsBox;
      final allKeys = box.keys.toList();
      final result = <Map<String, dynamic>>[];
      final startIdx = allKeys.length > limit ? allKeys.length - limit : 0;
      for (int i = allKeys.length - 1; i >= startIdx; i--) {
        final raw = box.get(allKeys[i]);
        if (raw is Map) {
          result.add(Map<String, dynamic>.from(raw));
        }
      }
      return result;
    } catch (e) {
      debugPrint('[AuditLogger] 读取失败: $e');
      return [];
    }
  }
}
