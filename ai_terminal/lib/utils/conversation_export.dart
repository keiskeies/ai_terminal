import '../models/agent_event.dart';
import '../models/chat_item.dart';
import '../models/operation_report.dart';

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
    buffer.writeln('目标：${report.goal.trim()}');
  }
  buffer.writeln('结论：${report.conclusion.trim()}');
  final answerBody = report.answerBody?.trim();
  if (answerBody != null && answerBody.isNotEmpty && !_sameText(answerBody, report.conclusion)) {
    buffer
      ..writeln()
      ..writeln(answerBody);
  }
  if (report.changes.isNotEmpty) {
    buffer.writeln('变更：');
    for (final change in report.changes) {
      final rollback = change.canRollback
          ? (change.localRestore && (change.rollbackCommand ?? '').trim().isEmpty
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

  for (final event in events) {
    switch (event.type) {
      case AgentEventType.thought:
      case AgentEventType.text:
      case AgentEventType.info:
        emit(event.text);
        break;
      case AgentEventType.command:
        final command = (event.command ?? '').trim();
        if (command.isEmpty) break;
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
          if ((event.question ?? '').trim().isNotEmpty) event.question!.trim(),
          if (options.isNotEmpty) options.map((o) => '- $o').join('\n'),
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

  // 没有事件的历史消息：退回持久化正文，流式中则退回增量文本
  if (buffer.isEmpty) {
    emit(content.trim().isNotEmpty ? content : streamingContent);
  }
  return buffer.toString().trimRight();
}

/// ReAct 协议控制行：命令与询问已经各自成卡，正文里再抄一遍就是重复。
final RegExp _reactControlLine = RegExp(r'^\s*(?:动作|命令|选项|工具)\s*[:：]');

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
