import 'dart:async';

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/agent_model.dart';
import '../models/operation_report.dart';
import '../models/token_usage.dart';
import '../models/plan_step.dart';
import '../utils/agent_ui_text.dart';
import 'plan_panel.dart';
import '../core/l10n_holder.dart';

/// 操作单：一轮 Agent 任务的结论 + 元数据 + 可折叠证据
///
/// 只负责结构，不负责构建证据内容；证据由调用方传入，避免把命令渲染逻辑
/// 复制到两个地方。
class OperationSheet extends StatelessWidget {
  final OperationReport report;
  final ThemeColors tc;

  /// 证据层按需构建：折叠时不创建命令/结果卡片，避免长会话 build 成本
  final Widget Function() evidenceBuilder;
  final Widget Function(String text, ThemeColors tc) markdownBuilder;
  final bool hasEvidence;

  /// 模型声明的执行清单；为空时回退到 report.plan
  final List<PlanStep>? plan;

  /// 已成功回滚的变更 id
  final Set<String> rolledBackChangeIds;

  /// 请求执行回滚（由页面负责主机连接、确认与执行）
  final void Function(OperationChange change, String? hostId)? onRollbackChange;

  /// 回滚执行中（禁用所有回滚按钮，避免重复执行）
  final bool rollbackBusy;

  /// 打开该主机的审计记录
  final VoidCallback? onOpenAudit;

  /// 中断/失败后继续任务（基于对话上下文，不自动重跑已完成步骤）
  final VoidCallback? onContinueOperation;

  /// 是否为当前进行中的这一轮；历史回合的过程层默认收起
  final bool isLiveTurn;

  /// 证据构成（`12 条命令 · 2 条推理 · 30 条系统日志`），由调用方按真实事件统计。
  /// 只报"12 条命令"时用户不知道点开是 12 行还是 1 万行。
  final String? evidenceSummary;

  /// 是否在结果层复述任务目标。
  /// 会话里目标就是上一条用户消息时，两段同样的大字叠在一起只是噪音；
  /// 由调用方比对后决定，独立展示时仍保留目标。
  final bool showGoal;

  /// 过程已经按时间顺序铺在正文流里时，底部不再出现「过程与证据」折叠。
  final bool showEvidence;

  /// 正文由调用方在结果卡之前渲染时，这里不再重复一遍。
  final bool showAnswerBody;

  /// 正文与结论合并渲染时，结果卡不再重复一段「结论」；
  /// 状态、指标、变更与建议下一步仍然保留。
  final bool showConclusion;

  /// 执行清单由调用方放到整条回答最底部时，这里不再插入。
  final bool showPlan;

  const OperationSheet({
    super.key,
    required this.report,
    required this.tc,
    required this.evidenceBuilder,
    required this.markdownBuilder,
    this.hasEvidence = true,
    this.plan,
    this.rolledBackChangeIds = const {},
    this.onRollbackChange,
    this.rollbackBusy = false,
    this.onOpenAudit,
    this.onContinueOperation,
    this.isLiveTurn = true,
    this.evidenceSummary,
    this.showGoal = true,
    this.showEvidence = true,
    this.showAnswerBody = true,
    this.showConclusion = true,
    this.showPlan = true,
  });

