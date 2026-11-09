// Hermetic unit tests for the three untested leaf utility modules:
//   line_diff.ts    (LCS-based +N/-M statistics, R8: bounded)
//   tail_buffer.ts  (R8: tail-retaining buffer, 5 boundary cases)
//   pending_registry.ts (R1.2: resolve-all on cancel + CompleterLike)

import {describe, it, expect} from "vitest";
import {LineDiff} from "../src/utils/line_diff.js";
import {TailTextBuffer} from "../src/utils/tail_buffer.js";
import {PendingRegistry, CompleterLike} from "../src/utils/pending_registry.js";

// ── LineDiff ────────────────────────────────────────────────────────────────

describe("LineDiff.compute (LCS +N/-M)", () => {
  it("empty old + empty new -> {additions:0, deletions:0}", () => {
    expect(LineDiff.compute("", "")).toEqual({additions: 0, deletions: 0});
  });

  it("single line changed -> 1 addition + 1 deletion", () => {
    expect(LineDiff.compute("a", "b")).toEqual({additions: 1, deletions: 1});
  });

  it("identical text -> 0/0", () => {
    expect(LineDiff.compute("a\nb\nc", "a\nb\nc")).toEqual({additions: 0, deletions: 0});
  });

  it("addition only: old empty, new 3 lines", () => {
    expect(LineDiff.compute("", "a\nb\nc")).toEqual({additions: 3, deletions: 0});
  });

  it("deletion only: new empty, old 2 lines", () => {
    expect(LineDiff.compute("a\nb", "")).toEqual({additions: 0, deletions: 2});
  });

  it("LCS preserves shared lines (partial overlap)", () => {
    // old = [x, y, z], new = [x, w, z] -> LCS=[x,z] len=2
    // additions = 3-2=1 (w), deletions = 3-2=1 (y)
    expect(LineDiff.compute("x\ny\nz", "x\nw\nz")).toEqual({additions: 1, deletions: 1});
  });

  it("CRLF normalised before splitting", () => {
    expect(LineDiff.compute("a\r\nb", "a\r\nb")).toEqual({additions: 0, deletions: 0});
    expect(LineDiff.compute("a\r\nb", "a\r\nc")).toEqual({additions: 1, deletions: 1});
  });

  it("trailing newline does not add an empty line", () => {
    expect(LineDiff.compute("a\nb\n", "a\nb")).toEqual({additions: 0, deletions: 0});
  });

  it("returns null when either side exceeds MAX_LINES (600)", () => {
    const big = Array.from({length: 601}, (_, i) => "line" + i).join("\n");
    expect(LineDiff.compute(big, big)).toBeNull();
    expect(LineDiff.compute("", big)).toBeNull();
  });

  it("600 lines exactly is still computed (boundary: not > MAX_LINES)", () => {
    const exactly600 = Array.from({length: 600}, (_, i) => "line" + i).join("\n");
    expect(LineDiff.compute(exactly600, exactly600)).toEqual({additions: 0, deletions: 0});
  });
});

// ── TailTextBuffer (R8: 5 boundary cases) ───────────────────────────────────

