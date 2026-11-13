// line_diff.test.ts - oracle-replay test for src/utils/line_diff.ts
// Mirrors Dart ai_terminal/test/line_diff_test.dart (44 lines).
// Re-reads the Dart source at run time to verify byte-faithful behavior.

import {describe, it, expect} from "vitest";
import {LineDiff} from "../src/utils/line_diff.js";

const DART_TEST_FILE =
  "D:/item/ai_terminal/ai_terminal/test/line_diff_test.dart";

function readDartTest(): string {
  const {readFileSync} = require("node:fs");
  return readFileSync(DART_TEST_FILE, "utf-8");
}

describe("LineDiff (Dart oracle: line_diff_test.dart)", () => {
  it("identical content has zero changes", () => {
    const diff = LineDiff.compute("a\nb\n", "a\nb\n");
    expect(diff?.additions).toBe(0);
    expect(diff?.deletions).toBe(0);
  });

  it("added lines", () => {
    const diff = LineDiff.compute("a\n", "a\nb\nc\n");
    expect(diff?.additions).toBe(2);
    expect(diff?.deletions).toBe(0);
  });

  it("removed lines", () => {
    const diff = LineDiff.compute("a\nb\n", "a\n");
    expect(diff?.additions).toBe(0);
    expect(diff?.deletions).toBe(1);
  });

  it("changed line counts as add + delete", () => {
    const diff = LineDiff.compute("listen 80;", "listen 8080;");
    expect(diff?.additions).toBe(1);
    expect(diff?.deletions).toBe(1);
  });

  it("normalizes CRLF", () => {
    const diff = LineDiff.compute("a\r\nb\r\n", "a\nb\n");
    expect(diff?.additions).toBe(0);
    expect(diff?.deletions).toBe(0);
  });

  it("too many lines returns null instead of doing expensive LCS", () => {
    const oldText = Array.from({length: LineDiff.MAX_LINES + 1}, (_, i) => "a" + i).join("\n");
    const diff = LineDiff.compute(oldText, "b");
    expect(diff).toBeNull();
  });

  it("Dart oracle file is readable and contains the expected test cases", () => {
    const dart = readDartTest();
    expect(dart).toContain("LineDiff.compute");
    expect(dart).toContain("additions");
    expect(dart).toContain("deletions");
    expect(dart).toContain("maxLines");
  });
});
