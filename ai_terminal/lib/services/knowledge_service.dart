import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import '../models/software_guide.dart';

/// 知识库远程更新配置
class KnowledgeConfig {
  /// 远程知识库基础 URL（按版本号拼接：{baseUrl}/knowledge-{version}.db）
  static const String remoteBaseUrl = 'https://ai-terminal.keiskei.top/knowledge';

  /// 根据版本号拼接完整下载地址
  static String remoteDbUrlForVersion(String version) =>
      '$remoteBaseUrl/knowledge-$version.db';

  /// 本地数据库文件名
  static const String dbFileName = 'knowledge.db';

  /// 内置数据库的 asset 路径
  static const String bundledAssetPath = 'assets/knowledge/knowledge.db';

  /// FTS5 命中阈值（低于此分数不注入知识库）
  static const double matchThreshold = 0.3;

  /// 最大返回条目数
  static const int maxResults = 3;
}

/// 知识库服务 — SQLite FTS5 全文搜索 + 远程同步 + 离线兜底
class KnowledgeService {
  static final KnowledgeService _instance = KnowledgeService._internal();
  factory KnowledgeService() => _instance;
  KnowledgeService._internal();

  Database? _db;
  bool _initialized = false;
  bool _initializing = false;

  /// 获取数据库实例
  Database? get db => _db;
  bool get isInitialized => _initialized;

  /// 初始化知识库
  /// 1. 尝试从远程下载最新 knowledge.db
  /// 2. 下载失败则使用内置版本（assets/knowledge/knowledge.db）
  /// 3. 打开本地数据库，验证 FTS5 索引
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

      // 尝试远程更新
      await _tryRemoteUpdate(dbPath);

      // 如果本地没有数据库文件，从内置 assets 复制
      if (!await dbFile.exists()) {
        await _copyBundledDb(dbPath);
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
        // 重新打开
        _db = await openDatabase(dbPath, version: 1, onCreate: _onCreate);
        await _validateFts5Index();
      }

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

