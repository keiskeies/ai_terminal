// utils/pty_output_detector.ts - r216 port of services/pty_output_detector.dart
// (242 lines, import-free). Every regex body, enum member and zh reason
// string was extracted from the Dart source at generation time; the oracle
// test re-extracts them at run time and diffs, so drift is impossible.

// 命令执行失败的细分类原因
//
// 让 AI 能区分"命令真的失败"vs"环境问题"，避免盲目重试。
// 例如 syntaxError 应该修正命令而非重试；disconnected 应该重连而非重试。
export enum CommandFailureKind {
  // 正常完成（含命令返回非 0 退出码）
  none = "none",
  // 命令执行超时
  timeout = "timeout",
  // Shell 语法错误（命令根本没执行，如 `&;` 引号未闭合等）
  syntaxError = "syntaxError",
  // 交互式提示阻塞（sudo 密码、ssh yes/no 等）
  interactivePrompt = "interactivePrompt",
  // 连接断开（SSH 网络断开 / 本地 PTY 进程退出）
  disconnected = "disconnected",
  // 权限不足（写入/读取被拒绝，需要 sudo 或切换用户）
  permissionDenied = "permissionDenied",
  // 取消执行
  cancelled = "cancelled",
  // 其他未分类错误
  unknown = "unknown",
}

// 检测结果
export class CommandFailureDiagnostic {
  constructor(
    readonly kind: CommandFailureKind,
    readonly reason: string,
  ) {}
}

// 命令执行失败的细分类原因（诊断规则见各模式注释）
export class PtyOutputDetector {
  // Shell 语法错误（POSIX shell）
  // 严格模式：必须以 `bash:` 或 `-bash:` 开头，且包含 `syntax error`
  // 误报规避：用户 `cat` 日志时，日志中包含 `bash:` 字样不会同时满足两个条件
  static readonly syntaxErrorPattern = new RegExp("(?:^|\\n|[\\r\\n])\\-?(?:bash|sh|zsh|ksh):\\s*(.+)");

  static readonly syntaxErrorKeyword = new RegExp("syntax error", "i");

  // PS2 多行提示符（引号/括号未闭合）
  // 模式：行首 `> ` 或 `dquote> ` / `quote> ` / `cmdsubst> ` / `bquote> `
  // 误报规避：要求出现在新行行首，且命令已发出超过 200ms（避免命令回显瞬间误判）
  static readonly ps2PromptPattern = new RegExp("(?:^|\\n)\\s*(?:dquote|quote|cmdsubst|bquote|curly|paren|)> ");

  // 交互式密码/确认提示（sudo 之外的）
  //
  // sudo 提示不在这里匹配 —— 见 [SudoPromptResponder]，它按语言中立的
  // `[sudo]` 前缀识别，覆盖中文 `[sudo] cjm 的密码：` 这类本地化提示。
  static readonly interactivePromptPattern = new RegExp("(?:Password:\\s*$|Enter passphrase|Are you sure you want to continue|^\\s*\\(yes/no\\)|^\\s*\\(yes/no/\\[fingerprint\\]\\))", "m");

  // sudo 密码提示（语言中立）
  //
  // sudo 只翻译 "password for %u" 这部分，`[sudo]` 前缀在所有 locale 下保留：
  //   en: `[sudo] password for cjm:`  zh: `[sudo] cjm 的密码：`
  static readonly sudoPromptAtEnd = new RegExp("\\[sudo\\][^\\r\\n]*[:：][ \\t\\r]*$");

  // less/more 分页器停在等待按键的状态行
  //
  // 交互式 PTY 中 `journalctl`/`git log`/`systemctl status` 默认把输出交给
  // pager，命令不退出，末尾的退出码 marker 永远不会出现 —— 只能干等超时
  static readonly pagerStatusAtEnd = new RegExp("(?:\\(END\\)|--\\s*More\\s*--(?:\\(\\d+%\\))?|lines\\s+\\d+-\\d+/\\d+)(?:[\\s\\x08]|\\x1B\\[[\\x20-\\x3F]*[\\x40-\\x7E]|\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)|\\x1B[(][A-Za-z]|\\x1B[)][A-Za-z]|\\x1B[A-Za-z])*$");
  // 缓冲尾部是否停在 less/more 的分页状态行上
  //
  // 命中后调用方应向 stdin 发送 `q`，让 pager 退出、命令继续执行到 marker。
  // 只看尾部 2KB：状态行一定在最后，遍历 256KB 缓冲没有意义。
  static waitsForPager(buffer: string): boolean {
    const tailLength = 2048;
    const tail = buffer.length > tailLength
      ? buffer.substring(buffer.length - tailLength)
      : buffer;
    return PtyOutputDetector.pagerStatusAtEnd.test(tail);
  }

  // 当前缓冲尾部是否正卡在 sudo 密码提示上
  static waitsForSudoPassword(buffer: string): boolean {
    return PtyOutputDetector.sudoPromptAtEnd.test(buffer);
  }

