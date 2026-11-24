import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// 转发方向：local = 本地端口 → 远端目标（ssh -L）；
/// remote = 远端端口 → 本地目标（ssh -R）。
enum ForwardDirection { local, remote }

class PortForwardRule {
  PortForwardRule({
    required this.id,
    required this.direction,
    required this.bindHost,
    required this.bindPort,
    required this.targetHost,
    required this.targetPort,
  });

  final String id;
  final ForwardDirection direction;
  final String bindHost;
  final int bindPort;
  final String targetHost;
  final int targetPort;

  bool active = false;
  String? error;

  /// 累计转发的连接数
  int connections = 0;

  String get label => direction == ForwardDirection.local
      ? '$bindHost:$bindPort → $targetHost:$targetPort'
      : '$targetHost:$targetPort ← $bindHost:$bindPort';
}

/// 双向管道端点：Socket 与 SSHForwardChannel 都适配成这个形状，便于单测。
typedef PipeEndpoint = ({
  Stream<List<int>> stream,
  StreamSink<List<int>> sink,
  Future<void> Function() close,
});

PipeEndpoint socketEndpoint(Socket s) =>
    (stream: s, sink: s, close: () => s.close());

PipeEndpoint channelEndpoint(SSHForwardChannel c) =>
    (stream: c.stream, sink: c.sink, close: () => c.close());

/// 双向泵送，任一侧结束/出错即关闭两侧（订阅必须取消，R2）。
Future<void> pipeEndpoints(PipeEndpoint a, PipeEndpoint b) {
  final done = Completer<void>();
  StreamSubscription<List<int>>? subA;
  StreamSubscription<List<int>>? subB;
  void finish() {
    if (done.isCompleted) return;
    subA?.cancel();
    subB?.cancel();
    a.close().catchError((_) {});
    b.close().catchError((_) {});
    done.complete();
  }

  subA = a.stream.listen(b.sink.add, onError: (_) => finish(), onDone: finish);
  subB = b.stream.listen(a.sink.add, onError: (_) => finish(), onDone: finish);
  return done.future;
}

/// 单个标签的端口转发管理。生命周期跟随标签：关标签/页面销毁时 dispose。
/// 连接断开后转发随之失效，规则保留错误状态供 UI 展示，重连后需重新添加。
class PortForwardService extends ChangeNotifier {
  final List<PortForwardRule> _rules = [];
  final Map<String, Future<void> Function()> _stoppers = {};
  bool _disposed = false;

  List<PortForwardRule> get rules => List.unmodifiable(_rules);

  /// 本地转发：bindHost:bindPort 的入站连接经 SSH 转到 targetHost:targetPort。
  /// 默认只绑回环地址，避免把转发端口暴露到局域网。
  Future<PortForwardRule> addLocal(
    SSHClient client, {
    String bindHost = '127.0.0.1',
    required int bindPort,
    required String targetHost,
    required int targetPort,
  }) async {
    final rule = PortForwardRule(
      id: UniqueKey().toString(),
      direction: ForwardDirection.local,
      bindHost: bindHost,
      bindPort: bindPort,
      targetHost: targetHost,
      targetPort: targetPort,
    );
    _rules.add(rule);
    try {
      final server = await ServerSocket.bind(bindHost, bindPort);
      rule.active = true;
      final sub = server.listen((socket) async {
        rule.connections++;
        _safeNotify();
        try {
          final channel = await client.forwardLocal(targetHost, targetPort);
          await pipeEndpoints(socketEndpoint(socket), channelEndpoint(channel));
        } catch (_) {
          try {
            socket.destroy();
          } catch (_) {}
        }
      }, onError: (Object e) {
        rule.error = e.toString();
        rule.active = false;
        _safeNotify();
      });
      _stoppers[rule.id] = () async {
        await sub.cancel();
        await server.close();
      };
    } catch (e) {
      rule.error = e.toString();
    }
    _safeNotify();
    return rule;
  }

  /// 远程转发：远端 bindHost:bindPort 的入站连接经 SSH 转回本地 target。
  Future<PortForwardRule> addRemote(
    SSHClient client, {
    String bindHost = '127.0.0.1',
    required int bindPort,
    required String targetHost,
    required int targetPort,
  }) async {
    final rule = PortForwardRule(
      id: UniqueKey().toString(),
      direction: ForwardDirection.remote,
      bindHost: bindHost,
      bindPort: bindPort,
      targetHost: targetHost,
      targetPort: targetPort,
    );
    _rules.add(rule);
    try {
      final forward =
          await client.forwardRemote(host: bindHost, port: bindPort);
      if (forward == null) {
        rule.error = '服务器拒绝了转发请求（检查 sshd AllowTcpForwarding）';
      } else {
        rule.active = true;
        final sub = forward.connections.listen((channel) async {
          rule.connections++;
          _safeNotify();
          try {
            final socket = await Socket.connect(targetHost, targetPort,
                timeout: const Duration(seconds: 10));
            await pipeEndpoints(
                socketEndpoint(socket), channelEndpoint(channel));
          } catch (_) {
            channel.destroy();
          }
        });
        _stoppers[rule.id] = () async {
          await sub.cancel();
          forward.close();
        };
      }
    } catch (e) {
      rule.error = e.toString();
    }
    _safeNotify();
    return rule;
  }

  Future<void> remove(String id) async {
    final stopper = _stoppers.remove(id);
    _rules.removeWhere((r) => r.id == id);
    _safeNotify();
    if (stopper != null) {
      try {
        await stopper();
      } catch (e) {
        debugPrint('[PortForward] 停止转发失败: $e');
      }
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final stopper in _stoppers.values) {
      stopper().catchError((Object e) {
        debugPrint('[PortForward] dispose 停止转发失败: $e');
      });
    }
    _stoppers.clear();
    _rules.clear();
    super.dispose();
  }
}
