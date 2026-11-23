import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import '../models/host_config.dart';
import '../core/ssh_algorithms.dart';
import '../core/ui_text.dart';
import '../utils/exit_marker_scanner.dart';
import '../utils/output_processor.dart';
import '../utils/tail_text_buffer.dart';
import '../utils/terminal_charset.dart';
import 'command_executor.dart';
import 'session_log_service.dart';
import 'ssh_keepalive_socket.dart';
import '../core/l10n_holder.dart';

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
  final StreamController<String> outputController =
      StreamController<String>.broadcast();

  SSHSession? _session;
  SSHClient? _client;
  SSHSocket? _socket;
  bool _isConnected = false;
  String _osInfo = '';

  /// 非主动断开（掉线）时回调一次，供上层标记 lost / 触发自动重连。
  /// 主动 disconnect() 不触发。connect() 时重置去重标记。
  VoidCallback? onDisconnected;
  bool _intentionalDisconnect = false;
  bool _dropNotified = false;
  // 连接池的 release/forceDisconnect/dispose 都可能走到 dispose()，
  // 幂等守卫避免重复断开向已关闭的 outputController 写数据。
  bool _disposed = false;
  // M2: _handleDrop 会 complete 所有等待者且不写原因，异常完成分支据此
  // 把「服务级掉线」归类 disconnected，AI 才能收到明确的「该重连」信号
  bool _droppedWhileWaiting = false;
  // M4: 远端为 Windows OpenSSH（默认 shell cmd.exe）时，POSIX 包装的
  // `; echo "MARKER$?"` 永远不会产生 marker —— 每条命令干等到超时。
  // 连接后由 _osInfo 判定（Windows 没有 uname），执行路径按此走 cmd 包装。
  bool _remoteIsWindowsCmd = false;

  // 跳板机相关
  SSHClient? _jumpClient;
  SSHSocket? _jumpSocket;

  // 唯一标记计数器，用于检测命令完成
  int _markerSeq = 0;

  // pending 的 doneCompleter 集合，disconnect 时全部 complete 避免挂起
  // 用 Set 而非单字段，支持并发执行的 executeAndWait / writeFileViaPty 各自注册
  // 自己的等待者，互不覆盖。当前 Agent 模型为串行，但 disconnect 时仍可能有
  // 多个未完成的等待者（如 writeFileViaPty 触发了 executeAndWait 预检）。
  final Set<Completer<void>> _pendingDoneCompleters = {};

  SSHService(this.config);

  @override
  bool get isConnected => _isConnected;

  /// 测试专用：不建立真实 SSH 会话即可注入连接状态。
  /// `_session == null` 时 `_writeText` 为空操作，测试通过 [outputController]
  /// 注入输出来驱动 executeAndWait 的求值循环。
  @visibleForTesting
  set isConnectedForTesting(bool value) => _isConnected = value;

  String get osInfo => _osInfo;
  @override
  Stream<String> get output => outputController.stream;

  /// 暴露内部 SSHClient（只读），供 SFTP 等子工具复用连接
  /// 调用方不得 close 此 client，生命周期由 SSHService 管理
  SSHClient? get client => _client;

  /// 建连超时。此前 `config.timeout` 只存不用（建连恒 15 s），
  /// 用户的「连接超时」设置完全无效；范围与 UI 滑杆一致（10–120 s）。
  static Duration connectTimeoutFor(HostConfig cfg) =>
      Duration(seconds: cfg.timeout.clamp(10, 120).toInt());

  Duration get _connectTimeout => connectTimeoutFor(config);

  /// 连接建立后写进 PTY 的初始化串。
  ///
  /// 关分页器：PTY 下的 journalctl/systemctl/git/man 默认调 less，命令停在
  /// `(END)` 等按键，退出码 marker 永远不会执行。
  ///
  /// TMOUT 是等保基线里常见的空闲自动登出（常见 300 s，且常设成 readonly）。
  /// 一旦生效，Agent 等待期内 shell 自己退出，marker 永远不出现，
  /// 用户看到的是"莫名断线"。先置 0 再 unset：只有一种生效即可。
  /// 两段都要能真正抑制报错：裸赋值 `TMOUT=0 2>/dev/null` 的那个
  /// `2>/dev/null` 对 "readonly variable" 这条 shell 级报错无效（bash/dash 实测），
  /// 报错会照常打在用户终端上；`export TMOUT=0 2>/dev/null` 才咽得掉。
  /// 仅 POSIX：cmd/PowerShell 没有这套语法（R6 按 shell 分支）。
  /// 已知遗留：alias/LS_COLORS 两段仍是 POSIX 专属，cmd 远端会回显报错；
  /// 修改需要在真实 Windows SSH 目标上验证，不在本次范围内。
  @visibleForTesting
  static String initCommandsFor({required bool remoteIsWindowsCmd}) =>
      'export PAGER=cat SYSTEMD_PAGER=cat GIT_PAGER=cat MANPAGER=cat;'
      'export LS_COLORS="rs=0:di=01;34:ln=01;36:mh=00:pi=40;33:so=01;35:do=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:mi=00:su=37;41:sg=30;43:ca=30;41:tw=30;42:ow=34;42:st=37;44:ex=01;32";'
      'alias ls="ls --color=auto" 2>/dev/null;'
      'alias ll="ls -la --color=auto" 2>/dev/null;'
      'alias grep="grep --color=auto" 2>/dev/null;'
      '${remoteIsWindowsCmd ? '' : 'export TMOUT=0 2>/dev/null;unset TMOUT 2>/dev/null;'}'
      // 用 ANSI 清屏，避免最小化容器没有 clear 命令时打印
      // "clear: command not found" 并把初始化命令留在屏幕上
      'printf \'\\033[2J\\033[H\'\n';

  SSHConnectionState get state => _isConnected
      ? SSHConnectionState.connected
      : SSHConnectionState.disconnected;

  Future<void> connect({
    String? password,
    String? privateKeyContent,
    String? passphrase,
    HostConfig? jumpHostConfig,
    String? jumpPassword,
    String? jumpPrivateKeyContent,
  }) async {
    _intentionalDisconnect = false;
    _dropNotified = false;
    try {
      // 连接过程的提示直接进终端输出流，是用户能看到的文案，必须过 UiText。
      outputController.add(L10n.str.ut_ed6128ba80(config.host, config.port) +
          '\n');

      // 如果配置了跳板机
      if (jumpHostConfig != null) {
        outputController.add(L10n.str.ut_2574cd27d5(jumpHostConfig.host) +
            '\n');

        // 1. 先连接跳板机（用跳板机自己的超时配置）
        _jumpSocket = await KeepaliveSSHSocket.connect(
          jumpHostConfig.host,
          jumpHostConfig.port,
          timeout: connectTimeoutFor(jumpHostConfig),
        );
        _jumpClient = SSHClient(
          _jumpSocket!,
          username: jumpHostConfig.username,
          onPasswordRequest: () => jumpPassword ?? '',
          algorithms: kFastSshAlgorithms,
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
        // 直连（加超时 + TCP keepalive）
        _socket = await KeepaliveSSHSocket.connect(
          config.host,
          config.port,
          timeout: _connectTimeout,
        );
      }

      _client = SSHClient(
        _socket!,
        username: config.username,
        onPasswordRequest: () => password ?? '',
        algorithms: kFastSshAlgorithms,
        identities: privateKeyContent != null
            ? [
                ...SSHKeyPair.fromPem(privateKeyContent, passphrase),
              ]
            : null,
      );

      // 验证连通性
      try {
        final echoResult = await _client!.execute("echo 'OK'");
        await echoResult.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .join();
        outputController.add(UiText.t('连接验证通过\n', 'Connection verified\n'));
      } catch (e) {
        outputController
            .add(L10n.str.ut_939fbbbde2(e));
      }

      // 获取系统信息
      try {
        final sysInfo = await _client!.execute('uname -s -m');
        _osInfo = (await sysInfo.stdout
                .cast<List<int>>()
                .transform(utf8.decoder)
                .join())
            .trim();
      } catch (e) {
        debugPrint('[SSHService] 获取系统信息失败: $e');
        _osInfo = 'Unknown';
      }

      // M4: Windows OpenSSH 没有 uname（_osInfo 为空/Unknown）—— 补一次 ver
      // 探测远端默认 shell。探测失败按 POSIX 处理（维持现状，无阻塞风险）。
      if (_osInfo.isEmpty || _osInfo == 'Unknown') {
        try {
          final verSession = await _client!
              .execute('ver')
              .timeout(const Duration(seconds: 5));
          final verOut = await verSession.stdout
              .cast<List<int>>()
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 5), onTimeout: () => '');
          if (verOut.contains('Windows')) {
            _remoteIsWindowsCmd = true;
            _osInfo = 'Windows';
            debugPrint('[SSHService] 远端判定为 Windows cmd，使用 Windows 包装');
          }
        } catch (e) {
          debugPrint('[SSHService] Windows 探测失败（按 POSIX 处理）: $e');
        }
      }

      // 打开 Shell
      _session = await _client!.shell(
        pty: const SSHPtyConfig(
          type: 'xterm-256color',
          width: 80,
          height: 24,
        ),
      );

      // 流式解码：跨包的半个多字节字符会被 decoder 暂存到下一包，
      // 逐包 utf8.decode 会把中文显示成 �。
      // GBK/BIG5 主机按主机编码解码（terminal_charset），UTF-8 行为不变。
      decodeTerminalOutput(_session!.stdout.cast<List<int>>(), config.encoding)
          .listen(
        (data) {
          outputController.add(data);
        },
        onError: (error) {
          outputController.add('\r\n${UiText.t('[错误]', '[error]')} $error\r\n');
          _handleDrop();
        },
        onDone: () {
          if (!outputController.isClosed) {
            outputController
                .add('\r\n${UiText.t('[连接已关闭]', '[connection closed]')}\r\n');
          }
          _handleDrop();
        },
      );

      decodeTerminalOutput(_session!.stderr.cast<List<int>>(), config.encoding)
          .listen(
        (data) {
          outputController.add(data);
        },
      );

      _isConnected = true;

      await Future.delayed(const Duration(milliseconds: 300));
      _session!.write(Uint8List.fromList(utf8.encode(
          initCommandsFor(remoteIsWindowsCmd: _remoteIsWindowsCmd))));

      // 刚建好的连接即为"刚刚确认活着"，第一条命令不必再付一次探测 RTT。
      _lastConfirmedAliveAt = DateTime.now();

      outputController.add('\r\n✅ ${UiText.t('连接成功', 'Connected')}\r\n');
      outputController.add('OS: $_osInfo\r\n');
      outputController.add('\$ ');
    } catch (e) {
      _isConnected = false;
      outputController
          .add('\r\n❌ ${UiText.t('连接失败: ', 'Connection failed: ')}$e\r\n');
      rethrow;
    }
  }

  /// 执行命令并等待完成，返回结构化结果（含退出码）
  /// 通过在命令后追加 echo "EXITCODE:$?" 来捕获退出码
  ///
  /// 改进点：
  /// 1. **buffer 上限**（R8 合规）：保留尾部 256KB，避免 `cat huge_file` OOM
  /// 2. **Shell 语法错误快速失败**：检测到 `bash: syntax error` 等立即返回，不等 60s 超时
  /// 3. **PS2 提示符检测**：引号未闭合导致 bash 进入 `> ` 等待输入时立即返回
  /// 4. **交互式密码提示检测**：sudo 提示在传入 sudoPassword 时直接应答 stdin，
  ///    其它交互式提示（ssh Password:、yes/no）仍立即返回
  /// 5. **SSH 断开区分**：onDone 触发但 marker 未出现 = 异常断开（非正常完成）
  /// 6. **marker 后停止写入 buffer**：避免 history 等命令回显的旧 marker 残留误判
  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
    String? sudoPassword,
    Future<String?> Function(String prompt)? onInteractivePrompt,
  }) async {
    // _isConnected 是权威状态位：connect 拿到 session 后才置 true，掉线即置
    // false，与 isConnected getter 同一口径。内部写入对 _session==null 已是
    // 空操作，测试缝隙（isConnectedForTesting）只注入该标志即可驱动求值循环。
    if (!_isConnected) {
      return CommandResult(
        stdout: '',
        stderr: '未连接',
        exitCode: -1,
        duration: Duration.zero,
        failureKind: CommandFailureKind.disconnected,
        failureReason: 'SSH 未连接',
      );
    }

    // 后台→前台假连接检测 / 空闲后的活性复检。
    // 注意：`_writeTextQuietly` 的 catch 在这里是死代码——SSHSession.write 是
    // void（fire-and-forget），socket 已死时写入不会抛，这个 try 永远进不去。
    // 真正能证伪"假连接"的只有传输层 ping，见 _probeLiveness。
    // 命令连发（30 s 内刚确认过）时跳过，避免每条命令多付一个 RTT。
    final lastAlive = _lastConfirmedAliveAt;
    final staleSince =
        lastAlive == null ? null : DateTime.now().difference(lastAlive);
    final needsRevalidate = _client != null || livenessProbeForTesting != null;
    if (needsRevalidate &&
        (staleSince == null || staleSince >= _idleRevalidateGap)) {
      if (!await _probeLiveness()) {
        _isConnected = false;
        _handleDrop();
        return CommandResult(
          stdout: '',
          stderr: 'SSH 连接已断开（活性探测无响应），请重新连接',
          exitCode: -1,
          duration: Duration.zero,
          failureKind: CommandFailureKind.disconnected,
          failureReason: 'SSH 连接已断开：主动探测无响应（连接已空闲 '
              '${staleSince?.inSeconds ?? 0}s 以上）',
        );
      }
      _lastConfirmedAliveAt = DateTime.now();
    }
    // 保留原有行为：向 PTY 敲一次换行，让后台恢复后停在半途的交互提示
    // （分页器 / PS2 续行）露出提示符。它证明不了连接活着，只是刷一下屏。
    _writeTextQuietly('\n');

    final stopwatch = Stopwatch()..start();
    _markerSeq++;
    final marker = 'EXITCODE_$_markerSeq:';
    // 标记必须另起一行：`command; echo` 会破坏 heredoc 的结束行
    // （EOF; echo ... 不再被识别为结束标记），导致多行文件写入永远不结束。
    //
    // 但单行命令必须留在同一行。分成两行时，第二行的 echo 会滞留在 tty 的输入队列里，
    // sudo 随后打开 /dev/tty 读密码，把 `echo "EXITCODE_1:$?"` 当成第一次密码尝试吃掉
    // → "对不起，请重试"，而 marker 再也不会出现。用户实机 `sudo apt update`
    // 反复失败正是这条路径，与 locale 无关。
    final wrappedCommand = _remoteIsWindowsCmd
        ? windowsWrapWithExitMarker(command, marker, isPowerShell: false)
        : posixWrapWithExitMarker(command, marker);
    final markerScanner = ExitMarkerScanner(marker);
    final donePattern = markerScanner.donePattern;

    // R8: buffer 必须有上限，保留尾部（最新输出），避免 cat huge_file OOM
    const maxBufferChars = 256 * 1024; // 256KB
    // 异常检测只看尾部窗口：语法错误/PS2/密码提示/分页器状态都出现在输出末尾，
    // 没必要每个 chunk 扫完整个 256KB。
    const detectTailChars = 8192;
    const evaluateIntervalMs = 150;

    // 独立流监听：等待 marker 出现（比 prompt regex 更可靠）
    final buffer = TailTextBuffer(maxBufferChars);
    final detectBuffer = TailTextBuffer(detectTailChars);
    final doneCompleter = Completer<void>();
    // 异常完成的原因（非 null 表示异常完成，而非 marker 出现）
    // 通过 volatile 标记区分 onDone 是正常完成（marker 已出现）还是连接断开
    var markerSeen = false;
    var abnormalReason = <String?>[];
    var pagerQuitSent = false;
    var pagerDetections = 0;
    var lastEvaluateAtMs = -evaluateIntervalMs;
    // 等待期活性看门狗：最后一次收到输出的时刻 + 连续探测失败次数。
    // 半开连接上没有任何事件会告诉我们链路已死（write 是 void、对端不发 FIN），
    // 只有这里能主动提问；不提问就只能干等满命令超时（60 s–10 min）。
    var lastOutputAtMs = 0;
    var probeFailures = 0;
    var probeInFlight = false;
    // 看门狗判定断连的显式标记：kind 不靠 reason 文案反推（R8 忌裸子串匹配）
    var droppedByProbe = false;
    final silenceLimitMs =
        (silenceLimitForTesting ?? silenceLimitFor(timeout)).inMilliseconds;
    // sudo 提示应答器：命中提示时把密码写进 stdin，而不是让检测器中断命令
    final sudoResponder = SudoPromptResponder();
    // 确认类提示应答器：命中提示时桥接给上层（UI/自动应答），而不是中断命令
    final confirmationResponder = ConfirmationPromptResponder();
    // 桥接回调进行中：同一提示的增量 chunk 不再重复触发回调
    var waitingInteractiveAnswer = false;
    _droppedWhileWaiting = false;
    _pendingDoneCompleters.add(doneCompleter);
    StreamSubscription<String>? sub;

    // 一次求值：marker 完成 → sudo 提示应答 → 异常状态检测。
    // 抽出来是因为它既要在数据到达时跑，也要在"再也没有数据到达"时跑 ——
    // 命令停在密码提示上之后就再无输出，只靠流回调会永远等不到第二次判定，
    // 于是 300ms 门槛形同虚设，只能干满超时。
    void evaluate({bool force = false}) {
      if (doneCompleter.isCompleted) return;
      final elapsed = stopwatch.elapsedMilliseconds;
      // 数据洪流下每 150ms 最多做一次全窗口检测；marker 检测已在数据回调里
      // 用增量 carry 实时完成，不受这里节流影响。
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
      final pagerWaiting =
          elapsed >= 400 && PtyOutputDetector.waitsForPager(snapshot);
      pagerDetections = pagerWaiting ? pagerDetections + 1 : 0;
      if (!pagerQuitSent && pagerDetections >= 2) {
        pagerQuitSent = true;
        _writeTextQuietly('q\n');
      }
      // sudo 正在等密码：直接应答 stdin。密码只写进终端，不进 buffer/命令/日志；
      // 应答期间注册到 SecretMasker，会话日志里的任何回显都会被掩码。
      if (sudoPassword != null && sudoResponder.shouldAnswer(snapshot)) {
        SecretMasker.register(sudoPassword);
        _writeTextQuietly('$sudoPassword\n');
      }
      // 确认类提示（yes/no、[Y/n]、Press ENTER 等）：调用方提供桥接回调时，
      // 把提示尾部文本交给上层（UI 弹窗 / 自动应答），等待期间不打断命令。
      // 答案只写进 stdin，不进 buffer/命令串；密码类提示不走此桥（R7），
      // 仍由 detect() 按 interactivePrompt 中断。
      // 门槛：命令回显行已结束（出现换行）且超过 300ms —— 本地 PTY 逐字符
      // 回显时，命令串里恰好含 `[Y/n]` 等字样会在回显中途短暂卡在缓冲尾部。
      if (onInteractivePrompt != null &&
          !waitingInteractiveAnswer &&
          elapsed >= 300 &&
          snapshot.contains('\n') &&
          confirmationResponder.shouldAnswer(snapshot)) {
        waitingInteractiveAnswer = true;
        final promptText = PtyOutputDetector.confirmationPromptText(snapshot);
        // 异步桥接：不阻塞 evaluate 循环，答案到达后写 stdin 继续等 marker
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
            _writeTextQuietly('$answer\n');
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
        isWindows: _remoteIsWindowsCmd,
        sudoPromptWillBeAnswered: sudoPassword != null,
        confirmationPromptWillBeBridged: onInteractivePrompt != null,
        donePattern: donePattern,
      );
      if (diag != null) {
        abnormalReason.add(diag.reason);
        doneCompleter.complete();
      }
    }

    sub = outputController.stream.listen(
      (data) {
        if (doneCompleter.isCompleted) return; // marker 已出现，停止写入避免残留污染
        lastOutputAtMs = stopwatch.elapsedMilliseconds;
        buffer.write(data);
        detectBuffer.write(data);
        // 增量 marker 检测：只拼接上一块尾部，不做全缓冲扫描
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
        // onDone 触发：marker 未出现 = SSH channel 关闭（异常断开）
        // marker 已出现 = 正常完成（不应走到这里，但兜底）
        if (!doneCompleter.isCompleted) {
          if (!markerSeen) {
            // H1 兜底：marker 数字恰好压在缓冲尾部、后继 \r\n 还没到 channel
            // 就关了 —— scanner 等不到数字边界。补判尾部匹配，避免误判断线。
            if (ExitMarkerScanner.matchesAtEnd(detectBuffer.tail(), marker)) {
              markerSeen = true;
              doneCompleter.complete();
              return;
            }
            abnormalReason.add('SSH channel 已关闭（连接断开）');
            _isConnected = false;
          }
          doneCompleter.complete();
        }
      },
    );

    try {
      await _writeText('$wrappedCommand\n');
    } catch (e) {
      // 此处 recheck 定时器尚未创建，无需 cancel
      await sub.cancel();
      _pendingDoneCompleters.remove(doneCompleter);
      stopwatch.stop();
      return CommandResult(
        stdout: buffer.toString(),
        stderr: '命令写入失败: $e',
        exitCode: -1,
        duration: stopwatch.elapsed,
        failureKind: CommandFailureKind.disconnected,
        failureReason: '命令写入失败: $e',
      );
    }

    // 命令停在密码提示上时不再有任何输出，只靠流回调就永远等不到判定。
    // 定时补一次求值，让"卡在交互提示"在秒级被识别，而不是干满超时。
    // 同一个定时器兼任活性看门狗：静默超过阈值就主动探一次链路，
    // 连续 _probeFailuresToDrop 次无响应即按断连收尾——否则半开连接上
    // 只能干等满 timeout（最长 10 分钟）才知道连接早死了。
    // 只有真拿得到 SSHClient（或测试注入的探针）才有探测能力；
    // 没有 client 时探测无从进行，绝不能把"探测不了"当成"已断连"。
    final canProbe = _client != null || livenessProbeForTesting != null;
    late final Timer recheck;
    recheck = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) async {
        evaluate(force: true);
        if (doneCompleter.isCompleted) {
          recheck.cancel();
          return;
        }
        if (!canProbe || probeInFlight) return;
        if (stopwatch.elapsedMilliseconds - lastOutputAtMs < silenceLimitMs) {
          return;
        }
        probeInFlight = true;
        final alive = await _probeLiveness();
        probeInFlight = false;
        if (doneCompleter.isCompleted) return; // 探测期间已收尾（R1）
        if (alive) {
          probeFailures = 0;
          lastOutputAtMs = stopwatch.elapsedMilliseconds;
          _lastConfirmedAliveAt = DateTime.now();
          // 链路活着但长时间无新输出且尾部停在续行提示符（PS2 被置空/自定义，
          // 行首正则漏检的情况）：shell 在等引号/括号闭合，命令永远不会结束。
          // 主动发 Ctrl+C 退出等待并按语法错误收尾，避免干等满总超时（最长 10min）。
          if (PtyOutputDetector.waitsForContinuation(buffer.tail())) {
            debugPrint('[SSHService] 静默且尾部停在续行提示符，判定命令未闭合，主动中断');
            abnormalReason.add('PS2：shell 停在续行提示符（引号或括号未闭合），已主动中断');
            _writeTextQuietly('\x03');
            await Future<void>.delayed(const Duration(milliseconds: 200));
            if (!doneCompleter.isCompleted) doneCompleter.complete();
            recheck.cancel();
          }
          return;
        }
        probeFailures++;
        if (probeFailures < _probeFailuresToDrop) return;
        droppedByProbe = true;
        abnormalReason.add('连接静默 ${silenceLimitMs ~/ 1000}s 以上且主动探测无响应'
            '（判定为断连）');
        // _handleDrop 会 complete 全部等待者并只通知一次 onDisconnected，
        // 这里只补标记，等待侧随即返回 disconnected。
        _isConnected = false;
        _handleDrop();
        recheck.cancel();
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
        _writeTextQuietly('q\n');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // 发送 Ctrl+C 中断远程命令，防止后台进程继续输出污染下一条命令
      _writeTextQuietly('\x03');
      // 同 markerSeen==false 分支：给被打断的程序留出退出窗口，
      // 否则它会吃掉调用方下一条命令的输入
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
    // marker 正常出现 = 链路此刻确实可用，记为"最近确认活着"，
    // 后续命令在 _idleRevalidateGap 内不再重复付费探测。
    _lastConfirmedAliveAt = DateTime.now();

    var rawOutput = buffer.toString();

    // 异常完成（检测器触发 / onDone 触发但无 marker）
    if (!markerSeen) {
      // H1 兜底：_handleDrop 直接 complete 且不写原因，marker 数字若恰在缓冲
      // 尾部（scanner 等不到数字边界）也会被误归为异常 —— 先按完成补判一次
      if (ExitMarkerScanner.matchesAtEnd(buffer.tail(), marker)) {
        markerSeen = true;
      }
    }
    if (!markerSeen) {
      // 取消时如果停在分页器上，Ctrl+C 退不出 less，必须先按 q
      if (PtyOutputDetector.waitsForPager(rawOutput)) {
        _writeTextQuietly('q\n');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // 取消时 marker 可能未出现 — 发送 Ctrl+C 停止可能仍在运行的命令
      _writeTextQuietly('\x03');
      // 等一下再返回：被 Ctrl+C 打断的 sudo 还活着，并且会把 tty 输入队列里的
      // 字节当密码尝试吃掉。调用方紧接着发的下一条命令（`sudo -k id; echo ...`）
      // 整条会被吞进密码提示，于是命令根本没跑、marker 永远不出现、只能干等超时。
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final reason = abnormalReason.isNotEmpty
          ? abnormalReason.join('; ')
          : (_droppedWhileWaiting
              ? 'SSH channel 已关闭（连接断开）'
              : (rawOutput.contains(marker)
                  ? 'marker 出现但未触发完成'
                  : '命令未完成'));
      // 推断 failureKind
      CommandFailureKind kind = CommandFailureKind.unknown;
      if (droppedByProbe) {
        kind = CommandFailureKind.disconnected;
      } else if (reason.contains('syntax error') || reason.contains('PS2')) {
        kind = CommandFailureKind.syntaxError;
      } else if (reason.contains('交互式') || reason.contains('password')) {
        kind = CommandFailureKind.interactivePrompt;
      } else if (reason.contains('channel 已关闭') || reason.contains('断开')) {
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

    // 从输出中提取退出码：与 scanner 同一口径要求数字后有非数字边界
    // （H1），否则跨 chunk 的 137 在只到 "1" 时会被解析成 1
    final exitCodeRegex =
        RegExp('${RegExp.escape(marker)}(\\d+)(?:[^\\d]|\$)');
    final match = exitCodeRegex.firstMatch(rawOutput);
    int exitCode = 0;
    if (match != null) {
      exitCode = int.tryParse(match.group(1) ?? '0') ?? 0;
      rawOutput = rawOutput.replaceRange(match.start, match.end, '');
    }

    // 清理输出：回显去除（绕排容忍，R8 唯一清洗点）+ 精确提示符尾行（H2）
    var cleanOutput = stripWrappedEcho(rawOutput, wrappedCommand);
    cleanOutput = stripTrailingPromptLine(cleanOutput).trim();

    return CommandResult(
      stdout: cleanOutput,
      stderr: '',
      exitCode: exitCode,
      duration: stopwatch.elapsed,
    );
  }

  @override
  void execute(String command) {
    if (_session == null || !_isConnected) {
      outputController
          .add('${UiText.t('[错误] 未连接', '[error] Not connected')}\r\n');
      return;
    }

    if (command.contains('\n')) {
      _writeMultiLineCommand(command);
    } else {
      _writeUserInput('$command\n');
    }
  }

  /// 通过 PTY stdin 写入远程文件（绕过 shell 转义，继承当前 shell 权限）
  ///
  /// 流程：
  /// 1. 发送 `cat > /path`（或 `sudo tee /path > /dev/null`）+ 换行
  /// 2. 等 100ms 让 shell 进入 stdin 等待状态
  /// 3. 逐行发送文件内容（每行尾 \n），shell 把每行作为 cat/tee 的 stdin 接收
  /// 4. 发送 Ctrl+D 结束 stdin
  /// 5. 等待 marker，提取退出码
  ///
  /// 注意：文件内容里的控制字符（\x03/\x04/\x1a 等）会被 PTY 解释为信号，
  /// 因此本方法仅适用于纯文本文件（配置文件、脚本、JSON/YAML 等）。
  @override
  Future<CommandResult> writeFileViaPty({
    required String path,
    required Uint8List content,
    bool useSudo = false,
    Duration timeout = const Duration(seconds: 30),
    Completer<void>? cancelToken,
  }) async {
    if (_session == null || !_isConnected) {
      return CommandResult(
        stdout: '',
        stderr: '未连接',
        exitCode: -1,
        duration: Duration.zero,
        failureKind: CommandFailureKind.disconnected,
        failureReason: 'SSH 未连接',
      );
    }

    // M4: 远端 Windows cmd 没有 stty/cat-heredoc/Ctrl+D(EOF) 语义，
    // PTY 写文件流程整体不成立 —— 明确拒绝并给出替代路径，不冒然执行。
    if (_remoteIsWindowsCmd) {
      return CommandResult(
        stdout: '',
        stderr: '远端为 Windows，不支持 PTY 写文件',
        exitCode: -1,
        duration: Duration.zero,
        failureKind: CommandFailureKind.unknown,
        failureReason: '远端是 Windows OpenSSH（cmd），cat/heredoc 与 stty 语义不存在。'
            '建议：用 SFTP 上传，或 echo 重定向逐行写入，或 PowerShell Set-Content',
      );
    }

    // 0. 写前预检（关键安全防护）：
    //    若直接发 `cat > /path` 然后流式发文件内容，当 cat 因权限/路径失败时
    //    shell 会立即返回错误，**后续的文件内容会被 shell 当作命令执行**
    //    （如 `[base]` 被当数组语法、`name=foo bar` 被当变量赋值+命令）。
    //    因此必须先用 `test -w` 验证可写，无权限直接返回失败，不发任何内容。
    final escapedPath = path.replaceAll("'", "'\\''");
    final parentDir = _posixDirname(path);
    final escapedParent = parentDir.replaceAll("'", "'\\''");

    if (useSudo) {
      // sudo 模式：验证 sudo 可用且不需要密码（NOPASSWD 或已缓存）
      // 用 `sudo -n true` —— -n 表示不提示输入密码，需要密码时直接失败
      final sudoCheck = await executeAndWait(
        "sudo -n true",
        timeout: const Duration(seconds: 5),
        cancelToken: cancelToken,
      );
      if (sudoCheck.failureKind == CommandFailureKind.disconnected) {
        return CommandResult(
          stdout: '',
          stderr: 'sudo 预检时连接断开: ${sudoCheck.failureReason}',
          exitCode: -1,
          duration: Duration.zero,
          failureKind: CommandFailureKind.disconnected,
          failureReason: 'sudo 预检时连接断开: ${sudoCheck.failureReason}',
        );
      }
      if (sudoCheck.exitCode != 0) {
        return CommandResult(
          stdout: '',
          stderr: 'sudo 不可用或需要密码（NOPASSWD 未配置，且密码未缓存）',
          exitCode: -1,
          duration: Duration.zero,
          failureKind: CommandFailureKind.interactivePrompt,
          failureReason: 'sudo 不可用或需要密码。建议用户先在终端执行一次 sudo 命令缓存密码，'
              '或配置 /etc/sudoers 的 NOPASSWD。',
        );
      }
    } else {
      // 非 sudo 模式：验证文件本身可写 OR 父目录可写（可创建新文件）
      final permCheck = await executeAndWait(
        "test -w '$escapedPath' || test -w '$escapedParent'",
        timeout: const Duration(seconds: 5),
        cancelToken: cancelToken,
      );
      if (permCheck.failureKind == CommandFailureKind.disconnected) {
        return CommandResult(
          stdout: '',
          stderr: '权限预检时连接断开: ${permCheck.failureReason}',
          exitCode: -1,
          duration: Duration.zero,
          failureKind: CommandFailureKind.disconnected,
          failureReason: '权限预检时连接断开: ${permCheck.failureReason}',
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

    // 构造写入命令：单引号包裹路径，路径内的单引号转义为 '\''
    final writeCmd = useSudo
        ? "sudo tee '$escapedPath' > /dev/null"
        : "cat > '$escapedPath'";

    final stopwatch = Stopwatch()..start();
    _markerSeq++;
    final marker = 'EXITCODE_$_markerSeq:';
    // 关闭终端输入的行尾转换，否则 PTY 的 ICRNL 会把 CRLF 中的 \r 变成 \n，
    // 导致通过 PTY fallback 写入的文件与原文不一致。写入完成后恢复原 stty。
    final wrappedCommand = '__ai_terminal_stty=\$(stty -g 2>/dev/null); '
        'stty -icrnl -inlcr -igncr 2>/dev/null; '
        '$writeCmd; __ai_terminal_ec=\$?; '
        '[ -n "\$__ai_terminal_stty" ] && stty "\$__ai_terminal_stty" 2>/dev/null; '
        'echo "$marker\$__ai_terminal_ec"';
    final markerScanner = ExitMarkerScanner(marker);
    final donePattern = markerScanner.donePattern;
    // M3 阶段门控：进入逐行发送内容后，缓冲里回显的就是文件本身，
    // detect 会把内容里的 Password:/[Y/n] 行误判成交互提示而中断写入。
    // sudo 密码提示只出现在「命令已发出、内容未发送」窗口；内容期只留
    // marker 扫描与总超时（cat 挂起由 timeout 兜底）。
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
    _droppedWhileWaiting = false;
    _pendingDoneCompleters.add(doneCompleter);
    StreamSubscription<String>? sub;

    sub = outputController.stream.listen(
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
            abnormalReason.add('SSH channel 已关闭（连接断开）');
            _isConnected = false;
          }
          doneCompleter.complete();
        }
      },
    );

    // 1. 发送写入命令（cat > path / sudo tee path > /dev/null）
    try {
      await _writeText('$wrappedCommand\n');
    } catch (e) {
      _isConnected = false;
      await sub.cancel();
      _pendingDoneCompleters.remove(doneCompleter);
      stopwatch.stop();
      return CommandResult(
        stdout: '',
        stderr: 'SSH 写入失败: $e',
        exitCode: -1,
        duration: stopwatch.elapsed,
        failureKind: CommandFailureKind.disconnected,
        failureReason: 'SSH 写入失败: $e',
      );
    }

    // 2. 等待 shell 进入 stdin 等待状态
    await Future.delayed(const Duration(milliseconds: 100));

    // 3. 逐行发送文件内容（进入内容期：交互式提示检测停止，见 contentSending）
    contentSending = true;
    // content 末尾换行判断：保留原文件的换行行为
    final hasTrailingNewline = content.isNotEmpty && content.last == 0x0a;
    final contentStr = utf8.decode(content, allowMalformed: true);
    final lines = contentStr.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (doneCompleter.isCompleted) break; // 中途异常则停止
      final line = lines[i];
      final isLast = i == lines.length - 1;
      // split('\n') 后最后一项若原内容以 \n 结尾则为空串，需跳过避免多送一个空行
      if (isLast && line.isEmpty && hasTrailingNewline) break;
      // 最后一行若原内容不以 \n 结尾，则不补 \n（保留无尾换行）
      final suffix = (isLast && !hasTrailingNewline) ? '' : '\n';
      // 非 UTF-8 主机必须按主机编码写入，否则中文内容到 GBK 主机就是 UTF-8 字节 → 乱码文件
      try {
        await _writeText('$line$suffix');
      } catch (e) {
        abnormalReason
            .add(L10n.str.ut_5c09d2ebc3(e));
        if (!doneCompleter.isCompleted) doneCompleter.complete();
        break;
      }
      // 每 200 行小延迟，避免 PTY 输入缓冲区溢出
      if (i > 0 && i % 200 == 0) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    // 4. 发送 Ctrl+D 结束 stdin
    // 终端处于 canonical 模式时，Ctrl+D 只会“提交当前行”：
    // - 内容以 \n 结尾：缓冲区为空，一次 Ctrl+D 即 EOF
    // - 内容不以 \n 结尾：第一次 Ctrl+D 只把残留内容交给 cat，cat 仍在等输入，
    //   必须再发一次 Ctrl+D 才会产生 EOF（否则 cat 永久阻塞直到超时）
    if (!doneCompleter.isCompleted) {
      try {
        await _writeText('\x04');
        if (!hasTrailingNewline) {
          await Future.delayed(const Duration(milliseconds: 100));
          if (!doneCompleter.isCompleted) {
            await _writeText('\x04');
          }
        }
      } catch (e) {
        abnormalReason.add(L10n.str.ut_160a20b4b9(e));
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
      _writeTextQuietly('\x03');
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

    // H1 兜底：marker 数字恰压缓冲尾（scanner 等不到数字边界）时按完成补判。
    // marker 带本调用独占的 seq，文件内容恰好以同 seq 形态结尾的概率可忽略。
    if (!markerSeen && ExitMarkerScanner.matchesAtEnd(buffer.tail(), marker)) {
      markerSeen = true;
    }

    if (!markerSeen) {
      _writeTextQuietly('\x03');
      final reason = abnormalReason.isNotEmpty
          ? abnormalReason.join('; ')
          : (rawOutput.contains(marker) ? 'marker 出现但未触发完成' : '文件写入未完成');
      CommandFailureKind kind = CommandFailureKind.unknown;
      if (reason.contains('syntax error') || reason.contains('PS2')) {
        kind = CommandFailureKind.syntaxError;
      } else if (reason.contains('交互式') || reason.contains('password')) {
        kind = CommandFailureKind.interactivePrompt;
      } else if (reason.contains('channel 已关闭') || reason.contains('断开')) {
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

    // 提取退出码（与 scanner 同口径的数字边界，H1）
    final exitCodeRegex =
        RegExp('${RegExp.escape(marker)}(\\d+)(?:[^\\d]|\$)');
    final match = exitCodeRegex.firstMatch(rawOutput);
    int exitCode = 0;
    if (match != null) {
      exitCode = int.tryParse(match.group(1) ?? '0') ?? 0;
      rawOutput = rawOutput.replaceRange(match.start, match.end, '');
    }

    // 清理输出：回显去除（绕排容忍）+ 精确提示符尾行（H2），
    // 保留 cat/tee 的错误输出（如 "Permission denied"）
    var cleanOutput = stripWrappedEcho(rawOutput, wrappedCommand);
    cleanOutput = stripTrailingPromptLine(cleanOutput).trim();

    // exitCode != 0：cat/tee 写入失败（如磁盘满、SELinux 拒绝）
    // 必须把错误信息透传给调用方，否则 AI 看不到失败原因瞎试
    if (exitCode != 0) {
      // 从 cleanOutput 提取关键错误行
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
      } else if (errorLine.contains('No space')) {
        kind = CommandFailureKind.unknown;
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

  /// 一次性执行命令并返回 stdout（不走 PTY，使用 exec channel）
  ///
  /// 用于监控面板等需要轻量、不污染交互式 shell 的场景。
  /// 失败返回空字符串。超时默认 5 秒。
  /// M5：超时/异常必须 close session —— exec channel 不关，远端进程会继续
  /// 跑并泄漏 channel 句柄（R2：谁创建谁清理）。
  @override
  Future<String> runOnce(String command,
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (_client == null || !_isConnected) return '';
    SSHSession? session;
    try {
      session = await _client!.execute(command).timeout(timeout);
      return await session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
    } catch (e) {
      debugPrint('[SSHService] runOnce 失败 ($command): $e');
      return '';
    } finally {
      session?.close();
    }
  }

  void _writeMultiLineCommand(String command) async {
    final lines = command.split('\n');
    for (int i = 0; i < lines.length; i++) {
      _writeUserInput('${lines[i]}\n');
      if (i == 0 && lines.first.contains('<<')) {
        await Future.delayed(const Duration(milliseconds: 100));
      } else if (i < lines.length - 1) {
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }
  }

  /// 发送原始输入到终端（用于 xterm 输入）
  @override
  void writeToTerminal(String data) {
    if (_session == null || !_isConnected) {
      return;
    }
    _writeUserInput(data);
  }

  // 会话写入队列：非 UTF-8 主机的编码写入必须排队，否则「命令 → 文件内容 → Ctrl+D」
  // 的字节顺序取决于谁先编码完成，文件内容会错位。用户按键与 AI 链路共用这一条队列。
  final OrderedCharsetWriter _charsetWriter = OrderedCharsetWriter();

  /// 编码感知写入：UTF-8 同步执行（零开销零回归），GBK/BIG5 排队异步编码。
  /// ASCII（控制序列、EXITCODE marker）在 GBK/GB18030/Big5 下字节不变，走哪条分支都安全。
  /// 无法 await 的调用点（定时/流回调里的 q、Ctrl+C、Ctrl+D、sudo 应答）用 [_writeTextQuietly]。
  Future<void> _writeText(String text) {
    final session = _session;
    if (session == null) return Future.value();
    return _charsetWriter.write(
      text,
      config.encoding,
      (bytes) => session.write(bytes),
    );
  }

  void _writeTextQuietly(String text) {
    _writeText(text).catchError((Object e) {
      debugPrint('[SSHService] 会话写入失败: $e');
    });
  }

  /// 活性探测钩子，供测试替换成可控的假实现。
  /// 默认走 SSH 传输层 `ping()`（一个 RTT，不进 PTY、不打扰正在跑的命令）。
  @visibleForTesting
  Future<void> Function()? livenessProbeForTesting;

  /// 覆盖静默判定阈值，让看门狗行为能在测试里秒级验证。
  @visibleForTesting
  Duration? silenceLimitForTesting;

  /// 等待期静默多久后主动探一次活。
  ///
  /// 太短会在正常长命令上白发探测，太长等于没有：按命令超时收在 10–30 s，
  /// 保证短命令也能在被判"超时"之前先被判定"断线"。
  @visibleForTesting
  static Duration silenceLimitFor(Duration timeout) {
    final quarter = timeout ~/ 4;
    if (quarter < const Duration(seconds: 10)) return const Duration(seconds: 10);
    if (quarter > const Duration(seconds: 30)) return const Duration(seconds: 30);
    return quarter;
  }

  /// 单次探测超时。链路需要两个 RTT（请求+应答），给弱网留余量，
  /// 但必须远小于任何命令超时——探测本身不能变成新的等待源。
  static const Duration _probeTimeout = Duration(seconds: 4);

  /// 连续几次探测无响应才判定断连。单次超时可能是抖动/高 RTT，
  /// 两次才能把"慢"和"死"分开（误判的代价是打断一条正在跑的好命令）。
  static const int _probeFailuresToDrop = 2;

  /// 空闲超过这个再动命令时先验一次活。
  /// 命令连发时不付费（零额外 RTT），只在"停了一阵"后补一次，
  /// 覆盖 app 后台恢复、用户停顿、服务器空闲回收这类"两条命令之间死掉"的场景。
  static const Duration _idleRevalidateGap = Duration(seconds: 30);

  /// 最近一次确认链路可用的时刻（建连成功 / 命令收尾 / 探测成功）。
  /// null = 本次连接还没确认过，下一条命令开工前先验一次活。
  DateTime? _lastConfirmedAliveAt;

  @visibleForTesting
  void confirmAliveForTesting() => _lastConfirmedAliveAt = DateTime.now();

  @visibleForTesting
  void expireAliveConfirmationForTesting() =>
      _lastConfirmedAliveAt = DateTime.now().subtract(const Duration(hours: 1));

  /// 主动探一次活。
  ///
  /// 返回 `true` 表示"链路可用**或无从探测**"——探测失败必须是肯定证据，
  /// 不能拿"没有 client"当断连证据，否则会凭空打断好连接。
  Future<bool> _probeLiveness() async {
    final probe = livenessProbeForTesting;
    if (probe != null) {
      try {
        await probe().timeout(_probeTimeout);
        return true;
      } catch (_) {
        return false;
      }
    }
    final client = _client;
    if (client == null) return true;
    try {
      // SSH 传输层 global request：不进 PTY、不打扰正在运行的命令、无输出。
      // 必须自带超时——dartssh2 的 ping() 等应答没有超时，半开连接上会永久挂住，
      // 且它内部 _isPinging 一旦卡住就再也不发第二次 keepalive。
      await client.ping().timeout(_probeTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _writeUserInput(String data) {
    _writeTextQuietly(data);
  }

  void resize(int columns, int rows) {
    _session?.resizeTerminal(columns, rows);
  }

  /// 掉线统一处理：complete 所有等待者（避免 executeAndWait 永久挂起，R1），
  /// 非主动断开时通知上层一次（去重：onError 后通常还跟一个 onDone）。
  void _handleDrop() {
    _isConnected = false;
    _droppedWhileWaiting = true;
    for (final p in _pendingDoneCompleters) {
      if (!p.isCompleted) p.complete();
    }
    _pendingDoneCompleters.clear();
    if (!_intentionalDisconnect && !_dropNotified) {
      _dropNotified = true;
      onDisconnected?.call();
    }
  }

  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _isConnected = false;
    // complete 所有等待者，避免 executeAndWait / writeFileViaPty 永久挂起
    for (final p in _pendingDoneCompleters) {
      if (!p.isCompleted) p.complete();
    }
    _pendingDoneCompleters.clear();
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
    if (!outputController.isClosed) {
      outputController.add('\r\n${UiText.t('[已断开连接]', '[disconnected]')}\r\n');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(disconnect());
    unawaited(outputController.close());
  }
}
