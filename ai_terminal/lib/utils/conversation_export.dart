import '../models/agent_event.dart';
import '../models/chat_item.dart';
import '../models/operation_report.dart';
import '../core/l10n_holder.dart';
import 'react_stream_parser.dart';

/// 解析 D1 raw fallback 的 ReAct 协议文本为结构化事件。
///
/// 老会话持久化的是原始协议正文（思考:/动作:/命令: 行）；解析失败或内容为空
/// 时返回空列表，调用方保留原文。
///
/// 只解析**确实含协议行**的正文：解析器把任意 ``` 围栏都产出为可执行 command
/// 事件，普通 Markdown 回答（带代码示例/引用块里写「命令:」）若进解析，
/// 会被重排成分节文本、围栏还会挂上执行按钮。无协议行 → 返回空，原样渲染。
final RegExp _reactProtocolLine = RegExp(
    r'^\s*(思考|计划|说明|动作|命令|选项|工具|参数|回答|结论|现状|变更|建议)\s*[:：]',
    multiLine: true);

List<AgentEvent> parseRawReactFallbackEvents(String raw) {
  if (raw.trim().isEmpty) return const [];
  if (!_reactProtocolLine.hasMatch(raw)) return const [];
  try {
    return ReActStreamParser.parse(raw);
  } catch (_) {
    return const [];
  }
}

/// 事件列表里是否有可作为正文展示的可见内容（与 terminal_page 的判定同口径）
bool hasVisibleReactEvents(List<AgentEvent> events) => events.any(
    (e) => e.isThought || e.isCommand || e.isText || e.isAsk || e.isFinish);

/// 把会话拼成纯文本，供 `/export` 复制到剪贴板。
///
/// 不新造导出格式：导出的是用户屏幕上看得见的内容。仍在流式输出的消息取
/// `streamingContent` 兜底，否则刚问完就导出会丢最后一条。
String formatConversationForExport(List<ChatItem> items) {
  final buffer = StringBuffer();
  for (final item in items) {
    final content =
        item.content.isNotEmpty ? item.content : item.streamingContent;
    if (content.trim().isEmpty) continue;
    buffer
      ..writeln(item.role == 'user' ? '## 你' : '## Agent')
      ..writeln(content.trim())
      ..writeln();
  }
  return buffer.toString().trimRight();
}

/// 操作单的可复制文本：目标 + 结论 + 回答正文 + 变更清单。
///
/// 操作单上的「复制」和消息底部的「复制回答」共用这一份，
/// 否则同一轮回答会有两种复制结果。
String formatOperationReportCopy(OperationReport report) {
  final buffer = StringBuffer();
  if (report.goal.trim().isNotEmpty) {
    buffer.writeln(L10n.str.ut_eb988194e9(report.goal.trim()));
  }
  buffer.writeln(L10n.str.ut_304b011a8a(report.conclusion.trim()));
  final answerBody = report.answerBody?.trim();
  if (answerBody != null &&
      answerBody.isNotEmpty &&
      !_sameText(answerBody, report.conclusion)) {
    buffer
      ..writeln()
      ..writeln(answerBody);
  }
  if (report.changes.isNotEmpty) {
    buffer.writeln('变更：');
    for (final change in report.changes) {
      final rollback = change.canRollback
          ? (change.localRestore &&
                  (change.rollbackCommand ?? '').trim().isEmpty
              ? '（可回滚：从备份/回收区移回）'
              : '（可回滚：${change.rollbackCommand}）')
          : '（无自动回滚）';
      buffer.writeln('- ${change.command}$rollback');
    }
  }
  return buffer.toString().trimRight();
}

