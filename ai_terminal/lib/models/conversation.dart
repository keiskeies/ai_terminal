import 'agent_event.dart';

/// 会话消息（与具体 AI 模式无关，统一存储用户/AI 对话）
class ConvMessage {
  late String role; // 'user' | 'assistant' | 'system'

  late String content;

  late DateTime timestamp;

  String? command; // 若该消息对应一条执行的命令，记录命令原文

  bool? commandSuccess; // 命令执行是否成功

  List<AgentEvent>? events; // 结构化事件列表（含命令执行结果）

  /// 压缩后的摘要内容：传给 AI 用，为空时回退到 content
  /// UI 展示始终用 content（原文），AI 读取用 summary ?? content
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
class ConvAgentLog {
  late DateTime timestamp;

  late String level; // 'DEBUG' | 'INFO' | 'WARN' | 'ERROR'

  late String tag;

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
class Conversation {
  late String id;

  late String hostId; // 服务器 id 或 'local'

  late String title;

  late List<ConvMessage> messages;

  late List<ConvAgentLog> agentLogs;

  /// 早期对话的 AI 摘要（旧机制，新压缩改为逐条写入 ConvMessage.summary）
  /// 保留字段避免反序列化失败，新逻辑不再使用
  String? summary;

  /// 已纳入 summary 的消息下标（旧机制，新压缩不再使用）
  int summarizedUpToIndex = 0;

  late DateTime createdAt;

  late DateTime updatedAt;

  /// 是否为当前活跃会话（每个 hostId 只有一个 active）
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
