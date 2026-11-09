// line_diff.ts - 1:1 port of Dart ai_terminal/lib/utils/line_diff.dart.
// Simple line-level diff statistics (used for file-patch "+N -M").

export interface LineDiffResult {
  additions: number;
  deletions: number;
}

export class LineDiff {
  /** Above this line count we skip LCS to avoid O(n*m) on big files. */
  static readonly MAX_LINES = 600;

  /** Returns null when either side is too large for exact counting. */
  static compute(oldText: string, newText: string): LineDiffResult | null {
    const oldLines = LineDiff.lines(oldText);
    const newLines = LineDiff.lines(newText);
    if (oldLines.length > LineDiff.MAX_LINES || newLines.length > LineDiff.MAX_LINES) return null;
    if (oldLines.length === 0 && newLines.length === 0) return {additions: 0, deletions: 0};

    // LCS, rolling array over the new-line dimension.
    const dp = new Array<number>(newLines.length + 1).fill(0);
    for (let i = 0; i < oldLines.length; i++) {
      let prev = 0;
      for (let j = 1; j <= newLines.length; j++) {
        const temp = dp[j];
        if (oldLines[i] === newLines[j - 1]) {
          dp[j] = prev + 1;
        } else if (dp[j - 1] > dp[j]) {
          dp[j] = dp[j - 1];
        }
        prev = temp;
      }
    }
    const lcs = dp[newLines.length];
    return {additions: newLines.length - lcs, deletions: oldLines.length - lcs};
  }

  private static lines(text: string): string[] {
    const normalized = text.replace(/\r\n/g, "\n");
    if (normalized === "") return [];
    const lines = normalized.split("\n");
    if (lines.length > 0 && lines[lines.length - 1] === "") lines.length--;
    return lines;
  }
}
