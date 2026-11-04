import 'dart:convert';
import '../models/ai_endpoint.dart';
import '../models/ai_model_config.dart';
import '../core/credentials_store.dart';
import 'daos.dart';

/// 选择器里的一个「端点 + 模型」选项。
class AIModelChoice {
  final AIEndpoint endpoint;
  final AIEndpointModel model;

  const AIModelChoice({required this.endpoint, required this.model});

  String get modelId => model.id;
  String get displayName => model.name;
  String get endpointName => endpoint.name;
}

/// 「当前选择」的持久化与解析。
///
/// 这不是配置里的默认模型：配置页没有默认项，只有上次选择。
/// 没有任何选择时，运行时取第一个可用模型并把选择写回。
class AIModelSelectionService {
  static const String selectedModelKey = 'aiSelectedModelId';
  static const String reasoningTiersKey = 'aiSelectedReasoningTiers';

  static String? get selectedModelId =>
      SettingsDao.getCached(selectedModelKey) as String?;

  static Future<void> saveSelectedModel(String modelId) =>
      SettingsDao.set(selectedModelKey, modelId);

  static Map<String, String> _savedTiers() {
    final raw = SettingsDao.getCached(reasoningTiersKey);
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      } catch (_) {}
    }
    return {};
  }

  static String? tierFor(String modelId) => _savedTiers()[modelId];

  static Future<void> saveReasoningTier(String modelId, String level) async {
    final tiers = _savedTiers();
    tiers[modelId] = level;
    await SettingsDao.set(reasoningTiersKey, tiers);
  }

  static List<AIModelChoice> allChoices(List<AIEndpoint> endpoints) {
    final result = <AIModelChoice>[];
    for (final e in endpoints) {
      for (final m in e.models) {
        result.add(AIModelChoice(endpoint: e, model: m));
      }
    }
    return result;
  }

  static AIModelChoice? findChoice(
      List<AIEndpoint> endpoints, String modelId) {
    for (final e in endpoints) {
      for (final m in e.models) {
        if (m.id == modelId) {
          return AIModelChoice(endpoint: e, model: m);
        }
      }
    }
    return null;
  }

  /// 同步解析：只使用调用方传入的端点状态（通常已注入 API Key）。
  static AIModelConfig? buildConfig(
    List<AIEndpoint> endpoints,
    String modelId, {
    String? tierLevel,
  }) {
    final choice = findChoice(endpoints, modelId);
    if (choice == null) return null;
    final level = tierLevel ?? tierFor(modelId);
    final tier = choice.model.resolveReasoningTier(level);
    return AIModelConfig.fromEndpoint(
      endpoint: choice.endpoint,
      model: choice.model,
      tier: tier,
    );
  }

  /// 解析「当前选择」，供终端页初始化、ChatProvider 等无 provider 状态处使用。
  ///
  /// API Key 未注入时从 CredentialsStore 读取；没有任何选择时取第一个模型。
  static Future<AIModelConfig?> resolveCurrent({
    List<AIEndpoint>? endpoints,
  }) async {
    final list = endpoints ?? AIEndpointsDao.cached;
    if (list.isEmpty) return null;

    var choice = selectedModelId == null
        ? null
        : findChoice(list, selectedModelId!);
    if (choice == null) {
      final all = allChoices(list);
      if (all.isEmpty) return null;
      final first = all.first;
      choice = first;
      await saveSelectedModel(choice.modelId);
    }

    final endpoint = choice.endpoint;
    var apiKey = endpoint.apiKey;
    if (apiKey.isEmpty) {
      apiKey =
          await CredentialsStore.get(hostId: endpoint.id, type: 'apiKey') ?? '';
    }
    final resolvedEndpoint =
        apiKey == endpoint.apiKey ? endpoint : endpoint.copyWith(apiKey: apiKey);
    final tier = choice.model.resolveReasoningTier(tierFor(choice.modelId));
    return AIModelConfig.fromEndpoint(
      endpoint: resolvedEndpoint,
      model: choice.model,
      tier: tier,
    );
  }
}
