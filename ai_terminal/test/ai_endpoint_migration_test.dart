import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/services/ai_endpoint_migration.dart';

void main() {
  AIModelConfig legacy({
    required String id,
    required String provider,
    required String baseUrl,
    required String modelName,
  }) =>
      AIModelConfig.create(
        id: id,
        provider: provider,
        name: modelName,
        apiKey: '',
        baseUrl: baseUrl,
        modelName: modelName,
      );

  test('按 provider + Base URL 分组：同一端点的多个模型合并', () {
    final grouped = AIEndpointsMigration.groupLegacyModels([
      legacy(id: '1', provider: 'openai', baseUrl: 'http://a/v1', modelName: 'm1'),
      legacy(id: '2', provider: 'openai', baseUrl: 'http://a/v1', modelName: 'm2'),
      legacy(id: '3', provider: 'deepseek', baseUrl: 'http://a/v1', modelName: 'm3'),
      legacy(id: '4', provider: 'openai', baseUrl: 'http://b/v1', modelName: 'm4'),
    ]);

    expect(grouped, hasLength(3));
    final aOpenAi = grouped['openai\u0000http://a/v1'];
    expect(aOpenAi?.map((m) => m.id), ['1', '2']);
    expect(grouped['deepseek\u0000http://a/v1']?.single.id, '3');
    expect(grouped['openai\u0000http://b/v1']?.single.id, '4');
  });

  test('空输入返回空分组', () {
    expect(AIEndpointsMigration.groupLegacyModels([]), isEmpty);
  });
}
