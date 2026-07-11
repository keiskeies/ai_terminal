import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../core/db_init.dart';
import '../models/host_config.dart';
import '../models/ai_model_config.dart';
import '../models/chat_session.dart';
import '../models/command_snippet.dart';
import '../models/conversation.dart';
import '../models/agent_event.dart';
import '../models/change_record.dart';
import '../models/runbook.dart';

// ═══════════════════════════════════════════════════════════
// HostsDao
// ═══════════════════════════════════════════════════════════
class HostsDao {
  // 内存缓存：启动时加载，sync 读路径使用（如 MultiHostExecutor）
  static List<HostConfig> _cache = [];

  static Future<void> loadCache() async {
    _cache = await getAll();
  }

  /// 同步获取缓存中所有主机
  static List<HostConfig> get cached => _cache;

  /// 同步按 id 查找（从缓存）
  static HostConfig? getCachedById(String id) {
    for (final h in _cache) {
      if (h.id == id) return h;
    }
    return null;
  }

  static Future<List<HostConfig>> getAll() async {
    final rows = await DbInit.db.query('hosts', orderBy: 'createdAt ASC');
    return rows.map(_fromRow).toList();
  }

  static Future<HostConfig?> getById(String id) async {
    final rows = await DbInit.db.query('hosts', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static Future<void> upsert(HostConfig h) async {
    final idx = _cache.indexWhere((e) => e.id == h.id);
    if (idx >= 0) { _cache[idx] = h; } else { _cache.add(h); }
    await DbInit.db.insert('hosts', _toRow(h),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> delete(String id) async {
    _cache.removeWhere((e) => e.id == id);
    await DbInit.db.delete('hosts', where: 'id = ?', whereArgs: [id]);
  }

  /// 清空所有主机（同步清缓存 + 异步清表）
  static Future<void> clearAll() async {
    _cache = [];
    await DbInit.db.delete('hosts');
  }

  static Map<String, dynamic> _toRow(HostConfig h) => {
    'id': h.id, 'name': h.name, 'host': h.host, 'port': h.port,
    'username': h.username, 'authType': h.authType,
    'group': h.group, 'tagColor': h.tagColor,
    'jumpHost': h.jumpHost, 'jumpPort': h.jumpPort,
    'jumpUsername': h.jumpUsername, 'jumpAuthType': h.jumpAuthType,
    'timeout': h.timeout, 'encoding': h.encoding,
    'createdAt': h.createdAt.millisecondsSinceEpoch,
    'lastConnectedAt': h.lastConnectedAt?.millisecondsSinceEpoch,
    'lastStatus': h.lastStatus,
  };

  static HostConfig _fromRow(Map<String, dynamic> r) {
    final h = HostConfig()
      ..id = r['id'] as String
      ..name = r['name'] as String
      ..host = r['host'] as String
      ..port = r['port'] as int
      ..username = r['username'] as String
      ..authType = r['authType'] as String
      ..group = r['group'] as String? ?? '默认'
      ..tagColor = r['tagColor'] as String?
      ..jumpHost = r['jumpHost'] as String?
      ..jumpPort = r['jumpPort'] as int? ?? 22
      ..jumpUsername = r['jumpUsername'] as String?
      ..jumpAuthType = r['jumpAuthType'] as String?
      ..timeout = r['timeout'] as int? ?? 30
      ..encoding = r['encoding'] as String? ?? 'utf-8'
      ..createdAt = DateTime.fromMillisecondsSinceEpoch(r['createdAt'] as int)
      ..lastConnectedAt = r['lastConnectedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(r['lastConnectedAt'] as int)
          : null
      ..lastStatus = r['lastStatus'] as String?;
    return h;
  }
}

// ═══════════════════════════════════════════════════════════
// AIModelsDao
// ═══════════════════════════════════════════════════════════
class AIModelsDao {
  // 内存缓存：启动时加载，sync 读路径使用
  static List<AIModelConfig> _cache = [];

  static Future<void> loadCache() async {
    _cache = await getAll();
  }

  /// 同步获取缓存中所有模型
  static List<AIModelConfig> get cached => _cache;

  /// 同步按 id 查找（从缓存）
  static AIModelConfig? getCachedById(String id) {
    for (final m in _cache) {
      if (m.id == id) return m;
    }
    return null;
  }

  static Future<List<AIModelConfig>> getAll() async {
    final rows = await DbInit.db.query('ai_models', orderBy: 'name ASC');
    return rows.map(_fromRow).toList();
  }

  static Future<AIModelConfig?> getById(String id) async {
    final rows = await DbInit.db.query('ai_models', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static Future<void> upsert(AIModelConfig m) async {
    final idx = _cache.indexWhere((e) => e.id == m.id);
    if (idx >= 0) { _cache[idx] = m; } else { _cache.add(m); }
    await DbInit.db.insert('ai_models', _toRow(m),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> delete(String id) async {
    _cache.removeWhere((e) => e.id == id);
    await DbInit.db.delete('ai_models', where: 'id = ?', whereArgs: [id]);
  }

  /// 清空所有模型（同步清缓存 + 异步清表）
  static Future<void> clearAll() async {
    _cache = [];
    await DbInit.db.delete('ai_models');
  }

  /// 取消所有默认标记（同步更新缓存 + 异步写库）
  static Future<void> clearDefault() async {
    for (final m in _cache) {
      m.isDefault = false;
    }
    await DbInit.db.update('ai_models', {'isDefault': 0},
        where: 'isDefault = 1');
  }

  static Map<String, dynamic> _toRow(AIModelConfig m) => {
    'id': m.id, 'provider': m.provider, 'name': m.name,
    'apiKey': m.apiKey, 'baseUrl': m.baseUrl, 'modelName': m.modelName,
    'temperature': m.temperature, 'maxTokens': m.maxTokens,
    'isDefault': m.isDefault ? 1 : 0,
  };

  static AIModelConfig _fromRow(Map<String, dynamic> r) {
    final m = AIModelConfig()
      ..id = r['id'] as String
      ..provider = r['provider'] as String
      ..name = r['name'] as String
      ..apiKey = r['apiKey'] as String
      ..baseUrl = r['baseUrl'] as String
      ..modelName = r['modelName'] as String
      ..temperature = (r['temperature'] as num?)?.toDouble() ?? 0.3
      ..maxTokens = r['maxTokens'] as int? ?? 4096
      ..isDefault = (r['isDefault'] as int?) == 1;
    return m;
  }
}

// ═══════════════════════════════════════════════════════════
// ChatSessionsDao
// ═══════════════════════════════════════════════════════════
class ChatSessionsDao {
  // 内存缓存：启动时加载，sync 读路径使用
  static final Map<String, ChatSession> _cache = {};

  static Future<void> loadCache() async {
    _cache.clear();
    final all = await getAll();
    for (final s in all) {
      _cache[s.id] = s;
    }
  }

  /// 同步获取所有缓存的会话
  static List<ChatSession> get cached => _cache.values.toList();

  /// 同步按 id 查找（从缓存）
  static ChatSession? getCachedById(String id) => _cache[id];

  static Future<List<ChatSession>> getAll() async {
    final rows = await DbInit.db.query('chat_sessions', orderBy: 'updatedAt DESC');
    return rows.map(_fromRow).toList();
  }

  static Future<ChatSession?> getById(String id) async {
    final rows = await DbInit.db.query('chat_sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static Future<void> upsert(ChatSession s) async {
    _cache[s.id] = s;
    await DbInit.db.insert('chat_sessions', _toRow(s),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> delete(String id) async {
    _cache.remove(id);
    await DbInit.db.delete('chat_sessions', where: 'id = ?', whereArgs: [id]);
  }

  /// 清空所有聊天会话（同步清缓存 + 异步清表）
  static Future<void> clearAll() async {
    _cache.clear();
    await DbInit.db.delete('chat_sessions');
  }

  static Map<String, dynamic> _toRow(ChatSession s) => {
    'id': s.id, 'hostId': s.hostId,
    'messages': jsonEncode(s.messages.map(_chatMsgToJson).toList()),
    'createdAt': s.createdAt.millisecondsSinceEpoch,
    'updatedAt': s.updatedAt.millisecondsSinceEpoch,
  };

  static ChatSession _fromRow(Map<String, dynamic> r) {
    final s = ChatSession()
      ..id = r['id'] as String
      ..hostId = r['hostId'] as String?
      ..messages = (jsonDecode(r['messages'] as String) as List)
          .map((e) => _chatMsgFromJson(e as Map<String, dynamic>)).toList()
      ..createdAt = DateTime.fromMillisecondsSinceEpoch(r['createdAt'] as int)
      ..updatedAt = DateTime.fromMillisecondsSinceEpoch(r['updatedAt'] as int);
    return s;
  }

  static Map<String, dynamic> _chatMsgToJson(ChatMessage m) => {
    'role': m.role, 'content': m.content,
    'timestamp': m.timestamp.toIso8601String(),
    'commandBlocks': m.commandBlocks?.map((b) => {
      'command': b.command, 'description': b.description,
      'dangerous': b.dangerous, 'safetyLevel': b.safetyLevel,
      'output': b.output,
    }).toList(),
  };

  static ChatMessage _chatMsgFromJson(Map<String, dynamic> j) {
    final m = ChatMessage()
      ..role = j['role'] as String
      ..content = j['content'] as String
      ..timestamp = DateTime.parse(j['timestamp'] as String);
    final cbs = j['commandBlocks'];
    if (cbs is List) {
      m.commandBlocks = cbs.map((b) {
        final bm = b as Map<String, dynamic>;
        return CommandBlock()
          ..command = bm['command'] as String
          ..description = bm['description'] as String?
          ..dangerous = bm['dangerous'] as bool? ?? false
          ..safetyLevel = bm['safetyLevel'] as String? ?? 'safe'
          ..output = bm['output'] as String?;
      }).toList();
    }
    return m;
  }
}

// ═══════════════════════════════════════════════════════════
// SnippetsDao
// ═══════════════════════════════════════════════════════════
class SnippetsDao {
  // 内存缓存：启动时加载，sync 读路径使用
  static List<CommandSnippet> _cache = [];

  static Future<void> loadCache() async {
    _cache = await getAll();
  }

  /// 同步获取缓存中所有片段
  static List<CommandSnippet> get cached => _cache;

  /// 同步按 id 查找（从缓存）
  static CommandSnippet? getCachedById(String id) {
    for (final s in _cache) {
      if (s.id == id) return s;
    }
    return null;
  }

  static Future<List<CommandSnippet>> getAll() async {
    final rows = await DbInit.db.query('snippets', orderBy: 'createdAt DESC');
    return rows.map(_fromRow).toList();
  }

  static Future<void> upsert(CommandSnippet s) async {
    final idx = _cache.indexWhere((e) => e.id == s.id);
    if (idx >= 0) { _cache[idx] = s; } else { _cache.add(s); }
    await DbInit.db.insert('snippets', _toRow(s),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> delete(String id) async {
    _cache.removeWhere((e) => e.id == id);
    await DbInit.db.delete('snippets', where: 'id = ?', whereArgs: [id]);
  }

  /// 清空所有片段（同步清缓存 + 异步清表）
  static Future<void> clearAll() async {
    _cache = [];
    await DbInit.db.delete('snippets');
  }

  static Map<String, dynamic> _toRow(CommandSnippet s) => {
    'id': s.id, 'name': s.name, 'command': s.command,
    'description': s.description,
    'variables': jsonEncode(s.variables),
    'createdAt': s.createdAt.millisecondsSinceEpoch,
  };

  static CommandSnippet _fromRow(Map<String, dynamic> r) {
    final s = CommandSnippet()
      ..id = r['id'] as String
      ..name = r['name'] as String
      ..command = r['command'] as String
      ..description = r['description'] as String?
      ..variables = (jsonDecode(r['variables'] as String) as List)
          .map((e) => e as String).toList()
      ..createdAt = DateTime.fromMillisecondsSinceEpoch(r['createdAt'] as int);
    return s;
  }
}

// ═══════════════════════════════════════════════════════════
// ConversationsDao
// ═══════════════════════════════════════════════════════════
class ConversationsDao {
  // 内存缓存：key = conversationId，启动时加载
  // ConversationService 的 sync 方法（getActiveSession 等）依赖此缓存
  static final Map<String, Conversation> _cache = {};

  static Future<void> loadCache() async {
    _cache.clear();
    final rows = await DbInit.db.query('conversations');
    for (final r in rows) {
      final c = _fromRow(r);
      _cache[c.id] = c;
    }
  }

  /// 同步获取所有缓存的会话
  static List<Conversation> get cached => _cache.values.toList();

  /// 同步按 id 获取（从缓存）
  static Conversation? getCachedById(String id) => _cache[id];

  /// 同步获取指定 hostId 的 active 会话（从缓存）
  static Conversation? getCachedActiveByHost(String hostId) {
    for (final c in _cache.values) {
      if (c.hostId == hostId && c.isActive) return c;
    }
    return null;
  }

  /// 同步获取指定 hostId 的所有会话（从缓存）
  static List<Conversation> getCachedByHost(String hostId) {
    return _cache.values.where((c) => c.hostId == hostId).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  static Future<Conversation?> getActiveByHost(String hostId) async {
    final rows = await DbInit.db.query('conversations',
        where: 'hostId = ? AND isActive = 1', whereArgs: [hostId], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static Future<Conversation?> getById(String id) async {
    final rows = await DbInit.db.query('conversations',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static Future<void> upsert(Conversation c) async {
    _cache[c.id] = c;
    await DbInit.db.insert('conversations', _toRow(c),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 设置某个 hostId 下只允许一个 active（同步更新缓存 + 异步写库）
  static Future<void> setActive(String id, String hostId) async {
    // 同步更新缓存
    for (final c in _cache.values) {
      if (c.hostId == hostId) {
        c.isActive = (c.id == id);
      }
    }
    await DbInit.db.transaction((txn) async {
      await txn.update('conversations', {'isActive': 0},
          where: 'hostId = ?', whereArgs: [hostId]);
      await txn.update('conversations', {'isActive': 1},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<void> delete(String id) async {
    _cache.remove(id);
    await DbInit.db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  static Map<String, dynamic> _toRow(Conversation c) => {
    'id': c.id, 'hostId': c.hostId, 'title': c.title,
    'messages': jsonEncode(c.messages.map(_msgToJson).toList()),
    'agentLogs': jsonEncode(c.agentLogs.map(_logToJson).toList()),
    'summary': c.summary,
    'summarizedUpToIndex': c.summarizedUpToIndex,
    'createdAt': c.createdAt.millisecondsSinceEpoch,
    'updatedAt': c.updatedAt.millisecondsSinceEpoch,
    'isActive': c.isActive ? 1 : 0,
  };

  static Conversation _fromRow(Map<String, dynamic> r) {
    final c = Conversation()
      ..id = r['id'] as String
      ..hostId = r['hostId'] as String
      ..title = r['title'] as String
      ..messages = (jsonDecode(r['messages'] as String) as List)
          .map((e) => _msgFromJson(e as Map<String, dynamic>)).toList()
      ..agentLogs = (jsonDecode(r['agentLogs'] as String) as List)
          .map((e) => _logFromJson(e as Map<String, dynamic>)).toList()
      ..summary = r['summary'] as String?
      ..summarizedUpToIndex = r['summarizedUpToIndex'] as int? ?? 0
      ..createdAt = DateTime.fromMillisecondsSinceEpoch(r['createdAt'] as int)
      ..updatedAt = DateTime.fromMillisecondsSinceEpoch(r['updatedAt'] as int)
      ..isActive = (r['isActive'] as int?) == 1;
    return c;
  }

  static Map<String, dynamic> _msgToJson(ConvMessage m) => {
    'role': m.role, 'content': m.content,
    'timestamp': m.timestamp.toIso8601String(),
    'command': m.command, 'commandSuccess': m.commandSuccess,
    'events': m.events?.map(_eventToJson).toList(),
    'summary': m.summary,
  };

  static ConvMessage _msgFromJson(Map<String, dynamic> j) {
    final m = ConvMessage()
      ..role = j['role'] as String
      ..content = j['content'] as String
      ..timestamp = DateTime.parse(j['timestamp'] as String)
      ..command = j['command'] as String?
      ..commandSuccess = j['commandSuccess'] as bool?
      ..summary = j['summary'] as String?;
    final evs = j['events'];
    if (evs is List) {
      m.events = evs.map((e) => _eventFromJson(e as Map<String, dynamic>)).toList();
    }
    return m;
  }

  static Map<String, dynamic> _eventToJson(AgentEvent e) => {
    'id': e.id, 'type': e.type.name,
    'timestamp': e.timestamp.toIso8601String(),
    'text': e.text, 'command': e.command, 'commandId': e.commandId,
    'dangerous': e.dangerous, 'blocked': e.blocked,
    'success': e.success, 'output': e.output, 'error': e.error,
    'options': e.options, 'question': e.question, 'summary': e.summary,
    'isStreaming': e.isStreaming,
  };

  static AgentEvent _eventFromJson(Map<String, dynamic> j) {
    final e = AgentEvent()
      ..id = j['id'] as String
      ..type = AgentEventType.values.byName(j['type'] as String)
      ..timestamp = DateTime.parse(j['timestamp'] as String)
      ..text = j['text'] as String?
      ..command = j['command'] as String?
      ..commandId = j['commandId'] as String?
      ..dangerous = j['dangerous'] as bool?
      ..blocked = j['blocked'] as bool?
      ..success = j['success'] as bool?
      ..output = j['output'] as String?
      ..error = j['error'] as String?
      ..options = (j['options'] as List?)?.map((e) => e as String).toList()
      ..question = j['question'] as String?
      ..summary = j['summary'] as String?
      ..isStreaming = j['isStreaming'] as bool? ?? false;
    return e;
  }

  static Map<String, dynamic> _logToJson(ConvAgentLog l) => {
    'timestamp': l.timestamp.toIso8601String(),
    'level': l.level, 'tag': l.tag, 'message': l.message,
  };

  static ConvAgentLog _logFromJson(Map<String, dynamic> j) {
    return ConvAgentLog()
      ..timestamp = DateTime.parse(j['timestamp'] as String)
      ..level = j['level'] as String
      ..tag = j['tag'] as String
      ..message = j['message'] as String;
  }
}

// ═══════════════════════════════════════════════════════════
// ChangeRecordsDao
// ═══════════════════════════════════════════════════════════
class ChangeRecordsDao {
  // 内存缓存：启动时加载全部，sync 读路径使用
  static List<ChangeRecord> _cache = [];

  static Future<void> loadCache() async {
    _cache = await getAll();
  }

  static Future<List<ChangeRecord>> getAll() async {
    final rows = await DbInit.db.query('change_records', orderBy: 'timestamp DESC');
    return rows.map(_fromRow).toList();
  }

  /// 同步获取缓存中指定 host 的变更记录（按时间倒序）
  static List<ChangeRecord> getCachedByHost(String hostId, {int limit = 100}) {
    final list = _cache.where((r) => r.hostId == hostId).toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list.take(limit).toList();
  }

  /// 同步获取缓存中所有变更记录（按时间倒序）
  static List<ChangeRecord> get cachedAll {
    final list = List<ChangeRecord>.from(_cache);
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  /// 同步按 id 获取
  static ChangeRecord? getCachedById(String id) {
    for (final r in _cache) {
      if (r.id == id) return r;
    }
    return null;
  }

  static Future<List<ChangeRecord>> getByHost(String hostId, {int? limit}) async {
    final rows = await DbInit.db.query('change_records',
        where: 'hostId = ?', whereArgs: [hostId],
        orderBy: 'timestamp DESC', limit: limit);
    return rows.map(_fromRow).toList();
  }

  static Future<void> upsert(ChangeRecord r) async {
    final idx = _cache.indexWhere((e) => e.id == r.id);
    if (idx >= 0) { _cache[idx] = r; } else { _cache.add(r); }
    await DbInit.db.insert('change_records', _toRow(r),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> delete(String id) async {
    _cache.removeWhere((e) => e.id == id);
    await DbInit.db.delete('change_records', where: 'id = ?', whereArgs: [id]);
  }

  static Map<String, dynamic> _toRow(ChangeRecord r) => {
    'id': r.id, 'hostId': r.hostId, 'command': r.command,
    'type': r.type.name,
    'rollbackCommand': r.rollbackCommand,
    'rollbackDescription': r.rollbackDescription,
    'timestamp': r.timestamp.millisecondsSinceEpoch,
    'success': r.success ? 1 : 0,
    'username': r.username, 'conversationId': r.conversationId,
    'rolledBack': r.rolledBack ? 1 : 0,
  };

  static ChangeRecord _fromRow(Map<String, dynamic> r) {
    return ChangeRecord(
      id: r['id'] as String,
      hostId: r['hostId'] as String,
      command: r['command'] as String,
      type: ChangeType.values.byName(r['type'] as String),
      rollbackCommand: r['rollbackCommand'] as String?,
      rollbackDescription: r['rollbackDescription'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(r['timestamp'] as int),
      success: (r['success'] as int) == 1,
      username: r['username'] as String?,
      conversationId: r['conversationId'] as String?,
      rolledBack: (r['rolledBack'] as int?) == 1,
    );
  }
}

// ═══════════════════════════════════════════════════════════
// RunbooksDao
// ═══════════════════════════════════════════════════════════
class RunbooksDao {
  // 内存缓存：启动时加载，sync 读路径使用
  static List<Runbook> _cache = [];

  static Future<void> loadCache() async {
    _cache = await getAll();
  }

  /// 同步获取缓存中所有工作流
  static List<Runbook> get cached => _cache;

  /// 同步按 id 查找（从缓存）
  static Runbook? getCachedById(String id) {
    for (final r in _cache) {
      if (r.id == id) return r;
    }
    return null;
  }

  static Future<List<Runbook>> getAll() async {
    final rows = await DbInit.db.query('runbooks', orderBy: 'createdAt ASC');
    return rows.map(_fromRow).toList();
  }

  static Future<Runbook?> getById(String id) async {
    final rows = await DbInit.db.query('runbooks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static Future<void> upsert(Runbook r) async {
    final idx = _cache.indexWhere((e) => e.id == r.id);
    if (idx >= 0) { _cache[idx] = r; } else { _cache.add(r); }
    await DbInit.db.insert('runbooks', _toRow(r),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> delete(String id) async {
    _cache.removeWhere((e) => e.id == id);
    await DbInit.db.delete('runbooks', where: 'id = ?', whereArgs: [id]);
  }

  /// 执行次数 +1，并更新 lastRunAt（同步更新缓存 + 异步写库）
  static Future<void> incrementRunCount(String id) async {
    final rb = getCachedById(id);
    if (rb != null) {
      rb.runCount += 1;
      rb.lastRunAt = DateTime.now();
    }
    await DbInit.db.rawUpdate(
      "UPDATE runbooks SET runCount = runCount + 1, lastRunAt = ? WHERE id = ?",
      [DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  static Map<String, dynamic> _toRow(Runbook r) => {
    'id': r.id, 'name': r.name, 'icon': r.icon,
    'description': r.description,
    'type': r.type.name, 'category': r.category.name,
    'content': r.content,
    'isBuiltin': r.isBuiltin ? 1 : 0,
    'createdAt': r.createdAt.millisecondsSinceEpoch,
    'updatedAt': r.updatedAt.millisecondsSinceEpoch,
    'runCount': r.runCount,
    'lastRunAt': r.lastRunAt?.millisecondsSinceEpoch,
  };

  static Runbook _fromRow(Map<String, dynamic> r) {
    final rb = Runbook()
      ..id = r['id'] as String
      ..name = r['name'] as String
      ..icon = r['icon'] as String
      ..description = r['description'] as String?
      ..type = RunbookType.values.byName(r['type'] as String)
      ..category = RunbookCategory.values.byName(r['category'] as String)
      ..content = r['content'] as String
      ..isBuiltin = (r['isBuiltin'] as int?) == 1
      ..createdAt = DateTime.fromMillisecondsSinceEpoch(r['createdAt'] as int)
      ..updatedAt = DateTime.fromMillisecondsSinceEpoch(r['updatedAt'] as int)
      ..runCount = r['runCount'] as int? ?? 0
      ..lastRunAt = r['lastRunAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(r['lastRunAt'] as int)
          : null;
    return rb;
  }
}

// ═══════════════════════════════════════════════════════════
// SettingsDao (KV)
// ═══════════════════════════════════════════════════════════
class SettingsDao {
  // 内存缓存：启动时加载，sync 读路径使用（prompts/app_lock/command_heuristics 等）
  static final Map<String, dynamic> _cache = {};

  static Future<void> loadCache() async {
    _cache.clear();
    _cache.addAll(await loadAll());
  }

  /// 同步获取缓存中的设置项
  static dynamic getCached(String key, {dynamic defaultValue}) {
    return _cache[key] ?? defaultValue;
  }

  /// 同步获取整个缓存 Map（SettingsNotifier.loadSettings 使用）
  static Map<String, dynamic> get cachedMap => Map<String, dynamic>.from(_cache);

  /// 异步加载所有设置
  static Future<Map<String, dynamic>> loadAll() async {
    final rows = await DbInit.db.query('settings');
    final result = <String, dynamic>{};
    for (final r in rows) {
      final key = r['key'] as String;
      final val = r['value'] as String?;
      if (val == null) continue;
      try {
        result[key] = jsonDecode(val);
      } catch (_) {
        result[key] = val;
      }
    }
    return result;
  }

  static Future<void> set(String key, dynamic value) async {
    _cache[key] = value;
    final encoded = jsonEncode(value);
    await DbInit.db.insert('settings', {'key': key, 'value': encoded},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> remove(String key) async {
    _cache.remove(key);
    await DbInit.db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  static Future<void> clear() async {
    _cache.clear();
    await DbInit.db.delete('settings');
  }
}

// ═══════════════════════════════════════════════════════════
// AuditLogsDao
// ═══════════════════════════════════════════════════════════
class AuditLogsDao {
  static const _maxEntries = 1000;

  // 内存缓存：最近 N 条审计日志，启动时加载
  // AuditLogger 的 sync 读方法（getLogsForHost/getRecentLogs）依赖此缓存
  static final List<Map<String, dynamic>> _cache = [];

  static Future<void> loadCache() async {
    _cache.clear();
    final rows = await DbInit.db.query('audit_logs',
        orderBy: 'timestamp DESC', limit: _maxEntries);
    for (final r in rows.reversed) {
      _cache.add(_rowToMap(r));
    }
  }

  /// 同步获取缓存中指定 host 的审计日志（正序：最早到最新）
  static List<Map<String, dynamic>> getCachedLogsForHost(String hostId, {int limit = 100}) {
    final result = <Map<String, dynamic>>[];
    for (int i = _cache.length - 1; i >= 0 && result.length < limit; i--) {
      if (_cache[i]['hostId'] == hostId) {
        result.add(_cache[i]);
      }
    }
    return result.reversed.toList(growable: false);
  }

  /// 同步获取最近的审计日志（倒序：最新在前）
  static List<Map<String, dynamic>> getCachedRecentLogs({int limit = 100}) {
    final result = <Map<String, dynamic>>[];
    for (int i = _cache.length - 1; i >= 0 && result.length < limit; i--) {
      result.add(_cache[i]);
    }
    return result;
  }

  static Future<void> add({
    required String hostId,
    required String command,
    required String safetyLevel,
    String? output,
    required bool executed,
  }) async {
    final entry = {
      'timestamp': DateTime.now().toIso8601String(),
      'hostId': hostId,
      'command': command,
      'safetyLevel': safetyLevel,
      'output': output,
      'executed': executed,
    };
    // 同步更新缓存
    _cache.add(entry);
    while (_cache.length > _maxEntries) {
      _cache.removeAt(0);
    }
    // 异步写入数据库
    await DbInit.db.insert('audit_logs', {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'hostId': hostId,
      'command': command,
      'safetyLevel': safetyLevel,
      'output': output,
      'executed': executed ? 1 : 0,
    });
    // 容量控制：删除超出上限的最早记录
    final count = Sqflite.firstIntValue(
        await DbInit.db.rawQuery('SELECT COUNT(*) FROM audit_logs'));
    if (count != null && count > _maxEntries) {
      await DbInit.db.rawDelete(
        'DELETE FROM audit_logs WHERE id IN (SELECT id FROM audit_logs ORDER BY timestamp ASC LIMIT ?)',
        [count - _maxEntries],
      );
    }
  }

  static Future<List<Map<String, dynamic>>> getLogsForHost(String hostId, {int limit = 100}) async {
    final rows = await DbInit.db.query('audit_logs',
        where: 'hostId = ?', whereArgs: [hostId],
        orderBy: 'timestamp DESC', limit: limit);
    return rows.map(_rowToMap).toList().reversed.toList();
  }

  static Future<List<Map<String, dynamic>>> getRecentLogs({int limit = 100}) async {
    final rows = await DbInit.db.query('audit_logs',
        orderBy: 'timestamp DESC', limit: limit);
    return rows.map(_rowToMap).toList();
  }

  static Map<String, dynamic> _rowToMap(Map<String, dynamic> r) => {
    'timestamp': DateTime.fromMillisecondsSinceEpoch(r['timestamp'] as int).toIso8601String(),
    'hostId': r['hostId'],
    'command': r['command'],
    'safetyLevel': r['safetyLevel'],
    'output': r['output'],
    'executed': (r['executed'] as int) == 1,
  };
}

// ═══════════════════════════════════════════════════════════
// CredentialsFallbackDao
// ═══════════════════════════════════════════════════════════
/// AES 加密密文存储（Keychain 不可用时的降级方案）
class CredentialsFallbackDao {
  static Future<void> put(String key, String encryptedValue) async {
    await DbInit.db.insert('credentials_fallback',
        {'key': key, 'value': encryptedValue},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<String?> get(String key) async {
    final rows = await DbInit.db.query('credentials_fallback',
        where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  static Future<void> delete(String key) async {
    await DbInit.db.delete('credentials_fallback',
        where: 'key = ?', whereArgs: [key]);
  }

  /// 获取所有 key（用于旧数据迁移）
  static Future<List<String>> getAllKeys() async {
    final rows = await DbInit.db.query('credentials_fallback', columns: ['key']);
    return rows.map((r) => r['key'] as String).toList();
  }
}
