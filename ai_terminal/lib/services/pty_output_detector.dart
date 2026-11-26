import '../utils/exit_marker_scanner.dart';

/// 命令执行失败的细分类原因///
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

  /// 前序主机失败/任务取消导致本机未派发（区别于“执行后被取消”）
  skipped,

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
    r'(?:(?<=\n)|(?<=\r)|^)\-?(?:bash|sh|zsh|ksh):\s*(.+)',
    dotAll: false,
  );
  static final _syntaxErrorKeyword =
      RegExp(r'syntax error', caseSensitive: false);

  /// PS2 多行提示符（引号/括号未闭合）
  /// 命名前缀（dquote> / quote> / cmdsubst> 等）可以独立证明这是 shell 提示符。
  /// 裸 `> ` 也可能是 diff、日志或重定向输出，只有调用方在执行前确认命令未闭合时才允许。
  static final _ps2PromptPattern = RegExp(
    r'(?:^|\n)\s*((?:dquote|quote|cmdsubst|bquote|curly|paren)> )',
  );
  static final _barePs2PromptPattern = RegExp(r'(?:^|\n)\s*> ');

  /// 交互式**密码类**提示（sudo 之外的）
  ///
  /// sudo 提示不在这里匹配 —— 见 [SudoPromptResponder]，它按语言中立的
  /// `[sudo]` 前缀识别，覆盖中文 `[sudo] cjm 的密码：` 这类本地化提示。
  /// 模式：ssh / scp / mysql 等的密码提示。
  ///
  /// 密码类提示**永远不走自由文本输入桥**（AGENTS.md R7）：无论调用方是否
  /// 声明桥接，命中即打断，走 provide_password / sudo 密码的既有流程。
  static final _passwordPromptPattern = RegExp(
    r'(?:Password:[ \t\r]*|Enter passphrase[^\r\n]*[ \t\r]*)(?![\s\S])',
  );

  /// 确认类提示的**尾部锚定**模式（桥接用，AGENTS.md R8）
  ///
  /// 只匹配缓冲尾部：提示一定卡在输出末尾等待输入，正文里出现同样文字不算。
  /// 覆盖：
  /// - ssh/scp：`Are you sure you want to continue connecting (yes/no/[fingerprint])? `
  /// - apt 等：`Do you want to continue? [Y/n] `
  /// - 通用：`Continue?` / `Overwrite? [y/N]` / `Press ENTER to continue`
  /// - PowerShell Read-Host 会在提示后追加 `: `，所以允许尾随冒号/问号/空白。
  static final _confirmationPromptAtEnd = RegExp(
    r'(?:\((?:yes/no|y/n)(?:/\[fingerprint\])?\)'
    r'|\[(?:Y/n|y/N|yes/no)\]'
    r'|Are you sure you want to continue[^\r\n]*'
    r'|Continue\?'
    r'|Press ENTER[^\r\n]*)'
    r'[ \t]*[:：?]?[ \t\r]*$',
  );

  /// sudo 密码提示（语言中立）
  ///
  /// sudo 只翻译 "password for %u" 这部分，`[sudo]` 前缀在所有 locale 下保留：
  ///   en: `[sudo] password for cjm:`  zh: `[sudo] cjm 的密码：`
  /// 要求提示卡在缓冲尾部（后面紧跟冒号），因此 `grep '[sudo]'` 这类
  /// 输出里出现 `[sudo]` 的行不会被命中（AGENTS.md R8：不用裸子串判定）。
  static final _sudoPromptAtEnd = RegExp(r'\[sudo\][^\r\n]*[:：][ \t\r]*$');

  /// less/more 分页器停在等待按键的状态行
  ///
  /// 交互式 PTY 中 `journalctl`/`git log`/`systemctl status` 默认把输出交给
  /// pager，命令不退出，末尾的退出码 marker 永远不会出现 —— 只能干等超时
  /// （AGENTS.md R6：TTY 下的分页器行为和管道不同）。
  ///
  /// 只匹配**缓冲尾部**：状态行由 pager 最后绘制，正文里出现同样文字不算。
  /// 允许状态行后跟 ANSI 序列（颜色/清行）和空白，覆盖 `(END)` 被
  /// `\x1b[7m ... \x1b[27m` 包裹的情况。`lines x-y/z` 是 less `-M` 提示；
  /// `--More--(nn%)` 是 more，百分号会被退格重绘，尾部可能有 `\x08`。
  static final _pagerStatusAtEnd = RegExp(
    r'(?:\(END\)|--\s*More\s*--(?:\(\d+%\))?|lines\s+\d+-\d+/\d+)'
    r'(?:[\s\x08]|\x1B\[[\x20-\x3F]*[\x40-\x7E]'
    r'|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)'
    r'|\x1B[(][A-Za-z]'
    r'|\x1B[)][A-Za-z]'
    r'|\x1B[A-Za-z])*$',
  );

  /// 缓冲尾部是否停在 shell 续行（PS2）提示符上——供静默兜底用。
  ///
  /// 与 [_ps2PromptPattern] 的区别：只看**尾部一行**，且允许自定义 PS2 前缀。
  ///
  /// 关键约束（R8）：必须**整行**就是提示符形态才命中，`>` 前只允许已知的
  /// PS2 名称前缀或行首空白。绝不能是"任意以 > 结尾的文本"——否则正常命令
  /// 输出（`echo abc >`、日志、diff 的 `> `）在静默超时后会被误判为未闭合，
  /// 主动 Ctrl+C 打断一条正在执行的长命令。误判代价远高于漏判（漏判还有
  /// 原 [_ps2PromptPattern] 与超时兜底）。
  static final RegExp _continuationTail = RegExp(
    r'^(?:dquote|quote|cmdsubst|bquote|curly|paren)>[\s\x08]*$',
  );
  static final RegExp _bareContinuationTail = RegExp(r'^>[\s\x08]*$');

  static bool waitsForContinuation(
    String buffer, {
    bool unclosedSyntaxConfirmed = false,
  }) {
    const tailLength = 512;
    final tail = buffer.length > tailLength
        ? buffer.substring(buffer.length - tailLength)
        : buffer;
    // 取最后一行（去掉 ANSI），尾部匹配续行提示符
    final plain = tail.replaceAll(
      RegExp(
          r'\x1B\[[\x20-\x3F]*[\x40-\x7E]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)'),
      '',
    );
    final lines = plain.split(RegExp(r'[\r\n]+'));
    if (lines.isEmpty) return false;
    final last = lines.last.trimRight();
    if (last.isEmpty) return false;
    return _continuationTail.hasMatch(last) ||
        (unclosedSyntaxConfirmed && _bareContinuationTail.hasMatch(last));
  }

  /// 缓冲尾部是否停在 less/more 的分页状态行上
  ///
  /// 命中后调用方应向 stdin 发送 `q`，让 pager 退出、命令继续执行到 marker。
  /// 只看尾部 2KB：状态行一定在最后，遍历 256KB 缓冲没有意义。
  static bool waitsForPager(String buffer) {
    const tailLength = 2048;
    final tail = buffer.length > tailLength
        ? buffer.substring(buffer.length - tailLength)
        : buffer;
    return _pagerStatusAtEnd.hasMatch(tail);
  }

  /// 当前缓冲尾部是否正卡在 sudo 密码提示上
  static bool waitsForSudoPassword(String buffer) =>
      _sudoPromptAtEnd.hasMatch(buffer);

  /// 尾部 sudo 密码提示的匹配（无提示返回 null）
  ///
  /// 暴露匹配位置而不只是布尔值：`[sudo]` 之前的内容无法跨行匹配，
  /// 所以命中的永远是**最后**一段提示，其起始下标可以用来区分"同一个提示的
  /// 后续增量"和"sudo 重试/命令链里的下一个提示"。
  static RegExpMatch? sudoPromptMatch(String buffer) =>
      _sudoPromptAtEnd.firstMatch(buffer);

  /// 尾部确认类提示的匹配（无提示返回 null）
  ///
  /// 与 [sudoPromptMatch] 同理：暴露匹配位置供 [ConfirmationPromptResponder]
  /// 用起始下标区分"同一提示的增量"和"命令链里的下一个确认提示"。
  static RegExpMatch? confirmationPromptMatch(String buffer) =>
      _confirmationPromptAtEnd.firstMatch(buffer);

  /// 提取确认提示所在的尾部行，供 UI 弹窗展示（不携带整个缓冲区）
  ///
  /// 去掉 ANSI 转义序列和首尾空白，只保留最后一行非空文本。
  static String confirmationPromptText(String buffer) {
    final plain = buffer.replaceAll(
      RegExp(
          r'\x1B\[[\x20-\x3F]*[\x40-\x7E]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)'),
      '',
    );
    final lines = plain
        .split(RegExp(r'[\r\n]+'))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    return lines.isEmpty ? '' : lines.last.trim();
  }

  /// 检测输出并返回失败原因（null 表示未检测到异常）
  ///
  /// [buffer] 当前累积的输出
  /// [marker] 当前命令的 marker（"EXITCODE_N:" 形式）
  /// [elapsedMs] 自命令发出后经过的毫秒数
  /// [isWindows] 平台分支（Windows 不做 POSIX shell 检测）
  /// [sudoPromptWillBeAnswered] 调用方会在命中 sudo 提示时写入密码。
  ///   为 true 时 sudo 提示不再算异常 —— 否则检测器抢在注入之前 complete()，
  ///   调用方随即发 Ctrl+C，把刚要接受密码的 sudo 打断（中英文 locale 都会）。
  /// [unclosedSyntaxConfirmed] 仅在整个命令已由静态扫描确认未闭合时允许裸 `> `
  /// 作为 PS2；普通输出中的裸 `> ` 永不触发续行失败。
  /// [confirmationPromptWillBeBridged] 调用方会把确认类提示桥接给上层
  ///   （UI 弹窗）。为 true 时确认提示不再算异常；密码类提示
  ///   **不受此开关影响**，永远打断（R7：密码不走自由文本桥）。
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
    bool sudoPromptWillBeAnswered = false,
    bool confirmationPromptWillBeBridged = false,
    bool unclosedSyntaxConfirmed = false,
    RegExp? donePattern,
    int scanStart = 0,
  }) {
    // scanStart > 0 时 buffer 由“上一块尾部 carry + 本次新增输出”组成。
    // 只有从新增区域开始的行首模式才参与判定，历史错误不会反复触发假 positive；
    // 尾部锚定提示允许从 carry 开始，以支持提示被拆成多个 chunk。
    final added = scanStart.clamp(0, buffer.length);
    final completedPattern =
        donePattern ?? RegExp('${RegExp.escape(marker)}\\d+');
    if (completedPattern.hasMatch(buffer) ||
        ExitMarkerScanner.matchesAtEnd(buffer, marker)) {
      return null;
    }

    // 太早检测会误报（命令回显瞬间）—— 至少等 150ms 让回显稳定
    if (elapsedMs < 150) return null;

    // 1. 连接断开优先级最高（已由 onDone 路径处理，这里不重复）

    if (!isWindows) {
      // 2. Shell 语法错误检测
      // 严格匹配：bash/sh/zsh 行 + syntax error 关键字
      // 排除普通 stderr 输出（如 `bash: line 1: foo: command not found` 不含 syntax error）
      RegExpMatch? syntaxMatch;
      for (final match in _syntaxErrorPattern.allMatches(buffer)) {
        if (match.end > added) {
          syntaxMatch = match;
          break;
        }
      }
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
      var newPs2Prompt = false;
      if (elapsedMs > 500) {
        for (final match in _ps2PromptPattern.allMatches(buffer)) {
          if (match.end > added) {
            newPs2Prompt = true;
            break;
          }
        }
        if (!newPs2Prompt && unclosedSyntaxConfirmed) {
          for (final match in _barePs2PromptPattern.allMatches(buffer)) {
            if (match.end > added) {
              newPs2Prompt = true;
              break;
            }
          }
        }
      }
      if (newPs2Prompt) {
        return CommandFailureDiagnostic(
          kind: CommandFailureKind.syntaxError,
          reason: 'Shell 等待更多输入（引号或括号未闭合），进入 PS2 提示符',
        );
      }
    }

    // 4. 交互式密码/确认提示检测（跨平台）
    // 仅在命令发出超过 300ms 后检测（避免命令本身输出 Password: 等字样时误报，
    // 但 sudo 等提示通常在 300ms 内出现，所以仍能及时识别）
    if (elapsedMs > 300) {
      // sudo 提示单独判定：调用方持有密码时应答它，而不是把命令打断
      if (waitsForSudoPassword(buffer)) {
        if (!sudoPromptWillBeAnswered) {
          return CommandFailureDiagnostic(
            kind: CommandFailureKind.interactivePrompt,
            reason: '命令等待交互式 sudo 密码提示（未配置 sudo 密码）',
          );
        }
      } else if (_passwordPromptPattern.hasMatch(buffer)) {
        // R7：密码类提示不走自由文本桥，无论是否声明桥接都打断，
        // 走 provide_password / sudo 密码的既有安全流程。
        return CommandFailureDiagnostic(
          kind: CommandFailureKind.interactivePrompt,
          reason: '命令进入交互式密码提示，无法在非交互模式完成',
        );
      } else if (_confirmationPromptAtEnd.hasMatch(buffer)) {
        // 确认类提示：调用方声明桥接时不打断，等 UI 写入答案
        if (!confirmationPromptWillBeBridged) {
          return CommandFailureDiagnostic(
            kind: CommandFailureKind.interactivePrompt,
            reason: '命令进入交互式提示（密码/确认），无法在非交互模式完成',
          );
        }
      }
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

/// 只消费新增输出的检测入口。
///
/// carry 仅用于识别跨 chunk 的提示符；历史缓冲不会在每次定时 recheck 时重新扫描。
/// pending 也有上限，数据洪峰只保留最新增量，避免检测层成为第二个无界 buffer。
class PtyIncrementalOutputDetector {
  static const int carryChars = 512;
  static const int maxPendingChars = 8192;
  String _carry = '';
  String _pending = '';

  static String _safeTail(String text, int limit) {
    if (text.length <= limit) return text;
    var start = text.length - limit;
    final previous = text.codeUnitAt(start - 1);
    final first = text.codeUnitAt(start);
    if (previous >= 0xD800 &&
        previous <= 0xDBFF &&
        first >= 0xDC00 &&
        first <= 0xDFFF) {
      start++;
    }
    return text.substring(start);
  }

  void add(String data) {
    if (data.isEmpty) return;
    _pending += data;
    if (_pending.length > maxPendingChars * 2) {
      _pending = _safeTail(_pending, maxPendingChars);
    }
  }

  CommandFailureDiagnostic? consume({
    required String marker,
    required int elapsedMs,
    required bool isWindows,
    bool sudoPromptWillBeAnswered = false,
    bool confirmationPromptWillBeBridged = false,
    bool unclosedSyntaxConfirmed = false,
    RegExp? donePattern,
  }) {
    if (_pending.isEmpty) return null;
    final pending = _pending.length > maxPendingChars
        ? _safeTail(_pending, maxPendingChars)
        : _pending;
    _pending = '';
    final scanStart = _carry.length;
    final diagnostic = PtyOutputDetector.detect(
      buffer: '$_carry$pending',
      marker: marker,
      elapsedMs: elapsedMs,
      isWindows: isWindows,
      sudoPromptWillBeAnswered: sudoPromptWillBeAnswered,
      confirmationPromptWillBeBridged: confirmationPromptWillBeBridged,
      unclosedSyntaxConfirmed: unclosedSyntaxConfirmed,
      donePattern: donePattern,
      scanStart: scanStart,
    );
    final combined = '$_carry$pending';
    _carry = combined.length > carryChars
        ? _safeTail(combined, carryChars)
        : combined;
    return diagnostic;
  }

  /// 定时重扫最近的尾部输出。
  ///
  /// [consume] 只扫描新增块，但 detect 有 150/300/500ms 时间门槛：提示若在
  /// 门槛前到达，会先被 consume 判成 null 并清空 pending，之后命令不再有输出，
  /// 定时 recheck 就永远看不到它。这里对 carry 尾窗重跑一次完整检测，
  /// 让密码/PS2 提示在门槛过后仍能被识别（旧实现每 tick 扫全尾窗）。
  CommandFailureDiagnostic? recheck({
    required String marker,
    required int elapsedMs,
    required bool isWindows,
    bool sudoPromptWillBeAnswered = false,
    bool confirmationPromptWillBeBridged = false,
    bool unclosedSyntaxConfirmed = false,
    RegExp? donePattern,
  }) {
    if (_carry.isEmpty) return null;
    return PtyOutputDetector.detect(
      buffer: _carry,
      marker: marker,
      elapsedMs: elapsedMs,
      isWindows: isWindows,
      sudoPromptWillBeAnswered: sudoPromptWillBeAnswered,
      confirmationPromptWillBeBridged: confirmationPromptWillBeBridged,
      unclosedSyntaxConfirmed: unclosedSyntaxConfirmed,
      donePattern: donePattern,
    );
  }
}

/// sudo 密码应答状态机（每次 executeAndWait 一个实例）。
///
/// [PtyOutputDetector.waitsForSudoPassword] 只在提示卡在缓冲尾部时命中，但同一个
/// 提示可能分多个 chunk 到达（尾随空格、换行）。这里用提示的起始下标区分：
/// 下标没变 = 同一段提示的增量，不再应答；下标变大 = sudo 重试或命令链里的下一条
/// sudo，需要再答一次。答重了会把密码当成新一轮尝试，直接触发"对不起，请重试"。
class SudoPromptResponder {
  int _lastAnsweredStart = -1;

  /// 此刻是否应该把密码写入 stdin。
  bool shouldAnswer(String buffer) {
    final match = PtyOutputDetector.sudoPromptMatch(buffer);
    if (match == null) return false;
    // 缓冲按尾部 256KB 截断后下标会整体前移，此时旧游标已无意义
    if (_lastAnsweredStart >= buffer.length) _lastAnsweredStart = -1;
    if (match.start <= _lastAnsweredStart) return false;
    _lastAnsweredStart = match.start;
    return true;
  }
}

/// 确认类提示应答状态机（每次 executeAndWait 一个实例）。
///
/// 用稳定的提示文本指纹去重，不使用绝对下标：256KB 滑动窗口截断会让同一提示的
/// 下标整体前移。只有提示真正离开缓冲区尾部才重置，因此命令链里的下一条确认
/// （即使文本完全相同）仍会再次桥接。
class ConfirmationPromptResponder {
  String? _lastFingerprint;
  bool _promptPresent = false;

  /// 此刻是否应该把确认提示桥接给上层（UI 弹窗）。
  bool shouldAnswer(String buffer) {
    final match = PtyOutputDetector.confirmationPromptMatch(buffer);
    if (match == null) {
      _promptPresent = false;
      return false;
    }
    // 指纹只取命中的提示片段并剥掉尾随冒号/问号/空白：
    // 同一提示分 chunk 到达、或滑动窗口把前缀截掉，都会归一到同一指纹；
    // 不能取整行文本，否则截断前后前缀差异会让同一提示被重复应答。
    final fingerprint = match.group(0)!.replaceAll(RegExp(r'[ \t\r:：?]+$'), '');
    if (_promptPresent && fingerprint == _lastFingerprint) return false;
    _promptPresent = true;
    _lastFingerprint = fingerprint;
    return true;
  }
}
