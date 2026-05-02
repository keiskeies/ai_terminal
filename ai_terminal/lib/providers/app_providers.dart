import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hive_init.dart';
import '../models/host_config.dart';
import '../models/ai_model_config.dart';
import '../models/command_snippet.dart';
import '../models/chat_session.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

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
    state = HiveInit.aiModelsBox.values.toList();
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
    await HiveInit.aiModelsBox.put(config.id, config);
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
    await HiveInit.aiModelsBox.put(config.id, config);
    loadModels();
  }

  Future<void> deleteModel(String id) async {
    await HiveInit.aiModelsBox.delete(id);
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
