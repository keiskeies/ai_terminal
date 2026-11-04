import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/services/local_file_policy.dart';
import 'package:ai_terminal/utils/local_file_ops.dart';

/// 回收区用量与清理
///
/// `local_file_delete` 把文件移进 `<所在目录>/.ai_terminal_trash/<时间戳>/`，
/// 还原又是复制回去，副本永久留着 —— 没有用量视图和清理入口就是无界增长
/// （AGENTS.md R8）。清理唯一必须守住的底线是：只删回收区里的条目。
void main() {
  const trash = LocalFilePolicy.trashDirName;

  late Directory sandbox;
  String sandboxPath(String relative) =>
      p.normalize(p.join(sandbox.path, relative));

  /// 造一个回收条目：`<dir>/.ai_terminal_trash/<stamp>/<name>`，返回条目目录
  String makeEntry(String dirName, String stamp, Map<String, String> files) {
    final entry = p.join(sandboxPath(dirName), trash, stamp);
    Directory(entry).createSync(recursive: true);
    files.forEach((name, content) {
      File(p.join(entry, name)).writeAsStringSync(content);
    });
    return entry;
  }

  setUp(() => sandbox = Directory.systemTemp.createTempSync('trash_test_'));
  tearDown(() => sandbox.deleteSync(recursive: true));

  group('isTrashEntryDir', () {
    test('认时间戳那一层，不认回收区根目录', () {
      expect(
          isTrashEntryDir(sandboxPath('.ai_terminal_trash/1700000000000'),
              trashDirName: trash),
          isTrue);
      expect(isTrashEntryDir(sandboxPath('.ai_terminal_trash'),
              trashDirName: trash),
          isFalse,
          reason: '回收区根目录是保留目录，删了后续删除就无处可去');
    });

    test('不认更深一层，也不认无关目录', () {
      expect(
          isTrashEntryDir(sandboxPath('.ai_terminal_trash/17/a/b'),
              trashDirName: trash),
          isFalse);
      expect(isTrashEntryDir(sandboxPath('projects/src'), trashDirName: trash),
          isFalse);
    });
  });

  group('trashEntriesFromRestorePaths', () {
    test('取 restoreFrom 的父目录并去重', () {
      final entries = trashEntriesFromRestorePaths([
        sandboxPath('.ai_terminal_trash/100/a.txt'),
        sandboxPath('.ai_terminal_trash/100/b.txt'),
        sandboxPath('.ai_terminal_trash/200/c.txt'),
      ], trashDirName: trash);

      expect(entries, [
        sandboxPath('.ai_terminal_trash/100'),
        sandboxPath('.ai_terminal_trash/200'),
      ]);
    });

    test('丢掉不指向回收区的路径', () {
      // 台账行可能被旧版本或异常数据写成普通目录：这种路径绝不能进清理列表
      final entries = trashEntriesFromRestorePaths([
        sandboxPath('projects/config.yaml'),
        sandboxPath(''),
        '   ',
        sandboxPath('.ai_terminal_trash/300/x.txt'),
      ], trashDirName: trash);

      expect(entries, [sandboxPath('.ai_terminal_trash/300')]);
    });
  });

  group('measureTrashEntries', () {
    test('统计存在的条目与字节', () async {
      final first = makeEntry('d1', '100', {'a.txt': '12345'});
      makeEntry('d1', '200', {'b.txt': '678'});

      final usage = await measureTrashEntries([
        first,
        p.join(sandboxPath('d1'), trash, '200'),
        p.join(sandboxPath('d1'), trash, 'missing'),
      ]);

      expect(usage.count, 2, reason: '不存在的路径不该算进用量');
      expect(usage.bytes, 8);
    });

    test('空列表得到空用量', () async {
      final usage = await measureTrashEntries([]);
      expect(usage.isEmpty, isTrue);
      expect(usage.bytes, 0);
    });
  });

  group('clearTrashEntries', () {
    test('删除条目并报告释放量', () async {
      final entry = makeEntry('d1', '100', {'a.txt': '12345'});

      final result =
          await clearTrashEntries([entry], trashDirName: trash);

      expect(result.removed, 1);
      expect(result.bytesFreed, 5);
      expect(result.isClean, isTrue);
      expect(Directory(entry).existsSync(), isFalse);
      // 回收区根目录保留
      expect(Directory(p.join(sandboxPath('d1'), trash)).existsSync(), isTrue);
    });

    test('拒绝删除回收区之外的目录，且目录原样保留', () async {
      final realProject = Directory(sandboxPath('projects'))
        ..createSync(recursive: true);
      File(p.join(realProject.path, 'important.txt'))
          .writeAsStringSync('do not delete me');

      final result = await clearTrashEntries(
        [realProject.path],
        trashDirName: trash,
      );

      expect(result.removed, 0);
      expect(result.refused, [realProject.path]);
      expect(result.isClean, isFalse);
      expect(
          File(p.join(realProject.path, 'important.txt')).existsSync(), isTrue,
          reason: '清理回收区绝不能碰到用户真实目录');
    });

    test('条目不存在时算跳过，不算失败', () async {
      final missing = p.join(sandboxPath('d1'), trash, '999');

      final result =
          await clearTrashEntries([missing], trashDirName: trash);

      expect(result.removed, 0);
      expect(result.failed, isEmpty);
      expect(result.isClean, isTrue);
    });

    test('混合输入：只删该删的', () async {
      final entry = makeEntry('d1', '100', {'a.txt': 'xyz'});
      final outside = Directory(sandboxPath('keepme'))..createSync();

      final result = await clearTrashEntries(
        [entry, outside.path],
        trashDirName: trash,
      );

      expect(result.removed, 1);
      expect(result.refused, [outside.path]);
      expect(Directory(outside.path).existsSync(), isTrue);
    });
  });

  group('countPathsUnderEntries', () {
    test('数出落在这些条目里的还原路径', () {
      final entry = sandboxPath('.ai_terminal_trash/100');

      expect(
          countPathsUnderEntries([
            p.join(entry, 'a.txt'),
            p.join(entry, 'b.txt'),
            sandboxPath('.ai_terminal_trash/200/c.txt'),
          ], [entry]),
          2);
    });

    test('没有条目时为 0，不遍历', () {
      expect(countPathsUnderEntries([sandboxPath('a/b.txt')], []), 0);
    });
  });

  group('formatByteSize', () {
    test('按量级切换单位', () {
      expect(formatByteSize(0), '0 B');
      expect(formatByteSize(1023), '1023 B');
      expect(formatByteSize(1024), '1.0 KB');
      expect(formatByteSize(1024 * 1024), '1.0 MB');
      expect(formatByteSize(3 * 1024 * 1024 * 1024), '3.00 GB');
    });
  });
}
