/// 一个端点（Base URL + API Key + 协议）下挂多个模型。
///
/// 运行时不会直接把这个对象交给 AIProvider：选择模型后由
/// `AIModelConfig.fromEndpoint` 拍平成 `AIModelConfig`，保持引擎/AIProvider
/// 的接口不变。API Key 仅存在内存与 CredentialsStore，不写入数据库。
class AIEndpoint {
  final String id;
  final String providerId;
  final String name;
  final String baseUrl;
  final String protocol;
  final String apiKey;
  final List<AIEndpointModel> models;
  final int createdAt;

  const AIEndpoint({
    required this.id,
    required this.providerId,
    required this.name,
    required this.baseUrl,
    required this.protocol,
    this.apiKey = '',
    this.models = const [],
    required this.createdAt,
  });

  AIEndpointModel? modelById(String modelId) {
    for (final m in models) {
      if (m.id == modelId) return m;
    }
    return null;
  }

  AIEndpoint copyWith({
    String? id,
    String? providerId,
    String? name,
    String? baseUrl,
    String? protocol,
    String? apiKey,
    List<AIEndpointModel>? models,
    int? createdAt,
  }) {
    return AIEndpoint(
      id: id ?? this.id,
      providerId: providerId ?? this.providerId,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      protocol: protocol ?? this.protocol,
      apiKey: apiKey ?? this.apiKey,
      models: models ?? this.models,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson({bool includeApiKey = false}) => {
        'id': id,
        'providerId': providerId,
        'name': name,
        'baseUrl': baseUrl,
        'protocol': protocol,
        if (includeApiKey) 'apiKey': apiKey,
        'models': models.map((m) => m.toJson()).toList(),
        'createdAt': createdAt,
      };

  factory AIEndpoint.fromJson(Map<String, dynamic> json) {
    final rawModels = json['models'] as List<dynamic>? ?? const [];
    return AIEndpoint(
      id: json['id'] as String? ?? '',
      providerId: json['providerId'] as String? ?? 'custom',
      name: json['name'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      protocol: json['protocol'] as String? ?? 'openai',
      apiKey: json['apiKey'] as String? ?? '',
      models: rawModels
          .whereType<Map>()
          .map((m) => AIEndpointModel.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class AIEndpointModel {
  final String id;
  final String name;
  final String modelName;
  final int contextWindow;
  final int maxTokens;
  final double temperature;
  final bool supportsFunctionCalling;
  final String? fallbackModelId;
  final bool reasoningEnabled;
  final List<AIReasoningTier> reasoningTiers;

  const AIEndpointModel({
    required this.id,
    required this.name,
    required this.modelName,
    this.contextWindow = 0,
    this.maxTokens = kDefaultMaxOutputTokens,
    this.temperature = 0.3,
    this.supportsFunctionCalling = false,
    this.fallbackModelId,
    this.reasoningEnabled = false,
    this.reasoningTiers = const [],
  });

  /// 启用推理但档位为空时退回标准四档，避免界面上「开了却没有可选档位」。
  List<AIReasoningTier> get activeReasoningTiers {
    if (!reasoningEnabled) return const [];
    if (reasoningTiers.isNotEmpty) return reasoningTiers;
    return kDefaultReasoningTiers;
  }

  /// 按已保存档位解析当前应使用的档位。
  ///
  /// 规则：已保存且存在 → 用它；否则 medium；否则第一个有 API 值的；
  /// 否则第一档。模型未启用推理时返回 null（请求不携带该参数）。
  AIReasoningTier? resolveReasoningTier([String? savedLevel]) {
    final tiers = activeReasoningTiers;
    if (tiers.isEmpty) return null;
    if (savedLevel != null) {
      for (final t in tiers) {
        if (t.level == savedLevel) return t;
      }
    }
    for (final t in tiers) {
      if (t.level == 'medium') return t;
    }
    for (final t in tiers) {
      if (t.apiValue.trim().isNotEmpty) return t;
    }
    return tiers.first;
  }

  AIEndpointModel copyWith({
    String? id,
    String? name,
    String? modelName,
    int? contextWindow,
    int? maxTokens,
    double? temperature,
    bool? supportsFunctionCalling,
    Object? fallbackModelId = _unset,
    bool? reasoningEnabled,
    List<AIReasoningTier>? reasoningTiers,
  }) {
    return AIEndpointModel(
      id: id ?? this.id,
      name: name ?? this.name,
      modelName: modelName ?? this.modelName,
      contextWindow: contextWindow ?? this.contextWindow,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      supportsFunctionCalling:
          supportsFunctionCalling ?? this.supportsFunctionCalling,
      fallbackModelId: identical(fallbackModelId, _unset)
          ? this.fallbackModelId
          : fallbackModelId as String?,
      reasoningEnabled: reasoningEnabled ?? this.reasoningEnabled,
      reasoningTiers: reasoningTiers ?? this.reasoningTiers,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'modelName': modelName,
        'contextWindow': contextWindow,
        'maxTokens': maxTokens,
        'temperature': temperature,
        'supportsFunctionCalling': supportsFunctionCalling,
        if (fallbackModelId != null) 'fallbackModelId': fallbackModelId,
        'reasoningEnabled': reasoningEnabled,
        'reasoningTiers': reasoningTiers.map((t) => t.toJson()).toList(),
      };

  factory AIEndpointModel.fromJson(Map<String, dynamic> json) {
    final rawTiers = json['reasoningTiers'] as List<dynamic>? ?? const [];
    return AIEndpointModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      modelName: json['modelName'] as String? ?? '',
      contextWindow: (json['contextWindow'] as num?)?.toInt() ?? 0,
      maxTokens: (json['maxTokens'] as num?)?.toInt() ?? kDefaultMaxOutputTokens,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.3,
      supportsFunctionCalling: json['supportsFunctionCalling'] as bool? ?? false,
      fallbackModelId: json['fallbackModelId'] as String?,
      reasoningEnabled: json['reasoningEnabled'] as bool? ?? false,
      reasoningTiers: rawTiers
          .whereType<Map>()
          .map((t) => AIReasoningTier.fromJson(Map<String, dynamic>.from(t)))
          .toList(),
    );
  }
}

class AIReasoningTier {
  final String level;
  final String apiValue;

  const AIReasoningTier({required this.level, this.apiValue = ''});

  /// 胶囊/档位 chips 的短标签。off/low/medium/high 走固定大小写，
  /// 其他自定义档位原样显示。
  String get label {
    switch (level) {
      case 'off':
        return 'Off';
      case 'low':
        return 'Low';
      case 'medium':
        return 'Medium';
      case 'high':
        return 'High';
      default:
        if (level.isEmpty) return '';
        return level[0].toUpperCase() + level.substring(1);
    }
  }

  bool get sendsParameter => apiValue.trim().isNotEmpty;

  AIReasoningTier copyWith({String? level, String? apiValue}) =>
      AIReasoningTier(
        level: level ?? this.level,
        apiValue: apiValue ?? this.apiValue,
      );

  Map<String, dynamic> toJson() => {'level': level, 'apiValue': apiValue};

  factory AIReasoningTier.fromJson(Map<String, dynamic> json) =>
      AIReasoningTier(
        level: json['level'] as String? ?? '',
        apiValue: json['apiValue'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is AIReasoningTier &&
      other.level == level &&
      other.apiValue == apiValue;

  @override
  int get hashCode => Object.hash(level, apiValue);
}

const Object _unset = Object();

/// 未知上下文窗口时的运行时默认值（256K）
const int kDefaultContextWindow = 262144;

/// 未显式配置最大输出时的默认值（32K）
const int kDefaultMaxOutputTokens = 32768;

const List<AIReasoningTier> kDefaultReasoningTiers = [
  AIReasoningTier(level: 'off', apiValue: ''),
  AIReasoningTier(level: 'low', apiValue: 'low'),
  AIReasoningTier(level: 'medium', apiValue: 'medium'),
  AIReasoningTier(level: 'high', apiValue: 'high'),
];
