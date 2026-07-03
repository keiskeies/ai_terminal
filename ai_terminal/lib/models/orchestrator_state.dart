/// 多机编排状态模型

/// 编排阶段
enum OrchestratorPhase {
  /// AI 规划中
  planning,
  /// 等待用户确认矩阵
  confirming,
  /// 执行中
  executing,
  /// 连通性验证
  verifying,
  /// 已完成
  completed,
  /// 失败
  failed,
  /// 失败后暂停，等用户决策
  paused,
}

/// 主机角色（部署矩阵的一行）
class HostRole {
  /// 主机 id（对应 HostConfig.id）
  final String hostId;
  /// 主机显示名
  final String displayName;
  /// 角色（如 "后端"、"数据库"、"nginx"）
  final String role;
  /// 目标路径
  final String? targetPath;
  /// 操作描述
  final String? operation;

  const HostRole({
    required this.hostId,
    required this.displayName,
    required this.role,
    this.targetPath,
    this.operation,
  });

  Map<String, dynamic> toJson() => {
        'hostId': hostId,
        'displayName': displayName,
        'role': role,
        'targetPath': targetPath,
        'operation': operation,
      };

  factory HostRole.fromJson(Map<String, dynamic> json) => HostRole(
        hostId: json['hostId'] as String,
        displayName: json['displayName'] as String,
        role: json['role'] as String,
        targetPath: json['targetPath'] as String?,
        operation: json['operation'] as String?,
      );
}

/// 单台主机的任务状态
enum HostTaskStatus {
  pending,
  running,
  success,
  failed,
  skipped,
}

/// 主机任务结果
class HostTaskResult {
  final String hostId;
  final HostTaskStatus status;
  final String? output;
  final String? error;

  const HostTaskResult({
    required this.hostId,
    required this.status,
    this.output,
    this.error,
  });
}

/// 连通性测试结果
class ConnectivityResult {
  final String fromHostId;
  final String targetHost;
  final int port;
  final bool reachable;
  final String? detail;
  final Duration elapsed;

  const ConnectivityResult({
    required this.fromHostId,
    required this.targetHost,
    required this.port,
    required this.reachable,
    this.detail,
    required this.elapsed,
  });

  String get summary {
    final ms = elapsed.inMilliseconds;
    if (reachable) {
      return '$fromHostId → $targetHost:$port ✓ (${ms}ms)';
    }
    return '$fromHostId → $targetHost:$port ✗ (${detail ?? "不可达"})';
  }
}

/// 编排状态
class OrchestratorState {
  final OrchestratorPhase phase;
  /// 部署矩阵
  final List<HostRole> matrix;
  /// 每台机的状态
  final Map<String, HostTaskResult> hostResults;
  /// 当前阶段索引（用于进度展示）
  final int currentPhaseIndex;
  /// 总阶段数
  final int totalPhases;
  /// 失败的主机 id
  final String? failureHostId;
  /// 失败原因
  final String? failureReason;
  /// 参与编排的主机 id 列表
  final List<String> participantHostIds;

  const OrchestratorState({
    this.phase = OrchestratorPhase.planning,
    this.matrix = const [],
    this.hostResults = const {},
    this.currentPhaseIndex = 0,
    this.totalPhases = 0,
    this.failureHostId,
    this.failureReason,
    this.participantHostIds = const [],
  });

  OrchestratorState copyWith({
    OrchestratorPhase? phase,
    List<HostRole>? matrix,
    Map<String, HostTaskResult>? hostResults,
    int? currentPhaseIndex,
    int? totalPhases,
    String? failureHostId,
    String? failureReason,
    List<String>? participantHostIds,
    bool clearFailure = false,
  }) {
    return OrchestratorState(
      phase: phase ?? this.phase,
      matrix: matrix ?? this.matrix,
      hostResults: hostResults ?? this.hostResults,
      currentPhaseIndex: currentPhaseIndex ?? this.currentPhaseIndex,
      totalPhases: totalPhases ?? this.totalPhases,
      failureHostId: clearFailure ? null : (failureHostId ?? this.failureHostId),
      failureReason: clearFailure ? null : (failureReason ?? this.failureReason),
      participantHostIds: participantHostIds ?? this.participantHostIds,
    );
  }

  bool get isActive =>
      phase == OrchestratorPhase.executing ||
      phase == OrchestratorPhase.planning ||
      phase == OrchestratorPhase.verifying;
}
