import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/plan_step.dart';

/// 执行清单：展示模型声明的计划步骤与状态
///
/// 计划只做展示，不代表系统已验证；真实执行证据仍在"过程与证据"里。
class PlanPanel extends StatefulWidget {
  final List<PlanStep> steps;
  final ThemeColors tc;
  final bool? initiallyExpanded;

  /// 当前正在执行的命令（仅运行中传入，展示在第一个进行中步骤下）
  final String? currentCommand;

  const PlanPanel({
    super.key,
    required this.steps,
    required this.tc,
    this.initiallyExpanded,
    this.currentCommand,
  });

  @override
  State<PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends State<PlanPanel> {
  static const _collapsedLimit = 12;

  late bool _expanded = widget.initiallyExpanded ?? widget.steps.length <= 8;
  bool _showAll = false;

  @override
  void didUpdateWidget(covariant PlanPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.steps.length != widget.steps.length &&
        widget.initiallyExpanded == null) {
      // 计划首次出现/增长时自动展开，但用户手动收起后不强制打断
      if (widget.steps.length <= 8) _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    if (steps.isEmpty) return const SizedBox.shrink();
    final tc = widget.tc;
    final counts = _counts();
    final currentIndex = steps
        .indexWhere((s) => s.status == PlanStepStatus.inProgress);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: tc.surface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 15, color: tc.textSub),
                  const SizedBox(width: 6),
                  Text(
                    '执行清单',
                    style: TextStyle(
                      color: tc.textMain,
                      fontSize: fSmall,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'AI 计划',
                    style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      counts,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: tc.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 0.5, thickness: 0.5, color: tc.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ..._visibleSteps()
                      .asMap()
                      .entries
                      .map((entry) => _buildStepRow(
                            entry.value,
                            isCurrentStep: entry.key == currentIndex,
                          )),
                  if (steps.length > _collapsedLimit && !_showAll)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: InkWell(
                        onTap: () => setState(() => _showAll = true),
                        child: Text(
                          '展开全部 ${steps.length} 项',
                          style: TextStyle(color: cPrimary, fontSize: fMicro),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<PlanStep> _visibleSteps() {
    if (_showAll) return widget.steps;
    return widget.steps.take(_collapsedLimit).toList(growable: false);
  }

  Widget _buildStepRow(PlanStep step, {required bool isCurrentStep}) {
    final tc = widget.tc;
    final (icon, color) = _statusVisual(step.status);
    final isCurrent = step.status == PlanStepStatus.inProgress;
    final titleColor = switch (step.status) {
      PlanStepStatus.completed || PlanStepStatus.skipped => tc.textMuted,
      PlanStepStatus.failed => cDanger,
      PlanStepStatus.inProgress => tc.textMain,
      PlanStepStatus.pending => tc.textSub,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: isCurrent
            ? cPrimary.withValues(alpha: 0.07)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(rXSmall),
        border: isCurrent
            ? Border.all(color: cPrimary.withValues(alpha: 0.2))
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 13, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: fSmall,
                    height: 1.35,
                    fontWeight:
                        isCurrent ? FontWeight.w600 : FontWeight.w400,
                    decoration: step.status == PlanStepStatus.skipped
                        ? TextDecoration.lineThrough
                        : null,
                    decorationColor: tc.textMuted,
                  ),
                ),
                if (isCurrentStep &&
                    widget.currentCommand != null &&
                    widget.currentCommand!.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.terminal,
                          size: 10, color: tc.textMuted),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          widget.currentCommand!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tc.textMuted,
                            fontSize: fMicro,
                            fontFamily: 'JetBrainsMono',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (step.hostIds.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              step.hostIds.join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tc.textMuted,
                fontSize: fMicro,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ],
        ],
      ),
    );
  }

  (IconData, Color) _statusVisual(PlanStepStatus status) {
    final tc = widget.tc;
    switch (status) {
      case PlanStepStatus.completed:
        return (Icons.check_circle, cSuccess);
      case PlanStepStatus.inProgress:
        return (Icons.radio_button_checked, cPrimary);
      case PlanStepStatus.failed:
        return (Icons.error, cDanger);
      case PlanStepStatus.skipped:
        return (Icons.remove_circle_outline, tc.textMuted);
      case PlanStepStatus.pending:
        return (Icons.radio_button_unchecked, tc.textMuted);
    }
  }

  String _counts() {
    final total = widget.steps.length;
    final completed = widget.steps
        .where((s) => s.status == PlanStepStatus.completed)
        .length;
    final inProgress = widget.steps
        .where((s) => s.status == PlanStepStatus.inProgress)
        .length;
    final failed =
        widget.steps.where((s) => s.status == PlanStepStatus.failed).length;
    final pending = widget.steps
        .where((s) => s.status == PlanStepStatus.pending)
        .length;
    final skipped = widget.steps
        .where((s) => s.status == PlanStepStatus.skipped)
        .length;
    final parts = <String>['$total 项', '$completed 完成'];
    if (inProgress > 0) parts.add('$inProgress 进行中');
    if (failed > 0) parts.add('$failed 失败');
    if (skipped > 0) parts.add('$skipped 跳过');
    if (pending > 0) parts.add('$pending 待处理');
    return parts.join(' · ');
  }
}
