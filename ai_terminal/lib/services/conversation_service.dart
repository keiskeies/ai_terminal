import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
import '../core/hive_init.dart';
import '../models/agent_event.dart';
import '../models/conversation.dart';

/// 会话持久化服务
///
/// 设计要点：
/// - 每个 hostId（含 'local'）对应一个 project，可有多个会话
/// - 每个 project 同时只有一个 active 会话（用户切到该服务器时自动加载）
/// - 写盘策略：消息追加用 `box.put` 覆盖整个对象（Hive 二进制增量编码，单条消息写入开销很小）
/// - 节流：批量场景下用 `appendToActive` 累积，由调用方控制 flush 时机
class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  static const _uuid = Uuid();

  Box<Conversation> get _box => HiveInit.conversationsBox;

  // ═══════════════════════════════════════════
  // 会话生命周期
  // ═══════════════════════════════════════════

  /// 创建新会话并标记为 active（同 project 其他会话自动设为 inactive）
  Conversation createSession({
    required String hostId,
    String? title,
  }) {
    // 将同 project 的其他会话设为 inactive
    for (final conv in _box.values.toList()) {
      if (conv.hostId == hostId && conv.isActive) {
        conv.isActive = false;
        conv.save();
      }
    }

    final conv = Conversation.create(
      id: _uuid.v4(),
      hostId: hostId,
      title: title ?? _defaultTitle(),
    );
    _box.put(conv.id, conv);
    return conv;
  }

  String _defaultTitle() {
    final now = DateTime.now();
    return '会话 ${now.month}/${now.day} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  /// 获取指定 project 的当前 active 会话（没有则返回 null）
  Conversation? getActiveSession(String hostId) {
    try {
      for (final conv in _box.values) {
        if (conv.hostId == hostId && conv.isActive) return conv;
      }
      return null;
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
    final list = _box.values.where((c) => c.hostId == hostId).toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// 切换 active 会话（同 project 其他会话设为 inactive）
  void setActive(String hostId, String conversationId) {
    for (final conv in _box.values.toList()) {
      if (conv.hostId == hostId) {
        final shouldActive = conv.id == conversationId;
        if (conv.isActive != shouldActive) {
          conv.isActive = shouldActive;
          conv.save();
        }
      }
    }
  }

  /// 重命名会话
  Future<void> rename(String conversationId, String title) async {
    final conv = _box.get(conversationId);
    if (conv == null) return;
    conv.title = title;
    await conv.save();
  }

  /// 删除会话
  Future<void> delete(String conversationId) async {
    await _box.delete(conversationId);
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
    await conv.save();
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
    await conv.save();
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
      conv.save();
    });
  }

  /// 强制刷盘（应用退出 / 切换会话时调用）
  Future<void> flush(String conversationId) async {
    _flushTimers[conversationId]?.cancel();
    _flushTimers.remove(conversationId);
    final conv = _box.get(conversationId);
    if (conv != null) await conv.save();
  }

  Future<void> flushAll() async {
    for (final timer in _flushTimers.values) {
      timer.cancel();
    }
    _flushTimers.clear();
    for (final conv in _box.values) {
      await conv.save();
    }
  }

  // ═══════════════════════════════════════════
  // 记忆压缩
  // ═══════════════════════════════════════════

  /// 写入压缩摘要并推进 summarizedUpToIndex
  Future<void> applySummary(String conversationId, String summary) async {
    final conv = _box.get(conversationId);
    if (conv == null) return;
    // 如果已有旧摘要，合并（旧摘要 + 新摘要）
    if (conv.summary != null && conv.summary!.isNotEmpty) {
      conv.summary = '${conv.summary}\n\n---\n\n$summary';
    } else {
      conv.summary = summary;
    }
    conv.summarizedUpToIndex = conv.messages.length;
    conv.updatedAt = DateTime.now();
    await conv.save();
  }

  /// 清空会话（删除所有消息和摘要，但保留会话本身）
  Future<void> clearMessages(String conversationId) async {
    final conv = _box.get(conversationId);
    if (conv == null) return;
    conv.messages.clear();
    conv.agentLogs.clear();
    conv.summary = null;
    conv.summarizedUpToIndex = 0;
    conv.updatedAt = DateTime.now();
    await conv.save();
  }
}
