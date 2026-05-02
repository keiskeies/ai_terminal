/// Agent 模式枚举
enum AgentMode {
  /// 辅助模式：生成命令供用户确认（当前行为）
  assistant,

  /// 自动模式：AI 自动分析、执行、验证
  automatic,
}

/// Agent 执行状态
enum AgentStatus {
  idle,       // 空闲
  thinking,   // AI 思考中
  executing,  // 执行命令中
  waitingConfirm,  // 等待用户确认危险命令
  completed, // 任务完成
  failed,    // 任务失败
  cancelled, // 用户取消
}

/// Agent 执行结果
class AgentResult {
  final bool success;
  final String? output;
  final String? error;
  final int? exitCode;
  final Duration? duration;

  AgentResult({
    required this.success,
    this.output,
    this.error,
    this.exitCode,
    this.duration,
  });

  factory AgentResult.fromCommand({
    required String command,
    required String stdout,
    required String stderr,
    required int exitCode,
    required Duration duration,
  }) {
    return AgentResult(
      success: exitCode == 0,
      output: stdout.isNotEmpty ? stdout : null,
      error: stderr.isNotEmpty ? stderr : null,
      exitCode: exitCode,
      duration: duration,
    );
  }

  String get summary {
    if (success) {
      return '✅ 执行成功 (${duration?.inMilliseconds ?? 0}ms)';
    } else {
      return '❌ 执行失败 (退出码: $exitCode, ${duration?.inMilliseconds ?? 0}ms)';
    }
  }
}

/// Agent 任务
class AgentTask {
  final String id;
  final String goal;           // 用户目标
  final String? currentStep;   // 当前步骤描述
  final List<String> steps;    // 执行步骤历史
  final List<AgentResult> results;  // 执行结果
  final AgentStatus status;
  final DateTime createdAt;
  final DateTime? completedAt;

  AgentTask({
    required this.id,
    required this.goal,
    this.currentStep,
    List<String>? steps,
    List<AgentResult>? results,
    this.status = AgentStatus.idle,
    DateTime? createdAt,
    this.completedAt,
  })  : steps = steps ?? [],
        results = results ?? [],
        createdAt = createdAt ?? DateTime.now();

  AgentTask copyWith({
    String? currentStep,
    List<String>? steps,
    List<AgentResult>? results,
    AgentStatus? status,
    DateTime? completedAt,
  }) {
    return AgentTask(
      id: id,
      goal: goal,
      currentStep: currentStep ?? this.currentStep,
      steps: steps ?? this.steps,
      results: results ?? this.results,
      status: status ?? this.status,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  String get progress {
    if (status == AgentStatus.completed) return '✅ 完成';
    if (status == AgentStatus.failed) return '❌ 失败';
    if (status == AgentStatus.executing) return '⚡ 执行中: $currentStep';
    if (status == AgentStatus.thinking) return '🤔 思考中...';
    return '⏳ 等待';
  }
}
