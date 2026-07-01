/// 截断命令输出，保留尾部（长输出有价值的信息通常在末尾，如 "Complete!"）
/// 最多保留 [maxLines] 行，或 [maxChars] 字符
String truncateOutput(String? output, {int maxLines = 8, int maxChars = 600}) {
  if (output == null || output.isEmpty) return '(无输出)';
  if (output.length <= maxChars) return output;

  // 按行分割，取尾部行
  final lines = output.split('\n');
  if (lines.length <= maxLines) {
    // 行数不多但字符超限，取尾部字符
    return '...(输出过长，已截断前 ${output.length - maxChars} 字符)\n${output.substring(output.length - maxChars)}';
  }

  // 取尾部行
  final tailLines = lines.skip(lines.length - maxLines).toList();
  final tailText = tailLines.join('\n');
  if (tailText.length > maxChars) {
    return '...(输出过长，已截断)\n${tailText.substring(tailText.length - maxChars)}';
  }
  return '...(输出过长，已截断前 ${lines.length - maxLines} 行)\n$tailText';
}

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
