// Round 126: 1:1 replay of ai_terminal/test/choice_request_detector_test.dart
// (8 oracle cases) against src/utils/choice_request_detector.ts, plus a regex-
// drift lock that re-reads the Dart source. ASCII-pure: CJK via \uXXXX escapes.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {ChoiceRequestDetector, ChoiceRequest} from "../src/utils/choice_request_detector.js";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const NL = String.fromCharCode(10);
const readText = (path: string): string => readFileSync(path, "utf-8").replace(/\r\n/g, NL);

type CR = ChoiceRequest;

describe("ChoiceRequestDetector - 8 Dart oracle cases", () => {
  it("letter options + explicit ask -> button texts", () => {
    const r = ChoiceRequestDetector.detect("\u5b89\u88c5 Docker \u6709\u4e24\u79cd\u65b9\u5f0f\uff1a\nA. \u4f7f\u7528\u5b98\u65b9\u6e90\u5b89\u88c5\nB. \u4f7f\u7528\u6e05\u534e\u955c\u50cf\u5b89\u88c5\n\u8bf7\u56de\u590d\u9009\u62e9 A \u8fd8\u662f B\uff0c\u6211\u7acb\u5373\u6267\u884c\u3002");
    expect(r).not.toBeNull();
    expect([...((r as CR | null) as CR).options]).toEqual(["A. \u4f7f\u7528\u5b98\u65b9\u6e90\u5b89\u88c5", "B. \u4f7f\u7528\u6e05\u534e\u955c\u50cf\u5b89\u88c5"]);
    expect(((r as CR | null) as CR).question).toContain("\u5b89\u88c5 Docker \u6709\u4e24\u79cd\u65b9\u5f0f");
    expect(((r as CR | null) as CR).question).toContain("\u8bf7\u56de\u590d\u9009\u62e9 A \u8fd8\u662f B");
    // option lines must not duplicate into the question body
    expect(((r as CR | null) as CR).question).not.toContain("A. \u4f7f\u7528\u5b98\u65b9\u6e90\u5b89\u88c5");
  });
  it("options written before the ask line still detected", () => {
    const r = ChoiceRequestDetector.detect("A\uff1a\u5148\u5907\u4efd\u518d\u5347\u7ea7\nB\uff1a\u76f4\u63a5\u5347\u7ea7\n\u8bf7\u9009\u62e9\u4e00\u4e2a\u65b9\u6848\u3002");
    expect(r).not.toBeNull();
    expect(((r as CR | null) as CR).options).toHaveLength(2);
    expect(((r as CR | null) as CR).options[0] as string).toMatch(/^A\. /);
  });
  it("letters-only A-or-B line -> bare letter buttons", () => {
    const r = ChoiceRequestDetector.detect("\u5982\u9700\u514d sudo \u4f7f\u7528 docker\uff0c\u5b89\u88c5\u5b8c\u6210\u540e\u6211\u53ef\u4ee5\u518d\u7ed9\u547d\u4ee4\u3002\n\u8bf7\u56de\u590d\u9009\u62e9 A \u8fd8\u662f B\uff08\u6216\u76f4\u63a5\u8bf4\u201c\u7528 A \u4f46\u8d70\u6e05\u534e\u955c\u50cf\u201d\uff09\uff0c\u6211\u7acb\u5373\u6267\u884c\u3002");
    expect(r).not.toBeNull();
    expect([...((r as CR | null) as CR).options]).toEqual(["\u65b9\u6848 A", "\u65b9\u6848 B"]);
  });
  it("long summary without an explicit ask is NOT hijacked", () => {
    const r = ChoiceRequestDetector.detect("\u7ed3\u8bba: \u5df2\u5b8c\u6210\u68c0\u67e5\n\u73b0\u72b6: \u670d\u52a1\u8fd0\u884c\u6b63\u5e38\n\u53d8\u66f4: \u65e0\n\u5efa\u8bae: \u540e\u7eed\u53ef\u4ee5\u8003\u8651 A \u6216 B \u4e24\u79cd\u4f18\u5316\u65b9\u5f0f\u3002");
    expect(r).toBeNull();
  });
  it("plain numbered list without an ask is NOT hijacked", () => {
    const r = ChoiceRequestDetector.detect("\u6267\u884c\u5b8c\u6210\uff0c\u7ed3\u679c\u5982\u4e0b\uff1a\n1. \u7cfb\u7edf\u7248\u672c\u5df2\u786e\u8ba4\n2. \u78c1\u76d8\u7a7a\u95f4\u5145\u8db3\n3. \u670d\u52a1\u72b6\u6001\u6b63\u5e38");
    expect(r).toBeNull();
  });
  it("bare confirm line is NOT a choice request", () => {
    const r = ChoiceRequestDetector.detect("\u8bf7\u786e\u8ba4\u4ee5\u4e0a\u4fe1\u606f\u3002");
    expect(r).toBeNull();
  });
  it("fenced example is NOT hijacked", () => {
    const r = ChoiceRequestDetector.detect("\u8fd9\u662f\u4e00\u4e2a\u683c\u5f0f\u793a\u4f8b\uff1a\n```\n\u8bf7\u56de\u590d\u9009\u62e9 A \u8fd8\u662f B\nA. \u793a\u4f8b\u4e00\nB. \u793a\u4f8b\u4e8c\n```\n\u7ed3\u8bba: \u4efb\u52a1\u5df2\u5b8c\u6210");
    expect(r).toBeNull();
  });
  it("numbered CJK options + explicit ask", () => {
    const r = ChoiceRequestDetector.detect("\u8bf7\u9009\u62e9\u8981\u5b89\u88c5\u7684\u7248\u672c\uff1a\n1\u3001\u7a33\u5b9a\u7248\n2\u3001\u6700\u65b0\u7248");
    expect(r).not.toBeNull();
    expect([...((r as CR | null) as CR).options]).toEqual(["1. \u7a33\u5b9a\u7248", "2. \u6700\u65b0\u7248"]);
  });
});

// Regex-drift lock: each Dart pattern (single raw literal or adjacent raw-
// literal concatenation inside RegExp(...)) must equal the TS RegExp source.
// JS escapes a literal slash inside regex literals as \/ - normalize both sides.
describe("regex drift vs Dart source", () => {
  const dart = readText(HERE + "../../ai_terminal/lib/utils/choice_request_detector.dart");
  const slash = (s: string): string => s.replace(/\\\//g, "/");
  const dartPat = (varName: string): string => {
    const at = dart.indexOf(varName + " = RegExp(");
    if (at < 0) throw new Error(varName + " not found");
    const end = dart.indexOf(");", at);
    if (end < 0) throw new Error(varName + ": no closer");
    const seg = dart.slice(at, end + 2);
    const lits = seg.match(/r'[^']*'/g);
    if (lits === null) throw new Error(varName + ": no raw literals");
    return lits.map((s) => s.slice(2, -1)).join("");
  };
  const priv = ChoiceRequestDetector as unknown as Record<string, RegExp>;
  for (const [tsName, dartName] of [
    ["CUE", "_cuePattern"], ["binaryLetters", "_binaryLetters"],
    ["letterOption", "_letterOption"], ["numberedOption", "_numberedOption"],
    ["trailingPunct", "_trailingPunct"],
  ] as const) {
    it(tsName + " source equals Dart " + dartName, () => {
      expect(slash(priv[tsName].source)).toBe(slash(dartPat(dartName)));
    });
  }
});
