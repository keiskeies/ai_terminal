import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import '../models/host_config.dart';
import 'command_executor.dart';

/// SSH 连接状态
enum SSHConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// SSH 连接错误
class SSHConnectionError implements Exception {
  final String message;
  SSHConnectionError(this.message);

  @override
  String toString() => message;
}

/// SSH 服务
class SSHService implements CommandExecutor {
  final HostConfig config;
  final StreamController<String> outputController = StreamController<String>.broadcast();

  SSHSession? _session;
  SSHClient? _client;
  SSHSocket? _socket;
  bool _isConnected = false;
  String _osInfo = '';

  // 跳板机相关
  SSHClient? _jumpClient;
  SSHSocket? _jumpSocket;

  // 命令执行等待：用唯一标记 + 退出码检测
  final StringBuffer _outputBuffer = StringBuffer();
  final _promptRegex = RegExp(r'[\]\$#]\s*$');
  final List<Completer<String>> _completers = [];

  // 唯一标记计数器，用于检测命令完成
  int _markerSeq = 0;

  SSHService(this.config);

  bool get isConnected => _isConnected;
  String get osInfo => _osInfo;
  Stream<String> get output => outputController.stream;
  SSHConnectionState get state =>
      _isConnected ? SSHConnectionState.connected : SSHConnectionState.disconnected;

  Future<void> connect({
    String? password,
    String? privateKeyContent,
    String? passphrase,
    HostConfig? jumpHostConfig,
    String? jumpPassword,
    String? jumpPrivateKeyContent,
  }) async {
    try {
      outputController.add('正在连接 ${config.host}:${config.port}...\n');

      // 如果配置了跳板机
      if (jumpHostConfig != null) {
        outputController.add('通过跳板机 ${jumpHostConfig.host} 中转连接...\n');

        // 1. 先连接跳板机（加超时）
        _jumpSocket = await SSHSocket.connect(
          jumpHostConfig.host,
          jumpHostConfig.port,
          timeout: const Duration(seconds: 15),
        );
        _jumpClient = SSHClient(
          _jumpSocket!,
          username: jumpHostConfig.username,
          onPasswordRequest: () => jumpPassword ?? '',
          identities: jumpPrivateKeyContent != null
              ? [...SSHKeyPair.fromPem(jumpPrivateKeyContent)]
              : null,
        );

        // 2. 通过跳板机端口转发到目标
        final forwardSocket = await _jumpClient!.forwardLocal(
          config.host,
          config.port,
        );

        _socket = forwardSocket;
      } else {
        // 直连（加超时）
        _socket = await SSHSocket.connect(
          config.host,
          config.port,
          timeout: const Duration(seconds: 15),
        );
      }

      _client = SSHClient(
        _socket!,
        username: config.username,
        onPasswordRequest: () => password ?? '',
        identities: privateKeyContent != null
            ? [
                ...SSHKeyPair.fromPem(privateKeyContent, passphrase),
              ]
            : null,
      );

      // 验证连通性
      try {
        final echoResult = await _client!.execute("echo 'OK'");
        await echoResult.stdout.cast<List<int>>().transform(utf8.decoder).join();
        outputController.add('连接验证通过\n');
      } catch (e) {
        outputController.add('连接验证跳过: $e\n');
      }

      // 获取系统信息
      try {
        final sysInfo = await _client!.execute('uname -s -m');
        _osInfo = (await sysInfo.stdout.cast<List<int>>().transform(utf8.decoder).join()).trim();
      } catch (e) {
        debugPrint('[SSHService] 获取系统信息失败: $e');
        _osInfo = 'Unknown';
      }

      // 打开 Shell
      _session = await _client!.shell(
        pty: const SSHPtyConfig(
          type: 'xterm-256color',
          width: 80,
          height: 24,
        ),
      );

      _session!.stdout.listen(
        (data) {
          final output = utf8.decode(data, allowMalformed: true);
          outputController.add(output);
          _onShellData(output);
        },
        onError: (error) {
          outputController.add('\r\n[错误] $error\r\n');
          _isConnected = false;
        },
        onDone: () {
          outputController.add('\r\n[连接已关闭]\r\n');
          _isConnected = false;
        },
      );

      _session!.stderr.listen(
        (data) {
          outputController.add(utf8.decode(data, allowMalformed: true));
        },
      );

      _isConnected = true;

      await Future.delayed(const Duration(milliseconds: 300));
      _session!.write(Uint8List.fromList(utf8.encode(
        'export LS_COLORS="rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:ca=30;41:tw=30;42:ow=34;42:st=37;44:ex=01;32";'
        'alias ls="ls --color=auto" 2>/dev/null;'
        'alias ll="ls -la --color=auto" 2>/dev/null;'
        'alias grep="grep --color=auto" 2>/dev/null;'
        'clear\n'
      )));

      outputController.add('\r\n✅ 连接成功\r\n');
      outputController.add('OS: $_osInfo\r\n');
      outputController.add('\$ ');

    } catch (e) {
      _isConnected = false;
      outputController.add('\r\n❌ 连接失败: $e\r\n');
      rethrow;
    }
  }

  /// Shell 数据回调 - 检测 prompt 判断命令执行完毕
  void _onShellData(String data) {
    _outputBuffer.write(data);

    // 检测是否出现 prompt（表示命令执行完毕）
    if (_promptRegex.hasMatch(data)) {
      for (final c in _completers) {
        if (!c.isCompleted) {
          c.complete(_outputBuffer.toString());
        }
      }
      _completers.clear();
      _outputBuffer.clear();
    }
  }

