// exit_marker_scanner.test.ts - 1:1 port of Dart exit_marker_scanner.dart
// (dea9cc1). add() semantics: hasMatch over (carry + chunk); the carry
// keeps only the last marker.length+16 chars. The Dart call site
// (local_terminal_service.dart:331) gates re-firing with
// `if (doneCompleter.isCompleted) return;` - dedup is a CALLER concern,
// not the class concern, so the class reports pattern presence in the
// current window.
import {describe, it, expect} from "vitest";
import {ExitMarkerScanner} from "../src/utils/exit_marker_scanner.js";

const MARKER = "EXITCODE_1:"; // 12 chars -> carry keeps 28

describe("ExitMarkerScanner", () => {
  it("detects marker+digits inside a single chunk", () => {
    const s = new ExitMarkerScanner(MARKER);
    expect(s.add("some output ")).toBe(false);
    expect(s.add(MARKER + "0 ")).toBe(true);
    // Dart add() = hasMatch(window); no caller-level dedup here. The
    // pattern may still be in the window - the Dart caller would have
    // already stopped calling add() (doneCompleter completed).
  });

  it("catches a marker split exactly at a chunk boundary", () => {
    const s = new ExitMarkerScanner(MARKER);
    // 6 marker chars + '0' in chunk 1; the carry window (28 chars) keeps
    // all of it. Chunk 2 has the remaining 6 marker chars.
    expect(s.add(MARKER.slice(0, 6))).toBe(false);
    expect(s.add(MARKER.slice(6) + "0")).toBe(true);
  });

  it("catches a marker + code arriving in the same chunk", () => {
    const s = new ExitMarkerScanner(MARKER);
    expect(s.add(MARKER + "1")).toBe(true);
  });

  it("keeps only the carry window after long chunks", () => {
    const s = new ExitMarkerScanner(MARKER);
    // 1000 x's + marker: the carry holds the last 28 chars, which
    // includes the full marker. Then '0' completes it.
    s.add("x".repeat(1000) + MARKER);
    expect(s.add("0")).toBe(true);
  });

  it("does NOT match when digits are absent (Dart pattern needs \\d+)", () => {
    const s = new ExitMarkerScanner(MARKER);
    expect(s.add(MARKER + " ")).toBe(false); // marker with only a trailing space
    expect(s.add("no digits here")).toBe(false);
  });

  it("literal marker echo without digits does not fire (R8.2)", () => {
    const s = new ExitMarkerScanner(MARKER);
    expect(s.add(MARKER + "$?")).toBe(false); // $? is not a digit
    expect(s.add(MARKER + " ")).toBe(false);
    expect(s.add(MARKER + "2")).toBe(true);
  });

  it("carries across an empty chunk", () => {
    const s = new ExitMarkerScanner(MARKER);
    s.add(MARKER.slice(0, 4));
    expect(s.add("")).toBe(false); // empty chunk: carry unchanged
    expect(s.add(MARKER.slice(4) + "0")).toBe(true);
  });
});
