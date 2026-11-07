import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../core/db_init.dart';
import '../models/host_config.dart';
import '../models/ai_model_config.dart';
import '../models/ai_endpoint.dart';
import '../models/chat_session.dart';
import '../models/command_snippet.dart';
import '../models/conversation.dart';
import '../models/agent_event.dart';
import '../models/operation_report.dart';
import '../models/plan_step.dart';
import '../models/host_execution_result.dart';
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

  /// 旧数据的默认模型 id（仅迁移时用于初始化当前选择），新配置不再有默认模型
  static Future<String?> getLegacyDefaultId() async {
    final rows = await DbInit.db.query('ai_models',
        columns: ['id'], where: 'isDefault = 1', limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as String?;
  }

  static Map<String, dynamic> _toRow(AIModelConfig m) => {
    'id': m.id, 'provider': m.provider, 'name': m.name,
    'apiKey': m.apiKey, 'baseUrl': m.baseUrl, 'modelName': m.modelName,
    'temperature': m.temperature, 'maxTokens': m.maxTokens,
    'contextWindow': m.contextWindow,
    'fallbackModelId': m.fallbackModelId,
    'supportsFunctionCalling': m.supportsFunctionCalling ? 1 : 0,
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
      ..contextWindow = r['contextWindow'] as int? ?? 0
      ..fallbackModelId = r['fallbackModelId'] as String?
      ..supportsFunctionCalling = (r['supportsFunctionCalling'] as int?) == 1;
    return m;
  }
}

// ═══════════════════════════════════════════════════════════
// AIEndpointsDao
// ═══════════════════════════════════════════════════════════

/// 端点及其模型目录。API Key 不落此表，由 CredentialsStore 按端点 id 保存。
class AIEndpointsDao {
  static List<AIEndpoint> _cache = [];

  static Future<void> loadCache() async {
    _cache = await getAll();
  }

  /// 用已注入 API Key 的内存副本替换缓存（不落库）。
  /// 供无 ref 的同步路径（如 Agent 的 fallback 解析）使用。
  static void cacheWithRuntimeKeys(List<AIEndpoint> endpoints) {
    _cache = endpoints;
  }

  static List<AIEndpoint> get cached => _cache;

  static AIEndpoint? getCachedById(String id) {
    for (final e in _cache) {
      if (e.id == id) return e;
    }
    return null;
  }

  static Future<List<AIEndpoint>> getAll() async {
    final rows =
        await DbInit.db.query('ai_endpoints', orderBy: 'createdAt ASC');
    return rows.map(_fromRow).toList();
  }

