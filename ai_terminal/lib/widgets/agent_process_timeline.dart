import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/agent_event.dart';
import '../providers/terminal_provider.dart' as tp;
import '../utils/agent_ui_text.dart';
import '../utils/risk_explainer.dart';
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

  /// 询问行渲染器（由调用方提供）。
  ///
  /// 提问和命令一样是流程里的一步，但它的"等待作答 / 已作答"两种形态
  /// 差异很大（可点选项 vs 收起的一行），交给调用方决定。
  final Widget Function(BuildContext context, AgentEvent ask)? askBuilder;

  /// 正在流式产生的模型原生推理（reasoning_content）。
  ///
  /// 它渲染成时间线**末尾**的一行思考，而不是浮在整条回答顶部的独立块：
  /// 思考本来就发生在命令之前、答案之后的位置上，浮在顶部会让人以为它属于
  /// 上一轮；步骤结束时这段推理会被固化成同位置的思考事件，两者无缝衔接，
  /// 不会出现"闪一下就没了"。
  final String liveReasoning;

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
    this.askBuilder,
    this.liveReasoning = '',
  });

  @override
  State<AgentProcessTimeline> createState() => _AgentProcessTimelineState();
}

class _AgentProcessTimelineState extends State<AgentProcessTimeline> {
  /// 用户手动切换过的命令/工具行（key 用事件 id，避免位置变化时错位）
  final Map<String, bool> _rowOpen = {};

  /// 被展开的长思考（默认 3 行，点开看全文）
  final Set<String> _openThoughts = {};

  /// 展开逐条的进度组（key 用组内第一条事件 id）
  final Set<String> _openProgress = {};

  /// `上传进度: 1/100 文件` —— 前缀 + 分子/分母 + 单位
  static final RegExp _progressPattern =
      RegExp(r'^(.{2,}?)[：:]\s*(\d+)\s*/\s*(\d+)(.*)$');

