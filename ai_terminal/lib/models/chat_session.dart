class ChatSession {
  late String id;

  String? hostId;

  late List<ChatMessage> messages;

  late DateTime createdAt;

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

class ChatMessage {
  late String role; // 'user' | 'assistant' | 'system'

  late String content;

  late DateTime timestamp;

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

class CommandBlock {
  late String command;

  String? description;

  late bool dangerous;

  late String safetyLevel; // 'safe' | 'info' | 'warn' | 'blocked'

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
