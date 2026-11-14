import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/services/daos.dart';

/// 只覆盖 DAO 的缓存层（未初始化 DbInit 时 record 降级为只写缓存，与
/// SettingsDao 同口径）。SQL 路径与其余 DAO 一样不在单测范围内。
void main() {
  setUp(() async {
    await CommandHistoryDao.clearAll();
  });

  test('新命令进缓存最前', () async {
    await CommandHistoryDao.record('ls -l');
    await CommandHistoryDao.record('pwd');
    expect(CommandHistoryDao.cached.map((e) => e.command), ['pwd', 'ls -l']);
  });

  test('同一命令合并成一条并累加次数、提到最前', () async {
    await CommandHistoryDao.record('ls -l');
    await CommandHistoryDao.record('pwd');
    await CommandHistoryDao.record('ls -l');
    final cached = CommandHistoryDao.cached;
    expect(cached.length, 2);
    expect(cached.first.command, 'ls -l');
    expect(cached.first.useCount, 2);
  });

  test('大小写不同视为不同命令（shell 本身区分）', () async {
    await CommandHistoryDao.record('Docker ps');
    await CommandHistoryDao.record('docker ps');
    expect(CommandHistoryDao.cached.length, 2);
  });

  test('search 子串匹配且忽略大小写', () async {
    await CommandHistoryDao.record('docker compose up -d');
    await CommandHistoryDao.record('git status');
    expect(
        CommandHistoryDao.search('DOCKER').map((e) => e.command),
        ['docker compose up -d']);
    expect(
        CommandHistoryDao.search('status').map((e) => e.command),
        ['git status']);
    expect(CommandHistoryDao.search('').length, 2);
  });

  test('search 空结果返回空表', () async {
    await CommandHistoryDao.record('ls');
    expect(CommandHistoryDao.search('nope'), isEmpty);
  });

  test('delete 同步移除缓存', () async {
    await CommandHistoryDao.record('ls -l');
    final id = CommandHistoryDao.cached.first.id;
    await CommandHistoryDao.delete(id);
    expect(CommandHistoryDao.cached, isEmpty);
  });

  test('超出上限时丢弃最旧，缓存有界（R8：不留无界缓冲）', () async {
    const total = 500 + 20;
    for (var i = 0; i < total; i++) {
      await CommandHistoryDao.record('cmd_$i');
    }
    final cached = CommandHistoryDao.cached;
    expect(cached.length, 500);
    expect(cached.first.command, 'cmd_${total - 1}');
    expect(cached.any((e) => e.command == 'cmd_0'), isFalse);
  });
}
