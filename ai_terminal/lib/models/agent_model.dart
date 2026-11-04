import 'plan_step.dart';

/// Agent 执行状态
enum AgentStatus {
  idle, // 空闲
  thinking, // AI 思考中
  executing, // 执行命令中
  waitingConfirm, // 等待用户确认危险命令
  completed, // 任务完成
  failed, // 任务失败
  cancelled, // 用户取消
  paused, // P2-7: 用户暂停（可恢复）
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

  /// 失败类型（CommandFailureKind.name），成功时为 null
  final String? failureKind;

  AgentResult({
    required this.success,
    this.output,
    this.error,
    this.exitCode,
    this.duration,
    this.failureKind,
  });

  factory AgentResult.fromCommand({
    required String command,
    required String stdout,
    required String stderr,
    required int exitCode,
    required Duration duration,
    String? failureKind,
  }) {
    return AgentResult(
      success: exitCode == 0,
      output: stdout.isNotEmpty ? stdout : null,
      error: stderr.isNotEmpty ? stderr : null,
      exitCode: exitCode,
      duration: duration,
      failureKind: failureKind,
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

  /// 模型声明的执行计划（可选）
  final List<PlanStep>? plan;

  /// 面向用户的最终回答正文（finish 时可选，Markdown）
  ///
  /// 四段式（结论/现状/变更/建议）是给操作单字段用的；这一字段是"回答"本身，
  /// 允许写成带标题、列表、代码块的长文，不再被四行模板挤成短句。
  final String? answer;

  /// `回答:` 之后的操作单四字段块（结论/现状/变更/建议）
  ///
  /// 单独解析，避免它被当成回答正文的一部分塞进证据层。
  final String? sections;

  /// 原始 AI 响应（用于 fallback 和 UI 显示）
  final String rawResponse;

  const ReActStep({
    required this.thought,
    this.action,
    this.command,
    this.options,
    this.toolName,
    this.toolArgs,
    this.plan,
    this.answer,
    this.sections,
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
  /// command 含换行（如多行参数的工具调用）时不用反引号包裹，避免单行反引号跨多行造成歧义
  String format() {
    final isMultiline = command.contains('\n');
    final cmdRef = isMultiline ? command : '`$command`';
    final buffer = StringBuffer();
    if (success) {
      buffer.writeln('观测: 命令 $cmdRef 执行成功');
      if (output.isNotEmpty) {
        buffer.writeln('输出:');
        buffer.writeln(output);
      }
    } else {
      buffer.writeln('观测: 命令 $cmdRef 执行失败');
      buffer.writeln('错误:');
      buffer.writeln(error ?? output);
    }
    return buffer.toString();
  }
}

/// Agent 任务
class AgentTask {
  final String id;

  /// 稳定操作 id：暂停/恢复不变，用于关联变更台账与操作单
  final String? operationId;

  final String goal; // 用户目标
  final String? currentStep; // 当前步骤描述

  /// 展示层阶段文案：理解需求 / 检查环境 / 执行变更 / 验证结果 / 整理结论
  final String? phase;

  final List<String> steps; // 执行步骤历史
  final List<AgentResult> results; // 执行结果
  final AgentStatus status;
  final DateTime createdAt;
  final DateTime? completedAt;

  /// 预估总步骤数（AI 首次回复时可从思考中推断，初始为 null）
  final int? totalStepsEstimate;

  /// 已用时间（秒），从任务开始计算
  final int? elapsedSeconds;

  /// 当前步号（引擎循环计数）
  final int stepIndex;

  /// 成功执行的命令数
  final int successCount;

  /// 失败执行的命令数
  final int failureCount;

  /// AI 请求轮数（含重试），与 trace 的 ai_call_count 同语义
  final int rounds;

  /// token 总量。[hasEstimatedTokens] 为 true 时其中含估算成分，界面必须显示 ≈
  final int tokenTotal;

  /// 总量里是否含估算部分（provider 没给 usage 的那几次）
  final bool hasEstimatedTokens;

  /// 提示缓存命中率 0-100。provider 不提供 cached_tokens 时为 null——界面整项不渲染：
  /// 显示 0% 会被读成"这个模型没有提示缓存"，那是把未知说成结论。
  final int? cacheHitPercent;

  /// 最近一次发给模型的 prompt 规模，用于上下文占用环
  final int contextTokens;

  /// 等待用户确认危险命令/工具所占用的秒数。
  ///
  /// [elapsedSeconds] 是墙钟，对用户是事实，不减它；这个值只用来算 `tok/s` 的分母
  /// ——把"人想了 40 秒"算进引擎吞吐率，速率会从 215 掉到 174，那是测量口径错了
  /// 而不是模型变慢。
  final int confirmWaitSeconds;

  AgentTask({
    required this.id,
    this.operationId,
    required this.goal,
    this.currentStep,
    this.phase,
    List<String>? steps,
    List<AgentResult>? results,
    this.status = AgentStatus.idle,
    DateTime? createdAt,
    this.completedAt,
    this.totalStepsEstimate,
    this.elapsedSeconds,
    this.stepIndex = 0,
    this.successCount = 0,
    this.failureCount = 0,
    this.rounds = 0,
    this.tokenTotal = 0,
    this.hasEstimatedTokens = false,
    this.cacheHitPercent,
    this.contextTokens = 0,
    this.confirmWaitSeconds = 0,
  })  : steps = steps ?? [],
        results = results ?? [],
        createdAt = createdAt ?? DateTime.now();

  AgentTask copyWith({
    String? operationId,
    String? currentStep,
    String? phase,
    List<String>? steps,
    List<AgentResult>? results,
    AgentStatus? status,
    DateTime? completedAt,
    int? totalStepsEstimate,
    int? elapsedSeconds,
    int? stepIndex,
    int? successCount,
    int? failureCount,
    int? rounds,
    int? tokenTotal,
    bool? hasEstimatedTokens,
    int? cacheHitPercent,
    bool clearCacheHitPercent = false,
    int? contextTokens,
    int? confirmWaitSeconds,
  }) {
    return AgentTask(
      id: id,
      operationId: operationId ?? this.operationId,
      goal: goal,
      currentStep: currentStep ?? this.currentStep,
      phase: phase ?? this.phase,
      steps: steps ?? this.steps,
      results: results ?? this.results,
      status: status ?? this.status,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
      totalStepsEstimate: totalStepsEstimate ?? this.totalStepsEstimate,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      stepIndex: stepIndex ?? this.stepIndex,
      successCount: successCount ?? this.successCount,
      failureCount: failureCount ?? this.failureCount,
      rounds: rounds ?? this.rounds,
      tokenTotal: tokenTotal ?? this.tokenTotal,
      hasEstimatedTokens: hasEstimatedTokens ?? this.hasEstimatedTokens,
      cacheHitPercent: clearCacheHitPercent
          ? null
          : (cacheHitPercent ?? this.cacheHitPercent),
      contextTokens: contextTokens ?? this.contextTokens,
      confirmWaitSeconds: confirmWaitSeconds ?? this.confirmWaitSeconds,
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
