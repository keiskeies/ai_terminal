/// Agent 执行状态
enum AgentStatus {
  idle,       // 空闲
  thinking,   // AI 思考中
  executing,  // 执行命令中
  waitingConfirm,  // 等待用户确认危险命令
  completed, // 任务完成
  failed,    // 任务失败
  cancelled, // 用户取消
  paused,    // P2-7: 用户暂停（可恢复）
}

/// P2-7: 判断状态是否为终态（不会再变化）
bool isTerminalStatus(AgentStatus s) =>
    s == AgentStatus.completed ||
    s == AgentStatus.failed ||
    s == AgentStatus.cancelled;

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

/// ReAct 动作类型
enum ActionType {
  /// 执行 shell 命令
  execute,

  /// 任务完成
  finish,

  /// 询问用户选择
  ask,

  /// 调用工具（如 SFTP 上传等非 shell 能力）
  tool,
}

/// ReAct 步骤 — 从 AI 响应中解析的结构化动作
class ReActStep {
  /// 推理过程
  final String thought;

  /// 动作类型（null 表示 AI 未返回有效动作）
  final ActionType? action;

  /// 命令（execute 时）
  final String? command;

  /// 选项（ask 时）
  final List<String>? options;

  /// 工具名（tool 时）
  final String? toolName;

  /// 工具参数（tool 时，已解析的 JSON Map）
  final Map<String, dynamic>? toolArgs;

  /// 原始 AI 响应（用于 fallback 和 UI 显示）
  final String rawResponse;

  const ReActStep({
    required this.thought,
    this.action,
    this.command,
    this.options,
    this.toolName,
    this.toolArgs,
    required this.rawResponse,
  });

  @override
  String toString() =>
      'ReActStep(thought: $thought, action: $action, command: $command, options: $options, toolName: $toolName)';
}

/// ReAct 观测结果 — 命令执行后反馈给 AI 的标准格式
class ReActObservation {
  /// 执行的命令
  final String command;

  /// 命令输出
  final String output;

  /// 是否执行成功
  final bool success;

  /// 错误信息
  final String? error;

  const ReActObservation({
    required this.command,
    required this.output,
    this.success = true,
    this.error,
  });

  /// 格式化为 AI 可理解的观测文本
  String format() {
    final buffer = StringBuffer();
    if (success) {
      buffer.writeln('观测: 命令 `$command` 执行成功');
      if (output.isNotEmpty) {
        buffer.writeln('输出:');
        buffer.writeln(output);
      }
    } else {
      buffer.writeln('观测: 命令 `$command` 执行失败');
      buffer.writeln('错误:');
      buffer.writeln(error ?? output);
    }
    return buffer.toString();
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
  /// 预估总步骤数（AI 首次回复时可从思考中推断，初始为 null）
  final int? totalStepsEstimate;
  /// 已用时间（秒），从任务开始计算
  final int? elapsedSeconds;
  /// 成功执行的命令数
  final int successCount;
  /// 失败执行的命令数
  final int failureCount;

  AgentTask({
    required this.id,
    required this.goal,
    this.currentStep,
    List<String>? steps,
    List<AgentResult>? results,
    this.status = AgentStatus.idle,
    DateTime? createdAt,
    this.completedAt,
    this.totalStepsEstimate,
    this.elapsedSeconds,
    this.successCount = 0,
    this.failureCount = 0,
  })  : steps = steps ?? [],
        results = results ?? [],
        createdAt = createdAt ?? DateTime.now();

  AgentTask copyWith({
    String? currentStep,
    List<String>? steps,
    List<AgentResult>? results,
    AgentStatus? status,
    DateTime? completedAt,
    int? totalStepsEstimate,
    int? elapsedSeconds,
    int? successCount,
    int? failureCount,
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
      totalStepsEstimate: totalStepsEstimate ?? this.totalStepsEstimate,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      successCount: successCount ?? this.successCount,
      failureCount: failureCount ?? this.failureCount,
    );
  }

  String get progress {
    if (status == AgentStatus.completed) return '✅ 完成';
    if (status == AgentStatus.failed) return '❌ 失败';
    if (status == AgentStatus.cancelled) return '🚫 已取消';
    if (status == AgentStatus.paused) return '⏸️ 已暂停';
    if (status == AgentStatus.executing) return '⚡ 执行中: $currentStep';
    if (status == AgentStatus.thinking) return '🤔 思考中...';
    return '⏳ 等待';
  }
}
