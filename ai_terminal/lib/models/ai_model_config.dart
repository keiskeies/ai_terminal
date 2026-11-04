import 'ai_endpoint.dart';

/// 运行时的模型配置快照：由一个端点和它下面的某个模型拍平而成。
///
/// AgentEngine / AIProvider 只依赖这个对象，因此端点级配置的改造不会
/// 扩散到调用链。API Key 只在内存中存在，落盘由 CredentialsStore 负责。
class AIModelConfig {
  late String id;

  /// 所属端点 id / 显示名（诊断与选择器分组用）
  String endpointId = '';
  String endpointName = '';

  /// 协议：openai / ernie（决定使用哪个 AIProvider）
  late String provider;

  /// 模型显示名称
  late String name;

  late String apiKey;

  late String baseUrl;

  late String modelName;

  double temperature = 0.3;

  int maxTokens = kDefaultMaxOutputTokens;

  /// 模型上下文窗口大小（tokens）。0 表示未知，按默认值 262144（256K）处理
  /// 用于 token-aware 上下文裁剪（_trimMessages）和自动压缩触发判断
  int contextWindow = 0;

  /// 备用模型 ID（指向另一个模型配置的 id）。
  /// 主模型重试 maxRetries 次仍失败时，自动切换到该备用模型重试一次。
  String? fallbackModelId;

  /// 是否支持原生 Function Calling（OpenAI tools API）。
  bool supportsFunctionCalling = false;

  /// 非空时随请求发送 `reasoning_effort: <值>`；空表示不发送。
  String? reasoningEffort;

  /// 当前档位显示文案（Off/Low/Medium/High/自定义）。
  String? reasoningLabel;

  AIModelConfig();

  AIModelConfig.create({
    required this.id,
    this.endpointId = '',
    this.endpointName = '',
    required this.provider,
    required this.name,
    required this.apiKey,
    required this.baseUrl,
    required this.modelName,
    this.temperature = 0.3,
    this.maxTokens = kDefaultMaxOutputTokens,
    this.contextWindow = 0,
    this.fallbackModelId,
    this.supportsFunctionCalling = false,
    this.reasoningEffort,
    this.reasoningLabel,
  });

  /// 把「端点 + 模型 + 当前档位」拍平成运行时配置。
  factory AIModelConfig.fromEndpoint({
    required AIEndpoint endpoint,
    required AIEndpointModel model,
    AIReasoningTier? tier,
  }) {
    return AIModelConfig.create(
      id: model.id,
      endpointId: endpoint.id,
      endpointName: endpoint.name,
      provider: endpoint.protocol,
      name: model.name,
      apiKey: endpoint.apiKey,
      baseUrl: endpoint.baseUrl,
      modelName: model.modelName,
      temperature: model.temperature,
      maxTokens:
          model.maxTokens <= 0 ? kDefaultMaxOutputTokens : model.maxTokens,
      contextWindow: model.contextWindow,
      fallbackModelId: model.fallbackModelId,
      supportsFunctionCalling: model.supportsFunctionCalling,
      reasoningEffort:
          tier != null && tier.sendsParameter ? tier.apiValue.trim() : null,
      reasoningLabel: tier?.label,
    );
  }

  /// 有效的上下文窗口（contextWindow=0 时回退到默认 262144 / 256K）
  int get effectiveContextWindow =>
      contextWindow > 0 ? contextWindow : kDefaultContextWindow;

  AIModelConfig copyWith({
    String? id,
    String? endpointId,
    String? endpointName,
    String? provider,
    String? name,
    String? apiKey,
    String? baseUrl,
    String? modelName,
    double? temperature,
    int? maxTokens,
    int? contextWindow,
    Object? fallbackModelId = _unset,
    bool? supportsFunctionCalling,
    Object? reasoningEffort = _unset,
    Object? reasoningLabel = _unset,
  }) {
    return AIModelConfig.create(
      id: id ?? this.id,
      endpointId: endpointId ?? this.endpointId,
      endpointName: endpointName ?? this.endpointName,
      provider: provider ?? this.provider,
      name: name ?? this.name,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      modelName: modelName ?? this.modelName,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      contextWindow: contextWindow ?? this.contextWindow,
      fallbackModelId: identical(fallbackModelId, _unset)
          ? this.fallbackModelId
          : fallbackModelId as String?,
      supportsFunctionCalling:
          supportsFunctionCalling ?? this.supportsFunctionCalling,
      reasoningEffort: identical(reasoningEffort, _unset)
          ? this.reasoningEffort
          : reasoningEffort as String?,
      reasoningLabel: identical(reasoningLabel, _unset)
          ? this.reasoningLabel
          : reasoningLabel as String?,
    );
  }
}

const Object _unset = Object();
