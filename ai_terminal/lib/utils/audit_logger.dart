import 'package:flutter/foundation.dart';
import '../core/permission_policy.dart';
import '../core/safety_guard.dart';
import '../core/security/command_intent.dart';
import '../models/agent_permission_mode.dart';
import '../services/daos.dart';

class AuditLogEntry {
  final DateTime timestamp;
  final String hostId;
  final String command;
  final String safetyLevel;
  final String? output;
  final bool executed;
  final Map<String, dynamic>? metadata;

  AuditLogEntry({
    required this.timestamp,
    required this.hostId,
    required this.command,
    required this.safetyLevel,
    this.output,
    required this.executed,
    this.metadata,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'hostId': hostId,
        'command': command,
        'safetyLevel': safetyLevel,
        'output': output,
        'executed': executed,
        if (metadata != null) 'metadata': metadata,
      };

  static AuditLogEntry fromJson(Map<dynamic, dynamic> json) => AuditLogEntry(
        timestamp: DateTime.parse(json['timestamp'] as String),
        hostId: json['hostId'] as String,
        command: json['command'] as String,
        safetyLevel: json['safetyLevel'] as String,
        output: json['output'] as String?,
        executed: json['executed'] as bool,
        metadata: json['metadata'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(json['metadata'] as Map)
            : null,
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
    Map<String, dynamic>? metadata,
  }) async {
    try {
      await AuditLogsDao.add(
        hostId: hostId,
        command: command,
        safetyLevel: safetyLevel,
        output: output,
        executed: executed,
        metadata: metadata,
      );
    } catch (e) {
      debugPrint('[AuditLogger] 记录失败: $e');
    }
  }

  static Map<String, dynamic> commandMetadata({
    required String command,
    AgentPermissionMode? permissionMode,
    CommandGateDecision? decision,
    String? policyReason,
  }) {
    final intent = SafetyGuard.intent(command);
    final gateDecision = permissionMode == null
        ? decision
        : (decision ??
            decideCommand(SafetyGuard.check(command), permissionMode));
    final unknownSyntaxReason =
        permissionMode == AgentPermissionMode.fullAuto &&
                intent.unresolved.isNotEmpty
            ? 'explicit_full_auto_unknown_syntax'
            : null;
    return {
      'parserVersion': CommandIntentParser.parserVersion,
      'shell': intent.shell,
      'executable': intent.executable,
      'confidence': intent.confidence,
      'conservativeSafe': intent.conservativeSafe,
      'effects': intent.effects.map((effect) => effect.name).toList(),
      'unresolved': intent.unresolved
          .take(20)
          .map((item) => {
                'kind': item.kind,
                'detail': item.detail.length <= 300
                    ? item.detail
                    : '${item.detail.substring(0, 300)}…',
              })
          .toList(),
      if (permissionMode != null) 'permissionMode': permissionMode.id,
      if (gateDecision != null) 'permissionDecision': gateDecision.name,
      if ((policyReason ?? unknownSyntaxReason) != null)
        'policyReason': policyReason ?? unknownSyntaxReason,
    };
  }

  /// 获取主机的审计日志（最近的 limit 条，正序：最早到最新）
  static List<Map<String, dynamic>> getLogsForHost(String hostId,
      {int limit = 100}) {
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
