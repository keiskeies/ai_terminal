import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_event.dart';
import '../models/agent_model.dart';
import '../models/operation_report.dart';
import '../models/plan_step.dart';
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
    final statusColor = _statusColor();
    final statusLabel = _statusLabel();
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
                      report.goal.isEmpty ? '任务记录' : report.goal,
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
                    Text(
                      _metaItems().join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tc.textMuted,
                        fontSize: fMicro,
                      ),
                    ),
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
                const Icon(Icons.warning_amber, size: 12, color: cWarning),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '计划仍有未收尾步骤，请核对是否全部完成',
                    style: TextStyle(
                      color: cWarning,
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
            color: tc.terminalBg.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: tc.border.withValues(alpha: 0.6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '结论',
                    style: TextStyle(
                      color: tc.textMuted,
                      fontSize: fMicro,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (report.verified)
                    _badge('有验证证据', cSuccess)
                  else if (report.aiGenerated)
                    _badge('AI 结论', tc.textMuted),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _copyConclusion(context),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.copy, size: 12, color: tc.textMuted),
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
                  color: cPrimary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(rXSmall),
                  border: Border.all(color: cPrimary.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.play_circle_outline,
                        size: 13, color: cPrimary),
                    const SizedBox(width: 4),
                    Text(
                      '继续任务',
                      style: TextStyle(
                        color: cPrimary,
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
                '变更与回滚',
                style: TextStyle(
                  color: tc.textMuted,
                  fontSize: fMicro,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${report.changes.length} 项',
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
                          '审计记录',
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
                '还有 ${report.changes.length - 5} 项变更，详见审计记录',
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
                        color: tc.surface,
                        borderRadius: BorderRadius.circular(rSmall),
                        border: Border.all(color: tc.border),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.arrow_forward,
                              size: 11, color: tc.textMuted),
                          const SizedBox(width: 4),
                          Text(
                            action,
                            style:
                                TextStyle(color: tc.textSub, fontSize: fSmall),
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
          summary: _evidenceSummary(),
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
      const SnackBar(
        content: Text('操作单已复制', style: TextStyle(fontSize: fSmall)),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.all(16),
      ),
    );
  }

  Color _statusColor() {
    switch (report.finishState) {
      case 'failed':
        return cDanger;
      case 'cancelled':
      case 'interrupted':
        return cWarning;
      default:
        return cSuccess;
    }
  }

  String _statusLabel() {
    switch (report.finishState) {
      case 'failed':
        return '失败';
      case 'cancelled':
        return '已取消';
      case 'interrupted':
        return '已中断';
      default:
        return '完成';
    }
  }

  List<String> _metaItems() {
    final items = <String>[];
    final host = report.hostId;
    if (host != null && host.isNotEmpty) {
      items.add(host == 'local' ? '本地' : host);
    }
    items.add(_formatElapsed(report.elapsedSeconds));
    if (report.stepIndex > 0) items.add('第 ${report.stepIndex} 步');
    if (report.commandCount > 0) {
      items.add(report.commandFailureCount > 0
          ? '${report.commandCount} 条命令 · ${report.commandFailureCount} 失败'
          : '${report.commandCount} 条命令');
    }
    final changeCount = report.changes.isNotEmpty
        ? report.changes.length
        : report.changeRecordIds.length;
    if (changeCount > 0) {
      items.add('$changeCount 项变更');
    }
    return items;
  }

  Widget _buildStateBadge(OperationBadge badge) {
    final color = badge.level == 'success'
        ? cSuccess
        : badge.level == 'warning'
            ? cWarning
            : tc.textMuted;
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
        color: tc.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: tc.border.withValues(alpha: 0.7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_changeIcon(change.type),
              size: 13, color: cWarning.withValues(alpha: 0.9)),
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
                        color: cWarning,
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
                            color: cSuccess,
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
                            color: cDanger,
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
                        ? cSuccess
                        : change.canRollback
                            ? tc.textMuted
                            : cWarning,
                    fontSize: fMicro,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (rolledBack)
            _badge('已回滚', cSuccess)
          else if (change.canRollback && onRollbackChange != null)
            _buildRollbackButton(change)
          else
            _badge(
              change.canRollback ? '可回滚' : '需人工',
              change.canRollback ? cSuccess : tc.textMuted,
            ),
        ],
      ),
    );
  }

  Widget _buildRollbackButton(OperationChange change) {
    final enabled = !rollbackBusy;
    final color = enabled ? cSuccess : tc.textMuted;
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

  String _evidenceSummary() {
    if (report.commandCount > 0) {
      return '${report.commandCount} 条命令';
    }
    return '思考与执行记录';
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

  static String _formatElapsed(int seconds) {
    if (seconds <= 0) return '不足 1s';
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
                  color: tc.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  '过程与证据',
                  style: TextStyle(
                    color: tc.textSub,
                    fontSize: fSmall,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '· ${widget.summary}',
                  style: TextStyle(color: tc.textMuted, fontSize: fMicro),
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
                color: tc.terminalBg.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(rSmall),
                border: Border.all(color: tc.border.withValues(alpha: 0.6)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '完整总结',
                    style: TextStyle(
                      color: tc.textMuted,
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
                '没有可展开的执行记录',
                style: TextStyle(color: tc.textMuted, fontSize: fSmall),
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
                style: TextStyle(color: tc.textMuted, fontSize: fMicro),
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
    final statusColor = _statusColor(tc);
    final elapsed = DateTime.now().difference(task.createdAt).inSeconds;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tc.surface,
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
                  task.goal.isEmpty ? 'Agent 任务' : task.goal,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tc.textMain,
                    fontSize: fSmall,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _metaText(task, elapsed),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                ),
              ],
            ),
          ),
          _iconButton(
            icon: Icons.terminal,
            tooltip: '在终端查看',
            color: tc.textSub,
            onTap: widget.onOpenTerminal,
          ),
          if (widget.status == AgentStatus.paused)
            _iconButton(
              icon: Icons.play_arrow,
              tooltip: '恢复',
              color: cSuccess,
              onTap: widget.onResume,
            )
          else if (_isRunning)
            _iconButton(
              icon: Icons.pause,
              tooltip: '暂停',
              color: tc.textSub,
              onTap: widget.onPause,
            ),
          _iconButton(
            icon: Icons.stop,
            tooltip: '停止',
            color: cDanger,
            onTap: widget.onStop,
          ),
        ],
      ),
    );
  }

  String _metaText(AgentTask task, int elapsed) {
    final parts = <String>[task.phase ?? _phaseLabel()];
    if (task.stepIndex > 0) parts.add('第 ${task.stepIndex} 步');
    parts.add(_formatElapsed(elapsed));
    if (task.successCount > 0 || task.failureCount > 0) {
      parts.add(task.failureCount > 0
          ? '${task.successCount} 成功 · ${task.failureCount} 失败'
          : '${task.successCount} 条命令');
    }
    if (widget.plan.isNotEmpty) {
      final done = widget.plan.where((s) => s.isDone).length;
      parts.add('计划 $done/${widget.plan.length}');
    }
    return parts.join(' · ');
  }

  String _phaseLabel() {
    switch (widget.status) {
      case AgentStatus.thinking:
        return '思考中';
      case AgentStatus.executing:
        return '执行中';
      case AgentStatus.waitingConfirm:
        return '等待确认';
      case AgentStatus.paused:
        return '已暂停';
      case AgentStatus.completed:
        return '已完成';
      case AgentStatus.failed:
        return '失败';
      case AgentStatus.cancelled:
        return '已取消';
      case AgentStatus.idle:
        return '就绪';
    }
  }

  Color _statusColor(ThemeColors tc) {
    switch (widget.status) {
      case AgentStatus.thinking:
      case AgentStatus.executing:
        return cSuccess;
      case AgentStatus.waitingConfirm:
        return cWarning;
      case AgentStatus.paused:
        return tc.textMuted;
      case AgentStatus.failed:
        return cDanger;
      case AgentStatus.cancelled:
        return cWarning;
      case AgentStatus.completed:
        return cSuccess;
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

  static String _formatElapsed(int seconds) {
    if (seconds <= 0) return '不足 1s';
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m < 60) return '${m}m${s.toString().padLeft(2, '0')}s';
    final h = m ~/ 60;
    return '${h}h${(m % 60).toString().padLeft(2, '0')}m';
  }
}