  // 尾部 sudo 密码提示的匹配（无提示返回 null）
  //
  // 暴露匹配位置而不只是布尔值：`[sudo]` 之前的内容无法跨行匹配，
  // 所以命中的永远是**最后**一段提示，其起始下标可以用来区分"同一个提示的
  // 后续增量"和"sudo 重试/命令链里的下一个提示"。
  static sudoPromptMatch(buffer: string): RegExpExecArray | null {
    return PtyOutputDetector.sudoPromptAtEnd.exec(buffer);
  }
}

export interface DetectOptions {
  readonly buffer: string;
  readonly marker: string;
  readonly elapsedMs: number;
  readonly isWindows: boolean;
  readonly sudoPromptWillBeAnswered?: boolean;
  readonly donePattern?: RegExp;
}

// 检测输出并返回失败原因（null 表示未检测到异常）
//
// [buffer] 当前累积的输出
// [marker] 当前命令的 marker（"EXITCODE_N:" 形式）
// [elapsedMs] 自命令发出后经过的毫秒数
// [isWindows] 平台分支（Windows 不做 POSIX shell 检测）
// [sudoPromptWillBeAnswered] 调用方会在命中 sudo 提示时写入密码。
//   为 true 时 sudo 提示不再算异常 —— 否则检测器抢在注入之前 complete()，
//   调用方随即发 Ctrl+C，把刚要接受密码的 sudo 打断（中英文 locale 都会）。
//
// 注意：marker 字符串本身会出现在命令回显里（如 `echo "EXITCODE_1:$?"`），
// 这是正常的。真正的"命令完成"是 marker + 退出码数字。
// 这里只检查 marker 是否出现，命令回显里的 marker 会被误判为完成 ——
// 这个误判由调用方 [executeAndWait] 的 donePattern（marker+\\d+）规避，
export function detectCommandFailure(o: DetectOptions): CommandFailureDiagnostic | null {
  const sudoPromptWillBeAnswered = o.sudoPromptWillBeAnswered === true;
  // 命令真正完成 = marker+数字出现（由调用方 donePattern 判定）
  const completedPattern = o.donePattern ?? new RegExp(
    o.marker.replace(/[.*+?^\${}()|[\]\\]/g, "\$&") + "\\d+");
  if (completedPattern.test(o.buffer)) return null;
  // 太早检测会误报（命令回显瞬间）—— 至少等 150ms 让回显稳定
  if (o.elapsedMs < 150) return null;
  if (!o.isWindows) {
    // 2. Shell 语法错误检测（bash/sh/zsh 行 + syntax error 关键字）
    const syntaxMatch = PtyOutputDetector.syntaxErrorPattern.exec(o.buffer);
    if (syntaxMatch !== null) {
      const rest = syntaxMatch[1] ?? "";
      if (PtyOutputDetector.syntaxErrorKeyword.test(rest)) {
        const firstLine = rest.split(new RegExp("\\[\r\n]"))[0].trim();
        return new CommandFailureDiagnostic(CommandFailureKind.syntaxError,
          "Shell syntax error: " + firstLine);
      }
    }
    // 3. PS2 多行提示符检测（引号未闭合，仅在 500ms 后）
    if (o.elapsedMs > 500 && PtyOutputDetector.ps2PromptPattern.test(o.buffer)) {
      return new CommandFailureDiagnostic(CommandFailureKind.syntaxError,
        "Shell 等待更多输入（引号或括号未闭合），进入 PS2 提示符");
    }
  }
  // 4. 交互式密码/确认提示检测（跨平台，300ms 后）
  if (o.elapsedMs > 300) {
    if (PtyOutputDetector.waitsForSudoPassword(o.buffer)) {
      if (!sudoPromptWillBeAnswered) {
        return new CommandFailureDiagnostic(CommandFailureKind.interactivePrompt,
          "命令等待交互式 sudo 密码提示（未配置 sudo 密码）");
      }
    } else if (PtyOutputDetector.interactivePromptPattern.test(o.buffer)) {
      return new CommandFailureDiagnostic(CommandFailureKind.interactivePrompt,
        "命令进入交互式提示（密码/确认），无法在非交互模式完成");
    }
  }
  return null;
}

// sudo 密码应答状态机（每次 executeAndWait 一个实例）。
//
// [PtyOutputDetector.waitsForSudoPassword] 只在提示卡在缓冲尾部时命中，但同一个
// 提示可能分多个 chunk 到达（尾随空格、换行）。这里用提示的起始下标区分：
// 下标没变 = 同一段提示的增量，不再应答；下标变大 = sudo 重试或命令链里的下一条
// sudo，需要再答一次。答重了会把密码当成新一轮尝试，直接触发"对不起，请重试"。
export class SudoPromptResponder {
  private lastAnsweredStart = -1;

  // 此刻是否应该把密码写入 stdin。
  shouldAnswer(buffer: string): boolean {
    const match = PtyOutputDetector.sudoPromptMatch(buffer);
    if (match === null) return false;
    // 缓冲按尾部 256KB 截断后下标会整体前移，此时旧游标已无意义
    if (this.lastAnsweredStart >= buffer.length) this.lastAnsweredStart = -1;
    if (match.index <= this.lastAnsweredStart) return false;
    this.lastAnsweredStart = match.index;
    return true;
  }
}
