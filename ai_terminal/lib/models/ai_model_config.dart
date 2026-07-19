import '../services/provider_config_service.dart';

class AIModelConfig {
  late String id;

  late String provider;

  late String name;

  late String apiKey;

  late String baseUrl;

  late String modelName;

  double temperature = 0.3;

  int maxTokens = 4096;

  /// 模型上下文窗口大小（tokens）。0 表示未知，按默认值 32768 处理
  /// 用于 token-aware 上下文裁剪（_trimMessages）和自动压缩触发判断
  int contextWindow = 0;

  /// 备用模型 ID（指向另一个 AIModelConfig 的 id）。
  /// 主模型重试 maxRetries 次仍失败时，自动切换到该备用模型重试一次。
  /// 空/null 表示无 fallback。
  String? fallbackModelId;

  /// P2-6: 是否支持原生 Function Calling（OpenAI tools API）。
  /// true 时 _callAI 会把 AgentToolRegistry 的工具以 tools schema 形式传入；
  /// OpenAIProvider 会解析 delta.tool_calls 并转换为 ReAct 文本格式投递。
  /// false（默认）时走纯文本协议，靠 ReActStreamParser 解析。
  bool supportsFunctionCalling = false;

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
    this.contextWindow = 0,
    this.fallbackModelId,
    this.supportsFunctionCalling = false,
    this.isDefault = false,
  });

  /// 有效的上下文窗口（contextWindow=0 时回退到默认 32768）
  int get effectiveContextWindow =>
      contextWindow > 0 ? contextWindow : _defaultContextWindow;

  static const int _defaultContextWindow = 32768;

  String get providerIcon {
    final info = ProviderConfigService.getProviderById(provider);
    return info?.icon ?? '💬';
  }

  int get providerColorValue {
    final info = ProviderConfigService.getProviderById(provider);
    return info?.colorValue ?? 0xFF002FA7;
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
    int? contextWindow,
    String? fallbackModelId,
    bool? supportsFunctionCalling,
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
      contextWindow: contextWindow ?? this.contextWindow,
      fallbackModelId: fallbackModelId ?? this.fallbackModelId,
      supportsFunctionCalling: supportsFunctionCalling ?? this.supportsFunctionCalling,
      isDefault: isDefault ?? this.isDefault,
    );
  }
}
