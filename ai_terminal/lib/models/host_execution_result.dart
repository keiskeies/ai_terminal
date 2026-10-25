/// 多主机批量执行的单机结果（随 ToolResult/AgentEvent 持久化）
class HostExecutionResult {
  final String hostId;
  final bool success;
  final String? output;
  final String? error;
  final int? exitCode;
  final int? durationMs;
  final String? failureKind;

  const HostExecutionResult({
    required this.hostId,
    required this.success,
    this.output,
    this.error,
    this.exitCode,
    this.durationMs,
    this.failureKind,
  });

  Map<String, dynamic> toJson() => {
        'hostId': hostId,
        'success': success,
        'output': output,
        'error': error,
        'exitCode': exitCode,
        'durationMs': durationMs,
        'failureKind': failureKind,
      };

  factory HostExecutionResult.fromJson(Map<String, dynamic> json) {
    final hostId = json['hostId'];
    return HostExecutionResult(
      hostId: hostId is String ? hostId : '',
      success: json['success'] == true,
      output: json['output'] is String ? json['output'] as String : null,
      error: json['error'] is String ? json['error'] as String : null,
      exitCode: (json['exitCode'] as num?)?.toInt(),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      failureKind:
          json['failureKind'] is String ? json['failureKind'] as String : null,
    );
  }
}
