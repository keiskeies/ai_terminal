import 'package:hive/hive.dart';

import 'agent_event.dart';

part 'conversation.g.dart';

/// 会话消息（与具体 AI 模式无关，统一存储用户/AI 对话）
@HiveType(typeId: 10)
class ConvMessage extends HiveObject {
  @HiveField(0)
  late String role; // 'user' | 'assistant' | 'system'

  @HiveField(1)
  late String content;

  @HiveField(2)
  late DateTime timestamp;

  @HiveField(3)
  String? command; // 若该消息对应一条执行的命令，记录命令原文

  @HiveField(4)
  bool? commandSuccess; // 命令执行是否成功

  @HiveField(5)
  List<AgentEvent>? events; // 结构化事件列表（含命令执行结果）

  /// 压缩后的摘要内容：传给 AI 用，为空时回退到 content
  /// UI 展示始终用 content（原文），AI 读取用 summary ?? content
  @HiveField(6)
  String? summary;

  ConvMessage();

  ConvMessage.create({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.command,
    this.commandSuccess,
    this.events,
    this.summary,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  /// 传给 AI 的有效内容：有压缩摘要用摘要，否则用原文
  String get effectiveContent => (summary != null && summary!.isNotEmpty) ? summary! : content;
}

/// Agent 日志条目（与会话关联存储）
@HiveType(typeId: 11)
class ConvAgentLog extends HiveObject {
  @HiveField(0)
  late DateTime timestamp;

  @HiveField(1)
  late String level; // 'DEBUG' | 'INFO' | 'WARN' | 'ERROR'

  @HiveField(2)
  late String tag;

  @HiveField(3)
  late String message;

  ConvAgentLog();

  ConvAgentLog.create({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });
}

/// 会话（归属于某个 hostId project，含压缩摘要）
@HiveType(typeId: 12)
class Conversation extends HiveObject {
  @HiveField(0)
  late String id;

  @HiveField(1)
  late String hostId; // 服务器 id 或 'local'

  @HiveField(2)
  late String title;

  @HiveField(3)
  late List<ConvMessage> messages;

  @HiveField(4)
  late List<ConvAgentLog> agentLogs;

  /// 早期对话的 AI 摘要（旧机制，新压缩改为逐条写入 ConvMessage.summary）
  /// 保留字段避免 Hive 反序列化失败，新逻辑不再使用
  @HiveField(5)
  String? summary;

  /// 已纳入 summary 的消息下标（旧机制，新压缩不再使用）
  @HiveField(6)
  int summarizedUpToIndex = 0;

  @HiveField(7)
  late DateTime createdAt;

  @HiveField(8)
  late DateTime updatedAt;

  /// 是否为当前活跃会话（每个 hostId 只有一个 active）
  @HiveField(9)
  bool isActive = false;

  Conversation();

  Conversation.create({
    required this.id,
    required this.hostId,
    required this.title,
    List<ConvMessage>? messages,
    List<ConvAgentLog>? agentLogs,
  })  : messages = messages ?? [],
        agentLogs = agentLogs ?? [],
        summarizedUpToIndex = 0,
        isActive = true,
        createdAt = DateTime.now(),
        updatedAt = DateTime.now();

  /// 添加消息并更新时间戳
  void addMessage(ConvMessage msg) {
    messages.add(msg);
    updatedAt = DateTime.now();
  }

  /// 添加 Agent 日志（不更新 updatedAt，避免频繁写盘）
  void addAgentLog(ConvAgentLog log) {
    agentLogs.add(log);
    // 限制单个会话日志条数，避免无限增长
    if (agentLogs.length > 2000) {
      agentLogs.removeRange(0, agentLogs.length - 2000);
    }
  }

  /// 估算消息总字符数（用于压缩阈值判断，基于 effectiveContent）
  int get totalChars => messages.fold<int>(0, (sum, m) => sum + m.effectiveContent.length);
}