  /// 默认展开策略：**只有还没出结果的行**展开（执行/确认/看变更影响都在里面）。
  ///
  /// 失败行不再自动铺开 —— 一行「✗ 失败」已经说明问题，错误输出点开再看，
  /// 十几条失败同时摊开会把真正的流程挤出屏幕。
  bool _rowOpenedByDefault(AgentEvent commandEvent, AgentEvent? result) {
    return result == null;
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
    final commandIds = <String>{};
    for (final e in events) {
      if (e.isResult && e.commandId != null) resultMap[e.commandId!] = e;
      if (e.isCommand) commandIds.add(e.id);
    }

    // 哪些命令执行前曾请用户确认：引擎在执行前紧跟着发一条「需要确认」info。
    // 执行后靠它把确认记录留在行上，否则确认卡一执行就整块消失。
    final confirmedIds = <String>{};
    String? askingCommandId;
    for (final e in events) {
      if (e.isCommand) {
        askingCommandId = e.id;
      } else if (e.type == AgentEventType.info) {
        if (askingCommandId != null &&
            (e.text ?? '').contains('需要确认')) {
          confirmedIds.add(askingCommandId);
        }
        askingCommandId = null;
      } else if (!e.isResult) {
        askingCommandId = null;
      }
    }

    // 先把事件折成"行"：result 不再独立成行，而是挂到它的 command 上
    final rows = <_TimelineRow>[];
    final orphans = <AgentEvent>[];
    // 相邻思考只留最后一条：双语模型会在 reasoning_content 里用英文推理、
    // 又在「思考:」行里用中文写一遍，两条相邻地挤在一起就是"中英双译"。
    // 中间没有插任何动作的连续思考是同一步的重复表述，最后的才是定稿。
    _TimelineRow? pendingThought;
    void flushThought() {
      final p = pendingThought;
      if (p != null) rows.add(p);
      pendingThought = null;
    }

    for (final e in events) {
      switch (e.type) {
        case AgentEventType.thought:
          if ((e.text ?? '').trim().isNotEmpty) {
            flushThought();
            pendingThought = _TimelineRow.thought(e);
          }
          break;
        case AgentEventType.command:
          flushThought();
          rows.add(_TimelineRow.call(e, result: resultMap[e.id]));
          break;
        case AgentEventType.result:
          // 找不到对应 command 的结果（旧数据/裁剪）仍要露出来。
          // 用集合查询代替 events.any：流式期间每次重建都跑，O(n²)→O(n)
          if (e.commandId == null || !commandIds.contains(e.commandId)) {
            orphans.add(e);
          }
          break;
        case AgentEventType.ask:
          flushThought();
          rows.add(_TimelineRow.interactive(e));
          break;
        case AgentEventType.info:
          if ((e.text ?? '').trim().isNotEmpty) {
            flushThought();
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
    flushThought();

    // 连续的同前缀进度（`上传进度: 1/100 文件` … `100/100`）合并成一行：
    // 它们是一次操作的 100 个采样点，逐条铺开会把真正的推理和失败挤走。
    final merged = _mergeProgress(rows);
    rows
      ..clear()
      ..addAll(merged);

    // 每个步骤都留在原位：不做「更早 N 步」折叠。
    // 上面已经把连续进度合并成一条，剩下的都是用户要看的真实动作。
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      switch (r.kind) {
        case _RowKind.call:
          children.add(_callRow(r, confirmed: confirmedIds.contains(r.event.id)));
          break;
        case _RowKind.thought:
        case _RowKind.note:
          children.add(_textRow(r));
          break;
        case _RowKind.progress:
          children.add(_progressRow(r));
          break;
        case _RowKind.interactive:
          final askBuilder = widget.askBuilder;
          children.add(askBuilder != null
              ? askBuilder(context, r.event)
              : _AskRow(event: r.event, tc: widget.tc));
          break;
      }
    }
    for (final o in orphans) {
      children.add(_resultFallback(o));
    }

    // 实时推理：接在时间线末尾，位置就是它真实发生的地方（下一步命令之前）。
    // 步骤结束时这段推理会被固化成同位置的思考事件，两者无缝衔接。
    final live = widget.liveReasoning.trim();
    if (live.isNotEmpty) {
      children.add(_textRow(_TimelineRow.thought(
        AgentEvent.thought(live, id: 'live_reasoning'),
      )));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }


  /// 头部：一行统计 + 展开/收起（仅在确实藏了行时渲染）
  /// 工具/命令行：一行摘要 + 尾部状态与耗时，点击展开参数与输出
  Widget _callRow(_TimelineRow row, {bool confirmed = false}) {
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
        description: e.description,
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
    // 执行前被询问过、且用户确认执行：行尾留一个「已确认」标记
    final showConfirmed = confirmed && ok;
    final statusColor = ok ? tc.ok : tc.error;
    final statusText = ok
        ? (isTool ? ui.toolDoneLabel : ui.executedLabel)
        : ui.failedLabel;
    final duration = result.durationMs;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        // 与其它 AI 卡片一致：透明填充 + 1px 边框。命令行原先是浅色块，
        // 在已经去掉气泡的回答里会变成一排浮起的小卡。
        color: tc.agentCardFill,
        // 命令行是"卡片级"容器，圆角与执行清单/结果卡统一用 10px：
        // 5px 在 25px 高的细边框行上接近直角，看着像表格而不是卡片
        borderRadius: BorderRadius.circular(rCard),
        // 与其它 AI 卡片同一套边框线（正文 / 结果卡 / 执行清单）
        border: Border.all(color: tc.agentCardBorder, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _toggleRow(e, result),
            child: Padding(
              // 上下留白加大，避免单行命令卡看起来又矮又挤
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                children: [
                  // 标签整体做成浅色底胶囊：图标 + "终端命令" 包在一起
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(
                      color: (isTool ? tc.brand : tc.ok)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isTool ? Icons.auto_awesome : Icons.terminal,
                          size: 13,
                          color: isTool ? tc.brand : tc.ok,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          isTool ? (e.toolName ?? 'tool') : ui.commandLabel,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isTool ? tc.brand : tc.ok,
                            fontSize: fMicro,
                            fontFamily: 'JetBrainsMono',
                            fontFamilyFallback: kMonoFontFallback,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _subject(e, isTool),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tc.textBody, fontSize: fMicro),
                    ),
                  ),
                  if (showConfirmed)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: tc.ok.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          ui.confirmedLabel,
                          style: TextStyle(color: tc.ok, fontSize: fMicro),
                        ),
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
          if (opened) _detail(e, result, showConfirmed),
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

  /// 确认记录里的影响说明：工具按工具类型解释，shell 按命令语义解释
  String _impact(AgentEvent e) {
    final raw = (e.command ?? '').trim();
    if (raw.isEmpty) return '';
    final isTool = e.toolName != null && e.toolName != 'exec_command';
    if (isTool) {
      return RiskExplainer.explainTool(raw.split('\n').first.trim()).impact;
    }
    return RiskExplainer.explain(raw).impact;
  }

  Widget _detail(AgentEvent commandEvent, AgentEvent result, bool confirmed) {
    final tc = widget.tc;
    final ui = AgentUiText.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tc.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 确认记录：这条命令执行前问过用户，展开仍能看到当时的影响说明
          if (confirmed) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: pSmall),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: tc.warn.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(rSmall),
                border: Border.all(color: tc.warn.withValues(alpha: 0.2)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1, right: 5),
                    child:
                        Icon(Icons.shield_outlined, size: 12, color: tc.warn),
                  ),
                  Expanded(
                    child: Text(
                      '${ui.confirmedRecord}：${_impact(commandEvent)}',
                      style: TextStyle(
                          color: tc.textSub, fontSize: fMicro, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if ((commandEvent.description ?? '').trim().isNotEmpty) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1, right: 5),
                  child: Icon(Icons.info_outline, size: 12, color: tc.textMuted),
                ),
                Expanded(
                  child: Text(
                    commandEvent.description!.trim(),
                    style: TextStyle(
                        color: tc.textSub, fontSize: fMicro, height: 1.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: pSmall),
          ],
          Text(
            commandEvent.command ?? '',
            style: TextStyle(
              fontSize: fMicro,
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: kMonoFontFallback,
              color: tc.textSub,
            ),
          ),
          const SizedBox(height: pSmall),
          widget.resultBuilder(context, result),
        ],
      ),
    );
  }

  Widget _textRow(_TimelineRow row) {
    final tc = widget.tc;
    final text = (row.event.text ?? '').trim();
    final isNote = row.kind == _RowKind.note;

    // 推理和系统日志必须长得不一样：原来两者都是「小图标 + 淡色两行」，
    // 63% 的进度/通知把模型真正的判断淹掉了。
    // - 推理：正文色、大一号、默认三行可展开，是"为什么这么做"；
    // - 日志：缩进一档、单行 micro 弱色，只当背景噪声。
    if (isNote) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(23, 2, 2, 2),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 3,
              margin: const EdgeInsets.only(right: 7),
              decoration: BoxDecoration(
                color: tc.textMuted.withValues(alpha: 0.7),
                shape: BoxShape.circle,
              ),
            ),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tc.textMuted,
                  fontSize: fMicro,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      );
    }
    // 长思考默认收成一行、点开看全文：完整内容必须能拿到，但不能默认
    // 让几行推理把命令挤下去。短思考一行本来就装得下。
    final opened = _openThoughts.contains(row.event.id);
    final long = text.length > 60 || text.split('\n').length > 2;
    return InkWell(
      borderRadius: BorderRadius.circular(rSmall),
      onTap: long
          ? () => setState(() {
                if (!_openThoughts.remove(row.event.id)) {
                  _openThoughts.add(row.event.id);
                }
              })
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Icon(
                Icons.psychology_outlined,
                size: 12,
                color: tc.brand.withValues(alpha: 0.85),
              ),
            ),
            Expanded(
              child: Text(
                text,
                maxLines: opened ? null : 1,
                overflow:
                    opened ? TextOverflow.clip : TextOverflow.ellipsis,
                style: TextStyle(
                  color: tc.textBody,
                  fontSize: fSmall,
                  height: 1.45,
                ),
              ),
            ),
            if (long)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 1),
                child: Icon(
                  opened ? Icons.expand_less : Icons.expand_more,
                  size: 13,
                  color: tc.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 连续进度合并后的一行：前缀 + 进度条 + `100/100 文件` + 条数
  ///
  /// 点开才逐条铺开，默认只占一行——一次上传的 100 个采样点不该等于 100 行。
  Widget _progressRow(_TimelineRow row) {
    final tc = widget.tc;
    final ui = AgentUiText.of(context);
    final group = row.events;
    final first =
        _progressPattern.firstMatch((group.first.text ?? '').trim());
    final last = _progressPattern.firstMatch((group.last.text ?? '').trim());
    final prefix = (first?.group(1) ?? '').trim();
    final current = int.tryParse(last?.group(2) ?? '') ?? 0;
    final total = int.tryParse(last?.group(3) ?? '') ?? 0;
    final suffix = (last?.group(4) ?? '').trim();
    final opened = _openProgress.contains(row.event.id);
    final fraction =
        total > 0 ? (current / total).clamp(0.0, 1.0).toDouble() : 0.0;

    return InkWell(
      borderRadius: BorderRadius.circular(rXSmall),
      onTap: () => setState(() {
        if (!_openProgress.remove(row.event.id)) {
          _openProgress.add(row.event.id);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(23, 3, 2, 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    prefix,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tc.textSub,
                      fontSize: fMicro,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 54,
                  height: 3,
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: tc.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: fraction,
                        alignment: Alignment.centerLeft,
                        child: Container(
                          decoration: BoxDecoration(
                            color: tc.brand.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$current/$total${suffix.isEmpty ? '' : ' $suffix'}',
                  style: TextStyle(
                    color: tc.textSub,
                    fontSize: fMicro,
                    fontFamily: 'JetBrainsMono',
                    fontFamilyFallback: kMonoFontFallback,
                  ),
                ),
                const Spacer(),
                Text(
                  ui.progressLines(group.length),
                  style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                ),
                const SizedBox(width: 2),
                Icon(
                  opened ? Icons.expand_less : Icons.expand_more,
                  size: 13,
                  color: tc.textMuted,
                ),
              ],
            ),
            if (opened)
              ...group.map((e) => Padding(
                    padding: const EdgeInsets.only(left: 2, top: 2),
                    child: Text(
                      (e.text ?? '').trim(),
                      style: TextStyle(
                        color: tc.textMuted,
                        fontSize: fMicro,
                        height: 1.4,
                      ),
                    ),
                  )),
          ],
        ),
      ),
    );
  }

  /// 把连续的同前缀进度合成一行；只有一条时保持原样
  List<_TimelineRow> _mergeProgress(List<_TimelineRow> rows) {
    final out = <_TimelineRow>[];
    var i = 0;
    while (i < rows.length) {
      final row = rows[i];
      final first = row.kind == _RowKind.note
          ? _progressPattern.firstMatch((row.event.text ?? '').trim())
          : null;
      if (first == null) {
        out.add(row);
        i++;
        continue;
      }
      final prefix = first.group(1)!.trim();
      final group = <AgentEvent>[row.event];
      var j = i + 1;
      while (j < rows.length && rows[j].kind == _RowKind.note) {
        final next =
            _progressPattern.firstMatch((rows[j].event.text ?? '').trim());
        if (next == null || next.group(1)!.trim() != prefix) break;
        group.add(rows[j].event);
        j++;
      }
      out.add(group.length > 1 ? _TimelineRow.progress(group) : row);
      i = j;
    }
    return out;
  }

  /// 没有父命令的结果（历史数据兜底）
  Widget _resultFallback(AgentEvent result) {
    final tc = widget.tc;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tc.agentCardFill,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: tc.border),
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

  /// 进度组内的原始事件（仅 progress 行非空）
  final List<AgentEvent> events;

  const _TimelineRow.thought(this.event)
      : kind = _RowKind.thought,
        result = null,
        events = const [];
  const _TimelineRow.note(this.event)
      : kind = _RowKind.note,
        result = null,
        events = const [];
  const _TimelineRow.interactive(this.event)
      : kind = _RowKind.interactive,
        result = null,
        events = const [];
  const _TimelineRow.call(this.event, {this.result})
      : kind = _RowKind.call,
        events = const [];
  _TimelineRow.progress(List<AgentEvent> group)
      : kind = _RowKind.progress,
        events = group,
        event = group.first,
        result = null;
}

enum _RowKind { thought, note, progress, call, interactive }

/// 询问行：保持可点，不参与折叠
class _AskRow extends StatelessWidget {
  final AgentEvent event;
  final ThemeColors tc;
  const _AskRow({required this.event, required this.tc});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: pSmall),
      padding: const EdgeInsets.all(pCompact),
      decoration: BoxDecoration(
        color: tc.warn.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: tc.warn.withValues(alpha: 0.3)),
      ),
      child: Text(
        event.question ?? event.text ?? '',
        style: TextStyle(color: tc.textMain, fontSize: fSmall),
      ),
    );
  }
}
