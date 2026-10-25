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