describe("TailTextBuffer (R8 tail-cap)", () => {
  it("boundary 1: length equals cap -> isFull true, tail = full content", () => {
    const b = new TailTextBuffer(10);
    b.write("0123456789");
    expect(b.length()).toBe(10);
    expect(b.isFull).toBe(true);
    expect(b.tail()).toBe("0123456789");
  });

  it("boundary 2: length below cap -> isFull false, tail = full content", () => {
    const b = new TailTextBuffer(10);
    b.write("0123");
    expect(b.length()).toBe(4);
    expect(b.isFull).toBe(false);
    expect(b.tail()).toBe("0123");
  });

  it("boundary 3: single write exceeds cap -> keeps the tail cap chars", () => {
    const b = new TailTextBuffer(5);
    b.write("ABCDEFGHIJ");  // 10 chars, cap 5 -> tail "FGHIJ"
    expect(b.tail()).toBe("FGHIJ");
    expect(b.length()).toBe(5);
    expect(b.isFull).toBe(true);
  });

  it("boundary 4: cap = 1 keeps exactly 1 char (tail)", () => {
    const b = new TailTextBuffer(1);
    b.write("a");
    b.write("b");
    expect(b.tail()).toBe("b");
  });

  it("boundary 5: constructor rejects 0 / negative / non-finite", () => {
    expect(() => new TailTextBuffer(0)).toThrow(RangeError);
    expect(() => new TailTextBuffer(-1)).toThrow(RangeError);
    expect(() => new TailTextBuffer(Infinity)).toThrow(RangeError);
  });

  it("empty write is a no-op", () => {
    const b = new TailTextBuffer(10);
    b.write("");
    expect(b.tail()).toBe("");
    expect(b.length()).toBe(0);
  });

  it("clear() resets to empty", () => {
    const b = new TailTextBuffer(5);
    b.write("ABCDE");
    b.clear();
    expect(b.tail()).toBe("");
    expect(b.isFull).toBe(false);
  });

  it("set() overwrites and truncates to cap", () => {
    const b = new TailTextBuffer(3);
    b.set("XYZ");
    expect(b.tail()).toBe("XYZ");
    b.set("ABCDEFG");
    expect(b.tail()).toBe("EFG");
  });

  it("chained writes: write() returns this for chaining", () => {
    const b = new TailTextBuffer(10);
    const c = b.write("a");
    expect(c).toBe(b);
    const d = b.clear();
    expect(d).toBe(b);
    const e = b.set("hi");
    expect(e).toBe(b);
  });
});

// ── PendingRegistry (R1.2: resolve-all on cancel) ──────────────────────────

describe("PendingRegistry (R1.2)", () => {
  it("register + resolveAll resolves all waiters", async () => {
    const reg = new PendingRegistry();
    let a = false, b = false, c = false;
    reg.register(() => { a = true; });
    reg.register(() => { b = true; });
    reg.register(() => { c = true; });
    expect(reg.size).toBe(3);
    expect(reg.isEmpty).toBe(false);
    reg.resolveAll();
    // microtask flush
    await new Promise(r => setImmediate(r));
    expect(a).toBe(true);
    expect(b).toBe(true);
    expect(c).toBe(true);
    expect(reg.size).toBe(0);
    expect(reg.isEmpty).toBe(true);
  });

  it("resolveAll is idempotent (calling twice does not re-fire)", () => {
    const reg = new PendingRegistry();
    let calls = 0;
    reg.register(() => { calls++; });
    reg.resolveAll();
    reg.resolveAll();  // no-op: set is cleared
    expect(calls).toBe(1);
  });

  it("a throwing waiter does not block other waiters", () => {
    const reg = new PendingRegistry();
    let second = false;
    reg.register(() => { throw new Error("boom"); });
    reg.register(() => { second = true; });
    reg.resolveAll();
    expect(second).toBe(true);
  });

  it("empty registry: resolveAll is a no-op", () => {
    const reg = new PendingRegistry();
    expect(() => reg.resolveAll()).not.toThrow();
    expect(reg.size).toBe(0);
  });
});

// ── CompleterLike (R1.2: promise wrapper) ─────────────────────────────────

describe("CompleterLike", () => {
  it("resolve() resolves the promise exactly once", async () => {
    const c = new CompleterLike<string>();
    c.resolve("val");
    c.resolve("other");  // idempotent
    const out = await c.promise;
    expect(out).toBe("val");
    expect(c.isDone).toBe(true);
  });

  it("reject() rejects the promise exactly once", async () => {
    const c = new CompleterLike<number>();
    c.reject(new Error("fail"));
    c.reject(new Error("second"));
    await expect(c.promise).rejects.toThrow("fail");
    expect(c.isDone).toBe(true);
  });

  it("isDone is false before resolve/reject", () => {
    const c = new CompleterLike();
    expect(c.isDone).toBe(false);
  });

  it("resolve wins over reject when called first (idempotency)", () => {
    const c = new CompleterLike<string>();
    c.resolve("ok");
    c.reject(new Error("should be ignored"));
    expect(c.isDone).toBe(true);
  });
});
