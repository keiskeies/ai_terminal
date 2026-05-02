import 'dart:async';

/// 终端命令执行器接口
/// 统一 SSHService 和 LocalTerminalService 的命令执行能力
/// 使 AgentEngine 可同时支持远程 SSH 和本地 PTY
abstract class CommandExecutor {
  /// 是否已连接
  bool get isConnected;

  /// 命令输出流
  Stream<String> get output;

  /// 执行命令（自动追加回车）
  void execute(String command);

  /// 直接写入终端（用于交互式输入）
  void writeToTerminal(String data);
}
