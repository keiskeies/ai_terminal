import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'command_executor.dart';

/// 本地终端服务 — 使用原生 PTY（伪终端）实现真正的本地 shell
/// 支持 macOS / Linux / Windows，提供与 macOS Terminal / Windows CMD 完全一致的体验
class LocalTerminalService implements CommandExecutor {
  Pty? _pty;
  final StreamController<String> _outputController = StreamController<String>.broadcast();
  bool _isConnected = false;
  bool _isExited = false;

  // 命令执行等待：prompt 检测
  final StringBuffer _outputBuffer = StringBuffer();
  final _promptRegex = RegExp(r'[\]\$#>]\s*$');
  final List<Completer<String>> _completers = [];
  int _markerSeq = 0;

  bool get isConnected => _isConnected;
  Stream<String> get output => _outputController.stream;

  /// 启动本地 PTY shell
  Future<void> start({int columns = 80, int rows = 24}) async {
    if (_isConnected) return;

    try {
      String shell;
      List<String> args;

      if (Platform.isWindows) {
        shell = 'cmd.exe';
        args = [];
      } else {
        final userShell = Platform.environment['SHELL'];
        if (userShell != null && File(userShell).existsSync()) {
          shell = userShell;
        } else if (File('/bin/bash').existsSync()) {
          shell = '/bin/bash';
        } else if (File('/bin/zsh').existsSync()) {
          shell = '/bin/zsh';
        } else if (File('/bin/sh').existsSync()) {
          shell = '/bin/sh';
        } else {
          shell = 'bash';
        }
        args = ['-l'];
      }

      final ptyEnv = Map<String, String>.from(Platform.environment);
      ptyEnv['TERM'] = 'xterm-256color';
      ptyEnv['CLICOLOR'] = '1';
      ptyEnv['LSCOLORS'] = 'ExFxCxDxBxegedabagacad';
      ptyEnv['LS_COLORS'] = 'rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:ca=30;41:tw=30;42:ow=34;42:st=37;44:ex=01;32';

      _pty = Pty.start(
        shell,
        arguments: args,
        workingDirectory: Platform.environment['HOME'] ?? Directory.current.path,
        environment: ptyEnv,
        columns: columns,
        rows: rows,
      );

      _isConnected = true;

      _pty!.output.listen(
        (data) {
          if (!_outputController.isClosed && !_isExited) {
            final output = utf8.decode(data, allowMalformed: true);
            _outputController.add(output);
            _onPtyData(output);
          }
        },
        onDone: _handleExit,
        onError: (e) {
          debugPrint('[LocalTerminal] 输出错误: $e');
          _handleExit();
        },
      );

      _pty!.exitCode.then((_) => _handleExit());
    } catch (e) {
      _outputController.add('\r\n\x1b[31m✗ 本地终端启动失败: $e\x1b[0m\r\n');
      _isConnected = false;
    }
  }

  void _onPtyData(String data) {
    _outputBuffer.write(data);
    // 检测 prompt
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

  void _handleExit() {
    if (_isExited) return;
    _isExited = true;
    _isConnected = false;
    if (!_outputController.isClosed) {
      _outputController.add('\r\n\x1b[90m[进程已退出]\x1b[0m\r\n');
    }
  }

  /// 向终端写入数据（用户键盘输入）
  void writeToTerminal(String data) {
    if (_pty == null || !_isConnected) return;
    _pty!.write(utf8.encode(data));
  }

  /// 执行命令（写入命令 + 回车）
  void execute(String command) {
    if (command.contains('\n')) {
      _executeMultiLine(command);
    } else {
      writeToTerminal('$command\r');
    }
  }

  void _executeMultiLine(String command) async {
    final lines = command.split('\n');
    for (int i = 0; i < lines.length; i++) {
      _pty!.write(utf8.encode('${lines[i]}\r'));
      if (i == 0 && lines.first.contains('<<')) {
        await Future.delayed(const Duration(milliseconds: 100));
      } else if (i < lines.length - 1) {
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }
  }

  /// 执行命令并等待完成，返回结构化结果（含退出码）
  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
  }) async {
    if (_pty == null || !_isConnected) {
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
    final wrappedCommand = '$command; echo "$marker\$?"';

    // 独立流监听：等待 marker 出现（比 prompt regex 更可靠）
    final buffer = StringBuffer();
    final doneCompleter = Completer<void>();
    StreamSubscription<String>? sub;

    sub = _outputController.stream.listen(
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

    _pty!.write(utf8.encode('$wrappedCommand\r'));

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

    // 清理输出
    var cleanOutput = rawOutput;
    final cmdEchoIdx = cleanOutput.indexOf(wrappedCommand);
    if (cmdEchoIdx >= 0) {
      cleanOutput = cleanOutput.substring(cmdEchoIdx + wrappedCommand.length);
    }
    cleanOutput = cleanOutput.replaceAll(RegExp(r'[\]\$#>]\s*$'), '').trim();

    return CommandResult(
      stdout: cleanOutput,
      stderr: '',
      exitCode: exitCode,
      duration: stopwatch.elapsed,
    );
  }

  /// 调整终端大小
  void resize(int columns, int rows) {
    if (_pty == null || !_isConnected) return;
    if (columns <= 0 || rows <= 0) return;
    _pty!.resize(rows, columns);
  }

  /// 断开连接
  void disconnect() {
    if (_isExited) return;
    _isExited = true;
    _isConnected = false;
    _pty?.kill();
    _pty = null;
  }

  /// 释放资源
  void dispose() {
    disconnect();
    _outputController.close();
  }

  /// 是否支持本地终端
  static bool get isSupported => Platform.isMacOS || Platform.isLinux || Platform.isWindows;
}
