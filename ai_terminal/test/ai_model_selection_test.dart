import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/ai_endpoint.dart';
import 'package:ai_terminal/services/ai_model_selection_service.dart';
import 'package:ai_terminal/services/daos.dart';

void main() {
  const endpointA = AIEndpoint(
    id: 'ep-a',
    providerId: 'custom',
    name: 'gateway',
    baseUrl: 'http://localhost:1994/v1',
    protocol: 'openai',
    apiKey: 'sk-a',
    createdAt: 1,
    models: [
      AIEndpointModel(
        id: 'm-a1',
        name: 'Agnes',
        modelName: 'agnes',
        reasoningEnabled: true,
      ),
      AIEndpointModel(
        id: 'm-a2',
        name: 'Qwen',
        modelName: 'qwen',
      ),
    ],
  );
  const endpointB = AIEndpoint(
    id: 'ep-b',
    providerId: 'openai',
    name: 'openai',
    baseUrl: 'https://api.openai.com/v1',
    protocol: 'openai',
    createdAt: 2,
    models: [
      AIEndpointModel(id: 'm-b1', name: 'GPT', modelName: 'gpt'),
    ],
  );

  setUp(() async {
    // SettingsDao 在 DB 未初始化时仍会写内存缓存，足以测试选择逻辑
    await SettingsDao.set(AIModelSelectionService.selectedModelKey, '');
    await SettingsDao.set(AIModelSelectionService.reasoningTiersKey, {});
  });

  test('allChoices 按端点顺序拍平模型', () {
    final choices = AIModelSelectionService.allChoices([endpointA, endpointB]);
    expect(choices.map((c) => c.modelId), ['m-a1', 'm-a2', 'm-b1']);
    expect(choices.first.endpointName, 'gateway');
  });

  test('buildConfig 使用已保存档位', () async {
    await AIModelSelectionService.saveReasoningTier('m-a1', 'high');
    final config = AIModelSelectionService.buildConfig(
        [endpointA, endpointB], 'm-a1');
    expect(config, isNotNull);
    expect(config!.endpointId, 'ep-a');
    expect(config.apiKey, 'sk-a');
    expect(config.reasoningEffort, 'high');
    expect(config.reasoningLabel, 'High');
  });

  test('buildConfig 对未保存档位默认 medium', () {
    final config = AIModelSelectionService.buildConfig([endpointA], 'm-a1');
    expect(config!.reasoningEffort, 'medium');
    expect(config.reasoningLabel, 'Medium');
  });

  test('未启用推理的模型不发送思考参数', () {
    final config = AIModelSelectionService.buildConfig([endpointA], 'm-a2');
    expect(config!.reasoningEffort, isNull);
    expect(config.reasoningLabel, isNull);
  });

  test('找不到模型时返回 null', () {
    expect(AIModelSelectionService.buildConfig([endpointA], 'missing'), isNull);
  });
}
