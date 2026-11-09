// llm/stream.ts - hermetic unit tests for StreamAccumulator + shouldRetryWithoutStreamOptions
//
// Covers the W2 streaming-layer gap: no direct unit test existed for the chunk
// accumulator (only e2e via anthropic/r9). This locks the Dart-parity semantics:
//   - pushText / pushReasoningDelta / pushRawChunk chunk accumulation
//   - reasoning_content (DeepSeek/OpenAI) and reasoning (other gateways) both honored
//   - non-string / empty reasoning deltas are ignored (never pollutes body text)
//   - tailCap retains the TAIL (most recent), not the head (R8 unbounded-buffer rule)
//   - shouldRetryWithoutStreamOptions: only 400 + actually sent the flag
//
// These are byte-faithful to Dart reasoningDeltaOf + ai_service.dart stream loop.
import {describe, it, expect} from "vitest";
import {StreamAccumulator, shouldRetryWithoutStreamOptions} from "../src/llm/stream.js";

describe("StreamAccumulator - text accumulation", () => {
  it("joins text deltas in order", () => {
    const a = new StreamAccumulator();
    a.pushText("abc");
    a.pushText("def");
    a.pushText("");       // empty delta -> no-op (Dart: content != null && isNotEmpty)
    expect(a.getResult().text).toBe("abcdef");
  });

  it("getResult returns empty text + no reasoning when nothing pushed", () => {
    const a = new StreamAccumulator();
    const r = a.getResult();
    expect(r.text).toBe("");
    expect(r.reasoning).toBe("");
    expect(r.hasReasoning).toBe(false);
  });
});

describe("StreamAccumulator - reasoning delta (reasoningDeltaOf parity)", () => {
  it("accumulates string reasoning deltas, ignores non-string + empty", () => {
    const a = new StreamAccumulator();
    a.pushReasoningDelta("think: ");
    a.pushReasoningDelta("let me compute");
    a.pushReasoningDelta("");       // empty -> ignored (Dart: value.isNotEmpty)
    a.pushReasoningDelta(null);    // non-string -> ignored (Dart: value is String)
    a.pushReasoningDelta(123);     // non-string -> ignored
    const r = a.getResult();
    expect(r.reasoning).toBe("think: let me compute");
    expect(r.hasReasoning).toBe(true);
  });

  it("hasReasoning stays false when only non-string deltas arrive", () => {
    const a = new StreamAccumulator();
    a.pushReasoningDelta(null);
    a.pushReasoningDelta(42);
    expect(a.getResult().hasReasoning).toBe(false);
    expect(a.getResult().reasoning).toBe("");
  });
});

describe("StreamAccumulator - pushRawChunk (both reasoning field names)", () => {
  it("honors reasoning_content (DeepSeek/OpenAI)", () => {
    const a = new StreamAccumulator();
    a.pushRawChunk({choices: [{delta: {content: "body", reasoning_content: "deep"}}]});
    const r = a.getResult();
    expect(r.text).toBe("body");
    expect(r.reasoning).toBe("deep");
    expect(r.hasReasoning).toBe(true);
  });

  it("falls back to reasoning (other gateways) when reasoning_content absent", () => {
    const a = new StreamAccumulator();
    a.pushRawChunk({choices: [{delta: {content: "x", reasoning: "alt"}}]});
    const r = a.getResult();
    expect(r.reasoning).toBe("alt");
    expect(r.hasReasoning).toBe(true);
  });

  it("reasoning_content wins when both present (Dart: ?? precedence)", () => {
    const a = new StreamAccumulator();
    a.pushRawChunk({choices: [{delta: {content: "y", reasoning_content: "rc", reasoning: "rg"}}]});
    // Dart delta['reasoning_content'] ?? delta['reasoning'] -> reasoning_content wins
    expect(a.getResult().reasoning).toBe("rc");
  });

  it("missing choices/delta is a safe no-op", () => {
    const a = new StreamAccumulator();
    a.pushRawChunk({});                          // no choices
    a.pushRawChunk({choices: []});              // empty choices
    a.pushRawChunk({choices: [{delta: null}]}); // null delta
    const r = a.getResult();
    expect(r.text).toBe("");
    expect(r.hasReasoning).toBe(false);
  });
});

describe("StreamAccumulator - tailCap (R8: keep TAIL not head)", () => {
  it("retains the most-recent tailCap chars, drops the head", () => {
    const a = new StreamAccumulator({tailCap: 5});
    a.pushText("AAAAA");
    a.pushText("BBBBB");   // "AAAAABBBBB" (10) -> tail5 = "BBBBB"
    expect(a.getResult().text).toBe("BBBBB");
  });

  it("boundary: length == tailCap keeps the whole string (no off-by-one)", () => {
    const a = new StreamAccumulator({tailCap: 5});
    a.pushText("ABCDE");
    expect(a.getResult().text).toBe("ABCDE");
  });

  it("tailCap below length by 1 keeps exactly tailCap", () => {
    const a = new StreamAccumulator({tailCap: 3});
    a.pushText("ABCDEF");   // "ABCDEF" (6) -> tail3 = "DEF"
    expect(a.getResult().text).toBe("DEF");
  });

  it("tailCap=0 means unlimited (default)", () => {
    const a = new StreamAccumulator();
    a.pushText("very long text that should not be truncated at all");
    expect(a.getResult().text).toBe("very long text that should not be truncated at all");
  });

  it("tailCap applies to text only; reasoning is never capped", () => {
    const a = new StreamAccumulator({tailCap: 3});
    a.pushText("XXXXX");
    a.pushReasoningDelta("long reasoning that survives");
    const r = a.getResult();
    expect(r.text).toBe("XXX");
    expect(r.reasoning).toBe("long reasoning that survives");
  });
});

describe("shouldRetryWithoutStreamOptions (Dart parity)", () => {
  it("true only when the flag was sent AND the gateway returned 400", () => {
    expect(shouldRetryWithoutStreamOptions(true, 400)).toBe(true);
  });
  it("false on 401 (quota/auth, unrelated to the field)", () => {
    expect(shouldRetryWithoutStreamOptions(true, 401)).toBe(false);
  });
  it("false on 429 / 500 (transient / server error, not a schema reject)", () => {
    expect(shouldRetryWithoutStreamOptions(true, 429)).toBe(false);
    expect(shouldRetryWithoutStreamOptions(true, 500)).toBe(false);
  });
  it("false when the flag was not sent even on 400", () => {
    expect(shouldRetryWithoutStreamOptions(false, 400)).toBe(false);
  });
  it("false when status is null (no response)", () => {
    expect(shouldRetryWithoutStreamOptions(true, null)).toBe(false);
  });
});
