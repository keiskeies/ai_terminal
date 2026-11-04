import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_goal.dart';
import '../utils/agent_ui_text.dart';

/// 目标模式横幅。
///
/// 三个操作按钮必须长在横幅上，不能只靠 `/goal` 命令：任务运行中输入框是禁用的
/// （`AIPromptInput._send` 遇到 isRunning 直接 return），只给命令等于让用户
/// 没法中途停下自动续跑。
class AgentGoalBanner extends StatelessWidget {
  final AgentGoal goal;
  final ThemeColors tc;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onFinish;
  final ValueChanged<String>? onEdit;

  const AgentGoalBanner({
    super.key,
    required this.goal,
    required this.tc,
    this.onPause,
    this.onResume,
    this.onFinish,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final ui = AgentUiText.of(context);
    final isFinished = goal.status == AgentGoalStatus.finished;
    final isActive = goal.status == AgentGoalStatus.active;
    final statusColor = isActive
        ? tc.brand
        : (isFinished ? tc.textMuted : tc.gold);
    final title = isActive
        ? ui.goalRunning
        : (isFinished ? ui.goalFinished : ui.goalPaused);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: BoxDecoration(
        color: tc.surface,
        border: Border(
          bottom: BorderSide(color: tc.border, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Text(
                title,
                style: TextStyle(
                  color: statusColor,
                  fontSize: fMicro,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  goal.objective,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tc.textMain,
                    fontSize: fSmall,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              _actionButton(
                icon: Icons.edit_outlined,
                tooltip: ui.goalEditAction,
                onTap: goal.status == AgentGoalStatus.finished
                    ? null
                    : () => _showEditDialog(context, ui),
              ),
              const SizedBox(width: 2),
              if (isActive)
                _actionButton(
                  icon: Icons.pause_outlined,
                  tooltip: ui.pause,
                  onTap: onPause,
                )
              else if (!isFinished)
                _actionButton(
                  icon: Icons.play_arrow_outlined,
                  tooltip: ui.resume,
                  onTap: onResume,
                ),
              const SizedBox(width: 2),
              _actionButton(
                icon: isFinished ? Icons.delete_outline : Icons.stop_circle_outlined,
                tooltip: isFinished ? ui.goalClearAction : ui.goalFinishAction,
                onTap: isFinished ? onFinish : () => _confirmFinish(context, ui),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  ui.goalRounds(goal.roundsUsed, goal.maxRounds),
                  style: TextStyle(
                    color: tc.textSub,
                    fontSize: fMicro,
                    fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                  ),
                ),
                if (!isFinished)
                  Text(
                    goal.budgetExhausted
                        ? ui.goalBudgetExhausted
                        : ui.goalRoundsLeft(goal.roundsLeft),
                    style: TextStyle(
                      color: goal.budgetExhausted ? tc.gold : tc.textMuted,
                      fontSize: fMicro,
                    ),
                  ),
                if ((goal.note ?? '').trim().isNotEmpty)
                  // Wrap 的子项拿的是无界宽度，不能用 Flexible：
                  // 限一个宽度再加省略号，长原因不会把轮次挤掉
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      goal.note!.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: onTap == null
                ? Colors.transparent
                : tc.cardElevated,
            borderRadius: BorderRadius.circular(rXSmall),
            border: Border.all(color: tc.border, width: 1),
          ),
          child: Icon(
            icon,
            size: 14,
            color: onTap == null ? tc.textMuted.withValues(alpha: 0.4) : tc.textSub,
          ),
        ),
      ),
    );
  }

  void _showEditDialog(BuildContext context, AgentUiText ui) {
    final controller = TextEditingController(text: goal.objective);
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(ui.goalEditTitle,
              style: const TextStyle(fontSize: fBody)),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: controller,
              minLines: 2,
              maxLines: 5,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final text = controller.text.trim();
                Navigator.of(dialogContext).pop();
                if (text.isNotEmpty) onEdit?.call(text);
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  void _confirmFinish(BuildContext context, AgentUiText ui) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(ui.goalFinishTitle,
              style: const TextStyle(fontSize: fBody)),
          content: SizedBox(
            width: 420,
            child: Text(ui.goalFinishBody,
                style: const TextStyle(fontSize: fSmall, height: 1.5)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                onFinish?.call();
              },
              child: const Text('结束'),
            ),
          ],
        );
      },
    );
  }
}
