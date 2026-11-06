import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_model.dart';
import '../models/operation_report.dart';
import '../models/token_usage.dart';
import '../models/plan_step.dart';
import '../utils/agent_ui_text.dart';
import '../utils/conversation_export.dart';
import 'plan_panel.dart';
import '../core/app_toast.dart';

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
        // 目标头
        Container(
          padding: const EdgeInsets.fromLTRB(0, 2, 0, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 34,
                margin: const EdgeInsets.only(top: 2),
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
                    Text(
                      report.goal.isEmpty ? ui.taskRecord : report.goal,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tc.textMain,
                        fontSize: fBody,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildMetaLine(ui),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(rFull),
                  border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: fMicro,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),

        // 执行清单（模型声明）
        if (planSteps.isNotEmpty)
          PlanPanel(
            steps: planSteps,
            tc: tc,
            // 历史回合只留进度一行，展开状态不跨回合记忆
            initiallyExpanded: isLiveTurn ? null : false,
          ),
        if (planSteps.isNotEmpty &&
            report.isSuccess &&
            planSteps.any((s) =>
                s.status == PlanStepStatus.inProgress ||
                s.status == PlanStepStatus.pending))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
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

        // 结论
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: tc.dataCard,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: tc.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                  GestureDetector(
                    onTap: () => _copyConclusion(context),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.copy, size: 12, color: tc.textSub),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              markdownBuilder(
                report.conclusion.isEmpty ? '任务已结束，详见执行记录。' : report.conclusion,
                tc,
              ),
              // 回答正文是结论层的正文，不是证据：放在结论卡片下方直接可见，
              // 折叠进"过程与证据"会让用户看不到 Agent 到底答了什么。
              if (report.stateBadges.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: report.stateBadges.map(_buildStateBadge).toList(),
                ),
              ],
            ],
          ),
        ),

        // 完整回答正文：与"结论 + 验证徽标"分开，避免徽标看起来像在给整篇正文背书
        if (answerBody != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: markdownBuilder(answerBody, tc),
          ),

        // 中断/失败后继续
        if (!report.isSuccess && onContinueOperation != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: onContinueOperation,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: tc.brand.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(rXSmall),
                  border: Border.all(color: tc.brand.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_circle_outline, size: 13, color: tc.brand),
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
            ),
          ),
        ],

        // 变更与回滚
        if (report.changes.isNotEmpty) ...[
          const SizedBox(height: 10),
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
          const SizedBox(height: 4),
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
          const SizedBox(height: 8),
          _NextActions(actions: report.nextActions, tc: tc),
        ],

        const SizedBox(height: 6),

        // 证据层
        _ExpandableEvidence(
          tc: tc,
          summary: _evidenceSummary(ui),
          details: report.details,
          markdownBuilder: markdownBuilder,
          hasEvidence: hasEvidence,
          evidenceBuilder: evidenceBuilder,
          failureCount: report.commandFailureCount,
          forceCollapsed: !isLiveTurn,
        ),
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

  void _copyConclusion(BuildContext context) {
    Clipboard.setData(ClipboardData(text: formatOperationReportCopy(report)));
    clearTopToast();
    showTopSnackBar(context, 
      SnackBar(
        content: Text(
          AgentUiText.of(context).operationCopied,
          style: const TextStyle(fontSize: fSmall),
        ),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
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
      add(host == 'local' ? '本地' : host, tc.textSub, mono: true, maxWidth: 200);
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
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: tc.dataCard,
        borderRadius: BorderRadius.circular(rXSmall),
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
                      ? '已执行回滚'
                      : change.canRollback
                          ? '回滚：${change.rollbackCommand}'
                          : '无自动回滚，建议使用执行前快照',
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
            _badge('已回滚', tc.ok)
          else if (change.canRollback && onRollbackChange != null)
            _buildRollbackButton(change)
          else
            _badge(
              change.canRollback ? '可回滚' : '需人工',
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
              rollbackBusy ? '回滚中' : '回滚',
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
        return '安装';
      case 'uninstall':
        return '卸载';
      case 'modifyConfig':
        return '修改配置';
      case 'startService':
        return '启动服务';
      case 'stopService':
        return '停止服务';
      case 'restartService':
        return '重启服务';
      case 'fileOperation':
        return '文件操作';
      case 'permission':
        return '权限修改';
      default:
        return '变更';
    }
  }

  String _evidenceSummary(AgentUiText ui) {
    if (report.commandCount > 0) {
      return ui.commandCount(report.commandCount);
    }
    return ui.thinkingAndExecution;
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

  /// 失败命令数：>0 时默认展开并给警示色——把故障藏进一次点击里，用户会以为任务顺利
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
  late bool _expanded = widget.failureCount > 0;

  @override
  void didUpdateWidget(covariant _ExpandableEvidence oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 新一轮开始：上一轮被用户展开过的过程自动收起
    if (widget.forceCollapsed && !oldWidget.forceCollapsed) _expanded = false;
    // 中途出现失败：立刻把证据层顶开，不用等用户去点
    if (oldWidget.failureCount == 0 && widget.failureCount > 0) _expanded = true;
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
            padding: const EdgeInsets.symmetric(vertical: 6),
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
                    color: warn ? tc.warn : tc.textBody,
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
              margin: const EdgeInsets.only(top: 4, bottom: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: tc.dataCard,
                borderRadius: BorderRadius.circular(rSmall),
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
  // 「步」= 真正执行过的命令/工具数，不是引擎循环计数（stepIndex）。
  // 循环计数与「轮」几乎相等（一轮一次调用），并排显示等于同一件事说两遍；
  // 参考界面的 `11 轮 418 步` 里那个大数就是执行数。
  final executedSteps = task.successCount + task.failureCount;
  if (executedSteps > 0) add(ui.stepsCount(executedSteps), tc.textSub);
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
          // 窄面板里这一项必须能缩：Wrap 给子项的是"整行宽度"上限，
          // 而 min-size Row 里的 Text 若不可缩，就会把整行顶出去（测试里以
          // RenderFlex overflowed 暴露，真机上会是黄黑条纹）
          Flexible(
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
    // 贴窗口底边的细条，不做带边框的卡片：这行在输入框之下，再套一层框会在面板
    // 底部出现"框中框"。
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (!running) ...[
            Text(
              statusLabel(task.status, ui),
              style: TextStyle(
                color: statusColor(tc, task.status),
                fontSize: fMicro,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              _formatElapsedLabel(elapsed, ui),
              style: TextStyle(
                color: tc.gold,
                fontSize: fMicro,
                fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          ...buildMetricItems(
            task: task,
            contextWindow: contextWindow,
            ui: ui,
            tc: tc,
            elapsedSeconds: elapsed,
          ),
        ],
      ),
    );
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
        color: tc.card,
        borderRadius: BorderRadius.circular(rSmall),
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
