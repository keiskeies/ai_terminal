import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/plan_step.dart';
import '../utils/agent_ui_text.dart';

/// 执行清单：展示模型声明的计划步骤与状态
///
/// 计划只做展示，不代表系统已验证；真实执行证据仍在"过程与证据"里。
class PlanPanel extends StatefulWidget {
  final List<PlanStep> steps;
  final ThemeColors tc;
  final bool? initiallyExpanded;

  /// 当前正在执行的命令（仅运行中传入，展示在第一个进行中步骤下）
  final String? currentCommand;

  /// 展开区限高（像素）。贴底常驻时传入：长计划会把输入框顶出屏幕，
  /// 所以卡内自己滚动、头部固定。null = 不限高（会话流内的历史回看用法）。
  final double? maxHeight;

  /// 外间距由所在布局决定：操作单里统一由模块间距控制，
  /// 贴底/遗留流里保留默认的 8px 下边距。
  final EdgeInsetsGeometry margin;

  const PlanPanel({
    super.key,
    required this.steps,
    required this.tc,
    this.initiallyExpanded,
    this.currentCommand,
    this.maxHeight,
    this.margin = const EdgeInsets.only(bottom: 8),
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
    // 全部收尾后计划只是存档：自动收起，把屏幕还给结论
    final allDone = widget.steps.isNotEmpty &&
        widget.steps.every((s) => s.status == PlanStepStatus.completed);
    final wasAllDone = oldWidget.steps.isNotEmpty &&
        oldWidget.steps.every((s) => s.status == PlanStepStatus.completed);
    if (allDone && !wasAllDone) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    if (steps.isEmpty) return const SizedBox.shrink();
    final tc = widget.tc;
    final ui = AgentUiText.of(context);
    final currentIndex =
        steps.indexWhere((s) => s.status == PlanStepStatus.inProgress);
    final doneCount =
        steps.where((s) => s.status == PlanStepStatus.completed).length;
    // 收起时把"当前在做哪一步"带到标题行：只留进度数字等于把计划藏没了
    final headerLabel = !_expanded && currentIndex >= 0
        ? '${ui.step(currentIndex + 1)} · ${steps[currentIndex].title}'
        : '';

    return Container(
      margin: widget.margin,
      decoration: BoxDecoration(
        color: tc.agentCardFill,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: tc.agentCardBorder, width: 1),
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
                    ui.planTitle,
                    style: TextStyle(
                      color: tc.textMain,
                      fontSize: fSmall,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    ui.planByAi,
                    style: TextStyle(
                      color: tc.textSub,
                      fontSize: fMicro,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 设计稿 count-chip：完成/总数以胶囊徽标呈现，其余统计留给收起行
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(rFull),
                      border: Border.all(color: tc.border, width: 1),
                    ),
                    child: Text(
                      '$doneCount/${steps.length}',
                      style: TextStyle(
                        color: tc.textSub,
                        fontSize: fMicro,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (headerLabel.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        headerLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: tc.textSub,
                          fontSize: fMicro,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ] else
                    const Spacer(),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: tc.textSub,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: tc.hairline),
            _buildExpandedList(ui, currentIndex),
          ],
        ],
      ),
    );
  }

  Widget _buildExpandedList(AgentUiText ui, int currentIndex) {
    final list = Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._visibleSteps().asMap().entries.map((entry) => _buildStepRow(
                entry.value,
                isCurrentStep: entry.key == currentIndex,
              )),
          if (widget.steps.length > _collapsedLimit && !_showAll)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: InkWell(
                onTap: () => setState(() => _showAll = true),
                child: Text(
                  ui.expandAll(widget.steps.length),
                  style: TextStyle(
                    color: widget.tc.brand,
                    fontSize: fMicro,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (widget.maxHeight == null) return list;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight!),
      child: SingleChildScrollView(child: list),
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
      PlanStepStatus.completed => tc.textSub,
      PlanStepStatus.skipped => tc.textMuted,
      PlanStepStatus.failed => tc.error,
      PlanStepStatus.inProgress => tc.textMain,
      PlanStepStatus.pending => tc.textBody,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        // 面板底已经是 dataCard，用品牌色标"当前步"而不是再造一档灰
        color:
            isCurrent ? tc.brand.withValues(alpha: 0.10) : Colors.transparent,
        // 选中条是"胶囊"而不是表格单元：5px 在这条窄条上几乎看不出弧度，
        // 和卡片 10px 的圆角也接不上，统一到 8px
        borderRadius: BorderRadius.circular(rSmall),
        border: isCurrent
            ? Border.all(color: tc.brand.withValues(alpha: 0.28))
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            // 设计稿 .pulse：只有进行中的步骤图标做呼吸闪烁
            child: isCurrent
                ? _PulsingIcon(icon: icon, size: 13, color: color)
                : Icon(icon, size: 13, color: color),
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
                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
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
                      Icon(Icons.terminal, size: 10, color: tc.textSub),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          widget.currentCommand!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tc.textSub,
                            fontSize: fMicro,
                            fontFamily: 'JetBrainsMono',
                            fontFamilyFallback: kMonoFontFallback,
                            fontWeight: FontWeight.w500,
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
                color: tc.textSub,
                fontSize: fMicro,
                fontFamily: 'JetBrainsMono',
                fontFamilyFallback: kMonoFontFallback,
                fontWeight: FontWeight.w500,
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
        return (Icons.check_circle, tc.ok);
      case PlanStepStatus.inProgress:
        return (Icons.radio_button_checked, tc.brand);
      case PlanStepStatus.failed:
        return (Icons.error, tc.error);
      case PlanStepStatus.skipped:
        return (Icons.remove_circle_outline, tc.textMuted);
      case PlanStepStatus.pending:
        return (Icons.radio_button_unchecked, tc.textSub);
    }
  }
}

/// 进行中步骤图标的呼吸闪烁（对应设计稿 .pulse，1.2s 循环）
class _PulsingIcon extends StatefulWidget {
  final IconData icon;
  final double size;
  final Color color;

  const _PulsingIcon({
    required this.icon,
    required this.size,
    required this.color,
  });

  @override
  State<_PulsingIcon> createState() => _PulsingIconState();
}

class _PulsingIconState extends State<_PulsingIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1.0).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.85, end: 1.0).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
        ),
        child: Icon(widget.icon, size: widget.size, color: widget.color),
      ),
    );
  }
}