  @override
  Widget build(BuildContext context) {
    final ui = AgentUiText.of(context);
    final statusColor = _statusColor();
    final statusLabel = _statusLabel(ui);
    final planSteps = (plan != null && plan!.isNotEmpty) ? plan! : report.plan;
    final answerBody = _visibleAnswerBody;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 结果层：目标 + 结论 + 指标 + 状态合成一块。
        // 原来"目标头"和"结论卡"是两套容器，下面还跟着回答正文，同一件事讲三遍；
        // 合成一块后，第一眼看到的就是"这件事做成了什么"。
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: tc.agentCardFill,
            borderRadius: BorderRadius.circular(rCard),
            border: Border.all(color: tc.agentCardBorder, width: 1),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showGoal) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                report.goal.isEmpty
                                    ? ui.taskRecord
                                    : report.goal,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tc.textMain,
                                  fontSize: fBody,
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _statusPill(statusColor, statusLabel),
                          ],
                        ),
                        const SizedBox(height: pSmall),
                      ],
                      if (showConclusion) ...[
                        Row(
                          children: [
                            Text(
                              ui.conclusion,
                              style: TextStyle(
                                color: tc.textSub,
                                fontSize: fMicro,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(width: 6),
                            if (report.verified)
                              _badge(ui.verifiedEvidence, tc.ok)
                            else if (report.aiGenerated)
                              _badge(ui.aiConclusion, tc.textSub),
                            const Spacer(),
                            // 目标不复述时，状态要挪到这一行，否则卡片没有状态标记
                            if (!showGoal) ...[
                              _statusPill(statusColor, statusLabel),
                              const SizedBox(width: 6),
                            ],
                          ],
                        ),
                        const SizedBox(height: pXSmall),
                        markdownBuilder(
                          report.conclusion.isEmpty
                              ? UiText.t('任务已结束，详见执行记录。',
                                  'Task finished. See the execution record for details.')
                              : report.conclusion,
                          tc,
                        ),
                        // 结论走 Markdown，自带 4px 底距；这里再补 4，
                        // 视觉上就是 8，和"结论标签 → 正文"的 4 拉开一档
                        const SizedBox(height: pXSmall),
                      ],
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 结论整块隐藏时，状态胶囊落到这一行的最前面
                          if (!showGoal && !showConclusion) ...[
                            _statusPill(statusColor, statusLabel),
                            const SizedBox(width: pSmall),
                          ],
                          Expanded(child: _buildMetaLine(ui)),
                          // 继续任务贴着"失败"状态放：它原来是单独一行右对齐，
                          // 上下各 12px，结果在清单和过程之间留出一条空带
                          if (!report.isSuccess && onContinueOperation != null) ...[
                            const SizedBox(width: pSmall),
                            _buildContinueButton(ui),
                          ],
                        ],
                      ),
                      if (report.stateBadges.isNotEmpty) ...[
                        const SizedBox(height: pSmall),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children:
                              report.stateBadges.map(_buildStateBadge).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // 执行清单（模型声明）
        if (showPlan && planSteps.isNotEmpty) ...[
          const SizedBox(height: pModule),
          PlanPanel(
            steps: planSteps,
            tc: tc,
            // 历史回合只留进度一行，展开状态不跨回合记忆
            initiallyExpanded: isLiveTurn ? null : false,
            // 外间距由这里统一给，避免卡片自己带下边距导致节奏忽宽忽窄
            margin: EdgeInsets.zero,
          ),
        ],
        if (showPlan &&
            planSteps.isNotEmpty &&
            report.isSuccess &&
            planSteps.any((s) =>
                s.status == PlanStepStatus.inProgress ||
                s.status == PlanStepStatus.pending))
          Padding(
            padding: const EdgeInsets.only(top: pSmall),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber, size: 12, color: tc.warn),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    ui.planWarning,
                    style: TextStyle(
                      color: tc.warn,
                      fontSize: fMicro,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // 完整回答正文：与"结论 + 验证徽标"分开，避免徽标看起来像在给整篇正文背书
        if (showAnswerBody && answerBody != null)
          Padding(
            padding: const EdgeInsets.only(top: pModule),
            child: markdownBuilder(answerBody, tc),
          ),

        // 变更与回滚
        if (report.changes.isNotEmpty) ...[
          const SizedBox(height: pModule),
          Row(
            children: [
              Text(
                ui.changesAndRollback,
                style: TextStyle(
                  color: tc.textSub,
                  fontSize: fMicro,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                ui.itemsCount(report.changes.length),
                style: TextStyle(color: tc.textMuted, fontSize: fMicro),
              ),
              const Spacer(),
              if (onOpenAudit != null)
                GestureDetector(
                  onTap: onOpenAudit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.receipt_long, size: 11, color: tc.textSub),
                        const SizedBox(width: 3),
                        Text(
                          ui.auditLog,
                          style: TextStyle(
                            color: tc.textSub,
                            fontSize: fMicro,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: pXSmall + 2),
          ...report.changes.take(5).map(_buildChangeRow),
          if (report.changes.length > 5)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                ui.moreChanges(report.changes.length - 5),
                style: TextStyle(color: tc.textMuted, fontSize: fMicro),
              ),
            ),
        ],

        // 建议下一步
        if (report.nextActions.isNotEmpty) ...[
          const SizedBox(height: pModule),
          _NextActions(actions: report.nextActions, tc: tc),
        ],

        // 证据层：过程已经按时间顺序铺在正文里时整块省略
        if (showEvidence) ...[
          const SizedBox(height: pModule),
          _ExpandableEvidence(
            tc: tc,
            summary: evidenceSummary ?? _evidenceSummary(ui),
            details: report.details,
            markdownBuilder: markdownBuilder,
            hasEvidence: hasEvidence,
            evidenceBuilder: evidenceBuilder,
            failureCount: report.commandFailureCount,
            forceCollapsed: !isLiveTurn,
          ),
        ],
      ],
    );
  }

  /// 回答正文；与结论完全相同时不重复渲染
  String? get _visibleAnswerBody {
    final body = report.answerBody?.trim();
    if (body == null || body.isEmpty) return null;
    if (_sameText(body, report.conclusion)) return null;
    return body;
  }

  static bool _sameText(String a, String b) {
    String normalize(String s) => s
        .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalize(a) == normalize(b);
  }

  Color _statusColor() {
    switch (report.finishState) {
      case 'failed':
        return tc.error;
      case 'cancelled':
      case 'interrupted':
        return tc.warn;
      default:
        return tc.ok;
    }
  }

  String _statusLabel(AgentUiText ui) {
    switch (report.finishState) {
      case 'failed':
        return ui.failed;
      case 'cancelled':
        return ui.cancelled;
      case 'interrupted':
        return ui.interrupted;
      default:
        return ui.completed;
    }
  }

  Widget _buildMetaLine(AgentUiText ui) {
    final items = <Widget>[];
    void add(String text, Color color, {bool mono = false, double? maxWidth}) {
      final widget = Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: fMicro,
          fontFamily: mono ? 'JetBrainsMono' : null,
          fontFamilyFallback: mono ? kMonoFontFallback : null,
          fontWeight: FontWeight.w500,
        ),
      );
      items.add(maxWidth == null
          ? widget
          : ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: widget,
            ));
    }

    final host = report.hostId;
    if (host != null && host.isNotEmpty) {
      add(host == 'local' ? UiText.t('本地', 'Local') : host, tc.textSub, mono: true, maxWidth: 200);
    }
    add(_formatElapsed(report.elapsedSeconds, ui), tc.gold, mono: true);
    if (report.stepIndex > 0) add(ui.step(report.stepIndex), tc.textSub);
    if (report.commandCount > 0) {
      add(ui.commandCount(report.commandCount), tc.textSub);
      if (report.commandFailureCount > 0) {
        add(ui.failureCount(report.commandFailureCount), tc.error, mono: true);
      }
    }
    final changeCount = report.changes.isNotEmpty
        ? report.changes.length
        : report.changeRecordIds.length;
    if (changeCount > 0) add(ui.changesCount(changeCount), tc.textSub);

    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }

  Widget _buildStateBadge(OperationBadge badge) {
    final color = badge.level == 'success'
        ? tc.ok
        : badge.level == 'warning'
            ? tc.warn
            : tc.textSub;
    final icon = badge.level == 'success'
        ? Icons.check_circle_outline
        : badge.level == 'warning'
            ? Icons.error_outline
            : Icons.info_outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            badge.text,
            style: TextStyle(
              color: color,
              fontSize: fMicro,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChangeRow(OperationChange change) {
    final rolledBack = rolledBackChangeIds.contains(change.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tc.agentCardFill,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_changeIcon(change.type),
              size: 13, color: tc.gold.withValues(alpha: 0.9)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _changeTypeLabel(change.type),
                      style: TextStyle(
                        color: tc.gold,
                        fontSize: fMicro,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Tooltip(
                        message: change.command,
                        child: Text(
                          change.command,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tc.textBody,
                            fontSize: fMicro,
                            fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (change.hasDiff) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (change.additions != null)
                        Text(
                          '+${change.additions}',
                          style: TextStyle(
                            color: tc.ok,
                            fontSize: fMicro,
                            fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (change.additions != null && change.deletions != null)
                        const SizedBox(width: 6),
                      if (change.deletions != null)
                        Text(
                          '-${change.deletions}',
                          style: TextStyle(
                            color: tc.error,
                            fontSize: fMicro,
                            fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  rolledBack
                      ? UiText.t('已执行回滚', 'Rolled back')
                      : change.canRollback
                          ? L10n.str.ut_e36a5ac905(change.rollbackCommand ?? '')
                          : UiText.t('无自动回滚，建议使用执行前快照', 'No automatic rollback; use a pre-change snapshot'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: rolledBack
                        ? tc.ok
                        : change.canRollback
                            ? tc.textSub
                            : tc.warn,
                    fontSize: fMicro,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (rolledBack)
            _badge(UiText.t('已回滚', 'Rolled back'), tc.ok)
          else if (change.canRollback && onRollbackChange != null)
            _buildRollbackButton(change)
          else
            _badge(
              change.canRollback
                  ? UiText.t('可回滚', 'Rollback available')
                  : UiText.t('需人工', 'Manual'),
              change.canRollback ? tc.ok : tc.textMuted,
            ),
        ],
      ),
    );
  }

  Widget _buildRollbackButton(OperationChange change) {
    final enabled = !rollbackBusy;
    final color = enabled ? tc.ok : tc.textMuted;
    return GestureDetector(
      onTap:
          enabled ? () => onRollbackChange?.call(change, report.hostId) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(rXSmall),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.undo, size: 11, color: color),
            const SizedBox(width: 3),
            Text(
              rollbackBusy ? UiText.t('回滚中', 'Rolling back') : UiText.t('回滚', 'Rollback'),
              style: TextStyle(
                color: color,
                fontSize: fMicro,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _changeIcon(String type) {
    switch (type) {
      case 'install':
        return Icons.download_outlined;
      case 'uninstall':
        return Icons.delete_outline;
      case 'startService':
      case 'stopService':
      case 'restartService':
        return Icons.settings_outlined;
      case 'permission':
        return Icons.lock_outline;
      case 'fileOperation':
      case 'modifyConfig':
        return Icons.description_outlined;
      default:
        return Icons.build_outlined;
    }
  }

  String _changeTypeLabel(String type) {
    switch (type) {
      case 'install':
        return UiText.t('安装', 'Install');
      case 'uninstall':
        return UiText.t('卸载', 'Uninstall');
      case 'modifyConfig':
        return UiText.t('修改配置', 'Config change');
      case 'startService':
        return UiText.t('启动服务', 'Start service');
      case 'stopService':
        return UiText.t('停止服务', 'Stop service');
      case 'restartService':
        return UiText.t('重启服务', 'Restart service');
      case 'fileOperation':
        return UiText.t('文件操作', 'File operation');
      case 'permission':
        return UiText.t('权限修改', 'Permission change');
      default:
        return UiText.t('变更', 'Change');
    }
  }

  String _evidenceSummary(AgentUiText ui) {
    if (report.commandCount > 0) {
      return ui.commandCount(report.commandCount);
    }
    return ui.thinkingAndExecution;
  }

  Widget _buildContinueButton(AgentUiText ui) {
    return GestureDetector(
      onTap: onContinueOperation,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: tc.brand.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(rSmall),
          border: Border.all(color: tc.brand.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_outline, size: 12, color: tc.brand),
            const SizedBox(width: 4),
            Text(
              ui.continueTask,
              style: TextStyle(
                color: tc.brand,
                fontSize: fMicro,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusPill(Color color, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(rFull),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: fMicro,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: fMicro),
      ),
    );
  }

  static String _formatElapsed(int seconds, AgentUiText ui) {
    if (seconds <= 0) return ui.lessThanOneSecond;
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m < 60) return '${m}m${s.toString().padLeft(2, '0')}s';
    final h = m ~/ 60;
    return '${h}h${(m % 60).toString().padLeft(2, '0')}m';
  }
}

/// 下一步建议：超过 3 条先收成一行，其余按需展开
class _NextActions extends StatefulWidget {
  const _NextActions({required this.actions, required this.tc});

  final List<String> actions;
  final ThemeColors tc;

  @override
  State<_NextActions> createState() => _NextActionsState();
}

class _NextActionsState extends State<_NextActions> {
  static const _collapsedCount = 3;
  bool _showAll = false;

  Widget _chip(String action, ThemeColors tc) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tc.cardElevated,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.arrow_forward, size: 11, color: tc.brand),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              action,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: tc.textBody,
                  fontSize: fSmall,
                  height: 1.35,
                  fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final ui = AgentUiText.of(context);
    final visible = _showAll
        ? widget.actions
        : widget.actions.take(_collapsedCount).toList(growable: false);
    final hidden = widget.actions.length - visible.length;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final action in visible) _chip(action, tc),
        if (hidden > 0)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showAll = true),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(ui.moreActions(hidden),
                  style: TextStyle(color: tc.textSub, fontSize: fMicro)),
            ),
          ),
        if (hidden == 0 && _showAll && widget.actions.length > _collapsedCount)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _showAll = false),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(ui.collapse,
                  style: TextStyle(color: tc.textSub, fontSize: fMicro)),
            ),
          ),
      ],
    );
  }
}

