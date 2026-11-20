import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/services/history_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 大上下文窗口：避免触发 token-aware 裁剪，便于单独测试其它层
  const bigCtx = 262144;

  group('HistoryPolicy 三层裁剪', () {
    test('小上下文且消息少时不裁剪', () {
      final messages = <ChatMessage>[
        ChatMessage.create(role: 'user', content: 'hello'),
        ChatMessage.create(role: 'assistant', content: 'hi there'),
      ];

      HistoryPolicy.trimMessages(messages, contextWindow: bigCtx);

      expect(messages.length, 2);
      expect(messages.first.content, 'hello');
    });

    test('普通消息超 4000 字符按尾部截断并标注', () {
      final messages = <ChatMessage>[
        ChatMessage.create(role: 'user', content: 'a' * 10000),
      ];

      HistoryPolicy.trimMessages(messages, contextWindow: bigCtx);

      expect(messages.first.content, contains('已截断前'));
      expect(messages.first.content.length, lessThan(10000));
      expect(messages.first.content.endsWith('a'), isTrue);
    });

    test('观测消息按 12000 上限截断而非 4000', () {
      final content = '观测: 命令执行成功\n输出:\n${'b' * 15000}';
      final messages = <ChatMessage>[
        ChatMessage.create(role: 'user', content: content),
      ];

      HistoryPolicy.trimMessages(messages, contextWindow: bigCtx);

      final trimmed = messages.first.content;
      expect(trimmed, contains('已截断'));
      expect(trimmed.length, greaterThan(12000));
      expect(trimmed.length, lessThan(12100));
    });

    test('截断保留的代码块奇数反引号会补闭合', () {
      // 尾部 4000 字符里含奇数个 ``` → 应补一个，避免代码块不闭合
      final tail = 'x' * 3997;
      final content = '${'`' * 3}\n$tail';
      final messages = <ChatMessage>[
        ChatMessage.create(role: 'user', content: content),
      ];

      HistoryPolicy.trimMessages(messages, contextWindow: bigCtx);

      final trimmed = messages.first.content;
      expect('```'.allMatches(trimmed).length % 2, 0);
    });

    test('轮数兜底：超过 80 条非系统消息保留最近 80 条', () {
      final messages = <ChatMessage>[
        for (var i = 0; i < 100; i++)
          ChatMessage.create(role: 'user', content: 'msg-$i'),
      ];

      HistoryPolicy.trimMessages(messages, contextWindow: bigCtx);

      expect(messages.length, 80);
      expect(messages.first.content, 'msg-20');
      expect(messages.last.content, 'msg-99');
    });

    test('token-aware：超出预算丢弃最早消息', () {
      final messages = <ChatMessage>[
        for (var i = 0; i < 6; i++)
          ChatMessage.create(
            role: i % 2 == 0 ? 'user' : 'assistant',
            content: '一二三四五六七八九十一二三四五六七八九十一二三四五',
          ),
      ];

      // 预算 = 100 * 0.7 = 70 tokens，6 条约 204 tokens → 裁到 2~3 条
      HistoryPolicy.trimMessages(messages, contextWindow: 100);

      expect(messages.length, lessThanOrEqualTo(3));
      expect(messages.length, greaterThanOrEqualTo(2));
      expect(messages.last.content, contains('一二三四五'));
    });

    test('system 消息始终保留且不被 token 裁剪丢弃', () {
      final messages = <ChatMessage>[
        ChatMessage.create(role: 'system', content: 'you are an agent'),
        ChatMessage.create(role: 'user', content: '一二三四五六七八九十一二三四五'),
        ChatMessage.create(role: 'assistant', content: '一二三四五六七八九十一二三四五'),
        ChatMessage.create(role: 'user', content: '一二三四五六七八九十一二三四五'),
      ];

      HistoryPolicy.trimMessages(messages, contextWindow: 30);

      expect(messages.where((m) => m.role == 'system').length, 1);
      expect(messages.first.role, 'system');
    });

    test('原地修改传入的列表', () {
      final messages = <ChatMessage>[
        for (var i = 0; i < 100; i++)
          ChatMessage.create(role: 'user', content: 'msg-$i'),
      ];
      final sameList = messages;

      HistoryPolicy.trimMessages(messages, contextWindow: bigCtx);

      expect(identical(messages, sameList), isTrue);
      expect(messages.length, 80);
    });
  });
}
