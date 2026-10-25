import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_event.dart';
import '../providers/terminal_provider.dart' as tp;
import 'agent_command_block.dart';
import 'host_result_matrix.dart';
import 'output_viewer_sheet.dart';

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

  /// 失败命令重试回调（由页面负责构造新一轮任务）
  final void Function(AgentEvent event)? onRetryFailedCommand;

  /// 断线重连回调（仅 disconnected 失败显示）
  final void Function(AgentEvent event)? onReconnectHost;

  /// 多主机矩阵重试失败主机回调
  final void Function(List<String> failedHostIds)? onRetryFailedHosts;

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
    this.onRetryFailedCommand,
    this.onReconnectHost,
    this.onRetryFailedHosts,
  });

  @override
  Widget build(BuildContext context) {
    return _buildEventsContent(context);
  }

  /// 结构化事件列表渲染：内容自动追加，只有命令单独包装成块
  Widget _buildEventsContent(BuildContext context) {
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
          final isTool =
              event.toolName != null && event.toolName != 'exec_command';
          // 若有对应 result，紧跟在 command 后渲染
          final result = resultMap[event.id];
          widgets.add(AgentCommandBlock(
            command: event.command ?? '',
            tc: tc,
            tab: tab,
            showAutoExecute: showAutoExecute,
            isLoading: isLoading,
            executingCommand: executingCommand,
            pendingConfirmCommand: pendingConfirmCommand,
            isTool: isTool,
            executed: result != null,
            onExecute: onExecuteCommand,
            onConfirm: onConfirmCommand,
            onReject: onRejectCommand,
          ));
          if (result != null) {
            widgets.add(_buildResultCard(result, tc, context));
          }
          break;
        case AgentEventType.result:
          if (event.commandId == null ||
              !events.any((e) => e.id == event.commandId)) {
            flushText();
            widgets.add(_buildResultCard(event, tc, context));
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
        case AgentEventType.report:
          // 操作单由 OperationSheet 单独渲染，证据层忽略
          break;
        case AgentEventType.plan:
          // 执行清单由 PlanPanel 单独渲染，证据层忽略
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
  Widget _buildResultCard(AgentEvent event, ThemeColors tc, BuildContext context) {
    final success = event.success ?? false;
    final output = event.output ?? event.error ?? '(无输出)';
    final lines = output.split('\n');
    final hostResults = event.hostResults;
    final showMatrix = hostResults != null && hostResults.length > 1;

    final statusColor = success ? cSuccess : cDanger;
    final statusBg = success
        ? cSuccess.withValues(alpha: 0.08)
        : cDanger.withValues(alpha: 0.08);
    final statusIcon = success ? Icons.check : Icons.close;
    final statusText = success
        ? '执行成功'
        : _failureLabel(event.failureKind);

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
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      if (!success && event.exitCode != null)
                        _metaChip('退出码 ${event.exitCode}', cDanger),
                      if (event.durationMs != null)
                        _metaChip(
                            _formatDuration(event.durationMs!), tc.textMuted),
                      if (event.outputTruncated == true)
                        _metaChip(
                          event.outputTotalChars != null
                              ? '已截断 ${event.outputTotalChars} 字符'
                              : '已截断',
                          cWarning,
                        ),
                      if (event.diffAdditions != null)
                        _metaChip('+${event.diffAdditions}', cSuccess),
                      if (event.diffDeletions != null)
                        _metaChip('-${event.diffDeletions}', cDanger),
                      if (!showMatrix)
                        _metaChip('${lines.length} 行', tc.textMuted),
                    ],
                  ),
                ),
                // 复制按钮：与命令块体验一致，一键复制输出
                _buildCopyButton(output, tc, context),
              ],
            ),
          ),
          if (!success) _buildFailureHint(event.failureKind, tc),
          if (!success &&
              (onRetryFailedCommand != null || onReconnectHost != null))
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
              child: Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  alignment: WrapAlignment.end,
                  children: [
                    if (event.failureKind == 'disconnected' &&
                        onReconnectHost != null)
                      _failureActionButton(
                        icon: Icons.wifi_tethering,
                        label: '重连',
                        color: cWarning,
                        onTap: () => onReconnectHost!(event),
                      ),
                    if (onRetryFailedCommand != null &&
                        (event.command ?? '').trim().isNotEmpty)
                      _failureActionButton(
                        icon: Icons.refresh,
                        label: '让 AI 重试',
                        color: cPrimary,
                        onTap: () => onRetryFailedCommand!(event),
                      ),
                  ],
                ),
              ),
            ),
          // 输出区：多主机用矩阵，单主机保持原始输出
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showMatrix)
                  HostResultMatrix(
                    results: hostResults,
                    tc: tc,
                    onRetryFailedHosts: onRetryFailedHosts,
                  )
                else
                  SelectableText(
                    output.trimRight(),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: fMono,
                      color: tc.textBody,
                      height: 1.45,
                    ),
                  ),
                if (!showMatrix &&
                    event.outputTail != null &&
                    event.outputTail!.trim().isNotEmpty)
                  _RawOutputTail(
                    tail: event.outputTail!,
                    totalChars: event.outputTotalChars,
                    tc: tc,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _failureActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(rXSmall),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              label,
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

  Widget _buildFailureHint(String? failureKind, ThemeColors tc) {
    final hint = _failureHint(failureKind);
    if (hint == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_outline, size: 13, color: cWarning),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              hint,
              style: TextStyle(
                color: tc.textSub,
                fontSize: fMicro,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _failureHint(String? failureKind) {
    switch (failureKind) {
      case 'disconnected':
        return '连接已断开。建议先重连服务器，再重试本步。';
      case 'timeout':
        return '执行超时。建议延长超时，或把命令拆小后重试。';
      case 'permissionDenied':
        return '权限不足。建议使用 sudo 重试，或更换有权限的用户。';
      case 'interactivePrompt':
        return '命令在等待输入。建议改用非交互参数（如 -y / --batch）后重试。';
      case 'syntaxError':
        return '命令语法错误，未执行。建议修正命令后重试。';
      case 'cancelled':
        return '执行已取消。可以重新发起本步。';
      case 'unknown':
        return '执行失败。建议查看输出后修正并重试。';
      default:
        return null;
    }
  }

  Widget _metaChip(String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(rXSmall),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: fMicro,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  String _failureLabel(String? failureKind) {
    switch (failureKind) {
      case 'disconnected':
        return '连接已断开';
      case 'timeout':
        return '执行超时';
      case 'permissionDenied':
        return '权限不足';
      case 'interactivePrompt':
        return '等待输入';
      case 'syntaxError':
        return '命令语法错误';
      case 'cancelled':
        return '已取消';
      default:
        return '执行失败';
    }
  }

  String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    final seconds = ms / 1000;
    if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
    final minutes = seconds ~/ 60;
    return '${minutes}m${(seconds % 60).round()}s';
  }

  /// 复制按钮（与 AgentCommandBlock._buildCopyButton 行为一致）
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

  /// 任务终态卡片（完成 / 取消 / 失败 / 中断）
  Widget _buildFinishCard(AgentEvent event, ThemeColors tc) {
    final state = event.finishState ?? AgentFinishState.success;
    final (accent, background, title, icon, defaultSummary) = switch (state) {
      AgentFinishState.success => (
          cSuccess,
          cSuccessBg,
          '任务完成',
          Icons.celebration,
          '已完成所有步骤',
        ),
      AgentFinishState.cancelled => (
          cWarning,
          cWarningBg,
          '任务已取消',
          Icons.cancel_outlined,
          '任务已取消',
        ),
      AgentFinishState.failed => (
          cDanger,
          cDangerBg,
          '任务失败',
          Icons.error_outline,
          '任务执行失败',
        ),
      AgentFinishState.interrupted => (
          cWarning,
          cWarningBg,
          '任务已中断',
          Icons.pause_circle_outline,
          '任务被中断',
        ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8, top: 4),
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 15, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: accent,
                    fontSize: fSmall,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                MarkdownBody(
                  data: event.summary ?? defaultSummary,
                  selectable: true,
                  // 规避 flutter_markdown 0.6.23 在 selectable=true 时无条件调用 onSelectionChanged!() 的 bug
                  onSelectionChanged: (_, __, ___) {},
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(
                      color: accent.withValues(alpha: 0.9),
                      fontSize: fBody,
                      fontWeight: FontWeight.w500,
                      height: 1.5,
                    ),
                    h1: TextStyle(
                      color: accent,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    h2: TextStyle(
                      color: accent,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                    h3: TextStyle(
                      color: accent,
                      fontSize: fBody,
                      fontWeight: FontWeight.w600,
                    ),
                    code: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: fMono,
                      backgroundColor: accent.withValues(alpha: 0.1),
                    ),
                    listBullet: TextStyle(color: accent),
                    strong: TextStyle(color: accent, fontWeight: FontWeight.bold),
                    a: TextStyle(color: accent),
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

class _RawOutputTail extends StatefulWidget {
  final String tail;
  final int? totalChars;
  final ThemeColors tc;

  const _RawOutputTail({
    required this.tail,
    required this.totalChars,
    required this.tc,
  });

  @override
  State<_RawOutputTail> createState() => _RawOutputTailState();
}

class _RawOutputTailState extends State<_RawOutputTail> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: tc.terminalBg.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: tc.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(rXSmall),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              child: Row(
                children: [
                  Icon(Icons.subject, size: 12, color: tc.textMuted),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.totalChars != null
                          ? '原始输出尾部 · 共 ${widget.totalChars} 字符'
                          : '原始输出尾部',
                      style: TextStyle(color: tc.textSub, fontSize: fMicro),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => showOutputViewer(
                      context,
                      text: widget.tail,
                      tc: tc,
                      title: '原始输出尾部',
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.open_in_full,
                          size: 13, color: tc.textMuted),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: tc.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(7, 0, 7, 7),
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: tc.terminalBg,
                borderRadius: BorderRadius.circular(rXSmall),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  primary: false,
                  child: SelectableText(
                    widget.tail,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: fMicro,
                      color: tc.textBody,
                      height: 1.4,
                    ),
                  ),
                ),
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
