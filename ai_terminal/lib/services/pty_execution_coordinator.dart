import 'dart:async';
import 'dart:math';

/// 单个 PTY/SSH 会话的命令执行互斥。
///
/// 必须是实例字段：不同会话仍可并行。等待者按 FIFO 获取会话，已取消的等待者
/// 不会占位，也不会阻止后面的调用。
class PtyExecutionMutex {
  final List<Completer<void>> _waiters = [];
  bool _locked = false;

  Future<bool> acquire({Completer<void>? cancelToken}) async {
    if (cancelToken?.isCompleted ?? false) return false;
    if (!_locked) {
      _locked = true;
      return true;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    try {
      await Future.any<void>([
        waiter.future,
        if (cancelToken != null) cancelToken.future,
      ]);
    } catch (_) {
      if (waiter.isCompleted) return true;
      _waiters.remove(waiter);
      return false;
    }
    // 同时获得锁和收到取消时，以已经取得的锁为准；finally 仍负责释放。
    if (waiter.isCompleted) return true;
    _waiters.remove(waiter);
    return false;
  }

  void _drain() {
    if (_locked) return;
    while (_waiters.isNotEmpty) {
      final first = _waiters.removeAt(0);
      if (!first.isCompleted) {
        _locked = true;
        first.complete();
        return;
      }
    }
  }

  void release() {
    if (!_locked) return;
    _locked = false;
    _drain();
  }
}

/// 中断后的 PTY 恢复验证。
///
/// Ctrl+C 只表示“已发送信号”，不能证明前台进程已退出。向 shell 排入一条只输出
/// 随机 ready 标记的命令；只有该标记重新出现，才证明 shell 已夺回 tty 并执行新命令。
/// 若进程吞掉输入或忽略信号，标记不会出现。调用方应关闭这个已无法验证的会话，
/// 不能把下一条命令送进原进程的 stdin。
class PtyInterruptionRecovery {
  static final Random _random = Random.secure();
  static int _sequence = 0;

  static String nextMarker() {
    final nonce = _random.nextInt(0x1000000).toRadixString(16).padLeft(6, '0');
    return 'AI_TERMINAL_READY_${_sequence++}_$nonce:';
  }

  /// [write] 应写入完整的一行（本地为 CR，SSH 为 LF，由调用方适配）。
  /// [interrupt] 单独发送 Ctrl+C，不带行结束符：若 Ctrl+C 和换行一次性写入，
  /// 信号尚未清空行缓冲时换行可能被 shell 当作“提交半条命令”执行。
  static Future<bool> verifyShellReady({
    required Stream<String> output,
    required void Function(String) write,
    required String Function(String marker) readyCommand,
    void Function()? beforeInterrupt,
    void Function()? interrupt,
    Duration firstWait = const Duration(milliseconds: 800),
    Duration escalationWait = const Duration(milliseconds: 1200),
  }) async {
    final marker = nextMarker();
    final ready = Completer<void>();
    // 输出流可能在探测命令发出前就报错（sendProbe 内的短等待跨越事件轮次）；
    // 这里先挂一个消费错误的监听，避免错误在 _wait 挂上监听前被 zone 视为未捕获。
    ready.future.catchError((Object _) {});
    var carry = '';
    final sub = output.listen((data) {
      if (ready.isCompleted) return;
      final combined = carry + data;
      final lines = combined.split(RegExp(r'\r\n|\n|\r'));
      if (lines.any((line) => line == marker)) {
        ready.complete();
        return;
      }
      carry = combined.length >= marker.length
          ? combined.substring(combined.length - marker.length + 1)
          : combined;
    }, onError: (Object error, StackTrace stackTrace) {
      if (!ready.isCompleted) ready.completeError(error, stackTrace);
    });
    final sendInterrupt = interrupt ?? () => write('\x03');
    Future<void> sendProbe() async {
      // PTY/SSH 已关闭时 write 可能同步抛错。验证失败必须 fail closed，
      // 不能让异常穿出调用方、跳过会话清理。
      try {
        sendInterrupt();
      } catch (e) {
        if (!ready.isCompleted) ready.completeError(e);
        return;
      }
      // 给终端驱动一点时间处理 SIGINT、清空行缓冲，再排入探测命令。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (ready.isCompleted) return;
      try {
        write(readyCommand(marker));
      } catch (e) {
        if (!ready.isCompleted) ready.completeError(e);
      }
    }

    try {
      try {
        beforeInterrupt?.call();
      } catch (_) {
        // 分页器退出等前置动作失败不应阻止后续中断与探测。
      }
      await sendProbe();
      if (await _wait(ready, firstWait)) return true;

      // 第二次 SIGINT 是安全的升级：不杀进程树、不提高权限。仍不ready则放弃会话。
      await sendProbe();
      return await _wait(ready, escalationWait);
    } finally {
      await sub.cancel();
    }
  }

  static Future<bool> _wait(Completer<void> ready, Duration timeout) async {
    try {
      await ready.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
