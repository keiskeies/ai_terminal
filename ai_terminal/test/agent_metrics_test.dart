import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/agent_tracer.dart';
import 'package:ai_terminal/services/ai_service.dart';

/// 不产生任何输出的占位 provider：本文件只验证计量累加，不发任务。
class _NullProvider implements AIProvider {
  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    Duration? responseTimeout,
    List<Map<String, dynamic>>? tools,
    void Function(TokenUsage usage)? onUsage,
    void Function(String delta)? onReasoning,
  }) async =>
      const Stream<String>.empty();
}

void main() {
  setUp(() => AgentTracer.instance.setDisabled(true));
  tearDown(() => AgentTracer.instance.setDisabled(false));

  AgentEngine newEngine() => AgentEngine(
        aiProvider: _NullProvider(),
        modelConfig: AIModelConfig(),
        memory: AgentMemory(),
      );

  group('引擎 token 计量', () {
    test('累计式 provider 一轮内多次回调只取最后一次，不重复累加', () {
      final e = newEngine();
      e.beginRoundForTesting();
      e.recordUsageForTesting(const TokenUsage(totalTokens: 100));
      e.recordUsageForTesting(const TokenUsage(totalTokens: 150));
      e.recordUsageForTesting(const TokenUsage(totalTokens: 200));

      // 若按"每次都加"实现，这里会是 450 —— 长任务会虚高数倍
      expect(e.tokenTotalForTesting, 200);
    });

    test('末包式 provider 两轮各自累加', () {
      final e = newEngine();
      e.beginRoundForTesting();
      e.recordUsageForTesting(const TokenUsage(totalTokens: 200));
      e.beginRoundForTesting();
      e.recordUsageForTesting(const TokenUsage(totalTokens: 300));

      expect(e.tokenTotalForTesting, 500);
      expect(e.roundsForTesting, 2);
    });

    test('没有 total_tokens 时用 prompt+completion 兜底', () {
      final e = newEngine();
      e.beginRoundForTesting();
      e.recordUsageForTesting(
        const TokenUsage(promptTokens: 1200, completionTokens: 80),
      );

      expect(e.tokenTotalForTesting, 1280);
    });

    test('一轮没拿到 usage 时不会串用上一轮的值', () {
      final e = newEngine();
      e.beginRoundForTesting();
      e.recordUsageForTesting(const TokenUsage(totalTokens: 500));
      // 第二轮 provider 什么都没给：不能把 500 再算一次
      e.beginRoundForTesting();

      expect(e.tokenTotalForTesting, 500);
    });

    test('cached_tokens 缺失时缓存命中率是未知而不是 0%', () {
      final e = newEngine();
      e.beginRoundForTesting();
      e.recordUsageForTesting(const TokenUsage(promptTokens: 2000));
      expect(e.cacheHitForTesting, isNull);

      e.beginRoundForTesting();
      e.recordUsageForTesting(
        const TokenUsage(promptTokens: 2000, cachedTokens: 1000),
      );
      expect(e.cacheHitForTesting, 50);
    });

    test('缓存命中率封顶 100，不因异常数据出负数或超百分比', () {
      final e = newEngine();
      e.beginRoundForTesting();
      e.recordUsageForTesting(
        const TokenUsage(promptTokens: 100, cachedTokens: 900),
      );
      expect(e.cacheHitForTesting, 100);
    });
  });

  group('formatTokenCount', () {
    test('千以下原样', () {
      expect(formatTokenCount(999), '999');
    });

    test('千级保留一位小数', () {
      expect(formatTokenCount(1280), '1.3k');
      expect(formatTokenCount(1500), '1.5k');
    });

    test('整千不带小数', () {
      expect(formatTokenCount(2000), '2k');
      expect(formatTokenCount(150000), '150k');
    });

    test('百万级', () {
      expect(formatTokenCount(165000000), '165M');
      expect(formatTokenCount(2400000), '2.4M');
    });
  });
}
