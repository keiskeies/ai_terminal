import 'package:hive/hive.dart';

part 'ai_model_config.g.dart';

@HiveType(typeId: 1)
class AIModelConfig extends HiveObject {
  @HiveField(0)
  late String id;

  @HiveField(1)
  late String provider; // 'openai' | 'qwen' | 'ernie'

  @HiveField(2)
  late String name;

  @HiveField(3)
  late String apiKey;

  @HiveField(4)
  late String baseUrl;

  @HiveField(5)
  late String modelName;

  @HiveField(6)
  double temperature = 0.3;

  @HiveField(7)
  int maxTokens = 4096;

  @HiveField(8)
  bool isDefault = false;

  AIModelConfig();

  AIModelConfig.create({
    required this.id,
    required this.provider,
    required this.name,
    required this.apiKey,
    required this.baseUrl,
    required this.modelName,
    this.temperature = 0.3,
    this.maxTokens = 4096,
    this.isDefault = false,
  });

  /// 提供商图标
  String get providerIcon {
    switch (provider) {
      case 'openai':
        return '🤖';
      case 'qwen':
        return '🐯';
      case 'ernie':
        return '🟠';
      default:
        return '💬';
    }
  }

  /// 提供商颜色
  int get providerColorValue {
    switch (provider) {
      case 'openai':
        return 0xFF22C55E; // 绿色
      case 'qwen':
        return 0xFF3B82F6; // 蓝色
      case 'ernie':
        return 0xFF8B5CF6; // 紫色
      default:
        return 0xFF6366F1;
    }
  }

  AIModelConfig copyWith({
    String? id,
    String? provider,
    String? name,
    String? apiKey,
    String? baseUrl,
    String? modelName,
    double? temperature,
    int? maxTokens,
    bool? isDefault,
  }) {
    return AIModelConfig.create(
      id: id ?? this.id,
      provider: provider ?? this.provider,
      name: name ?? this.name,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      modelName: modelName ?? this.modelName,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      isDefault: isDefault ?? this.isDefault,
    );
  }
}