  /// 执行命令并等待完成（旧接口，保留兼容）
  Future<String> executeAndWaitLegacy(String command, {int timeoutSec = 30}) async {
    if (_session == null || !_isConnected) {
      throw SSHConnectionError('未连接');
    }

    final completer = Completer<String>();
    _completers.add(completer);

    _session!.write(Uint8List.fromList(utf8.encode('$command\n')));

    return completer.future.timeout(
      Duration(seconds: timeoutSec),
      onTimeout: () {
        _completers.remove(completer);
        throw TimeoutException('命令执行超时');
      },
    );
  }

  /// 执行命令并等待完成，返回结构化结果（含退出码）
  /// 通过在命令后追加 echo "EXITCODE:$?" 来捕获退出码
  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
  }) async {
    if (_session == null || !_isConnected) {
      return CommandResult(
        stdout: '',
        stderr: '未连接',
        exitCode: -1,
        duration: Duration.zero,
      );
    }

    final stopwatch = Stopwatch()..start();
    _markerSeq++;
    final marker = 'EXITCODE_$_markerSeq:';
    // 追加 echo 标记，命令完成后输出 "EXITCODE_N:0" 格式
    final wrappedCommand = '$command; echo "$marker\$?"';

    // 独立流监听：等待 marker 出现（比 prompt regex 更可靠）
    final buffer = StringBuffer();
    final doneCompleter = Completer<void>();
    StreamSubscription<String>? sub;

    sub = outputController.stream.listen(
      (data) {
        buffer.write(data);
        if (!doneCompleter.isCompleted && buffer.toString().contains(marker)) {
          doneCompleter.complete();
        }
      },
      onError: (e) {
        if (!doneCompleter.isCompleted) {
          doneCompleter.completeError(e);
        }
      },
    );

    _session!.write(Uint8List.fromList(utf8.encode('$wrappedCommand\n')));

    try {
      await Future.any([
        doneCompleter.future,
        Future.delayed(timeout, () => throw TimeoutException('命令执行超时')),
        if (cancelToken != null) cancelToken.future,
      ]);
    } on TimeoutException {
      await sub.cancel();
      stopwatch.stop();
      return CommandResult(
        stdout: buffer.toString(),
        stderr: '',
        exitCode: -1,
        duration: stopwatch.elapsed,
        timedOut: true,
      );
    } catch (e) {
      await sub.cancel();
      stopwatch.stop();
      return CommandResult(
        stdout: buffer.toString(),
        stderr: e.toString(),
        exitCode: -1,
        duration: stopwatch.elapsed,
      );
    }

    await sub.cancel();
    stopwatch.stop();

    var rawOutput = buffer.toString();

    // 取消时 marker 可能未出现
    if (!rawOutput.contains(marker)) {
      return CommandResult(
        stdout: rawOutput,
        stderr: '',
        exitCode: -1,
        duration: stopwatch.elapsed,
      );
    }

    // 从输出中提取退出码
    final exitCodeRegex = RegExp('$marker(\\d+)');
    final match = exitCodeRegex.firstMatch(rawOutput);
    int exitCode = 0;
    if (match != null) {
      exitCode = int.tryParse(match.group(1) ?? '0') ?? 0;
      rawOutput = rawOutput.replaceAll('$marker$exitCode', '');
    }

    // 清理输出：移除命令回显和末尾 prompt
    var cleanOutput = rawOutput;
    final cmdEchoIdx = cleanOutput.indexOf(wrappedCommand);
    if (cmdEchoIdx >= 0) {
      cleanOutput = cleanOutput.substring(cmdEchoIdx + wrappedCommand.length);
    }
    cleanOutput = cleanOutput.replaceAll(RegExp(r'[\]\$#]\s*$'), '').trim();

    return CommandResult(
      stdout: cleanOutput,
      stderr: '',
      exitCode: exitCode,
      duration: stopwatch.elapsed,
    );
  }

  void execute(String command) {
    if (_session == null || !_isConnected) {
      outputController.add('[错误] 未连接\r\n');
      return;
    }

    if (command.contains('\n')) {
      _writeMultiLineCommand(command);
    } else {
      _session!.write(Uint8List.fromList(utf8.encode('$command\n')));
    }
  }

  void _writeMultiLineCommand(String command) async {
    final lines = command.split('\n');
    for (int i = 0; i < lines.length; i++) {
      _session!.write(Uint8List.fromList(utf8.encode('${lines[i]}\n')));
      if (i == 0 && lines.first.contains('<<')) {
        await Future.delayed(const Duration(milliseconds: 100));
      } else if (i < lines.length - 1) {
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }
  }

  /// 发送原始输入到终端（用于 xterm 输入）
  void writeToTerminal(String data) {
    if (_session == null || !_isConnected) {
      return;
    }
    _session!.write(Uint8List.fromList(utf8.encode(data)));
  }

  void resize(int columns, int rows) {
    _session?.resizeTerminal(columns, rows);
  }

  Future<void> disconnect() async {
    _isConnected = false;
    _session?.close();
    _client?.close();
    _socket?.destroy();
    _jumpClient?.close();
    _jumpSocket?.destroy();
    _session = null;
    _client = null;
    _socket = null;
    _jumpClient = null;
    _jumpSocket = null;
    outputController.add('\r\n[已断开连接]\r\n');
  }

  void dispose() {
    disconnect();
    outputController.close();
  }
}
