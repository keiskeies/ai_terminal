import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/host_config.dart';
import '../models/ai_model_config.dart';
import '../models/chat_session.dart';
import '../models/command_snippet.dart';
import '../models/conversation.dart';
import '../models/agent_event.dart';
import 'credentials_store.dart';

class HiveInit {
  static Future<void> init() async {
    await Hive.initFlutter();

    // 注册适配器（按依赖顺序：AgentEventType → AgentEvent → ConvMessage）
    Hive.registerAdapter(HostConfigAdapter());
    Hive.registerAdapter(AIModelConfigAdapter());
    Hive.registerAdapter(ChatSessionAdapter());
    Hive.registerAdapter(ChatMessageAdapter());
    Hive.registerAdapter(CommandBlockAdapter());
    Hive.registerAdapter(CommandSnippetAdapter());
    Hive.registerAdapter(AgentEventTypeAdapter());
    Hive.registerAdapter(AgentEventAdapter());
    Hive.registerAdapter(ConvMessageAdapter());
    Hive.registerAdapter(ConvAgentLogAdapter());
    Hive.registerAdapter(ConversationAdapter());

    // 打开 boxes
    await Hive.openBox<HostConfig>('hosts');
    await Hive.openBox<AIModelConfig>('aiModels');
    await Hive.openBox<ChatSession>('chatSessions');
    await Hive.openBox<CommandSnippet>('snippets');
    await Hive.openBox('settings');
    await Hive.openBox('auditLogs');

    // 会话 box 如果因模型 typeId 变更（开发期 schema 调整）损坏，自动重建
    try {
      await Hive.openBox<Conversation>('conversations');
    } on HiveError catch (e) {
      debugPrint('[HiveInit] 会话数据无法读取，自动重置: $e');
      await Hive.deleteBoxFromDisk('conversations');
      await Hive.openBox<Conversation>('conversations');
    }

    // 初始化凭据存储
    await CredentialsStore.init();
  }

  // Box 引用
  static Box<HostConfig> get hostsBox => Hive.box<HostConfig>('hosts');
  static Box<AIModelConfig> get aiModelsBox => Hive.box<AIModelConfig>('aiModels');
  static Box<ChatSession> get chatSessionsBox => Hive.box<ChatSession>('chatSessions');
  static Box<CommandSnippet> get snippetsBox => Hive.box<CommandSnippet>('snippets');
  static Box get settingsBox => Hive.box('settings');
  static Box get auditLogsBox => Hive.box('auditLogs');
  static Box<Conversation> get conversationsBox => Hive.box<Conversation>('conversations');
}
