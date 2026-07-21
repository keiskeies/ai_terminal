/// 命令执行失败的细分类原因
///
/// 让 AI 能区分"命令真的失败"vs"环境问题"，避免盲目重试。
/// 例如 syntaxError 应该修正命令而非重试；disconnected 应该重连而非重试。
enum CommandFailureKind {
  /// 正常完成（含命令返回非 0 退出码）
  none,

  /// 命令执行超时
  timeout,

  /// Shell 语法错误（命令根本没执行，如 `&;` 引号未闭合等）
  syntaxError,

  /// 交互式提示阻塞（sudo 密码、ssh yes/no 等）
  interactivePrompt,

  /// 连接断开（SSH 网络断开 / 本地 PTY 进程退出）
  disconnected,

  /// 权限不足（写入/读取被拒绝，需要 sudo 或切换用户）
  permissionDenied,

  /// 取消执行
  cancelled,

  /// 其他未分类错误
  unknown,
}

/// PTY 输出实时检测器
///
/// 在 [executeAndWait] 的输出流上做实时模式识别，提前发现"命令根本没在跑"的
/// 各类异常状态，避免等到 60s 超时才返回。
///
/// 设计目标：
/// 1. 只在 marker 尚未出现时检测（marker 出现即命令完成，无需检测）
/// 2. 严格匹配模式，避免误报（要求完整模式而非裸子串）
/// 3. 误报规避：所有检测都要求 (a) marker 未出现 (b) 模式出现在新行行首或紧跟命令回显
///
/// 真实生产场景识别：
/// - **Shell 语法错误**：bash 在解析阶段报错，整行命令一行都没执行。
///   如 `nohup ... &;`、`echo "abc`、未闭合括号等。
///   模式：`-bash: syntax error near unexpected token` / `bash: syntax error`
/// - **PS2 多行提示符**：引号/括号未闭合时 bash 进入 PS2 等待更多输入。
///   模式：行首 `> ` / `dquote> ` / `quote> ` / `cmdsubst> `
/// - **交互式密码提示**：sudo / ssh / mysql 等等待密码输入。
///   模式：`[sudo] password` / `Password:` / `Enter passphrase`
/// - **连接断开**：PTY 进程退出 / SSH channel 关闭
///   检测方式：onDone 回调被触发
class PtyOutputDetector {
  /// Shell 语法错误（POSIX shell）
  /// 严格模式：必须以 `bash:` 或 `-bash:` 开头，且包含 `syntax error`
  /// 误报规避：用户 `cat` 日志时，日志中包含 `bash:` 字样不会同时满足两个条件
  static final _syntaxErrorPattern = RegExp(
    r'(?:^|\n|[\r\n])\-?(?:bash|sh|zsh|ksh):\s*(.+)',
    dotAll: false,
  );
  static final _syntaxErrorKeyword = RegExp(r'syntax error', caseSensitive: false);

  /// PS2 多行提示符（引号/括号未闭合）
  /// 模式：行首 `> ` 或 `dquote> ` / `quote> ` / `cmdsubst> ` / `bquote> `
  /// 误报规避：要求出现在新行行首，且命令已发出超过 200ms（避免命令回显瞬间误判）
  static final _ps2PromptPattern = RegExp(
    r'(?:^|\n)\s*(?:dquote|quote|cmdsubst|bquote|curly|paren|)> ',
  );

  /// 交互式密码/确认提示
  /// 模式：sudo / ssh / scp / mysql 等的密码提示，或 yes/no 确认
  static final _interactivePromptPattern = RegExp(
    r'(?:\[sudo\]\s*password|Password:\s*$|Enter passphrase|Are you sure you want to continue|^\s*\(yes/no\)|^\s*\(yes/no/\[fingerprint\]\))',
    multiLine: true,
  );

  /// 检测输出并返回失败原因（null 表示未检测到异常）
  ///
  /// [buffer] 当前累积的输出
  /// [marker] 当前命令的 marker（"EXITCODE_N:" 形式）
  /// [elapsedMs] 自命令发出后经过的毫秒数
  /// [isWindows] 平台分支（Windows 不做 POSIX shell 检测）
  ///
  /// 注意：marker 字符串本身会出现在命令回显里（如 `echo "EXITCODE_1:$?"`），
  /// 这是正常的。真正的"命令完成"是 marker + 退出码数字。
  /// 这里只检查 marker 是否出现，命令回显里的 marker 会被误判为完成 ——
  /// 这个误判由调用方 [executeAndWait] 的 donePattern（marker+\\d+）规避，
  /// 检测器只负责"在 marker+数字未出现时"识别异常状态。
  static CommandFailureDiagnostic? detect({
    required String buffer,
    required String marker,
    required int elapsedMs,
    required bool isWindows,
  }) {
    // 命令真正完成 = marker+数字出现（由调用方 donePattern 判定）
    // 检测器只在尚未完成时识别异常，故检查 buffer 是否含 marker+数字
    final donePattern = RegExp('${RegExp.escape(marker)}\\d+');
    if (donePattern.hasMatch(buffer)) return null;

    // 太早检测会误报（命令回显瞬间）—— 至少等 150ms 让回显稳定
    if (elapsedMs < 150) return null;

    // 1. 连接断开优先级最高（已由 onDone 路径处理，这里不重复）

    if (!isWindows) {
      // 2. Shell 语法错误检测
      // 严格匹配：bash/sh/zsh 行 + syntax error 关键字
      // 排除普通 stderr 输出（如 `bash: line 1: foo: command not found` 不含 syntax error）
      final syntaxMatch = _syntaxErrorPattern.firstMatch(buffer);
      if (syntaxMatch != null) {
        final rest = syntaxMatch.group(1) ?? '';
        if (_syntaxErrorKeyword.hasMatch(rest)) {
          // 提取第一行作为原因
          final firstLine = rest.split(RegExp(r'[\r\n]')).first.trim();
          return CommandFailureDiagnostic(
            kind: CommandFailureKind.syntaxError,
            reason: 'Shell syntax error: $firstLine',
          );
        }
      }

      // 3. PS2 多行提示符检测（引号未闭合）
      // 仅在命令发出超过 500ms 后检测（短命令正常早已完成，避免误报）
      if (elapsedMs > 500 && _ps2PromptPattern.hasMatch(buffer)) {
        return CommandFailureDiagnostic(
          kind: CommandFailureKind.syntaxError,
          reason: 'Shell 等待更多输入（引号或括号未闭合），进入 PS2 提示符',
        );
      }
    }

    // 4. 交互式密码/确认提示检测（跨平台）
    // 仅在命令发出超过 300ms 后检测（避免命令本身输出 Password: 等字样时误报，
    // 但 sudo 等提示通常在 300ms 内出现，所以仍能及时识别）
    if (elapsedMs > 300 && _interactivePromptPattern.hasMatch(buffer)) {
      return CommandFailureDiagnostic(
        kind: CommandFailureKind.interactivePrompt,
        reason: '命令进入交互式提示（密码/确认），无法在非交互模式完成',
      );
    }

    return null;
  }
}

/// 检测结果
class CommandFailureDiagnostic {
  final CommandFailureKind kind;
  final String reason;

  CommandFailureDiagnostic({required this.kind, required this.reason});
}
