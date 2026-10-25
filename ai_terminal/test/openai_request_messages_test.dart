import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/services/ai_service.dart';

void main() {
  group('OpenAIProvider.buildRequestMessages', () {
    test('Agent 模式 prompt 为空时不追加空 user 消息', () {
      final messages = OpenAIProvider.buildRequestMessages(
        history: [
          ChatMessage.create(role: 'system', content: 'react prompt'),
          ChatMessage.create(role: 'user', content: '任务: echo hi'),
        ],
        prompt: '',
        systemPrompt: 'context prompt',
      );

      expect(messages.length, 3);
      expect(messages[0]['role'], 'system');
      expect(messages[1]['role'], 'system');
      expect(messages[2]['role'], 'user');
      expect(messages.every((m) => (m['content'] as String).isNotEmpty), isTrue);
    });

    test('过滤内容为空或仅空白的消息', () {
      final messages = OpenAIProvider.buildRequestMessages(
        history: [
          ChatMessage.create(role: 'system', content: 'system'),
          ChatMessage.create(role: 'assistant', content: ''),
          ChatMessage.create(role: 'user', content: '   '),
          ChatMessage.create(role: 'user', content: 'hello'),
        ],
        prompt: 'next',
        systemPrompt: 'system',
      );

      expect(messages.length, 4);
      expect(messages.map((m) => m['content']).toList(), ['system', 'system', 'hello', 'next']);
      expect(messages.every((m) => (m['content'] as String).trim().isNotEmpty), isTrue);
    });

    test('空 systemPrompt 不生成 system 消息', () {
      final messages = OpenAIProvider.buildRequestMessages(
        history: const [],
        prompt: 'hi',
        systemPrompt: '  ',
      );

      expect(messages, [
        {'role': 'user', 'content': 'hi'},
      ]);
    });
  });
}
