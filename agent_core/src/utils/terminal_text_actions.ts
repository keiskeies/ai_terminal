// utils/terminal_text_actions.ts - r209 port of utils/terminal_text_actions.dart
// (104 lines). 终端右键菜单的文本判定：全部为纯函数，便于单测。
//
// 这些判定只影响"菜单里出现什么"，不会直接执行任何东西；误判最多多出一条
// 无害的菜单项，所以宁可宽松一点也不要漏掉常见形态。
//
// The Dart file's only import was core/ui_text.dart (zh/en selector). Following
// the established port precedent (engine hourglass notice, continue prompt),
// agentExplainPrompt/agentErrorPrompt keep the zh branch verbatim - the Node
// agent_core has no locale switch; the en strings stay pinned in the oracle test.

// noinspection RegExpRedundantEscape: Dart source uses \\s inside a string literal
const urlPattern = /[^\s<>"'`]+/;
const urlPrefix = /https?:\/\//g;
const windowsPathPattern = /[A-Za-z]:\\[^\s"'<>|]*/;
const posixPathPattern = /(?<![\w.])(?:~|\.{1,2})?\/[^\s"'<>|:,;]+/;
const errorPattern = new RegExp(
  "(error|exception|failed|failure|fatal|denied|not found|timed out|traceback|panic|segfault)" +
    "|错误|失败|异常|拒绝|超时|不存在",
  "i",
);
const promptPrefix = /^\s*(?:PS [^>]*>|\$|#|>|[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+:[^\s$#]*[$#])\s*/;

const trimTrailingPunctuation = (value: string): string =>
  value.replace(/[\])\].,;:!?，。；：！？]+$/, "");

/// 行内首个 URL
export function detectUrl(line: string): string | null {
  for (const m of line.matchAll(urlPrefix)) {
    const rest = line.slice(m.index);
    const token = urlPattern.exec(rest)?.[0];
    if (token !== undefined && token.length > m[0].length) {
      return trimTrailingPunctuation(token);
    }
  }
  return null;
}

/// 行内首个文件路径（Windows 盘符路径优先，其次 POSIX 绝对路径 / ~ / ./ ..）
export function detectPath(line: string): string | null {
  const windows = windowsPathPattern.exec(line);
  if (windows !== null) return trimTrailingPunctuation(windows[0]);
  const posix = posixPathPattern.exec(line);
  if (posix !== null) return trimTrailingPunctuation(posix[0]);
  return null;
}

/// 这一行像不像报错。
///
/// 先剔掉 URL 与路径再匹配：`/var/log/nginx/error.log`、`.../error.html` 只是文件名，
/// 不代表这一行是报错。
export function looksLikeError(line: string): boolean {
  let probe = line;
  const url = detectUrl(line);
  if (url !== null) probe = probe.replaceAll(url, " ");
  const path = detectPath(line);
  if (path !== null) probe = probe.replaceAll(path, " ");
  return errorPattern.test(probe);
}

/// 粘贴内容是否多行（多行等于批量执行，粘贴前必须确认）
export function isMultiLine(text: string): boolean {
  return text.includes("\n") || text.includes("\r") || text.includes("\u2028");
}

/// 去掉提示符前缀后，是否像一条可执行命令（单行、首 token 不含空格）
export function looksLikeCommand(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.length === 0 || isMultiLine(trimmed)) return false;
  if (looksLikeError(trimmed)) return false;
  const stripped = trimmed.replace(promptPrefix, "");
  if (stripped.length === 0) return false;
  const firstToken = stripped.split(/\s+/)[0];
  if (firstToken.length > 200) return false;
  // 首 token 必须是"像程序名"的样子，中文句子/英文正常句子直接排除
  return /^[A-Za-z0-9_./~\\:$-][A-Za-z0-9_./~\\:$-]*$/.test(firstToken);
}

/// 去掉提示符前缀（复制/发给 Agent 时用）
export function stripPromptPrefix(text: string): string {
  return text.replace(promptPrefix, "").replace(/\s+$/, "");
}

/// 发送给 Agent 的解释请求 (Dart UiText.t zh branch, pinned by the oracle test)
export function agentExplainPrompt(selection: string): string {
  return "解释下面这段终端输出，指出关键信息、风险和下一步建议：\n```\n" + selection.trim() + "\n```";
}

/// 发送给 Agent 的排错请求 (Dart UiText.t zh branch, pinned by the oracle test)
export function agentErrorPrompt(line: string): string {
  return "这段终端报错是什么意思？给出原因、影响和修复步骤：\n```\n" + line.trim() + "\n```";
}

/// 取路径所在目录（SFTP 定位用）：`/a/b/c.log` → `/a/b`，`~/x` → `~`
export function directoryOfPath(path: string): string {
  const normalized = path.replaceAll("\\", "/");
  const idx = normalized.lastIndexOf("/");
  if (idx > 0) return normalized.slice(0, idx);
  if (idx === 0) return "/";
  return ".";
}
