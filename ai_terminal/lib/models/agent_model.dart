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

  /// 失败诊断（CommandResult.failureReason 透传：超时时长/语法错误/交互提示原文）。
  /// 失败观测把它回传给 AI 用于决策（重试/修语法/重连/给密码）
  final String? failureReason;

  AgentResult({
    required this.success,
    this.output,
    this.error,
    this.exitCode,
    this.duration,
    this.failureKind,
    this.failureReason,
  });

  factory AgentResult.fromCommand({
    required String command,
    required String stdout,
    required String stderr,
    required int exitCode,
    required Duration duration,
    String? failureKind,
    String? failureReason,
  }) {
    return AgentResult(
      // 与 CommandResult.success 同口径：异常路径（超时/语法/断线/交互中断）
      // 即使 shell 报了 0 退出码也不算成功，消除对「异常必返 -1」的隐式依赖
      success: exitCode == 0 && failureKind == null,
      output: stdout.isNotEmpty ? stdout : null,
      error: stderr.isNotEmpty ? stderr : null,
      exitCode: exitCode,
      duration: duration,
      failureKind: failureKind,
      failureReason: failureReason,
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

  /// 错误信息（仅当 stderr 真有内容时非 null）
  final String? error;

  /// 退出码（失败观测标题里带给 AI）
  final int? exitCode;

  /// 失败类型（CommandFailureKind.name）
  final String? failureKind;

  /// 失败诊断原文（超时时长/语法错误/交互提示文本，AI 据此决策）
  final String? failureReason;

  const ReActObservation({
    required this.command,
    required this.output,
    this.success = true,
    this.error,
    this.exitCode,
    this.failureKind,
    this.failureReason,
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
      final codePart = exitCode != null ? ' (退出码: $exitCode)' : '';
      buffer.writeln('观测: 命令 $cmdRef 执行失败$codePart');
      final kind = failureKind ?? '';
      final reason = failureReason ?? '';
      if (kind.isNotEmpty || reason.isNotEmpty) {
        buffer.writeln([
          if (kind.isNotEmpty) '失败类型: $kind',
          if (reason.isNotEmpty) '诊断: $reason',
        ].join(' · '));
      }
      // 失败时真实报错几乎总在 output（执行器把远端 stderr 并入了 stdout，
      // error 恒空的契约）——旧实现只回显 error，AI 永远看到 "(无输出)"。
      final hasOutput = output.isNotEmpty && output != '(无输出)';
      if (hasOutput) {
        buffer.writeln('输出:');
        buffer.writeln(output);
      }
      // 拦截类观测把同一原因同时放进 output 和 error（历史契约）——
      // 不再重复输出第二遍；真实 stderr（执行器契约下与 output 不同源）仍单独成段。
      final err = error;
      final hasError =
          err != null && err.isNotEmpty && !(hasOutput && output.contains(err));
      if (hasError) {
        buffer.writeln('错误:');
        buffer.writeln(err);
      }
      if (!hasOutput && !hasError) {
        buffer.writeln('(无输出)');
      }
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

  /// 会话累计轮次：用户每次提问、目标每次续跑各 +1。
  ///
  /// 注意与 [aiCalls] 的区别——这里度量的是"用户可感知的第几次任务"，
  /// 不是模型调用次数。一轮里可能包含几十次模型调用（[aiCalls]）与命令执行。
  /// 由 provider 在启动任务时按会话累加后传入，引擎不自行递增。
  final int rounds;

  /// 本任务的模型请求次数（含重试与备用模型切换）。
  /// 只作为 [stepTotal] 的组成部分，不直接显示——显示它会让"轮"看起来比"步"多。
  final int aiCalls;

  /// 被安全策略 / 权限档位 / 用户拒绝而未执行的命令数（含确认超时）。
  /// 这些命令从未真正执行，但用户视角是"AI 尝试过"，按产品口径要计入 [stepTotal]。
  final int blockedCount;

  /// 本任务发起的工具调用次数（含未知工具、只读档拦截的调用）。
  final int toolCalls;

  /// 「步」= 请求 AI + 执行命令（成功/失败/被拦截）+ 工具调用。
  ///
  /// 与 [rounds] 是两个量纲：轮是任务次数，步是一轮内的活动次数，
  /// 所以步永远 ≥ 轮（只要一轮至少发起过一次模型请求）。
  /// 命名避开 [steps]（模型声明的执行清单），那是另一回事。
  int get stepTotal =>
      aiCalls + successCount + failureCount + blockedCount + toolCalls;

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
    this.aiCalls = 0,
    this.blockedCount = 0,
    this.toolCalls = 0,
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
    int? aiCalls,
    int? blockedCount,
    int? toolCalls,
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
      aiCalls: aiCalls ?? this.aiCalls,
      blockedCount: blockedCount ?? this.blockedCount,
      toolCalls: toolCalls ?? this.toolCalls,
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
