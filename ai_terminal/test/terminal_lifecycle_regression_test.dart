import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_pty/flutter_pty.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/local_terminal_service.dart';
import 'package:ai_terminal/services/ssh_service.dart';
import 'package:ai_terminal/utils/command_markers.dart';

class _FakePty implements Pty {
  final outputController = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();
  final writes = <String>[];
  void Function(String text)? onWrite;

  @override
  Stream<Uint8List> get output => outputController.stream;

  @override
  Future<int> get exitCode => exit.future;

  @override
  void write(Uint8List data) {
    final text = utf8.decode(data);
    writes.add(text);
    onWrite?.call(text);
  }

  void emit(String text) => outputController.add(utf8.encode(text));

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!exit.isCompleted) exit.complete(-1);
    return true;
  }

  @override
  void resize(int rows, int cols) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSession implements SSHSession {
  final writes = <List<int>>[];
  int closeCalls = 0;

  @override
  void write(Uint8List data) => writes.add(List<int>.of(data));

  @override
  void close() => closeCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SSHService makeSsh() => SSHService(HostConfig.create(
      id: 'lifecycle-host',
      name: 'lifecycle-host',
      host: '127.0.0.1',
      username: 'tester',
      authType: 'password',
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
    CommandMarkers.nonceForTesting = '';
  });
  tearDownAll(() => CommandMarkers.nonceForTesting = null);

  group('LocalTerminalService execution cleanup', () {
    late LocalTerminalService local;
    final ptys = <_FakePty>[];

    _FakePty newPty() {
      final pty = _FakePty();
      ptys.add(pty);
      local.ptyForTesting = pty;
      return pty;
    }

    setUp(() => local = LocalTerminalService());

    tearDown(() async {
      local.dispose();
      for (final pty in ptys) {
        await pty.outputController.close();
      }
      ptys.clear();
    });

    test('write/disconnect 竞态返回失败且不遗留等待者或订阅', () async {
      final first = newPty();
      await local.start();
      first.onWrite = (_) {
        local.disconnect();
        throw StateError('PTY 在命令写入时断开');
      };

      final failed = await local.executeAndWait(
        'first',
        timeout: const Duration(seconds: 2),
      );

      expect(failed.failureKind, CommandFailureKind.disconnected);
      expect(failed.failureReason, contains('命令写入失败'));
      expect(local.pendingExecutionCountForTesting, 0);
      expect(local.hasOutputListenerForTesting, isFalse);

      final second = newPty();
      await local.start();
      second.onWrite = (_) => second.emit('ok\r\nEXITCODE_2:0\r\n');

      final succeeded = await local.executeAndWait(
        'second',
        timeout: const Duration(seconds: 2),
      );

      expect(succeeded.exitCode, 0, reason: '第一次失败不能卡死执行锁或污染下一条命令');
      expect(succeeded.stdout, 'ok');
      expect(local.pendingExecutionCountForTesting, 0);
      expect(local.hasOutputListenerForTesting, isFalse);
    });
  });

  group('SSHService lifecycle', () {
    late SSHService ssh;

    setUp(() {
      ssh = makeSsh()..isConnectedForTesting = true;
      ssh.confirmAliveForTesting();
    });

    tearDown(() => ssh.dispose());

    test('掉线回调抛异常仍关闭未恢复的会话并返回结果', () async {
      final session = _FakeSession();
      ssh.sessionForTesting = session;
      var callbacks = 0;
      ssh.onDisconnected = () {
        callbacks++;
        throw StateError('UI callback failed');
      };

      final result = await ssh.executeAndWait(
        'quiet-command',
        timeout: const Duration(milliseconds: 20),
      );

      expect(result.timedOut, isTrue);
      expect(result.failureKind, CommandFailureKind.timeout);
      expect(callbacks, 1);
      expect(session.closeCalls, 1, reason: '回调异常不能跳过资源关闭');
      expect(ssh.pendingExecutionCountForTesting, 0);
      expect(ssh.isConnected, isFalse);
    });

    test('活性探测期间 session 被替换时旧命令不写入新会话', () async {
      final original = _FakeSession();
      final replacement = _FakeSession();
      ssh.sessionForTesting = original;
      ssh.expireAliveConfirmationForTesting();
      ssh.livenessProbeForTesting = () async {
        ssh.sessionForTesting = replacement;
      };

      final result = await ssh.executeAndWait(
        'old-command',
        timeout: const Duration(seconds: 2),
      );

      expect(result.failureKind, CommandFailureKind.disconnected);
      expect(result.failureReason, contains('被替换'));
      expect(original.writes, isEmpty);
      expect(replacement.writes, isEmpty);
      expect(ssh.outputController.hasListener, isFalse);
      expect(ssh.pendingExecutionCountForTesting, 0);
    });

    test('活性探测期间取消时不写入或注册命令完成', () async {
      final session = _FakeSession();
      final cancel = Completer<void>();
      ssh.sessionForTesting = session;
      ssh.expireAliveConfirmationForTesting();
      ssh.livenessProbeForTesting = () async {
        cancel.complete();
      };

      final result = await ssh.executeAndWait(
        'cancelled-command',
        timeout: const Duration(seconds: 2),
        cancelToken: cancel,
      );

      expect(result.failureKind, CommandFailureKind.cancelled);
      expect(session.writes, isEmpty);
      expect(ssh.outputController.hasListener, isFalse);
      expect(ssh.pendingExecutionCountForTesting, 0);
    });

    test('活性探测期间主动断开按 disconnected 返回且不触发掉线回调', () async {
      final session = _FakeSession();
      var callbacks = 0;
      ssh.sessionForTesting = session;
      ssh.onDisconnected = () => callbacks++;
      ssh.expireAliveConfirmationForTesting();
      ssh.livenessProbeForTesting = () async {
        await ssh.disconnect();
      };

      final result = await ssh.executeAndWait(
        'interrupted-command',
        timeout: const Duration(seconds: 2),
      );

      expect(result.failureKind, CommandFailureKind.disconnected);
      expect(session.writes, isEmpty);
      expect(session.closeCalls, 1);
      expect(callbacks, 0, reason: '主动断开不是意外掉线');
      expect(ssh.outputController.hasListener, isFalse);
    });

    test('disconnect 使在建 connect 失效且旧 finally 不破坏较新连接', () async {
      ssh.isConnectedForTesting = false;
      final firstResume = Completer<void>();
      final secondStarted = Completer<void>();
      final secondResume = Completer<void>();
      var attempts = 0;
      late Future<void> newer;
      ssh.connectGateForTesting = () async {
        attempts++;
        if (attempts == 1) {
          await ssh.disconnect();
          newer = ssh.connect();
          await firstResume.future;
          return;
        }
        secondStarted.complete();
        await secondResume.future;
        throw StateError('newer connection stopped by test');
      };

      final older = ssh.connect();
      await secondStarted.future.timeout(const Duration(seconds: 2));
      firstResume.complete();

      await expectLater(
        older,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('已被新连接替代'),
        )),
      );
      expect(ssh.isConnectingForTesting, isTrue,
          reason: '过期 connect 的 finally 不能把新连接标成未在建');

      secondResume.complete();
      await expectLater(newer, throwsStateError);
      expect(ssh.isConnectingForTesting, isFalse);
    });
  });
}
