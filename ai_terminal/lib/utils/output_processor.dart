/// 命令输出分级截断（回传给 AI 的观测）
///
/// 分级规则（O2）：
/// - 查询命令：保留尾部 20000 字符（错误信息通常在末尾）
/// - 非查询成功：保留尾部 2000 字符（长输出有价值的信息通常在末尾）
/// - 失败（exit ≠ 0 / 执行异常）：头 2000 + 尾 6000，中间标注省略字符数；
///   报错原因在头部、stack/summary 在尾部，两头都不能丢
///
/// UI outputTail（8000）与审计日志（500）不走这里，保持各自上限。
library;

/// 查询命令输出上限
const int maxQueryOutputChars = 20000;

/// 非查询成功输出上限
const int maxSuccessOutputChars = 2000;

/// 失败输出保留的头部字符数
const int failureHeadChars = 2000;

/// 失败输出保留的尾部字符数
const int failureTailChars = 6000;

/// 查询命令输出截断：保留尾部 [maxQueryOutputChars] 字符
/// R8: 查询命令不截断会导致 cat/journalctl/find 等输出撑爆 AI 上下文
String truncateQueryOutput(String? output) =>
    _tailTruncate(output, maxQueryOutputChars);

/// 非查询成功输出截断：保留尾部 [maxSuccessOutputChars] 字符
String truncateSuccessOutput(String? output) =>
    _tailTruncate(output, maxSuccessOutputChars);

/// 失败输出截断：头 [failureHeadChars] + 尾 [failureTailChars]，
/// 中间标注 `…(中间省略 N 字符)…`；总长不超过两者之和时原样返回（不截断）。
String truncateFailureOutput(String? output) {
  if (output == null || output.isEmpty) return '(无输出)';
  const keep = failureHeadChars + failureTailChars;
  // R8 边界：长度恰好等于上限时不截断，避免头尾重叠拼接出重复内容
  if (output.length <= keep) return output;
  final omitted = output.length - keep;
  return '${output.substring(0, failureHeadChars)}\n'
      '…(中间省略 $omitted 字符)…\n'
      '${output.substring(output.length - failureTailChars)}';
}

String _tailTruncate(String? output, int maxChars) {
  if (output == null || output.isEmpty) return '(无输出)';
  if (output.length <= maxChars) return output;
  return '...(输出过长，已截断前 ${output.length - maxChars} 字符)\n'
      '${output.substring(output.length - maxChars)}';
}

/// 清理交互确认提示 + 用户答案的终端回显行（O3）
///
/// PTY 先原样回显提示（`Continue? ` 不带换行），答案写进 stdin 后又被回显到
/// 同一行（`Continue? y`）。这段不是命令输出：留在观测里模型会把它当成下一条
/// 命令（真机验证里确实执行了 `Continue? y`，报 `command not found`）。
///
/// R8：只删除与「记录的提示 + 记录的答案」逐字相等的整行（空白折叠后比较），
/// 不做裸子串删除 —— 正文里恰好出现同样文字的行不能被误删。
String stripInteractiveEcho(
  String output,
  List<({String prompt, String answer})> interactions,
) {
  if (output.isEmpty || interactions.isEmpty) return output;
  final expected = <String>{};
  for (final item in interactions) {
    final prompt = _collapseSpaces(item.prompt);
    if (prompt.isEmpty) continue;
    final answer = _collapseSpaces(item.answer);
    expected.add(answer.isEmpty ? prompt : '$prompt $answer');
  }
  if (expected.isEmpty) return output;
  final lines = output.split('\n');
  final kept =
      lines.where((line) => !expected.contains(_collapseSpaces(line))).toList();
  return kept.length == lines.length ? output : kept.join('\n');
}

String _collapseSpaces(String s) =>
    s.replaceAll(RegExp(r'[ \t]+'), ' ').trim();

/// 清理 PTY 输出中的命令回显
/// 终端在执行命令时会先把输入的命令回显到 stdout，导致结果里包含命令本身
String stripCommandEcho(String output, String command) {
  if (output.isEmpty || command.isEmpty) return output;

  final trimmedOutput = output.trimLeft();
  final trimmedCommand = command.trim();

  // 情况 1：输出第一行就是命令本身（最常见）
  final firstNewline = trimmedOutput.indexOf('\n');
  final firstLine = firstNewline == -1 ? trimmedOutput : trimmedOutput.substring(0, firstNewline);
  if (firstLine.trim() == trimmedCommand || firstLine.trim().endsWith(trimmedCommand)) {
    return firstNewline == -1 ? '' : trimmedOutput.substring(firstNewline + 1).trimLeft();
  }

  // 情况 2：命令出现在开头，但前面可能有 prompt 残留字符
  final commandIndex = trimmedOutput.indexOf(trimmedCommand);
  if (commandIndex >= 0 && commandIndex < 20) {
    final afterCommand = trimmedOutput.substring(commandIndex + trimmedCommand.length);
    // 如果命令后紧跟换行，则把这整段视为回显
    if (afterCommand.startsWith('\n') || afterCommand.startsWith('\r')) {
      return afterCommand.replaceFirst(RegExp(r'^[\r\n]+'), '').trimLeft();
    }
  }

  return output;
}
