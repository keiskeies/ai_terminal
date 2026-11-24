import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ai_terminal/models/conversation.dart';
import 'package:ai_terminal/services/agent_logger.dart';
import 'package:ai_terminal/services/conversation_service.dart';
import 'package:ai_terminal/services/daos.dart';

/// 受控数据库：只实现本组用到的 insert/delete，其余 Database 方法均不应被调用。
class _ControlledDatabase implements Database {
  final Map<String, Map<String, Object?>> rows = {};
  int insertCalls = 0;
  int deleteCalls = 0;

  Completer<void>? insertGate;
  Object? insertError;
  final Completer<void> insertStarted = Completer<void>();

  Object? deleteError;

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    insertCalls++;
    final gate = insertGate;
    if (gate != null) {
      if (!insertStarted.isCompleted) insertStarted.complete();
      await gate.future;
    }
    final error = insertError;
    if (error != null) {
      insertError = null;
      throw error;
    }
    final id = values['id']! as String;
    rows[id] = Map<String, Object?>.from(values);
    return 1;
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    deleteCalls++;
    final error = deleteError;
    if (error != null) throw error;
    final id = whereArgs!.single! as String;
    rows.remove(id);
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Conversation _conversation(String id, {String content = 'snapshot'}) {
  return Conversation.create(id: id, hostId: 'host-$id', title: 'title')
    ..addMessage(ConvMessage.create(role: 'user', content: content));
}

void main() {
  late _ControlledDatabase db;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    db = _ControlledDatabase();
    ConversationService().resetForTesting();
    ConversationsDao.resetForTesting();
    ConversationsDao.databaseOverride = db;
  });

  tearDown(() async {
    ConversationService().resetForTesting();
    await agentLogger.flush();
    ConversationsDao.databaseOverride = null;
    ConversationsDao.resetForTesting();
  });

  test('appendMessagePair 失败只回滚本次对象，不误删并发成功消息', () async {
    final service = ConversationService();
    const hostId = 'host-rollback-identity';
    db
      ..insertGate = Completer<void>()
      ..insertError = StateError('first write failed');

    final first = service.appendMessagePair(
      hostId,
      userContent: 'first user',
      assistantContent: 'first assistant',
    );
    final firstExpectation = expectLater(first, throwsStateError);
    await db.insertStarted.future;

    // 第一次写仍阻塞时并发追加；它排在同一会话的 upsert 链后面。
    final second = service.appendMessage(
      hostId,
      role: 'user',
      content: 'concurrent success',
    );
    db.insertGate!.complete();

    await firstExpectation;
    await second;

    final conv = service.getActiveSession(hostId)!;
    expect(conv.messages, hasLength(1));
    expect(conv.messages.single.role, 'user');
    expect(conv.messages.single.content, 'concurrent success');
    expect(db.insertCalls, 2);
  });

  test('appendMessage 显式会话 id 不写入同 host 的新 active 会话', () async {
    final service = ConversationService();
    const hostId = 'host-explicit-conversation';
    final first = service.createSession(hostId: hostId);
    await service.appendMessage(hostId, role: 'user', content: 'first');
    final second = service.createSession(hostId: hostId);

    await service.appendMessage(
      hostId,
      role: 'assistant',
      content: 'belongs to first',
      conversationId: first.id,
    );

    expect(first.messages.map((m) => m.content), ['first', 'belongs to first']);
    expect(second.messages, isEmpty);
    expect(service.getActiveSession(hostId), same(second));
  });

  test('delete 等待旧 upsert 链，并阻止链中/后续旧快照重插', () async {
    final conv = _conversation('delete-race');
    db.insertGate = Completer<void>();

    final first = ConversationsDao.upsert(conv);
    await db.insertStarted.future;
    final queued = ConversationsDao.upsert(conv);
    final queuedExpectation = expectLater(queued, throwsStateError);

    final deletion = ConversationsDao.delete(conv.id);
    expect(db.deleteCalls, 0, reason: '删除必须等待已经开始的 upsert 链');
    await expectLater(
      ConversationsDao.upsert(conv),
      throwsA(isA<StateError>()),
    );

    db.insertGate!.complete();
    await first;
    await queuedExpectation;
    await deletion;

    expect(db.insertCalls, 1, reason: '排队中的旧快照在编码后看到墓碑并放弃');
    expect(db.deleteCalls, 1);
    expect(db.rows, isEmpty);
    expect(ConversationsDao.getCachedById(conv.id), isNull);
  });

  test('old-write-failure/new-write-success：旧写失败不阻断后续快照', () async {
    final conv = _conversation('old-write-failure', content: 'old');
    db
      ..insertGate = Completer<void>()
      ..insertError = StateError('old write failed');
    final first = ConversationsDao.upsert(conv);
    final firstExpectation = expectLater(first, throwsStateError);
    await db.insertStarted.future;

    conv.messages.single.content = 'new';
    final second = ConversationsDao.upsert(conv);
    db.insertGate!.complete();
    await firstExpectation;
    await second;

    final row = db.rows[conv.id]!;
    final messages = jsonDecode(row['messages']! as String) as List;
    expect((messages.single as Map<String, dynamic>)['content'], 'new');
  });

  test('delete-failure-retry：失败后恢复缓存/草稿并清除失败链与墓碑', () async {
    final service = ConversationService();
    final draft = service.createSession(hostId: 'delete-retry-host');
    db.deleteError = StateError('delete failed');

    await expectLater(service.delete(draft.id), throwsStateError);
    expect(service.lookup(draft.id), same(draft));
    expect(ConversationsDao.getCachedById(draft.id), same(draft));

    final written = await service.appendMessagePair(
      'delete-retry-host',
      userContent: '恢复后写入',
      assistantContent: '成功',
      conversationId: draft.id,
    );
    expect(written.messages, hasLength(2));
    expect(db.rows[draft.id], isNotNull);

    db.deleteError = null;
    await service.delete(draft.id);
    expect(db.deleteCalls, 2, reason: '失败 delete 链清理后必须真正重试');
    expect(service.lookup(draft.id), isNull);
    expect(db.rows, isEmpty);
  });

  test('delete 失败链清理后，重复 delete 会重新发起而不是永久复用错误', () async {
    final conv = _conversation('delete-error-retry');
    await ConversationsDao.upsert(conv);
    db.deleteError = StateError('delete failed');
    await expectLater(ConversationsDao.delete(conv.id), throwsStateError);
    await expectLater(ConversationsDao.delete(conv.id), throwsStateError);
    expect(db.deleteCalls, 2);
    expect(ConversationsDao.getCachedById(conv.id), same(conv));

    db.deleteError = null;
    await ConversationsDao.upsert(conv);
    await ConversationsDao.delete(conv.id);
    expect(db.deleteCalls, 3);
    expect(ConversationsDao.getCachedById(conv.id), isNull);
  });

  test('真实 SQLite 调度：upsert 链与 delete 墓碑阻止旧快照复活', () async {
    final sqlite = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(sqlite.close);
    await sqlite.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        hostId TEXT NOT NULL,
        title TEXT NOT NULL,
        titleSource TEXT,
        messages TEXT NOT NULL,
        agentLogs TEXT,
        summary TEXT,
        rollingSummary TEXT,
        summarizedUpToIndex INTEGER NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        isActive INTEGER NOT NULL
      )
    ''');
    ConversationsDao.databaseOverride = sqlite;
    final conv = _conversation('sqlite-schedule');
    await ConversationsDao.upsert(conv);
    final queued = ConversationsDao.upsert(conv);
    final queuedExpectation = expectLater(queued, throwsStateError);
    final deletion = ConversationsDao.delete(conv.id);
    await expectLater(ConversationsDao.upsert(conv), throwsStateError);
    await queuedExpectation;
    await deletion;

    expect(await ConversationsDao.getById(conv.id), isNull);
    expect(ConversationsDao.getCachedById(conv.id), isNull);
  });

  test('长 assistant 正文在内存与数据库均保尾截断到统一上限', () async {
    final service = ConversationService();
    const hostId = 'host-long-assistant';
    final conv = await service.appendMessagePair(
      hostId,
      userContent: '执行长任务',
      assistantContent: '',
    );

    final longContent =
        'OLD_HEAD${'x' * ConversationService.maxAssistantContentChars}NEW_TAIL';
    await service.updateLastAssistantContent(
      hostId,
      longContent,
      conversationId: conv.id,
    );

    final stored = conv.messages.last.content;
    expect(stored.length, ConversationService.maxAssistantContentChars);
    expect(stored, endsWith('NEW_TAIL'));
    expect(stored, isNot(contains('OLD_HEAD')));

    final row = db.rows[conv.id]!;
    final messages = jsonDecode(row['messages']! as String) as List;
    final persisted =
        (messages.last as Map<String, dynamic>)['content'] as String;
    expect(persisted, stored);
  });

  test('UTF-16 保尾截断不拆代理对，尾部 emoji 完整保留', () {
    const max = ConversationService.maxAssistantContentChars;
    final splitAtPair = '😀${'x' * (max - 1)}';
    final capped = ConversationService.tailCap(splitAtPair, max);
    expect(capped, 'x' * (max - 1));
    expect(capped.codeUnits.any((u) => u >= 0xD800 && u <= 0xDFFF), isFalse);

    final tailEmoji = '${'x' * max}😀';
    expect(ConversationService.tailCap(tailEmoji, max), endsWith('😀'));
  });
}
