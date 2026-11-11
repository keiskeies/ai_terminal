// utils/output_processor.ts - ports of the two output-capping helpers:
//   truncateOutput        - lib/utils/output_processor.dart lines 1-21, 1:1
//   truncateQueryOutput   - lib/services/agent_engine.dart lines 2957-2965, 1:1
// R8: query commands must NOT get unlimited output either - cat huge_file /
// journalctl can produce MBs; the query path keeps a tail of 20000 chars.
// stripCommandEcho stays unported: the Node executor layer already strips
// the echo once (R8 double-cleaning ban), a second pass would delete real
// output whose first line resembles the command.

/// 截断命令输出，保留尾部（长输出有价值的信息通常在末尾，如 "Complete!"）
/// 最多保留 [maxLines] 行，或 [maxChars] 字符
export function truncateOutput(output: string | undefined | null, maxLines = 8, maxChars = 600): string {
  if (output == null || output == "") return "(无输出)";
  if (output.length <= maxChars) return output;

  // 按行分割，取尾部行
  const lines = output.split("\n");
  if (lines.length <= maxLines) {
    // 行数不多但字符超限，取尾部字符
    return "...(输出过长，已截断前 " + (output.length - maxChars) + " 字符)\n" + output.substring(output.length - maxChars);
  }

  // 取尾部行
  const tailLines = lines.slice(lines.length - maxLines);
  const tailText = tailLines.join("\n");
  if (tailText.length > maxChars) {
    return "...(输出过长，已截断)\n" + tailText.substring(tailText.length - maxChars);
  }
  return "...(输出过长，已截断前 " + (lines.length - maxLines) + " 行)\n" + tailText;
}

/// 查询命令输出截断：保留尾部 20000 字符（错误信息通常在末尾）
/// R8: 查询命令不截断会导致 cat/journalctl/find 等输出撑爆 AI 上下文
export const MAX_QUERY_OUTPUT_CHARS = 20000;
export function truncateQueryOutput(output: string | undefined | null): string {
  if (output == null || output == "") return "(无输出)";
  if (output.length <= MAX_QUERY_OUTPUT_CHARS) return output;
  return "...(输出过长，已截断前 " + (output.length - MAX_QUERY_OUTPUT_CHARS) + " 字符)\n" +
    output.substring(output.length - MAX_QUERY_OUTPUT_CHARS);
}
