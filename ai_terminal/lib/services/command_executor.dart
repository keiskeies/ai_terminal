import 'dart:async';
import 'dart:typed_data';

import 'pty_output_detector.dart';
import '../utils/shell_syntax.dart';

// CommandFailureKind / PtyOutputDetector / CommandFailureDiagnostic 集中定义在
// pty_output_detector.dart，这里统一导出，方便调用方一处导入。
export 'pty_output_detector.dart'
    show
        CommandFailureDiagnostic,
        CommandFailureKind,
        ConfirmationPromptResponder,
        PtyOutputDetector,
        SudoPromptResponder;

/// POSIX shell 的退出码标记包装。
///
/// 单行命令用 `;` 接在**同一行**。分成两行时第二行的 echo 会滞留在 tty 输入队列里，
/// 之后任何读 /dev/tty 的程序（典型是 sudo 读密码）都会把它当成一次输入吃掉 ——
/// 实测表现为 `[sudo] … 的密码：` 后紧跟"对不起，请重试"，且 marker 永不出现。
///
/// 多行命令（heredoc）必须换行：`EOF; echo …` 不再被识别为结束标记，
/// 文件写入会永远等下去。
/// 后台命令的 `$?` 只表示“已启动”，不能代表后台任务最终成功，因此明确拒绝
/// 这种不可观测包装；调用方可改为前台执行或自行管理后台任务。
String posixWrapWithExitMarker(String command, String marker) {
  final scan = ShellSyntax.scanPosixCommand(command);
  final reliabilityReason = scan.reliabilityReason;
  if (reliabilityReason != null) {
    throw StateError(reliabilityReason);
  }
  if (command.contains('\n')) {
    return '$command\necho "$marker\$?"';
  }
  final commentStart = scan.commentStart;
  if (commentStart == null) return '$command; echo "$marker\$?"';

  final prefix = command.substring(0, commentStart);
  // 纯注释命令的退出码为 0；marker 放到下一行，不能插到注释里面。
  if (prefix.trim().isEmpty) return '$command\necho "$marker\$?"';
  final separator = RegExp(r'[;|&]\s*$').hasMatch(prefix) ? ' ' : '; ';
  return '$prefix${separator}__ai_terminal_exit_code=\$?; '
      'echo "$marker\$__ai_terminal_exit_code" '
      '${command.substring(commentStart)}';
}

/// Windows shell 的退出码标记包装（R6 分支逻辑单点维护，本地 PTY 与
/// 远端 Windows SSH 共用）。
///
/// cmd 分支必须用 `call echo MARKER%^errorlevel^%`：直接
/// `& echo MARKER%errorlevel%` 在整行解析期就展开，取到**上一条**命令的陈旧值。
/// `%^errorlevel^%` 第一遍因变量名含 `^` 属未定义而原样保留，`call` 触发
/// 第二遍展开时命令已执行完，取到新鲜值（交互 cmd 与 cmd /c 双上下文实测）。
String windowsWrapWithExitMarker(
  String command,
  String marker, {
  required bool isPowerShell,
}) {
  if (!isPowerShell) return '$command & call echo $marker%^errorlevel^%';
  // 行尾注释会吞掉后面的退出码捕获与 marker。宁可明确拒绝，也不能制造一个
  // 永远等不到 marker 的命令；引号内（含单引号转义）的 # 仍是普通字符。
  if (_hasPowerShellComment(command)) {
    throw StateError('PowerShell 命令含注释，无法安全追加退出码标记，请移除注释后重试');
  }
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

enum _PowerShellContext { code, singleQuote, doubleQuote }

class _PowerShellFrame {
  _PowerShellFrame(this.context, {this.interpolation = false});

  final _PowerShellContext context;
  final bool interpolation;
  int parenDepth = 0;
}

/// 只在明确的 PowerShell 注释位置失败；单引号、双引号与插值子表达式分别扫描，
/// 避免把字符串里的 # 当成注释，也避免漏掉 `"$(... # comment)"` 中的真实注释。
bool _hasPowerShellComment(String command) {
  final stack = <_PowerShellFrame>[_PowerShellFrame(_PowerShellContext.code)];
  for (var i = 0; i < command.length; i++) {
    final frame = stack.last;
    final c = command[i];
    if (frame.context == _PowerShellContext.singleQuote) {
      if (c != "'") continue;
      if (i + 1 < command.length && command[i + 1] == "'") {
        i++; // PowerShell 单引号字符串用 '' 表示一个字面量引号。
      } else {
        stack.removeLast();
      }
      continue;
    }
    if (c == '`' && i + 1 < command.length) {
      i++; // 反引号转义在 code/double-quote 中跳过下一个字符。
      continue;
    }
    if (frame.context == _PowerShellContext.doubleQuote) {
      if (c == '"') {
        stack.removeLast();
      } else if (c == r'$' && i + 1 < command.length && command[i + 1] == '(') {
        stack.add(
            _PowerShellFrame(_PowerShellContext.code, interpolation: true));
        i++;
      }
      continue;
    }

    if (c == "'") {
      stack.add(_PowerShellFrame(_PowerShellContext.singleQuote));
    } else if (c == '"') {
      stack.add(_PowerShellFrame(_PowerShellContext.doubleQuote));
    } else if (c == r'$' && i + 1 < command.length && command[i + 1] == '(') {
      stack.add(_PowerShellFrame(_PowerShellContext.code, interpolation: true));
      i++;
    } else if (c == '<' && i + 1 < command.length && command[i + 1] == '#') {
      return true; // 块注释同样会吞掉后续包装，统一安全拒绝。
    } else if (c == '#' &&
        (i == 0 || RegExp(r'[\s;|&(){}.,]').hasMatch(command[i - 1]))) {
      return true;
    } else if (c == '(') {
      frame.parenDepth++;
    } else if (c == ')') {
      if (frame.interpolation && frame.parenDepth == 0) {
        stack.removeLast();
      } else if (frame.parenDepth > 0) {
        frame.parenDepth--;
      }
    }
  }
  return false;
}

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

  bool get success =>
      exitCode == 0 && !timedOut && failureKind == CommandFailureKind.none;
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
  /// [sudoPassword] 命令卡在 sudo 密码提示时写入 PTY stdin 的应答密码。
  ///   默认 null 保持旧行为：命中交互式提示立即中断命令。
  ///   密码只进终端 stdin，不进命令串、输出缓冲与审计日志（AGENTS.md R7）。
  /// [onInteractivePrompt] 命令卡在**确认类**交互提示（yes/no、[Y/n]、
  ///   Press ENTER 等）时的桥接回调：返回答案字符串（空串 = 直接回车）
  ///   写入 stdin 后继续等 marker；返回 null（用户取消/超时）则按
  ///   interactivePrompt 中断。默认 null 保持旧行为：命中即中断。
  ///   密码类提示（Password:/Enter passphrase）**不走此桥**（R7），
  ///   仍按旧流程中断走 provide_password。
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
    String? sudoPassword,
    Future<String?> Function(String prompt)? onInteractivePrompt,
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

  /// 静默执行命令并返回 stdout（不写入交互终端）
  ///
  /// 用于监控采集、系统信息探测等内部操作：这些命令不应出现在用户终端里。
  Future<String> runOnce(String command,
      {Duration timeout = const Duration(seconds: 5)});

  /// 直接写入终端（用于交互式输入）
  void writeToTerminal(String data);
}
