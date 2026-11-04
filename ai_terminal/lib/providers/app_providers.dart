import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/daos.dart';
import '../core/credentials_store.dart';
import '../models/host_config.dart';
import '../models/ai_model_config.dart';
import '../models/ai_endpoint.dart';
import '../services/ai_model_selection_service.dart';
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

// ===== AI 端点 / 模型 Provider =====
final aiEndpointsProvider =
    StateNotifierProvider<AIEndpointsNotifier, List<AIEndpoint>>((ref) {
  return AIEndpointsNotifier();
});

class AIEndpointsNotifier extends StateNotifier<List<AIEndpoint>> {
  AIEndpointsNotifier() : super([]) {
    loadEndpoints();
  }

  Future<void> loadEndpoints() async {
    // 强制让出同步栈：provider 可能在 initState/build 期间被首次创建，
    // 空列表也必须在构建结束后再写 state，否则 Riverpod 会抛
    // "Tried to modify a provider while the widget tree was building"。
    await Future<void>.microtask(() {});
    final endpoints = AIEndpointsDao.cached.toList();
    // API Key 不落库：按端点 id 从安全存储注入到内存
    final loaded = <AIEndpoint>[];
    for (final e in endpoints) {
      final storedKey =
          await CredentialsStore.get(hostId: e.id, type: 'apiKey');
      loaded.add(storedKey == null || storedKey.isEmpty
          ? e
          : e.copyWith(apiKey: storedKey));
    }
    AIEndpointsDao.cacheWithRuntimeKeys(loaded);
    state = loaded;
  }

  Future<void> saveEndpoint(AIEndpoint endpoint,
      {bool clearApiKey = false}) async {
    final apiKey = endpoint.apiKey;
    await AIEndpointsDao.upsert(endpoint.copyWith(apiKey: ''));
    if (clearApiKey) {
      await CredentialsStore.delete(hostId: endpoint.id, type: 'apiKey');
    } else if (apiKey.isNotEmpty) {
      await CredentialsStore.save(
          hostId: endpoint.id, type: 'apiKey', value: apiKey);
    }
    await loadEndpoints();
  }

  Future<void> deleteEndpoint(String id) async {
    await AIEndpointsDao.delete(id);
    await CredentialsStore.delete(hostId: id, type: 'apiKey');
    await loadEndpoints();
  }

  /// 同步构建某个模型的运行时配置（state 中的端点已注入 API Key）
  AIModelConfig? configForModel(String modelId, {String? tierLevel}) {
    return AIModelSelectionService.buildConfig(state, modelId,
        tierLevel: tierLevel);
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
