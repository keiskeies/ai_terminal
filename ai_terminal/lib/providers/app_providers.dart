import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/daos.dart';
import '../core/credentials_store.dart';
import '../models/host_config.dart';
import '../models/ai_model_config.dart';
import '../models/command_snippet.dart';
import '../models/chat_session.dart';

// ===== 主机 Provider =====
final hostsProvider = StateNotifierProvider<HostsNotifier, AsyncValue<List<HostConfig>>>((ref) {
  return HostsNotifier();
});

class HostsNotifier extends StateNotifier<AsyncValue<List<HostConfig>>> {
  HostsNotifier() : super(const AsyncValue.loading()) {
    loadHosts();
  }

  Future<void> loadHosts() async {
    state = const AsyncValue.loading();
    try {
      final hosts = HostsDao.cached.toList();
      hosts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      state = AsyncValue.data(hosts);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> addHost(HostConfig config) async {
    await HostsDao.upsert(config);
    await loadHosts();
  }

  Future<void> updateHost(HostConfig config) async {
    await HostsDao.upsert(config);
    await loadHosts();
  }

  Future<void> deleteHost(String id) async {
    await HostsDao.delete(id);
    await loadHosts();
  }

  Map<String, List<HostConfig>> getHostsByGroup() {
    final hosts = state.valueOrNull ?? [];
    final grouped = <String, List<HostConfig>>{};
    for (final host in hosts) {
      grouped.putIfAbsent(host.group, () => []).add(host);
    }
    return grouped;
  }

  HostConfig? getHostById(String id) {
    return HostsDao.getCachedById(id);
  }
}

// ===== AI 模型 Provider =====
final aiModelsProvider = StateNotifierProvider<AIModelsNotifier, List<AIModelConfig>>((ref) {
  return AIModelsNotifier();
});

class AIModelsNotifier extends StateNotifier<List<AIModelConfig>> {
  AIModelsNotifier() : super([]) {
    loadModels();
  }

  Future<void> loadModels() async {
    final models = AIModelsDao.cached.toList();
    // 异步从 CredentialsStore 注入 apiKey（DB 中只存空占位）
    // 必须 await：否则 state 在 apiKey 注入完成前就被设置，导致重启后 apiKey 为空
    await _injectApiKeys(models);
    state = models;
  }

  /// 异步从 CredentialsStore 注入 apiKey 到内存模型
  /// 兼容旧数据：若 DB 中 apiKey 非空（旧版本明文存储），迁移到 CredentialsStore
  Future<void> _injectApiKeys(List<AIModelConfig> models) async {
    var changed = false;
    for (final m in models) {
      final storedKey = await CredentialsStore.get(hostId: m.id, type: 'apiKey');
      if (storedKey != null) {
        m.apiKey = storedKey;
      } else if (m.apiKey.isNotEmpty) {
        // 旧数据迁移：DB 中有明文 apiKey，转移到 CredentialsStore
        await CredentialsStore.save(hostId: m.id, type: 'apiKey', value: m.apiKey);
        m.apiKey = ''; // 清空 DB 引用（下次 put 时会落盘空值）
        changed = true;
      }
    }
    if (changed) {
      for (final m in models) {
        await AIModelsDao.upsert(m);
      }
    }
  }

  AIModelConfig? get defaultModel {
    return state.firstWhere(
      (m) => m.isDefault,
      orElse: () => state.isNotEmpty ? state.first : AIModelConfig(),
    );
  }

  Future<void> addModel(AIModelConfig config) async {
    // 如果设为默认，先取消其他默认
    if (config.isDefault) {
      await AIModelsDao.clearDefault();
    }
    // apiKey 走 CredentialsStore，DB 中只存空占位
    final apiKey = config.apiKey;
    config.apiKey = '';
    await AIModelsDao.upsert(config);
    if (apiKey.isNotEmpty) {
      await CredentialsStore.save(hostId: config.id, type: 'apiKey', value: apiKey);
      config.apiKey = apiKey; // 内存中保留供当前会话使用
    }
    await loadModels();
  }

  Future<void> updateModel(AIModelConfig config) async {
    if (config.isDefault) {
      await AIModelsDao.clearDefault();
    }
    // apiKey 走 CredentialsStore
    final apiKey = config.apiKey;
    config.apiKey = '';
    await AIModelsDao.upsert(config);
    await CredentialsStore.save(hostId: config.id, type: 'apiKey', value: apiKey);
    config.apiKey = apiKey;
    await loadModels();
  }

  Future<void> deleteModel(String id) async {
    // 先从当前 state 判断被删除的是否是默认模型
    final wasDefault = state.any((m) => m.id == id && m.isDefault);
    await AIModelsDao.delete(id);
    await CredentialsStore.delete(hostId: id, type: 'apiKey');
    // 如果删除的是默认模型，且还有其他模型，把第一个设为默认
    final remaining = state.where((m) => m.id != id).toList();
    if (wasDefault && remaining.isNotEmpty) {
      final first = remaining.first.copyWith(isDefault: true);
      await AIModelsDao.upsert(first);
    }
    await loadModels();
  }
}

// ===== 快捷命令 Provider =====
final snippetsProvider = StateNotifierProvider<SnippetsNotifier, List<CommandSnippet>>((ref) {
  return SnippetsNotifier();
});

class SnippetsNotifier extends StateNotifier<List<CommandSnippet>> {
  SnippetsNotifier() : super([]) {
    loadSnippets();
  }

  void loadSnippets() {
    state = SnippetsDao.cached.toList();
  }

  Future<void> addSnippet(CommandSnippet snippet) async {
    await SnippetsDao.upsert(snippet);
    loadSnippets();
  }

  Future<void> updateSnippet(CommandSnippet snippet) async {
    await SnippetsDao.upsert(snippet);
    loadSnippets();
  }

  Future<void> deleteSnippet(String id) async {
    await SnippetsDao.delete(id);
    loadSnippets();
  }
}

// ===== 聊天会话 Provider =====
final chatSessionsProvider = StateNotifierProvider<ChatSessionsNotifier, List<ChatSession>>((ref) {
  return ChatSessionsNotifier();
});

class ChatSessionsNotifier extends StateNotifier<List<ChatSession>> {
  ChatSessionsNotifier() : super([]) {
    loadSessions();
  }

  void loadSessions() {
    state = ChatSessionsDao.cached.toList();
    state.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  ChatSession? getSession(String id) {
    return ChatSessionsDao.getCachedById(id);
  }

  Future<void> saveSession(ChatSession session) async {
    await ChatSessionsDao.upsert(session);
    loadSessions();
  }

  Future<void> deleteSession(String id) async {
    await ChatSessionsDao.delete(id);
    loadSessions();
  }
}

// ===== 设置 Provider =====
final settingsProvider = StateNotifierProvider<SettingsNotifier, Map<String, dynamic>>((ref) {
  return SettingsNotifier();
});

class SettingsNotifier extends StateNotifier<Map<String, dynamic>> {
  SettingsNotifier() : super({}) {
    loadSettings();
  }

  void loadSettings() {
    state = SettingsDao.cachedMap;
  }

  Future<void> setSetting(String key, dynamic value) async {
    await SettingsDao.set(key, value);
    state = {...state, key: value};
  }

  T? getSetting<T>(String key, {T? defaultValue}) {
    return state[key] as T? ?? defaultValue;
  }
}
