import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:io';
import '../services/daos.dart';

/// 应用主数据库初始化（替代 HiveInit）
///
/// 使用 SQLite 存储所有应用数据，schema 版本化管理。
/// 升级时通过 onUpgrade 回调做增量迁移。
class DbInit {
  static Database? _db;
  static const int _schemaVersion = 1;

  /// 数据库文件名
  static const String dbFileName = 'app_data.db';

  static bool get isInitialized => _db != null;

  /// 获取数据库实例（必须先调用 init）
  static Database get db {
    assert(_db != null, 'DbInit 未初始化，请先调用 DbInit.init()');
    return _db!;
  }

  /// 初始化数据库
  static Future<void> init() async {
    if (_db != null) return;

    // 桌面端使用 sqflite_ffi
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await _getDbPath();
    final dbDir = Directory(p.dirname(dbPath));
    if (!await dbDir.exists()) {
      await dbDir.create(recursive: true);
    }

    _db = await openDatabase(
      dbPath,
      version: _schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );

    // 加载所有 DAO 内存缓存（供 sync 读路径使用）
    await _loadAllCaches();

    debugPrint('[DbInit] 初始化成功: $dbPath (v$_schemaVersion)');
  }

  /// 获取数据库存储路径
  static Future<String> _getDbPath() async {
    final appDir = await getApplicationSupportDirectory();
    return p.join(appDir.path, dbFileName);
  }

  /// 首次创建数据库：建所有表
  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    // ===== hosts =====
    batch.execute('''
      CREATE TABLE hosts (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        username TEXT NOT NULL,
        authType TEXT NOT NULL,
        "group" TEXT NOT NULL DEFAULT '默认',
        tagColor TEXT,
        jumpHost TEXT,
        jumpPort INTEGER NOT NULL DEFAULT 22,
        jumpUsername TEXT,
        jumpAuthType TEXT,
        timeout INTEGER NOT NULL DEFAULT 30,
        encoding TEXT NOT NULL DEFAULT 'utf-8',
        createdAt INTEGER NOT NULL,
        lastConnectedAt INTEGER,
        lastStatus TEXT
      )
    ''');

    // ===== ai_models =====
    batch.execute('''
      CREATE TABLE ai_models (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        name TEXT NOT NULL,
        apiKey TEXT NOT NULL,
        baseUrl TEXT NOT NULL,
        modelName TEXT NOT NULL,
        temperature REAL NOT NULL DEFAULT 0.3,
        maxTokens INTEGER NOT NULL DEFAULT 4096,
        isDefault INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // ===== chat_sessions =====
    batch.execute('''
      CREATE TABLE chat_sessions (
        id TEXT PRIMARY KEY,
        hostId TEXT,
        messages TEXT NOT NULL DEFAULT '[]',
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');

    // ===== snippets =====
    batch.execute('''
      CREATE TABLE snippets (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        command TEXT NOT NULL,
        description TEXT,
        variables TEXT NOT NULL DEFAULT '[]',
        createdAt INTEGER NOT NULL
      )
    ''');

    // ===== conversations =====
    batch.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        hostId TEXT NOT NULL,
        title TEXT NOT NULL,
        messages TEXT NOT NULL DEFAULT '[]',
        agentLogs TEXT NOT NULL DEFAULT '[]',
        summary TEXT,
        summarizedUpToIndex INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        isActive INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute('CREATE INDEX idx_conversations_hostId ON conversations(hostId)');
    batch.execute('CREATE INDEX idx_conversations_isActive ON conversations(isActive)');

    // ===== change_records =====
    batch.execute('''
      CREATE TABLE change_records (
        id TEXT PRIMARY KEY,
        hostId TEXT NOT NULL,
        command TEXT NOT NULL,
        type TEXT NOT NULL,
        rollbackCommand TEXT,
        rollbackDescription TEXT,
        timestamp INTEGER NOT NULL,
        success INTEGER NOT NULL,
        username TEXT,
        conversationId TEXT,
        rolledBack INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute('CREATE INDEX idx_change_records_hostId ON change_records(hostId)');
    batch.execute('CREATE INDEX idx_change_records_timestamp ON change_records(timestamp)');

    // ===== runbooks =====
    batch.execute('''
      CREATE TABLE runbooks (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        icon TEXT NOT NULL,
        description TEXT,
        type TEXT NOT NULL,
        category TEXT NOT NULL,
        content TEXT NOT NULL,
        isBuiltin INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        runCount INTEGER NOT NULL DEFAULT 0,
        lastRunAt INTEGER
      )
    ''');

    // ===== settings (KV) =====
    batch.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    // ===== audit_logs =====
    batch.execute('''
      CREATE TABLE audit_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        hostId TEXT NOT NULL,
        command TEXT NOT NULL,
        safetyLevel TEXT NOT NULL,
        output TEXT,
        executed INTEGER NOT NULL
      )
    ''');
    batch.execute('CREATE INDEX idx_audit_logs_hostId ON audit_logs(hostId)');
    batch.execute('CREATE INDEX idx_audit_logs_timestamp ON audit_logs(timestamp)');

    // ===== credentials_fallback =====
    // 存 AES 加密后的密文（ivBase64:cipherBase64），与旧 Hive 兼容
    batch.execute('''
      CREATE TABLE credentials_fallback (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // ===== migration_flag =====
    // 标记 Hive→SQLite 迁移是否完成，避免重复迁移
    batch.execute('''
      CREATE TABLE migration_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await batch.commit(noResult: true);
  }

  /// 升级数据库（未来版本在此追加迁移脚本）
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 示例：
    // if (oldVersion < 2) {
    //   await db.execute('ALTER TABLE hosts ADD COLUMN newField TEXT');
    // }
  }

  /// 关闭数据库
  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// 加载所有 DAO 内存缓存
  /// 在 init() 和 migrate() 之后调用，保证 sync 读路径数据可用
  static Future<void> _loadAllCaches() async {
    await reloadCaches();
  }

  /// 重新加载所有 DAO 内存缓存（迁移后调用，保证缓存与数据库一致）
  static Future<void> reloadCaches() async {
    await Future.wait([
      HostsDao.loadCache(),
      AIModelsDao.loadCache(),
      ChatSessionsDao.loadCache(),
      SnippetsDao.loadCache(),
      ConversationsDao.loadCache(),
      ChangeRecordsDao.loadCache(),
      RunbooksDao.loadCache(),
      SettingsDao.loadCache(),
      AuditLogsDao.loadCache(),
    ]);
  }
}
