/// 目标模式的状态。
///
/// 与 `AgentTask` 的区别：任务是一次 ReAct 循环，目标是跨任务的持续意图。
/// 自动续跑失控是本功能的最大风险，所以预算、无进展检测与终态归因都必须
/// 记在目标自己身上，而不是散在引擎里。
enum AgentGoalStatus { active, paused, finished }

class AgentGoal {
  final String id;

  /// 归属 host（'local' 或服务器 id）。状态按 host 隔离，
  /// 自动续跑必须用这个 id，不能用注册表的活跃 host（AGENTS.md R3）。
  final String hostId;

  /// 用户原文，不做大小写转换
  final String objective;
  final AgentGoalStatus status;

  /// 已用的目标轮次（只有目标驱动的任务计数；用户手动发消息不扣预算）
  final int roundsUsed;

  /// 硬止损。默认值见 [AgentGoal.defaultMaxRounds]
  final int maxRounds;

  /// 上一轮实际执行的命令数，用于无进展检测
  final int lastRoundCommands;

  /// 连续多少轮步数没有增量。达到 2 就暂停而不是继续空转
  final int noProgressRounds;

  /// 暂停/结束的原因，给用户看
  final String? note;

  final DateTime createdAt;
  final DateTime updatedAt;

  const AgentGoal({
    required this.id,
    required this.hostId,
    required this.objective,
    this.status = AgentGoalStatus.active,
    this.roundsUsed = 0,
    this.maxRounds = defaultMaxRounds,
    this.lastRoundCommands = 0,
    this.noProgressRounds = 0,
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  static const int defaultMaxRounds = 24;
  static const int maxAllowedRounds = 256;

  bool get isActive => status == AgentGoalStatus.active;

  /// 预算是否已用尽
  bool get budgetExhausted => roundsUsed >= maxRounds;

  int get roundsLeft =>
      maxRounds - roundsUsed > 0 ? maxRounds - roundsUsed : 0;

  AgentGoal copyWith({
    AgentGoalStatus? status,
    String? objective,
    int? roundsUsed,
    int? maxRounds,
    int? lastRoundCommands,
    int? noProgressRounds,
    String? note,
    bool clearNote = false,
    DateTime? updatedAt,
  }) {
    return AgentGoal(
      id: id,
      hostId: hostId,
      objective: objective ?? this.objective,
      status: status ?? this.status,
      roundsUsed: roundsUsed ?? this.roundsUsed,
      maxRounds: maxRounds ?? this.maxRounds,
      lastRoundCommands: lastRoundCommands ?? this.lastRoundCommands,
      noProgressRounds: noProgressRounds ?? this.noProgressRounds,
      note: clearNote ? null : (note ?? this.note),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'hostId': hostId,
        'objective': objective,
        'status': status.name,
        'roundsUsed': roundsUsed,
        'maxRounds': maxRounds,
        'lastRoundCommands': lastRoundCommands,
        'noProgressRounds': noProgressRounds,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  static AgentGoal? fromJson(Object? json) {
    if (json is! Map) return null;
    final objective = json['objective'];
    if (objective is! String || objective.trim().isEmpty) return null;
    final createdAt = _date(json['createdAt']);
    final updatedAt = _date(json['updatedAt']);
    if (createdAt == null || updatedAt == null) return null;
    return AgentGoal(
      id: json['id'] is String ? json['id'] as String : '',
      hostId: json['hostId'] is String ? json['hostId'] as String : '',
      objective: objective,
      status: _status(json['status']),
      roundsUsed: _int(json['roundsUsed']),
      // 夹取：改过上限或数据被外部编辑过时，不能让预算值突破硬上限
      maxRounds: _clampRounds(json['maxRounds']),
      lastRoundCommands: _int(json['lastRoundCommands']),
      noProgressRounds: _int(json['noProgressRounds']),
      note: json['note'] is String ? json['note'] as String : null,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  static AgentGoalStatus _status(Object? raw) {
    for (final s in AgentGoalStatus.values) {
      if (s.name == raw) return s;
    }
    // 未知/缺失状态一律当 paused：宁可停下等用户，也不要凭半个字段就自动续跑
    return AgentGoalStatus.paused;
  }

  static int _int(Object? v) => v is num ? v.toInt() : 0;

  static int _clampRounds(Object? v) {
    final raw = v is num ? v.toInt() : defaultMaxRounds;
    if (raw < 1) return 1;
    return raw > maxAllowedRounds ? maxAllowedRounds : raw;
  }

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;
}
