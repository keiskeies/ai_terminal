import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/safety_guard.dart';
import '../providers/terminal_provider.dart' as tp;

/// 统一命令块：左侧 3px 安全色条 + 命令文本 + 顶部状态标签与操作
///
/// 由 `_TerminalPageState._buildCommandBlock` 系列方法提取而来，包含：
/// 复制按钮、执行按钮、危险命令内联确认按钮。
class AgentCommandBlock extends StatelessWidget {
  final String command;
  final ThemeColors tc;
  final tp.TerminalTab? tab;
  final bool showAutoExecute;
  final bool isLoading;

  /// 当前正在执行的命令（用于显示加载态 / 禁用其它按钮）
  final String? executingCommand;

  /// 当前等待内联确认的危险命令（与 [command] 相等时显示确认/取消按钮）
  final String? pendingConfirmCommand;

  /// 执行命令回调（点击执行按钮时触发）
  final void Function(String command, bool dangerous, tp.TerminalTab tab)?
      onExecute;

  /// 确认执行危险命令回调（点击「确认执行」时触发，由调用方解析当前活动 tab）
  final void Function(String command)? onConfirm;

  /// 拒绝/取消执行危险命令回调（点击「取消」时触发）
  final VoidCallback? onReject;

  const AgentCommandBlock({
    super.key,
    required this.command,
    required this.tc,
    this.tab,
    this.showAutoExecute = false,
    this.isLoading = false,
    this.executingCommand,
    this.pendingConfirmCommand,
    this.onExecute,
    this.onConfirm,
    this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return _buildCommandBlock(context);
  }

  /// 统一命令块：左侧 3px 安全色条 + 命令文本 + 顶部状态标签与操作
  Widget _buildCommandBlock(BuildContext context) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    // 用局部变量保证 tab 的空提升
    final tab = this.tab;
    final canExecute = tab != null && tab.isConnected && showAutoExecute;
    final safetyLevel = SafetyGuard.check(trimmed);
    final dangerous = safetyLevel != SafetyLevel.safe;
    final isBlocked = safetyLevel == SafetyLevel.blocked;
    final isWaitingConfirm = pendingConfirmCommand == trimmed;

    final cmdColor = isBlocked
        ? cDanger
        : dangerous
            ? cWarning
            : tc.terminalGreen;

    final accentColor =
        isBlocked ? cDanger : dangerous ? cWarning : tc.terminalGreen;
    final headerBg = isBlocked
        ? cDanger.withValues(alpha: 0.08)
        : dangerous
            ? cWarning.withValues(alpha: 0.08)
            : cSuccess.withValues(alpha: 0.08);

    final block = Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: tc.terminalOutput,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: cBorder, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧色条
          Container(
            width: 3,
            color: accentColor,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部栏
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: headerBg,
                    border: Border(
                        bottom: BorderSide(color: tc.border, width: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Icon(
                          isBlocked
                              ? Icons.block
                              : dangerous
                                  ? Icons.warning_amber
                                  : Icons.check,
                          size: 9,
                          color: accentColor,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isBlocked ? '已拦截' : dangerous ? '需确认' : '可执行',
                        style: TextStyle(
                          fontSize: fMicro,
                          color: accentColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      // 复制按钮
                      _buildCopyButton(trimmed, tc, context),
                      const SizedBox(width: 4),
                      // 执行按钮 或 内联确认按钮
                      if (canExecute && !isLoading && !isBlocked) ...[
                        if (dangerous && isWaitingConfirm) ...[
                          // 危险命令待确认：显示取消 + 确认按钮
                          _buildInlineConfirmButtons(trimmed, tc),
                        ] else ...[
                          _buildExecuteButton(
                              trimmed, dangerous, isBlocked, tc, tab),
                        ],
                      ] else if (isBlocked)
                        Container(
                          width: 26,
                          height: 26,
                          alignment: Alignment.center,
                          child: const Icon(Icons.block, size: 13, color: cDanger),
                        ),
                    ],
                  ),
                ),
                // 命令内容
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // $ 提示符
                      Text(
                        '\$ ',
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: fMono,
                          color: accentColor,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                      // 命令文本
                      Expanded(
                        child: SelectableText(
                          trimmed,
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: fMono,
                            color: cmdColor,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return block;
  }

  /// 复制按钮
  Widget _buildCopyButton(String text, ThemeColors tc, BuildContext context) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已复制', style: TextStyle(fontSize: fSmall)),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.all(16),
          ),
        );
      },
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        child: Icon(Icons.copy, size: 13, color: tc.textMuted),
      ),
    );
  }

  /// 命令执行按钮（带背景色的三角形按钮）
  Widget _buildExecuteButton(
      String command, bool dangerous, bool isBlocked, ThemeColors tc, tp.TerminalTab tab) {
    final isExecuting = executingCommand == command;
    final hasAnyExecuting = executingCommand != null;
    final isDisabled = isBlocked || (hasAnyExecuting && !isExecuting);

    final color = isBlocked
        ? cDanger
        : dangerous
            ? cWarning
            : cPrimary;

    return GestureDetector(
      onTap: isDisabled ? null : () => onExecute?.call(command, dangerous, tab),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isDisabled ? Colors.transparent : color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(rSmall),
          border: isDisabled ? null : Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: isExecuting
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
              )
            : isBlocked
                ? const Icon(Icons.block, size: 14, color: cDanger)
                : Icon(Icons.play_arrow, size: 18, color: color),
      ),
    );
  }

  /// 危险命令内联确认/取消按钮（替代弹窗）
  Widget _buildInlineConfirmButtons(String command, ThemeColors tc) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 取消按钮
        GestureDetector(
          onTap: onReject,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tc.surface,
              borderRadius: BorderRadius.circular(rSmall),
              border: Border.all(color: tc.border),
            ),
            child: Text('取消',
                style: TextStyle(
                    fontSize: fSmall,
                    color: tc.textSub,
                    fontWeight: FontWeight.w500)),
          ),
        ),
        const SizedBox(width: 4),
        // 确认执行按钮
        GestureDetector(
          onTap: () => onConfirm?.call(command),
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cWarning.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(rSmall),
              border: Border.all(color: cWarning.withValues(alpha: 0.4)),
            ),
            child: const Text('确认执行',
                style: TextStyle(
                    fontSize: fSmall,
                    color: cWarning,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }
}

