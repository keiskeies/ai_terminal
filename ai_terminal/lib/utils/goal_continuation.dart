import '../models/agent_event.dart';
import '../models/agent_goal.dart';

/// 续跑决策的结果类型。
enum GoalAction {
  /// 发起下一轮目标任务
  continueRound,

  /// 目标达成或预算耗尽，正常收尾
  finish,

  /// 停下来等用户，不再自动发起
  pause,
}

class GoalDecision {
  final GoalAction action;

  /// 决策后的目标状态（含 roundsUsed / lastStepIndex 等推进），调用方直接落盘
  final AgentGoal goal;

  /// 给用户看的原因；continueRound 时为 null
  final String? note;

  /// 本轮决策依据，用于测试与日志
  final String reason;

  const GoalDecision({
    required this.action,
    required this.goal,
    required this.reason,
    this.note,
  });
}

/// 模型在回答里声明目标达成的标记（出现在行首即算）
const String kGoalDoneMarker = '目标已达成';

/// 整条"命令"其实只是达成标记。
///
/// 真机复拍发现：模型会把「目标已达成」写进 `命令:` 块，于是被丢进 shell，
/// 得到一条 CommandNotFoundException。提示词只能降低概率，挡不住，
/// 所以执行侧必须有一道硬守卫。
bool isGoalMarkerOnlyCommand(String command) {
  final stripped = command
      .replaceAll(
          RegExp(r'''["'`()\[\]【】「」『』。，,：:；;！!]'''), '')
      .trim();
  return stripped.isNotEmpty && stripped == kGoalDoneMarker;
}

/// 判断一轮的收尾文本是否声明了目标达成。
///
/// 要求出现在**行首**，避免模型在正文里引述这句话就误判完成。
bool goalMarkedDone(String? summary) {
  if (summary == null) return false;
  for (final line in summary.split('\n')) {
    if (line.trimLeft().startsWith(kGoalDoneMarker)) return true;
  }
  return false;
}

/// 目标模式的续跑决策——设计文档 §3.2.4 的终态矩阵，纯函数。
///
/// 抽出来是为了能脱离引擎与 provider 逐行测这 9 条：自动续跑失控是本功能最大的
/// 风险，而这些分支在真机上很难凑齐（要恰好赶上断连、超时、预算耗尽）。
///
/// 判定顺序即优先级，**不可重排**：用户取消必须排在预算检查之前，
/// 否则"取消后预算还剩"会被当成"还能继续"而复活。
GoalDecision decideGoalContinuation({
  required AgentGoal goal,
  required AgentFinishState? finishState,

  /// 本轮实际执行的命令数（成功+失败），无进展判定的依据
  required int commandsRun,
  required bool hadConfirmTimeout,
  required bool connectionAlive,
  required bool isForegroundHost,
  required String? finishSummary,
}) {
  // 1. 模型显式声明达成
  if (goalMarkedDone(finishSummary)) {
    return GoalDecision(
      action: GoalAction.finish,
      reason: 'objective_done',
      goal: goal.copyWith(
        status: AgentGoalStatus.finished,
        note: '模型声明目标已达成',
        updatedAt: DateTime.now(),
      ),
    );
  }

  // 2. 用户点停止：绝不自动复活
  if (finishState == AgentFinishState.cancelled) {
    return GoalDecision(
      action: GoalAction.pause,
      reason: 'user_cancelled',
      note: '你停止了任务，目标已暂停',
      goal: goal.copyWith(
        status: AgentGoalStatus.paused,
        note: '你停止了任务，目标已暂停',
        updatedAt: DateTime.now(),
      ),
    );
  }

  // 3. 人不在看管：确认超时说明没人批准，继续跑只会反复超时空转
  if (hadConfirmTimeout) {
    return GoalDecision(
      action: GoalAction.pause,
      reason: 'confirm_timeout',
      note: '有操作因超时未获确认被自动拒绝，目标已暂停',
      goal: goal.copyWith(
        status: AgentGoalStatus.paused,
        note: '有操作因超时未获确认被自动拒绝，目标已暂停',
        updatedAt: DateTime.now(),
      ),
    );
  }

  // 4. 执行环境异常：连接断了或会话已切走，此时发任务只会失败或跑错机器
  if (!connectionAlive) {
    return GoalDecision(
      action: GoalAction.pause,
      reason: 'disconnected',
      note: '终端连接已断开，目标已暂停',
      goal: goal.copyWith(
        status: AgentGoalStatus.paused,
        note: '终端连接已断开，目标已暂停',
        updatedAt: DateTime.now(),
      ),
    );
  }
  if (!isForegroundHost) {
    return GoalDecision(
      action: GoalAction.pause,
      reason: 'not_foreground',
      note: '已切到其他会话，回到本会话后恢复目标',
      goal: goal.copyWith(
        status: AgentGoalStatus.paused,
        note: '已切到其他会话，回到本会话后恢复目标',
        updatedAt: DateTime.now(),
      ),
    );
  }

  // 5. 硬止损：预算耗尽。放在"失败"之前——预算没了就该结束而不是暂停等恢复
  if (goal.budgetExhausted) {
    return GoalDecision(
      action: GoalAction.finish,
      reason: 'budget_exhausted',
      note: '轮次预算耗尽（${goal.roundsUsed}/${goal.maxRounds}）',
      goal: goal.copyWith(
        status: AgentGoalStatus.finished,
        note: '轮次预算耗尽（${goal.roundsUsed}/${goal.maxRounds}）',
        updatedAt: DateTime.now(),
      ),
    );
  }

  // 6. 任务异常终止：继续跑就是烧 token
  if (finishState == AgentFinishState.failed) {
    return GoalDecision(
      action: GoalAction.pause,
      reason: 'task_failed',
      note: '上一轮任务失败，目标已暂停',
      goal: goal.copyWith(
        status: AgentGoalStatus.paused,
        note: '上一轮任务失败，目标已暂停',
        updatedAt: DateTime.now(),
      ),
    );
  }

  // 7. 无进展检测：这一轮一条命令都没执行，说明模型只是又想了想、没动手。
  //    曾用"步数是否比上一轮多"判定，但 stepIndex 是每个任务各自从 1 计的，
  //    跨轮比较必然误判——真机复拍里两轮各跑 4 条命令就被判成"连续无进展"暂停了。
  final progressed = commandsRun > 0;
  final noProgressRounds = progressed ? 0 : goal.noProgressRounds + 1;
  if (noProgressRounds >= 2) {
    return GoalDecision(
      action: GoalAction.pause,
      reason: 'no_progress',
      note: '连续 $noProgressRounds 轮没有新进展，目标已暂停',
      goal: goal.copyWith(
        status: AgentGoalStatus.paused,
        noProgressRounds: noProgressRounds,
        lastRoundCommands: commandsRun,
        note: '连续 $noProgressRounds 轮没有新进展，目标已暂停',
        updatedAt: DateTime.now(),
      ),
    );
  }

  // 8. 正常续跑：success（本轮收尾）与 interrupted（步数用满）都算有进展
  return GoalDecision(
    action: GoalAction.continueRound,
    reason: progressed ? 'progress' : 'continue',
    goal: goal.copyWith(
      roundsUsed: goal.roundsUsed + 1,
      lastRoundCommands: commandsRun,
      noProgressRounds: noProgressRounds,
      clearNote: true,
      updatedAt: DateTime.now(),
    ),
  );
}

