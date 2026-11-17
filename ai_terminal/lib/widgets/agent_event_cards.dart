import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_event.dart';
import '../providers/terminal_provider.dart' as tp;
import '../utils/agent_ui_text.dart';
import '../core/ui_text.dart';
import 'agent_process_timeline.dart';
import 'agent_ask_card.dart';
import 'host_result_matrix.dart';
import 'output_viewer_sheet.dart';
import '../core/app_toast.dart';

/// 旧名保留：外部引用的是 `AskCustomAnswerField`
typedef AskCustomAnswerField = AgentAskCustomAnswerField;

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
/// 回答正文的框：与命令行 / 结果卡同一套（透明填充 + 0.5px 边框 + rCard 圆角，
/// 内边距同过程卡片的 12/10）。
///
/// 正文原来直接铺在面板上：上下都是带边框的卡片，只有中间这段大字没有容器，
/// 看着像"溢出到卡片之外"的文字。给它一个同样克制的框，阅读区才立得住。
Widget agentAnswerCard(Widget child, ThemeColors tc) {
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.symmetric(vertical: 3),
    // 底 6 + Markdown 自带的 4px 底距 = 10，与上边距对称
    padding: const EdgeInsets.fromLTRB(pCompact, pModule, pCompact, 6),
    decoration: BoxDecoration(
      color: tc.agentCardFill,
      borderRadius: BorderRadius.circular(rCard),
      // 与命令行 / 结果卡 / 执行清单同一套边框线
      border: Border.all(color: tc.agentCardBorder, width: 1),
    ),
    child: child,
  );
}

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

  /// 正在流式产生的模型原生推理，交给时间线渲染成末尾的思考行
  final String liveReasoning;

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
    this.liveReasoning = '',
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
        widgets.add(agentAnswerCard(markdownBuilder(text, tc), tc));
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
        // 只有最后一段（当前正在推进的那一段）才挂实时推理：
        // 实时推理永远发生在时间线的末尾
        liveReasoning: segmentEvents.last.id == events.last.id
            ? liveReasoning
            : '',
        resultBuilder: (ctx, result) => _buildResultCard(result, tc, ctx),
        // 询问行的渲染交给时间线：提问是流程里的一步，不是流程外的一块卡片
        askBuilder: (ctx, ask) =>
            _buildAskStep(ctx, ask, events, pendingAskId),
      ));
    }

    for (final event in events) {
      switch (event.type) {
        case AgentEventType.thought:
          flushText();
          segment.add(event);
          break;
        case AgentEventType.info:
          flushText();
          // 「👉 你选择了 X」不再单独占一行：答案已经显示在提问步骤的胶囊里，
          // 重复一遍等于同一条信息说两次。
          if (_isChoiceNote(event, events)) break;
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
          // 提问留在过程段里（不切段）：它和思考/命令是同一条时间线上的步骤，
          // 切出去会变成"浮在流程之外的一块"，答完后更难看出问过什么。
          flushText();
          segment.add(event);
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

  /// 这条 info 是不是「用户选择了 X」的回执。
  ///
  /// 它是提问步骤的附属信息，不是独立的一步：答案已经写在提问步骤里，
  /// 再单独渲染一行就是把同一件事说两遍。
  static bool _isChoiceNote(AgentEvent event, List<AgentEvent> events) {
    if (!event.isInfo) return false;
    final text = (event.text ?? '').trim();
    if (!text.contains('你选择了') && !text.contains('You chose')) {
      return false;
    }
    // 必须真的有对应的提问，否则这条提示本身就是唯一的信息，不能吞掉
    return events.any((e) => e.isAsk);
  }

  /// 询问行的渲染：等待作答 → 完整卡片；已作答 → 可收起展开的步骤行。
  ///
  /// 提问是流程里的一步：等待作答时必须完整可见（用户要能立刻选），
  /// 答完后收成一行（问题 + 答案胶囊），点开才看到完整问题与当时的选项。
  /// 绝不能"答完就没"——那样时间线上就看不出这一轮问过什么。
  Widget _buildAskStep(BuildContext context, AgentEvent ask,
      List<AgentEvent> allEvents, String? pendingAskId) {
    final isPending = isWaitingChoice && ask.id == pendingAskId;
    if (isPending) {
      return AgentAskCard(
        event: ask,
        tc: tc,
        markdownBuilder: markdownBuilder,
        onSelectChoice: onSelectChoice,
      );
    }
    final chosen = ask.chosenAnswer ?? _chosenAnswerFor(allEvents, ask);
    // key 用**位置**而不是事件 id：内容相同的两轮提问可能拿到同一个 id
    // （引擎已改成全局递增序号，但历史数据仍可能重复），
    // 用 id 做 key 会撞 Flutter 的重复 key，整块提问步骤直接渲染失败。
    final index = allEvents.indexWhere((e) => identical(e, ask));
    return AgentAskStepRow(
      key: ValueKey('ask-step-$index-${ask.id}'),
      event: ask,
      chosen: chosen,
      tc: tc,
      expanded: AgentAskCard(
        event: ask,
        tc: tc,
        markdownBuilder: markdownBuilder,
      ),
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

  /// 在 ask 事件之后找「用户选择了 xxx」的 info 事件，提取答案文本。
  /// 时间线里的询问行要显示用户到底选了什么。
  static String? _chosenAnswerFor(List<AgentEvent> events, AgentEvent ask) {
    final idx = events.indexOf(ask);
    if (idx < 0) return null;
    final pattern = RegExp(r'(?:你选择了|You chose)[：:]\s*(.+)$');
    for (var i = idx + 1; i < events.length; i++) {
      final e = events[i];
      if (e.isAsk) break; // 下一次询问开始还没答案
      if (!e.isInfo) continue;
      final m =
          pattern.firstMatch((e.text ?? '').trim());
      if (m != null) {
        final answer = m.group(1)?.trim();
        if (answer != null && answer.isNotEmpty) return answer;
      }
    }
    return null;
  }

  /// 结果卡片：成功/失败状态 + 输出（全部展开显示）
  /// 背景保持 terminalBg，无左侧缩进，与命令块视觉对齐
  Widget _buildResultCard(AgentEvent event, ThemeColors tc, BuildContext context) {
    final ui = AgentUiText.of(context);
    final success = event.success ?? false;
    final output = event.output ?? event.error ??
        UiText.t('(无输出)', '(no output)');
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
        color: tc.agentCardFill,
        borderRadius: BorderRadius.circular(rCard),
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
                      // 设计稿 stchip：成功也展示退出码（exit 0 用成功色）
                      if (event.exitCode != null)
                        _metaChip(ui.exitCode(event.exitCode!),
                            success ? tc.ok : tc.error),
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
                        label: UiText.t('重连', 'Reconnect'),
                        color: tc.warn,
                        onTap: () => onReconnectHost!(event),
                      ),
                    if (onRetryFailedCommand != null &&
                        (event.command ?? '').trim().isNotEmpty)
                      _failureActionButton(
                        icon: Icons.refresh,
                        label: UiText.t('让 AI 重试', 'Ask AI to retry'),
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
                  _ResultOutputPreview(
                    output: output,
                    failed: !success,
                    tc: tc,
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
    final ui = AgentUiText.of(context);
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: text));
        clearTopToast();
        showTopSnackBar(context, 
          SnackBar(
            content: Text(ui.copied, style: const TextStyle(fontSize: fSmall)),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
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

  /// 任务终态卡片（完成 / 取消 / 失败 / 中断）
  Widget _buildFinishCard(AgentEvent event, ThemeColors tc) {
    final state = event.finishState ?? AgentFinishState.success;
    final (accent, _, title, icon, defaultSummary) = switch (state) {
      AgentFinishState.success => (
          tc.ok,
          tc.okBg,
          UiText.t('任务完成', 'Task complete'),
          Icons.celebration,
          UiText.t('已完成所有步骤', 'All steps finished'),
        ),
      AgentFinishState.cancelled => (
          tc.warn,
          tc.warnBg,
          UiText.t('任务已取消', 'Task cancelled'),
          Icons.cancel_outlined,
          UiText.t('任务已取消', 'Task cancelled'),
        ),
      AgentFinishState.failed => (
          tc.error,
          tc.errorBg,
          UiText.t('任务失败', 'Task failed'),
          Icons.error_outline,
          UiText.t('任务执行失败', 'Task execution failed'),
        ),
      AgentFinishState.interrupted => (
          tc.warn,
          tc.warnBg,
          UiText.t('任务已中断', 'Task interrupted'),
          Icons.pause_circle_outline,
          UiText.t('任务被中断', 'Task was interrupted'),
        ),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8, top: 4),
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tc.agentCardFill,
        borderRadius: BorderRadius.circular(rCard),
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
      margin: const EdgeInsets.only(top: pSmall),
      decoration: BoxDecoration(
        color: tc.agentCardFill,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(rSmall),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.subject, size: 12, color: tc.textMuted),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.totalChars != null
                          ? UiText.t('原始输出尾部 · 共 ${widget.totalChars} 字符',
                              'Raw output tail · ${widget.totalChars} chars total')
                          : UiText.t('原始输出尾部', 'Raw output tail'),
                      style: TextStyle(color: tc.textSub, fontSize: fMicro),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => showOutputViewer(
                      context,
                      text: widget.tail,
                      tc: tc,
                      title: UiText.t('原始输出尾部', 'Raw output tail'),
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
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                // 设计稿 mono-block：输出正文统一比卡片深一档 + 发丝边框
                color: tc.terminalBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: tc.hairline, width: 1),
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

/// 结果输出预览：卡片里最多 12 行，其余进"查看完整输出"弹层。
///
/// 一次 `Get-ChildItem -Recurse` 就能刷出几千字符，全量摊在证据层里会把
/// 结论与失败原因一起挤出屏幕；失败时改看尾部，错误通常在最后。
class _ResultOutputPreview extends StatelessWidget {
  const _ResultOutputPreview({
    required this.output,
    required this.failed,
    required this.tc,
  });

  static const int _previewLines = 12;

  final String output;
  final bool failed;
  final ThemeColors tc;

  @override
  Widget build(BuildContext context) {
    final ui = AgentUiText.of(context);
    final lines = output.replaceAll('\r\n', '\n').split('\n');
    final hidden = lines.length - _previewLines;
    final shown = hidden > 0
        ? (failed
            ? lines.skip(lines.length - _previewLines).join('\n')
            : lines.take(_previewLines).join('\n'))
        : output;
    final textStyle = TextStyle(
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: kMonoFontFallback,
      fontSize: fMono,
      color: tc.textBody,
      height: 1.45,
      fontWeight: FontWeight.w500,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 设计稿 mono-block：比卡片再深一档的底 + 发丝边框，输出区视觉下沉
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            color: tc.terminalBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: tc.hairline, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 失败时看的是尾部，被省略的部分在前面
              if (hidden > 0 && failed) Text('…', style: textStyle),
              Text(shown.trimRight(), style: textStyle),
            ],
          ),
        ),
        if (hidden > 0)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showOutputViewer(
              context,
              text: output,
              tc: tc,
              title: UiText.t('命令输出', 'Command output'),
            ),
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.open_in_full, size: 11, color: tc.textSub),
                  const SizedBox(width: 4),
                  Text(
                    '${ui.moreOutputLines(hidden)} · ${ui.viewFullOutput}',
                    style: TextStyle(color: tc.textSub, fontSize: fMicro),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
