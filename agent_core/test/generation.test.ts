// Hermetic tests for utils/generation.ts (TaskGeneration / StaleTaskError /
// crossBoundary) - the R1.1 stale-task guard. No I/O, no network.
//
// The guard prevents a stale task from writing state after it has been
// superseded or cancelled. These tests pin every branch: isCurrent (current
// vs. stale vs. cancelled), ensureCurrent (the matching throw / no-throw),
// StaleTaskError payload + name, and the crossBoundary/ensureCurrent ordering
// the R1 review checklist mandates.

import {describe, it, expect} from "vitest";
import {TaskGeneration, StaleTaskError, crossBoundary} from "../src/utils/generation.js";

// A shared mutable counter mirrors how ReActEngine wires TaskGeneration:
// the engine holds a single _currentTaskGeneration that is read by every
// TaskGeneration instance and bumped on cancel / supersede.
function makeHarness(initialGen: number) {
  const counter = { value: initialGen };
  let cancelled = false;
  const gen = new TaskGeneration(initialGen, () => counter.value, () => cancelled);
  return {
    gen,
    bump: () => { counter.value++; },
    cancel: () => { cancelled = true; },
  };
}

describe("TaskGeneration.isCurrent", () => {
  it("is true when myGen equals the current generation and not cancelled", () => {
    const { gen } = makeHarness(5);
    expect(gen.isCurrent()).toBe(true);
  });

  it("is false when myGen is STALE (behind the current generation)", () => {
    const { gen, bump } = makeHarness(5);
    bump(); // currentGen now 6, myGen still 5
    expect(gen.isCurrent()).toBe(false);
  });

  it("is false when cancelled, even if myGen still matches", () => {
    const { gen, cancel } = makeHarness(3);
    cancel();
    expect(gen.isCurrent()).toBe(false);
  });

  it("reflects a live currentGen callback (re-evaluated on each call)", () => {
    const { gen, bump } = makeHarness(1);
    expect(gen.isCurrent()).toBe(true);
    bump();
    expect(gen.isCurrent()).toBe(false);
  });
});

describe("TaskGeneration.bump + ensureCurrent", () => {
  it("bump() makes a previously-current task stale; ensureCurrent() throws", () => {
    const { gen, bump } = makeHarness(1);
    expect(gen.isCurrent()).toBe(true);
    bump();
    expect(gen.isCurrent()).toBe(false);
    expect(() => gen.ensureCurrent()).toThrow(StaleTaskError);
    const e: StaleTaskError | null = (() => {
      try { gen.ensureCurrent(); return null; } catch (x) { return x as StaleTaskError; }
    })();
    expect(e!.myGen).toBe(1);
    expect(e!.currentGen).toBe(2);
    expect(e!.name).toBe("StaleTaskError");
    expect(e!.message).toContain("stale");
    expect(e).toBeInstanceOf(Error);
  });

  it("ensureCurrent() is a no-op while the task is still current", () => {
    const { gen } = makeHarness(9);
    expect(() => gen.ensureCurrent()).not.toThrow();
  });

  it("cancelled() (without bump) also trips ensureCurrent", () => {
    const { gen, cancel } = makeHarness(4);
    cancel();
    expect(() => gen.ensureCurrent()).toThrow(StaleTaskError);
  });
});

describe("StaleTaskError shape", () => {
  it("carries myGen / currentGen and a descriptive, name-tagged message", () => {
    const e = new StaleTaskError(2, 6);
    expect(e.myGen).toBe(2);
    expect(e.currentGen).toBe(6);
    expect(e.name).toBe("StaleTaskError");
    expect(e.message).toContain("my=2");
    expect(e.message).toContain("current=6");
    expect(e).toBeInstanceOf(Error);
  });
});

describe("crossBoundary + ensureCurrent ordering (R1 checklist)", () => {
  it("the caller MUST guard shared-state writes after the await", async () => {
    const { gen, bump } = makeHarness(1);
    let wrote = 0;
    await crossBoundary(async () => {
      await new Promise((r) => setTimeout(r, 0));
      bump(); // the task was superseded while we were awaiting
    }, gen);
    try {
      gen.ensureCurrent();
      wrote = 1;
    } catch (x) {
      expect(x).toBeInstanceOf(StaleTaskError);
    }
    expect(wrote).toBe(0); // the stale write was dropped
  });

  it("propagates a rejecting inner promise (does not swallow the error)", async () => {
    const { gen } = makeHarness(1);
    await expect(crossBoundary(async () => { throw new Error("boom"); }, gen)).rejects.toThrow("boom");
  });
});
