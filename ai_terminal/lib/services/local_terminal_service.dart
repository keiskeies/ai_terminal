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

  int _markerSeq = 0;

  // pending 的 doneCompleter，disconnect 时完成避免挂起
  Completer<void>? _pendingDoneCompleter;

  // 当前 shell 类型（影响 wrappedCommand 拼接语法）
  bool _isPowerShell = false;

  @override
  bool get isConnected => _isConnected;
  @override
  Stream<String> get output => _outputController.stream;

  /// 启动本地 PTY shell
  Future<void> start({int columns = 80, int rows = 24}) async {
    if (_isConnected) return;

    try {
      String shell;
      List<String> args;

      if (Platform.isWindows) {
        // Windows 优先 PowerShell（支持 ANSI/更丰富命令），回退 cmd.exe
        if (File('C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe').existsSync()) {
          shell = 'powershell.exe';
          args = ['-NoLogo'];
          _isPowerShell = true;
        } else {
          shell = 'cmd.exe';
          args = [];
          _isPowerShell = false;
        }
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
      if (!Platform.isWindows) {
        ptyEnv['CLICOLOR'] = '1';
        ptyEnv['LSCOLORS'] = 'ExFxCxDxBxegedabagacad';
        ptyEnv['LS_COLORS'] = 'rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:ca=30;41:tw=30;42:ow=34;42:st=37;44:ex=01;32';
      }

      _pty = Pty.start(
        shell,
        arguments: args,
        workingDirectory: Platform.isWindows
            ? (Platform.environment['USERPROFILE'] ?? Directory.current.path)
            : (Platform.environment['HOME'] ?? Directory.current.path),
        environment: ptyEnv,
        columns: columns,
        rows: rows,
      );

      _isConnected = true;

      _pty!.output.listen(
        (data) {
          if (!_outputController.isClosed && !_isExited) {
            _outputController.add(utf8.decode(data, allowMalformed: true));
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

  void _handleExit() {
    if (_isExited) return;
    _isExited = true;
    _isConnected = false;
    final p = _pendingDoneCompleter;
    if (p != null && !p.isCompleted) p.complete();
    if (!_outputController.isClosed) {
      _outputController.add('\r\n\x1b[90m[进程已退出]\x1b[0m\r\n');
    }
  }

  /// 向终端写入数据（用户键盘输入）
  @override
  void writeToTerminal(String data) {
    if (_pty == null || !_isConnected) return;
    _pty!.write(utf8.encode(data));
  }

  /// 执行命令（写入命令 + 回车）
  @override
  void execute(String command) {
    if (command.contains('\n')) {
      _executeMultiLine(command);
    } else {
      writeToTerminal('$command\r');
    }
  }

  /// 一次性执行命令并返回 stdout（不走 PTY，使用 Process.run）
  ///
  /// 用于监控面板等需要轻量、不污染交互式 shell 的场景。
  /// 失败返回空字符串。超时默认 5 秒。
  Future<String> runOnce(String command, {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('cmd', ['/c', command]).timeout(timeout);
        return (result.stdout as String?) ?? '';
      } else {
        final result = await Process.run('/bin/sh', ['-c', command]).timeout(timeout);
        return (result.stdout as String?) ?? '';
      }
    } catch (e) {
      debugPrint('[LocalTerminalService] runOnce 失败 ($command): $e');
      return '';
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
    // 平台+shell 分支：PowerShell 用 ; 和 $LASTEXITCODE，cmd 用 & 和 %errorlevel%
    final wrappedCommand = Platform.isWindows
        ? (_isPowerShell
            ? '$command; echo "$marker\$LASTEXITCODE"'
            : '$command & echo $marker%errorlevel%')
        : '$command; echo "$marker\$?"';
    final donePattern = RegExp('${RegExp.escape(marker)}\\d+');

    // 独立流监听：等待 marker 出现（比 prompt regex 更可靠）
    final buffer = StringBuffer();
    final doneCompleter = Completer<void>();
    _pendingDoneCompleter = doneCompleter;
    StreamSubscription<String>? sub;

    sub = _outputController.stream.listen(
      (data) {
        buffer.write(data);
        if (!doneCompleter.isCompleted && donePattern.hasMatch(buffer.toString())) {
          doneCompleter.complete();
        }
      },
      onError: (e) {
        if (!doneCompleter.isCompleted) {
          doneCompleter.completeError(e);
        }
      },
      onDone: () {
        if (!doneCompleter.isCompleted) {
          doneCompleter.complete();
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
      // 发送 Ctrl+C 中断本地命令，防止后台进程继续输出污染下一条命令
      try {
        _pty!.write(utf8.encode('\x03'));
      } catch (_) {}
      await sub.cancel();
      if (_pendingDoneCompleter == doneCompleter) _pendingDoneCompleter = null;
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
      if (_pendingDoneCompleter == doneCompleter) _pendingDoneCompleter = null;
      stopwatch.stop();
      return CommandResult(
        stdout: buffer.toString(),
        stderr: e.toString(),
        exitCode: -1,
        duration: stopwatch.elapsed,
      );
    }

    await sub.cancel();
    if (_pendingDoneCompleter == doneCompleter) _pendingDoneCompleter = null;
    stopwatch.stop();

    var rawOutput = buffer.toString();

    // 取消时 marker 可能未出现 — 发送 Ctrl+C 停止可能仍在运行的命令
    if (!rawOutput.contains(marker)) {
      try {
        _pty!.write(utf8.encode('\x03'));
      } catch (_) {}
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
    final p = _pendingDoneCompleter;
    if (p != null && !p.isCompleted) p.complete();
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
