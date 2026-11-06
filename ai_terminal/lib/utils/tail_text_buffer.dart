/// 只保留尾部有限字符的可追加缓冲。
///
/// 对比 `StringBuffer` + 每次超限都 `toString/substring/clear/write` 的写法：
/// 这里只在超过 2× 上限时裁剪一次，写入是摊还 O(1)，适合持续输出的大命令。
class TailTextBuffer {
  final int maxChars;
  final StringBuffer _buffer = StringBuffer();

  TailTextBuffer(this.maxChars);

  int get length => _buffer.length;

  void write(String data) {
    if (data.isEmpty) return;
    _buffer.write(data);
    if (_buffer.length > maxChars * 2) {
      final text = _buffer.toString();
      _buffer
        ..clear()
        ..write(text.substring(text.length - maxChars));
    }
  }

  void clear() => _buffer.clear();

  /// 尾部快照（最多 [maxChars] 字符）
  String tail() {
    final text = _buffer.toString();
    return text.length > maxChars
        ? text.substring(text.length - maxChars)
        : text;
  }

  @override
  String toString() => tail();
}
