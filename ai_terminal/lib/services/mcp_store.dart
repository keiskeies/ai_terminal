import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/credentials_store.dart';
import 'daos.dart';
import 'mcp_models.dart';

/// MCP 配置持久化
///
/// 非敏感字段进 SettingsDao；headers / env / OAuth clientSecret / token 进
/// CredentialsStore（R7：敏感数据必须经 secure_storage，AES 加密 SQLite 兜底）。
class McpStore {
  McpStore._();

  static const String _settingsKey = 'mcpServers';
  static const String _credHostId = '__mcp__';

  static List<McpServerConfig> loadCachedConfigs() {
    final raw = SettingsDao.getCached(_settingsKey);
    if (raw == null) return const [];
    try {
      dynamic decoded = raw;
      if (raw is String) {
        decoded = jsonDecode(raw);
      }
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => McpServerConfig.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.id.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[McpStore] 解析配置失败: $e');
      return const [];
    }
  }

  /// 读取完整配置（含 headers/env/clientSecret）
  static Future<List<McpServerConfig>> loadAll() async {
    final configs = loadCachedConfigs();
    if (configs.isEmpty) return configs;
    final out = <McpServerConfig>[];
    for (final config in configs) {
      final headers = await _readMap('headers_${config.id}');
      final env = await _readMap('env_${config.id}');
      final clientSecret =
          await _readString('oauthClient_${config.id}') ?? '';
      out.add(config.copyWith(
        headers: headers,
        env: env,
        oauthClientSecret: clientSecret,
      ));
    }
    return out;
  }

  static Future<void> saveAll(
    List<McpServerConfig> configs, {
    Iterable<String> removedIds = const [],
  }) async {
    await saveConfigs(configs);
    final failures = <String>[];
    for (final config in configs) {
      if (!await _writeMap('headers_${config.id}', config.headers)) {
        failures.add('${config.name} headers');
      }
      if (!await _writeMap('env_${config.id}', config.env)) {
        failures.add('${config.name} env');
      }
      if (config.oauthClientSecret.trim().isEmpty) {
        await CredentialsStore.delete(
          hostId: _credHostId,
          type: 'oauthClient_${config.id}',
        );
      } else {
        final ok = await CredentialsStore.save(
          hostId: _credHostId,
          type: 'oauthClient_${config.id}',
          value: config.oauthClientSecret.trim(),
        );
        if (!ok) failures.add('${config.name} clientSecret');
      }
    }
    for (final id in removedIds) {
      await deleteSecrets(id);
    }
    // R8: 凭据写入失败必须暴露，不能只留在 debug 日志里
    if (failures.isNotEmpty) {
      throw StateError('MCP 凭据写入失败：${failures.join('、')}');
    }
  }

  /// 只写非敏感配置（开关、工具白名单等），不触碰凭据
  static Future<void> saveConfigs(List<McpServerConfig> configs) async {
    await SettingsDao.set(
      _settingsKey,
      configs.map((c) => c.toJson()).toList(),
    );
  }

  static Future<void> deleteSecrets(String id) async {
    for (final type in [
      'headers_$id',
      'env_$id',
      'oauthClient_$id',
      'oauthToken_$id',
    ]) {
      await CredentialsStore.delete(hostId: _credHostId, type: type);
    }
  }

  static Future<McpOAuthTokenData?> loadOAuthToken(String id) async {
    final raw = await _readString('oauthToken_$id');
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final token = McpOAuthTokenData.fromJson(Map<String, dynamic>.from(json));
      if (token.accessToken.isEmpty) return null;
      return token;
    } catch (e) {
      debugPrint('[McpStore] 解析 OAuth token 失败 ($id): $e');
      return null;
    }
  }

  static Future<void> saveOAuthToken(
    String id,
    McpOAuthTokenData token,
  ) async {
    await CredentialsStore.save(
      hostId: _credHostId,
      type: 'oauthToken_$id',
      value: jsonEncode(token.toJson()),
    );
  }

  static Future<void> clearOAuthToken(String id) async {
    await CredentialsStore.delete(
      hostId: _credHostId,
      type: 'oauthToken_$id',
    );
  }

  static Future<Map<String, String>> _readMap(String type) async {
    final raw = await _readString(type);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return const {};
      return json.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } catch (_) {
      return const {};
    }
  }

  static Future<String?> _readString(String type) async {
    try {
      return await CredentialsStore.get(hostId: _credHostId, type: type);
    } catch (e) {
      debugPrint('[McpStore] 读取凭据失败 ($type): $e');
      return null;
    }
  }

  static Future<bool> _writeMap(
    String type,
    Map<String, String> values,
  ) async {
    final cleaned = <String, String>{
      for (final entry in values.entries)
        if (entry.key.trim().isNotEmpty) entry.key.trim(): entry.value,
    };
    if (cleaned.isEmpty) {
      await CredentialsStore.delete(hostId: _credHostId, type: type);
      return true;
    }
    return CredentialsStore.save(
      hostId: _credHostId,
      type: type,
      value: jsonEncode(cleaned),
    );
  }
}
