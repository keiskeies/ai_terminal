import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/services/ssh_keepalive_socket.dart';

/// C2：dartssh2 的 `SSHSocket.connect` 没有任何 socket 选项钩子，半开连接
/// （NAT 静默回收映射、对端掉电）不会有 FIN/RST，客户端不发字节就永远不知道链路已死
/// （docs/ssh-disconnect-resilience-design.md F1/F11）。
///
/// 这里能证明的只有"选项确实尽力下发了、下发失败不会拖垮建连"。
/// Windows 的每连接探测参数在 Dart 侧设不了（`SIO_KEEPALIVE_VALS` 要结构体，
/// `setRawOption` 只收 int32），那是平台限制，不是这段代码的 bug——
/// 所以断言按平台分档，不许把 Windows 写成"已保活"。
void main() {
  test('wholeSeconds 向下取整且不低于 1 秒', () {
    // 内核里 keepalive 空闲/间隔是秒级整数；0 会关掉探测，等于白设。
    expect(wholeSeconds(const Duration(seconds: 20)), 20);
    expect(wholeSeconds(const Duration(milliseconds: 900)), 1);
    expect(wholeSeconds(Duration.zero), 1);
    expect(wholeSeconds(const Duration(seconds: 5, milliseconds: 900)), 5);
  });

  group('applyTcpKeepAlive（真实 loopback socket）', () {
    late ServerSocket server;
    late Socket client;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      client = await Socket.connect(
          InternetAddress.loopbackIPv4, server.port);
      await accepted;
    });

    tearDown(() {
      client.destroy();
      server.close();
    });

    test('SO_KEEPALIVE 必然下发，且返回的是实际成功项', () {
      final applied = applyTcpKeepAlive(client);
      expect(applied, contains('SO_KEEPALIVE'));
      expect(applied.length, greaterThanOrEqualTo(1));
    });

    test('POSIX 下三个每连接参数一起下发；Windows 只承诺 SO_KEEPALIVE', () {
      final applied = applyTcpKeepAlive(client);
      if (Platform.isWindows) {
        expect(applied, isNot(contains('TCP_KEEPIDLE')),
            reason: 'Windows 走 SIO_KEEPALIVE_VALS，setRawOption 传不了结构体');
      } else {
        expect(
            applied,
            containsAll(
                ['SO_KEEPALIVE', 'TCP_KEEPINTVL', 'TCP_KEEPCNT']),
            reason: 'Linux 用 TCP_KEEPIDLE、BSD 用 TCP_KEEPALIVE，'
                '两者名字不同但都属"空闲阈值"，故不断言其字面名');
      }
    });

    test('单项下发失败只降级，不影响其余选项', () {
      // 探测节奏设成不可能的值不会让已开的 SO_KEEPALIVE 回滚——
      // 逐项 try/catch 的意义就在这里：一个平台的坏选项不能带走好选项。
      final applied = applyTcpKeepAlive(client,
          idle: const Duration(seconds: 1),
          interval: const Duration(seconds: 1),
          probes: 0);
      expect(applied, contains('SO_KEEPALIVE'));
    });
  });

  group('KeepaliveSSHSocket.connect', () {
    test('建连后 stream/sink 直通原始 socket', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final socket =
          await KeepaliveSSHSocket.connect('127.0.0.1', server.port);
      final remote = await accepted;

      remote.add([1, 2, 3]);
      final received = await socket.stream.first;
      expect(received, [1, 2, 3]);

      socket.sink.add([4, 5]);
      await socket.flush();
      expect(await remote.first, [4, 5]);

      remote.destroy();
      server.close();
    });

    test('目标不可达时抛连接异常，而不是静默返回', () async {
      // 端口 1 在回环上必然拒接。这里要的是"失败要说失败"——
      // 静默返回一个不可用 socket 会让上层把它当成活连接。
      await expectLater(
          KeepaliveSSHSocket.connect('127.0.0.1', 1,
              timeout: const Duration(seconds: 2)),
          throwsA(anything));
    });
  });
}
