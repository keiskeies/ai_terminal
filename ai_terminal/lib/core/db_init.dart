import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'dart:io';
import '../services/daos.dart';
import 'credentials_store.dart';

/// 应用主数据库初始化（替代 HiveInit）
///
/// 使用 SQLite 存储所有应用数据，schema 版本化管理。
/// 全库加密：通过 SQLite3MultipleCiphers (sqlite3mc) 实现，密码为 OS 主密钥。
/// 升级时通过 onUpgrade 回调做增量迁移。
class DbInit {
  static Database? _db;
  static const int _schemaVersion = 4;

  /// 数据库文件名
  static const String dbFileName = 'app_data.db';

  /// 旧明文 DB 迁移后的备份后缀
  static const String _dbBackupSuffix = '.bak';

  static bool get isInitialized => _db != null;

  /// 获取数据库实例（必须先调用 init）
  static Database get db {
    assert(_db != null, 'DbInit 未初始化，请先调用 DbInit.init()');
    return _db!;
  }

  /// 初始化数据库
  ///
  /// 前置条件：必须先调用 [CredentialsStore.loadMasterKey] 获取 OS 主密钥
  /// （主密钥用作 SQLCipher/sqlite3mc 全库加密的密码）
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

    // 获取数据库加密密码（基于 OS 主密钥）
    final password = CredentialsStore.getDatabasePassword();

    // 检测旧明文 DB 并迁移到加密格式（仅首次升级时执行）
    await _migratePlaintextDbIfNeeded(dbPath, password);

    // 尝试打开加密 DB；若密钥不匹配（ad-hoc 重签名导致 Keychain 主密钥变化），
    // 直接删除旧加密 DB 并新建 — 绝不从 .bak 恢复，否则每次密钥变化都会
    // 把数据库回退到 .bak 的旧状态，丢失用户在旧密钥期间产生的所有数据。
    try {
      _db = await _openEncryptedDb(dbPath, password);
    } catch (e) {
      debugPrint('[DbInit] 打开加密 DB 失败（密钥可能变化），新建空 DB: $e');
      // 备份无法解密的 DB（用户后续可手动找回数据），再删除让 onCreate 重建
      await _archiveUnopenableDb(dbPath);
      _db = await _openEncryptedDb(dbPath, password);
    }

    // 加载所有 DAO 内存缓存（供 sync 读路径使用）
    await _loadAllCaches();