class _ExpandableEvidence extends StatefulWidget {
  final ThemeColors tc;
  final String summary;
  final String? details;
  final Widget Function(String text, ThemeColors tc) markdownBuilder;
  final bool hasEvidence;
  final Widget Function() evidenceBuilder;

  /// 失败命令数：>0 时摘要行用警示色并显示失败数，但过程层仍保持收起，
  /// 避免把故障细节平铺到操作单下面；用户点开摘要即可看到全部证据。
  final int failureCount;

  /// 非当前轮的历史回合强制收起，避免打开旧会话满屏过程
  final bool forceCollapsed;

  const _ExpandableEvidence({
    required this.tc,
    required this.summary,
    required this.details,
    required this.markdownBuilder,
    required this.hasEvidence,
    required this.evidenceBuilder,
    this.failureCount = 0,
    this.forceCollapsed = false,
  });

  @override
  State<_ExpandableEvidence> createState() => _ExpandableEvidenceState();
}

class _ExpandableEvidenceState extends State<_ExpandableEvidence> {
  // 完成态与历史回合都默认收起，只留一行摘要：把 14 张命令卡平铺在操作单下面
  // 会把结论和执行清单挤到视口之外。失败信息仍由摘要行的警示色与失败数承担，
  // 用户需要细节时点一下即可，故障并没有被藏进"看不见"的地方。
  late bool _expanded = false;

