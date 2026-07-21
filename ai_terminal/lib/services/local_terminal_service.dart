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

  // pending 的 doneCompleter 集合，进程退出 / disconnect 时全部 complete 避免挂起
  // 用 Set 而非单字段，支持并发执行的 executeAndWait / writeFileViaPty 各自注册
  // 自己的等待者，互不覆盖。
  final Set<Completer<void>> _pendingDoneCompleters = {};

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
    // 进程退出时 complete 所有等待者
    for (final p in _pendingDoneCompleters) {
      if (!p.isCompleted) p.complete();
    }
    _pendingDoneCompleters.clear();
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
  ///
  /// 改进点同 [SshService.executeAndWait]：
  /// 1. buffer 上限（R8 合规，保留尾部 256KB）
  /// 2. Shell 语法错误快速失败（bash/sh/zsh 解析错误）
  /// 3. PS2 提示符检测（引号未闭合）
  /// 4. 交互式密码提示检测
  /// 5. PTY 进程退出区分正常/异常
  /// 6. marker 后停止写入 buffer
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
        failureKind: CommandFailureKind.disconnected,
        failureReason: '本地 PTY 未连接',
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

    // R8: buffer 必须有上限，保留尾部（最新输出）
    const maxBufferChars = 256 * 1024; // 256KB

    // 独立流监听：等待 marker 出现（比 prompt regex 更可靠）
    final buffer = StringBuffer();
    final doneCompleter = Completer<void>();
    var markerSeen = false;
    var abnormalReason = <String?>[];
    _pendingDoneCompleters.add(doneCompleter);
    StreamSubscription<String>? sub;

    sub = _outputController.stream.listen(
      (data) {
        if (doneCompleter.isCompleted) return;
        buffer.write(data);
        if (buffer.length > maxBufferChars) {
          final truncated = buffer.toString();
          buffer
            ..clear()
            ..write(truncated.substring(truncated.length - maxBufferChars));
        }
        final snapshot = buffer.toString();
        if (donePattern.hasMatch(snapshot)) {
          markerSeen = true;
          doneCompleter.complete();
          return;
        }
        final diag = PtyOutputDetector.detect(
          buffer: snapshot,
          marker: marker,
          elapsedMs: stopwatch.elapsedMilliseconds,
          isWindows: Platform.isWindows,
        );
        if (diag != null) {
          abnormalReason.add(diag.reason);
          doneCompleter.complete();
        }
      },
      onError: (e) {
        if (!doneCompleter.isCompleted) {
          abnormalReason.add('Stream error: $e');
          doneCompleter.complete();
        }
      },
      onDone: () {
        if (!doneCompleter.isCompleted) {
          if (!markerSeen) {
            abnormalReason.add('本地 PTY 进程已退出');
            _isConnected = false;
          }
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
      try {
        _pty!.write(utf8.encode('\x03'));
      } catch (_) {}
      await sub.cancel();
      _pendingDoneCompleters.remove(doneCompleter);
      stopwatch.stop();
      return CommandResult(
        stdout: buffer.toString(),
        stderr: '',
        exitCode: -1,
        duration: stopwatch.elapsed,
        timedOut: true,
        failureKind: CommandFailureKind.timeout,
        failureReason: '命令执行超时 (${timeout.inSeconds}s)',
      );
    } catch (e) {
      await sub.cancel();
      _pendingDoneCompleters.remove(doneCompleter);
      stopwatch.stop();
      return CommandResult(
        stdout: buffer.toString(),
        stderr: e.toString(),
        exitCode: -1,
        duration: stopwatch.elapsed,
        failureKind: CommandFailureKind.unknown,
        failureReason: e.toString(),
      );
    }

    await sub.cancel();
    _pendingDoneCompleters.remove(doneCompleter);
    stopwatch.stop();

    var rawOutput = buffer.toString();

    if (!markerSeen) {
      try {
        _pty!.write(utf8.encode('\x03'));
      } catch (_) {}
      final reason = abnormalReason.isNotEmpty
          ? abnormalReason.join('; ')
          : (rawOutput.contains(marker) ? 'marker 出现但未触发完成' : '命令未完成');
      CommandFailureKind kind = CommandFailureKind.unknown;
      if (reason.contains('syntax error') || reason.contains('PS2')) {
        kind = CommandFailureKind.syntaxError;
      } else if (reason.contains('交互式') || reason.contains('password')) {
        kind = CommandFailureKind.interactivePrompt;
      } else if (reason.contains('进程已退出')) {
        kind = CommandFailureKind.disconnected;
      }
      return CommandResult(
        stdout: rawOutput,
        stderr: '',
        exitCode: -1,
        duration: stopwatch.elapsed,
        failureKind: kind,
        failureReason: reason,
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

  /// 通过 PTY stdin 写入本地文件（绕过 shell 转义，继承当前 shell 权限）
  ///
  /// 仅 Unix（macOS/Linux）支持 cat > /path 模式；Windows 直接返回失败
  /// （本地终端用户极少通过 file_write 写本地文件，且 PowerShell/cmd 无 cat 等价物）。
  @override
  Future<CommandResult> writeFileViaPty({
    required String path,
    required Uint8List content,
    bool useSudo = false,
    Duration timeout = const Duration(seconds: 30),
    Completer<void>? cancelToken,
  }) async {
    if (_pty == null || !_isConnected) {
      return CommandResult(
        stdout: '',
        stderr: '未连接',
        exitCode: -1,
        duration: Duration.zero,
        failureKind: CommandFailureKind.disconnected,
        failureReason: '本地 PTY 未连接',
      );
    }
    if (Platform.isWindows) {
      return CommandResult(
        stdout: '',
        stderr: 'Windows 本地终端不支持 PTY stdin 写文件',
        exitCode: -1,
        duration: Duration.zero,
        failureKind: CommandFailureKind.unknown,
        failureReason: 'Windows 本地终端不支持 PTY stdin 写文件，请用 SSH 远程会话或本地编辑器',
      );
    }

    final escapedPath = path.replaceAll("'", "'\\''");
    final parentDir = _posixDirname(path);
    final escapedParent = parentDir.replaceAll("'", "'\\''");

    // 0. 写前预检（关键安全防护）：
    //    若直接发 `cat > /path` 然后流式发文件内容，当 cat 因权限/路径失败时
    //    shell 会立即返回错误，**后续的文件内容会被 shell 当作命令执行**
    //    （如 `[base]` 被当数组语法、`name=foo bar` 被当变量赋值+命令）。
    if (useSudo) {
      final sudoCheck = await executeAndWait(
        "sudo -n true",
        timeout: const Duration(seconds: 5),
        cancelToken: cancelToken,
      );
      if (sudoCheck.failureKind == CommandFailureKind.disconnected) {
        return CommandResult(
          stdout: '',
          stderr: 'sudo 预检时 PTY 退出: ${sudoCheck.failureReason}',
          exitCode: -1,
          duration: Duration.zero,
          failureKind: CommandFailureKind.disconnected,
          failureReason: 'sudo 预检时 PTY 退出: ${sudoCheck.failureReason}',
        );
      }
      if (sudoCheck.exitCode != 0) {
        return CommandResult(
          stdout: '',
          stderr: 'sudo 不可用或需要密码（NOPASSWD 未配置，且密码未缓存）',
          exitCode: -1,
          duration: Duration.zero,
          failureKind: CommandFailureKind.interactivePrompt,
          failureReason: 'sudo 不可用或需要密码。建议先在终端执行一次 sudo 命令缓存密码，'
              '或配置 /etc/sudoers 的 NOPASSWD。',
        );
      }
    } else {
      final permCheck = await executeAndWait(
        "test -w '$escapedPath' || test -w '$escapedParent'",
        timeout: const Duration(seconds: 5),
        cancelToken: cancelToken,
      );
      if (permCheck.failureKind == CommandFailureKind.disconnected) {
        return CommandResult(
          stdout: '',
          stderr: '权限预检时 PTY 退出: ${permCheck.failureReason}',
          exitCode: -1,
          duration: Duration.zero,
          failureKind: CommandFailureKind.disconnected,
          failureReason: '权限预检时 PTY 退出: ${permCheck.failureReason}',
        );
      }
      if (permCheck.exitCode != 0) {
        return CommandResult(
          stdout: '',
          stderr: '权限不足: 当前用户无法写 $path（文件本身和父目录 $parentDir 均不可写）',
          exitCode: -1,
          duration: Duration.zero,
          failureKind: CommandFailureKind.permissionDenied,
          failureReason: '权限不足: 当前用户无法写 $path。'
              '建议：1) sudo -i 切换 root；2) 在 file_write 参数加 use_sudo: true；'
              '3) 检查路径权限（ls -ld $parentDir）',
        );
      }
    }

    final writeCmd = useSudo
        ? "sudo tee '$escapedPath' > /dev/null"
        : "cat > '$escapedPath'";

    final stopwatch = Stopwatch()..start();
    _markerSeq++;
    final marker = 'EXITCODE_$_markerSeq:';
    final wrappedCommand = '$writeCmd; echo "$marker\$?"';
    final donePattern = RegExp('${RegExp.escape(marker)}\\d+');

    const maxBufferChars = 256 * 1024;
    final buffer = StringBuffer();
    final doneCompleter = Completer<void>();
    var markerSeen = false;
    var abnormalReason = <String?>[];
    _pendingDoneCompleters.add(doneCompleter);
    StreamSubscription<String>? sub;

    sub = _outputController.stream.listen(
      (data) {
        if (doneCompleter.isCompleted) return;
        buffer.write(data);
        if (buffer.length > maxBufferChars) {
          final truncated = buffer.toString();
          buffer
            ..clear()
            ..write(truncated.substring(truncated.length - maxBufferChars));
        }
        final snapshot = buffer.toString();
        if (donePattern.hasMatch(snapshot)) {
          markerSeen = true;
          doneCompleter.complete();
          return;
        }
        final diag = PtyOutputDetector.detect(
          buffer: snapshot,
          marker: marker,
          elapsedMs: stopwatch.elapsedMilliseconds,
          isWindows: false,
        );
        if (diag != null) {
          abnormalReason.add(diag.reason);
          doneCompleter.complete();
        }
      },
      onError: (e) {
        if (!doneCompleter.isCompleted) {
          abnormalReason.add('Stream error: $e');
          doneCompleter.complete();
        }
      },
      onDone: () {
        if (!doneCompleter.isCompleted) {
          if (!markerSeen) {
            abnormalReason.add('本地 PTY 进程已退出');
            _isConnected = false;
          }
          doneCompleter.complete();
        }
      },
    );

    // 1. 发送写入命令
    _pty!.write(utf8.encode('$wrappedCommand\r'));

    // 2. 等待 shell 进入 stdin 等待状态
    await Future.delayed(const Duration(milliseconds: 100));

    // 3. 逐行发送文件内容
    final hasTrailingNewline = content.isNotEmpty && content.last == 0x0a;
    final contentStr = utf8.decode(content, allowMalformed: true);
    final lines = contentStr.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (doneCompleter.isCompleted) break;
      final line = lines[i];
      final isLast = i == lines.length - 1;
      if (isLast && line.isEmpty && hasTrailingNewline) break;
      final suffix = (isLast && !hasTrailingNewline) ? '' : '\n';
      try {
        _pty!.write(utf8.encode('$line$suffix'));
      } catch (e) {
        abnormalReason.add('写入 stdin 失败: $e');
        if (!doneCompleter.isCompleted) doneCompleter.complete();
        break;
      }
      if (i > 0 && i % 200 == 0) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    // 4. 发送 Ctrl+D 结束 stdin
    if (!doneCompleter.isCompleted) {
      try {
        _pty!.write(utf8.encode('\x04'));
      } catch (e) {
        abnormalReason.add('发送 EOF 失败: $e');
        if (!doneCompleter.isCompleted) doneCompleter.complete();
      }
    }

    // 5. 等待 marker / 超时 / 取消
    try {
      await Future.any([
        doneCompleter.future,
        Future.delayed(timeout, () => throw TimeoutException('文件写入超时')),
        if (cancelToken != null) cancelToken.future,
      ]);
    } on TimeoutException {
      try {
        _pty!.write(utf8.encode('\x03'));
      } catch (_) {}
      await sub.cancel();
      _pendingDoneCompleters.remove(doneCompleter);
      stopwatch.stop();
      return CommandResult(
        stdout: buffer.toString(),
        stderr: '',
        exitCode: -1,
        duration: stopwatch.elapsed,
        timedOut: true,
        failureKind: CommandFailureKind.timeout,
        failureReason: '文件写入超时 (${timeout.inSeconds}s)',
      );
    } catch (e) {
      await sub.cancel();
      _pendingDoneCompleters.remove(doneCompleter);
      stopwatch.stop();
      return CommandResult(
        stdout: buffer.toString(),
        stderr: e.toString(),
        exitCode: -1,
        duration: stopwatch.elapsed,
        failureKind: CommandFailureKind.unknown,
        failureReason: e.toString(),
      );
    }

    await sub.cancel();
    _pendingDoneCompleters.remove(doneCompleter);
    stopwatch.stop();

    var rawOutput = buffer.toString();

    if (!markerSeen) {
      try {
        _pty!.write(utf8.encode('\x03'));
      } catch (_) {}
      final reason = abnormalReason.isNotEmpty
          ? abnormalReason.join('; ')
          : (rawOutput.contains(marker) ? 'marker 出现但未触发完成' : '文件写入未完成');
      CommandFailureKind kind = CommandFailureKind.unknown;
      if (reason.contains('syntax error') || reason.contains('PS2')) {
        kind = CommandFailureKind.syntaxError;
      } else if (reason.contains('交互式') || reason.contains('password')) {
        kind = CommandFailureKind.interactivePrompt;
      } else if (reason.contains('进程已退出')) {
        kind = CommandFailureKind.disconnected;
      } else if (reason.contains('Permission denied') || reason.contains('权限')) {
        kind = CommandFailureKind.permissionDenied;
      }
      return CommandResult(
        stdout: rawOutput,
        stderr: '',
        exitCode: -1,
        duration: stopwatch.elapsed,
        failureKind: kind,
        failureReason: reason,
      );
    }

    final exitCodeRegex = RegExp('$marker(\\d+)');
    final match = exitCodeRegex.firstMatch(rawOutput);
    int exitCode = 0;
    if (match != null) {
      exitCode = int.tryParse(match.group(1) ?? '0') ?? 0;
      rawOutput = rawOutput.replaceAll('$marker$exitCode', '');
    }

    // 清理输出：移除命令回显，保留 cat/tee 的错误输出
    var cleanOutput = rawOutput;
    final cmdEchoIdx = cleanOutput.indexOf(wrappedCommand);
    if (cmdEchoIdx >= 0) {
      cleanOutput = cleanOutput.substring(cmdEchoIdx + wrappedCommand.length);
    }
    cleanOutput = cleanOutput.replaceAll(RegExp(r'[\]\$#>]\s*$'), '').trim();

    // exitCode != 0：cat/tee 写入失败（如磁盘满、SELinux 拒绝）
    if (exitCode != 0) {
      final errorLine = cleanOutput
          .split('\n')
          .where((l) =>
              l.contains('Permission denied') ||
              l.contains('No space') ||
              l.contains('Read-only') ||
              l.contains('Operation not permitted') ||
              l.contains('denied') ||
              l.contains('error'))
          .join('; ');
      CommandFailureKind kind = CommandFailureKind.unknown;
      if (errorLine.contains('Permission denied') || errorLine.contains('权限')) {
        kind = CommandFailureKind.permissionDenied;
      }
      return CommandResult(
        stdout: cleanOutput,
        stderr: errorLine.isNotEmpty ? errorLine : 'cat/tee 退出码 $exitCode',
        exitCode: exitCode,
        duration: stopwatch.elapsed,
        failureKind: kind,
        failureReason: errorLine.isNotEmpty
            ? errorLine
            : 'cat/tee 写入失败，退出码 $exitCode。输出: $cleanOutput',
      );
    }

    return CommandResult(
      stdout: '',
      stderr: '',
      exitCode: exitCode,
      duration: stopwatch.elapsed,
    );
  }

  /// POSIX 路径 dirname（不依赖 path 包，避免引入新 import）
  static String _posixDirname(String path) {
    final idx = path.lastIndexOf('/');
    if (idx < 0) return '.';
    if (idx == 0) return '/';
    return path.substring(0, idx);
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
    // complete 所有等待者
    for (final p in _pendingDoneCompleters) {
      if (!p.isCompleted) p.complete();
    }
    _pendingDoneCompleters.clear();
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
