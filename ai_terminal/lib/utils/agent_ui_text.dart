import 'package:flutter/widgets.dart';

/// Agent 操作单/计划面板的轻量文案。
///
/// 这些标签是 v1.3.7 新增界面，尚未进入 14 语言 ARB；先覆盖中文/英文，
/// 其它语言回退英文，避免英文界面出现中英混排。
class AgentUiText {
  final bool zh;

  const AgentUiText(this.zh);

  factory AgentUiText.of(BuildContext context) {
    return AgentUiText(
      Localizations.localeOf(context).languageCode == 'zh',
    );
  }

  String get taskRecord => zh ? '任务记录' : 'Task record';
  String get completed => zh ? '完成' : 'Completed';
  String get failed => zh ? '失败' : 'Failed';
  String get cancelled => zh ? '已取消' : 'Cancelled';
  String get interrupted => zh ? '已中断' : 'Interrupted';

  String get planTitle => zh ? '执行清单' : 'Execution Plan';
  String get planByAi => zh ? 'AI 计划' : 'AI plan';
  String get planWarning => zh
      ? '计划仍有未收尾步骤，请核对是否全部完成'
      : 'Some plan steps are still open. Please verify the task is complete.';

  String get conclusion => zh ? '结论' : 'Conclusion';
  String get verifiedEvidence => zh ? '有验证证据' : 'Verified evidence';
  String get aiConclusion => zh ? 'AI 结论' : 'AI conclusion';
  String get continueTask => zh ? '继续任务' : 'Continue task';
  String get operationCopied => zh ? '操作单已复制' : 'Operation sheet copied';

  String get changesAndRollback => zh ? '变更与回滚' : 'Changes & rollback';
  String get auditLog => zh ? '审计记录' : 'Audit log';
  String itemsCount(int n) => zh ? '$n 项' : '$n items';
  String changesCount(int n) => zh ? '$n 项变更' : '$n changes';
  String moreChanges(int n) =>
      zh ? '还有 $n 项变更，详见审计记录' : '$n more changes — see audit log';

  String get processAndEvidence => zh ? '过程与证据' : 'Process & evidence';
  String get fullSummary => zh ? '完整总结' : 'Full summary';
  String get noEvidence =>
      zh ? '没有可展开的执行记录' : 'No execution records to expand';

  String step(int n) => zh ? '第 $n 步' : 'Step $n';
  String commandCount(int n) =>
      zh ? '$n 条命令' : (n == 1 ? '1 command' : '$n commands');
  String get thinkingAndExecution =>
      zh ? '思考与执行记录' : 'Thinking & execution log';
  String get lessThanOneSecond => zh ? '不足 1s' : '<1s';
  String get agentTask => zh ? 'Agent 任务' : 'Agent task';
  String get openInTerminal => zh ? '在终端查看' : 'Open in terminal';
  String get resume => zh ? '恢复' : 'Resume';
  String get pause => zh ? '暂停' : 'Pause';
  String get stop => zh ? '停止' : 'Stop';
  String get thinking => zh ? '思考中' : 'Thinking';
  String get executing => zh ? '执行中' : 'Executing';
  String get waitingConfirm => zh ? '等待确认' : 'Waiting for confirmation';
  String get paused => zh ? '已暂停' : 'Paused';
  String get idle => zh ? '就绪' : 'Idle';
  String successCount(int n) => zh ? '$n 成功' : '$n succeeded';
  String planProgress(int done, int total) =>
      zh ? '计划 $done/$total' : 'Plan $done/$total';

  String get toolCall => zh ? '工具调用' : 'Tool call';
  String get blocked => zh ? '已拦截' : 'Blocked';
  String get needsConfirm => zh ? '需确认' : 'Needs confirmation';
  String get executedLabel => zh ? '已运行' : 'Executed';
  String get executable => zh ? '可执行' : 'Ready';
  String get riskBlocked =>
      zh ? '该命令已被安全策略拦截' : 'Blocked by the safety policy';
  String get changeImpact => zh ? '变更影响' : 'Change impact';
  String get confirmImpact => zh ? '执行前请确认影响' : 'Review impact before running';
  String riskPrefix(String reason) => zh ? '风险：$reason' : 'Risk: $reason';
  String rollbackPrefix(String command) =>
      zh ? '回滚：$command' : 'Rollback: $command';
  String get noRollbackSnapshot =>
      zh ? '回滚：无自动回滚，建议先快照' : 'Rollback: no automatic rollback; snapshot first';
  String get cancel => zh ? '取消' : 'Cancel';
  String get confirmExecute => zh ? '确认执行' : 'Run';

