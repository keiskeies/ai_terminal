import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/services/ai_service.dart';

/// P2：真实 token 用量的解析契约。
///
/// 核心是「provider 没给」与「provider 给了 0」必须可区分：缓存命中缺失时 UI
/// 整项不渲染，若把 0 和缺失混为一谈，界面上就会显示"缓存命中 0%"，
/// 那是把一个未知说成一个结论。
void main() {
  group('TokenUsage.tryParse', () {
    test('末包式完整 usage：四个字段都取到', () {
      final usage = TokenUsage.tryParse({
        'prompt_tokens': 1200,
        'completion_tokens': 80,
        'total_tokens': 1280,
        'prompt_tokens_details': {'cached_tokens': 1024},
      });

      expect(usage?.promptTokens, 1200);
      expect(usage?.completionTokens, 80);
      expect(usage?.totalTokens, 1280);
      expect(usage?.cachedTokens, 1024);
    });

    test('没有 prompt_tokens_details 时 cachedTokens 为 null（不是 0）', () {
      final usage = TokenUsage.tryParse({
        'prompt_tokens': 500,
        'completion_tokens': 40,
      });

      expect(usage?.promptTokens, 500);
      expect(usage?.cachedTokens, isNull);
    });

    test('给了 0 是真实值，不能被当成缺失', () {
      final usage = TokenUsage.tryParse({
        'prompt_tokens': 0,
        'completion_tokens': 0,
        'total_tokens': 0,
        'prompt_tokens_details': {'cached_tokens': 0},
      });

      expect(usage, isNotNull);
      expect(usage?.hasAny, isTrue);
      expect(usage?.promptTokens, 0);
      expect(usage?.cachedTokens, 0);
    });

    test('浮点数（部分网关按 JSON number 给）取整', () {
      final usage = TokenUsage.tryParse({
        'prompt_tokens': 1200.0,
        'completion_tokens': 80.5,
      });

      expect(usage?.promptTokens, 1200);
      expect(usage?.completionTokens, 80);
    });

    test('空对象 / null / 非 Map 都不是用量', () {
      expect(TokenUsage.tryParse({}), isNull);
      expect(TokenUsage.tryParse(null), isNull);
      expect(TokenUsage.tryParse('usage'), isNull);
      expect(TokenUsage.tryParse([1, 2]), isNull);
    });

    test('值类型不对（字符串数字）不算用量，避免把类型错误当统计', () {
      expect(TokenUsage.tryParse({'prompt_tokens': '1200'}), isNull);
    });

    test('prompt_tokens_details 不是 Map 时其余字段仍解析', () {
      final usage = TokenUsage.tryParse({
        'prompt_tokens': 300,
        'prompt_tokens_details': 'none',
      });

      expect(usage?.promptTokens, 300);
      expect(usage?.cachedTokens, isNull);
    });

    test('只有 cachedTokens 不算有用量（三个主字段全缺）', () {
      final usage = TokenUsage.tryParse({
        'prompt_tokens_details': {'cached_tokens': 5},
      });

      expect(usage, isNull);
    });
  });

  // §4-P2 的验收项之一：stream_options 不被支持时必须降级，但只能降一次、
  // 且不能顺手把真实错误也"降级"掉。
  group('shouldRetryWithoutStreamOptions', () {
    test('带了该字段且网关回 400 → 去掉字段重试一次', () {
      expect(
          shouldRetryWithoutStreamOptions(
              sentStreamOptions: true, statusCode: 400),
          isTrue);
    });

    test('真实错误不能被降级掩盖', () {
      for (final code in [401, 403, 429, 500, 503]) {
        expect(
            shouldRetryWithoutStreamOptions(
                sentStreamOptions: true, statusCode: code),
            isFalse,
            reason: '$code 与 stream_options 无关');
      }
      // 连接层失败没有状态码，同样不该重试
      expect(
          shouldRetryWithoutStreamOptions(
              sentStreamOptions: true, statusCode: null),
          isFalse);
    });

    test('降级那次再失败不继续重试（防死循环）', () {
      expect(
          shouldRetryWithoutStreamOptions(
              sentStreamOptions: false, statusCode: 400),
          isFalse);
    });
  });
}
