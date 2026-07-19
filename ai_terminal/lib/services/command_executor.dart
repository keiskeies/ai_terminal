import 'dart:async';

import 'pty_output_detector.dart';

// CommandFailureKind / PtyOutputDetector / CommandFailureDiagnostic 集中定义在
// pty_output_detector.dart，这里统一导出，方便调用方一处导入。
export 'pty_output_detector.dart'
    show CommandFailureDiagnostic, CommandFailureKind, PtyOutputDetector;

/// 命令执行结果（包含退出码）
class CommandResult {
  final String stdout;
  final String stderr;
  final int exitCode;
  final Duration duration;
  final bool timedOut;

  /// 失败原因细分（用于 AI 决策：重试 / 修正命令 / 重连）
  final CommandFailureKind failureKind;

  /// 人类可读的失败诊断（非空时配合 failureKind 使用）
  /// 例如 "Shell syntax error: unexpected token ';'"
  final String? failureReason;

  CommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.duration,
    this.timedOut = false,
    this.failureKind = CommandFailureKind.none,
    this.failureReason,
  });

  bool get success => exitCode == 0 && !timedOut && failureKind == CommandFailureKind.none;
}

/// 终端命令执行器接口
/// 统一 SSHService 和 LocalTerminalService 的命令执行能力
/// 使 AgentEngine 可同时支持远程 SSH 和本地 PTY
abstract class CommandExecutor {
  /// 是否已连接
  bool get isConnected;

  /// 命令输出流（用于 UI 实时显示终端输出）
  Stream<String> get output;

  /// 执行命令（自动追加回车），仅写入终端不等待完成
  void execute(String command);

  /// 执行命令并等待完成，返回结构化结果（含退出码）
  /// [timeout] 超时时间，默认 60 秒
  /// [cancelToken] 可选的取消令牌，complete 时立即终止等待
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
  });

  /// 直接写入终端（用于交互式输入）
  void writeToTerminal(String data);
}
