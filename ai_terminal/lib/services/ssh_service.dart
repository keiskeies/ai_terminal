import 'dart:async';
import 'dart:convert';
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
  String get osInfo => _osInfo;
  @override
  Stream<String> get output => outputController.stream;
  /// 暴露内部 SSHClient（只读），供 SFTP 等子工具复用连接
  /// 调用方不得 close 此 client，生命周期由 SSHService 管理
  SSHClient? get client => _client;
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
          outputController.add(utf8.decode(data, allowMalformed: true));
        },
        onError: (error) {
          outputController.add('\r\n[错误] $error\r\n');
          _isConnected = false;
        },
        onDone: () {
          if (!outputController.isClosed) {
            outputController.add('\r\n[连接已关闭]\r\n');
          }
          _isConnected = false;
          // 连接断开时 complete 所有等待者，避免 executeAndWait 永久挂起
          for (final p in _pendingDoneCompleters) {
            if (!p.isCompleted) p.complete();
          }
          _pendingDoneCompleters.clear();
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

  /// 执行命令并等待完成，返回结构化结果（含退出码）
  /// 通过在命令后追加 echo "EXITCODE:$?" 来捕获退出码
  ///
  /// 改进点：
  /// 1. **buffer 上限**（R8 合规）：保留尾部 256KB，避免 `cat huge_file` OOM
  /// 2. **Shell 语法错误快速失败**：检测到 `bash: syntax error` 等立即返回，不等 60s 超时
  /// 3. **PS2 提示符检测**：引号未闭合导致 bash 进入 `> ` 等待输入时立即返回
  /// 4. **交互式密码提示检测**：sudo / ssh 等待密码时立即返回
  /// 5. **SSH 断开区分**：onDone 触发但 marker 未出现 = 异常断开（非正常完成）
  /// 6. **marker 后停止写入 buffer**：避免 history 等命令回显的旧 marker 残留误判
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
        failureKind: CommandFailureKind.disconnected,
        failureReason: 'SSH 未连接',
      );
    }

    // 后台→前台假连接检测：app 从后台恢复后 SSH socket 可能已死但 _isConnected 仍为 true
    // 通过发送空命令（echo）检测连接是否真的活着
    try {
      _session!.write(Uint8List.fromList(utf8.encode('\n')));
    } catch (e) {
      _isConnected = false;
      return CommandResult(
        stdout: '',
        stderr: 'SSH 连接已断开（后台恢复检测失败），请重新连接',
        exitCode: -1,
        duration: Duration.zero,
        failureKind: CommandFailureKind.disconnected,
        failureReason: 'SSH 连接已断开: $e',
      );
    }

    final stopwatch = Stopwatch()..start();
    _markerSeq++;
    final marker = 'EXITCODE_$_markerSeq:';
    // 追加 echo 标记，命令完成后输出 "EXITCODE_N:0" 格式
    final wrappedCommand = '$command; echo "$marker\$?"';
    final donePattern = RegExp('${RegExp.escape(marker)}\\d+');

    // R8: buffer 必须有上限，保留尾部（最新输出），避免 cat huge_file OOM
    const maxBufferChars = 256 * 1024; // 256KB

    // 独立流监听：等待 marker 出现（比 prompt regex 更可靠）
    final buffer = StringBuffer();
    final doneCompleter = Completer<void>();
    // 异常完成的原因（非 null 表示异常完成，而非 marker 出现）
    // 通过 volatile 标记区分 onDone 是正常完成（marker 已出现）还是连接断开
    var markerSeen = false;
    var abnormalReason = <String?>[];
    _pendingDoneCompleters.add(doneCompleter);
    StreamSubscription<String>? sub;

    sub = outputController.stream.listen(
      (data) {
        if (doneCompleter.isCompleted) return; // marker 已出现，停止写入避免残留污染
        buffer.write(data);
        // R8: 截断到尾部 256KB
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
        // 实时检测异常状态：语法错误 / PS2 提示符 / 交互式密码
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
        // onDone 触发：marker 未出现 = SSH channel 关闭（异常断开）
        // marker 已出现 = 正常完成（不应走到这里，但兜底）
        if (!doneCompleter.isCompleted) {
          if (!markerSeen) {
            abnormalReason.add('SSH channel 已关闭（连接断开）');
            _isConnected = false;
          }
          doneCompleter.complete();
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
      // 发送 Ctrl+C 中断远程命令，防止后台进程继续输出污染下一条命令
      try {
        _session!.write(Uint8List.fromList(utf8.encode('\x03')));
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

    // 异常完成（检测器触发 / onDone 触发但无 marker）
    if (!markerSeen) {
      // 取消时 marker 可能未出现 — 发送 Ctrl+C 停止可能仍在运行的命令
      try {
        _session!.write(Uint8List.fromList(utf8.encode('\x03')));
      } catch (_) {}

      final reason = abnormalReason.isNotEmpty
          ? abnormalReason.join('; ')
          : (rawOutput.contains(marker) ? 'marker 出现但未触发完成' : '命令未完成');
      // 推断 failureKind
      CommandFailureKind kind = CommandFailureKind.unknown;
      if (reason.contains('syntax error') || reason.contains('PS2')) {
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

  @override
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
    // 写入命令后追加 echo marker：cat/tee 接收完 stdin 退出后，shell 执行下一条 echo
    final wrappedCommand = '$writeCmd; echo "$marker\$?"';
    final donePattern = RegExp('${RegExp.escape(marker)}\\d+');

    const maxBufferChars = 256 * 1024;
    final buffer = StringBuffer();
    final doneCompleter = Completer<void>();
    var markerSeen = false;
    var abnormalReason = <String?>[];
    _pendingDoneCompleters.add(doneCompleter);
    StreamSubscription<String>? sub;

    sub = outputController.stream.listen(
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
            abnormalReason.add('SSH channel 已关闭（连接断开）');
            _isConnected = false;
          }
          doneCompleter.complete();
        }
      },
    );

    // 1. 发送写入命令（cat > path / sudo tee path > /dev/null）
    try {
      _session!.write(Uint8List.fromList(utf8.encode('$wrappedCommand\n')));
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

    // 3. 逐行发送文件内容
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
      try {
        _session!.write(Uint8List.fromList(utf8.encode('$line$suffix')));
      } catch (e) {
        abnormalReason.add('写入 stdin 失败: $e');
        if (!doneCompleter.isCompleted) doneCompleter.complete();
        break;
      }
      // 每 200 行小延迟，避免 PTY 输入缓冲区溢出
      if (i > 0 && i % 200 == 0) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }

    // 4. 发送 Ctrl+D 结束 stdin
    if (!doneCompleter.isCompleted) {
      try {
        _session!.write(Uint8List.fromList(utf8.encode('\x04')));
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
        _session!.write(Uint8List.fromList(utf8.encode('\x03')));
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
        _session!.write(Uint8List.fromList(utf8.encode('\x03')));
      } catch (_) {}
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

    // 提取退出码
    final exitCodeRegex = RegExp('$marker(\\d+)');
    final match = exitCodeRegex.firstMatch(rawOutput);
    int exitCode = 0;
    if (match != null) {
      exitCode = int.tryParse(match.group(1) ?? '0') ?? 0;
      rawOutput = rawOutput.replaceAll('$marker$exitCode', '');
    }

    // 清理输出：移除命令回显，保留 cat/tee 的错误输出（如 "Permission denied"）
    var cleanOutput = rawOutput;
    final cmdEchoIdx = cleanOutput.indexOf(wrappedCommand);
    if (cmdEchoIdx >= 0) {
      cleanOutput = cleanOutput.substring(cmdEchoIdx + wrappedCommand.length);
    }
    cleanOutput = cleanOutput.replaceAll(RegExp(r'[\]\$#>]\s*$'), '').trim();

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
  Future<String> runOnce(String command, {Duration timeout = const Duration(seconds: 5)}) async {
    if (_client == null || !_isConnected) return '';
    try {
      final result = await _client!.execute(command).timeout(timeout);
      return await result.stdout.cast<List<int>>().transform(utf8.decoder).join();
    } catch (e) {
      debugPrint('[SSHService] runOnce 失败 ($command): $e');
      return '';
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
  @override
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
    outputController.add('\r\n[已断开连接]\r\n');
  }

  void dispose() {
    disconnect();
    outputController.close();
  }
}