/// 单条 Agent 回答的纯文本，供消息下方的「复制回答」按钮使用。
///
/// 命令输出不进复制内容：它是屏幕上的证据，整段粘到别处会淹没正文。
/// 与操作单重复的正文按归一化文本去重，同一段话不该出现两遍。
String formatAnswerForCopy({
  required List<AgentEvent> events,
  String content = '',
  String streamingContent = '',
}) {
  final buffer = StringBuffer();
  final emitted = <String>{};
  // 命令/询问已经各自成卡，ReAct 协议行只在有这些卡片时才是重复；
  // 纯文本回答里「命令: xxx」就是用户看到的正文，删掉等于少复制了内容。
  final hasStructuredCards = events.any((e) => e.isCommand || e.isAsk);

  // 按行去重：操作单里「结论：xxx」和事件流里重述同一句话的 thought 不该都进剪贴板。
  // 短行（'- ok'、'### 总体判断' 之类）不参与去重，否则会被误删。
  void emit(String? raw) {
    final source = (raw ?? '').replaceAll('\r\n', '\n');
    if (source.trim().isEmpty) return;
    final kept = <String>[];
    final keys = <String>[];
    var contentLines = 0;
    var dropped = 0;
    for (final line in source.split('\n')) {
      if (line.trim().isEmpty) {
        kept.add('');
        continue;
      }
      contentLines++;
      if (hasStructuredCards && _reactControlLine.hasMatch(line)) {
        dropped++;
        continue;
      }
      // 「思考: 正文」的标签是协议，去掉后正文才能与上面已输出的同一段落对上
      final value = line.replaceFirst(_reactLabel, '').trimRight();
      final key = _dedupKey(value);
      if (value.isEmpty) {
        dropped++;
        continue;
      }
      if (key.length > 12 && emitted.contains(key)) {
        dropped++;
        continue;
      }
      kept.add(value);
      if (key.length > 12) keys.add(key);
    }
    // 整段大半都在上面出现过：剩下几个短标题/短 bullet 拼不出新内容，
    // 补进去只会得到一串没有正文的空标题。
    if (contentLines > 0 && dropped * 2 >= contentLines) return;
    final text = kept.join('\n').trim().replaceAll(RegExp(r'\n{3,}'), '\n\n');
    if (text.isEmpty) return;
    emitted.addAll(keys);
    buffer
      ..writeln(text)
      ..writeln();
  }

  OperationReport? report;
  for (final event in events) {
    if (event.isReport && event.operationReport != null) {
      report = event.operationReport;
    }
  }
  if (report != null) {
    emit(formatOperationReportCopy(report));
  }

  // 询问行已经带上了用户的选择时，「👉 你选择了 X」那条回执不再重复输出：
  // 同一件事说两遍，复制出去就是噪音。
  final hasRecordedChoice =
      events.any((e) => e.isAsk && (e.chosenAnswer ?? '').trim().isNotEmpty);

  void emitEvents(List<AgentEvent> source) {
    for (final event in source) {
      switch (event.type) {
        case AgentEventType.thought:
        case AgentEventType.text:
          emit(event.text);
          break;
        case AgentEventType.info:
          final text = (event.text ?? '').trim();
          final isChoiceNote =
              text.contains('你选择了') || text.contains('You chose');
          if (isChoiceNote && hasRecordedChoice) break;
          emit(event.text);
          break;
        case AgentEventType.command:
          final command = (event.command ?? '').trim();
          if (command.isEmpty) break;
          // 命令说明跟着命令一起复制，否则复制出去只剩一行命令，看不出意图
          final description = (event.description ?? '').trim();
          if (description.isNotEmpty) emit('> $description');
          final tool = event.toolName;
          if (tool == null || tool == 'exec_command') {
            emit('\$ $command');
          } else {
            // 工具调用的 command 首行一般就是工具名，再拼一遍会变成两个名字
            emit('› ${command.startsWith(tool) ? command : '$tool $command'}');
          }
          break;
        case AgentEventType.ask:
          final options = event.options ?? const [];
          emit([
            if ((event.question ?? '').trim().isNotEmpty)
              event.question!.trim(),
            if (options.isNotEmpty) options.map((o) => '- $o').join('\n'),
            // 用户选了什么必须进复制文本：界面上它显示在提问步骤的胶囊里，
            // 复制走的是另一条路径，不带上就丢了
            if ((event.chosenAnswer ?? '').trim().isNotEmpty)
              '> ${event.chosenAnswer!.trim()}',
          ].join('\n'));
          break;
        case AgentEventType.finish:
          emit(event.summary);
          break;
        case AgentEventType.result:
        case AgentEventType.report:
        case AgentEventType.plan:
          break;
      }
    }
  }

  emitEvents(events);

  // 没有事件的历史消息：退回持久化正文，流式中则退回增量文本。
  // D1 raw fallback：老会话的正文是原始 ReAct 协议文本，先解析成事件再分节导出，
  // 协议行（动作:/命令:）不再当正文原样导出；非协议正文（普通 Markdown）与
  // 解析不出可见事件时都保留原文。
  if (buffer.isEmpty) {
    final fallback = content.trim().isNotEmpty ? content : streamingContent;
    final parsed = parseRawReactFallbackEvents(fallback);
    if (hasVisibleReactEvents(parsed)) emitEvents(parsed);
    if (buffer.isEmpty) emit(fallback);
  }
  return buffer.toString().trimRight();
}

/// ReAct 协议控制行：命令与询问已经各自成卡，正文里再抄一遍就是重复。
final RegExp _reactControlLine = RegExp(r'^\s*(?:动作|说明|命令|选项|工具)\s*[:：]');

/// 段落标签：去掉标签留下正文，才能和上面已输出的同一段落对上。
final RegExp _reactLabel = RegExp(r'^\s*(?:思考|回答)\s*[:：]\s*');

String _dedupKey(String text) {
  return text
      .replaceFirst(RegExp(r'^(目标|结论|变更)\s*[:：]\s*'), '')
      .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^[-*]\s*', multiLine: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();
}

bool _sameText(String a, String b) => _dedupKey(a) == _dedupKey(b);
