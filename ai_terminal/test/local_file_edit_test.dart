import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/local_terminal_service.dart';

/// 本地文件编辑回归测试。
///
/// 历史上 file_write 在 Windows 本地会话直接失败（没有 cat），file_patch 只支持
/// SSH。这里覆盖本地直接文件 I/O 的实现：写入/追加/备份/字节级补丁/失败回滚。
void main() {
  late Directory tempDir;
  late LocalTerminalService local;
  late FileWriteTool writeTool;
  late FilePatchTool patchTool;

  String b64(String text) => base64Encode(utf8.encode(text));
  String b64Bytes(List<int> bytes) => base64Encode(bytes);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ai_terminal_local_edit_');
    local = LocalTerminalService();
    writeTool = FileWriteTool();
    patchTool = FilePatchTool();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<Uint8List> readBytes(String path) => File(path).readAsBytes();

  Future<String> writeLocal(
    String path,
    String content, {
    String mode = 'write',
    bool backup = false,
  }) async {
    final result = await writeTool.execute(
      executor: local,
      args: {
        'path': path,
        'content_b64': b64(content),
        'mode': mode,
        'backup': backup,
      },
    );
    expect(result.success, isTrue, reason: result.error ?? result.output);
    return result.output;
  }

  Future<ToolResult> patchLocal(
    String path,
    String oldText,
    String newText, {
    bool backup = false,
    Uint8List? oldBytes,
    Uint8List? newBytes,
  }) {
    return patchTool.execute(
      executor: local,
      args: {
        'path': path,
        'old_b64': oldBytes != null ? b64Bytes(oldBytes) : b64(oldText),
        'new_b64': newBytes != null ? b64Bytes(newBytes) : b64(newText),
        'backup': backup,
      },
    );
  }

  group('file_write 本地文件', () {
    test('L-W1: 中文/emoji/特殊字符/CRLF 原样写入', () async {
      final path = p.join(tempDir.path, '本地 目录', '配置 😀.txt');
      const content = '第一行：中文测试\r\n'
          '第二行：emoji 😀🚀\r\n'
          '第三行：\$HOME `whoami` "double" \'single\' \\backslash & | ; > %\r\n'
          '第四行：制表符\t结尾空格  ';

      await writeLocal(path, content);

      expect(await readBytes(path), utf8.encode(content));
      expect(await File(path).exists(), isTrue);
    });

    test('L-W2: append 追加而不是覆盖', () async {
      final path = p.join(tempDir.path, 'append.txt');
      await writeLocal(path, '第一行：中文\n');
      await writeLocal(path, '第二行：emoji ✅\n', mode: 'append');

      expect(
        utf8.decode(await readBytes(path)),
        '第一行：中文\n第二行：emoji ✅\n',
      );
    });

    test('L-W3: write 覆盖已存在文件并生成备份', () async {
      final path = p.join(tempDir.path, 'backup.txt');
      await File(path).writeAsString('旧内容 ✅');

      final output = await writeLocal(path, '新内容 🚀', backup: true);

      expect(utf8.decode(await readBytes(path)), '新内容 🚀');
      final backups = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('backup.txt.bak.'))
          .toList();
      expect(backups, hasLength(1));
      expect(await backups.single.readAsString(), '旧内容 ✅');
      expect(output, contains('原文件已备份'));
    });

    test('L-W4: append 目标不存在 → 明确失败且不创建文件', () async {
      final path = p.join(tempDir.path, 'missing.txt');
      final result = await writeTool.execute(
        executor: local,
        args: {
          'path': path,
          'content_b64': b64('x'),
          'mode': 'append',
          'backup': false,
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('append'));
      expect(await File(path).exists(), isFalse);
    });

    test('L-W5: 自动创建多级父目录', () async {
      final path = p.join(tempDir.path, 'a', 'b', 'c', 'new.txt');
      await writeLocal(path, 'ok');
      expect(await File(path).readAsString(), 'ok');
      expect(await Directory(p.join(tempDir.path, 'a', 'b', 'c')).exists(),
          isTrue);
    });

    test('L-W7: content 纯文本 \\n/\\r/\\t/\\\\ 转义还原为真实字节', () async {
      final path = p.join(tempDir.path, 'escaped.txt');
      final result = await writeTool.execute(
        executor: local,
        args: {
          'path': path,
          'content': r'第一行：中文 😀\n第二行：\tTab\r\n第三行：C:\\path\\name',
          'mode': 'write',
          'backup': false,
        },
      );
      expect(result.success, isTrue, reason: result.error ?? result.output);
      expect(
        utf8.decode(await readBytes(path)),
        '第一行：中文 😀\n第二行：\tTab\r\n第三行：C:\\path\\name',
      );
    });

    test('L-W8: content 为空 → 拒绝，避免多行参数被截断成空文件', () async {
      final path = p.join(tempDir.path, 'empty.txt');
      final result = await writeTool.execute(
        executor: local,
        args: {
          'path': path,
          'content': '',
          'mode': 'write',
          'backup': false,
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('为空'));
      expect(await File(path).exists(), isFalse);
    });

    test('L-W6: 写入目录路径 → 失败但不影响其他文件', () async {
      final other = p.join(tempDir.path, 'keep.txt');
      await File(other).writeAsString('keep');
      final result = await writeTool.execute(
        executor: local,
        args: {
          'path': tempDir.path,
          'content_b64': b64('x'),
          'mode': 'write',
          'backup': true,
        },
      );
      expect(result.success, isFalse);
      expect(await File(other).readAsString(), 'keep');
    });
  });

  group('file_patch 本地文件', () {
    test('L-P1: 字节级替换保留 BOM/CRLF/非 UTF-8 字节', () async {
      final path = p.join(tempDir.path, 'nginx 配置.log');
      final prefix = <int>[0xEF, 0xBB, 0xBF]; // UTF-8 BOM
      final head = utf8.encode('server {\r\n  listen 80;\r\n  name 中文;\r\n}\r\n');
      final invalidTail = <int>[0xFF, 0xFE, 0x00, 0x01];
      final original = <int>[...prefix, ...head, ...invalidTail];
      await File(path).writeAsBytes(original);

      final result = await patchLocal(path, 'listen 80;', 'listen 8080;');

      expect(result.success, isTrue, reason: result.error ?? result.output);
      final expected = <int>[
        ...prefix,
        ...utf8.encode('server {\r\n  listen 8080;\r\n  name 中文;\r\n}\r\n'),
        ...invalidTail,
      ];
      expect(await readBytes(path), expected);
      expect(result.diffAdditions, 1);
      expect(result.diffDeletions, 1);
    });

    test('L-P2: 删除片段（new_b64 为空）', () async {
      final path = p.join(tempDir.path, 'delete.txt');
      const original = 'keep-a\nREMOVE-ME\nkeep-b\n';
      await File(path).writeAsString(original);

      final result = await patchLocal(path, 'REMOVE-ME\n', '');

      expect(result.success, isTrue, reason: result.error ?? result.output);
      expect(await File(path).readAsString(), 'keep-a\nkeep-b\n');
    });

    test('L-P3: old 不唯一 → 拒绝且文件不变', () async {
      final path = p.join(tempDir.path, 'dup.txt');
      const original = 'listen 80;\nlisten 80;\n';
      await File(path).writeAsString(original);

      final result = await patchLocal(path, 'listen 80;', 'listen 81;');

      expect(result.success, isFalse);
      expect(result.error, contains('2'));
      expect(await File(path).readAsString(), original);
    });

    test('L-P4: old 未找到 → 拒绝且文件不变', () async {
      final path = p.join(tempDir.path, 'notfound.txt');
      await File(path).writeAsString('abc');
      final result = await patchLocal(path, 'xyz', '123');
      expect(result.success, isFalse);
      expect(result.error, contains('未找到'));
      expect(await File(path).readAsString(), 'abc');
    });

    test('L-P5: 文件不存在 → 拒绝且不创建文件', () async {
      final path = p.join(tempDir.path, 'missing.txt');
      final result = await patchLocal(path, 'a', 'b');
      expect(result.success, isFalse);
      expect(result.error, contains('不存在'));
      expect(await File(path).exists(), isFalse);
    });

    test('L-P6: 备份开启时生成原内容备份', () async {
      final path = p.join(tempDir.path, 'patch-backup.txt');
      await File(path).writeAsString('value=旧\n');

      final result = await patchLocal(path, '旧', '新', backup: true);

      expect(result.success, isTrue, reason: result.error ?? result.output);
      expect(await File(path).readAsString(), 'value=新\n');
      final backups = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('patch-backup.txt.bak.'))
          .toList();
      expect(backups, hasLength(1));
      expect(await backups.single.readAsString(), 'value=旧\n');
    });

    test('L-P8: 单行中文用 old/new 纯文本参数（无需 base64）', () async {
      final path = p.join(tempDir.path, 'plain.txt');
      await File(path).writeAsString('name = 旧值\n保留 😀\n');

      final result = await patchTool.execute(
        executor: local,
        args: {
          'path': path,
          'old': 'name = 旧值',
          'new': 'name = 新值 😀',
          'backup': false,
        },
      );

      expect(result.success, isTrue, reason: result.error ?? result.output);
      expect(await File(path).readAsString(), 'name = 新值 😀\n保留 😀\n');
    });

    test('L-P9: old 纯文本优先于缺失的 old_b64，且可删除内容', () async {
      final path = p.join(tempDir.path, 'plain-delete.txt');
      await File(path).writeAsString('keep\nremove 中文\nkeep2\n');

      final result = await patchTool.execute(
        executor: local,
        args: {
          'path': path,
          'old': 'remove 中文\n',
          'new_b64': '',
          'backup': false,
        },
      );

      expect(result.success, isTrue, reason: result.error ?? result.output);
      expect(await File(path).readAsString(), 'keep\nkeep2\n');
    });

    test('L-P7: 多行中文 old/new 正确替换', () async {
      final path = p.join(tempDir.path, 'multi.txt');
      const original = '标题\n第一段：中文 😀\n第二段：保留\n结尾\n';
      await File(path).writeAsString(original);

      final result = await patchLocal(
        path,
        '第一段：中文 😀\n第二段：保留\n',
        '第一段：已修改 ✅\n第二段：仍保留\n',
      );

      expect(result.success, isTrue, reason: result.error ?? result.output);
      expect(
        await File(path).readAsString(),
        '标题\n第一段：已修改 ✅\n第二段：仍保留\n结尾\n',
      );
    });
  });
}
