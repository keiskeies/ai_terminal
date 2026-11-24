import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'agent_logger.dart';
import 'daos.dart';
import '../models/agent_event.dart';
import '../models/conversation.dart';

/// 会话持久化服务
///
/// 设计要点：
/// - 每个 hostId（含 'local'）对应一个 project，可有多个会话
/// - 每个 project 同时只有一个 active 会话（用户切到该服务器时自动加载）
/// - 写盘策略：消息追加用 `ConversationsDao.upsert` 覆盖整个对象
/// - 节流：批量场景下用 `appendToActive` 累积，由调用方控制 flush 时机
/// - sync 读路径使用 ConversationsDao 内存缓存
class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  static const _uuid = Uuid();

  /// 单条 assistant 正文的持久化/UI 总上限。长任务会把多轮 ReAct 文本累积到
  /// 同一条消息中，仅限制 streaming buffer 仍会让 content 无限增长。
  /// 超限时保留尾部（最新结论与命令证据优先），UI 与写盘共用同一口径。
  static const int maxAssistantContentChars = 200000;

  static String capAssistantContent(String content) =>
      tailCap(content, maxAssistantContentChars);

  /// 按 UTF-16 单元保尾截断，但绝不把代理对劈成孤立 surrogate。
  /// UI 输出与 assistant 持久化统一使用此口径。
  static String tailCap(String text, int maxChars) {
    if (maxChars <= 0) return '';
    if (text.length <= maxChars) return text;
    var start = text.length - maxChars;
    if (start > 0 &&
        _isLowSurrogate(text.codeUnitAt(start)) &&
        _isHighSurrogate(text.codeUnitAt(start - 1))) {
      start++;
    }
    return text.substring(start);
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  /// 尚未落盘的会话：新建时只驻内存，写出第一条内容时才入库。
  /// 空白会话因此不会出现在历史列表，也不会在重启后残留。
  final Map<String, Conversation> _drafts = {};

  // ═══════════════════════════════════════════
  // 会话生命周期
  // ═══════════════════════════════════════════

  /// 创建新会话并标记为 active（同 project 其他会话自动设为 inactive）
  ///
  /// 新会话本身此时是空白的，只登记进内存缓存；第一条消息/摘要写出时才入库。
  Conversation createSession({
    required String hostId,
    String? title,
  }) {
    // 将同 project 的其他会话设为 inactive（同步更新缓存）
    for (final conv in ConversationsDao.cached) {
      if (conv.hostId == hostId && conv.isActive) {
        conv.isActive = false;
        // 未落盘的会话没有数据库行，upsert 只会把它提前写入
        if (!_drafts.containsKey(conv.id)) {
          ConversationsDao.upsert(conv).catchError((Object e) {
            agentLogger.warn(
                'ConvService', '切换 active 时保存旧会话失败 (convId=${conv.id}): $e');
          });
        }
      }
    }

    final conv = Conversation.create(
      id: _uuid.v4(),
      hostId: hostId,
      title: title ?? _defaultTitle(),
      titleSource: title != null
          ? Conversation.titleSourceUser
          : Conversation.titleSourceAuto,
    );
    ConversationsDao.cacheOnly(conv);
    _drafts[conv.id] = conv;
    return conv;
  }

  /// 按 id 取会话：先查未落盘会话，再查 DAO 缓存
  Conversation? _lookup(String conversationId) {
    final draft = _drafts[conversationId];
    if (draft != null) {
      // 缓存重载会把未落盘会话从 DAO 缓存里清掉，命中时补登记，避免写入丢失
      ConversationsDao.cacheOnly(draft);
      return draft;
    }
    return ConversationsDao.getCachedById(conversationId);
  }

  /// 公开的按 id 取会话（含未落盘草稿）。供 AI 命名等旁路特性读取会话，
  /// 避免它们直接触碰 DAO 而绕过草稿登记与写库串行化。
  Conversation? lookup(String conversationId) => _lookup(conversationId);

  /// 统一写盘入口：未落盘且仍空白的会话不入库
  Future<void> _persist(Conversation conv) async {
    // 写盘前沿统一收敛存量 assistant 正文，避免标题/日志等旁路写盘把超长内容
    // 再次带回数据库。调用方写入时也应使用同一 cap，保证 UI 与磁盘一致。
    for (final message in conv.messages) {
      if (message.isAssistant) {
        message.content = capAssistantContent(message.content);
      }
    }
    // 只有消息/摘要算内容：agent 日志跟着任务走，不足以让一条空对话留档
    final hasContent = !conv.isBlank;
    final isDraft = _drafts.containsKey(conv.id);
    if (isDraft && !hasContent) return;
    await ConversationsDao.upsert(conv);
    // 写入成功后才算正式会话；失败时保持草稿身份，历史列表依旧看不到它
    if (hasContent) _drafts.remove(conv.id);
  }

  String _defaultTitle() {
    final now = DateTime.now();
    return '会话 ${now.month}/${now.day} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  /// 获取指定 project 的当前 active 会话（没有则返回 null）
  Conversation? getActiveSession(String hostId) {
    try {
      return ConversationsDao.getCachedActiveByHost(hostId);
    } catch (e) {
      debugPrint('[ConversationService] getActiveSession 失败: $e');
      return null;
    }
  }

  /// 获取指定 project 的当前 active 会话，没有则自动创建
  Conversation getOrCreateActiveSession(String hostId) {
    final existing = getActiveSession(hostId);
    if (existing != null) return existing;
    return createSession(hostId: hostId);
  }

  /// 列出指定 project 的所有会话（按 updatedAt 倒序）
  ///
  /// 空白会话不属于历史记录，不列出（未落盘的草稿天然不在这里，
  /// 旧版本已经写进库的空白会话同样不再展示）。
  List<Conversation> listSessions(String hostId) {
    return ConversationsDao.getCachedByHost(hostId)
        .where((c) => !c.isBlank)
        .toList();
  }

  /// 切换 active 会话（同 project 其他会话设为 inactive）。
  /// 调用方必须 await 并处理失败，不能把持久化选择当成已完成。
  Future<void> setActive(String hostId, String conversationId) {
    return ConversationsDao.setActive(conversationId, hostId);
  }

  /// 重命名会话（用户手动）：锁定 titleSource 为 user，后续 AI 不再覆盖
  Future<void> rename(String conversationId, String title) async {
    final conv = _lookup(conversationId);
    if (conv == null) return;
    conv.title = title;
    conv.titleSource = Conversation.titleSourceUser;
    await _persist(conv);
  }

  /// AI 自动命名：仅当会话仍为占位标题（titleSource == auto）时写入，
  /// 否则（用户改过名 / 已有 AI 标题）直接跳过。不改变 updatedAt，
  /// 避免历史列表按时间排序时因改名跳动。
  Future<void> applyAiTitle(String conversationId, String title) async {
    final conv = _lookup(conversationId);
    if (conv == null) return;
    if (conv.titleSource != Conversation.titleSourceAuto) return;
    conv.title = title;
    conv.titleSource = Conversation.titleSourceAi;
    await _persist(conv);
  }

  /// 删除会话
  Future<void> delete(String conversationId) async {
    // 删除成功前保留草稿与待刷盘状态；DB 失败时完整恢复，后续可重试。
    final hadPendingFlush = _flushTimers.containsKey(conversationId);
    _flushTimers[conversationId]?.cancel();
    _flushTimers.remove(conversationId);
    final conv = _lookup(conversationId);
    conv?.bumpMutationEpoch();
    final draft = _drafts.remove(conversationId);
    try {
      await ConversationsDao.delete(conversationId);
    } catch (_) {
      // 无论草稿还是已持久化会话，删除失败都必须完整恢复缓存与延迟刷盘。
      if (conv != null) {
        if (draft != null) _drafts[conversationId] = draft;
        ConversationsDao.cacheOnly(conv);
        if (hadPendingFlush) _scheduleFlush(conv);
      }
      rethrow;
    }
  }

  // ═══════════════════════════════════════════
  // 消息追加
  // ═══════════════════════════════════════════

  /// 追加一条消息到 active 会话（自动创建会话）
  Future<Conversation> appendMessage(
    String hostId, {
    required String role,
    required String content,
    String? command,
    bool? commandSuccess,
    String? conversationId,
  }) async {
    final conv = conversationId == null
        ? getOrCreateActiveSession(hostId)
        : _lookup(conversationId);
    if (conv == null) {
      throw StateError('conversation not found: $conversationId');
    }
    final isFirstUserMessage =
        role == 'user' && !conv.messages.any((m) => m.isUser);
    final appended = ConvMessage.create(
      role: role,
      content: role == 'assistant' ? capAssistantContent(content) : content,
      command: command,
      commandSuccess: commandSuccess,
    );
    conv.addMessage(appended);
    if (isFirstUserMessage) conv.adoptTitleFromFirstMessage(content);
    try {
      await _persist(conv);
    } catch (e) {
      // R8: 持久化失败不可静默吞掉 — 只回滚本次追加的对象身份。
      // await 期间可能有并发追加，removeLast 会误删别人的消息。
      conv.messages.removeWhere((m) => identical(m, appended));
      rethrow;
    }
    debugPrint(
        '[ConversationService] appendMessage: hostId=$hostId role=$role contentLength=${content.length} messages=${conv.messages.length}');
    return conv;
  }

  /// 原子追加 user + assistant 消息对（消除两次 save 之间的崩溃窗口）
  /// 防止崩溃后留下孤儿 user 消息（有用户提问但无 AI 回复占位）
  ///
  /// [conversationId] 指定时写入该会话，而不是 host 当前的 active 会话。
  /// 多 tab 并行场景必须走这条路径：另一个 tab 新建会话会改变 host 的
  /// active 会话，但正在执行的任务仍应写回自己开始时所在的会话。
  Future<Conversation> appendMessagePair(
    String hostId, {
    required String userContent,
    required String assistantContent,
    String? conversationId,
  }) async {
    final conv = conversationId == null
        ? getOrCreateActiveSession(hostId)
        : _lookup(conversationId);
    if (conv == null) {
      throw StateError('conversation not found: $conversationId');
    }
    final isFirstUserMessage = !conv.messages.any((m) => m.isUser);
    final userMessage = ConvMessage.create(role: 'user', content: userContent);
    final assistantMessage = ConvMessage.create(
      role: 'assistant',
      content: capAssistantContent(assistantContent),
    );
    conv.addMessage(userMessage);
    conv.addMessage(assistantMessage);
    if (isFirstUserMessage) conv.adoptTitleFromFirstMessage(userContent);
    try {
      await _persist(conv);
    } catch (e) {
      // 回滚本次追加的两个对象身份。await 期间其他任务可能继续 append，
      // 不能按末尾两条 removeRange，否则会删掉并发追加的成功消息。
      conv.messages.removeWhere(
          (m) => identical(m, userMessage) || identical(m, assistantMessage));
      rethrow;
    }
    return conv;
  }

  /// 更新指定会话的最后一条 assistant 消息内容（用于流式结束后回写完整内容）
  Future<void> updateLastAssistantContent(
    String hostId,
    String content, {
    List<AgentEvent>? events,
    String? conversationId,
  }) async {
    final conv = conversationId == null
        ? getActiveSession(hostId)
        : _lookup(conversationId);
    if (conv == null || conv.messages.isEmpty) return;
    final lastIdx = conv.messages.length - 1;
    if (conv.messages[lastIdx].role != 'assistant') return;
    final boundedContent = capAssistantContent(content);
    conv.messages[lastIdx].content = boundedContent;
    if (events != null) {
      conv.messages[lastIdx].events = events;
    }
    conv.updatedAt = DateTime.now();
    try {
      await _persist(conv);
    } catch (e) {
      debugPrint('[ConversationService] updateLastAssistantContent 保存失败 '
          '(hostId=$hostId, conversationId=${conv.id}): $e');
      rethrow;
    }
  }

  /// 追加 Agent 日志到 active 会话
  Future<void> appendAgentLog(
    String hostId, {
    required String level,
    required String tag,
    required String message,
    String? conversationId,
  }) async {
    final conv = conversationId == null
        ? getActiveSession(hostId)
        : _lookup(conversationId);
    if (conv == null) return;
    conv.addAgentLog(ConvAgentLog.create(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    ));
    // Agent 日志高频写入，使用 lazy save（不立即刷盘），由 flush 触发
    _scheduleFlush(conv);
  }

  /// 累积 Agent 日志写入请求，5 秒批量刷一次盘（避免每条日志都 IO）
  final Map<String, Timer> _flushTimers = {};

  void _scheduleFlush(Conversation conv) {
    _flushTimers[conv.id]?.cancel();
    _flushTimers[conv.id] = Timer(const Duration(seconds: 5), () {
      _flushTimers.remove(conv.id);
      // await upsert 确保 agent 日志落盘；fire-and-forget 会在 app 退出时丢失
      _persist(conv).catchError((e) {
        // R8: 日志刷盘失败不可静默吞掉，warn 级记录便于排查
        agentLogger.warn(
            'ConvService', 'agent 日志延迟保存失败 (convId=${conv.id}): $e');
      });
    });
  }

  /// 强制刷盘（应用退出 / 切换会话时调用）
  Future<void> flush(String conversationId) async {
    _flushTimers[conversationId]?.cancel();
    _flushTimers.remove(conversationId);
    final conv = _lookup(conversationId);
    if (conv != null) await _persist(conv);
  }

  Future<void> flushAll() async {
    for (final timer in _flushTimers.values) {
      timer.cancel();
    }
    _flushTimers.clear();
    // 每个 upsert 独立 try/catch：单个会话保存失败不影响其他会话
    for (final conv in ConversationsDao.cached) {
      try {
        await _persist(conv);
      } catch (e) {
        // R8: app 退出时刷盘失败不可静默吞掉，warn 级记录便于事后排查
        agentLogger.warn('ConvService', 'flushAll: 会话 ${conv.id} 保存失败: $e');
      }
    }
  }

  /// 测试隔离：取消全局单例的日志刷盘 Timer 并清除未落盘草稿。
  @visibleForTesting
  void resetForTesting() {
    for (final timer in _flushTimers.values) {
      timer.cancel();
    }
    _flushTimers.clear();
    _drafts.clear();
  }

  // ═══════════════════════════════════════════
  // 记忆压缩
  // ═══════════════════════════════════════════

  /// 合并摘要最大字符数：超出时截断旧摘要尾部，保留新摘要完整
  static const int _maxSummaryChars = 4000;

  /// 写入压缩摘要并物理删除已摘要的旧消息
  /// [deleteCount] 需要从 conv.messages 头部删除的消息条数（由 compact 计算并传入）
  /// 删除后 summarizedUpToIndex 重置为 0，后续新消息从 0 开始追加
  Future<void> applySummary(String conversationId, String summary,
      {int deleteCount = 0}) async {
    final conv = _lookup(conversationId);
    if (conv == null) return;
    // 如果已有旧摘要，合并（旧摘要 + 新摘要）
    if (conv.summary != null && conv.summary!.isNotEmpty) {
      final merged = '${conv.summary}\n\n---\n\n$summary';
      // 长对话场景下 summary 无限增长会撑爆 AI 上下文
      // 超出上限时截断旧摘要（保留尾部=较新的摘要），新摘要始终完整保留
      if (merged.length > _maxSummaryChars) {
        final keepOld = _maxSummaryChars - summary.length - 5;
        if (keepOld > 0) {
          conv.summary =
              '...${conv.summary!.substring(conv.summary!.length - keepOld)}\n\n---\n\n$summary';
        } else {
          conv.summary = summary.length > _maxSummaryChars
              ? summary.substring(summary.length - _maxSummaryChars)
              : summary;
        }
      } else {
        conv.summary = merged;
      }
    } else {
      conv.summary = summary;
    }
    // 物理删除已摘要的旧消息，防止小白用户长对话场景下 conv.messages 无限增长
    if (deleteCount > 0 && deleteCount <= conv.messages.length) {
      conv.messages.removeRange(0, deleteCount);
    }
    conv.summarizedUpToIndex = 0;
    conv.updatedAt = DateTime.now();
    conv.bumpMutationEpoch();
    await _persist(conv);
  }

  /// 清空会话（删除所有消息和摘要，但保留会话本身）。
  /// mutationEpoch 必须在首个 await 前递增，使进行中的压缩立即失效。
  Future<void> clearMessages(String conversationId) async {
    final conv = _lookup(conversationId);
    if (conv == null) return;
    conv.bumpMutationEpoch();
    conv.messages.clear();
    conv.agentLogs.clear();
    conv.summary = null;
    conv.rollingSummary = null;
    conv.summarizedUpToIndex = 0;
    conv.updatedAt = DateTime.now();
    await _persist(conv);
  }
}