/// 带执行按钮的代码块 — 每条命令独立成块，复用统一命令块样式
Widget buildCodeBlockWithExecuteButton(
  String codeBlock,
  ThemeColors tc,
  tp.TerminalTab? tab,
  bool showAutoExecute,
  bool isLoading, {
  String? executingCommand,
  String? pendingConfirmCommand,
  void Function(String command, bool dangerous, tp.TerminalTab tab)? onExecute,
  void Function(String command)? onConfirm,
  VoidCallback? onReject,
}) {
  final lines = codeBlock.trimRight().split('\n');
  final children = <Widget>[];

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    children.add(AgentCommandBlock(
      command: trimmed,
      tc: tc,
      tab: tab,
      showAutoExecute: showAutoExecute,
      isLoading: isLoading,
      executingCommand: executingCommand,
      pendingConfirmCommand: pendingConfirmCommand,
      onExecute: onExecute,
      onConfirm: onConfirm,
      onReject: onReject,
    ));
  }

  if (children.isEmpty) return const SizedBox.shrink();

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
}

/// 纯代码块（非 shell）
Widget buildPlainCodeBlock(String codeBlock, ThemeColors tc) {
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: tc.terminalBg,
      borderRadius: BorderRadius.circular(rSmall),
      border: Border.all(color: tc.border),
    ),
    child: SelectableText(
      codeBlock.trimRight(),
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: fMono,
        color: tc.textSub,
        height: 1.4,
      ),
    ),
  );
}