  @override
  void didUpdateWidget(covariant _ExpandableEvidence oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 新一轮开始：上一轮被用户展开过的过程自动收起
    if (widget.forceCollapsed && !oldWidget.forceCollapsed) _expanded = false;
    // 这里不再因"中途出现失败"整层顶开：失败摘要行已经是警示色并带失败数，
    // 自动铺开全部证据与"完成态保持干净"冲突，且会把当前正在读的结论顶走。
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final ui = AgentUiText.of(context);
    final warn = widget.failureCount > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(rXSmall),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: warn ? tc.warn : tc.textSub,
                ),
                const SizedBox(width: 4),
                Text(
                  ui.processAndEvidence,
                  style: TextStyle(
                    // 只有失败计数上警示色：整行橙会让"有失败"变成"整块出事"
                    color: tc.textBody,
                    fontSize: fSmall,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '· ${widget.summary}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tc.textSub,
                      fontSize: fMicro,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (warn)
                  Text(
                    ui.failedCommands(widget.failureCount),
                    style: TextStyle(
                      color: tc.warn,
                      fontSize: fMicro,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          if (widget.details != null && widget.details!.trim().isNotEmpty) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 6, bottom: 6),
              padding: const EdgeInsets.all(pCompact),
              decoration: BoxDecoration(
                color: tc.agentCardFill,
                borderRadius: BorderRadius.circular(rCard),
                border: Border.all(color: tc.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ui.fullSummary,
                    style: TextStyle(
                      color: tc.textSub,
                      fontSize: fMicro,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  widget.markdownBuilder(widget.details!, tc),
                ],
              ),
            ),
          ],
          if (widget.hasEvidence)
            widget.evidenceBuilder()
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                ui.noEvidence,
                style: TextStyle(
                  color: tc.textSub,
                  fontSize: fSmall,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// 常驻运行条：目标 + 阶段 + 步数 + 计时 + 暂停/停止
/// 耗时文案（本文件里已有两份同规则的私有副本，新界面统一用这个）。
String _formatElapsedLabel(int seconds, AgentUiText ui) {
  if (seconds <= 0) return ui.lessThanOneSecond;
  if (seconds < 60) return '${seconds}s';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  if (m < 60) return '${m}m${s.toString().padLeft(2, '0')}s';
  final h = m ~/ 60;
  return '${h}h${(m % 60).toString().padLeft(2, '0')}m';
}

/// 指标项：轮 / token / 速率 / 缓存命中 / 上下文占用环。
///
/// 规则来自设计 §3.1.2——没有出处的数字整项不渲染，而不是渲染成 0。
/// 运行条与常驻指标条共用这一套：`≈` 与"缺数据不显示"这类判断各写一遍，
/// 两个界面迟早会互相矛盾。
List<Widget> buildMetricItems({
  required AgentTask task,
  required int? contextWindow,
  required AgentUiText ui,
  required ThemeColors tc,
  required int elapsedSeconds,
}) {
  final items = <Widget>[];
  void add(String text, Color color, {bool mono = false}) {
    items.add(Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color,
        fontSize: fMicro,
        fontFamily: mono ? 'JetBrainsMono' : null,
        fontFamilyFallback: mono ? kMonoFontFallback : null,
        fontWeight: FontWeight.w500,
      ),
    ));
  }

  if (task.rounds > 0) add(ui.roundsCount(task.rounds), tc.textSub);
  // 「步」= 请求 AI 的次数 + 命令执行次数（成功/失败/被拦截）+ 工具调用。
  // 「轮」是会话累计的任务轮次（用户提问、目标续跑各一轮），两者量纲不同：
  // 一轮里可能跑几十步，所以步数只会大于等于轮数。
  if (task.stepTotal > 0) add(ui.stepsCount(task.stepTotal), tc.textSub);
  if (task.tokenTotal > 0) {
    add(
      ui.tokensCount(formatTokenCount(task.tokenTotal),
          estimated: task.hasEstimatedTokens),
      tc.textSub,
      mono: true,
    );
    // 速率只在全是实测时给：估算 token 除以真实秒数会得到一个"看着像实测"的速率
    final wall =
        elapsedSeconds > 0 ? elapsedSeconds : (task.elapsedSeconds ?? 0);
    // 分母还要剔掉等待用户确认的墙钟 —— 那段时间引擎没在产出 token，
    // 算进去测的是人的反应速度（真机观察到 215 tok/s 掉到 174）。
    // 扣完为 0 说明这一轮几乎全在等人，此时整项不渲染，而不是显示 0 tok/s。
    final active = wall - task.confirmWaitSeconds;
    if (!task.hasEstimatedTokens && active > 0) {
      add(ui.tokPerSec(task.tokenTotal ~/ active), tc.textSub, mono: true);
    }
  }
  final cacheHit = task.cacheHitPercent;
  if (cacheHit != null) add(ui.cacheHit(cacheHit), tc.textSub);

  if (contextWindow != null && contextWindow > 0 && task.contextTokens > 0) {
    final raw = (task.contextTokens * 100 / contextWindow).round();
    final pct = raw < 0 ? 0 : (raw > 100 ? 100 : raw);
    final ringColor = pct >= 70 ? tc.warn : tc.textSub;
    items.add(Tooltip(
      message: ui.contextHint,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              value: pct / 100,
              strokeWidth: 2,
              color: ringColor,
            ),
          ),
          const SizedBox(width: 5),
          // 常驻指标条改为单行横向滚动后，父级给的是无界宽度，Flexible 在这种
          // 约束下会抛错；改用有界宽度 + ellipsis，窄面板也不会出现黄黑条纹。
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 92),
            child: Text(
              ui.contextUsed(pct),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ringColor,
                fontSize: fMicro,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    ));
  }
  return items;
}