    debugPrint('[DbInit] 初始化成功: $dbPath (v$_schemaVersion, encrypted)');
  }

  /// 打开加密 DB（设置 PRAGMA key）
  static Future<Database> _openEncryptedDb(String dbPath, String password) {
    return openDatabase(
      dbPath,
      version: _schemaVersion,
      onConfigure: (db) async {
        // 加密 DB 必须在连接后立即设置 key（sqlite3mc 兼容 SQLCipher）
        // PRAGMA key 必须是连接后的第一条语句
        await db.execute("PRAGMA key = '${_escapeSqlString(password)}';");
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 备份无法打开的加密 DB（用户后续可手动恢复数据），然后删除让 onCreate 重建
  ///
  /// 重要：**绝不用 .bak 覆盖当前 DB**。
  /// 旧实现从 .bak 明文备份恢复，导致每次 Keychain 主密钥变化（ad-hoc 重签名）
  /// 都把数据库回退到 .bak 的状态，丢失用户在旧密钥期间产生的所有数据。
  /// 现在改为：保留旧加密 DB 为 `.unopenable-{timestamp}.db`（供事后调查），
  /// 删除当前 dbPath，让 _openEncryptedDb 的 onCreate 重新创建空 DB。
  static Future<void> _archiveUnopenableDb(String dbPath) async {
    final dbFile = File(dbPath);
    if (!await dbFile.exists()) return;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final archivePath = '$dbPath.unopenable-$timestamp.db';
    try {
      await dbFile.rename(archivePath);
      debugPrint('[DbInit] 无法打开的加密 DB 已归档: $archivePath');
      // 仅保留最近 1 个归档，避免磁盘堆积
      final dir = Directory(p.dirname(dbPath));
      await for (final entity in dir.list()) {
        final name = p.basename(entity.path);
        if (name.startsWith('$dbFileName.unopenable-') &&
            name.endsWith('.db') &&
            entity.path != archivePath) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[DbInit] 归档失败，直接删除: $e');
      try {
        await dbFile.delete();
      } catch (_) {}
    }
  }

  /// 检测旧明文 DB 并迁移到加密格式
  ///
  /// 判断逻辑：读取 DB 文件头部 16 字节，明文 SQLite 以 "SQLite format 3\0" 开头。
  /// 若为明文：
  /// 1. 用无密码方式打开旧 DB，读取所有表 schema 和数据到内存
  /// 2. 关闭旧 DB，重命名为 .bak 备份
  /// 3. 用密码创建新加密 DB，重建 schema 并写入数据
  ///
  /// 重要：**只在 dbPath 是明文 SQLite 时触发**。
  /// 旧实现的"恢复中断迁移"分支（.bak 存在但 dbPath 不存在时把 .bak 重命名为 dbPath）
  /// 会导致用户每次重装/Keychain 重置后，数据库被回退到 .bak 的旧状态。
  /// 现在改为：dbPath 不存在就直接新建，绝不把 .bak 当 dbPath 用。
  /// .bak 仅作为只读历史快照保留，不再参与自动恢复流程。
  static Future<void> _migratePlaintextDbIfNeeded(
    String dbPath,
    String password,
  ) async {
    final dbFile = File(dbPath);
    final backupPath = '$dbPath$_dbBackupSuffix';
    final backupFile = File(backupPath);

    if (!await dbFile.exists()) {
      return; // 新建 DB，无需迁移
    }

    // 读取文件头部 16 字节判断是否明文 SQLite
    final raf = await dbFile.open();
    try {
      final header = await raf.read(16);
      // SQLite 明文文件头："SQLite format 3\0"
      const sqliteHeader = [
        0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
        0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
      ];
      bool isPlaintext = header.length == 16;
      for (int i = 0; isPlaintext && i < 16; i++) {
        if (header[i] != sqliteHeader[i]) {
          isPlaintext = false;
        }
      }
      if (!isPlaintext) {
        return; // 已加密或非 SQLite 文件，无需迁移
      }
    } finally {
      await raf.close();
    }

    debugPrint('[DbInit] 检测到明文 DB，开始迁移到加密格式...');

    // 1. 用无密码方式打开旧 DB，读取所有表数据
    final List<Map<String, dynamic>> tableData = [];
    final List<String> schemaSqls = [];

    final oldDb = await openDatabase(dbPath, readOnly: true);
    try {
      // 获取所有用户表的 schema（排除 sqlite_ 内部表和 android_metadata）
      final tables = await oldDb.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
      );
      for (final t in tables) {
        final name = t['name'] as String;
        final sql = t['sql'] as String?;
        if (sql != null) {
          schemaSqls.add(sql);
        }
        final rows = await oldDb.query(name);
        tableData.add({'name': name, 'rows': rows});
        debugPrint('[DbInit] 读取表 $name: ${rows.length} 行');
      }
      // 获取所有索引的 schema
      final indexes = await oldDb.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL",
      );
      for (final idx in indexes) {
        final sql = idx['sql'] as String?;
        if (sql != null) {
          schemaSqls.add(sql);
        }
      }
    } finally {
      await oldDb.close();
    }

    // 2. 重命名旧 DB 为 .bak（若已存在 .bak 则先删除）
    if (await backupFile.exists()) {
      await backupFile.delete();
    }
    await dbFile.rename(backupPath);
    debugPrint('[DbInit] 旧明文 DB 已备份到: $backupPath');

    // 3. 创建新的加密 DB 并写入数据
    final newDb = await openDatabase(
      dbPath,
      version: _schemaVersion,
      onConfigure: (db) async {
        await db.execute("PRAGMA key = '${_escapeSqlString(password)}';");
      },
      onCreate: (db, version) async {
        // 重建所有 schema（表 + 索引）
        final batch = db.batch();
        for (final sql in schemaSqls) {
          batch.execute(sql);
        }
        await batch.commit(noResult: true);

        // 写入数据
        for (final td in tableData) {
          final name = td['name'] as String;
          final rows = td['rows'] as List<Map<String, dynamic>>;
          if (rows.isEmpty) continue;
          final batch = db.batch();
          for (final row in rows) {
            batch.insert(name, row);
          }
          await batch.commit(noResult: true);
          debugPrint('[DbInit] 写入表 $name: ${rows.length} 行');
        }
      },
    );
    await newDb.close();

    debugPrint('[DbInit] 加密 DB 创建成功，明文→加密迁移完成');
  }

  /// 转义 SQL 字符串中的单引号（防止密码中的特殊字符导致 SQL 注入）
  /// base64 编码不包含单引号，但保留此防御性转义以应对未来变更
  static String _escapeSqlString(String s) {
    return s.replaceAll("'", "''");
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
        contextWindow INTEGER NOT NULL DEFAULT 0,
        fallbackModelId TEXT,
        supportsFunctionCalling INTEGER NOT NULL DEFAULT 0,
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
    // v2: ai_models 添加 contextWindow 字段（用于 token-aware 上下文裁剪）
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE ai_models ADD COLUMN contextWindow INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v3: ai_models 添加 fallbackModelId 字段（用于主模型失败时切换备用模型）
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE ai_models ADD COLUMN fallbackModelId TEXT',
      );
    }
    // v4: ai_models 添加 supportsFunctionCalling 字段（P2-6: 原生 Function Calling 支持）
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE ai_models ADD COLUMN supportsFunctionCalling INTEGER NOT NULL DEFAULT 0',
      );
    }
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
