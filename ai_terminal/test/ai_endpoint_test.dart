import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/ai_endpoint.dart';
import 'package:ai_terminal/models/ai_model_config.dart';

void main() {
  const endpoint = AIEndpoint(
    id: 'ep-1',
    providerId: 'custom',
    name: 'ai_gateway',
    baseUrl: 'http://localhost:1994/v1',
    protocol: 'openai',
    apiKey: 'sk-test',
    models: [],
    createdAt: 1,
  );

  const model = AIEndpointModel(
    id: 'm-1',
    name: 'Agnes',
    modelName: 'agnes-3.0-flash',
    contextWindow: 200000,
    maxTokens: 32000,
    supportsFunctionCalling: true,
    reasoningEnabled: true,
  );

  group('AIEndpoint JSON', () {
    test('端点与模型目录可往返序列化', () {
      final source = endpoint.copyWith(models: [model]);
      final restored = AIEndpoint.fromJson(source.toJson());

      expect(restored.id, 'ep-1');
      expect(restored.providerId, 'custom');
      expect(restored.name, 'ai_gateway');
      expect(restored.baseUrl, 'http://localhost:1994/v1');
      expect(restored.protocol, 'openai');
      expect(restored.apiKey, isEmpty, reason: 'apiKey 不落 JSON/DB');
      expect(restored.models.single.modelName, 'agnes-3.0-flash');
      expect(restored.models.single.contextWindow, 200000);
      expect(restored.models.single.reasoningEnabled, isTrue);
    });

    test('模型档位往返序列化（含自定义档位）', () {
      final withTier = model.copyWith(reasoningTiers: [
        const AIReasoningTier(level: 'off', apiValue: ''),
        const AIReasoningTier(level: 'turbo', apiValue: 'max'),
      ]);
      final restored = AIEndpointModel.fromJson(withTier.toJson());
      expect(restored.reasoningTiers, hasLength(2));
      expect(restored.reasoningTiers[1].level, 'turbo');
      expect(restored.reasoningTiers[1].apiValue, 'max');
      expect(restored.reasoningTiers[1].label, 'Turbo');
    });
  });

  group('档位解析', () {
    test('未启用推理时返回 null', () {
      expect(model.copyWith(reasoningEnabled: false).resolveReasoningTier('high'),
          isNull);
    });

    test('启用但未配置档位时回退标准四档', () {
      final tiers = model.activeReasoningTiers;
      expect(tiers.map((t) => t.level),
          ['off', 'low', 'medium', 'high']);
    });

    test('没有保存值时默认 medium', () {
      expect(model.resolveReasoningTier()?.level, 'medium');
    });

    test('保存值存在时优先使用保存值', () {
      expect(model.resolveReasoningTier('high')?.level, 'high');
      expect(model.resolveReasoningTier('off')?.level, 'off');
    });

    test('保存值已不存在时回退 medium', () {
      expect(model.resolveReasoningTier('deleted-level')?.level, 'medium');
    });

    test('自定义档位列表没有 medium 时取第一个有 API 值的档位', () {
      final custom = model.copyWith(reasoningTiers: [
        const AIReasoningTier(level: 'off', apiValue: ''),
        const AIReasoningTier(level: 'turbo', apiValue: 'max'),
      ]);
      expect(custom.resolveReasoningTier()?.level, 'turbo');
    });
  });

  group('运行时配置拍平', () {
    test('推理档位非空时写入 reasoningEffort 与 label', () {
      final config = AIModelConfig.fromEndpoint(
        endpoint: endpoint,
        model: model,
        tier: const AIReasoningTier(level: 'high', apiValue: 'high'),
      );
      expect(config.id, 'm-1');
      expect(config.endpointId, 'ep-1');
      expect(config.endpointName, 'ai_gateway');
      expect(config.provider, 'openai');
      expect(config.baseUrl, 'http://localhost:1994/v1');
      expect(config.apiKey, 'sk-test');
      expect(config.modelName, 'agnes-3.0-flash');
      expect(config.maxTokens, 32000);
      expect(config.contextWindow, 200000);
      expect(config.supportsFunctionCalling, isTrue);
      expect(config.reasoningEffort, 'high');
      expect(config.reasoningLabel, 'High');
    });

    test('off 档（空 API 值）不发送参数', () {
      final config = AIModelConfig.fromEndpoint(
        endpoint: endpoint,
        model: model,
        tier: const AIReasoningTier(level: 'off', apiValue: ''),
      );
      expect(config.reasoningEffort, isNull);
      expect(config.reasoningLabel, 'Off');
    });

    test('maxTokens=0 时回退 32768；contextWindow=0 时 effective 回退 262144', () {
      final config = AIModelConfig.fromEndpoint(
        endpoint: endpoint,
        model: model.copyWith(maxTokens: 0, contextWindow: 0),
      );
      expect(config.maxTokens, 32768);
      expect(config.effectiveContextWindow, 262144);
    });

    test('新模型默认最大输出 32768，未知上下文按 256K 处理', () {
      const fresh = AIEndpointModel(
        id: 'm-new',
        name: 'New',
        modelName: 'new-model',
      );
      expect(fresh.maxTokens, kDefaultMaxOutputTokens);
      expect(fresh.maxTokens, 32768);
      expect(fresh.contextWindow, 0);
      final config = AIModelConfig.fromEndpoint(
        endpoint: endpoint,
        model: fresh,
      );
      expect(config.effectiveContextWindow, 262144);
    });
  });
}
