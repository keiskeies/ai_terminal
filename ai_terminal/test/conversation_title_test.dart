import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/conversation.dart';

Conversation _conv({String title = '会话 11/4 02:34'}) => Conversation.create(
      id: 'conv-1',
      hostId: 'web-01',
      title: title,
    );

void main() {
  group('会话标题推导', () {
    test('日期默认标题回退到首条用户消息前 20 字', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(role: 'user', content: '请检查本机 gdm 和 systemd-logind 两个服务是否正在运行，然后总结'))
        ..addMessage(ConvMessage.create(role: 'assistant', content: '...'));

      expect(conv.displayTitle, '请检查本机 gdm 和 systemd-…');
    });

    test('只取首行，并把连续空白折叠成一个空格', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(
          role: 'user',
          content: '  第一行   有空格\n第二行不应该出现  ',
        ));

      expect(conv.displayTitle, '第一行 有空格');
    });

    test('不超过 20 字时不加省略号', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(role: 'user', content: '检查服务状态'));

      expect(conv.displayTitle, '检查服务状态');
    });

    test('按 rune 截断，不劈开 emoji', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(
          role: 'user',
          content: '😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀',
        ));

      final title = conv.displayTitle;
      expect(title.runes.length, 21); // 20 个 emoji + 省略号
      expect(title.endsWith('…'), isTrue);
    });

    test('自定义标题不被覆盖', () {
      final conv = _conv(title: '生产环境巡检')
        ..addMessage(ConvMessage.create(role: 'user', content: '检查 Nginx'));

      expect(conv.displayTitle, '生产环境巡检');
      conv.adoptTitleFromFirstMessage('另一个任务');
      expect(conv.title, '生产环境巡检');
    });

    test('没有用户消息时保留日期标题', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(role: 'assistant', content: '占位'));

      expect(conv.displayTitle, '会话 11/4 02:34');
    });

    test('首条用户消息到达时持久化标题', () {
      final conv = _conv();
      conv.adoptTitleFromFirstMessage('排查服务器自动关机的原因');
      expect(conv.title, '排查服务器自动关机的原因');
      expect(conv.hasAutoTitle, isFalse);
    });
  });
}
