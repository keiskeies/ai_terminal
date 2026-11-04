/// 从 finish / 回答正文里识别「让用户在若干方案中选择」的请求。
///
/// ReAct 协议要求提问走 `动作: ask` + `选项:`，但部分模型会把
/// “请回复选择 A 还是 B”写进 finish 正文：UI 没有按钮，任务却在用户
/// 做决定前收尾。这里做保守兜底 —— 必须同时命中「明确的选择请求」和
/// 「可提取的选项」才转换，普通总结里的“建议: 可以考虑 A 或 B”不会误伤。
class ChoiceRequest {
  final String question;
  final List<String> options;

  const ChoiceRequest(this.question, this.options);
}

class ChoiceRequestDetector {
  /// 只看正文末尾：选择请求几乎总在回答收尾处，避免扫到历史里的示例。
  static const int _tailLines = 25;

  /// 询问窗口：选项通常紧挨着提问行，最多向前回看 6 行。
  static const int _optionLookback = 6;

  static const int _maxQuestionChars = 600;
  static const int _maxOptionDescChars = 60;

  /// 明确的选择请求。单独的“请确认”不算 —— 那多半是命令确认，不是选项。
  static final RegExp _cuePattern = RegExp(
    r'请\s*(?:你\s*)?(?:回复|选择|选一个|选个|挑选|告诉|做出选择|确认选择)'
    r'|需要你(?:来)?(?:选择|决定|确认)'
    r'|(?:回复|选择)\s*(?:选项|[A-Za-z0-9一二三四五六])'
    r'|(?:哪一?个|哪一种|哪套|哪个)(?:方案|方式|做法|版本)'
    r'|(?:选|用)\s*[A-Za-z]\s*(?:还是|或|/)',
  );

  /// “请回复选择 A 还是 B”这类只有字母、没有描述的写法。
  static final RegExp _binaryLetters = RegExp(
    r'(?:选择|回复|选)\s*([A-Za-z0-9一二三四五六])\s*(?:还是|或|/|、)\s*([A-Za-z0-9一二三四五六])',
  );

  static final RegExp _letterOption = RegExp(
    r'^\s*(?:[-*•·]\s*)?(?:方案\s*)?([A-Za-z])\s*[.、:：)）]\s*(\S.{0,59})$',
  );

  static final RegExp _numberedOption = RegExp(
    r'^\s*(?:[-*•·]\s*)?(?:方案\s*)?([1-6一二三四五六])\s*[.、:：)）]\s*(\S.{0,59})$',
  );

  static final RegExp _trailingPunct = RegExp(r'[。；;，,\s]+$');

  /// 返回 null 表示不是明确的选择请求，调用方应照常 finish。
  static ChoiceRequest? detect(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final allLines = trimmed.split(RegExp(r'\r?\n'));
    final start =
        allLines.length > _tailLines ? allLines.length - _tailLines : 0;
    final lines = allLines.sublist(start);

    // 跳过 ``` 围栏里的内容：示范格式的正文不能被当成真实提问
    final inCode = List<bool>.filled(lines.length, false);
    var fenced = false;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().startsWith('```')) {
        inCode[i] = true;
        fenced = !fenced;
      } else {
        inCode[i] = fenced;
      }
    }

    var cueIndex = -1;
    for (var i = lines.length - 1; i >= 0; i--) {
      if (inCode[i]) continue;
      if (_cuePattern.hasMatch(lines[i])) {
        cueIndex = i;
        break;
      }
    }
    if (cueIndex < 0) return null;

    final windowStart =
        cueIndex > _optionLookback ? cueIndex - _optionLookback : 0;
    final options = <String>[];
    final optionLines = <int>{};
    final seen = <String>{};
    void collect(RegExp pattern) {
      for (var i = windowStart; i < lines.length; i++) {
        if (inCode[i] || optionLines.contains(i)) continue;
        final m = pattern.firstMatch(lines[i]);
        if (m == null) continue;
        final label = m.group(1)!.toUpperCase();
        final desc = m.group(2)!.trim().replaceAll(_trailingPunct, '');
        if (desc.isEmpty || !seen.add(label)) continue;
        final clipped = desc.length > _maxOptionDescChars
            ? '${desc.substring(0, _maxOptionDescChars)}…'
            : desc;
        options.add('$label. $clipped');
        optionLines.add(i);
      }
    }

    collect(_letterOption);
    if (options.length < 2) collect(_numberedOption);

    if (options.length < 2) {
      options.clear();
      optionLines.clear();
      final binary = _binaryLetters.firstMatch(lines[cueIndex]);
      if (binary != null) {
        options.add('方案 ${binary.group(1)!.toUpperCase()}');
        options.add('方案 ${binary.group(2)!.toUpperCase()}');
      }
    }

    if (options.length < 2) return null;

    final questionLines = <String>[];
    final questionStart = cueIndex > 4 ? cueIndex - 4 : 0;
    for (var i = questionStart; i < lines.length; i++) {
      if (optionLines.contains(i) || inCode[i]) continue;
      final line = lines[i].trim();
      if (line.isNotEmpty) questionLines.add(line);
    }
    var question = questionLines.join('\n').trim();
    if (question.isEmpty) question = lines[cueIndex].trim();
    if (question.length > _maxQuestionChars) {
      question = '…${question.substring(question.length - _maxQuestionChars)}';
    }

    return ChoiceRequest(question, List.unmodifiable(options));
  }
}
