import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../core/db_init.dart';
import 'daos.dart';
import '../models/host_config.dart';
import '../models/ai_model_config.dart';
import '../models/chat_session.dart';
import '../models/command_snippet.dart';
import '../models/conversation.dart';
import '../models/agent_event.dart';
import '../models/change_record.dart';
import '../models/runbook.dart';

/// Hive → SQLite 一次性数据迁移器
///
/// 启动时检测：如果 Hive box 存在且 SQLite 未标记已迁移，则执行迁移。
/// 迁移完成后写入 migration_meta 标记，避免重复执行。
class HiveMigrator {
  static const _flagKey = 'hive_migrated';

  /// 是否需要迁移（SQLite 未标记已迁移 + Hive 数据存在）
  static Future<bool> needsMigration() async {
    // 检查 SQLite 标记
    final rows = await DbInit.db.query('migration_meta',
        where: 'key = ?', whereArgs: [_flagKey], limit: 1);
    if (rows.isNotEmpty && rows.first['value'] == '1') {
      return false;
    }
    // 检查 Hive 是否有数据（通过文件存在性判断）
    return await _hiveHasData();
  }

  /// 执行迁移（幂等：已迁移则跳过）
  static Future<void> migrate() async {
    if (!await needsMigration()) return;

    debugPrint('[HiveMigrator] 开始迁移 Hive → SQLite...');
    var totalRecords = 0;

    try {
      // 初始化 Hive（只读模式，用于读取旧数据）
      await Hive.initFlutter();
      _registerAdapters();

      totalRecords += await _migrateHosts();
      totalRecords += await _migrateAIModels();
      totalRecords += await _migrateChatSessions();
      totalRecords += await _migrateSnippets();
      totalRecords += await _migrateConversations();
      totalRecords += await _migrateChangeRecords();
      totalRecords += await _migrateRunbooks();
      totalRecords += await _migrateSettings();
      totalRecords += await _migrateAuditLogs();
      totalRecords += await _migrateCredentialsFallback();

      // 标记迁移完成
      await DbInit.db.insert('migration_meta', {'key': _flagKey, 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);

      debugPrint('[HiveMigrator] 迁移完成，共 $totalRecords 条记录');

      // 关闭 Hive
      await Hive.close();
    } catch (e, stack) {
      debugPrint('[HiveMigrator] 迁移失败: $e\n$stack');
      // 不标记完成，下次启动会重试
      rethrow;
    }
  }

  static void _registerAdapters() {
    try {
      Hive.registerAdapter(HostConfigAdapter());
      Hive.registerAdapter(AIModelConfigAdapter());
      Hive.registerAdapter(ChatSessionAdapter());
      Hive.registerAdapter(ChatMessageAdapter());
      Hive.registerAdapter(CommandBlockAdapter());
      Hive.registerAdapter(CommandSnippetAdapter());
      Hive.registerAdapter(AgentEventTypeAdapter());
      Hive.registerAdapter(AgentEventAdapter());
      Hive.registerAdapter(ConvMessageAdapter());
      Hive.registerAdapter(ConvAgentLogAdapter());
      Hive.registerAdapter(ConversationAdapter());
      Hive.registerAdapter(ChangeTypeAdapter());
      Hive.registerAdapter(ChangeRecordAdapter());
      Hive.registerAdapter(RunbookTypeAdapter());
      Hive.registerAdapter(RunbookCategoryAdapter());
      Hive.registerAdapter(RunbookAdapter());
    } catch (_) {
      // adapter 可能已注册，忽略
    }
  }

  /// 检查 Hive 数据目录是否存在 .hive 文件
  static Future<bool> _hiveHasData() async {
    try {
      final dir = await _getHiveDir();
      if (dir == null) return false;
      final exists = await dir.exists();
      if (!exists) return false;
      // 检查是否有 .hive 文件
      final files = await dir.list().where((f) => f.path.endsWith('.hive')).toList();
      return files.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 获取 Hive 默认数据目录
  /// Hive.initFlutter() 默认使用 getApplicationDocumentsDirectory()
  static Future<Directory?> _getHiveDir() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return null;
    }
  }

  // ===== 各表迁移 =====

  static Future<int> _migrateHosts() async {
    try {
      final box = await Hive.openBox<HostConfig>('hosts');
      if (box.isEmpty) { await box.close(); return 0; }
      var count = 0;
      for (final key in box.keys) {
        final h = box.get(key);
        if (h != null) {
          await HostsDao.upsert(h);
          count++;
        }
      }
      await box.close();
      debugPrint('[HiveMigrator] hosts: $count 条');
      return count;
    } catch (e) {
      debugPrint('[HiveMigrator] hosts 迁移失败: $e');
      return 0;
    }
  }

  static Future<int> _migrateAIModels() async {
    try {
      final box = await Hive.openBox<AIModelConfig>('aiModels');
      if (box.isEmpty) { await box.close(); return 0; }
      var count = 0;
      for (final key in box.keys) {
        final m = box.get(key);
        if (m != null) {
          await AIModelsDao.upsert(m);
          count++;
        }
      }
      await box.close();
      debugPrint('[HiveMigrator] aiModels: $count 条');
      return count;
    } catch (e) {
      debugPrint('[HiveMigrator] aiModels 迁移失败: $e');
      return 0;
    }
  }

  static Future<int> _migrateChatSessions() async {
    try {
      final box = await Hive.openBox<ChatSession>('chatSessions');
      if (box.isEmpty) { await box.close(); return 0; }
      var count = 0;
      for (final key in box.keys) {
        final s = box.get(key);
        if (s != null) {
          await ChatSessionsDao.upsert(s);
          count++;
        }
      }
      await box.close();
      debugPrint('[HiveMigrator] chatSessions: $count 条');
      return count;
    } catch (e) {
      debugPrint('[HiveMigrator] chatSessions 迁移失败: $e');
      return 0;
    }
  }

  static Future<int> _migrateSnippets() async {
    try {
      final box = await Hive.openBox<CommandSnippet>('snippets');
      if (box.isEmpty) { await box.close(); return 0; }
      var count = 0;
      for (final key in box.keys) {
        final s = box.get(key);
        if (s != null) {
          await SnippetsDao.upsert(s);
          count++;
        }
      }
      await box.close();
      debugPrint('[HiveMigrator] snippets: $count 条');
      return count;
    } catch (e) {
      debugPrint('[HiveMigrator] snippets 迁移失败: $e');
      return 0;
    }
  }

  static Future<int> _migrateConversations() async {
    try {
      final box = await Hive.openBox<Conversation>('conversations');
      if (box.isEmpty) { await box.close(); return 0; }
      var count = 0;
      for (final key in box.keys) {
        final c = box.get(key);
        if (c != null) {
          await ConversationsDao.upsert(c);
          count++;
        }
      }
      await box.close();
      debugPrint('[HiveMigrator] conversations: $count 条');
      return count;
    } catch (e) {
      debugPrint('[HiveMigrator] conversations 迁移失败: $e');
      return 0;
    }
  }

  static Future<int> _migrateChangeRecords() async {
    try {
      final box = await Hive.openBox<ChangeRecord>('changeRecords');
      if (box.isEmpty) { await box.close(); return 0; }
      var count = 0;
      for (final key in box.keys) {
        final r = box.get(key);
        if (r != null) {
          await ChangeRecordsDao.upsert(r);
          count++;
        }
      }
      await box.close();
      debugPrint('[HiveMigrator] changeRecords: $count 条');
      return count;
    } catch (e) {
      debugPrint('[HiveMigrator] changeRecords 迁移失败: $e');
      return 0;
    }
  }

  static Future<int> _migrateRunbooks() async {
    try {
      final box = await Hive.openBox<Runbook>('runbooks');
      if (box.isEmpty) { await box.close(); return 0; }
      var count = 0;
      for (final key in box.keys) {
        final r = box.get(key);
        if (r != null) {
          await RunbooksDao.upsert(r);
          count++;
        }
      }
      await box.close();
      debugPrint('[HiveMigrator] runbooks: $count 条');
      return count;
    } catch (e) {
      debugPrint('[HiveMigrator] runbooks 迁移失败: $e');
      return 0;
    }
  }

  static Future<int> _migrateSettings() async {
    try {
      final box = await Hive.openBox('settings');
      if (box.isEmpty) { await box.close(); return 0; }
      var count = 0;
      for (final key in box.keys) {
        final value = box.get(key);
        if (value != null) {
          // Hive settings 的 value 可能是 String/int/bool/double/Map/List
          // 统一用 JSON 编码存储
          dynamic encoded;
          if (value is String) {
            // 字符串可能是 JSON 也可能是纯文本
            try {
              jsonDecode(value); // 验证是否 JSON
              encoded = value;   // 已是 JSON 字符串，直接存
            } catch (_) {
              encoded = jsonEncode(value); // 纯文本，包成 JSON 字符串
            }
          } else {
            encoded = jsonEncode(value);
          }
          await DbInit.db.insert('settings', {'key': key.toString(), 'value': encoded},
              conflictAlgorithm: ConflictAlgorithm.replace);
          count++;
        }
      }
      await box.close();
      debugPrint('[HiveMigrator] settings: $count 条');
      return count;
    } catch (e) {
      debugPrint('[HiveMigrator] settings 迁移失败: $e');
      return 0;
    }
  }

  static Future<int> _migrateAuditLogs() async {
    try {
      final box = await Hive.openBox('auditLogs');
      if (box.isEmpty) { await box.close(); return 0; }
      var count = 0;
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is Map) {
          await AuditLogsDao.add(
            hostId: raw['hostId'] as String? ?? 'unknown',
            command: raw['command'] as String? ?? '',
            safetyLevel: raw['safetyLevel'] as String? ?? 'safe',
            output: raw['output'] as String?,
            executed: raw['executed'] as bool? ?? false,
          );
          count++;
        }
      }
      await box.close();
      debugPrint('[HiveMigrator] auditLogs: $count 条');
      return count;
    } catch (e) {
      debugPrint('[HiveMigrator] auditLogs 迁移失败: $e');
      return 0;
    }
  }

  static Future<int> _migrateCredentialsFallback() async {
    try {
      final box = await Hive.openBox<String>('credentials_fallback');
      if (box.isEmpty) { await box.close(); return 0; }
      var count = 0;
      for (final key in box.keys) {
        final value = box.get(key);
        if (value != null) {
          await CredentialsFallbackDao.put(key.toString(), value);
          count++;
        }
      }
      await box.close();
      debugPrint('[HiveMigrator] credentials_fallback: $count 条');
      return count;
    } catch (e) {
      debugPrint('[HiveMigrator] credentials_fallback 迁移失败: $e');
      return 0;
    }
  }
}
