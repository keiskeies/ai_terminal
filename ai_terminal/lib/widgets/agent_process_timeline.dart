import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_event.dart';
import '../providers/terminal_provider.dart' as tp;
import '../utils/agent_ui_text.dart';
import 'agent_command_block.dart';

/// Agent 过程时间线：把"做了什么"压成一行一步的可折叠流水
///
/// 与操作单分工明确 —— 这里只回答"过程"，结论/变更/回滚仍由 OperationSheet 承担。
/// 渲染规则：
/// - 思考 → 一行淡色文本，超长截断
/// - 工具调用 / shell 命令 → 一行「名称 · 关键参数」+ 尾部状态与耗时
/// - 命令结果不再单独成卡，并进它所属的那一行，点开才展开输出
/// - 需要用户动作的行（待确认、询问、正在执行）**永远不被折叠**，否则用户会被卡住
class AgentProcessTimeline extends StatefulWidget {
  final List<AgentEvent> events;
  final ThemeColors tc;
  final tp.TerminalTab? tab;
  final bool showAutoExecute;
  final bool isLoading;
  final String? executingCommand;
  final String? pendingConfirmCommand;
  final void Function(String command, bool dangerous, tp.TerminalTab tab)?
      onExecuteCommand;
  final void Function(String command)? onConfirmCommand;
  final VoidCallback? onRejectCommand;

  /// 结果详情渲染器（由调用方提供，复用操作单/证据层那套完整实现：
  /// 失败分类、重试与重连按钮、多机矩阵、复制、diff 统计都在里面）。
  /// 时间线自己只负责"一行摘要 + 点开"，不复制渲染逻辑。
  final Widget Function(BuildContext context, AgentEvent result) resultBuilder;

  /// 折叠后仍展示的尾部行数
  final int visibleTail;

  const AgentProcessTimeline({
    super.key,
    required this.events,
    required this.tc,
    this.tab,
    this.showAutoExecute = false,
    this.isLoading = false,
    this.executingCommand,
    this.pendingConfirmCommand,
    this.onExecuteCommand,
    this.onConfirmCommand,
    this.onRejectCommand,
    required this.resultBuilder,
    this.visibleTail = 6,
  });

  @override
  State<AgentProcessTimeline> createState() => _AgentProcessTimelineState();
}

class _AgentProcessTimelineState extends State<AgentProcessTimeline> {
  bool _expanded = false;

  /// 用户手动切换过的行（key 用 command 事件 id，避免位置变化时错位）。
  /// 没记录过的行走默认策略：出问题的行默认展开。
  final Map<String, bool> _rowOpen = {};

  /// 默认展开策略：
  /// - 失败的结果默认展开 —— 把错误和重试按钮藏进一次点击里，用户会以为任务顺利
  /// - 多机结果默认展开 —— 主机矩阵是"哪台没成"的唯一答案
  /// - 成功且已收尾的行才收成一行摘要
  bool _rowOpenedByDefault(AgentEvent commandEvent, AgentEvent? result) {
    if (result == null) return true;
    if (result.success != true) return true;
    if (result.hostResults != null && result.hostResults!.length > 1) return true;
    return false;
  }

  bool _isOpen(AgentEvent commandEvent, AgentEvent? result) {
    return _rowOpen[commandEvent.id] ?? _rowOpenedByDefault(commandEvent, result);
  }

