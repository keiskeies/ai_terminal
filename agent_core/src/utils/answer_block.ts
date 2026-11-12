// utils/answer_block.ts - 1:1 port of agent_engine.dart 2103-2124 (the regex
// constants, the clip helper and _firstColonIndex) + 2126-2153 (parseAnswerBlock)
// + 2159-2198 (parseReportSections).
// Dart keeps them as static members of AgentEngine and calls them from
// _parseReActResponse (2002-2004) once per turn; the values then ride on the
// ReActStep (.answer / .sections) into the finish branch (1473-1482), the
// fallback step (2046-2054) and the choice hijack (3034-3047). Node has no
// ReActStep, so the two extractors live in utils/ (the same home as
// command_heuristics.ts) and the engine keeps turn-local variables with the
// same three values: answerText / sections / thought.

// 从 `回答:` 行之后收集到内容结束；遇到结构性关键词行停止。两条防误切规则：
// - 只认行首的协议关键词（动作/思考/计划/工具/参数 + 操作单四字段），
//   正文里的 `**结论**:` 这类带前缀的写法不受影响
// - ``` 围栏内的关键词行不触发停止，否则"回答里示范一段 ReAct 格式"会把正文截断
// Dart 2103-2104 (_answerStopLine) - .source must stay byte-identical, see
// test/answer_block_oracle.test.ts.
export const ANSWER_STOP_LINE = /^(动作|思考|说明|计划|工具|参数|结论|现状|变更|建议)\s*[:：]/;

// 操作单四段字段的行首标记（`**结论**:` 这类正文写法不算）
// Dart 2107 (_sectionStartLine)
export const SECTION_START_LINE = /^(结论|现状|变更|建议)\s*[:：]/;

// 回答正文上限（R8：落库文本必须有界；超出保留头部并标注截断）
// Dart 2110 (_maxAnswerChars)
export const MAX_ANSWER_CHARS = 12000;

// Dart 2112-2115 (_clipAnswerText). The marker is the Dart literal tail after
// the interpolation: NL NL + the truncation note.
export function clipAnswerText(text: string): string {
  if (text.length <= MAX_ANSWER_CHARS) return text;
  return text.substring(0, MAX_ANSWER_CHARS) + '\n\n…（回答过长，已截断）';
}

// 首个半角/全角冒号的位置（避免为一个 indexOf 编译正则）
// Dart 2118-2124 (_firstColonIndex)
export function firstColonIndex(text: string): number {
  const ascii = text.indexOf(':');
  const fullWidth = text.indexOf('：');
  if (ascii < 0) return fullWidth;
  if (fullWidth < 0) return ascii;
  return ascii < fullWidth ? ascii : fullWidth;
}

const NL = String.fromCharCode(10);

// Dart String.trimRight(): trailing whitespace only (Dart 2151 / 2152).
function trimRight(s: string): string {
  return s.replace(/\s+$/, '');
}

/**
 * Dart 2126-2153 parseAnswerBlock. Dart collects with a StringBuffer and
 * writeln(), i.e. every pushed line is followed by NL; the trailing NL is
 * invisible after trimRight, so join(NL) is the same string.
 */
export function parseAnswerBlock(lines: string[]): string | null {
  let startIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith('回答:') || t.startsWith('回答：')) {
      startIdx = i;
      break;
    }
  }
  if (startIdx < 0) return null;

  const first = lines[startIdx].trim();
  const sep = firstColonIndex(first);
  const parts: string[] = [];
  const inline = first.substring(sep + 1).trim();
  if (inline !== '') parts.push(inline);

  let inFence = false;
  for (let i = startIdx + 1; i < lines.length; i++) {
    const raw = lines[i];
    const t = raw.trim();
    if (t.startsWith('```')) {
      inFence = !inFence;
    } else if (!inFence && ANSWER_STOP_LINE.test(t)) {
      break;
    }
    parts.push(raw);
  }

  const text = trimRight(parts.join(NL));
  // Dart 2152 re-trims before clipping; keep the double trimRight verbatim.
  return text.trim() === '' ? null : clipAnswerText(trimRight(text));
}

// 解析 `回答:` 之后的操作单四字段块（结论/现状/变更/建议）。
//
// 只从 `回答:` 之后找，避免把正文里恰好以这些词开头的行当成字段；
// ``` 围栏内的行不触发。返回 null 表示模型没写四段。
/**
 * Dart 2159-2198 parseReportSections. Lines are collected RAW (Dart 2194),
 * and the block ends at the next 动作/思考/说明/回答 line (Dart 2184-2191).
 */
export function parseReportSections(lines: string[]): string | null {
  let answerIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith('回答:') || t.startsWith('回答：')) {
      answerIdx = i;
      break;
    }
  }
  if (answerIdx < 0) return null;

  let inFence = false;
  let start = -1;
  for (let i = answerIdx + 1; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (!inFence && SECTION_START_LINE.test(t)) {
      start = i;
      break;
    }
  }
  if (start < 0) return null;

  const parts: string[] = [];
  for (let i = start; i < lines.length; i++) {
    const t = lines[i].trim();
    if (t.startsWith('动作:') ||
        t.startsWith('动作：') ||
        t.startsWith('思考:') ||
        t.startsWith('思考：') ||
        t.startsWith('说明:') ||
        t.startsWith('说明：') ||
        t.startsWith('回答:') ||
        t.startsWith('回答：')) {
      break;
    }
    parts.push(lines[i]);
  }
  const text = parts.join(NL).trim();
  return text === '' ? null : text;
}
