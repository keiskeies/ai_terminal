import 'dart:io';
import 'package:hive/hive.dart';
import 'models/host_config.dart';
import 'models/ai_model_config.dart';
import 'models/chat_session.dart';
import 'models/command_snippet.dart';
import 'models/conversation.dart';
import 'models/agent_event.dart';

Future<void> main() async {
  Hive.init('/Users/cjm/Documents');
  Hive.registerAdapter(HostConfigAdapter());
  Hive.registerAdapter(AIModelConfigAdapter());
  Hive.registerAdapter(ChatSessionAdapter());
  Hive.registerAdapter(ChatMessageAdapter());
  Hive.registerAdapter(CommandBlockAdapter());
  Hive.registerAdapter(CommandSnippetAdapter());
  Hive.registerAdapter(ConvMessageAdapter());
  Hive.registerAdapter(ConvAgentLogAdapter());
  Hive.registerAdapter(ConversationAdapter());
  Hive.registerAdapter(AgentEventAdapter());
  Hive.registerAdapter(AgentEventTypeAdapter());

  final box = await Hive.openBox<Conversation>('conversations');
  print('Conversations count: ${box.length}');
  for (final conv in box.values) {
    print('--- Conversation: id=${conv.id} hostId=${conv.hostId} active=${conv.isActive} title=${conv.title} ---');
    print('messages: ${conv.messages.length}');
    for (final m in conv.messages) {
      print('  role=${m.role} contentLength=${m.content.length} command=${m.command} events=${m.events?.length ?? 0}');
      if (m.content.isNotEmpty) {
        print('    content preview: ${m.content.substring(0, m.content.length > 100 ? 100 : m.content.length)}');
      }
      if (m.events != null && m.events!.isNotEmpty) {
        for (final e in m.events!) {
          print('    event: type=${e.type} textLen=${e.text?.length ?? 0} commandLen=${e.command?.length ?? 0}');
        }
      }
    }
  }
  await box.close();
  await Hive.close();
}
