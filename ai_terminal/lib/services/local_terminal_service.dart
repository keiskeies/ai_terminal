import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_pty/flutter_pty.dart';
import 'command_executor.dart';

/// 本地终端服务 — 使用原生 PTY（伪终端）实现真正的本地 shell
/// 支持 macOS / Linux / Windows，提供与 macOS Terminal / Windows CMD 完全一致的体验
class LocalTerminalService implements CommandExecutor {
  Pty? _pty;
  final StreamController<String> _outputController = StreamController<String>.broadcast();
  bool _isConnected = false;
  bool _isExited = false;

  bool get isConnected => _isConnected;
  Stream<String> get output => _outputController.stream;

  /// 启动本地 PTY shell
  Future<void> start({int columns = 80, int rows = 24}) async {
    if (_isConnected) return;

    try {
      // 检测 shell 类型
      String shell;
      List<String> args;

      if (Platform.isWindows) {
        // Windows: 使用 cmd.exe
        shell = 'cmd.exe';
        args = [];
      } else {
        // macOS / Linux: 优先使用用户登录 shell
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
        // macOS Catalina 及以上默认 zsh；其他系统默认 bash
        // 使用 -l 以 login shell 模式启动（加载 ~/.zshrc / ~/.bash_profile 等）
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

      // 监听 PTY 输出（stdout + stderr 合并）
      _pty!.output.listen(
        (data) {
          if (!_outputController.isClosed && !_isExited) {
            _outputController.add(utf8.decode(data, allowMalformed: true));
          }
        },
        onDone: _handleExit,
        onError: (_) => _handleExit(),
      );

      // 监听进程退出
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

  /// 调整终端大小（columns=列数, rows=行数）
  void resize(int columns, int rows) {
    if (_pty == null || !_isConnected) return;
    if (columns <= 0 || rows <= 0) return;
    // ⚠️ Pty.resize 的参数顺序是 (rows, cols)，注意调换
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

  /// 是否支持本地终端（仅桌面平台）
  static bool get isSupported => Platform.isMacOS || Platform.isLinux || Platform.isWindows;
}
