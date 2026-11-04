import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/services/ai_service.dart';

void main() {
  AIModelConfig config({String? effort}) => AIModelConfig.create(
        id: 'm-1',
        provider: 'openai',
        name: 'Test',
        apiKey: 'sk-test',
        baseUrl: 'http://localhost:1994/v1',
        modelName: 'agnes-3.0-flash',
        temperature: 0.3,
        maxTokens: 8192,
        reasoningEffort: effort,
      );

  group('OpenAI 请求体', () {
    test('基础字段保持不变', () {
      final body = OpenAIProvider.buildChatRequestBody(
        config: config(),
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      expect(body['model'], 'agnes-3.0-flash');
      expect(body['stream'], true);
      expect(body['temperature'], 0.3);
      expect(body['max_tokens'], 8192);
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('有档位 API 值时发送 reasoning_effort', () {
      final body = OpenAIProvider.buildChatRequestBody(
        config: config(effort: 'high'),
        messages: const [],
      );
      expect(body['reasoning_effort'], 'high');
    });

    test('空值/空白值不发送 reasoning_effort', () {
      for (final effort in [null, '', '   ']) {
        final body = OpenAIProvider.buildChatRequestBody(
          config: config(effort: effort),
          messages: const [],
        );
        expect(body.containsKey('reasoning_effort'), isFalse,
            reason: 'effort=$effort');
      }
    });

    test('有 tools 时附加 tools，不强制 tool_choice', () {
      final tools = [
        {
          'type': 'function',
          'function': {'name': 'run_command'},
        }
      ];
      final body = OpenAIProvider.buildChatRequestBody(
        config: config(),
        messages: const [],
        tools: tools,
      );
      expect(body['tools'], tools);
      expect(body.containsKey('tool_choice'), isFalse);
    });
  });
}
