import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/chat_item.dart';
import 'package:ai_terminal/utils/conversation_export.dart';

/// `/export` 的会话文本装配。
void main() {
  group('formatConversationForExport', () {
    test('按角色分段，用户与 Agent 交替', () {
      final text = formatConversationForExport([
        ChatItem(role: 'user', content: '看下磁盘'),
        ChatItem(role: 'assistant', content: '磁盘剩余 40G'),
      ]);

      expect(text, contains('## 你'));
      expect(text, contains('看下磁盘'));
      expect(text, contains('## Agent'));
      expect(text, contains('磁盘剩余 40G'));
      // 顺序保留：导出后要能对着原对话读
      expect(text.indexOf('看下磁盘') < text.indexOf('磁盘剩余 40G'), isTrue);
    });

    test('空消息与只有空白的消息不产出段落', () {
      final text = formatConversationForExport([
        ChatItem(role: 'assistant', content: ''),
        ChatItem(role: 'user', content: '   \n  '),
      ]);

      expect(text, isEmpty);
    });

    test('还在流式输出的消息用 streamingContent 兜底', () {
      // 刚问完就导出，content 还是空的：不兜底就会把最后一条整个丢掉
      final text = formatConversationForExport([
        ChatItem(role: 'user', content: '列目录'),
        ChatItem(role: 'assistant', content: '', streamingContent: '正在执行 ls'),
      ]);

      expect(text, contains('正在执行 ls'));
    });

    test('内容两端空白被裁掉', () {
      final text = formatConversationForExport([
        ChatItem(role: 'user', content: '\n\n  部署  \n\n'),
      ]);

      expect(text.trimRight(), endsWith('部署'));
      expect(text, isNot(contains('  部署')));
    });
  });
}
