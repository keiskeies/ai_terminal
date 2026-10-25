import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_event.dart';
import '../models/agent_model.dart';
import '../models/operation_report.dart';
import '../models/plan_step.dart';
import '../utils/agent_ui_text.dart';
import 'plan_panel.dart';

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
  });

  @override
  Widget build(BuildContext context) {
    final ui = AgentUiText.of(context);
    final statusColor = _statusColor();
    final statusLabel = _statusLabel(ui);
    final planSteps = (plan != null && plan!.isNotEmpty) ? plan! : report.plan;

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
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(rFull),
                  border:
                      Border.all(color: statusColor.withValues(alpha: 0.3)),
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
        if (planSteps.isNotEmpty) PlanPanel(steps: planSteps, tc: tc),
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
            color: tc.card,
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
              if (report.stateBadges.isNotEmpty) ...[
                const SizedBox(height: 8),
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
                    Icon(Icons.play_circle_outline,
                        size: 13, color: tc.brand),
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
                        Icon(Icons.receipt_long,
                            size: 11, color: tc.textSub),
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
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: report.nextActions
                .map((action) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
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
                            child: Icon(Icons.arrow_forward,
                                size: 11, color: tc.brand),
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
                    ))
                .toList(),
          ),
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
        ),
      ],
    );
  }

  void _copyConclusion(BuildContext context) {
    final buffer = StringBuffer();
    if (report.goal.trim().isNotEmpty) {
      buffer.writeln('目标：${report.goal.trim()}');
    }
    buffer.writeln('结论：${report.conclusion.trim()}');
    if (report.changes.isNotEmpty) {
      buffer.writeln('变更：');
      for (final change in report.changes) {
        final rollback = change.canRollback
            ? '（可回滚：${change.rollbackCommand}）'
            : '（无自动回滚）';
        buffer.writeln('- ${change.command}$rollback');
      }
    }
    Clipboard.setData(ClipboardData(text: buffer.toString().trimRight()));
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
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
      add(host == 'local' ? '本地' : host, tc.textSub,
          mono: true, maxWidth: 200);
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
        color: tc.cardElevated,
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
                            fontFamily: 'JetBrainsMono',
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
                            fontFamily: 'JetBrainsMono',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (change.additions != null &&
                          change.deletions != null)
                        const SizedBox(width: 6),
                      if (change.deletions != null)
                        Text(
                          '-${change.deletions}',
                          style: TextStyle(
                            color: tc.error,
                            fontSize: fMicro,
                            fontFamily: 'JetBrainsMono',
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
      onTap: enabled
          ? () => onRollbackChange?.call(change, report.hostId)
          : null,
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

class _ExpandableEvidence extends StatefulWidget {
  final ThemeColors tc;
  final String summary;
  final String? details;
  final Widget Function(String text, ThemeColors tc) markdownBuilder;
  final bool hasEvidence;
  final Widget Function() evidenceBuilder;

  const _ExpandableEvidence({
    required this.tc,
    required this.summary,
    required this.details,
    required this.markdownBuilder,
    required this.hasEvidence,
    required this.evidenceBuilder,
  });

  @override
  State<_ExpandableEvidence> createState() => _ExpandableEvidenceState();
}

class _ExpandableEvidenceState extends State<_ExpandableEvidence> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final ui = AgentUiText.of(context);
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
                  color: tc.textSub,
                ),
                const SizedBox(width: 4),
                Text(
                  ui.processAndEvidence,
                  style: TextStyle(
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
                color: tc.card,
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

/// 运行态事件折叠：只展示最近若干事件，更早的收成一行摘要
///
/// 终态有 report 时走 OperationSheet 的证据折叠；这里覆盖"仍在运行、
/// 没有 report"的窗口，避免每多一步就把整屏历史卡片重新铺开。
class CollapsibleEventStream extends StatefulWidget {
  final List<AgentEvent> events;
  final ThemeColors tc;
  final bool isRunning;
  final Widget Function(List<AgentEvent> events) builder;
  final int maxVisible;

  const CollapsibleEventStream({
    super.key,
    required this.events,
    required this.tc,
    required this.isRunning,
    required this.builder,
    this.maxVisible = 8,
  });

  @override
  State<CollapsibleEventStream> createState() => _CollapsibleEventStreamState();
}

class _CollapsibleEventStreamState extends State<CollapsibleEventStream> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final total = widget.events.length;
    final collapsible = widget.isRunning && total > widget.maxVisible;
    if (!collapsible) {
      return widget.builder(widget.events);
    }

    if (_expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _toggle('收起过程', Icons.expand_less),
          widget.builder(widget.events),
        ],
      );
    }

    // 从命令边界开始截取，避免把 result 和它的 command 拆开
    var start = total - widget.maxVisible;
    while (start < total && !widget.events[start].isCommand) {
      start++;
    }
    if (start >= total) start = total - widget.maxVisible;
    final visible = widget.events.sublist(start);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _toggle(_summary(start), Icons.chevron_right),
        widget.builder(visible),
      ],
    );
  }

  Widget _toggle(String text, IconData icon) {
    final tc = widget.tc;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(rXSmall),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(icon, size: 15, color: tc.textMuted),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: tc.textSub, fontSize: fMicro),
              ),
            ),
            Text(
              _expanded ? '收起' : '完整过程',
              style: TextStyle(color: tc.textSub, fontSize: fMicro),
            ),
          ],
        ),
      ),
    );
  }

  String _summary(int visibleStart) {
    final results = widget.events.where((e) => e.isResult).toList();
    final success = results.where((e) => e.success == true).length;
    final failed = results.length - success;
    final hidden = visibleStart;
    final parts = <String>['更早 $hidden 个事件已折叠'];
    if (results.isNotEmpty) {
      parts.add('$success 成功${failed > 0 ? " · $failed 失败" : ""}');
    }
    return parts.join(' · ');
  }
}

/// 常驻运行条：目标 + 阶段 + 步数 + 计时 + 暂停/停止
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
          fontWeight: FontWeight.w500,
        ),
      ));
    }

    final phase = (task.phase != null && task.phase!.trim().isNotEmpty)
        ? ui.phase(task.phase)
        : _phaseLabelForStatus(ui);
    add(phase, tc.textSub);
    if (task.stepIndex > 0) add(ui.step(task.stepIndex), tc.textSub);
    add(_formatElapsed(elapsed, ui), tc.gold, mono: true);
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