  /// 引擎阶段是中文常量；英文环境映射到对应英文。
  String phase(String? raw) {
    if (zh) return raw ?? thinking;
    const map = {
      '理解需求': 'Understanding request',
      '思考中': 'Thinking',
      '执行命令': 'Executing command',
      '等待确认': 'Waiting for confirmation',
      '验证结果': 'Verifying result',
      '等待选择': 'Waiting for choice',
      '执行工具': 'Running tool',
      '整理结论': 'Summarizing',
      '执行失败': 'Failed',
      '已取消': 'Cancelled',
      '已暂停': 'Paused',
      '继续执行': 'Resuming',
    };
    return map[raw] ?? raw ?? thinking;
  }

  String failureLabel(String? kind) {
    if (zh) {
      switch (kind) {
        case 'disconnected': return '连接已断开';
        case 'timeout': return '执行超时';
        case 'permissionDenied': return '权限不足';
        case 'interactivePrompt': return '等待输入';
        case 'syntaxError': return '命令语法错误';
        case 'cancelled': return '已取消';
        default: return failed;
      }
    }
    switch (kind) {
      case 'disconnected': return 'Disconnected';
      case 'timeout': return 'Timed out';
      case 'permissionDenied': return 'Permission denied';
      case 'interactivePrompt': return 'Waiting for input';
      case 'syntaxError': return 'Syntax error';
      case 'cancelled': return 'Cancelled';
      default: return failed;
    }
  }

  String? failureHint(String? kind) {
    if (zh) {
      switch (kind) {
        case 'disconnected': return '连接已断开。建议先重连服务器，再重试本步。';
        case 'timeout': return '执行超时。建议延长超时，或把命令拆小后重试。';
        case 'permissionDenied': return '权限不足。建议使用 sudo 重试，或更换有权限的用户。';
        case 'interactivePrompt': return '命令在等待输入。建议改用非交互参数（如 -y / --batch）后重试。';
        case 'syntaxError': return '命令语法错误，未执行。建议修正命令后重试。';
        case 'cancelled': return '执行已取消。可以重新发起本步。';
        case 'unknown': return '执行失败。建议查看输出后修正并重试。';
        default: return null;
      }
    }
    switch (kind) {
      case 'disconnected':
        return 'Connection lost. Reconnect the server, then retry this step.';
      case 'timeout':
        return 'Command timed out. Increase the timeout or split it into smaller steps.';
      case 'permissionDenied':
        return 'Permission denied. Retry with sudo or use an account with the required access.';
      case 'interactivePrompt':
        return 'The command is waiting for input. Use non-interactive flags such as -y or --batch.';
      case 'syntaxError':
        return 'The command was not executed due to a syntax error. Fix it and retry.';
      case 'cancelled':
        return 'Execution was cancelled. You can start this step again.';
      case 'unknown':
        return 'Execution failed. Review the output, fix the command and retry.';
      default:
        return null;
    }
  }

  String get resultSuccess => zh ? '执行成功' : 'Succeeded';
  String exitCode(int n) => zh ? '退出码 $n' : 'Exit $n';
  String outputLines(int n) => zh ? '$n 行' : '$n lines';
  String truncated([int? chars]) => chars == null
      ? (zh ? '已截断' : 'Truncated')
      : (zh ? '已截断 $chars 字符' : 'Truncated · $chars chars');
  String failureCount(int n) => zh ? '$n 失败' : '$n failed';

  String planCounts({
    required int total,
    required int completed,
    required int inProgress,
    required int failed,
    required int skipped,
    required int pending,
  }) {
    final parts = <String>[
      zh ? '$total 项' : '$total items',
      zh ? '$completed 完成' : '$completed done',
    ];
    if (inProgress > 0) {
      parts.add(zh ? '$inProgress 进行中' : '$inProgress in progress');
    }
    if (failed > 0) parts.add(zh ? '$failed 失败' : '$failed failed');
    if (skipped > 0) parts.add(zh ? '$skipped 跳过' : '$skipped skipped');
    if (pending > 0) parts.add(zh ? '$pending 待处理' : '$pending pending');
    return parts.join(' · ');
  }

  String expandAll(int n) => zh ? '展开全部 $n 项' : 'Show all $n';
}
