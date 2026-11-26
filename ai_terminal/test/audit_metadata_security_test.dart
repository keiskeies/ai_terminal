import 'package:ai_terminal/core/db_init.dart';
import 'package:ai_terminal/core/security/command_intent.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/utils/audit_logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _auditTable = '''
  CREATE TABLE audit_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    hostId TEXT NOT NULL,
    command TEXT NOT NULL,
    safetyLevel TEXT NOT NULL,
    output TEXT,
    executed INTEGER NOT NULL,
    metadata TEXT
  )
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
  });

  tearDown(() async {
    AuditLogsDao.databaseOverride = null;
    await db.close();
  });

  test('fullAuto 未知语法审计保留解析原因且不记录参数', () {
    const command = "bash -c 'unknown-tool --token SUPER_SECRET'";
    final metadata = AuditLogger.commandMetadata(
      command: command,
      permissionMode: AgentPermissionMode.fullAuto,
    );

    expect(metadata['parserVersion'], CommandIntentParser.parserVersion);
    expect(metadata['permissionMode'], 'fullAuto');
    expect(metadata['permissionDecision'], 'execute');
    expect(metadata['policyReason'], 'explicit_full_auto_unknown_syntax');
    expect(metadata['executable'], 'bash');
    expect(metadata['unresolved'], isNotEmpty);
    expect(command.contains('SUPER_SECRET'), isTrue);
    expect(metadata.toString(), isNot(contains('SUPER_SECRET')));
  });

  test('只读命令审计不冒充未知语法放行', () {
    final metadata = AuditLogger.commandMetadata(
      command: 'grep --token SUPER_SECRET app.log',
      permissionMode: AgentPermissionMode.fullAuto,
    );

    expect(metadata['conservativeSafe'], isTrue);
    expect(metadata['unresolved'], isEmpty);
    expect(metadata.containsKey('policyReason'), isFalse);
    expect(metadata.toString(), isNot(contains('SUPER_SECRET')));
  });

  test('显式拦截原因优先于 fullAuto 未知语法原因', () {
    final metadata = AuditLogger.commandMetadata(
      command: r'echo "$(unknown-tool --token SUPER_SECRET)"',
      permissionMode: AgentPermissionMode.fullAuto,
      policyReason: 'command_syntax_error',
    );

    expect(metadata['policyReason'], 'command_syntax_error');
    expect(metadata.toString(), isNot(contains('SUPER_SECRET')));
  });

  test('审计条目 JSON 往返保留元数据并兼容旧记录', () {
    final entry = AuditLogEntry(
      timestamp: DateTime.utc(2026, 11, 25),
      hostId: 'host-a',
      command: 'ls',
      safetyLevel: 'safe',
      executed: true,
      metadata: const {'parserVersion': '1', 'confidence': 1.0},
    );
    final restored = AuditLogEntry.fromJson(entry.toJson());
    expect(restored.metadata, entry.metadata);

    final legacy = AuditLogEntry.fromJson({
      'timestamp': DateTime.utc(2026, 11, 24).toIso8601String(),
      'hostId': 'host-a',
      'command': 'pwd',
      'safetyLevel': 'safe',
      'output': null,
      'executed': true,
    });
    expect(legacy.metadata, isNull);
  });

  test('v12 到 v13 迁移增加元数据列并保留旧审计', () async {
    await db.execute('''
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
    await db.insert('audit_logs', {
      'timestamp': 1,
      'hostId': 'legacy-host',
      'command': 'pwd',
      'safetyLevel': 'safe',
      'executed': 1,
    });

    await DbInit.migrateSchemaForTesting(db, 12, 13);

    final columns = await db.rawQuery('PRAGMA table_info(audit_logs)');
    expect(columns.map((row) => row['name']), contains('metadata'));
    final rows = await db.query('audit_logs');
    expect(rows.single['command'], 'pwd');
    expect(rows.single['metadata'], isNull);
  });

  test('v10 跨版本迁移不会重复添加主机公钥列', () async {
    await db.execute('''
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

    await DbInit.migrateSchemaForTesting(db, 10, 13);

    final hostKeyColumns =
        await db.rawQuery('PRAGMA table_info(ssh_host_keys)');
    expect(
      hostKeyColumns.where((row) => row['name'] == 'public_key_base64'),
      hasLength(1),
    );
    final auditColumns = await db.rawQuery('PRAGMA table_info(audit_logs)');
    expect(auditColumns.map((row) => row['name']), contains('metadata'));
  });

  test('审计 DAO 元数据落库后缓存和数据库读回一致', () async {
    await db.execute(_auditTable);
    AuditLogsDao.databaseOverride = db;
    const metadata = {
      'parserVersion': '1',
      'permissionMode': 'fullAuto',
      'policyReason': 'explicit_full_auto_unknown_syntax',
      'unresolved': [
        {'kind': 'unknown_executable', 'detail': 'unknown-tool'}
      ],
    };

    await AuditLogsDao.add(
      hostId: 'host-a',
      command: 'unknown-tool --change',
      safetyLevel: 'warn',
      executed: false,
      metadata: metadata,
    );
    await AuditLogsDao.add(
      hostId: 'host-a',
      command: 'pwd',
      safetyLevel: 'safe',
      executed: true,
    );
    await AuditLogsDao.loadCache();

    final cached = AuditLogger.getLogsForHost('host-a');
    expect(cached.first['metadata'], metadata);
    expect(cached.last.containsKey('metadata'), isFalse);
    final stored = await AuditLogsDao.getLogsForHost('host-a');
    expect(stored.first['metadata'], metadata);
    expect(stored.last.containsKey('metadata'), isFalse);
  });
}
