/// 终端右键菜单的文本判定：全部为纯函数，便于单测。
///
/// 这些判定只影响"菜单里出现什么"，不会直接执行任何东西；误判最多多出一条
/// 无害的菜单项，所以宁可宽松一点也不要漏掉常见形态。
library;

import '../core/ui_text.dart';

final RegExp _urlPattern = RegExp("[^\\s<>\"'`]+");
final RegExp _urlPrefix = RegExp('https?://');
final RegExp _windowsPathPattern = RegExp("[A-Za-z]:\\\\[^\\s\"'<>|]*");
final RegExp _posixPathPattern =
    RegExp("(?<![\\w.])(?:~|\\.{1,2})?/[^\\s\"'<>|:,;]+");
final RegExp _errorPattern = RegExp(
  r'(error|exception|failed|failure|fatal|denied|not found|timed out|traceback|panic|segfault)'
  r'|错误|失败|异常|拒绝|超时|不存在',
  caseSensitive: false,
);
final RegExp _promptPrefix = RegExp(
  r'^\s*(?:PS [^>]*>|\$|#|>|[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+:[^\s$#]*[$#])\s*',
);

String _trimTrailingPunctuation(String value) =>
    value.replaceFirst(RegExp(r'[)\].,;:!?，。；：！？]+$'), '');

/// 行内首个 URL
String? detectUrl(String line) {
  for (final match in _urlPrefix.allMatches(line)) {
    final rest = line.substring(match.start);
    final token = _urlPattern.firstMatch(rest)?.group(0);
    if (token != null && token.length > match.end - match.start) {
      return _trimTrailingPunctuation(token);
    }
  }
  return null;
}

/// 行内覆盖 [column]（字符串下标）的 URL，Ctrl+点击打开链接用。
/// 与 [detectUrl] 同一套识别口径，只是多了一个位置命中判断。
String? urlAtColumn(String line, int column) {
  for (final match in _urlPrefix.allMatches(line)) {
    final rest = line.substring(match.start);
    final token = _urlPattern.firstMatch(rest)?.group(0);
    if (token == null || token.length <= match.end - match.start) continue;
    final url = _trimTrailingPunctuation(token);
    if (column >= match.start && column < match.start + url.length) return url;
  }
  return null;
}

/// 行内首个文件路径（Windows 盘符路径优先，其次 POSIX 绝对路径 / ~ / ./ ..）
String? detectPath(String line) {
  final windows = _windowsPathPattern.firstMatch(line);
  if (windows != null) return _trimTrailingPunctuation(windows.group(0)!);
  final posix = _posixPathPattern.firstMatch(line);
  if (posix != null) return _trimTrailingPunctuation(posix.group(0)!);
  return null;
}

/// 这一行像不像报错。
///
/// 先剔掉 URL 与路径再匹配：`/var/log/nginx/error.log`、`.../error.html` 只是文件名，
/// 不代表这一行是报错。
bool looksLikeError(String line) {
  var probe = line;
  final url = detectUrl(line);
  if (url != null) probe = probe.replaceAll(url, ' ');
  final path = detectPath(line);
  if (path != null) probe = probe.replaceAll(path, ' ');
  return _errorPattern.hasMatch(probe);
}

/// 粘贴内容是否多行（多行等于批量执行，粘贴前必须确认）
///
/// 末尾的**一个**换行符不算多行：从终端复制一条命令几乎总是连回车一起
/// 拷过来（选区天然含尾部 \n），判成多行就等于对最常见的单条命令粘贴
/// 也弹一次确认框。真正危险的「一次落进多条命令」要求去掉尾换行之后
/// 仍有行分隔符。
bool isMultiLine(String text) {
  var body = text;
  if (body.endsWith('\r\n')) {
    body = body.substring(0, body.length - 2);
  } else if (body.endsWith('\n') ||
      body.endsWith('\r') ||
      body.endsWith('\u2028')) {
    body = body.substring(0, body.length - 1);
  }
  return body.contains('\n') || body.contains('\r') || body.contains('\u2028');
}

/// 去掉提示符前缀后，是否像一条可执行命令（单行、首 token 不含空格）
bool looksLikeCommand(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || isMultiLine(trimmed)) return false;
  if (looksLikeError(trimmed)) return false;
  final stripped = trimmed.replaceFirst(_promptPrefix, '');
  if (stripped.isEmpty) return false;
  final firstToken = stripped.split(RegExp(r'\s+')).first;
  if (firstToken.length > 200) return false;
  // 首 token 必须是"像程序名"的样子，中文句子/英文正常句子直接排除
  return RegExp(r'^[A-Za-z0-9_./~\\:$-][A-Za-z0-9_./~\\:$-]*$')
      .hasMatch(firstToken);
}

/// 去掉提示符前缀（复制/发给 Agent 时用）
String stripPromptPrefix(String text) =>
    text.replaceFirst(_promptPrefix, '').trimRight();

/// 发送给 Agent 的解释请求
String agentExplainPrompt(String selection) => UiText.t(
      '解释下面这段终端输出，指出关键信息、风险和下一步建议：\n```\n${selection.trim()}\n```',
      'Explain the following terminal output. Point out the key information, risks, and recommended next steps:\n```\n${selection.trim()}\n```',
    );

/// 发送给 Agent 的排错请求
String agentErrorPrompt(String line) => UiText.t(
      '这段终端报错是什么意思？给出原因、影响和修复步骤：\n```\n${line.trim()}\n```',
      'What does this terminal error mean? Give the cause, impact, and fix steps:\n```\n${line.trim()}\n```',
    );

/// 发送给 Agent 的「整条命令 + 它的输出」请求（OSC 133 命令块）。
/// 与单行排错的差别在于：这里有完整上下文，可以让它先判断命令意图再看输出。
String agentBlockPrompt(String block) => UiText.t(
      '下面是一次命令及其完整输出（```` 代码块内，第一行通常是命令本身）。'
          '先说明这条命令在做什么，再判断结果是成功还是失败；失败就给出原因和修复步骤：\n'
          '````\n${block.trim()}\n````',
      'Below is one command with its full output (inside the ```` fence; the first line is usually the command). '
          'First state what the command does, then say whether it succeeded; if it failed, give the cause and the fix:\n'
          '````\n${block.trim()}\n````',
    );

/// 取路径所在目录（SFTP 定位用）：`/a/b/c.log` → `/a/b`，`~/x` → `~`
String directoryOfPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final idx = normalized.lastIndexOf('/');
  if (idx > 0) return normalized.substring(0, idx);
  if (idx == 0) return '/';
  return '.';
}