/// 常驻指标条：任务进入终态后接管 `LiveOperationBar` 的位置。
///
/// 参照界面的底部模块是常驻的，而运行条只在 running / paused / waitingConfirm
/// 时出现；调用方按状态二选一渲染，所以同一组数字不会同时显示两遍。
class AgentMetricsBar extends StatelessWidget {
  final AgentTask task;
  final ThemeColors tc;
  final int? contextWindow;

  /// 运行中 = true。此时不重复渲染状态与用时 —— 输入框上方的运行条已经在说
  /// "跑到哪了"，底边这条只管数字。
  final bool running;

  const AgentMetricsBar({
    super.key,
    required this.task,
    required this.tc,
    this.contextWindow,
    this.running = false,
  });

  static String statusLabel(AgentStatus status, AgentUiText ui) {
    switch (status) {
      case AgentStatus.completed:
        return ui.completed;
      case AgentStatus.failed:
        return ui.failed;
      case AgentStatus.cancelled:
        return ui.cancelled;
      case AgentStatus.paused:
        return ui.paused;
      default:
        return ui.agentTask;
    }
  }

  static Color statusColor(ThemeColors tc, AgentStatus status) {
    switch (status) {
      case AgentStatus.completed:
        return tc.ok;
      case AgentStatus.failed:
        return tc.error;
      case AgentStatus.cancelled:
        return tc.textMuted;
      default:
        return tc.textSub;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = AgentUiText.of(context);
    final elapsed = task.elapsedSeconds ?? 0;
    // 贴窗口底边的细条：单行横向滚动，不做带边框的卡片、也不折行。
    // Wrap 在窄面板会把最后两项甩到第二行，指标条高度随之跳动；改成 Row +
    // 横向滚动后高度恒定，超出部分可横向拖看，窄面板也不会 RenderFlex overflow。
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (!running) ...[
              Text(
                statusLabel(task.status, ui),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: statusColor(tc, task.status),
                  fontSize: fMicro,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatElapsedLabel(elapsed, ui),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tc.gold,
                  fontSize: fMicro,
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: kMonoFontFallback,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 8),
            ],
            ..._spaced(buildMetricItems(
              task: task,
              contextWindow: contextWindow,
              ui: ui,
              tc: tc,
              elapsedSeconds: elapsed,
            )),
          ],
        ),
      ),
    );
  }

  /// 给指标项之间插固定间距；Row 里不能用 Wrap 的 spacing。
  static List<Widget> _spaced(List<Widget> items) {
    final out = <Widget>[];
    for (final w in items) {
      if (out.isNotEmpty) out.add(const SizedBox(width: 8));
      out.add(w);
    }
    return out;
  }
}

