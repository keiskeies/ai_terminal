import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_event.dart';
import '../providers/terminal_provider.dart' as tp;
import 'agent_command_block.dart';

/// 结构化事件列表渲染：内容自动追加，只有命令单独包装成块
///
/// 渲染规则：
/// - thought/text/info：合并为连续 Markdown 文本自动追加显示
/// - command：单独命令块（执行按钮 + 复制按钮）
/// - result：紧跟对应 command 后，用缩进+连接线表示从属
/// - ask：问题文本 + 横向选项按钮组
/// - finish：完成横幅
///
/// 由 `_TerminalPageState._buildEventsContent` 系列方法提取而来。
class AgentEventContent extends StatelessWidget {
  final List<AgentEvent> events;
  final ThemeColors tc;
  final tp.TerminalTab? tab;
  final bool showAutoExecute;
  final bool isLoading;
  final bool isWaitingChoice;
  final List<String> pendingOptions;

  /// 当前正在执行的命令（传给内部命令块）
  final String? executingCommand;

  /// 当前等待内联确认的危险命令（传给内部命令块）
  final String? pendingConfirmCommand;

  /// 渲染 thought/text/info 文本为 Markdown 的回调（复用调用方的 _buildMarkdownText）
  final Widget Function(String text, ThemeColors tc) markdownBuilder;

  /// 命令执行回调（传给内部命令块）
  final void Function(String command, bool dangerous, tp.TerminalTab tab)?
      onExecuteCommand;

  /// 确认执行危险命令回调（传给内部命令块）
  final void Function(String command)? onConfirmCommand;

  /// 拒绝/取消执行危险命令回调（传给内部命令块）
  final VoidCallback? onRejectCommand;

  /// 选项选择回调（ask 选项 chip / 选项按钮组共用）
  final void Function(String choice)? onSelectChoice;

  const AgentEventContent({
    super.key,
    required this.events,
    required this.tc,
    this.tab,
    this.showAutoExecute = false,
    this.isLoading = false,
    this.isWaitingChoice = false,
    this.pendingOptions = const [],
    this.executingCommand,
    this.pendingConfirmCommand,
    required this.markdownBuilder,
    this.onExecuteCommand,
    this.onConfirmCommand,
    this.onRejectCommand,
    this.onSelectChoice,
  });

  @override
  Widget build(BuildContext context) {
    return _buildEventsContent();
  }

