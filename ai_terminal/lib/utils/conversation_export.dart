import '../models/chat_item.dart';

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
