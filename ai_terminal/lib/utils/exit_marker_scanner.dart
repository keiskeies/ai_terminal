/// 增量检测退出码 marker（形如 `EXITCODE_1:0`）。
///
/// marker 可能被拆在两个输出 chunk 的边界上。这里只保留上一块尾部与下一块
/// 拼接，检测成本从「每个 chunk 扫完整个输出缓冲」降为 O(当前 chunk)。
class ExitMarkerScanner {
  final RegExp donePattern;
  final int _carryChars;
  String _carry = '';

  ExitMarkerScanner(String marker)
      : donePattern = RegExp('${RegExp.escape(marker)}\\d+'),
        _carryChars = marker.length + 16;

  /// 追加一块输出，返回是否出现了完整的 marker+退出码
  bool add(String chunk) {
    final combined = _carry + chunk;
    final found = donePattern.hasMatch(combined);
    _carry = combined.length > _carryChars
        ? combined.substring(combined.length - _carryChars)
        : combined;
    return found;
  }
}
