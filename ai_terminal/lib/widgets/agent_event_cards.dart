import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_event.dart';
import '../providers/terminal_provider.dart' as tp;
import '../utils/agent_ui_text.dart';
import 'agent_process_timeline.dart';
import 'host_result_matrix.dart';
import 'output_viewer_sheet.dart';
import '../core/app_toast.dart';

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

  /// 结构化事件列表渲染
  ///
  /// 事件必须**按原始顺序**交错渲染：过程段（思考 / 命令 / 工具 / 结果）攒成
  /// 一段交时间线，遇到正文、询问、完成卡就切段。早先把所有过程事件汇总成
  /// 一条时间线、再把所有正文/询问接在后面，会让询问卡片永远沉在消息底部——
  /// 用户选完后新执行的命令反而出现在它上面，看起来像选择卡被钉住了。
  ///
  /// 命令与结果的配对不能因为切段而丢：结果通过全局 `resultByCommand`
  /// 挂到对应的命令行上，并在原位置跳过，避免同一个调用渲染两遍。
  Widget _buildEventsContent(BuildContext context) {
    final resultByCommand = <String, AgentEvent>{};
    final commandIds = <String>{};
    for (final e in events) {
      if (e.isCommand) commandIds.add(e.id);
    }
    for (final e in events) {
      if (!e.isResult) continue;
      final commandId = e.commandId;
      // 只登记"确实有对应命令"的结果；孤儿结果要留在原地单独渲染，
      // 不能被误认为已配对而跳过。
      if (commandId == null || !commandIds.contains(commandId)) continue;
      resultByCommand[commandId] = e;
    }

    final widgets = <Widget>[];
    final segment = <AgentEvent>[];
    final textBuffer = StringBuffer();
    final consumedResults = <String>{};
    final pendingAskId = isWaitingChoice ? _lastAskId(events) : null;

    void flushText() {
      final text = textBuffer.toString().trim();
      if (text.isNotEmpty) {
        widgets.add(markdownBuilder(text, tc));
        textBuffer.clear();
      }
    }

    void flushSegment() {
      if (segment.isEmpty) return;
      final segmentEvents = List<AgentEvent>.of(segment);
      segment.clear();
      widgets.add(AgentProcessTimeline(
        key: ValueKey('agent-process-${segmentEvents.first.id}'),
        events: segmentEvents,
        tc: tc,
        tab: tab,
        showAutoExecute: showAutoExecute,
        isLoading: isLoading,
        executingCommand: executingCommand,
        pendingConfirmCommand: pendingConfirmCommand,
        onExecuteCommand: onExecuteCommand,
        onConfirmCommand: onConfirmCommand,
        onRejectCommand: onRejectCommand,
        resultBuilder: (ctx, result) => _buildResultCard(result, tc, ctx),
      ));
    }

    for (final event in events) {
      switch (event.type) {
        case AgentEventType.thought:
        case AgentEventType.info:
          flushText();
          segment.add(event);
          break;
        case AgentEventType.command:
          flushText();
          segment.add(event);
          final result = resultByCommand[event.id];
          if (result != null && consumedResults.add(result.id)) {
            // 结果紧跟命令行进同一段，时间线才能配对
            segment.add(result);
          }
          break;
        case AgentEventType.result:
          // 已挂到命令行，或稍后会随命令行一起渲染
          if (consumedResults.contains(event.id)) break;
          if (event.commandId != null &&
              resultByCommand[event.commandId!]?.id == event.id) {
            break;
          }
          // 找不到命令的孤儿结果仍要露出来
          flushText();
          segment.add(event);
          break;
        case AgentEventType.text:
          flushSegment();
          if (event.text != null && event.text!.trim().isNotEmpty) {
            textBuffer.writeln(event.text);
          }
          break;
        case AgentEventType.ask:
          flushSegment();
          flushText();
          widgets.add(_buildAskCard(
            event,
            tc,
            pending: event.id == pendingAskId,
          ));
          break;
        case AgentEventType.finish:
          flushSegment();
          flushText();
          widgets.add(_buildFinishCard(event, tc));
          break;
        case AgentEventType.report:
        case AgentEventType.plan:
          // 操作单由 OperationSheet、执行清单由 PlanPanel 单独渲染；
          // 它们没有行内内容，不应打断过程段的连续渲染。
          break;
      }
    }
    flushSegment();
    flushText();

    // 兜底：若有 pendingOptions 但没有 ask 事件（旧格式），显示选项按钮
    if (isWaitingChoice && !events.any((e) => e.isAsk)) {
      if (pendingOptions.isNotEmpty) {
        widgets.add(buildOptionButtons(pendingOptions, tc, false,
            onSelectChoice: onSelectChoice));
      }
      if (onSelectChoice != null) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: AskCustomAnswerField(
            tc: tc,
            onSubmit: (answer) => onSelectChoice?.call(answer),
          ),
        ));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  /// 当前处于等待状态的询问：只允许最后一个 ask 卡片可点。
  /// 旧询问在历史里继续显示，但不能再被当成当前问题作答。
  static String? _lastAskId(List<AgentEvent> events) {
    for (var i = events.length - 1; i >= 0; i--) {
      if (events[i].isAsk) return events[i].id;
    }
    return null;
  }

  /// 结果卡片：成功/失败状态 + 输出（全部展开显示）
  /// 背景保持 terminalBg，无左侧缩进，与命令块视觉对齐
  Widget _buildResultCard(AgentEvent event, ThemeColors tc, BuildContext context) {
    final ui = AgentUiText.of(context);
    final success = event.success ?? false;
    final output = event.output ?? event.error ?? '(无输出)';
    final lines = output.split('\n');
    final hostResults = event.hostResults;
    final showMatrix = hostResults != null && hostResults.length > 1;

    final statusColor = success ? tc.ok : tc.error;
    final statusBg = success
        ? tc.ok.withValues(alpha: 0.08)
        : tc.error.withValues(alpha: 0.08);
    final statusIcon = success ? Icons.check : Icons.close;
    final statusText = success
        ? ui.resultSuccess
        : ui.failureLabel(event.failureKind);

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
                        _metaChip(ui.exitCode(event.exitCode!), tc.error),
                      if (event.durationMs != null)
                        _metaChip(
                            _formatDuration(event.durationMs!), tc.gold),
                      if (event.outputTruncated == true)
                        _metaChip(
                          event.outputTotalChars != null
                              ? ui.truncated(event.outputTotalChars)
                              : ui.truncated(),
                          tc.warn,
                        ),
                      if (event.diffAdditions != null)
                        _metaChip('+${event.diffAdditions}', tc.ok),
                      if (event.diffDeletions != null)
                        _metaChip('-${event.diffDeletions}', tc.error),
                      if (!showMatrix)
                        _metaChip(ui.outputLines(lines.length), tc.textSub),
                    ],
                  ),
                ),
                // 复制按钮：与命令块体验一致，一键复制输出
                _buildCopyButton(output, tc, context),
              ],
            ),
          ),
          if (!success) _buildFailureHint(event.failureKind, tc, ui),
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
                        color: tc.warn,
                        onTap: () => onReconnectHost!(event),
                      ),
                    if (onRetryFailedCommand != null &&
                        (event.command ?? '').trim().isNotEmpty)
                      _failureActionButton(
                        icon: Icons.refresh,
                        label: '让 AI 重试',
                        color: tc.brand,
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
                  Text(
                    output.trimRight(),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                      fontSize: fMono,
                      color: tc.textBody,
                      height: 1.45,
                      fontWeight: FontWeight.w500,
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

  Widget _buildFailureHint(
      String? failureKind, ThemeColors tc, AgentUiText ui) {
    final hint = ui.failureHint(failureKind);
    if (hint == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, size: 13, color: tc.brand),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              hint,
              style: TextStyle(
                color: tc.textSub,
                fontSize: fMicro,
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
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
        clearTopToast();
        showTopSnackBar(context, 
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
        child: Icon(Icons.copy, size: 13, color: tc.textSub),
      ),
    );
  }

  /// 询问卡片：问题 + 选项按钮
  ///
  /// [pending] 只对当前仍在等待的那一个询问为 true；历史询问保留问题文本，
  /// 但选项不可再点，避免用户回头误答一个已经结束的问题。
  Widget _buildAskCard(AgentEvent event, ThemeColors tc,
      {required bool pending}) {
    final options = event.options ?? [];
    final question = event.question ?? '请选择';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tc.brand.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.brand.withValues(alpha: 0.18)),
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
                  color: tc.brand.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.help_outline,
                    size: 13, color: tc.brand),
              ),
              const SizedBox(width: 8),
              Expanded(
                // 问题正文可能带 Markdown（表格/加粗/列表），
                // 与普通正文共用同一套渲染，避免把表格原样显示成竖线文本。
                child: markdownBuilder(question, tc),
              ),
            ],
          ),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: options.map((opt) {
                return _buildOptionChip(opt, tc, selectable: pending);
              }).toList(),
            ),
          ],
          if (pending && onSelectChoice != null) ...[
            const SizedBox(height: 10),
            AskCustomAnswerField(
              tc: tc,
              onSubmit: (answer) => onSelectChoice?.call(answer),
            ),
          ],
        ],
      ),
    );
  }

  /// [selectable] 为 false 时选项仍在界面上展示（历史回看/任务已推进），
  /// 只是不可点击 —— 否则用户回头只会看到一张没有选项的"请选择"卡片。
  Widget _buildOptionChip(String label, ThemeColors tc,
      {required bool selectable}) {
    final accent = selectable ? tc.brand : tc.textMuted;
    return GestureDetector(
      onTap: selectable ? () => onSelectChoice?.call(label) : null,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: tc.surface,
          borderRadius: BorderRadius.circular(rMedium),
          border: Border.all(
              color: accent.withValues(alpha: selectable ? 0.3 : 0.18)),
          boxShadow: [
            BoxShadow(
              color: tc.brand.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selectable ? Icons.touch_app : Icons.radio_button_unchecked,
                size: 12, color: accent),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: fSmall,
                color: accent,
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
          tc.ok,
          tc.okBg,
          '任务完成',
          Icons.celebration,
          '已完成所有步骤',
        ),
      AgentFinishState.cancelled => (
          tc.warn,
          tc.warnBg,
          '任务已取消',
          Icons.cancel_outlined,
          '任务已取消',
        ),
      AgentFinishState.failed => (
          tc.error,
          tc.errorBg,
          '任务失败',
          Icons.error_outline,
          '任务执行失败',
        ),
      AgentFinishState.interrupted => (
          tc.warn,
          tc.warnBg,
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
                  // 选区由 Agent 聊天列表外层的 SelectionArea 统一管理
                  selectable: false,
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
                      fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                      fontSize: fMono,
                      color: accent,
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(rXSmall),
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
                  child: Text(
                    widget.tail,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
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
        final color = isPrimary ? tc.brand : tc.textMain;
        final bgColor = isPrimary
            ? tc.brand.withValues(alpha: disabled ? 0.1 : 0.15)
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

/// ask 选项之外的自由输入：按钮覆盖不到用户想法时，直接回一句话。
class AskCustomAnswerField extends StatefulWidget {
  final ThemeColors tc;
  final void Function(String answer) onSubmit;

  const AskCustomAnswerField({
    super.key,
    required this.tc,
    required this.onSubmit,
  });

  @override
  State<AskCustomAnswerField> createState() => _AskCustomAnswerFieldState();
}

class _AskCustomAnswerFieldState extends State<AskCustomAnswerField> {
  final _controller = TextEditingController();
  bool _submitted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit([String? _]) {
    final text = _controller.text.trim();
    if (text.isEmpty || _submitted) return;
    _submitted = true;
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(rSmall),
      borderSide: BorderSide(color: tc.border),
    );
    return TextField(
      controller: _controller,
      style: TextStyle(color: tc.textMain, fontSize: fSmall),
      cursorColor: tc.brand,
      textInputAction: TextInputAction.send,
      onSubmitted: (value) => _submit(value),
      decoration: InputDecoration(
        isDense: true,
        hintText: '按钮都不合适？直接输入你的回答…',
        hintStyle: TextStyle(color: tc.textMuted, fontSize: fSmall),
        filled: true,
        fillColor: tc.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rSmall),
          borderSide: BorderSide(color: tc.brand.withValues(alpha: 0.5)),
        ),
        suffixIcon: IconButton(
          tooltip: '发送自定义回答',
          icon: Icon(Icons.send, size: 16, color: tc.brand),
          onPressed: _submit,
        ),
        suffixIconConstraints:
            const BoxConstraints(minWidth: 36, minHeight: 32),
      ),
    );
  }
}
