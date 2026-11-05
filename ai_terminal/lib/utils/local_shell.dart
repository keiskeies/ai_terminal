import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 本机命令使用的 shell。
enum LocalShellKind {
  powershell,
  cmd,
  bash,
  sh,
}

extension LocalShellKindX on LocalShellKind {
  bool get isWindowsShell =>
      this == LocalShellKind.powershell || this == LocalShellKind.cmd;

  String get id => name;
}

String localShellLabel(LocalShellKind kind) {
  switch (kind) {
    case LocalShellKind.powershell:
      return 'Windows PowerShell';
    case LocalShellKind.cmd:
      return '命令提示符 (cmd)';
    case LocalShellKind.bash:
      return 'bash';
    case LocalShellKind.sh:
      return 'sh';
  }
}

/// 解析 AI 传来的 shell 参数；空字符串/auto 返回 null（表示按平台默认）。
LocalShellKind? parseLocalShell(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  if (value.isEmpty || value == 'auto') return null;
  switch (value) {
    case 'powershell':
    case 'ps':
    case 'pwsh':
      return LocalShellKind.powershell;
    case 'cmd':
    case 'cmd.exe':
      return LocalShellKind.cmd;
    case 'bash':
      return LocalShellKind.bash;
    case 'sh':
      return LocalShellKind.sh;
    default:
      return null;
  }
}

/// 当前平台是否支持本机命令执行（桌面端）。
bool isLocalExecPlatformSupported() =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 当前平台的默认 shell；移动端返回 null。
LocalShellKind? resolveDefaultLocalShell() {
  if (Platform.isWindows) return LocalShellKind.powershell;
  if (Platform.isMacOS || Platform.isLinux) {
    return File('/bin/bash').existsSync()
        ? LocalShellKind.bash
        : LocalShellKind.sh;
  }
  return null;
}

/// 指定 shell 是否能在当前平台运行。
bool isShellCompatibleWithPlatform(LocalShellKind kind) {
  if (Platform.isWindows) return kind.isWindowsShell;
  if (Platform.isMacOS || Platform.isLinux) return !kind.isWindowsShell;
  return false;
}

/// 一次本机进程调用的可执行文件与参数。
class LocalShellInvocation {
  final String executable;
  final List<String> args;
  final String label;

  const LocalShellInvocation(this.executable, this.args, this.label);
}

/// 构造本机命令的进程参数。
///
/// PowerShell 的退出码逻辑复用 [LocalTerminalService.wrapCommandWithExitMarker] 的
/// 结论（R6/R8）：`$LASTEXITCODE` 是会话级变量且 cmdlet 不设置它，所以先置空，
/// 再用 `$?` + `$LASTEXITCODE` 计算真实退出码，最后 `exit $__ec`，让 Process.exitCode
/// 拿到准确值。这里不 echo marker，进程退出码本身就是完成信号。
LocalShellInvocation buildLocalShellInvocation(
  LocalShellKind kind,
  String command,
) {
  switch (kind) {
    case LocalShellKind.powershell:
      final script = StringBuffer()
        ..write('[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; ')
        ..write(r'$LASTEXITCODE=$null; ')
        ..write(command)
        ..writeln()
        ..write(r'$__ec=if($?){0}')
        ..write(
            r'elseif($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0){$LASTEXITCODE}')
        ..write(r'else{1}; exit $__ec');
      return LocalShellInvocation(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', script.toString()],
        localShellLabel(kind),
      );
    case LocalShellKind.cmd:
      return LocalShellInvocation(
        'cmd.exe',
        ['/d', '/s', '/c', command],
        localShellLabel(kind),
      );
    case LocalShellKind.bash:
      return LocalShellInvocation(
        'bash',
        ['-lc', command],
        localShellLabel(kind),
      );
    case LocalShellKind.sh:
      return LocalShellInvocation(
        'sh',
        ['-lc', command],
        localShellLabel(kind),
      );
  }
}

class LocalCommandResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;
  final bool timedOut;
  final bool cancelled;

  /// 截断前 stdout/stderr 的字符数（用于“输出过长”提示）
  final int stdoutTotalChars;
  final int stderrTotalChars;
  final bool stdoutTruncated;
  final bool stderrTruncated;

  const LocalCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
    required this.timedOut,
    required this.cancelled,
    required this.stdoutTotalChars,
    required this.stderrTotalChars,
    required this.stdoutTruncated,
    required this.stderrTruncated,
  });

  bool get success => !timedOut && !cancelled && exitCode == 0;
}

typedef LocalCommandRunner = Future<LocalCommandResult> Function({
  required String command,
  required String cwd,
  required LocalShellKind shell,
  required Duration timeout,
  Completer<void>? cancelToken,
});

/// 运行本机命令。调用方负责路径白名单与用户授权，这里只做进程与 IO。
Future<LocalCommandResult> runLocalCommand({
  required String command,
  required String cwd,
  required LocalShellKind shell,
  required Duration timeout,
  Completer<void>? cancelToken,
}) async {
  final invocation = buildLocalShellInvocation(shell, command);
  final stopwatch = Stopwatch()..start();
  final process = await Process.start(
    invocation.executable,
    invocation.args,
    workingDirectory: cwd,
    runInShell: false,
  );
  // 非交互：立即关闭 stdin，避免 grep/docker 等命令等待输入把任务挂死
  unawaited(process.stdin.close().catchError((Object _) {}));

  final encoding = shell == LocalShellKind.cmd
      ? systemEncoding
      : const Utf8Codec(allowMalformed: true);
  const captureCap = 200000;
  final outFuture = _capture(process.stdout, encoding, captureCap);
  final errFuture = _capture(process.stderr, encoding, captureCap);

  var cancelled = false;
  var processDone = false;
  if (cancelToken != null) {
    unawaited(cancelToken.future.then((_) {
      if (processDone) return;
      cancelled = true;
      process.kill();
    }));
  }

  var timedOut = false;
  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    process.kill();
    exitCode = await process.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () => -1,
    );
  }
  processDone = true;

  // 进程退出后流通常立即关闭；加超时兜底，避免异常子进程把工具挂死
  final out = await outFuture.timeout(
    const Duration(seconds: 5),
    onTimeout: () => const _Captured('', 0, false),
  );
  final err = await errFuture.timeout(
    const Duration(seconds: 5),
    onTimeout: () => const _Captured('', 0, false),
  );
  stopwatch.stop();

  return LocalCommandResult(
    exitCode: exitCode,
    stdout: out.text,
    stderr: err.text,
    duration: stopwatch.elapsed,
    timedOut: timedOut,
    cancelled: cancelled,
    stdoutTotalChars: out.totalChars,
    stderrTotalChars: err.totalChars,
    stdoutTruncated: out.truncated,
    stderrTruncated: err.truncated,
  );
}

class _Captured {
  final String text;
  final int totalChars;
  final bool truncated;

  const _Captured(this.text, this.totalChars, this.truncated);
}

/// 保留尾部 [cap] 字符；同时继续 drain 流，避免子进程因管道写满而阻塞。
Future<_Captured> _capture(
  Stream<List<int>> stream,
  Encoding encoding,
  int cap,
) async {
  final buffer = StringBuffer();
  var total = 0;
  await for (final chunk in stream.transform(encoding.decoder)) {
    total += chunk.length;
    if (chunk.isEmpty) continue;
    if (buffer.length + chunk.length <= cap) {
      buffer.write(chunk);
    } else {
      final combined = buffer.toString() + chunk;
      buffer
        ..clear()
        ..write(combined.length <= cap
            ? combined
            : combined.substring(combined.length - cap));
    }
  }
  return _Captured(buffer.toString(), total, total > cap);
}
