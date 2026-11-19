/// 增量检测退出码 marker（形如 `EXITCODE_1:0`）。
///
/// marker 可能被拆在两个输出 chunk 的边界上。这里只保留上一块尾部与下一块
/// 拼接，检测成本从「每个 chunk 扫完整个输出缓冲」降为 O(当前 chunk)。
class ExitMarkerScanner {
  /// 完成判定要求数字后跟一个非数字字符（正常是 `\r\n`）。
  ///
  /// 没有这个边界时，退出码 `137` 被拆成 `1` / `37` 两个 chunk 到达会立即按
  /// `1` 完成，而监听方在完成后丢弃后续 chunk —— 缓冲里永远只剩 `1`，
  /// OOM-kill 被误判成普通错误。
  final RegExp donePattern;
  final int _carryChars;
  String _carry = '';

  ExitMarkerScanner(String marker)
      : donePattern = RegExp('${RegExp.escape(marker)}\\d+[^\\d]'),
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

  /// 缓冲**尾部**正好停在 marker+数字上（后面再没有字节到达）时也视为完成。
  ///
  /// 用于 onDone/断线兜底：marker 刚输出完 channel 就关闭时，donePattern 等不到
  /// 边界字符，若按「未完成」处理会把正常结束的命令误判成断线。
  static bool matchesAtEnd(String bufferTail, String marker) =>
      RegExp('${RegExp.escape(marker)}\\d+\$').hasMatch(bufferTail);
}