  /// 尝试从远程下载最新数据库
  Future<void> _tryRemoteUpdate(String dbPath) async {
    try {
      final remoteUrl = await _getRemoteDbUrl();
      if (remoteUrl == null) return;

      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 5);
      dio.options.receiveTimeout = const Duration(seconds: 30);

      final dbFile = File(dbPath);
      int? localSize;
      if (await dbFile.exists()) {
        localSize = await dbFile.length();
      }

      // 发送 HEAD 请求检查是否更新
      final response = await dio.head(remoteUrl);
      final remoteSize = response.headers.value('content-length');

      // 如果远程文件大小与本地一致，跳过下载
      if (localSize != null && remoteSize != null) {
        if (localSize == int.parse(remoteSize)) {
          debugPrint('[KnowledgeService] 远程数据库与本地一致，跳过下载');
          return;
        }
      }

      // 下载最新数据库到临时文件，然后替换
      debugPrint('[KnowledgeService] 正在下载远程知识库: $remoteUrl');
      final tempPath = '$dbPath.tmp';
      await dio.download(remoteUrl, tempPath);

      // 验证下载的文件
      final tempFile = File(tempPath);
      if (await tempFile.exists() && await tempFile.length() > 0) {
        if (await dbFile.exists()) {
          final backupPath = '$dbPath.bak';
          await dbFile.rename(backupPath);
        }
        await tempFile.rename(dbPath);
        debugPrint('[KnowledgeService] 远程知识库下载完成');
      }
    } catch (e) {
      debugPrint('[KnowledgeService] 远程更新失败，使用本地数据库: $e');
    }
  }

  /// 获取当前版本对应的远程数据库 URL
  static Future<String?> _getRemoteDbUrl() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version; // e.g. "1.3.0"
      return KnowledgeConfig.remoteDbUrlForVersion(version);
    } catch (e) {
      debugPrint('[KnowledgeService] 获取版本号失败: $e');
      return null;
    }
  }

  /// 强制从远程更新知识库（设置页面手动触发）
  /// 返回更新结果消息
  Future<String> forceUpdateFromRemote() async {
    final remoteUrl = await _getRemoteDbUrl();
    if (remoteUrl == null) {
      return '获取版本号失败，无法确定下载地址';
    }

    try {
      final dbPath = await _getLocalDbPath();
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 10);
      dio.options.receiveTimeout = const Duration(seconds: 60);

      debugPrint('[KnowledgeService] 手动更新: 正在下载 $remoteUrl');
      final tempPath = '$dbPath.tmp';
      await dio.download(remoteUrl, tempPath);

      final tempFile = File(tempPath);
      if (!await tempFile.exists() || await tempFile.length() == 0) {
        return '下载失败：文件为空';
      }

      // 关闭旧数据库
      await _db?.close();
      _db = null;
      _initialized = false;

      // 备份旧文件，替换为新文件
      final dbFile = File(dbPath);
      if (await dbFile.exists()) {
        final backupPath = '$dbPath.bak';
        final backupFile = File(backupPath);
        if (await backupFile.exists()) {
          await backupFile.delete();
        }
        await dbFile.rename(backupPath);
      }
      await tempFile.rename(dbPath);

      // 重新打开数据库
      _db = await openDatabase(dbPath, version: 1, onCreate: _onCreate);
      await _validateFts5Index();
      _initialized = true;

      final stats = await getStats();
      debugPrint('[KnowledgeService] 手动更新完成，共 ${stats['total']} 条记录');
      return '更新成功，当前知识库共 ${stats['total']} 条记录';
    } catch (e) {
      // 恢复旧数据库
      debugPrint('[KnowledgeService] 手动更新失败: $e');
      final dbPath = await _getLocalDbPath();
      final backupPath = '$dbPath.bak';
      final backupFile = File(backupPath);
      final dbFile = File(dbPath);

      if (!await dbFile.exists() && await backupFile.exists()) {
        await backupFile.rename(dbPath);
      }

      // 重新初始化
      try {
        _initialized = false;
        await init();
      } catch (_) {}

      return '更新失败: $e';
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

  /// 全文搜索知识库
  /// [query] 搜索关键词（原始用户输入）
  /// [opType] 可选的操作类型过滤（install/uninstall/update/configure）
  /// [platform] 可选的平台过滤
  Future<List<KnowledgeSearchResult>> search(
    String query, {
    String? opType,
    String? platform,
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
      // FTS5 语法: term* 表示前缀匹配
      final ftsQuery = keywords.map((k) => '$k*').join(' AND ');

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
        ''', [ftsQuery, ...args, KnowledgeConfig.maxResults]);

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
        ''', [...likeArgs, KnowledgeConfig.maxResults]);

        debugPrint('[KnowledgeService] LIKE 回退搜索结果: ${results.length} 条');
      }

      if (results.isEmpty) {
        // 尝试宽松搜索：只用第一个关键词，不过滤 opType
        if (keywords.length > 1 || opType != null) {
          debugPrint('[KnowledgeService] 尝试宽松搜索...');
          final looseFtsQuery = '${keywords.first}*';

          List<Map<String, Object?>> looseResults;
          try {
            looseResults = await _db!.rawQuery('''
              SELECT sg.*, ft.rank as score
              FROM guides_fts ft
              JOIN software_guides sg ON ft.rowid = sg.id
              WHERE guides_fts MATCH ?
              ORDER BY ft.rank
              LIMIT ?
            ''', [looseFtsQuery, KnowledgeConfig.maxResults]);
          } catch (e) {
            // FTS5 不可用，LIKE 回退
            looseResults = await _db!.rawQuery('''
              SELECT sg.*, 0.0 as score
              FROM software_guides sg
              WHERE sg.software_name LIKE ? OR sg.aliases LIKE ? OR sg.summary LIKE ?
              LIMIT ?
            ''', ['%${keywords.first}%', '%${keywords.first}%', '%${keywords.first}%', KnowledgeConfig.maxResults]);
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

  /// 构建知识库注入文本（给 LLM system prompt）
  /// 返回 null 表示未命中知识库
  Future<String?> buildKnowledgeInjection(String userInput, {String? platform, String? osInfo}) async {
    final opType = extractOpType(userInput);
    final effectivePlatform = platform ?? detectPlatform();
    debugPrint('[KnowledgeService] buildKnowledgeInjection: input="$userInput", opType=$opType, platform=$effectivePlatform');

    var results = await search(
      userInput,
      opType: opType,
      platform: effectivePlatform,
    );

    if (results.isEmpty) {
      debugPrint('[KnowledgeService] 知识库未命中: "$userInput" (opType=$opType, platform=$effectivePlatform)');
      return null;
    }

    // 检查最高分是否超过阈值
    final topResult = results.first;
    debugPrint('[KnowledgeService] 最高分: ${topResult.score}, 阈值: ${KnowledgeConfig.matchThreshold}, 软件名: ${topResult.guide.softwareName}');

    if (topResult.score < KnowledgeConfig.matchThreshold && results.length == 1) {
      debugPrint('[KnowledgeService] 命中但分数低于阈值，跳过');
      return null;
    }

    // 智能排序：如果有多条平台细分的条目（如 linux-debian / linux-rhel），
    // 根据 osInfo 优先选择最匹配发行版的条目
    if (results.length > 1 && osInfo != null && osInfo.isNotEmpty) {
      results = _sortByDistroMatch(results, osInfo);
    }

    final buffer = StringBuffer();
    buffer.writeln('【本地知识库】');

    for (final result in results) {
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

    debugPrint('[KnowledgeService] 知识库命中 ✓: ${results.map((r) => r.guide.softwareName).join(", ")}');
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
    _db = null;
    _initialized = false;
  }
}