  void _toggleRow(AgentEvent commandEvent, AgentEvent? result) {
    setState(() {
      _rowOpen[commandEvent.id] =
          !_isOpen(commandEvent, result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.events;
    if (events.isEmpty) return const SizedBox.shrink();

    final resultMap = <String, AgentEvent>{};
    for (final e in events) {
      if (e.isResult && e.commandId != null) resultMap[e.commandId!] = e;
    }

    // 先把事件折成"行"：result 不再独立成行，而是挂到它的 command 上
    final rows = <_TimelineRow>[];
    final orphans = <AgentEvent>[];
    for (final e in events) {
      switch (e.type) {
        case AgentEventType.thought:
          if ((e.text ?? '').trim().isNotEmpty) {
            rows.add(_TimelineRow.thought(e));
          }
          break;
        case AgentEventType.command:
          rows.add(_TimelineRow.call(e, result: resultMap[e.id]));
          break;
        case AgentEventType.result:
          // 找不到对应 command 的结果（旧数据/裁剪）仍要露出来
          if (e.commandId == null ||
              !events.any((c) => c.id == e.commandId && c.isCommand)) {
            orphans.add(e);
          }
          break;
        case AgentEventType.ask:
          rows.add(_TimelineRow.interactive(e));
          break;
        case AgentEventType.info:
          if ((e.text ?? '').trim().isNotEmpty) {
            rows.add(_TimelineRow.note(e));
          }
          break;
        case AgentEventType.text:
        case AgentEventType.finish:
        case AgentEventType.report:
        case AgentEventType.plan:
          // 正文/结论/操作单/执行清单由外层渲染，时间线只放过程
          break;
      }
    }

    // 哪些行可以被折叠：已出结果、且不是当前正在跑/等确认的行
    bool collapsible(_TimelineRow r) {
      switch (r.kind) {
        case _RowKind.thought:
        case _RowKind.note:
          return true;
        case _RowKind.call:
          final cmd = r.event.command ?? '';
          if (r.result != null) return true;
          if (widget.executingCommand == cmd) return false;
          if (widget.pendingConfirmCommand == cmd) return false;
          // 没有结果也没在执行：要么已跳过，要么在等确认 —— 保守起见不折
          return false;
        case _RowKind.interactive:
          return false;
      }
    }

    final foldableIndexes = <int>[
      for (var i = 0; i < rows.length; i++)
        if (collapsible(rows[i])) i
    ];
    final hiddenCount = _expanded
        ? 0
        : (foldableIndexes.length - widget.visibleTail)
            .clamp(0, foldableIndexes.length);
    final hidden = foldableIndexes.take(hiddenCount).toSet();

    final children = <Widget>[];
    // 只有真的藏了行才出折叠头部，否则会出现"更早 0 步"这种没意义的控件
    if (hidden.isNotEmpty) {
      children.add(_header(rows, hidden));
    }
    for (var i = 0; i < rows.length; i++) {
      if (hidden.contains(i)) continue;
      final r = rows[i];
      switch (r.kind) {
        case _RowKind.call:
          children.add(_callRow(r));
          break;
        case _RowKind.thought:
        case _RowKind.note:
          children.add(_textRow(r));
          break;
        case _RowKind.interactive:
          children.add(_AskRow(event: r.event, tc: widget.tc));
          break;
      }
    }
    for (final o in orphans) {
      children.add(_resultFallback(o));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }


  /// 头部：一行统计 + 展开/收起（仅在确实藏了行时渲染）
  Widget _header(List<_TimelineRow> rows, Set<int> hidden) {
    final tc = widget.tc;
    final ui = AgentUiText.of(context);
    final calls = rows.where((r) => r.kind == _RowKind.call).length;
    final toolCalls = rows
        .where((r) => r.kind == _RowKind.call && (r.event.toolName != null))
        .length;
    final parts = <String>[
      if (toolCalls > 0) ui.toolCallsCount(toolCalls),
      if (calls - toolCalls > 0) ui.commandCallsCount(calls - toolCalls),
    ];
    final label = _expanded
        ? ui.collapseProcess
        : '${parts.isEmpty ? ui.processFolded : parts.join(' · ')}'
            ' · ${ui.moreSteps(hidden.length)}';

    return InkWell(
      borderRadius: BorderRadius.circular(rXSmall),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(_expanded ? Icons.expand_less : Icons.chevron_right,
                size: 15, color: tc.textMuted),
            const SizedBox(width: 4),
            Expanded(
              child: Text(label,
                  style: TextStyle(color: tc.textSub, fontSize: fMicro)),
            ),
            if (hidden.isNotEmpty)
              Text(_expanded ? ui.collapse : ui.expandProcess,
                  style: TextStyle(color: tc.textSub, fontSize: fMicro)),
          ],
        ),
      ),
    );
  }

  /// 工具/命令行：一行摘要 + 尾部状态与耗时，点击展开参数与输出
  Widget _callRow(_TimelineRow row) {
    final tc = widget.tc;
    final ui = AgentUiText.of(context);
    final e = row.event;
    final result = row.result;
    final isTool = e.toolName != null && e.toolName != 'exec_command';
    final opened = _isOpen(e, result);

    // 还没结果 = 用户可能要对这一行做点什么（执行/确认/拒绝/看变更影响）。
    // 这类行退回重量级命令块：播放按钮、风险说明与回滚提示都在那里，不能压成一行。
    final needsAction = result == null;
    if (needsAction) {
      return AgentCommandBlock(
        command: e.command ?? '',
        tc: tc,
        tab: widget.tab,
        showAutoExecute: widget.showAutoExecute,
        isLoading: widget.isLoading,
        executingCommand: widget.executingCommand,
        pendingConfirmCommand: widget.pendingConfirmCommand,
        isTool: isTool,
        executed: false,
        riskLevel: e.riskLevel,
        permissionDecision: e.permissionDecision,
        onExecute: widget.onExecuteCommand,
        onConfirm: widget.onConfirmCommand,
        onReject: widget.onRejectCommand,
      );
    }

    // 走到这里 result 一定非空（无结果的行已在上面退回重量级命令块）
    final ok = result.success == true;
    final statusColor = ok ? tc.ok : tc.error;
    final statusText = ok
        ? (isTool ? ui.toolDoneLabel : ui.executedLabel)
        : ui.failedLabel;
    final duration = result.durationMs;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: tc.terminalOutput.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: tc.border.withValues(alpha: 0.6), width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _toggleRow(e, result),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                children: [
                  Icon(
                    isTool ? Icons.auto_awesome : Icons.terminal,
                    size: 13,
                    color: isTool ? tc.brand : tc.ok,
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 92,
                    child: Text(
                      isTool ? (e.toolName ?? 'tool') : ui.commandLabel,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isTool ? tc.brand : tc.ok,
                        fontSize: fMicro,
                        fontFamily: 'JetBrainsMono',
                        fontFamilyFallback: kMonoFontFallback,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _subject(e, isTool),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tc.textBody, fontSize: fMicro),
                    ),
                  ),
                  if (duration != null && duration > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text('${duration}ms',
                          style: TextStyle(
                              color: tc.textMuted, fontSize: fMicro)),
                    ),
                  Text(
                    statusText,
                    style: TextStyle(color: statusColor, fontSize: fMicro),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.circle, size: 6, color: statusColor),
                  const SizedBox(width: 4),
                  Icon(opened ? Icons.expand_less : Icons.expand_more,
                      size: 14, color: tc.textMuted),
                ],
              ),
            ),
          ),
          if (opened) _detail(e, result),
        ],
      ),
    );
  }

  /// 行内摘要：工具取最能定位的那条参数，命令取命令行本身
  String _subject(AgentEvent e, bool isTool) {
    final raw = e.command ?? '';
    if (!isTool) {
      final firstLine = raw.split('\n').first.trim();
      return firstLine.isEmpty ? raw.trim() : firstLine;
    }
    // command 事件里存的是 "tool_name\n  key: value" 多行格式，取关键参数
    final parts = raw.split('\n').skip(1);
    const priority = [
      'path', 'command', 'query', 'remote', 'local', 'url', 'hostIds', 'action'
    ];
    String? fallback;
    for (final line in parts) {
      final idx = line.indexOf(':');
      if (idx < 0) continue;
      final key = line.substring(0, idx).trim();
      final value = line.substring(idx + 1).trim();
      if (value.isEmpty) continue;
      if (priority.contains(key)) return value;
      fallback ??= value;
    }
    return fallback ?? raw.split('\n').first.trim();
  }

  Widget _detail(AgentEvent commandEvent, AgentEvent result) {
    final tc = widget.tc;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tc.border, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            commandEvent.command ?? '',
            style: TextStyle(
              fontSize: fMicro,
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: kMonoFontFallback,
              color: tc.textSub,
            ),
          ),
          const SizedBox(height: 6),
          widget.resultBuilder(context, result),
        ],
      ),
    );
  }

  Widget _textRow(_TimelineRow row) {
    final tc = widget.tc;
    final text = (row.event.text ?? '').trim();
    final isNote = row.kind == _RowKind.note;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 6),
            child: Icon(
              isNote ? Icons.info_outline : Icons.psychology_outlined,
              size: 12,
              color: tc.textMuted,
            ),
          ),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tc.textMuted, fontSize: fMicro),
            ),
          ),
        ],
      ),
    );
  }

  /// 没有父命令的结果（历史数据兜底）
  Widget _resultFallback(AgentEvent result) {
    final tc = widget.tc;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: tc.terminalOutput,
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: tc.border, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(
            result.success == true ? Icons.check_circle : Icons.error_outline,
            size: 13,
            color: result.success == true ? tc.ok : tc.error,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              (result.output ?? result.error ?? '').split('\n').first,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tc.textSub, fontSize: fMicro),
            ),
          ),
        ],
      ),
    );
  }
}

/// 时间线的一行
class _TimelineRow {
  final _RowKind kind;
  final AgentEvent event;
  final AgentEvent? result;

  const _TimelineRow.thought(this.event) : kind = _RowKind.thought, result = null;
  const _TimelineRow.note(this.event) : kind = _RowKind.note, result = null;
  const _TimelineRow.interactive(this.event)
      : kind = _RowKind.interactive,
        result = null;
  const _TimelineRow.call(this.event, {this.result}) : kind = _RowKind.call;
}

enum _RowKind { thought, note, call, interactive }

/// 询问行：保持可点，不参与折叠
class _AskRow extends StatelessWidget {
  final AgentEvent event;
  final ThemeColors tc;
  const _AskRow({required this.event, required this.tc});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tc.warn.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: tc.warn.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Text(
        event.question ?? event.text ?? '',
        style: TextStyle(color: tc.textMain, fontSize: fSmall),
      ),
    );
  }
}
