import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/services/local_file_tools.dart';
import 'package:ai_terminal/utils/local_file_ops.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _NullExecutor implements CommandExecutor {
  @override
  bool get isConnected => true;

  @override
  Stream<String> get output => const Stream.empty();

  @override
  void execute(String command) {}

  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 1),
    Completer<void>? cancelToken,
    String? sudoPassword,
    Future<String?> Function(String prompt)? onInteractivePrompt,
  }) async =>
      CommandResult(
          stdout: '', stderr: '', exitCode: 0, duration: Duration.zero);

  @override
  Future<String> runOnce(String command,
          {Duration timeout = const Duration(seconds: 1)}) async =>
      '';

  @override
  Future<CommandResult> writeFileViaPty({
    required String path,
    required Uint8List content,
    bool useSudo = false,
    Duration timeout = const Duration(seconds: 1),
    Completer<void>? cancelToken,
  }) async =>
      CommandResult(
          stdout: '', stderr: '', exitCode: 0, duration: Duration.zero);

  @override
  void writeToTerminal(String data) {}
}

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('ai_file_limits_');
    sandbox = Directory(await sandbox.resolveSymbolicLinks());
    await SettingsDao.set('localFilePolicy', {
      'enabled': true,
      'allowedDirs': [sandbox.path],
      'maxReadBytes': 16,
    });
  });

  tearDown(() async {
    await SettingsDao.set('localFilePolicy', {
      'enabled': true,
      'allowedDirs': [],
      'maxReadBytes': 2 * 1024 * 1024,
    });
    await sandbox.delete(recursive: true);
  });

  test('patch 在读取前拒绝超限文件且不修改原内容', () async {
    final file = File(p.join(sandbox.path, 'large.txt'));
    const original = '0123456789abcdef0123456789abcdef';
    await file.writeAsString(original);

    final result = await patchLocalFile(
      path: file.path,
      oldText: 'a',
      newText: 'z',
      maxBytes: 16,
    );

    expect(result.success, isFalse);
    expect(result.error, contains('文件过大'));
    expect(await file.readAsString(), original);
  });

  test('patch 允许恰好等于上限的文件', () async {
    final file = File(p.join(sandbox.path, 'boundary.txt'));
    const original = '0123456789abcdef';
    await file.writeAsString(original);

    final result = await patchLocalFile(
      path: file.path,
      oldText: 'a',
      newText: 'z',
      maxBytes: 16,
    );

    expect(result.success, isTrue, reason: result.error);
    expect(await file.readAsString(), '0123456789zbcdef');
  });

  test('local_file_write 在纯文本转义解码前拒绝超 8KB 原文', () async {
    final file = File(p.join(sandbox.path, 'raw-too-large.txt'));
    final result = await LocalFileWriteTool().execute(
      executor: _NullExecutor(),
      args: ToolArgs({
        'path': file.path,
        'content': r'\n' * 5000,
      }),
    );

    expect(result.success, isFalse);
    expect(result.error, contains('已中止转义解码'));
    expect(await file.exists(), isFalse);
  });

  test('local_file_patch 在 old/new 纯文本编码前拒绝超 64KB 原文', () async {
    final file = File(p.join(sandbox.path, 'raw-patch.txt'));
    const original = 'a';
    await file.writeAsString(original);
    final oversized = 'x' * (64 * 1024 + 1);
    for (final args in [
      {'path': file.path, 'old': oversized, 'new': 'z'},
      {'path': file.path, 'old': 'a', 'new': oversized},
    ]) {
      final result = await LocalFilePatchTool().execute(
        executor: _NullExecutor(),
        args: ToolArgs(args),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('64KB'));
      expect(result.error, contains('已中止'));
      expect(await file.readAsString(), original);
    }
  });

  test('local_file_patch 使用策略字节上限', () async {
    final file = File(p.join(sandbox.path, 'policy-limit.txt'));
    await file.writeAsString('0123456789abcdef');
    final result = await LocalFilePatchTool().execute(
      executor: _NullExecutor(),
      args: ToolArgs({'path': file.path, 'old': 'a', 'new': 'z'}),
    );

    expect(result.success, isTrue, reason: result.error);
    expect(await file.readAsString(), '0123456789zbcdef');
  });

  test('patch 授权复核拒绝时不得提前截断文件', () async {
    final file = File(p.join(sandbox.path, 'authorization.txt'));
    const original = '0123456789abcdef';
    await file.writeAsString(original);
    final result = await patchLocalFile(
      path: file.path,
      oldText: 'a',
      newText: 'z',
      maxBytes: 16,
      authorizeWrite: () async {
        expect(await file.readAsString(), original);
        return '授权已撤销';
      },
    );
    expect(result.success, isFalse);
    expect(result.error, contains('授权已撤销'));
    expect(await file.readAsString(), original);
  });

  test('patch 以非截断模式打开后再执行授权复核', () async {
    final file = File(p.join(sandbox.path, 'authorized.txt'));
    const original = '0123456789abcdef';
    await file.writeAsString(original);
    var checked = false;
    final result = await patchLocalFile(
      path: file.path,
      oldText: 'a',
      newText: 'z',
      maxBytes: 16,
      authorizeWrite: () async {
        checked = true;
        expect(await file.readAsString(), original);
        return null;
      },
    );
    expect(checked, isTrue);
    expect(result.success, isTrue, reason: result.error);
    expect(await file.readAsString(), '0123456789zbcdef');
  });

  test('local_file_write 在 base64 解码前拒绝超限编码', () async {
    final file = File(p.join(sandbox.path, 'too-large.bin'));
    final result = await LocalFileWriteTool().execute(
      executor: _NullExecutor(),
      args: ToolArgs({
        'path': file.path,
        'content_b64': base64Encode(List<int>.filled(16 * 1024, 65)),
      }),
    );

    expect(result.success, isFalse);
    expect(result.error, contains('已中止解码'));
    expect(await file.exists(), isFalse);
  });
}
