import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// 带 TCP keepalive 的 [SSHSocket]。
///
/// 存在的理由：`SSHSocket.connect` 只收 host/port，没有任何 socket 选项钩子，
/// dart:io 也没有公开的 `soKeepAlive`（只有 `tcpNoDelay`）。半开连接（NAT 静默
/// 回收映射、服务器掉电、链路静默中断）不会送来 FIN/RST，客户端不发字节就永远
/// 不知道链路已死。TCP keepalive 是**无人等待时**也能感知链路死亡的唯一手段
/// ——应用层探测（见 `SSHService` 的活性看门狗）只在有命令在等结果时才会跑。
///
/// 局限必须如实说明：Windows 下每连接的探测参数（空闲/间隔/次数）只能通过
/// `SIO_KEEPALIVE_VALS` 这个 ioctl 设置，而 `setRawOption` 只能传一个 int32，
/// 传不了三元素的 `tcp_keepalive` 结构体。所以 Windows 上只打开 SO_KEEPALIVE，
/// 系统默认空闲 2 小时才探测，实践上等同于没开。等待期的快速发现靠应用层看门狗。
class KeepaliveSSHSocket implements SSHSocket {
  final Socket _socket;

  KeepaliveSSHSocket._(this._socket);

  /// 建立已启用 TCP keepalive 的 TCP 连接。
  ///
  /// keepalive 失败不影响建连结果：探测参数属于"尽力优化"，
  /// 任何 `setRawOption` 异常只记日志。
  static Future<SSHSocket> connect(
    String host,
    int port, {
    Duration? timeout,
    Duration idle = const Duration(seconds: 20),
    Duration interval = const Duration(seconds: 5),
    int probes = 3,
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    applyTcpKeepAlive(
      socket,
      idle: idle,
      interval: interval,
      probes: probes,
    );
    return KeepaliveSSHSocket._(socket);
  }

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();

  @override
  String toString() =>
      'KeepaliveSSHSocket(${_socket.remoteAddress.host}:${_socket.remotePort})';
}

// setsockopt 的 level/option 常量：dart:io 只导出 tcpNoDelay，其余要自己给编号。
const int _soKeepAlive = 0x0008;
// Linux / Android
const int _linuxTcpKeepIdle = 4;
const int _linuxTcpKeepIntvl = 5;
const int _linuxTcpKeepCnt = 6;
// macOS / iOS（BSD 编号体系，与 Linux 完全不同）
const int _bsdTcpKeepIdle = 0x10; // TCP_KEEPALIVE
const int _bsdTcpKeepIntvl = 0x101;
const int _bsdTcpKeepCnt = 0x102;

/// 尽力开启 TCP keepalive 并设置探测节奏。逐项下发，单项失败不影响其余项，
/// 也不影响连接本身（调用方拿到的仍是可用 socket）。
///
/// 返回实际下发成功的选项名，仅用于日志与测试断言。
@visibleForTesting
List<String> applyTcpKeepAlive(
  Socket socket, {
  Duration idle = const Duration(seconds: 20),
  Duration interval = const Duration(seconds: 5),
  int probes = 3,
}) {
  final applied = <String>[];
  final level = RawSocketOption.levelSocket;
  final tcpLevel = RawSocketOption.levelTcp;

  void apply(String name, RawSocketOption option) {
    try {
      socket.setRawOption(option);
      applied.add(name);
    } catch (e) {
      // 平台/驱动不支持属于预期内（Windows 的三个参数就是不支持），
      // 降级即可，绝不能因此让建连失败。
      debugPrint('[SSHKeepalive] $name 设置失败（忽略）: $e');
    }
  }

  apply('SO_KEEPALIVE',
      RawSocketOption.fromInt(level, _soKeepAlive, 1));

  if (Platform.isLinux || Platform.isAndroid) {
    apply('TCP_KEEPIDLE', RawSocketOption.fromInt(
        tcpLevel, _linuxTcpKeepIdle, wholeSeconds(idle)));
    apply('TCP_KEEPINTVL', RawSocketOption.fromInt(
        tcpLevel, _linuxTcpKeepIntvl, wholeSeconds(interval)));
    apply('TCP_KEEPCNT',
        RawSocketOption.fromInt(tcpLevel, _linuxTcpKeepCnt, probes));
  } else if (Platform.isMacOS || Platform.isIOS) {
    apply('TCP_KEEPALIVE', RawSocketOption.fromInt(
        tcpLevel, _bsdTcpKeepIdle, wholeSeconds(idle)));
    apply('TCP_KEEPINTVL', RawSocketOption.fromInt(
        tcpLevel, _bsdTcpKeepIntvl, wholeSeconds(interval)));
    apply('TCP_KEEPCNT',
        RawSocketOption.fromInt(tcpLevel, _bsdTcpKeepCnt, probes));
  } else {
    // Windows：每连接参数需要 SIO_KEEPALIVE_VALS（结构体入参），setRawOption
    // 传不了；此处只有 SO_KEEPALIVE 生效，探测节奏走系统默认的 2 小时。
    debugPrint('[SSHKeepalive] 当前平台只能开启 SO_KEEPALIVE，'
        '每连接探测参数不可设（等待期检测依赖应用层看门狗）');
  }

  return applied;
}

/// keepalive 空闲/间隔在内核里是秒级整数，向下取整且至少 1 秒。
@visibleForTesting
int wholeSeconds(Duration d) => d.inSeconds < 1 ? 1 : d.inSeconds;
