import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import '../models/software_guide.dart';
import 'daos.dart';

/// 知识库配置
class KnowledgeConfig {
  /// 本地数据库文件名（官方库，随 app 内置版本刷新）
  static const String dbFileName = 'knowledge.db';

  /// 内置库版本标记文件名（记录本地库对应的 app 版本）
  static const String versionMarkerFileName = 'knowledge.version';

  /// 用户经验库文件名（独立文件，不随内置库刷新）
  static const String userDbFileName = 'user_learnings.db';

  /// 内置数据库的 asset 路径
  static const String bundledAssetPath = 'assets/knowledge/knowledge.db';

  /// FTS5 命中阈值（低于此分数不注入知识库）
  static const double matchThreshold = 0.3;

  /// 最大返回条目数
  static const int maxResults = 3;

  /// 用户经验库容量上限（R8：必须有上限防止无限增长）
  static const int userLearningsCapacity = 500;

  /// 超过容量时淘汰的条目数
  static const int userLearningsEvictBatch = 50;
}

/// 按需检索条目（[KnowledgeService.searchKnowledge] 返回，供 knowledge_search 工具使用）
///
/// 与注入用的 [KnowledgeSearchResult] 分开：工具输出需要区分条目来源
/// （本机验证经验 vs 官方库），让模型知道哪些命令在当前环境实际跑通过。
class KnowledgeSearchEntry {
  final SoftwareGuide guide;

  /// FTS5 相关性分数（已取绝对值；LIKE 回退命中为 0）
  final double score;

  /// true = 用户经验库（本机/同类环境验证过），false = 官方知识库
  final bool isUserExperience;

  const KnowledgeSearchEntry({
    required this.guide,
    required this.score,
    required this.isUserExperience,
  });
}

/// 知识库服务 — SQLite FTS5 全文搜索 + 内置库 + 用户经验库
class KnowledgeService {
  static final KnowledgeService _instance = KnowledgeService._internal();
  factory KnowledgeService() => _instance;
  KnowledgeService._internal();

  Database? _db;
  /// 用户经验库（独立 db 文件，不受内置库刷新影响）
  Database? _userDb;
  bool _initialized = false;
  bool _initializing = false;

  /// 获取数据库实例
  Database? get db => _db;
  /// 获取用户经验库实例
  Database? get userDb => _userDb;
  bool get isInitialized => _initialized;

  /// 初始化知识库
  /// 1. 本地库缺失，或版本标记与当前 app 版本不一致时，从内置 assets 重建
  /// 2. 打开本地数据库，验证 FTS5 索引
  /// 3. 初始化独立的用户经验库
  Future<void> init() async {
    if (_initialized) return;
    if (_initializing) {
      // 防止并发初始化：等待另一个 init 完成
      while (_initializing) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return;
    }

    _initializing = true;

    try {
      // 初始化 sqflite_ffi（桌面端需要）
      _initSqfliteFfi();

      final dbPath = await _getLocalDbPath();
      final dbFile = File(dbPath);
      final dbDir = Directory(p.dirname(dbPath));

      // 确保目录存在
      if (!await dbDir.exists()) {
        await dbDir.create(recursive: true);
      }

      // 内置库随 app 版本发布，版本标记不一致即视为过期，需重建
      final appVersion = await _getAppVersion();
      final isStale = !await dbFile.exists() ||
          !await _isBundledVersionCurrent(dbPath, appVersion);
      if (isStale) {
        if (await dbFile.exists()) {
          debugPrint('[KnowledgeService] 本地知识库版本过期（app $appVersion），从内置 assets 重建...');
          await dbFile.delete();
        }
        await _copyBundledDb(dbPath);
        await _writeBundledVersion(dbPath, appVersion);
      }

      // 打开数据库
      _db = await openDatabase(
        dbPath,
        version: 1,
        onCreate: _onCreate,
      );

      // 验证 FTS5 索引是否存在
      await _validateFts5Index();

      // 检查数据库是否为空——如果为空，说明是旧版本遗留的空库，需要从 assets 重建
      final recordCount = await _getRecordCount();
      if (recordCount == 0) {
        debugPrint('[KnowledgeService] 数据库为空（旧版本遗留），从 assets 重建...');
        await _db!.close();
        _db = null;
        // 删除空库
        if (await dbFile.exists()) {
          await dbFile.delete();
        }
        // 从 assets 重新复制
        await _copyBundledDb(dbPath);
        await _writeBundledVersion(dbPath, appVersion);
        // 重新打开
        _db = await openDatabase(dbPath, version: 1, onCreate: _onCreate);
        await _validateFts5Index();
      }

      // 初始化用户经验库（独立文件，不参与内置库刷新）
      await _initUserLearningsDb();

      _initialized = true;

      // 打印统计信息
      final stats = await getStats();
      debugPrint('[KnowledgeService] 初始化成功，数据库路径: $dbPath，共 ${stats['total']} 条记录');
    } catch (e) {
      debugPrint('[KnowledgeService] 初始化失败: $e');
      _initialized = false;
    } finally {
      _initializing = false;
    }
  }