  static Future<void> upsert(AIEndpoint endpoint) async {
    final idx = _cache.indexWhere((e) => e.id == endpoint.id);
    if (idx >= 0) {
      _cache[idx] = endpoint;
    } else {
      _cache.add(endpoint);
    }
    await DbInit.db.insert('ai_endpoints', _toRow(endpoint),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> delete(String id) async {
    _cache.removeWhere((e) => e.id == id);
    await DbInit.db.delete('ai_endpoints', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> clearAll() async {
    _cache = [];
    await DbInit.db.delete('ai_endpoints');
  }

  static Map<String, dynamic> _toRow(AIEndpoint e) => {
        'id': e.id,
        'providerId': e.providerId,
        'name': e.name,
        'baseUrl': e.baseUrl,
        'protocol': e.protocol,
        'models': jsonEncode(e.models.map((m) => m.toJson()).toList()),
        'createdAt': e.createdAt,
      };

  static AIEndpoint _fromRow(Map<String, dynamic> r) {
    List<AIEndpointModel> models = const [];
    final raw = r['models'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          models = decoded
              .whereType<Map>()
              .map((m) =>
                  AIEndpointModel.fromJson(Map<String, dynamic>.from(m)))
              .toList();
        }
      } catch (e) {
        debugPrint('[AIEndpointsDao] 模型目录 JSON 解析失败 (id=${r['id']}): $e');
      }
    }
    return AIEndpoint(
      id: r['id'] as String,
      providerId: r['providerId'] as String? ?? 'custom',
      name: r['name'] as String? ?? '',
      baseUrl: r['baseUrl'] as String? ?? '',
      protocol: r['protocol'] as String? ?? 'openai',
      models: models,
      createdAt: r['createdAt'] as int? ?? 0,
    );
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
  /// active 会话的二级索引缓存：避免每次 tab 切换都线性扫全部会话
  static String? _activeHostKey;
  static Conversation? _activeConversation;

  static void _invalidateActiveCache() {
    _activeHostKey = null;
    _activeConversation = null;
  }

  static Future<void> loadCache() async {
    _cache.clear();
    final rows = await DbInit.db.query('conversations');
    for (final r in rows) {
      final c = _fromRow(r);
      _cache[c.id] = c;
    }
    _invalidateActiveCache();
  }

  /// 同步获取所有缓存的会话
  static List<Conversation> get cached => _cache.values.toList();

  /// 同步按 id 获取（从缓存）
  static Conversation? getCachedById(String id) => _cache[id];

  /// 同步获取指定 hostId 的 active 会话（从缓存）
  static Conversation? getCachedActiveByHost(String hostId) {
    final cached = _activeConversation;
    if (_activeHostKey == hostId &&
        cached != null &&
        cached.isActive &&
        identical(_cache[cached.id], cached)) {
      return cached;
    }
    for (final c in _cache.values) {
      if (c.hostId == hostId && c.isActive) {
        _activeHostKey = hostId;
        _activeConversation = c;
        return c;
      }
    }
    _activeHostKey = hostId;
    _activeConversation = null;
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

  /// 每会话一条写入链：序列化移到后台 isolate 后，两次 upsert 的编码耗时
  /// 不再与调用顺序一致，必须串行化保证"后调用的快照最后落盘"，
  /// 否则旧快照可能覆盖新快照。
  static final Map<String, Future<void>> _upsertChains = {};

  static Future<void> upsert(Conversation c) async {
    _cache[c.id] = c;
    _invalidateActiveCache();
    final prev = _upsertChains[c.id] ?? Future<void>.value();
    final completer = Completer<void>();
    _upsertChains[c.id] = completer.future;
    // 链本身吞掉错误继续运转；错误仍通过返回的 future 暴露给调用方（R8）
    completer.future.catchError((Object _) {});
    // 前一次写入失败不阻断后续写入（错误已暴露给该次调用方）
    prev.catchError((Object _) {}).then((_) async {
      try {
        final row = await _encodeRow(c);
        await DbInit.db.insert('conversations', row,
            conflictAlgorithm: ConflictAlgorithm.replace);
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        if (identical(_upsertChains[c.id], completer.future)) {
          _upsertChains.remove(c.id);
        }
      }
    });
    return completer.future;
  }

  /// 大会话的 jsonEncode（全部消息+事件+日志）可达数十 ms，放在 UI isolate
  /// 会造成掉帧；超过阈值时移到后台 isolate 编码。isolate 消息拷贝在发送侧
  /// 同步完成，拷贝后 UI 继续修改 conv 不影响 isolate 内的私有副本。
  static Future<Map<String, dynamic>> _encodeRow(Conversation c) async {
    var size = 0;
    for (final m in c.messages) {
      size += m.content.length;
    }
    if (size < 32768) return _toRow(c);
    try {
      return await compute(_toRow, c);
    } catch (_) {
      // isolate 路径失败（如对象图不可发送）时回退内联编码，保证写入不丢
      return _toRow(c);
    }
  }

  /// 设置某个 hostId 下只允许一个 active（同步更新缓存 + 异步写库）
  static Future<void> setActive(String id, String hostId) async {
    // 同步更新缓存
    for (final c in _cache.values) {
      if (c.hostId == hostId) {
        c.isActive = (c.id == id);
      }
    }
    _invalidateActiveCache();
    await DbInit.db.transaction((txn) async {
      await txn.update('conversations', {'isActive': 0},
          where: 'hostId = ?', whereArgs: [hostId]);
      await txn.update('conversations', {'isActive': 1},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<void> delete(String id) async {
    _cache.remove(id);
    _invalidateActiveCache();
    await DbInit.db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  static Map<String, dynamic> _toRow(Conversation c) => {
    'id': c.id, 'hostId': c.hostId, 'title': c.title,
    'messages': jsonEncode(c.messages.map(_msgToJson).toList()),
    'agentLogs': c.rawAgentLogsJson ??
        jsonEncode(c.agentLogs.map(_logToJson).toList()),
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
      ..setAgentLogsJson(r['agentLogs'] as String?)
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
    'finishState': e.finishState?.name,
    'hostId': e.hostId, 'toolName': e.toolName, 'riskLevel': e.riskLevel,
    'permissionDecision': e.permissionDecision,
    'durationMs': e.durationMs, 'exitCode': e.exitCode,
    'failureKind': e.failureKind,
    'outputTotalChars': e.outputTotalChars,
    'outputTruncated': e.outputTruncated,
    'outputTail': e.outputTail,
    'diffAdditions': e.diffAdditions,
    'diffDeletions': e.diffDeletions,
    'operationReport': e.operationReport?.toJson(),
    'planSteps': e.planSteps?.map((s) => s.toJson()).toList(growable: false),
    'hostResults': e.hostResults?.map(
        (hostId, r) => MapEntry(hostId, r.toJson())),
    'isStreaming': e.isStreaming,
  };

  static AgentEvent _eventFromJson(Map<String, dynamic> j) {
    final rawReport = j['operationReport'];
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
      ..finishState =
          AgentFinishState.values.asNameMap()[j['finishState'] as String?]
      ..hostId = j['hostId'] as String?
      ..toolName = j['toolName'] as String?
      ..riskLevel = j['riskLevel'] as String?
      ..permissionDecision = j['permissionDecision'] as String?
      ..durationMs = (j['durationMs'] as num?)?.toInt()
      ..exitCode = (j['exitCode'] as num?)?.toInt()
      ..failureKind = j['failureKind'] as String?
      ..outputTotalChars = (j['outputTotalChars'] as num?)?.toInt()
      ..outputTruncated = j['outputTruncated'] as bool?
      ..outputTail = j['outputTail'] as String?
      ..diffAdditions = (j['diffAdditions'] as num?)?.toInt()
      ..diffDeletions = (j['diffDeletions'] as num?)?.toInt()
      ..operationReport = rawReport is Map
          ? OperationReport.fromJson(Map<String, dynamic>.from(rawReport))
          : null
      ..planSteps = _planSteps(j['planSteps'])
      ..hostResults = _hostResults(j['hostResults'])
      ..isStreaming = j['isStreaming'] as bool? ?? false;
    return e;
  }

  static Map<String, HostExecutionResult>? _hostResults(Object? raw) {
    if (raw is! Map) return null;
    final results = <String, HostExecutionResult>{};
    raw.forEach((key, value) {
      if (key is String && value is Map) {
        results[key] = HostExecutionResult.fromJson(
            Map<String, dynamic>.from(value));
      }
    });
    return results.isEmpty ? null : results;
  }

  static List<PlanStep>? _planSteps(Object? raw) {
    if (raw is! List) return null;
    final steps = raw
        .whereType<Map>()
        .map((e) => PlanStep.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.title.trim().isNotEmpty)
        .toList(growable: false);
    return steps.isEmpty ? null : steps;
  }

  static Map<String, dynamic> _logToJson(ConvAgentLog l) => {
    'timestamp': l.timestamp.toIso8601String(),
    'level': l.level, 'tag': l.tag, 'message': l.message,
  };
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
    'localRestoreFrom': r.localRestoreFrom,
    'localRestoreTo': r.localRestoreTo,
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
      localRestoreFrom: r['localRestoreFrom'] as String?,
      localRestoreTo: r['localRestoreTo'] as String?,
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
    // R8: 持久化失败必须暴露（不能 silent catch）
    // 测试环境（widget_test）下 DbInit 未初始化，降级为只写缓存并 debugPrint
    // 生产环境 DbInit 必然已初始化（main.dart 顺序），不会走此分支
    // 不用 agentLogger.warn：会触发 AgentLogger._scheduleFlush() 创建 500ms Timer，
    // 在测试环境下不被清理导致 "Timer is still pending" 错误。
    // debugPrint 在 debug 模式下输出控制台（开发可见），release 模式 no-op
    // 但 release 模式下生产环境不会触发此分支，无数据丢失风险。
    if (!DbInit.isInitialized) {
      debugPrint('[SettingsDao] WARN: DbInit 未初始化，set($key) 仅写缓存，未持久化');
      return;
    }
    final encoded = jsonEncode(value);
    await DbInit.db.insert('settings', {'key': key, 'value': encoded},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> remove(String key) async {
    _cache.remove(key);
    // R8: 与 set() 一致的防御：DbInit 未初始化时仅清缓存
    if (!DbInit.isInitialized) {
      debugPrint('[SettingsDao] WARN: DbInit 未初始化，remove($key) 仅清缓存，未持久化');
      return;
    }
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
    // 旧版本可能留下超过上限的行；启动时一次性收敛，之后按溢出量增量清理
    await DbInit.db.rawDelete(
      'DELETE FROM audit_logs WHERE id NOT IN '
      '(SELECT id FROM audit_logs ORDER BY timestamp DESC LIMIT ?)',
      [_maxEntries],
    );
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
    final overflow = _cache.length - _maxEntries;
    if (overflow > 0) {
      _cache.removeRange(0, overflow);
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
    // 容量控制：只按新增溢出量删除，避免每条命令都 COUNT(*) 全表
    if (overflow > 0) {
      await DbInit.db.rawDelete(
        'DELETE FROM audit_logs WHERE id IN (SELECT id FROM audit_logs ORDER BY timestamp ASC LIMIT ?)',
        [overflow],
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