/// 是否真的要把续跑任务排上去。三个 provider 侧的守卫，抽出来是为了可测：
///
/// - 目标必须仍然活跃（用户可能在决策与执行之间点了暂停）；
/// - 同一个终局任务只许续跑一次——取消与异常路径可能连着发出两个 finish 事件，
///   不去重就会一次结束起两个任务；
/// - 引擎正在跑就不抢跑（`startTask` 自己也会拒，但那里的拒绝会写成一条
///   "Agent 正在执行任务"的错误，用户看到的是莫名其妙的报错）。
bool shouldScheduleGoalRound({
  required AgentGoal? goal,
  required String? finishingTaskId,
  required String? alreadyContinuedTaskId,
  required bool engineRunning,
}) {
  if (goal?.isActive != true) return false;
  if (finishingTaskId != null && finishingTaskId == alreadyContinuedTaskId) {
    return false;
  }
  return !engineRunning;
}

/// 恢复目标后要不要立刻补起一轮。
///
/// 续跑只在任务终局时触发，而被取消/失败暂停的目标**已经没有在跑的任务了**。
/// 所以"恢复"若只把状态翻成 active，横幅会显示进行中却什么都不做——那是个假恢复。
bool shouldKickGoalRound({
  required bool goalActive,
  required bool isForegroundHost,
  required bool engineRunning,
  required bool connectionAlive,
}) =>
    goalActive && isForegroundHost && !engineRunning && connectionAlive;

/// 续跑任务的提示词。
///
/// 只带目标、剩余预算与"达成就声明"的约定，**不拼历史全文**：
/// 上下文由引擎自己维护，重复拼进去会白白撑爆窗口。
String buildGoalContinuationPrompt(AgentGoal goal) {
  final done = goal.roundsUsed + 1;
  return '【目标模式 · 自动续跑】第 $done/${goal.maxRounds} 轮\n'
      '目标：${goal.objective}\n\n'
      '请继续朝该目标推进。若你确认目标已经完全达成，'
      '只在「回答:」正文里单独一行写 $kGoalDoneMarker 并说明结果；'
      '这一行是给你的结论，**不是命令**，绝不能放进 命令: 块或工具参数里。'
      '未达成则正常执行下一步，不要提前结束。';
}
