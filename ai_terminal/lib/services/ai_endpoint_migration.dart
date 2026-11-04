import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../core/credentials_store.dart';
import '../models/ai_endpoint.dart';
import '../models/ai_model_config.dart';
import 'agent_logger.dart';
import 'daos.dart';
import 'provider_config_service.dart';

/// 把旧的「一行一个模型」配置迁移成「端点 + 模型目录」。
///
/// 旧表 ai_models 保留不删，作为回滚/审计数据；新代码只读 ai_endpoints。
/// API Key 从按模型 id 的安全存储复制到按端点 id，旧 key 不删除。
class AIEndpointsMigration {
  static const String flagKey = 'aiEndpointsMigrationV1';
  static const Uuid _uuid = Uuid();

  static Future<void> migrateIfNeeded() async {
    if (SettingsDao.getCached(flagKey) == 'done') return;

    final List<AIModelConfig> legacy;
    try {
      legacy = AIModelsDao.cached.isNotEmpty
          ? List<AIModelConfig>.of(AIModelsDao.cached)
          : await AIModelsDao.getAll();
    } catch (e, stack) {
      agentLogger.error('AIEndpointMigration', '读取旧模型配置失败: $e\n$stack');
      return;
    }

    if (legacy.isEmpty) {
      await SettingsDao.set(flagKey, 'done');
      return;
    }

    try {
      final grouped = groupLegacyModels(legacy);

      final existing = List<AIEndpoint>.of(AIEndpointsDao.cached);
      final usedNames = <String>{
        for (final e in existing) e.name,
      };

      for (final models in grouped.values) {
        final first = models.first;
        final preset = ProviderConfigService.getProviderById(first.provider);
        final providerId = preset?.id ?? 'custom';
        final protocol = first.provider == 'ernie' ? 'ernie' : 'openai';

        var endpoint = _findEndpoint(existing, providerId, first.baseUrl);
        final endpointId = endpoint?.id ?? _uuid.v4();

        final baseName = preset != null && preset.id != 'custom'
            ? preset.name
            : '自定义端点';
        final name = endpoint != null && endpoint.name.isNotEmpty
            ? endpoint.name
            : _uniqueName(baseName, usedNames);
        usedNames.add(name);

        final mergedModels = <AIEndpointModel>[
          if (endpoint != null) ...endpoint.models,
        ];
        for (final m in models) {
          if (mergedModels.any((x) => x.id == m.id)) continue;
          mergedModels.add(AIEndpointModel(
            id: m.id,
            name: m.name,
            modelName: m.modelName,
            contextWindow: m.contextWindow,
            maxTokens: m.maxTokens,
            temperature: m.temperature,
            supportsFunctionCalling: m.supportsFunctionCalling,
            fallbackModelId: m.fallbackModelId,
          ));
        }

        endpoint = AIEndpoint(
          id: endpointId,
          providerId: providerId,
          name: name,
          baseUrl: first.baseUrl,
          protocol: protocol,
          models: mergedModels,
          createdAt: endpoint?.createdAt ??
              DateTime.now().millisecondsSinceEpoch,
        );
        await AIEndpointsDao.upsert(endpoint);

        await _migrateApiKey(endpointId, models);
      }

      if ((SettingsDao.getCached('aiSelectedModelId') as String?)?.isNotEmpty !=
          true) {
        final legacyDefault = await AIModelsDao.getLegacyDefaultId();
        final fallback = AIEndpointsDao.cached.isNotEmpty &&
                AIEndpointsDao.cached.first.models.isNotEmpty
            ? AIEndpointsDao.cached.first.models.first.id
            : null;
        final selected = legacyDefault ?? fallback;
        if (selected != null) {
          await SettingsDao.set('aiSelectedModelId', selected);
        }
      }

      await AIEndpointsDao.loadCache();
      await SettingsDao.set(flagKey, 'done');
      agentLogger.info(
          'AIEndpointMigration', '迁移完成：${grouped.length} 个端点，${legacy.length} 个模型');
    } catch (e, stack) {
      // 不写 done 标记：下次启动重试；旧表仍在，不会丢数据
      agentLogger.error('AIEndpointMigration', '迁移失败（下次启动重试）: $e\n$stack');
    }
  }

  /// 旧模型按「provider + Base URL」分组：同一端点的多个模型合并。
  /// 纯函数，供迁移与单测共用。
  @visibleForTesting
  static Map<String, List<AIModelConfig>> groupLegacyModels(
      List<AIModelConfig> legacy) {
    final grouped = <String, List<AIModelConfig>>{};
    for (final m in legacy) {
      final key = '${m.provider}\u0000${m.baseUrl}';
      grouped.putIfAbsent(key, () => []).add(m);
    }
    return grouped;
  }

  static AIEndpoint? _findEndpoint(
      List<AIEndpoint> existing, String providerId, String baseUrl) {
    for (final e in existing) {
      if (e.providerId == providerId && e.baseUrl == baseUrl) return e;
    }
    return null;
  }

  static String _uniqueName(String base, Set<String> used) {
    if (!used.contains(base)) return base;
    var i = 2;
    while (used.contains('$base ($i)')) {
      i++;
    }
    return '$base ($i)';
  }

  static Future<void> _migrateApiKey(
      String endpointId, List<AIModelConfig> models) async {
    try {
      final existingKey =
          await CredentialsStore.get(hostId: endpointId, type: 'apiKey');
      if (existingKey != null && existingKey.isNotEmpty) return;
      for (final m in models) {
        final stored =
            await CredentialsStore.get(hostId: m.id, type: 'apiKey');
        // 兼容更早版本把明文 key 留在 ai_models 行里的情况（R7 旧数据迁移）
        final key = (stored != null && stored.isNotEmpty) ? stored : m.apiKey;
        if (key.isNotEmpty) {
          await CredentialsStore.save(
              hostId: endpointId, type: 'apiKey', value: key);
          return;
        }
      }
    } catch (e) {
      // Key 复制失败不阻断配置迁移：端点仍在，用户可在设置里重填
      debugPrint('[AIEndpointMigration] 迁移 API Key 失败 ($endpointId): $e');
    }
  }
}
