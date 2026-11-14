import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/session_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecretMasker', () {
    tearDown(() => SecretMasker.clear());

    test('注册期内命中串被掩码，注销后不再掩码', () {
      SecretMasker.register('s3cret!');
      expect(SecretMasker.mask('echo s3cret! done'), 'echo ****** done');
      SecretMasker.unregister('s3cret!');
      expect(SecretMasker.mask('echo s3cret! done'), 'echo s3cret! done');
    });

    test('空/null 注册无效', () {
      SecretMasker.register(null);
      SecretMasker.register('');
      expect(SecretMasker.mask('abc'), 'abc');
    });

    test('多个秘密同时生效', () {
      SecretMasker.register('aaa');
      SecretMasker.register('bbb');
      expect(SecretMasker.mask('aaa bbb'), '****** ******');
    });
  });

  group('SessionRecorder', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('session_log_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => tempDir.path,
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'), null);
      SecretMasker.clear();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('落盘去 ANSI、规范化换行', () async {
      final recorder = SessionRecorder(label: 'test-host');
      await recorder.start();
      expect(recorder.filePath, isNotNull);
      recorder.write('\x1b[31mred\x1b[0m\r\nline2\r');
      await recorder.close();
      final content = await File(recorder.filePath!).readAsString();
      expect(content, contains('red\nline2\n'));
      expect(content.contains('\x1b'), isFalse);
    });

    test('sudo 密码全程不进日志（验收用例）', () async {
      final recorder = SessionRecorder(label: 'sudo-host');
      await recorder.start();
      recorder.write('[sudo] password for user: ');
      // 模拟执行器应答：注册 → 回显到达 → 命令结束注销
      SecretMasker.register('Sup3rSecret');
      recorder.write('Sup3rSecret\r\n');
      SecretMasker.unregister('Sup3rSecret');
      recorder.write('root output ok\r\n');
      await recorder.close();
      final content = await File(recorder.filePath!).readAsString();
      expect(content.contains('Sup3rSecret'), isFalse);
      expect(content, contains('******'));
      expect(content, contains('root output ok'));
    });

    test('密码回显跨 chunk 仍被掩码（holdback 兜底）', () async {
      final recorder = SessionRecorder(label: 'split-host');
      await recorder.start();
      SecretMasker.register('Sup3rSecret');
      recorder.write('Sup3r');
      // 等第一轮刷盘过去，密码前半段应被 holdback 扣住
      await Future<void>.delayed(const Duration(milliseconds: 700));
      recorder.write('Secret\r\n');
      SecretMasker.unregister('Sup3rSecret');
      await recorder.close();
      final content = await File(recorder.filePath!).readAsString();
      expect(content.contains('Sup3rSecret'), isFalse);
      expect(content, contains('******'));
    });

    test('注销后到达的迟到回显也已被到达时掩码', () async {
      final recorder = SessionRecorder(label: 'late-host');
      await recorder.start();
      SecretMasker.register('LateEcho1');
      recorder.write('LateEcho1\r\n');
      // 命令快速结束（超时/取消路径）：注销发生在刷盘之前
      SecretMasker.unregister('LateEcho1');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await recorder.close();
      final content = await File(recorder.filePath!).readAsString();
      expect(content.contains('LateEcho1'), isFalse);
    });

    test('close 后写入被忽略', () async {
      final recorder = SessionRecorder(label: 'closed-host');
      await recorder.start();
      recorder.write('before\r\n');
      await recorder.close();
      recorder.write('after\r\n');
      final content = await File(recorder.filePath!).readAsString();
      expect(content, contains('before'));
      expect(content.contains('after'), isFalse);
    });
  });
}