// test/token_estimator.test.ts - 1:1 replay of ai_terminal/test/token_estimator_test.dart
// against the port src/utils/token_estimator.ts, plus a Dart-source oracle so the
// estimation formula cannot drift silently from the reference implementation.
// CJK literals use \uXXXX escapes (project emit rule), each pinned by a comment.
import {describe, it, expect} from "vitest";
import {fileURLToPath} from "node:url";
import {readFileSync} from "node:fs";
import {
  estimateText,
  isCjk,
  estimateHistory,
  estimateMessage,
  MESSAGE_OVERHEAD_TOKENS,
} from "../src/utils/token_estimator.js";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const DART_ESTIMATOR = HERE + "../../ai_terminal/lib/utils/token_estimator.dart";
const TS_ESTIMATOR = HERE + "../src/utils/token_estimator.ts";
const NL = String.fromCharCode(10);

// CJK literals from the Dart test file, escaped per the emit rules.
const NI_HAO = "\u4f60\u597d"; // hello (2 CJK)
const NI_HAO_SHI_JIE = "\u4f60\u597d\u4e16\u754c"; // hello world (4 CJK)
const FENCE = String.fromCharCode(96, 96, 96); // three code ticks
const ROCKET = String.fromCodePoint(0x1f680); // emoji, 1 code point

function readText(path: string): string {
  return readFileSync(path, "utf-8").replace(/\r\n/g, NL);
}

describe("estimateText (Dart token_estimator_test.dart replay)", () => {
  it("empty string returns 0", () => {
    expect(estimateText("")).toBe(0);
  });

  it("pure ASCII estimates at chars / 4", () => {
    // "hello world" = 11 chars -> (11+3) ~/ 4 = 3
    expect(estimateText("hello world")).toBe(3);
  });

  it("pure CJK is one char = one token", () => {
    expect(estimateText(NI_HAO_SHI_JIE)).toBe(4);
  });

  it("mixed CJK and ASCII accumulate by weight", () => {
    // 2 CJK + 1 space + 5 ascii: cjk 2, ascii 6 -> 2 + (6+3)~/4 = 2 + 2 = 4
    expect(estimateText(NI_HAO + " hello")).toBe(4);
  });

  it("code block counts as plain ASCII", () => {
    const code = FENCE + "bash" + NL + "ls -la" + NL + FENCE; // 18 ASCII -> 5
    expect(code.length).toBe(18);
    expect(estimateText(code)).toBe(5);
  });

  it("long text grows sanely", () => {
    const short = estimateText("abc");
    const longResult = estimateText("a".repeat(1000));
    expect(longResult).toBeGreaterThan(short);
    expect(longResult).toBeLessThan(300); // 1000 ASCII = 250 tokens
    expect(longResult).toBe(250);
  });

  it("emoji counts as one other-char token", () => {
    expect(estimateText(ROCKET)).toBe(1); // Dart asserts greaterThan(0); the port is exactly 1
  });

  it("astral chars are ONE code point, not two UTF-16 units", () => {
    // Dart iterates runes (code points). A .length-based port would count the
    // rocket as 2 surrogates -> 2 tokens. 1 is the only correct answer.
    expect(ROCKET.length).toBe(2);
    expect(estimateText(ROCKET)).toBe(1);
  });
});

describe("isCjk (the six Dart ranges)", () => {
  it("covers exactly the six ranges of _isCjk", () => {
    const on: number[] = [
      0x4e00, 0x9fff, // CJK Unified Ideographs
      0x3400, 0x4dbf, // Extension A
      0xf900, 0xfaff, // Compatibility Ideographs
      0x3000, 0x303f, // CJK Symbols and Punctuation
      0x3040, 0x30ff, // Hiragana / Katakana
      0xac00, 0xd7af, // Hangul Syllables
    ];
    for (const c of on) expect(isCjk(c), "U+" + c.toString(16)).toBe(true);
    const off: number[] = [
      0x2fff, 0x3300, 0x33c0, 0x4dc0, 0x9fff + 1,
      0xac00 - 1, 0xd7b0, 0xf900 - 1, 0xfb00, 0x0041, 0x00e9, 0x2192,
    ];
    for (const c of off) expect(isCjk(c), "U+" + c.toString(16)).toBe(false);
  });
});

describe("estimateHistory / estimateMessage (Dart replay)", () => {
  it("empty history returns 0", () => {
    expect(estimateHistory([])).toBe(0);
  });

  it("each message adds 4 tokens of role overhead", () => {
    // hello -> 2 + 4 = 6 ; hi -> 1 + 4 = 5 ; total 11
    expect(estimateHistory([{content: "hello"}, {content: "hi"}])).toBe(11);
  });

  it("CJK messages sum right", () => {
    // 2+4 = 6 and 4+4 = 8 -> 14
    expect(estimateHistory([{content: NI_HAO}, {content: NI_HAO_SHI_JIE}])).toBe(14);
  });

  it("no system filtering - caller-layer contract (Dart 54-61)", () => {
    // Dart estimateHistory counts EVERY element; _trimMessages splits system out
    // BEFORE calling it. An empty-content message still pays the 4-token overhead.
    expect(estimateHistory([{content: ""}])).toBe(0 + MESSAGE_OVERHEAD_TOKENS);
    expect(estimateHistory([{content: ""}, {content: ""}])).toBe(2 * MESSAGE_OVERHEAD_TOKENS);
  });

  it("estimateMessage matches a single-element estimateHistory", () => {
    const m = {content: "hello"};
    expect(estimateMessage(m)).toBe(estimateHistory([m]));
    expect(MESSAGE_OVERHEAD_TOKENS).toBe(4);
  });
});

describe("Dart source oracle (the formula cannot drift)", () => {
  const dart = () => readText(DART_ESTIMATOR).toLowerCase();
  const ts = () => readText(TS_ESTIMATOR).toLowerCase();

  it("ASCII divisor formula matches", () => {
    expect(dart()).toContain("(ascii + 3) ~/ 4");
    expect(ts()).toContain("math.floor((ascii + 3) / 4)");
  });

  it("all six CJK ranges appear in BOTH sources", () => {
    const hexes = [
      "0x4e00", "0x9fff", "0x3400", "0x4dbf", "0xf900", "0xfaff",
      "0x3000", "0x303f", "0x3040", "0x30ff", "0xac00", "0xd7af",
    ];
    for (const h of hexes) {
      expect(dart(), "dart " + h).toContain(h);
      expect(ts(), "ts " + h).toContain(h);
    }
  });

  it("per-message overhead of 4 tokens matches", () => {
    expect(dart()).toContain("estimatetext(m.content) + 4");
    expect(dart()).toContain("estimatetext(message.content) + 4");
    expect(ts()).toContain("+ message_overhead_tokens");
  });

  it("empty text short-circuits to 0 in BOTH sources", () => {
    expect(dart()).toContain("if (text.isempty) return 0;");
    expect(ts()).toContain("if (text.length === 0) return 0;");
  });
});
