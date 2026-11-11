// utils/token_estimator.ts - byte-faithful port of ai_terminal/lib/utils/token_estimator.dart
// (68 lines). The estimator answers exactly one question: is the conversation history big
// enough that the context budget forces a trim. It is deliberately tokenizer-free:
// an approximation with +/-20% error is fine for THAT decision (the Dart comment says
// the same), and a real tokenizer dependency would bloat the bundled binary for no
// decision-relevant precision.
//
// The one trap a naive port falls into: Dart iterates text.runes - Unicode CODE POINTS.
// A JS .length loop counts UTF-16 code units, so every astral character (emoji, CJK
// Ext B) would count double and inflate the estimate. Array.from() iterates by code
// point, matching runes exactly.

/** Minimal structural view of a chat message: anything with content can be estimated.
 * Local (not imported from llm/clients) so utils stay dependency-free and cycle-proof. */
export interface TokenEstimateMessage {
  readonly content: string;
}

/**
 * Estimate the token count of a text block.
 * - ASCII (code point < 0x80): 4 chars = 1 token, remainder rounded UP ((ascii+3)~/4).
 * - CJK (six ranges below, incl. CJK punctuation): 1 char = 1 token (conservative
 *   upper bound; GPT tokenizes Chinese at roughly 0.6-0.8).
 * - Everything else (Latin extensions, emoji): 1 char = 1 token.
 * Dart token_estimator.dart:17-33, expression order preserved.
 */
export function estimateText(text: string): number {
  if (text.length === 0) return 0; // Dart: if (text.isEmpty) return 0;
  let cjk = 0;
  let ascii = 0;
  let other = 0;
  // Array.from splits by CODE POINT (Dart runes), not by UTF-16 unit.
  for (const ch of Array.from(text)) {
    const code = ch.codePointAt(0);
    if (code === undefined) continue;
    if (code < 0x80) {
      ascii++;
    } else if (isCjk(code)) {
      cjk++;
    } else {
      other++;
    }
  }
  // ASCII 4 chars ~= 1 token; CJK 1 ~= 1; other 1 ~= 1 (Dart line 32 verbatim formula)
  return cjk + Math.floor((ascii + 3) / 4) + other;
}

/**
 * CJK membership over the SAME six ranges as Dart _isCjk (lines 36-50) - boundaries
 * are inclusive on both ends in both languages. CJK Extension B (0x20000+) is NOT in
 * the Dart set and falls to "other" here too; matching the oracle beats being clever.
 */
export function isCjk(code: number): boolean {
  // CJK Unified Ideographs
  if (code >= 0x4e00 && code <= 0x9fff) return true;
  // CJK Extension A
  if (code >= 0x3400 && code <= 0x4dbf) return true;
  // CJK Compatibility Ideographs
  if (code >= 0xf900 && code <= 0xfaff) return true;
  // CJK Symbols and Punctuation
  if (code >= 0x3000 && code <= 0x303f) return true;
  // Hiragana / Katakana
  if (code >= 0x3040 && code <= 0x30ff) return true;
  // Hangul Syllables
  if (code >= 0xac00 && code <= 0xd7af) return true;
  return false;
}

/** Per-message structural overhead: role + separators, Dart lines 58/65. */
export const MESSAGE_OVERHEAD_TOKENS = 4;

/**
 * Estimate a whole history. System messages are included here: Dart
 * estimateHistory is used on ALREADY system-stripped lists by _trimMessages, but the
 * function itself never filters (token_estimator.dart:54-61) - do not add filtering,
 * that is the caller layer contract.
 */
export function estimateHistory(history: readonly TokenEstimateMessage[]): number {
  if (history.length === 0) return 0; // Dart: if (history.isEmpty) return 0;
  let total = 0;
  for (const m of history) {
    total += estimateText(m.content) + MESSAGE_OVERHEAD_TOKENS;
  }
  return total;
}

/** Estimate one message; consistent with estimateHistory for a single element. */
export function estimateMessage(message: TokenEstimateMessage): number {
  return estimateText(message.content) + MESSAGE_OVERHEAD_TOKENS;
}
