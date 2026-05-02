import 'package:hive/hive.dart';

part 'chat_session.g.dart';

@HiveType(typeId: 2)
class ChatSession extends HiveObject {
  @HiveField(0)
  late String id;

  @HiveField(1)
  String? hostId;

  @HiveField(2)
  late List<ChatMessage> messages;

  @HiveField(3)
  late DateTime createdAt;

  @HiveField(4)
  late DateTime updatedAt;

  ChatSession();

  ChatSession.create({
    required this.id,
    this.hostId,
    List<ChatMessage>? messages,
  })  : messages = messages ?? [],
        createdAt = DateTime.now(),
        updatedAt = DateTime.now();

  void addMessage(ChatMessage message) {
    messages.add(message);
    updatedAt = DateTime.now();
  }
}

@HiveType(typeId: 4)
class ChatMessage extends HiveObject {
  @HiveField(0)
  late String role; // 'user' | 'assistant' | 'system'

  @HiveField(1)
  late String content;

  @HiveField(2)
  late DateTime timestamp;

  @HiveField(3)
  List<CommandBlock>? commandBlocks;

  ChatMessage();

  ChatMessage.create({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.commandBlocks,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isSystem => role == 'system';
}

@HiveType(typeId: 5)
class CommandBlock extends HiveObject {
  @HiveField(0)
  late String command;

  @HiveField(1)
  String? description;

  @HiveField(2)
  late bool dangerous;

  @HiveField(3)
  late String safetyLevel; // 'safe' | 'info' | 'warn' | 'blocked'

  @HiveField(4)
  String? output;

  CommandBlock();

  CommandBlock.create({
    required this.command,
    this.description,
    this.dangerous = false,
    this.safetyLevel = 'safe',
    this.output,
  });

  bool get isBlocked => safetyLevel == 'blocked';
  bool get isWarn => safetyLevel == 'warn';
  bool get isSafe => safetyLevel == 'safe';
  bool get hasOutput => output != null && output!.isNotEmpty;
}
