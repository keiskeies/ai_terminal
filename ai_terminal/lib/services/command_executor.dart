import 'dart:async';
import 'dart:typed_data';

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

  /// 通过 PTY stdin 写入文件（绕过 shell 转义，继承当前 shell 权限）
  ///
  /// **设计动机**：SFTP 在以下场景会失败 ——
  /// 1. 当前 SSH 用户对目标路径无写权限（如普通用户写 /etc/yum.repos.d/）
  /// 2. SFTP 子系统被禁用（硬化的服务器或 rbash）
  /// 此时通过 PTY stdin 写文件可绕开这两个限制：
  /// - 发送 `cat > /path`（或 `sudo tee /path > /dev/null`）让 shell 进入 stdin 等待状态
  /// - 逐行发送文件内容，作为 cat/tee 的 stdin
  /// - 末尾 Ctrl+D 结束
  ///
  /// 文件内容**不经过 shell 解析**，`$`/反引号/`[`/`"` 等都是字面字符。
  /// 继承当前 shell 的权限（用户已 `sudo -i` 进 root 时直接有权限写 /etc/）。
  ///
  /// [useSudo] 为 true 时用 `sudo tee /path > /dev/null`，适用于非 root shell
  /// （需 sudo NOPASSWD 或已缓存密码，否则会卡在密码提示）。
  Future<CommandResult> writeFileViaPty({
    required String path,
    required Uint8List content,
    bool useSudo = false,
    Duration timeout = const Duration(seconds: 30),
    Completer<void>? cancelToken,
  });

  /// 直接写入终端（用于交互式输入）
  void writeToTerminal(String data);
}
