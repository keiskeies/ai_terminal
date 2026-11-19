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

/// 清理 PTY 输出中的命令回显（执行器层是唯一的回显清洗点，R8 只清一次）
///
/// 长命令会被 PTY 按列宽折行回显（每 80 列插入 \r\n），精确
/// `indexOf(wrappedCommand)` 会 miss，于是回显留在观测里。这里用逐字符
/// 允许 `\r?\n?` 的正则容忍折行；为控制匹配成本只在头部窗口内查找
/// （回显必然出现在输出流头部，命令 ≤500 字符）。找不到就原样返回——
/// 留回显是噪声，误删真实输出是损坏（stripCommandEcho 的前车之鉴）。
String stripWrappedEcho(String output, String wrappedCommand) {
  if (output.isEmpty || wrappedCommand.isEmpty) return output;
  // 快路径：未折行的精确匹配
  final exact = output.indexOf(wrappedCommand);
  if (exact >= 0) return output.substring(exact + wrappedCommand.length);
  // 折行容忍路径：只在头部窗口内试
  final window = output.substring(
      0, output.length < 4096 + wrappedCommand.length
          ? output.length
          : 4096 + wrappedCommand.length);
  final pattern = RegExp(
    wrappedCommand.split('').map(RegExp.escape).join(r'\r?\n?'),
  );
  final m = pattern.firstMatch(window);
  if (m == null) return output;
  return output.substring(m.end);
}

final RegExp _promptLineBash = RegExp(r'^[\w.\-]+@[\w.\-]+:[^\n]*[#$]\s*$');
final RegExp _promptLineBashRoot = RegExp(r'^\[[\w.\-]+@[\w.\-]+[^\]\n]*\][#$]\s*$');
final RegExp _promptLineCmd = RegExp(r'^[A-Za-z]:\\[^\n]*>\s*$');
final RegExp _promptLinePs = RegExp(r'^PS [^\n]*>\s*$');

/// 删除输出末尾整体匹配 shell 提示符形态的最后一行。
///
/// 替代旧的尾部单字符清洗 `replaceAll(RegExp(r'[\]\$#]\s*$'))`——那个会吃掉
/// JSON 数组的 `]`、口令里的 `$` 等合法末字符，而真提示符反而只删掉一个字符。
/// 只认三种整行形态（bash user@host:path$ / cmd `C:\path>` / PS `PS path>`），
/// 不做单字符删除。
String stripTrailingPromptLine(String output) {
  if (output.isEmpty) return output;
  final idx = output.lastIndexOf('\n');
  final lastLine = (idx == -1 ? output : output.substring(idx + 1)).trimRight();
  if (lastLine.isEmpty) return output;
  if (_promptLineBash.hasMatch(lastLine) ||
      _promptLineBashRoot.hasMatch(lastLine) ||
      _promptLineCmd.hasMatch(lastLine) ||
      _promptLinePs.hasMatch(lastLine)) {
    return idx == -1 ? '' : output.substring(0, idx);
  }
  return output;
}
