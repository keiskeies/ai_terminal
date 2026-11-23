import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import '../core/ui_text.dart';
import '../utils/exit_marker_scanner.dart';
import '../utils/output_processor.dart';
import '../utils/tail_text_buffer.dart';
import 'command_executor.dart';
import 'session_log_service.dart';
import '../core/l10n_holder.dart';

/// 本地终端服务 — 使用原生 PTY（伪终端）实现真正的本地 shell
/// 支持 macOS / Linux / Windows，提供与 macOS Terminal / Windows CMD 完全一致的体验
class LocalTerminalService implements CommandExecutor {
  Pty? _pty;
  final StreamController<String> _outputController =
      StreamController<String>.broadcast();
  final StreamController<void> _exitController =
      StreamController<void>.broadcast();
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

  /// shell 进程退出这一「事件」本身。
  ///
  /// 不能靠 `output` 的 onDone 推断：`_handleExit` 只打一行提示、不关流（主标签
  /// 的订阅者退出后还要读回滚区），所以下游永远等不到 onDone。分屏的额外 pane
  /// 必须知道进程已经没了，否则界面上一屏「还活着」、敲键毫无反应。
  Stream<void> get onExit => _exitController.stream;

  /// 启动本地 PTY shell
  Future<void> start({int columns = 80, int rows = 24}) async {
    if (_isConnected) return;

    try {
      String shell;
      List<String> args;

      if (Platform.isWindows) {
        // Windows 优先 PowerShell（支持 ANSI/更丰富命令），回退 cmd.exe
        if (File(
                'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe')
            .existsSync()) {
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
        ptyEnv['LS_COLORS'] =
            'rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:ca=30;41:tw=30;42:ow=34;42:st=37;44:ex=01;32';
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

      _pty!.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            (data) {
              if (!_outputController.isClosed && !_isExited) {
                _outputController.add(data);
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
      // 这行直接打进终端输出流，用户看得见，必须过 UiText。
      _outputController.add('\r\n\x1b[31m✗ '
          '${L10n.str.ut_3b4b10f1b2(e)}'
          '\x1b[0m\r\n');
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
      _outputController.add('\r\n\x1b[90m'
          '${UiText.t('[进程已退出]', '[process exited]')}'
          '\x1b[0m\r\n');
    }
    if (!_exitController.isClosed) {
      _exitController.add(null);
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

  /// 一次性执行命令并返回 stdout（不走 PTY，独立进程）
  ///
  /// 用于监控面板等需要轻量、不污染交互式 shell 的场景。
  /// 失败返回空字符串。超时默认 5 秒。
  /// M5：用 Process.start 而非 Process.run(...).timeout() —— 后者超时只让
  /// await 抛出，子进程继续跑（R2 泄漏）。这里超时主动 kill。
  @override
  Future<String> runOnce(String command,
      {Duration timeout = const Duration(seconds: 5)}) async {
    Process? process;
    try {
      process = Platform.isWindows
          ? await Process.start('cmd', ['/c', command])
          : await Process.start('/bin/sh', ['-c', command]);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      // 排空 stderr：管道写满会让子进程阻塞在写上，永远等不到 exitCode
      final stderrFuture = process.stderr.drain<void>().catchError((_) {});
      try {
        await process.exitCode.timeout(timeout);
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        debugPrint('[LocalTerminalService] runOnce 超时已终止 ($command)');
        return '';
      }
      final out =
          await stdoutFuture.timeout(const Duration(seconds: 2), onTimeout: () => '');
      await stderrFuture;
      return out;
    } catch (e) {
      process?.kill(ProcessSignal.sigkill);
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
  ///
  /// cmd 分支不能写成 `echo MARKER%errorlevel%`：**cmd 在同一遍解析里就把
  /// `%errorlevel%` 展开**，取值早于 `&` 后面的命令执行 —— 拿到的是上一条命令的
  /// 陈旧退出码（实机：`cmd /c exit 9 & echo %errorlevel%` 输出 0）。
  /// 采用 `call echo MARKER%^errorlevel^%`：第一遍 `%` 展开时变量名含 `^`
  /// 属未定义变量，cmd 原样保留该引用；随后去掉转义符 `^` 得到 `%errorlevel%`；
  /// `call` 触发第二遍展开，此时命令已执行完，取到新鲜退出码。
  /// 实机验证两种上下文都成立（交互 cmd 与 `cmd /c`）；`%%errorlevel%%` 形态
  /// 在 `cmd /c` 下内层先被展开成 `%9%`（输出 `MARKER%0%`），故弃用。
  @visibleForTesting
  static String wrapCommandWithExitMarker(
    String command,
    String marker, {
    required bool isWindows,
    required bool isPowerShell,
  }) {
    if (!isWindows) return posixWrapWithExitMarker(command, marker);
    return windowsWrapWithExitMarker(command, marker,
        isPowerShell: isPowerShell);
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
    Future<String?> Function(String prompt)? onInteractivePrompt,
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
    final markerScanner = ExitMarkerScanner(marker);
    final donePattern = markerScanner.donePattern;
    // H1：退出码提取与 scanner 完成判定同一口径——数字后必须是边界
    // （非数字字符或流尾，后者对应 matchesAtEnd 兜底），避免 137 被截半时提取到前缀 1。
    final exitCodeRegex =
        RegExp('${RegExp.escape(marker)}(\\d+)(?:[^\\d]|\$)');

    // R8: buffer 必须有上限，保留尾部（最新输出）
    const maxBufferChars = 256 * 1024; // 256KB
    // 异常检测只看尾部窗口，避免每个 chunk 扫完整个 256KB
    const detectTailChars = 8192;
    const evaluateIntervalMs = 150;

    // 独立流监听：等待 marker 出现（比 prompt regex 更可靠）
    final buffer = TailTextBuffer(maxBufferChars);
    final detectBuffer = TailTextBuffer(detectTailChars);
    final doneCompleter = Completer<void>();
    var markerSeen = false;
    var abnormalReason = <String?>[];
    var pagerQuitSent = false;
    var pagerDetections = 0;
    var lastEvaluateAtMs = -evaluateIntervalMs;
    // sudo 提示应答器：命中提示时把密码写进 stdin，而不是让检测器中断命令
    final sudoResponder = SudoPromptResponder();
    // 确认类提示应答器：命中提示时桥接给上层（UI/自动应答），而不是中断命令
    final confirmationResponder = ConfirmationPromptResponder();
    // 桥接回调进行中：同一提示的增量 chunk 不再重复触发回调
    var waitingInteractiveAnswer = false;
    // 静默兜底：记录最后一次输出时刻，用于识别「链路活着但 shell 停在 PS2」的卡死
    var lastOutputAtMs = 0;
    _pendingDoneCompleters.add(doneCompleter);
    StreamSubscription<String>? sub;

    // 一次求值：marker 完成 → sudo 提示应答 → 异常状态检测。
    // 命令停在密码提示上之后就再无输出，只靠流回调等不到第二次判定，
    // 所以抽成函数给定时器复用（见下方 recheck）。
    void evaluate({bool force = false}) {
      if (doneCompleter.isCompleted) return;
      final elapsed = stopwatch.elapsedMilliseconds;
      if (!force && elapsed - lastEvaluateAtMs < evaluateIntervalMs) return;
      lastEvaluateAtMs = elapsed;
      final snapshot = detectBuffer.tail();
      if (donePattern.hasMatch(snapshot)) {
        markerSeen = true;
        doneCompleter.complete();
        return;
      }
      // 分页器等待按键：命令不会自己退出，主动按 q 让后续的 marker 执行。
      // 400ms 门槛 + 连续两次判定，避开输出恰好以 (END) 结尾但命令仍在跑的误判。
      // Windows 本地终端不存在 POSIX 分页器，但正则不匹配也不会触发。
      final pagerWaiting =
          elapsed >= 400 && PtyOutputDetector.waitsForPager(snapshot);
      pagerDetections = pagerWaiting ? pagerDetections + 1 : 0;
      if (!pagerQuitSent && pagerDetections >= 2) {
        pagerQuitSent = true;
        try {
          _pty?.write(utf8.encode('q\r'));
        } catch (_) {}
      }
      // sudo 正在等密码：直接应答 stdin。密码只写进终端，不进 buffer/命令/日志；
      // 应答期间注册到 SecretMasker，会话日志里的任何回显都会被掩码。
      // Windows 没有 sudo，提示正则永远不命中，这里无需平台分支。
      if (sudoPassword != null && sudoResponder.shouldAnswer(snapshot)) {
        SecretMasker.register(sudoPassword);
        try {
          _pty?.write(utf8.encode('$sudoPassword\n'));
        } catch (_) {}
      }
      // 确认类提示（yes/no、[Y/n]、Press ENTER 等）：调用方提供桥接回调时，
      // 把提示尾部文本交给上层（UI 弹窗 / 自动应答），等待期间不打断命令。
      // 答案只写进 stdin，不进 buffer/命令串；密码类提示不走此桥（R7）。
      // 门槛：命令回显行已结束（出现换行）且超过 300ms —— 本地 PTY 逐字符
      // 回显时，命令串里恰好含 `[Y/n]` 等字样会在回显中途短暂卡在缓冲尾部。
      if (onInteractivePrompt != null &&
          !waitingInteractiveAnswer &&
          elapsed >= 300 &&
          snapshot.contains('\n') &&
          confirmationResponder.shouldAnswer(snapshot)) {
        waitingInteractiveAnswer = true;
        final promptText = PtyOutputDetector.confirmationPromptText(snapshot);
        // 异步桥接：不阻塞 evaluate 循环，答案到达后写 stdin 继续等 marker。
        // 回车用 \r（与 execute() 一致）：Unix ICRNL 转 \n，Windows ConPTY 认 \r。
        () async {
          String? answer;
          try {
            answer = await onInteractivePrompt(promptText);
          } catch (_) {
            answer = null; // 回调异常按取消处理，避免命令永远挂起（R1）
          }
          waitingInteractiveAnswer = false;
          if (doneCompleter.isCompleted) return; // 已超时/取消/断开，丢弃答案
          if (answer != null) {
            try {
              _pty?.write(utf8.encode('$answer\r'));
            } catch (_) {}
          } else {
            abnormalReason.add('交互式确认提示被取消或超时，命令无法继续');
            doneCompleter.complete();
          }
        }();
      }
      final diag = PtyOutputDetector.detect(
        buffer: snapshot,
        marker: marker,
        elapsedMs: elapsed,
        isWindows: Platform.isWindows,
        sudoPromptWillBeAnswered: sudoPassword != null,
        confirmationPromptWillBeBridged: onInteractivePrompt != null,
        donePattern: donePattern,
      );
      if (diag != null) {
        abnormalReason.add(diag.reason);
        doneCompleter.complete();
      }
    }

    sub = _outputController.stream.listen(
      (data) {
        if (doneCompleter.isCompleted) return;
        lastOutputAtMs = stopwatch.elapsedMilliseconds;
        buffer.write(data);
        detectBuffer.write(data);
        if (markerScanner.add(data)) {
          markerSeen = true;
          doneCompleter.complete();
          return;
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
          // H1 兜底：marker 刚输出完流就关闭时，donePattern 等不到数字后的
          // 边界字符。缓冲尾部正好停在 marker+数字上 → 按完成处理，
          // 不把正常结束的命令误判成进程退出。
          if (!markerSeen &&
              ExitMarkerScanner.matchesAtEnd(buffer.tail(), marker)) {
            markerSeen = true;
          } else if (!markerSeen) {
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
        evaluate(force: true);
        if (doneCompleter.isCompleted) {
          recheck.cancel();
          return;
        }
        // 静默兜底（POSIX）：链路活着但 shell 停在 PS2 等待输入时没有任何新输出，
        // 行首 PS2 正则可能漏检（自定义/置空 PS2）。静默 ≥30s 且尾部像续行 →
        // 主动 Ctrl+C 退出并按语法错误收尾，避免干等满总超时。
        if (!Platform.isWindows &&
            stopwatch.elapsedMilliseconds - lastOutputAtMs >= 30000 &&
            PtyOutputDetector.waitsForContinuation(buffer.tail())) {
          abnormalReason.add('PS2：shell 停在续行提示符（引号或括号未闭合），已主动中断');
          try {
            _pty!.write(utf8.encode('\x03'));
          } catch (_) {}
          recheck.cancel();
          doneCompleter.complete();
        }
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
      SecretMasker.unregister(sudoPassword);
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
      SecretMasker.unregister(sudoPassword);
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
    SecretMasker.unregister(sudoPassword);
    stopwatch.stop();

    var rawOutput = buffer.toString();

    // H1 兜底：完成由取消/异常检测触发，但缓冲尾部实际停在 marker+数字上
    // （边界字符始终没来）→ 按完成处理，正常提取退出码。
    if (!markerSeen && ExitMarkerScanner.matchesAtEnd(rawOutput, marker)) {
      markerSeen = true;
    }

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

    // 从输出中提取退出码（exitCodeRegex 与 scanner 同一边界口径，见上方声明处）
    final match = exitCodeRegex.firstMatch(rawOutput);
    int exitCode = 0;
    if (match != null) {
      exitCode = int.tryParse(match.group(1) ?? '0') ?? 0;
      rawOutput = rawOutput.replaceAll('$marker$exitCode', '');
    }

    // 清理输出：剔 marker（上）→ 去回显（绕排容忍，F3）→ 清尾行提示符（H2）。
    // 旧的尾部单字符清洗 [\]\$#>] 会吃掉 JSON 末 ]、口令 $ 等合法尾字符，
    // 换 stripTrailingPromptLine 整行精确匹配。
    var cleanOutput = stripWrappedEcho(rawOutput, wrappedCommand);
    cleanOutput = stripTrailingPromptLine(cleanOutput).trim();

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
    final markerScanner = ExitMarkerScanner(marker);
    final donePattern = markerScanner.donePattern;
    // M3 阶段门控（与 SSH 同口径）：内容期回显的就是文件本身，
    // detect 会把内容里的 Password:/[Y/n] 误判成交互提示而中断写入。
    var contentSending = false;

    const maxBufferChars = 256 * 1024;
    const detectTailChars = 8192;
    const evaluateIntervalMs = 150;
    final buffer = TailTextBuffer(maxBufferChars);
    final detectBuffer = TailTextBuffer(detectTailChars);
    final doneCompleter = Completer<void>();
    var markerSeen = false;
    var abnormalReason = <String?>[];
    var lastEvaluateAtMs = -evaluateIntervalMs;
    _pendingDoneCompleters.add(doneCompleter);
    StreamSubscription<String>? sub;

    sub = _outputController.stream.listen(
      (data) {
        if (doneCompleter.isCompleted) return;
        buffer.write(data);
        detectBuffer.write(data);
        if (markerScanner.add(data)) {
          markerSeen = true;
          doneCompleter.complete();
          return;
        }
        final elapsed = stopwatch.elapsedMilliseconds;
        if (elapsed - lastEvaluateAtMs < evaluateIntervalMs) return;
        lastEvaluateAtMs = elapsed;
        if (contentSending) return;
        final snapshot = detectBuffer.tail();
        final diag = PtyOutputDetector.detect(
          buffer: snapshot,
          marker: marker,
          elapsedMs: elapsed,
          isWindows: false,
          donePattern: donePattern,
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

    // 3. 逐行发送文件内容（进入内容期：交互式提示检测停止）
    contentSending = true;
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

    // H1 兜底：marker 数字恰压缓冲尾（scanner 等不到数字边界）时按完成补判
    if (!markerSeen && ExitMarkerScanner.matchesAtEnd(buffer.tail(), marker)) {
      markerSeen = true;
    }

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
      } else if (reason.contains('Permission denied') ||
          reason.contains('权限')) {
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

    final exitCodeRegex =
        RegExp('${RegExp.escape(marker)}(\\d+)(?:[^\\d]|\$)');
    final match = exitCodeRegex.firstMatch(rawOutput);
    int exitCode = 0;
    if (match != null) {
      exitCode = int.tryParse(match.group(1) ?? '0') ?? 0;
      rawOutput = rawOutput.replaceRange(match.start, match.end, '');
    }

    // 清理输出：回显去除（绕排容忍）+ 精确提示符尾行（H2），
    // 保留 cat/tee 的错误输出
    var cleanOutput = stripWrappedEcho(rawOutput, wrappedCommand);
    cleanOutput = stripTrailingPromptLine(cleanOutput).trim();

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
    // kill 要在 `_isExited` 短路之前：进程自己退出时也走这里（pane 收到退出
    // 事件后 close），短路会让 _pty 的主端句柄一直挂着等 GC 才回收。
    // 对已退出的进程 kill 只是 ESRCH，无副作用。
    try {
      _pty?.kill();
    } catch (_) {}
    _pty = null;
    if (_isExited) return;
    _isExited = true;
    _isConnected = false;
    // complete 所有等待者
    for (final p in _pendingDoneCompleters) {
      if (!p.isCompleted) p.complete();
    }
    _pendingDoneCompleters.clear();
  }

  /// 释放资源
  void dispose() {
    disconnect();
    _outputController.close();
    _exitController.close();
  }

  /// 是否支持本地终端
  static bool get isSupported =>
      Platform.isMacOS || Platform.isLinux || Platform.isWindows;
}