  /// 确保知识库已初始化（懒初始化，用于 agent_engine 等调用方）
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    await init();
  }

  /// 初始化 sqflite_ffi（桌面端）
  void _initSqfliteFfi() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  /// 获取本地数据库存储路径
  Future<String> _getLocalDbPath() async {
    final appDir = await getApplicationSupportDirectory();
    return p.join(appDir.path, 'knowledge', KnowledgeConfig.dbFileName);
  }

  /// 获取当前 app 版本号（内置知识库随 app 版本刷新）
  Future<String> _getAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version; // e.g. "1.3.3"
    } catch (e) {
      debugPrint('[KnowledgeService] 获取版本号失败: $e');
      return '';
    }
  }

  /// 版本标记文件路径（与数据库同目录）
  String _versionMarkerPath(String dbPath) =>
      p.join(p.dirname(dbPath), KnowledgeConfig.versionMarkerFileName);

  /// 本地库是否已对应当前 app 版本
  /// 版本号取不到时视为当前，避免启动失败导致反复重建
  Future<bool> _isBundledVersionCurrent(
      String dbPath, String appVersion) async {
    if (appVersion.isEmpty) return true;
    try {
      final marker = File(_versionMarkerPath(dbPath));
      if (!await marker.exists()) return false;
      return (await marker.readAsString()).trim() == appVersion;
    } catch (e) {
      debugPrint('[KnowledgeService] 读取版本标记失败: $e');
      return false;
    }
  }

  /// 写入版本标记（失败只导致下次启动多重建一次）
  Future<void> _writeBundledVersion(String dbPath, String appVersion) async {
    if (appVersion.isEmpty) return;
    try {
      await File(_versionMarkerPath(dbPath)).writeAsString(appVersion, flush: true);
    } catch (e) {
      debugPrint('[KnowledgeService] 写入版本标记失败: $e');
    }
  }

  /// 从内置 assets 复制数据库（使用 rootBundle 加载字节流）
  Future<void> _copyBundledDb(String dbPath) async {
    try {
      debugPrint('[KnowledgeService] 正在从内置 assets 复制数据库...');
      final byteData = await rootBundle.load(KnowledgeConfig.bundledAssetPath);
      final bytes = byteData.buffer.asUint8List();
      await File(dbPath).writeAsBytes(bytes, flush: true);
      debugPrint('[KnowledgeService] 从内置 assets 复制数据库完成，大小: ${bytes.length} bytes');
    } catch (e) {
      debugPrint('[KnowledgeService] 从内置 assets 复制数据库失败: $e');
      // 兜底：创建空数据库
      await _createEmptyDb(dbPath);
    }
  }

  /// 创建空数据库（含表结构和 FTS5 索引）
  Future<void> _createEmptyDb(String dbPath) async {
    debugPrint('[KnowledgeService] 创建空数据库...');
    final db = await openDatabase(dbPath, version: 1, onCreate: _onCreate);
    await db.close();
  }

  /// 初始化用户经验库（独立 db 文件，不受内置库刷新影响）
  Future<void> _initUserLearningsDb() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final dbPath = p.join(appDir.path, 'knowledge', KnowledgeConfig.userDbFileName);
      final dbDir = Directory(p.dirname(dbPath));
      if (!await dbDir.exists()) {
        await dbDir.create(recursive: true);
      }
      _userDb = await openDatabase(dbPath, version: 1, onCreate: _onCreateUserLearnings);
      // 验证 FTS5 索引
      try {
        await _userDb!.rawQuery('SELECT count(*) as c FROM user_learnings_fts LIMIT 1');
      } catch (e) {
        debugPrint('[KnowledgeService] 用户经验库 FTS5 索引缺失，重建: $e');
        await _onCreateUserLearnings(_userDb!, 1);
      }
      final count = await _userDb!.rawQuery('SELECT count(*) as c FROM user_learnings');
      final total = (count.first['c'] as int?) ?? 0;
      debugPrint('[KnowledgeService] 用户经验库初始化成功，共 $total 条经验');
    } catch (e) {
      debugPrint('[KnowledgeService] 用户经验库初始化失败: $e');
    }
  }

  /// 创建用户经验库表和 FTS5 索引
  Future<void> _onCreateUserLearnings(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_learnings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        host_id TEXT DEFAULT '',
        software_name TEXT NOT NULL DEFAULT '',
        op_type TEXT NOT NULL DEFAULT 'install',
        platform TEXT DEFAULT 'linux',
        summary TEXT DEFAULT '',
        commands TEXT DEFAULT '',
        notes TEXT DEFAULT '',
        source TEXT DEFAULT 'agent',
        created_at INTEGER NOT NULL,
        hit_count INTEGER DEFAULT 0,
        last_used_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS user_learnings_fts USING fts5(
        software_name,
        op_type,
        platform,
        summary,
        commands,
        notes,
        content=user_learnings,
        content_rowid=id
      )
    ''');

    // FTS5 自动同步触发器
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS user_learnings_ai AFTER INSERT ON user_learnings BEGIN
        INSERT INTO user_learnings_fts(rowid, software_name, op_type, platform, summary, commands, notes)
        VALUES (new.id, new.software_name, new.op_type, new.platform, new.summary, new.commands, new.notes);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS user_learnings_ad AFTER DELETE ON user_learnings BEGIN
        INSERT INTO user_learnings_fts(user_learnings_fts, rowid, software_name, op_type, platform, summary, commands, notes)
        VALUES ('delete', old.id, old.software_name, old.op_type, old.platform, old.summary, old.commands, old.notes);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS user_learnings_au AFTER UPDATE ON user_learnings BEGIN
        INSERT INTO user_learnings_fts(user_learnings_fts, rowid, software_name, op_type, platform, summary, commands, notes)
        VALUES ('delete', old.id, old.software_name, old.op_type, old.platform, old.summary, old.commands, old.notes);
        INSERT INTO user_learnings_fts(rowid, software_name, op_type, platform, summary, commands, notes)
        VALUES (new.id, new.software_name, new.op_type, new.platform, new.summary, new.commands, new.notes);
      END
    ''');
  }

  /// 创建数据库表和 FTS5 索引
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS software_guides (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        software_name TEXT NOT NULL,
        aliases TEXT DEFAULT '',
        op_type TEXT NOT NULL DEFAULT 'install',
        platform TEXT DEFAULT 'linux',
        package_manager TEXT DEFAULT '',
        summary TEXT DEFAULT '',
        steps TEXT DEFAULT '',
        commands TEXT DEFAULT '',
        pre_requirements TEXT DEFAULT '',
        notes TEXT DEFAULT '',
        mode TEXT DEFAULT 'strict'
      )
    ''');

    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS guides_fts USING fts5(
        software_name,
        aliases,
        op_type,
        platform,
        package_manager,
        summary,
        commands,
        content=software_guides,
        content_rowid=id
      )
    ''');

    // FTS5 自动同步触发器
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS guides_ai AFTER INSERT ON software_guides BEGIN
        INSERT INTO guides_fts(rowid, software_name, aliases, op_type, platform, package_manager, summary, commands)
        VALUES (new.id, new.software_name, new.aliases, new.op_type, new.platform, new.package_manager, new.summary, new.commands);
      END
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS guides_ad AFTER DELETE ON software_guides BEGIN
        INSERT INTO guides_fts(guides_fts, rowid, software_name, aliases, op_type, platform, package_manager, summary, commands)
        VALUES ('delete', old.id, old.software_name, old.aliases, old.op_type, old.platform, old.package_manager, old.summary, old.commands);
      END
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS guides_au AFTER UPDATE ON software_guides BEGIN
        INSERT INTO guides_fts(guides_fts, rowid, software_name, aliases, op_type, platform, package_manager, summary, commands)
        VALUES ('delete', old.id, old.software_name, old.aliases, old.op_type, old.platform, old.package_manager, old.summary, old.commands);
        INSERT INTO guides_fts(rowid, software_name, aliases, op_type, platform, package_manager, summary, commands)
        VALUES (new.id, new.software_name, new.aliases, new.op_type, new.platform, new.package_manager, new.summary, new.commands);
      END
    ''');
  }

  /// 验证 FTS5 索引
  Future<void> _validateFts5Index() async {
    if (_db == null) return;
    try {
      final result = await _db!.rawQuery('SELECT count(*) as c FROM guides_fts LIMIT 1');
      final count = result.first['c'] as int;
      debugPrint('[KnowledgeService] FTS5 索引验证通过，索引条目数: $count');
    } catch (e) {
      debugPrint('[KnowledgeService] FTS5 索引不存在，尝试重建: $e');
      await _onCreate(_db!, 1);
    }
  }

  /// 记录一次成功的任务经验到用户经验库
  /// 由 agent_provider 在任务完成（onCompleted）时调用
  /// [userRequest] 用户原始请求（用于提取软件名和操作类型）
  /// [executedCommands] 实际执行成功的命令（换行分隔）
  /// [aiSummary] AI 的完成总结
  Future<void> recordLearning({
    String? hostId,
    required String userRequest,
    required String executedCommands,
    required String aiSummary,
    String? platform,
  }) async {
    if (_userDb == null) {
      debugPrint('[KnowledgeService] recordLearning 跳过: 用户经验库未初始化');
      return;
    }
    // 空请求或空命令不记录（无价值）
    if (userRequest.trim().isEmpty || executedCommands.trim().isEmpty) {
      return;
    }

    try {
      // 提取软件名和操作类型（复用现有启发式）
      final opType = extractOpType(userRequest) ?? 'install';
      final keywords = _extractKeywords(userRequest);
      final softwareName = keywords.isNotEmpty ? keywords.first : 'unknown';
      final effectivePlatform = platform ?? detectPlatform() ?? 'linux';

      // R8: 容量上限检查，超限则淘汰最久未用 + 命中次数最少的
      final countResult = await _userDb!.rawQuery('SELECT count(*) as c FROM user_learnings');
      final total = (countResult.first['c'] as int?) ?? 0;
      if (total >= KnowledgeConfig.userLearningsCapacity) {
        await _userDb!.rawDelete(
          'DELETE FROM user_learnings WHERE id IN ('
          'SELECT id FROM user_learnings ORDER BY hit_count ASC, last_used_at ASC LIMIT ?)',
          [KnowledgeConfig.userLearningsEvictBatch],
        );
        debugPrint('[KnowledgeService] 用户经验库超容，淘汰 ${KnowledgeConfig.userLearningsEvictBatch} 条');
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      await _userDb!.insert('user_learnings', {
        'host_id': hostId ?? '',
        'software_name': softwareName,
        'op_type': opType,
        'platform': effectivePlatform,
        'summary': aiSummary.isNotEmpty ? aiSummary : userRequest,
        'commands': executedCommands,
        'notes': '',
        'source': 'agent',
        'created_at': now,
        'hit_count': 0,
        'last_used_at': now,
      });
      debugPrint('[KnowledgeService] 记录经验: software=$softwareName, op=$opType, platform=$effectivePlatform');
    } catch (e) {
      debugPrint('[KnowledgeService] recordLearning 失败: $e');
    }
  }

  /// 搜索用户经验库（内部使用，结果会与官方库合并）
  /// [limit] 最大返回条数（默认与注入路径一致）
  Future<List<KnowledgeSearchResult>> _searchUserLearnings(
    String query, {
    String? opType,
    String? platform,
    String? hostId,
    int limit = KnowledgeConfig.maxResults,
  }) async {
    if (_userDb == null) return [];
    try {
      final keywords = _extractKeywords(query);
      if (keywords.isEmpty) return [];
      final ftsQuery = _ftsPrefixQuery(keywords);

      var where = '';
      final args = <dynamic>[ftsQuery];
      if (opType != null) {
        where += ' AND ul.op_type = ?';
        args.add(opType);
      }
      if (platform != null) {
        where += ' AND (ul.platform = ? OR ul.platform = ?)';
        args.add(platform);
        args.add('all');
      }

      // 同 host 的经验优先（实际验证过），其次通用经验
      var orderClause = 'ORDER BY ft.rank';
      if (hostId != null && hostId.isNotEmpty) {
        orderClause = 'ORDER BY (ul.host_id = ?) DESC, ft.rank';
        args.add(hostId);
      }

      final results = await _userDb!.rawQuery('''
        SELECT ul.*, ft.rank as score
        FROM user_learnings_fts ft
        JOIN user_learnings ul ON ft.rowid = ul.id
        WHERE user_learnings_fts MATCH ? $where
        $orderClause
        LIMIT ?
      ''', [...args, limit]);

      // 更新命中次数和最后使用时间（后台执行，不阻塞）
      if (results.isNotEmpty) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final ids = results.map((r) => r['id'] as int).toList();
        for (final id in ids) {
          await _userDb!.rawUpdate(
            'UPDATE user_learnings SET hit_count = hit_count + 1, last_used_at = ? WHERE id = ?',
            [now, id],
          );
        }
      }

      return results.map((row) {
        final score = (row['score'] as num?)?.toDouble() ?? 0.0;
        return KnowledgeSearchResult(
          guide: SoftwareGuide(
            softwareName: row['software_name'] as String? ?? '',
            opType: row['op_type'] as String? ?? 'install',
            platform: row['platform'] as String? ?? 'linux',
            summary: row['summary'] as String? ?? '',
            commands: row['commands'] as String? ?? '',
            notes: row['notes'] as String? ?? '',
            mode: 'flexible',
          ),
          score: score.abs(),
        );
      }).toList();
    } catch (e) {
      debugPrint('[KnowledgeService] _searchUserLearnings 失败: $e');
      return [];
    }
  }

  /// FTS5 前缀查询串：每个关键词包成引号字面量，再做前缀匹配。
  ///
  /// 裸拼 `'$k*'` 会把关键词当成 FTS5 查询语法解析：`-p` 是 NOT 运算符、
  /// `'continue?` 是字符串字面量起点，整条 MATCH 直接报
  /// `SQL logic error: no such column: p`（真机验证：命令里带 `-p` 的请求
  /// 让用户经验库与软件库检索全部降级到 LIKE）。引号内的内容只按字面处理。
  static String _ftsPrefixQuery(List<String> keywords) => keywords
      .map((k) => '"${k.replaceAll('"', '""')}"*')
      .join(' AND ');

  /// 获取用户经验库统计
  Future<int> getUserLearningsCount() async {
    if (_userDb == null) return 0;
    try {
      final result = await _userDb!.rawQuery('SELECT count(*) as c FROM user_learnings');
      return (result.first['c'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 全文搜索知识库
  /// [query] 搜索关键词（原始用户输入）
  /// [opType] 可选的操作类型过滤（install/uninstall/update/configure）
  /// [platform] 可选的平台过滤
  /// [limit] 最大返回条数（默认与注入路径一致）
  Future<List<KnowledgeSearchResult>> search(
    String query, {
    String? opType,
    String? platform,
    int limit = KnowledgeConfig.maxResults,
  }) async {
    if (!_initialized || _db == null) {
      debugPrint('[KnowledgeService] search 跳过: initialized=$_initialized, db=${_db != null}');
      return [];
    }

    try {
      // 清理查询：去除特殊字符，拆分为关键词
      final keywords = _extractKeywords(query);
      if (keywords.isEmpty) {
        debugPrint('[KnowledgeService] 搜索: 无有效关键词 (输入: "$query")');
        return [];
      }

      // 构建 FTS5 查询：关键词之间 AND 连接，使用前缀搜索
      // FTS5 语法: "term"* 表示字面量前缀匹配
      final ftsQuery = _ftsPrefixQuery(keywords);

      debugPrint('[KnowledgeService] 搜索: keywords=$keywords, ftsQuery="$ftsQuery", opType=$opType, platform=$platform');

      // 附加条件
      var where = '';
      final args = <dynamic>[];

      if (opType != null) {
        where += ' AND sg.op_type = ?';
        args.add(opType);
      }
      // platform 匹配：精确匹配 + 前缀匹配（linux 匹配 linux-debian/linux-rhel）+ all
      if (platform != null) {
        where += ' AND (sg.platform = ? OR sg.platform LIKE ? OR sg.platform = ?)';
        args.add(platform);
        args.add('$platform-%');
        args.add('all');
      }

      // 先尝试 FTS5 搜索
      List<Map<String, Object?>> results;
      try {
        results = await _db!.rawQuery('''
          SELECT sg.*, ft.rank as score
          FROM guides_fts ft
          JOIN software_guides sg ON ft.rowid = sg.id
          WHERE guides_fts MATCH ? $where
          ORDER BY ft.rank
          LIMIT ?
        ''', [ftsQuery, ...args, limit]);

        debugPrint('[KnowledgeService] FTS5 搜索结果: ${results.length} 条');
      } catch (e) {
        debugPrint('[KnowledgeService] FTS5 搜索失败，回退到 LIKE: $e');
        // FTS5 不可用时回退到 LIKE 搜索
        var likeWhere = <String>[];
        final likeArgs = <dynamic>[];
        for (final kw in keywords) {
          likeWhere.add('(sg.software_name LIKE ? OR sg.aliases LIKE ? OR sg.summary LIKE ?)');
          likeArgs.addAll(['%$kw%', '%$kw%', '%$kw%']);
        }
        if (opType != null) {
          likeWhere.add('sg.op_type = ?');
          likeArgs.add(opType);
        }
        if (platform != null) {
          likeWhere.add('(sg.platform = ? OR sg.platform LIKE ? OR sg.platform = ?)');
          likeArgs.addAll([platform, '$platform-%', 'all']);
        }
        results = await _db!.rawQuery('''
          SELECT sg.*, 0.0 as score
          FROM software_guides sg
          WHERE ${likeWhere.join(' AND ')}
          LIMIT ?
        ''', [...likeArgs, limit]);

        debugPrint('[KnowledgeService] LIKE 回退搜索结果: ${results.length} 条');
      }

      if (results.isEmpty) {
        // 尝试宽松搜索：只用第一个关键词，不过滤 opType
        if (keywords.length > 1 || opType != null) {
          debugPrint('[KnowledgeService] 尝试宽松搜索...');
          final looseFtsQuery = _ftsPrefixQuery([keywords.first]);

          List<Map<String, Object?>> looseResults;
          try {
            looseResults = await _db!.rawQuery('''
              SELECT sg.*, ft.rank as score
              FROM guides_fts ft
              JOIN software_guides sg ON ft.rowid = sg.id
              WHERE guides_fts MATCH ?
              ORDER BY ft.rank
              LIMIT ?
            ''', [looseFtsQuery, limit]);
          } catch (e) {
            // FTS5 不可用，LIKE 回退
            looseResults = await _db!.rawQuery('''
              SELECT sg.*, 0.0 as score
              FROM software_guides sg
              WHERE sg.software_name LIKE ? OR sg.aliases LIKE ? OR sg.summary LIKE ?
              LIMIT ?
            ''', ['%${keywords.first}%', '%${keywords.first}%', '%${keywords.first}%', limit]);
          }

          if (looseResults.isNotEmpty) {
            debugPrint('[KnowledgeService] 宽松搜索结果: ${looseResults.length} 条');
            return looseResults.map((row) {
              final score = (row['score'] as num?)?.toDouble() ?? 0.0;
              return KnowledgeSearchResult(
                guide: SoftwareGuide.fromMap(row),
                score: score.abs(),
              );
            }).toList();
          }
        }
        return [];
      }

      return results.map((row) {
        final score = (row['score'] as num?)?.toDouble() ?? 0.0;
        final normalizedScore = score.abs();
        return KnowledgeSearchResult(
          guide: SoftwareGuide.fromMap(row),
          score: normalizedScore,
        );
      }).toList();
    } catch (e) {
      debugPrint('[KnowledgeService] 搜索失败: $e');
      return [];
    }
  }

  /// 从用户输入中提取操作类型
  static String? extractOpType(String input) {
    final lower = input.toLowerCase();

    // 中文关键词
    if (lower.contains('卸载') || lower.contains('删除') || lower.contains('移除')) {
      return 'uninstall';
    }
    if (lower.contains('更新') || lower.contains('升级') || lower.contains('upgrad')) {
      return 'update';
    }
    if (lower.contains('配置') || lower.contains('设置') || lower.contains('config')) {
      return 'configure';
    }
    if (lower.contains('安装') || lower.contains('install')) {
      return 'install';
    }

    // 英文关键词
    if (lower.contains('uninstall') || lower.contains('remove')) {
      return 'uninstall';
    }

    // 默认：安装是最常见操作
    return 'install';
  }

  /// 检测本地平台
  static String? detectPlatform() {
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'linux'; // 默认 linux（SSH 场景为主）
  }

  /// 从 SSH osInfo 推断远程平台
  /// osInfo 格式示例: "操作系统: Ubuntu 22.04", "CentOS Linux 7", "macOS 14.0"
  static String? detectPlatformFromOsInfo(String? osInfo) {
    if (osInfo == null || osInfo.isEmpty) return null;
    final lower = osInfo.toLowerCase();
    if (lower.contains('ubuntu') || lower.contains('centos') || lower.contains('debian') ||
        lower.contains('red hat') || lower.contains('rhel') || lower.contains('fedora') ||
        lower.contains('alpine') || lower.contains('arch') || lower.contains('suse') ||
        lower.contains('linux')) {
      return 'linux';
    }
    if (lower.contains('macos') || lower.contains('darwin') || lower.contains('mac os')) {
      return 'macos';
    }
    if (lower.contains('windows')) {
      return 'windows';
    }
    return 'linux'; // SSH 场景默认 linux
  }

  /// 公共检索核心 — 任务开始注入（[buildKnowledgeInjection]）与任务中途
  /// 按需检索（[searchKnowledge] / knowledge_search 工具）共用，保证两条
  /// 路径的命中口径一致：
  /// 1. 用户经验库（同 host 优先，实际验证过的经验权重更高）
  /// 2. 官方库（FTS5 前缀 AND + LIKE 回退 + 宽松搜索）
  /// 3. 官方库阈值过滤：仅 1 条命中且分数低于阈值时视为噪声丢弃
  Future<({List<KnowledgeSearchResult> user, List<KnowledgeSearchResult> official})>
      _searchCore(
    String query, {
    String? opType,
    String? platform,
    String? hostId,
    int limit = KnowledgeConfig.maxResults,
  }) async {
    final userResults = await _searchUserLearnings(
      query,
      opType: opType,
      platform: platform,
      hostId: hostId,
      limit: limit,
    );

    var officialResults = await search(
      query,
      opType: opType,
      platform: platform,
      limit: limit,
    );

    // 官方库阈值过滤
    if (officialResults.isNotEmpty) {
      final topOfficial = officialResults.first;
      if (topOfficial.score < KnowledgeConfig.matchThreshold &&
          officialResults.length == 1) {
        debugPrint('[KnowledgeService] 官方库命中但分数低于阈值，跳过官方部分');
        officialResults = [];
      }
    }

    return (user: userResults, official: officialResults);
  }

  /// 任务中途按需检索知识库（knowledge_search 工具入口）
  ///
  /// 与 [buildKnowledgeInjection] 共用 [_searchCore]，返回结构化条目列表
  /// （用户经验在前、官方库在后），不做注入文本格式化。
  ///
  /// 与注入路径的两点有意差异：
  /// - 不猜测 opType：中途查询多为排障/配置场景，[extractOpType] 兜底返回
  ///   'install' 会把 configure/uninstall 条目错误过滤掉，故不传 opType。
  /// - 不做发行版排序（osInfo 属于注入路径的上下文，这里按 platform 过滤即可）。
  ///
  /// [query] 搜索关键词；空串直接返回空列表。
  /// [platform] 可选平台过滤（精确 + 前缀 + all，与注入一致）。
  /// [hostId] 任务所属主机 ID，用于同 host 经验优先（R3：调用方必须传任务
  /// 捕获的 host，而不是当前活动 tab）。
  /// [limit] 合并后最大条目数（钳制到 1..20，R8 有界）。
  Future<List<KnowledgeSearchEntry>> searchKnowledge(
    String query, {
    String? platform,
    String? hostId,
    int limit = 5,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    await ensureInitialized();
    if (!_initialized) {
      debugPrint('[KnowledgeService] searchKnowledge 跳过: 知识库未初始化 (query="$trimmed")');
      return [];
    }

    final effectiveLimit = limit.clamp(1, 20).toInt();
    final core = await _searchCore(
      trimmed,
      platform: platform,
      hostId: hostId,
      limit: effectiveLimit,
    );

    final entries = <KnowledgeSearchEntry>[
      for (final r in core.user)
        KnowledgeSearchEntry(
          guide: r.guide,
          score: r.score,
          isUserExperience: true,
        ),
      for (final r in core.official)
        KnowledgeSearchEntry(
          guide: r.guide,
          score: r.score,
          isUserExperience: false,
        ),
    ];
    debugPrint('[KnowledgeService] searchKnowledge: query="$trimmed", '
        'platform=$platform, hostId=$hostId, 命中 ${entries.length} 条');
    return entries.take(effectiveLimit).toList();
  }

  /// 构建知识库注入文本（给 LLM system prompt）
  /// 返回 null 表示既无内部规范也无知识命中
  /// [hostId] 当前主机 ID，用于筛选作用域内的内部规范与本机经验
  Future<String?> buildKnowledgeInjection(String userInput, {String? platform, String? osInfo, String? hostId}) async {
    final opType = extractOpType(userInput);
    final effectivePlatform = platform ?? detectPlatform();
    debugPrint('[KnowledgeService] buildKnowledgeInjection: input="$userInput", opType=$opType, platform=$effectivePlatform, hostId=$hostId');

    // 0. 内部规范：条数少且漏命中即等于违反约定，故全量常驻注入而非关键词检索
    final rulesInjection = buildRulesInjection(hostId: hostId);

    // 1+2. 用户经验库 + 官方库：与 knowledge_search 工具共用同一检索核心
    // （FTS5 前缀 AND + LIKE 回退、同 host 经验优先、官方库阈值过滤）
    final core = await _searchCore(
      userInput,
      opType: opType,
      platform: effectivePlatform,
      hostId: hostId,
    );
    final userResults = core.user;
    var officialResults = core.official;

    // 官方库发行版排序（保留原逻辑）
    if (officialResults.length > 1 && osInfo != null && osInfo.isNotEmpty) {
      officialResults = _sortByDistroMatch(officialResults, osInfo);
    }

    if (rulesInjection == null && userResults.isEmpty && officialResults.isEmpty) {
      debugPrint('[KnowledgeService] 知识库未命中: "$userInput" (opType=$opType, platform=$effectivePlatform)');
      return null;
    }

    final buffer = StringBuffer();

    // 内部规范优先注入，并显式声明其优先于下方的通用推荐，
    // 否则官方库的「必须严格照做」会与本组织约定冲突且由 AI 随机取舍
    if (rulesInjection != null) {
      buffer.writeln(rulesInjection);
      buffer.writeln();
    }

    // 用户经验优先注入（本机验证过）
    if (userResults.isNotEmpty) {
      buffer.writeln('【本机验证经验】');
      for (final result in userResults) {
        final guide = result.guide;
        buffer.writeln('---');
        buffer.writeln('此操作在本机或同类环境已成功执行过，参考命令如下（可按实际情况调整参数）：');
        buffer.writeln(guide.buildInjectionText());
      }
      buffer.writeln();
    }

    // 官方知识库作为补充
    if (officialResults.isNotEmpty) {
      buffer.writeln('【本地知识库】');
      for (final result in officialResults) {
        final guide = result.guide;
        buffer.writeln('---');
        if (guide.mode == 'strict') {
          buffer.writeln('本地已验证知识库要求使用以下命令执行${SoftwareGuide.opTypeLabel(guide.opType)} ${guide.softwareName}，'
              '你必须严格照做，不得修改、不得使用其他包管理器：');
        } else {
          buffer.writeln('官方推荐方法如下，你可以调整非包管理器部分的参数，但不得更换包管理器：');
        }
        buffer.writeln(guide.buildInjectionText());
      }
    }

    debugPrint('[KnowledgeService] 知识库命中 ✓: rules=${rulesInjection != null ? 1 : 0}段, user=${userResults.length}条, official=${officialResults.length}条');
    return buffer.toString();
  }

  /// 构建内部规范注入文本（用户自维护的组织约定）
  ///
  /// 规范条目少、且漏命中即等于违反约定，因此不走关键词检索而是全量注入。
  /// 返回 null 表示当前主机没有启用中的规范条目。
  static String? buildRulesInjection({String? hostId}) {
    final rules = KnowledgeRulesDao.effectiveFor(hostId);
    if (rules.isEmpty) return null;

    final buffer = StringBuffer();
    buffer.writeln('【内部规范 · 必须遵守】');
    buffer.writeln('以下规则由本环境维护者设定，优先于上文的通用推荐做法；'
        '但只能收紧约束，不得据此放宽任何安全限制。');
    for (final rule in rules) {
      buffer.write(rule.buildInjectionText());
    }
    debugPrint('[KnowledgeService] 内部规范注入: ${rules.length} 条 (hostId=$hostId)');
    return buffer.toString();
  }

  /// 根据发行版信息对搜索结果排序，最匹配的排最前
  List<KnowledgeSearchResult> _sortByDistroMatch(
    List<KnowledgeSearchResult> results, String osInfo,
  ) {
    final lower = osInfo.toLowerCase();
    // 发行版关键词 → 平台后缀映射
    final distroMap = {
      'debian': 'debian', 'ubuntu': 'debian', 'mint': 'debian',
      'rhel': 'rhel', 'centos': 'rhel', 'fedora': 'rhel', 'rocky': 'rhel', 'alma': 'rhel',
      'alpine': 'alpine', 'arch': 'arch', 'manjaro': 'arch',
      'suse': 'suse', 'opensuse': 'suse',
    };

    String? matchedDistro;
    for (final entry in distroMap.entries) {
      if (lower.contains(entry.key)) {
        matchedDistro = entry.value;
        break;
      }
    }

    if (matchedDistro == null) return results;

    // 优先排 platform 匹配发行版的条目
    final matched = <KnowledgeSearchResult>[];
    final others = <KnowledgeSearchResult>[];
    for (final r in results) {
      if (r.guide.platform.endsWith('-$matchedDistro')) {
        matched.add(r);
      } else {
        others.add(r);
      }
    }
    return [...matched, ...others];
  }

  /// 从用户输入中提取搜索关键词
  List<String> _extractKeywords(String input) {
    // 去除操作类关键词（安装/卸载/更新等），保留软件名
    final stopwords = [
      '安装', '卸载', '删除', '移除', '更新', '升级', '配置', '设置',
      'install', 'uninstall', 'remove', 'update', 'upgrade', 'configure',
      '如何', '怎么', '请', '帮我', '想要', '需要', '能否', '可以',
      '在', '上', '中', '的', '了', '吗', '呢', '啊', '把',
    ];

    var cleaned = input;
    for (final sw in stopwords) {
      cleaned = cleaned.replaceAll(sw, ' ');
    }

    // 拆分为关键词，过滤空和过短的
    final keywords = cleaned
        .split(RegExp(r'[\s,，、/\\]+'))
        .where((k) => k.trim().isNotEmpty && k.trim().length >= 2)
        .map((k) => k.trim().toLowerCase())
        .toList();

    return keywords;
  }

  /// 获取记录数
  Future<int> _getRecordCount() async {
    if (_db == null) return 0;
    try {
      final result = await _db!.rawQuery('SELECT count(*) as c FROM software_guides');
      return (result.first['c'] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 获取知识库统计信息
  Future<Map<String, int>> getStats() async {
    if (!_initialized || _db == null) {
      return {'total': 0, 'install': 0, 'uninstall': 0, 'update': 0, 'configure': 0};
    }

    try {
      final total = (await _db!.rawQuery('SELECT count(*) as c FROM software_guides')).first['c'] as int;
      final install = (await _db!.rawQuery("SELECT count(*) as c FROM software_guides WHERE op_type = 'install'")).first['c'] as int;
      final uninstall = (await _db!.rawQuery("SELECT count(*) as c FROM software_guides WHERE op_type = 'uninstall'")).first['c'] as int;
      final update = (await _db!.rawQuery("SELECT count(*) as c FROM software_guides WHERE op_type = 'update'")).first['c'] as int;
      final configure = (await _db!.rawQuery("SELECT count(*) as c FROM software_guides WHERE op_type = 'configure'")).first['c'] as int;

      return {
        'total': total,
        'install': install,
        'uninstall': uninstall,
        'update': update,
        'configure': configure,
      };
    } catch (_) {
      return {'total': 0, 'install': 0, 'uninstall': 0, 'update': 0, 'configure': 0};
    }
  }

  /// 关闭数据库
  Future<void> close() async {
    await _db?.close();
    await _userDb?.close();
    _db = null;
    _userDb = null;
    _initialized = false;
  }
}