  /// 结构化事件列表渲染：内容自动追加，只有命令单独包装成块
  Widget _buildEventsContent() {
    // 构建事件→结果配对映射：commandId → result
    final resultMap = <String, AgentEvent>{};
    for (final e in events) {
      if (e.isResult && e.commandId != null) {
        resultMap[e.commandId!] = e;
      }
    }

    final widgets = <Widget>[];
    final textBuffer = StringBuffer();

    void flushText() {
      final text = textBuffer.toString().trim();
      if (text.isNotEmpty) {
        widgets.add(markdownBuilder(text, tc));
        textBuffer.clear();
      }
    }

    for (final event in events) {
      switch (event.type) {
        case AgentEventType.thought:
        case AgentEventType.text:
        case AgentEventType.info:
          if (event.text != null && event.text!.trim().isNotEmpty) {
            textBuffer.writeln(event.text);
          }
          break;
        case AgentEventType.command:
          flushText();
          widgets.add(AgentCommandBlock(
            command: event.command ?? '',
            tc: tc,
            tab: tab,
            showAutoExecute: showAutoExecute,
            isLoading: isLoading,
            executingCommand: executingCommand,
            pendingConfirmCommand: pendingConfirmCommand,
            onExecute: onExecuteCommand,
            onConfirm: onConfirmCommand,
            onReject: onRejectCommand,
          ));
          // 若有对应 result，紧跟在 command 后渲染
          final result = resultMap[event.id];
          if (result != null) {
            widgets.add(_buildResultCard(result, tc));
          }
          break;
        case AgentEventType.result:
          if (event.commandId == null ||
              !events.any((e) => e.id == event.commandId)) {
            flushText();
            widgets.add(_buildResultCard(event, tc));
          }
          break;
        case AgentEventType.ask:
          flushText();
          widgets.add(_buildAskCard(event, tc));
          break;
        case AgentEventType.finish:
          flushText();
          widgets.add(_buildFinishCard(event, tc));
          break;
      }
    }
    flushText();

    // 兜底：若有 pendingOptions 但没有 ask 事件（旧格式），显示选项按钮
    if (isWaitingChoice &&
        pendingOptions.isNotEmpty &&
        !events.any((e) => e.isAsk)) {
      widgets.add(buildOptionButtons(pendingOptions, tc, false,
          onSelectChoice: onSelectChoice));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  /// 结果卡片：成功/失败状态 + 输出（全部展开显示）
  /// 背景保持 terminalBg，无左侧缩进，与命令块视觉对齐
  Widget _buildResultCard(AgentEvent event, ThemeColors tc) {
    final success = event.success ?? false;
    final output = event.output ?? event.error ?? '(无输出)';
    final lines = output.split('\n');

    final statusColor = success ? cSuccess : cDanger;
    final statusBg = success
        ? cSuccess.withValues(alpha: 0.08)
        : cDanger.withValues(alpha: 0.08);
    final statusIcon = success ? Icons.check : Icons.close;
    final statusText = success ? '执行成功' : '执行失败';

    return Container(
      margin: const EdgeInsets.only(bottom: 8, top: 2),
      decoration: BoxDecoration(
        color: tc.terminalBg,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 状态条
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: statusBg,
              border: Border(
                  bottom: BorderSide(color: tc.border, width: 0.5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(statusIcon, size: 9, color: statusColor),
                ),
                const SizedBox(width: 6),
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: fMicro,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: tc.textMuted.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rXSmall),
                  ),
                  child: Text(
                    '${lines.length} 行',
                    style: TextStyle(
                        color: tc.textMuted,
                        fontSize: fMicro,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
          // 输出区 - 全部展开显示
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: SelectableText(
              output.trimRight(),
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: fMono,
                color: tc.textBody,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 询问卡片：问题 + 选项按钮
  Widget _buildAskCard(AgentEvent event, ThemeColors tc) {
    final options = event.options ?? [];
    final question = event.question ?? '请选择';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cWarning.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: cWarning.withValues(alpha: 0.15)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: cWarning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.help_outline,
                    size: 13, color: cWarning),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  question,
                  style: TextStyle(
                      color: tc.textMain,
                      fontSize: fBody,
                      height: 1.5,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          if (options.isNotEmpty && isWaitingChoice) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: options.map((opt) {
                return _buildOptionChip(opt, tc);
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionChip(String label, ThemeColors tc) {
    return GestureDetector(
      onTap: () => onSelectChoice?.call(label),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: tc.surface,
          borderRadius: BorderRadius.circular(rMedium),
          border: Border.all(color: cWarning.withValues(alpha: 0.3)),
          boxShadow: [
            BoxShadow(
              color: cWarning.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.touch_app, size: 12, color: cWarning),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: fSmall,
                color: cWarning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 任务完成卡片
  Widget _buildFinishCard(AgentEvent event, ThemeColors tc) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8, top: 4),
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cSuccessBg,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: cSuccess.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: cSuccess.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.celebration,
                size: 15, color: cSuccess),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '任务完成',
                  style: TextStyle(
                    color: cSuccess,
                    fontSize: fSmall,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                MarkdownBody(
                  data: event.summary ?? '已完成所有步骤',
                  selectable: true,
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(
                      color: cSuccess.withValues(alpha: 0.9),
                      fontSize: fBody,
                      fontWeight: FontWeight.w500,
                      height: 1.5,
                    ),
                    h1: TextStyle(
                      color: cSuccess,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    h2: TextStyle(
                      color: cSuccess,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                    h3: TextStyle(
                      color: cSuccess,
                      fontSize: fBody,
                      fontWeight: FontWeight.w600,
                    ),
                    code: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: fMono,
                      backgroundColor: cSuccess.withValues(alpha: 0.1),
                    ),
                    listBullet: const TextStyle(color: cSuccess),
                    strong: const TextStyle(color: cSuccess, fontWeight: FontWeight.bold),
                    a: const TextStyle(color: cSuccess),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

}

/// 选项按钮组 — AI 输出 :::choose A|B|C::: 后渲染为可点击选项
Widget buildOptionButtons(
  List<String> options,
  ThemeColors tc,
  bool disabled, {
  void Function(String choice)? onSelectChoice,
}) {
  return Container(
    margin: const EdgeInsets.only(top: 8),
    child: Wrap(
      spacing: 8,
      runSpacing: 6,
      children: options.asMap().entries.map((entry) {
        final index = entry.key;
        final option = entry.value;
        final isPrimary = index == 0; // 第一个选项用主色高亮
        final color = isPrimary ? cPrimary : tc.textMain;
        final bgColor = isPrimary
            ? cPrimary.withValues(alpha: disabled ? 0.1 : 0.15)
            : tc.border.withValues(alpha: disabled ? 0.3 : 0.6);

        return GestureDetector(
          onTap: disabled ? null : () => onSelectChoice?.call(option),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(rSmall),
              border: Border.all(
                color: color.withValues(alpha: disabled ? 0.2 : 0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isPrimary) ...[
                  Icon(Icons.check_circle_outline,
                      size: 14,
                      color: color.withValues(alpha: disabled ? 0.4 : 1)),
                  const SizedBox(width: 4),
                ],
                Text(
                  option,
                  style: TextStyle(
                    fontSize: fSmall,
                    color: color.withValues(alpha: disabled ? 0.4 : 1),
                    fontWeight:
                        isPrimary ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    ),
  );
}
