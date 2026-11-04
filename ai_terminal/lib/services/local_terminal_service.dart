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
          // flutter_pty 的 ConPTY 下直接启动 powershell.exe 会立即静默退出（无法获得
          // 有效控制台句柄），由 cmd.exe 托管后 PowerShell 才能正常交互
          shell = 'cmd.exe';
          args = ['/K', 'powershell.exe', '-NoLogo'];
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
        // 关闭分页器：PTY 下的 journalctl/systemctl/git/man 会停在 (END)，
        // 命令不退出，执行器只能干等超时。
        ptyEnv['PAGER'] = 'cat';
        ptyEnv['SYSTEMD_PAGER'] = 'cat';
        ptyEnv['GIT_PAGER'] = 'cat';
        ptyEnv['MANPAGER'] = 'cat';
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

      _pty!.exitCode.then((code) {
        debugPrint('[LocalTerminal] 进程退出, code=$code shell=$shell');
        _handleExit();
      });
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
  @override
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

  /// 按平台 + shell 生成"末尾带数字退出码标记"的包装命令（R6 分支、R8 可判定）。
  ///
  /// PowerShell 分支不能写成 `echo "MARKER\$LASTEXITCODE"`：**cmdlet 不设置
  /// `$LASTEXITCODE`**，标记会渲染成 `EXITCODE_1:`（冒号后什么都没有），而完成判定
  /// 必须按 `EXITCODE_1:\d+` 匹配（不带数字的那条 R8 规则是为了不吃命令回显），
  /// 于是每条 cmdlet 都匹配不上、白等满超时并记成失败 —— 真机实测过。
  ///
  /// 改法：先把 `$LASTEXITCODE` 置空，再用 `$?` 推导数字。
  /// - 原生命令：`$?` 与 `$LASTEXITCODE` 都被设置，取准确退出码；
  /// - cmdlet：只有 `$?` 可靠，成功记 0、失败记 1；
  /// - `$?` 为假但 `$LASTEXITCODE` 是 0（上一条原生命令留下的陈旧值）记 1，
  ///   所以 `cmd /c exit 0; Get-ChildItem 不存在路径` 不会冒充成功。
  @visibleForTesting
  static String wrapCommandWithExitMarker(
    String command,
    String marker, {
    required bool isWindows,
    required bool isPowerShell,
  }) {
    if (!isWindows) return posixWrapWithExitMarker(command, marker);
    if (!isPowerShell) return '$command & echo $marker%errorlevel%';
    // PowerShell 分支里全是 `$var` 字面量，用 raw 字符串拼，避免 Dart 插值吃掉它们。
    // 置空是必需的：`$LASTEXITCODE` 是会话级变量，上一条命令留下的非零值会串到
    // 这一条（例如上一条 `cmd /c exit 7`、这一条 cmdlet 失败 → 报 7 而不是 1）。
    return r'$LASTEXITCODE=$null; ' +
        command +
        r'; $__ec=if($?){0}' +
        r'elseif($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0){$LASTEXITCODE}' +
        r'else{1}; echo "' +
        marker +
        r'$__ec"';
  }

  /// 执行命令并等待完成，返回结构化结果（含退出码）
  ///
  /// 改进点同 [SshService.executeAndWait]：
  /// 1. buffer 上限（R8 合规，保留尾部 256KB）
  /// 2. Shell 语法错误快速失败（bash/sh/zsh 解析错误）
  /// 3. PS2 提示符检测（引号未闭合）
  /// 4. 交互式密码提示检测（sudo 提示在传入 sudoPassword 时直接应答 stdin）
  /// 5. PTY 进程退出区分正常/异常
  /// 6. marker 后停止写入 buffer
  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
    String? sudoPassword,
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
    // 平台+shell 分支：见 [wrapCommandWithExitMarker]
    final wrappedCommand = wrapCommandWithExitMarker(
      command,
      marker,
      isWindows: Platform.isWindows,
      isPowerShell: _isPowerShell,
    );
    final donePattern = RegExp('${RegExp.escape(marker)}\\d+');

    // R8: buffer 必须有上限，保留尾部（最新输出）
    const maxBufferChars = 256 * 1024; // 256KB

    // 独立流监听：等待 marker 出现（比 prompt regex 更可靠）
    final buffer = StringBuffer();
    final doneCompleter = Completer<void>();
    var markerSeen = false;
    var abnormalReason = <String?>[];
    var pagerQuitSent = false;
    var pagerDetections = 0;
    // sudo 提示应答器：命中提示时把密码写进 stdin，而不是让检测器中断命令
    final sudoResponder = SudoPromptResponder();
    _pendingDoneCompleters.add(doneCompleter);
    StreamSubscription<String>? sub;

    // 一次求值：marker 完成 → sudo 提示应答 → 异常状态检测。
    // 命令停在密码提示上之后就再无输出，只靠流回调等不到第二次判定，
    // 所以抽成函数给定时器复用（见下方 recheck）。
    void evaluate() {
      if (doneCompleter.isCompleted) return;
      final snapshot = buffer.toString();
      if (donePattern.hasMatch(snapshot)) {
        markerSeen = true;
        doneCompleter.complete();
        return;
      }
      // 分页器等待按键：命令不会自己退出，主动按 q 让后续的 marker 执行。
      // 400ms 门槛 + 连续两次判定，避开输出恰好以 (END) 结尾但命令仍在跑的误判。
      // Windows 本地终端不存在 POSIX 分页器，但正则不匹配也不会触发。
      final pagerWaiting = stopwatch.elapsedMilliseconds >= 400 &&
          PtyOutputDetector.waitsForPager(snapshot);
      pagerDetections = pagerWaiting ? pagerDetections + 1 : 0;
      if (!pagerQuitSent && pagerDetections >= 2) {
        pagerQuitSent = true;
        try {
          _pty?.write(utf8.encode('q\r'));
        } catch (_) {}
      }
      // sudo 正在等密码：直接应答 stdin。密码只写进终端，不进 buffer/命令/日志。
      // Windows 没有 sudo，提示正则永远不命中，这里无需平台分支。
      if (sudoPassword != null && sudoResponder.shouldAnswer(snapshot)) {
        try {
          _pty?.write(utf8.encode('$sudoPassword\n'));
        } catch (_) {}
      }
      final diag = PtyOutputDetector.detect(
        buffer: snapshot,
        marker: marker,
        elapsedMs: stopwatch.elapsedMilliseconds,
        isWindows: Platform.isWindows,
        sudoPromptWillBeAnswered: sudoPassword != null,
      );
      if (diag != null) {
        abnormalReason.add(diag.reason);
        doneCompleter.complete();
      }
    }

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
        evaluate();
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

    // 命令停在密码提示上时不再有任何输出，只靠流回调就永远等不到判定。
    // 定时补一次求值，让"卡在交互提示"在秒级被识别，而不是干满超时。
    late final Timer recheck;
    recheck = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) {
        evaluate();
        if (doneCompleter.isCompleted) recheck.cancel();
      },
    );

    try {
      await Future.any([
        doneCompleter.future,
        Future.delayed(timeout, () => throw TimeoutException('命令执行超时')),
        if (cancelToken != null) cancelToken.future,
      ]);
    } on TimeoutException {
      // 分页器不会响应 Ctrl+C，先按 q 退出，否则它会把下一条命令当成按键吃掉
      if (PtyOutputDetector.waitsForPager(buffer.toString())) {
        try {
          _pty!.write(utf8.encode('q\r'));
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      try {
        _pty!.write(utf8.encode('\x03'));
      } catch (_) {}
      // 给被打断的程序留出退出窗口：它还活着时会把 tty 输入队列里的字节
      // 当密码尝试吃掉，调用方紧接着发的下一条命令就被吞了
      await Future<void>.delayed(const Duration(milliseconds: 300));
      recheck.cancel();
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
      recheck.cancel();
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

    recheck.cancel();
    await sub.cancel();
    _pendingDoneCompleters.remove(doneCompleter);
    stopwatch.stop();

    var rawOutput = buffer.toString();

    if (!markerSeen) {
      // 取消时如果停在分页器上，Ctrl+C 退不出 less，必须先按 q
      if (PtyOutputDetector.waitsForPager(rawOutput)) {
        try {
          _pty!.write(utf8.encode('q\r'));
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      try {
        _pty!.write(utf8.encode('\x03'));
      } catch (_) {}
      // 同超时分支：等被打断的程序真正退出再返回，避免它吃掉下一条命令的输入
      await Future<void>.delayed(const Duration(milliseconds: 300));
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
    // canonical 模式下第一次 Ctrl+D 只提交当前行；内容无尾换行时必须再发一次 EOF，
    // 否则 cat 会一直等待输入直到超时。
    if (!doneCompleter.isCompleted) {
      try {
        _pty!.write(utf8.encode('\x04'));
        if (!hasTrailingNewline) {
          await Future.delayed(const Duration(milliseconds: 100));
          if (!doneCompleter.isCompleted) {
            _pty!.write(utf8.encode('\x04'));
          }
        }
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
