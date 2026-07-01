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

    // 打开 boxes（若因 schema 变更导致老数据反序列化失败，自动重建对应 box，避免黑屏）
    await _openBoxSafe<HostConfig>('hosts');
    await _openBoxSafe<AIModelConfig>('aiModels');
    await _openBoxSafe<ChatSession>('chatSessions');
    await _openBoxSafe<CommandSnippet>('snippets');
    await Hive.openBox('settings');
    await Hive.openBox('auditLogs');
    await _openBoxSafe<Conversation>('conversations');

    // 初始化凭据存储
    await CredentialsStore.init();
  }

  /// 安全打开 Hive box:若因 schema 变更/老数据反序列化失败,自动重建 box 避免黑屏
  static Future<void> _openBoxSafe<T>(String name) async {
    try {
      await Hive.openBox<T>(name);
    } on HiveError catch (e) {
      debugPrint('[HiveInit] $name box 数据无法读取,自动重置: $e');
      await Hive.deleteBoxFromDisk(name);
      await Hive.openBox<T>(name);
    } on TypeError catch (e) {
      // 捕获 'type Null is not a subtype of type int' 之类老数据类型不匹配
      debugPrint('[HiveInit] $name box 老数据类型不匹配,自动重置: $e');
      await Hive.deleteBoxFromDisk(name);
      await Hive.openBox<T>(name);
    }
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
