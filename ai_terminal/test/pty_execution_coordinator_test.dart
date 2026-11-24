import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/pty_execution_coordinator.dart';

void main() {
  group('PtyExecutionMutex', () {
    test('按 FIFO 获取且只释放一个等待者', () async {
      final mutex = PtyExecutionMutex();
      final order = <String>[];
      expect(await mutex.acquire(), isTrue);
      final second = mutex.acquire().then((acquired) {
        order.add('second');
        return acquired;
      });
      final third = mutex.acquire().then((acquired) {
        order.add('third');
        return acquired;
      });
      await Future<void>.delayed(Duration.zero);
      expect(order, isEmpty);
      mutex.release();
      expect(await second, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(order, ['second']);
      mutex.release();
      expect(await third, isTrue);
      mutex.release();
    });

    test('取消等待者不占位并唤醒下一个', () async {
      final mutex = PtyExecutionMutex();
      final cancelled = Completer<void>();
      final first = mutex.acquire();
      final abandoned = mutex.acquire(cancelToken: cancelled);
      final next = mutex.acquire();
      expect(await first, isTrue);
      cancelled.complete();
      expect(await abandoned, isFalse);
      mutex.release();
      expect(await next, isTrue);
      mutex.release();
    });

    test('取消 token 异常不会遗留等待者或占锁', () async {
      final mutex = PtyExecutionMutex();
      expect(await mutex.acquire(), isTrue);
      final cancelled = Completer<void>();
      final abandoned = mutex.acquire(cancelToken: cancelled);
      final next = mutex.acquire();
      cancelled.completeError(StateError('cancel failed'));
      expect(await abandoned, isFalse);
      mutex.release();
      expect(await next, isTrue);
      mutex.release();
    });

    test('取消与获锁同时发生时由调用方 finally 释放', () async {
      final mutex = PtyExecutionMutex();
      final holder = await mutex.acquire();
      expect(holder, isTrue);
      final cancelled = Completer<void>();
      final waiter = mutex.acquire(cancelToken: cancelled);
      cancelled.complete();
      mutex.release();
      final acquired = await waiter;
      expect(acquired, isTrue);
      if (acquired) mutex.release();
      expect(await mutex.acquire(), isTrue);
      mutex.release();
    });
  });

  group('PtyInterruptionRecovery', () {
    test('收到真实 ready 标记才确认 shell 恢复', () async {
      final controller = StreamController<String>();
      final writes = <String>[];
      addTearDown(controller.close);
      final ready = await PtyInterruptionRecovery.verifyShellReady(
        output: controller.stream,
        write: (line) {
          writes.add(line);
          if (line.startsWith('echo ')) {
            controller.add('${line.substring(5)}\n');
          }
        },
        readyCommand: (marker) => 'echo $marker',
        firstWait: const Duration(milliseconds: 200),
        escalationWait: const Duration(milliseconds: 200),
      );
      expect(ready, isTrue);
      expect(writes.first, '\x03');
      expect(writes, hasLength(2));
    });

    test('命令回显中的 marker 不能证明 shell 已恢复', () async {
      final controller = StreamController<String>();
      final writes = <String>[];
      addTearDown(controller.close);
      final ready = await PtyInterruptionRecovery.verifyShellReady(
        output: controller.stream,
        write: (line) {
          writes.add(line);
          if (line != '\x03') controller.add('$line\n');
        },
        readyCommand: (marker) => 'echo $marker',
        firstWait: const Duration(milliseconds: 20),
        escalationWait: const Duration(milliseconds: 20),
      );
      expect(ready, isFalse);
      expect(writes, hasLength(4));
    });

    test('输出流异常时 fail closed 并释放订阅', () async {
      final controller = StreamController<String>();
      addTearDown(controller.close);
      controller.addError(StateError('output failed'));
      final ready = await PtyInterruptionRecovery.verifyShellReady(
        output: controller.stream,
        write: (_) {},
        readyCommand: (marker) => 'echo $marker',
        firstWait: const Duration(milliseconds: 100),
        escalationWait: const Duration(milliseconds: 100),
      );
      expect(ready, isFalse);
      expect(controller.hasListener, isFalse);
    });

    test('写入通道已关闭（write 抛错）时 fail closed 而不是抛出', () async {
      final controller = StreamController<String>();
      addTearDown(controller.close);
      final ready = await PtyInterruptionRecovery.verifyShellReady(
        output: controller.stream,
        write: (_) => throw StateError('pty closed'),
        interrupt: () => throw StateError('pty closed'),
        readyCommand: (marker) => 'echo $marker',
        firstWait: const Duration(milliseconds: 20),
        escalationWait: const Duration(milliseconds: 20),
      );
      expect(ready, isFalse);
      expect(controller.hasListener, isFalse);
    });

    test('进程吞掉信号时升级一次后放弃会话', () async {
      final controller = StreamController<String>();
      final writes = <String>[];
      addTearDown(controller.close);
      final ready = await PtyInterruptionRecovery.verifyShellReady(
        output: controller.stream,
        write: writes.add,
        readyCommand: (marker) => 'echo $marker',
        firstWait: const Duration(milliseconds: 20),
        escalationWait: const Duration(milliseconds: 20),
      );
      expect(ready, isFalse);
      expect(writes.where((line) => line == '\x03'), hasLength(2));
      expect(writes, hasLength(4));
    });
  });
}
