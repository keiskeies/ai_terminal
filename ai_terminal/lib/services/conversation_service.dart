import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
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

  // ═══════════════════════════════════════════
  // 会话生命周期
  // ═══════════════════════════════════════════

  /// 创建新会话并标记为 active（同 project 其他会话自动设为 inactive）
  Conversation createSession({
    required String hostId,
    String? title,
  }) {
    // 将同 project 的其他会话设为 inactive（同步更新缓存）
    for (final conv in ConversationsDao.cached) {
      if (conv.hostId == hostId && conv.isActive) {
        conv.isActive = false;
        ConversationsDao.upsert(conv); // fire-and-forget 写库
      }
    }

    final conv = Conversation.create(
      id: _uuid.v4(),
      hostId: hostId,
      title: title ?? _defaultTitle(),
    );
    ConversationsDao.upsert(conv); // fire-and-forget 写库 + 同步更新缓存
    return conv;
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
  List<Conversation> listSessions(String hostId) {
    return ConversationsDao.getCachedByHost(hostId);
  }

  /// 切换 active 会话（同 project 其他会话设为 inactive）
  void setActive(String hostId, String conversationId) {
    ConversationsDao.setActive(conversationId, hostId); // fire-and-forget 写库 + 同步更新缓存
  }

  /// 重命名会话
  Future<void> rename(String conversationId, String title) async {
    final conv = ConversationsDao.getCachedById(conversationId);
    if (conv == null) return;
    conv.title = title;
    await ConversationsDao.upsert(conv);
  }

  /// 删除会话
  Future<void> delete(String conversationId) async {
    // 取消该会话的待刷盘 Timer，防止已删除会话被 Timer 复活
    _flushTimers[conversationId]?.cancel();
    _flushTimers.remove(conversationId);
    await ConversationsDao.delete(conversationId);
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
  }) async {
    final conv = getOrCreateActiveSession(hostId);
    conv.addMessage(ConvMessage.create(
      role: role,
      content: content,
      command: command,
      commandSuccess: commandSuccess,
    ));
    try {
      await ConversationsDao.upsert(conv);
    } catch (e) {
      // R8: 持久化失败不可静默吞掉 — 回滚内存中的消息追加，保持内存与磁盘一致
      if (conv.messages.isNotEmpty) conv.messages.removeLast();
      rethrow;
    }
    debugPrint('[ConversationService] appendMessage: hostId=$hostId role=$role contentLength=${content.length} messages=${conv.messages.length}');
    return conv;
  }

  /// 原子追加 user + assistant 消息对（消除两次 save 之间的崩溃窗口）
  /// 防止崩溃后留下孤儿 user 消息（有用户提问但无 AI 回复占位）
  Future<Conversation> appendMessagePair(
    String hostId, {
    required String userContent,
    required String assistantContent,
  }) async {
    final conv = getOrCreateActiveSession(hostId);
    conv.addMessage(ConvMessage.create(role: 'user', content: userContent));
    conv.addMessage(ConvMessage.create(role: 'assistant', content: assistantContent));
    try {
      await ConversationsDao.upsert(conv);
    } catch (e) {
      // 回滚两条消息追加
      if (conv.messages.length >= 2) conv.messages.removeRange(conv.messages.length - 2, conv.messages.length);
      rethrow;
    }
    return conv;
  }

  /// 更新 active 会话的最后一条 assistant 消息内容（用于流式结束后回写完整内容）
  Future<void> updateLastAssistantContent(
    String hostId,
    String content, {
    List<AgentEvent>? events,
  }) async {
    final conv = getActiveSession(hostId);
    if (conv == null || conv.messages.isEmpty) return;
    final lastIdx = conv.messages.length - 1;
    if (conv.messages[lastIdx].role != 'assistant') return;
    conv.messages[lastIdx].content = content;
    if (events != null) {
      conv.messages[lastIdx].events = events;
    }
    conv.updatedAt = DateTime.now();
    try {
      await ConversationsDao.upsert(conv);
    } catch (e) {
      debugPrint('[ConversationService] updateLastAssistantContent 保存失败 (hostId=$hostId): $e');
      rethrow;
    }
  }

  /// 追加 Agent 日志到 active 会话
  Future<void> appendAgentLog(
    String hostId, {
    required String level,
    required String tag,
    required String message,
  }) async {
    final conv = getActiveSession(hostId);
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
      ConversationsDao.upsert(conv).catchError((e) {
        debugPrint('[ConversationService] agent 日志延迟保存失败: $e');
      });
    });
  }

  /// 强制刷盘（应用退出 / 切换会话时调用）
  Future<void> flush(String conversationId) async {
    _flushTimers[conversationId]?.cancel();
    _flushTimers.remove(conversationId);
    final conv = ConversationsDao.getCachedById(conversationId);
    if (conv != null) await ConversationsDao.upsert(conv);
  }

  Future<void> flushAll() async {
    for (final timer in _flushTimers.values) {
      timer.cancel();
    }
    _flushTimers.clear();
    // 每个 upsert 独立 try/catch：单个会话保存失败不影响其他会话
    for (final conv in ConversationsDao.cached) {
      try {
        await ConversationsDao.upsert(conv);
      } catch (e) {
        debugPrint('[ConversationService] flushAll: 会话 ${conv.id} 保存失败: $e');
      }
    }
  }

  // ═══════════════════════════════════════════
  // 记忆压缩
  // ═══════════════════════════════════════════

  /// 合并摘要最大字符数：超出时截断旧摘要尾部，保留新摘要完整
  static const int _maxSummaryChars = 4000;

  /// 写入压缩摘要并物理删除已摘要的旧消息
  /// [deleteCount] 需要从 conv.messages 头部删除的消息条数（由 compact 计算并传入）
  /// 删除后 summarizedUpToIndex 重置为 0，后续新消息从 0 开始追加
  Future<void> applySummary(String conversationId, String summary, {int deleteCount = 0}) async {
    final conv = ConversationsDao.getCachedById(conversationId);
    if (conv == null) return;
    // 如果已有旧摘要，合并（旧摘要 + 新摘要）
    if (conv.summary != null && conv.summary!.isNotEmpty) {
      final merged = '${conv.summary}\n\n---\n\n$summary';
      // 长对话场景下 summary 无限增长会撑爆 AI 上下文
      // 超出上限时截断旧摘要（保留尾部=较新的摘要），新摘要始终完整保留
      if (merged.length > _maxSummaryChars) {
        final keepOld = _maxSummaryChars - summary.length - 5;
        if (keepOld > 0) {
          conv.summary = '...${conv.summary!.substring(conv.summary!.length - keepOld)}\n\n---\n\n$summary';
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
    await ConversationsDao.upsert(conv);
  }

  /// 清空会话（删除所有消息和摘要，但保留会话本身）
  Future<void> clearMessages(String conversationId) async {
    final conv = ConversationsDao.getCachedById(conversationId);
    if (conv == null) return;
    conv.messages.clear();
    conv.agentLogs.clear();
    conv.summary = null;
    conv.summarizedUpToIndex = 0;
    conv.updatedAt = DateTime.now();
    await ConversationsDao.upsert(conv);
  }
}