class LiveOperationBar extends StatefulWidget {
  final AgentTask? task;
  final AgentStatus status;
  final ThemeColors tc;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onStop;
  final VoidCallback? onOpenTerminal;
  final List<PlanStep> plan;

  const LiveOperationBar({
    super.key,
    required this.task,
    required this.status,
    required this.tc,
    this.onPause,
    this.onResume,
    this.onStop,
    this.onOpenTerminal,
    this.plan = const [],
  });

  @override
  State<LiveOperationBar> createState() => _LiveOperationBarState();
}

class _LiveOperationBarState extends State<LiveOperationBar> {
  Timer? _ticker;

  bool get _isRunning =>
      widget.status == AgentStatus.thinking ||
      widget.status == AgentStatus.executing ||
      widget.status == AgentStatus.waitingConfirm;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant LiveOperationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _syncTicker();
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (_isRunning) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    if (task == null) return const SizedBox.shrink();
    final tc = widget.tc;
    final ui = AgentUiText.of(context);
    final statusColor = _statusColor(tc);
    final elapsed = DateTime.now().difference(task.createdAt).inSeconds;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tc.agentCardFill,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: tc.border),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.goal.isEmpty ? ui.agentTask : task.goal,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tc.textMain,
                    fontSize: fSmall,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                _buildLiveMeta(task, elapsed),
              ],
            ),
          ),
          _iconButton(
            icon: Icons.terminal,
            tooltip: ui.openInTerminal,
            color: tc.textSub,
            onTap: widget.onOpenTerminal,
          ),
          if (widget.status == AgentStatus.paused)
            _iconButton(
              icon: Icons.play_arrow,
              tooltip: ui.resume,
              color: tc.ok,
              onTap: widget.onResume,
            )
          else if (_isRunning)
            _iconButton(
              icon: Icons.pause,
              tooltip: ui.pause,
              color: tc.textSub,
              onTap: widget.onPause,
            ),
          _iconButton(
            icon: Icons.stop,
            tooltip: ui.stop,
            color: tc.error,
            onTap: widget.onStop,
          ),
        ],
      ),
    );
  }

  Widget _buildLiveMeta(AgentTask task, int elapsed) {
    final tc = widget.tc;
    final ui = AgentUiText.of(context);
    final items = <Widget>[];
    void add(String text, Color color, {bool mono = false}) {
      items.add(Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: fMicro,
          fontFamily: mono ? 'JetBrainsMono' : null,
          fontFamilyFallback: mono ? kMonoFontFallback : null,
          fontWeight: FontWeight.w500,
        ),
      ));
    }

    final phase = (task.phase != null && task.phase!.trim().isNotEmpty)
        ? ui.phase(task.phase)
        : _phaseLabelForStatus(ui);
    add(phase, tc.textSub);
    // 不再显示 `第 N 步`（引擎循环计数）：底边条的 `N 步` 是执行过的命令数，
    // 同一屏出现两个都叫"步"、含义不同的数字，等于让用户去猜哪个是真的。
    add(_formatElapsed(elapsed, ui), tc.gold, mono: true);
    // 数字（轮/步/tok/速率/缓存/占用环）不在这条里：它们统一渲染在输入框之下的
    // 底边状态条（[AgentMetricsBar]），运行中与终态共用同一位置，任务跑完数字
    // 不会换地方。这里只留"跑到哪了"。
    if (task.successCount > 0 || task.failureCount > 0) {
      add(ui.successCount(task.successCount), tc.textSub);
      if (task.failureCount > 0) {
        add(ui.failureCount(task.failureCount), tc.error, mono: true);
      }
    }
    if (widget.plan.isNotEmpty) {
      final done = widget.plan.where((s) => s.isDone).length;
      add(ui.planProgress(done, widget.plan.length), tc.textSub);
    }
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }

  String _phaseLabelForStatus(AgentUiText ui) {
    switch (widget.status) {
      case AgentStatus.thinking:
        return ui.thinking;
      case AgentStatus.executing:
        return ui.executing;
      case AgentStatus.waitingConfirm:
        return ui.waitingConfirm;
      case AgentStatus.paused:
        return ui.paused;
      case AgentStatus.completed:
        return ui.completed;
      case AgentStatus.failed:
        return ui.failed;
      case AgentStatus.cancelled:
        return ui.cancelled;
      case AgentStatus.idle:
        return ui.idle;
    }
  }

  Color _statusColor(ThemeColors tc) {
    switch (widget.status) {
      case AgentStatus.thinking:
      case AgentStatus.executing:
        return tc.brand;
      case AgentStatus.waitingConfirm:
        return tc.warn;
      case AgentStatus.paused:
        return tc.textMuted;
      case AgentStatus.failed:
        return tc.error;
      case AgentStatus.cancelled:
        return tc.warn;
      case AgentStatus.completed:
        return tc.ok;
      case AgentStatus.idle:
        return tc.textMuted;
    }
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    VoidCallback? onTap,
  }) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 17, color: color),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
    );
  }

  static String _formatElapsed(int seconds, AgentUiText ui) {
    if (seconds <= 0) return ui.lessThanOneSecond;
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m < 60) return '${m}m${s.toString().padLeft(2, '0')}s';
    final h = m ~/ 60;
    return '${h}h${(m % 60).toString().padLeft(2, '0')}m';
  }
}
