/// 简单的行级 diff 统计（用于文件补丁的 +N -M）
class LineDiffResult {
  final int additions;
  final int deletions;

  const LineDiffResult(this.additions, this.deletions);
}

class LineDiff {
  /// 超过这个行数就不做 LCS，避免大文件在 UI 线程做 O(n*m) 计算
  static const int maxLines = 600;

  /// 返回 null 表示片段过大、不做精确统计
  static LineDiffResult? compute(String oldText, String newText) {
    final oldLines = _lines(oldText);
    final newLines = _lines(newText);
    if (oldLines.length > maxLines || newLines.length > maxLines) return null;
    if (oldLines.isEmpty && newLines.isEmpty) return const LineDiffResult(0, 0);

    // LCS，滚动数组
    final dp = List<int>.filled(newLines.length + 1, 0);
    for (var i = 0; i < oldLines.length; i++) {
      var prev = 0;
      for (var j = 1; j <= newLines.length; j++) {
        final temp = dp[j];
        if (oldLines[i] == newLines[j - 1]) {
          dp[j] = prev + 1;
        } else if (dp[j - 1] > dp[j]) {
          dp[j] = dp[j - 1];
        }
        prev = temp;
      }
    }
    final lcs = dp[newLines.length];
    return LineDiffResult(
      newLines.length - lcs,
      oldLines.length - lcs,
    );
  }

  static List<String> _lines(String text) {
    final normalized = text.replaceAll('\r\n', '\n');
    if (normalized.isEmpty) return const [];
    final lines = normalized.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return lines;
  }
}
