// adaptive_concurrency.test.ts
// Mirrors Dart adaptive_concurrency_test.dart (102 lines, 5 cases).

import {describe, it, expect} from "vitest";
import {chooseInitialUploadConcurrency, AdaptiveConcurrency} from "../src/utils/adaptive_concurrency.js";

describe("chooseInitialUploadConcurrency (Dart oracle)", () => {

  it("tiers by average file size", () => {
    expect(chooseInitialUploadConcurrency({fileCount: 0, averageBytes: 0})).toBe(1);
    expect(chooseInitialUploadConcurrency({fileCount: 1, averageBytes: 1})).toBe(1);
    expect(chooseInitialUploadConcurrency({fileCount: 100, averageBytes: 100 * 1024})).toBe(16);
    expect(chooseInitialUploadConcurrency({fileCount: 100, averageBytes: 1 * 1024 * 1024})).toBe(8);
    expect(chooseInitialUploadConcurrency({fileCount: 100, averageBytes: 4 * 1024 * 1024})).toBe(4);
    expect(chooseInitialUploadConcurrency({fileCount: 100, averageBytes: 16 * 1024 * 1024})).toBe(2);
  });
});

describe("AdaptiveConcurrency (Dart oracle)", () => {

  it("halves after 3 consecutive failures, floor at 1", () => {
    const c = new AdaptiveConcurrency({initial: 16});
    c.onFailure();
    c.onFailure();
    expect(c.current).toBe(16, "below 3 does not reduce");
    c.onFailure();
    expect(c.current).toBe(8);
    for (let i = 0; i < 3; i++) c.onFailure();
    expect(c.current).toBe(4);
    for (let i = 0; i < 3; i++) c.onFailure();
    expect(c.current).toBe(2);
    for (let i = 0; i < 3; i++) c.onFailure();
    expect(c.current).toBe(1);
    for (let i = 0; i < 9; i++) c.onFailure();
    expect(c.current).toBe(1, "cannot go below 1");
    expect(c.degraded).toBe(true);
  });

  it("recovers to initial via 20-success streaks, capped at initial", () => {
    const c = new AdaptiveConcurrency({initial: 8});
    for (let i = 0; i < 3; i++) c.onFailure();
    expect(c.current).toBe(4);
    for (let i = 0; i < 20; i++) c.onSuccess();
    expect(c.current).toBe(5);
    for (let i = 0; i < 200; i++) c.onSuccess();
    expect(c.current).toBe(8);
  });

  it("success resets failure streak", () => {
    const c = new AdaptiveConcurrency({initial: 16});
    c.onFailure();
    c.onFailure();
    c.onSuccess();
    c.onFailure();
    c.onFailure();
    expect(c.current).toBe(16, "non-consecutive failures do not reduce");
  });

  it("fixed mode ignores success/failure", () => {
    const c = new AdaptiveConcurrency({initial: 8, adaptive: false});
    for (let i = 0; i < 10; i++) c.onFailure();
    expect(c.current).toBe(8);
    expect(c.degraded).toBe(false);
  });
});