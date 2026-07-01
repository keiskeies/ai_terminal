import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hive_init.dart';
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
      final hosts = HiveInit.hostsBox.values.toList();
      hosts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      state = AsyncValue.data(hosts);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> addHost(HostConfig config) async {
    await HiveInit.hostsBox.put(config.id, config);
    await loadHosts();
  }

  Future<void> updateHost(HostConfig config) async {
    await HiveInit.hostsBox.put(config.id, config);
    await loadHosts();
  }

  Future<void> deleteHost(String id) async {
    await HiveInit.hostsBox.delete(id);
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
    return HiveInit.hostsBox.get(id);
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

  void loadModels() {
    final models = HiveInit.aiModelsBox.values.toList();
    // 异步从 CredentialsStore 注入 apiKey（Hive 中只存空占位）
    // 不阻塞 UI，注入完成后 state 会自动刷新（调用方在 await 后再 loadModels 一次）
    _injectApiKeys(models);
    state = models;
  }

  /// 异步从 CredentialsStore 注入 apiKey 到内存模型
  /// 兼容旧数据：若 Hive 中 apiKey 非空（旧版本明文存储），迁移到 CredentialsStore
  Future<void> _injectApiKeys(List<AIModelConfig> models) async {
    var changed = false;
    for (final m in models) {
      final storedKey = await CredentialsStore.get(hostId: m.id, type: 'apiKey');
      if (storedKey != null) {
        m.apiKey = storedKey;
      } else if (m.apiKey.isNotEmpty) {
        // 旧数据迁移：Hive 中有明文 apiKey，转移到 CredentialsStore
        await CredentialsStore.save(hostId: m.id, type: 'apiKey', value: m.apiKey);
        m.apiKey = ''; // 清空 Hive 引用（下次 put 时会落盘空值）
        changed = true;
      }
    }
    if (changed) {
      for (final m in models) {
        await HiveInit.aiModelsBox.put(m.id, m);
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
      final list = state.map((m) => m.copyWith(isDefault: false)).toList();
      for (final m in list) {
        await HiveInit.aiModelsBox.put(m.id, m);
      }
    }
    // apiKey 走 CredentialsStore，Hive 中只存空占位
    final apiKey = config.apiKey;
    config.apiKey = '';
    await HiveInit.aiModelsBox.put(config.id, config);
    if (apiKey.isNotEmpty) {
      await CredentialsStore.save(hostId: config.id, type: 'apiKey', value: apiKey);
      config.apiKey = apiKey; // 内存中保留供当前会话使用
    }
    loadModels();
  }

  Future<void> updateModel(AIModelConfig config) async {
    if (config.isDefault) {
      final list = state.map((m) => m.copyWith(isDefault: false)).toList();
      for (final m in list) {
        if (m.id != config.id) {
          await HiveInit.aiModelsBox.put(m.id, m);
        }
      }
    }
    // apiKey 走 CredentialsStore
    final apiKey = config.apiKey;
    config.apiKey = '';
    await HiveInit.aiModelsBox.put(config.id, config);
    await CredentialsStore.save(hostId: config.id, type: 'apiKey', value: apiKey);
    config.apiKey = apiKey;
    loadModels();
  }

  Future<void> deleteModel(String id) async {
    await HiveInit.aiModelsBox.delete(id);
    await CredentialsStore.delete(hostId: id, type: 'apiKey');
    // 如果删除的是默认模型，设为第一个为默认
    if (state.isNotEmpty && !state.first.isDefault) {
      final first = state.first.copyWith(isDefault: true);
      await HiveInit.aiModelsBox.put(first.id, first);
    }
    loadModels();
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
    state = HiveInit.snippetsBox.values.toList();
  }

  Future<void> addSnippet(CommandSnippet snippet) async {
    await HiveInit.snippetsBox.put(snippet.id, snippet);
    loadSnippets();
  }

  Future<void> updateSnippet(CommandSnippet snippet) async {
    await HiveInit.snippetsBox.put(snippet.id, snippet);
    loadSnippets();
  }

  Future<void> deleteSnippet(String id) async {
    await HiveInit.snippetsBox.delete(id);
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
    state = HiveInit.chatSessionsBox.values.toList();
    state.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  ChatSession? getSession(String id) {
    return HiveInit.chatSessionsBox.get(id);
  }

  Future<void> saveSession(ChatSession session) async {
    await HiveInit.chatSessionsBox.put(session.id, session);
    loadSessions();
  }

  Future<void> deleteSession(String id) async {
    await HiveInit.chatSessionsBox.delete(id);
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
    state = Map<String, dynamic>.from(HiveInit.settingsBox.toMap());
  }

  Future<void> setSetting(String key, dynamic value) async {
    await HiveInit.settingsBox.put(key, value);
    state = {...state, key: value};
  }

  T? getSetting<T>(String key, {T? defaultValue}) {
    return state[key] as T? ?? defaultValue;
  }
}
