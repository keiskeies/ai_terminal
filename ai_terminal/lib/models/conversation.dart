import 'dart:convert';
import '../utils/token_estimator.dart';
import 'agent_event.dart';
import 'chat_session.dart';

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

  /// 已被会话级滚动摘要（Conversation.rollingSummary）吸收：
  /// 重建 AI 历史时整条跳过，原文仅留档展示。旧逐条 summary 机制的消息
  /// 不带此标记，仍按 effectiveContent 参与重建（向后兼容）。
  bool rolledUp = false;

  ConvMessage();

  ConvMessage.create({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.command,
    this.commandSuccess,
    this.events,
    this.summary,
    this.rolledUp = false,
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

  /// Agent 日志延迟解析：启动时只保留原始 JSON，真正读取（追加/清空/写回）
  /// 时才解码，避免所有历史会话的日志在启动阶段全部展开。
  List<ConvAgentLog>? _agentLogs;
  String? _agentLogsJson;

  List<ConvAgentLog> get agentLogs {
    return _agentLogs ??= _decodeAgentLogs(_agentLogsJson);
  }

  set agentLogs(List<ConvAgentLog> logs) {
    _agentLogs = logs;
    _agentLogsJson = null;
  }

  /// 未解码时的原始 JSON（DAO 写回可直接复用，避免无意义的编解码）
  String? get rawAgentLogsJson => _agentLogs == null ? _agentLogsJson : null;

  void setAgentLogsJson(String? json) {
    _agentLogsJson = json;
    _agentLogs = null;
  }

  static List<ConvAgentLog> _decodeAgentLogs(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final list = jsonDecode(json);
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((e) => ConvAgentLog()
            ..timestamp = DateTime.tryParse(e['timestamp'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0)
            ..level = e['level'] as String? ?? 'INFO'
            ..tag = e['tag'] as String? ?? ''
            ..message = e['message'] as String? ?? '')
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 早期对话的 AI 摘要（普通聊天模式的压缩机制，conversation_service 维护）
  /// Agent 模式改用下方 rollingSummary，两者互不干扰
  String? summary;

  /// Agent 模式的会话级滚动摘要（含【关键事实】pinned 段）。
  /// 每次压缩把早期消息整体并入此摘要，被吸收的消息标记 rolledUp。
  String? rollingSummary;

  /// 已纳入 summary 的消息下标（旧机制，新压缩不再使用）
  int summarizedUpToIndex = 0;

  late DateTime createdAt;

  late DateTime updatedAt;

  /// 是否为当前活跃会话（每个 hostId 只有一个 active）
  bool isActive = false;

  /// 创建时的默认日期标题形如「会话 11/4 02:34」；仍匹配它才允许自动改写
  static final RegExp _autoTitlePattern =
      RegExp(r'^会话\s+\d{1,2}/\d{1,2}\s+\d{1,2}:\d{2}$');

  static const int autoTitleMaxChars = 20;

  bool get hasAutoTitle => _autoTitlePattern.hasMatch(title.trim());

  /// 还没有写过任何消息或摘要：落盘只会在历史里留下一条空对话
  bool get isBlank => messages.isEmpty && (summary == null || summary!.isEmpty);

  /// 会话列表展示标题：仍是日期默认标题时，回退到首条用户消息前 20 字
  String get displayTitle {
    final stored = title.trim();
    if (!hasAutoTitle) return stored.isEmpty ? '会话' : stored;
    final snippet = _firstUserSnippet;
    return snippet.isEmpty ? stored : snippet;
  }

  String get _firstUserSnippet {
    for (final m in messages) {
      if (!m.isUser) continue;
      final snippet = snippetFromUserMessage(m.content);
      if (snippet.isNotEmpty) return snippet;
    }
    return '';
  }

  /// 首条用户消息到达时，把日期默认标题替换成内容摘要。
  /// 用户手动改过标题（不再匹配默认格式）时不覆盖。
  void adoptTitleFromFirstMessage(String content) {
    if (!hasAutoTitle) return;
    final snippet = snippetFromUserMessage(content);
    if (snippet.isNotEmpty) title = snippet;
  }

  /// 首行 + 空白折叠 + 最多 20 个字符（按 rune 截断，避免劈开 emoji）
  static String snippetFromUserMessage(String content) {
    final firstLine = content
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    final normalized = firstLine.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return '';
    final runes = normalized.runes.toList(growable: false);
    if (runes.length <= autoTitleMaxChars) return normalized;
    return '${String.fromCharCodes(runes.take(autoTitleMaxChars))}…';
  }

  Conversation();

  Conversation.create({
    required this.id,
    required this.hostId,
    required this.title,
    List<ConvMessage>? messages,
    List<ConvAgentLog>? agentLogs,
  })  : messages = messages ?? [],
        summarizedUpToIndex = 0,
        isActive = true,
        createdAt = DateTime.now(),
        updatedAt = DateTime.now() {
    this.agentLogs = agentLogs ?? [];
  }

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

  /// 重建传给 AI 的对话历史（压缩后与恢复会话共用同一口径）：
  /// 滚动摘要作为首条消息注入 → 跳过已被吸收的消息 → 其余用 effectiveContent
  /// （兼容旧逐条 summary）。system 消息不进 AI 历史（引擎另行构造 system prompt）。
  List<ChatMessage> buildAiHistory() {
    final msgs = <ChatMessage>[];
    final rolling = rollingSummary;
    if (rolling != null && rolling.isNotEmpty) {
      msgs.add(ChatMessage.create(
        role: 'user',
        content: '【早期对话摘要】\n$rolling',
      ));
    }
    for (final m in messages) {
      if (m.role == 'system' || m.rolledUp) continue;
      msgs.add(ChatMessage.create(role: m.role, content: m.effectiveContent));
    }
    return msgs;
  }

  /// AI 历史的有效 token 估算（压缩阈值判断用，与 buildAiHistory 同口径）
  int get totalTokens => TokenEstimator.estimateHistory(buildAiHistory());

  /// 是否需要压缩：未压缩轮次或有效 token 任一超阈值。
  /// token 口径消除中英文密度差（旧字符阈值对中文偏松 2-3 倍）。
  bool needsCompaction({
    required int tokenThreshold,
    required int roundThreshold,
  }) {
    final unsummarized = messages.where((m) =>
        m.role != 'system' &&
        !m.rolledUp &&
        (m.summary == null || m.summary!.isEmpty));
    final rounds = unsummarized.length ~/ 2;
    return rounds >= roundThreshold || totalTokens >= tokenThreshold;
  }
}
