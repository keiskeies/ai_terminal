/// 分屏里「额外 pane」的会话通道（文档 §4 方案 B）。
///
/// 只有**额外** pane 走这里：第一个 pane 就是标签本身，它的 service /
/// outputController / executor 绑定全在 `TerminalTab` 上，一律不动 ——
/// AI 的写入因此天然留在第一个 pane（默认绑定），分屏不会把命令打到别的屏。
///
/// 两种实现：
/// - 本地：一个 pane 一个真实 PTY 进程（各开各的，AI 走独立进程不受影响，事实 B）；
/// - SSH：`client.shell()` 在**已有连接**上再开一个会话，不新建 TCP（事实 A 的
///   共享连接保留，只是多一条 shell 通道）。额外 pane 是纯用户终端，
///   永不注册 executor，AI 绝不写入它。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';

import '../utils/terminal_charset.dart';
import 'local_terminal_service.dart';

/// 一个 pane 的输入输出通道。页面只认这个接口，不关心底下是 PTY 还是 SSH。
///
/// 两种实现都遵守同一条约定：**通道自己死掉时必须自行 `close()`**。
/// 只有 close 会关 [output]，页面正是靠 `output` 的 onDone 才知道「这一屏断了」
/// 并亮出重开入口；不关流的话那一屏会一直显示成活着，敲键却没有反应。
abstract class PaneSession {
  Stream<String> get output;

  bool get isConnected;

  /// 用户按键写入（编码感知）
  void writeToTerminal(String data);

  void resize(int columns, int rows);

  /// 幂等：关两次不报错
  void close();

  bool get isClosed;
}

/// 本地 pane：自己起一个 PTY。
class LocalPaneSession implements PaneSession {
  LocalPaneSession._(this._service);

  final LocalTerminalService _service;
  StreamSubscription<String>? _sub;
  StreamSubscription<void>? _exitSub;
  final StreamController<String> _out = StreamController<String>.broadcast();
  bool _closed = false;

  /// 转发给页面。
  ///
  /// 必须查 `isClosed`：`cancel()` 是异步的，close 之后仍可能有已经排队的输出
  /// 事件投递过来，对已关闭的 controller `add` 会抛 StateError（R2）。
  /// 而 close 常常正是输出流自己触发的（shell 退出），二者必然交叠。
  void _emit(String data) {
    if (_out.isClosed) return;
    _out.add(data);
  }

  static Future<LocalPaneSession?> start() async {
    if (!LocalTerminalService.isSupported) return null;
    final service = LocalTerminalService();
    try {
      await service.start();
    } catch (e) {
      service.dispose();
      debugPrint('[LocalPaneSession] PTY 启动失败: $e');
      return null;
    }
    if (!service.isConnected) {
      service.dispose();
      return null;
    }
    final session = LocalPaneSession._(service);
    session._sub = service.output.listen(session._emit);
    // shell 自己退出（用户敲 exit、进程被杀）：service 不关输出流（主标签还要读
    // 回滚），所以这里听退出事件并自行 close，页面才能收到断流提示。
    session._exitSub = service.onExit.listen((_) => session.close());
    // 订阅之前就已经退出（起得快、崩得也快，比如 shell 路径不对）：事件不会
    // 再来了，这里补一次判定，否则这一屏会停在「连着但没输出」的假活状态。
    if (!session.isConnected) session.close();
    return session;
  }

  @override
  Stream<String> get output => _out.stream;

  @override
  bool get isConnected => !_closed && _service.isConnected;

  @override
  void writeToTerminal(String data) {
    if (_closed) return;
    _service.writeToTerminal(data);
  }

  @override
  void resize(int columns, int rows) {
    if (_closed) return;
    _service.resize(columns, rows);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _sub?.cancel();
    _sub = null;
    _exitSub?.cancel();
    _exitSub = null;
    _service.disconnect();
    _service.dispose();
    _out.close();
  }

  @override
  bool get isClosed => _closed;
}

/// SSH pane：复用标签已有的 `SSHClient`，在它上面再开一条 shell。
///
/// 生命周期归调用方持有的 client 管：client 断开（掉线/关标签）后这里的
/// 会话随之失效，`close()` 只关自己那条 shell，绝不碰 client。
class SshPaneSession implements PaneSession {
  SshPaneSession._(this._session, this._encoding);

  final SSHSession _session;
  final String _encoding;
  final OrderedCharsetWriter _writer = OrderedCharsetWriter();
  final StreamController<String> _out = StreamController<String>.broadcast();
  final List<StreamSubscription<void>> _subs = [];
  bool _closed = false;

  static Future<SshPaneSession?> open(
    SSHClient client, {
    required String encoding,
    int columns = 80,
    int rows = 24,
  }) async {
    try {
      final session = await client.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: columns,
          height: rows,
        ),
      );
      final pane = SshPaneSession._(session, encoding);
      pane._bind(session);
      return pane;
    } catch (e) {
      debugPrint('[SshPaneSession] 打开 shell 会话失败: $e');
      return null;
    }
  }

  void _bind(SSHSession session) {
    // 主机侧关掉这条 shell（shell 退出、sshd 断链）→ stdout 完结。必须自行
    // close：否则 _out 永不关流，页面既不会提示也不会给重开入口，这一屏就
    // 永久停在「看着还在、敲键没反应」。
    _subs.add(decodeTerminalOutput(session.stdout.cast<List<int>>(), _encoding)
        .listen(_emit, onError: (_) => close(), onDone: close));
    _subs.add(decodeTerminalOutput(session.stderr.cast<List<int>>(), _encoding)
        .listen(_emit, onError: (_) => close()));
  }

  /// 同 `LocalPaneSession._emit`：close 由输出流自身触发，晚到的事件必须丢弃
  /// 而不是 add 到已关闭的 controller（R2）。
  void _emit(String data) {
    if (_out.isClosed) return;
    _out.add(data);
  }

  @override
  Stream<String> get output => _out.stream;

  @override
  bool get isConnected => !_closed;

  @override
  void writeToTerminal(String data) {
    if (_closed) return;
    // 非 UTF-8 主机要排队编码，否则会乱序（与 SSHService 同一套做法）
    _writer
        .write(data, _encoding, (bytes) {
          if (!_closed) _session.write(bytes);
        })
        .catchError((Object _) {});
  }

  @override
  void resize(int columns, int rows) {
    if (_closed) return;
    if (columns <= 0 || rows <= 0) return;
    try {
      _session.resizeTerminal(columns, rows);
    } catch (_) {}
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    try {
      _session.close();
    } catch (_) {}
    _out.close();
  }

  @override
  bool get isClosed => _closed;
}
