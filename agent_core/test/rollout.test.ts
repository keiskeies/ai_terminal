// W8 grayscale rollout bucketing tests - hermetic.
import {describe,it,expect} from "vitest";
import {shouldUseNodeAgent, rolloutFraction} from "../src/utils/rollout.js";

describe("shouldUseNodeAgent", () => {
  it("pct=0 -> always false (opt-in only) unless allow-listed", () => {
    expect(shouldUseNodeAgent("user_1", {pct: 0})).toBe(false);
    expect(shouldUseNodeAgent("user_2", {pct: 0})).toBe(false);
    expect(shouldUseNodeAgent("user_1", {pct: 0, allow: ["user_1"]})).toBe(true);
  });

  it("pct=100 -> always true (full rollout) unless denied", () => {
    expect(shouldUseNodeAgent("anyone", {pct: 100})).toBe(true);
    expect(shouldUseNodeAgent("anyone", {pct: 100, deny: ["anyone"]})).toBe(false);
  });

  it("deterministic: same user+salt+pct -> same answer across calls", () => {
    const opts = {pct: 10, salt: "ai_terminal-node-v1"};
    const answers = new Set<string>();
    for (let i = 0; i < 100; i++) answers.add(String(shouldUseNodeAgent("user_42", opts)));
    expect(answers.size).toBe(1); // stable
  });

  it("distribution: with pct=50, ~half of a large synthetic user set is in-rollout", () => {
    let inRollout = 0;
    const total = 10000;
    for (let i = 0; i < total; i++) {
      if (shouldUseNodeAgent("user_" + i, {pct: 50})) inRollout++;
    }
    // 50% ± 5% tolerance
    expect(inRollout).toBeGreaterThan(total * 0.40);
    expect(inRollout).toBeLessThan(total * 0.60);
  });

  it("distribution: with pct=10, ~10% of a large synthetic user set is in-rollout", () => {
    let inRollout = 0;
    const total = 10000;
    for (let i = 0; i < total; i++) {
      if (shouldUseNodeAgent("user_" + i, {pct: 10})) inRollout++;
    }
    expect(inRollout).toBeGreaterThan(total * 0.05);
    expect(inRollout).toBeLessThan(total * 0.15);
  });

  it("allow-list beats deny-list (allow wins)", () => {
    expect(shouldUseNodeAgent("u1", {pct: 0, allow: ["u1"], deny: ["u1"]})).toBe(true);
  });

  it("force=on overrides everything", () => {
    expect(shouldUseNodeAgent("u", {pct: 0, force: "on"})).toBe(true);
  });

  it("force=off overrides everything (even allow-list)", () => {
    expect(shouldUseNodeAgent("u", {pct: 100, force: "off"})).toBe(false);
  });

  it("rolloutFraction clamps pct", () => {
    expect(rolloutFraction(0)).toBe(0);
    expect(rolloutFraction(100)).toBe(1);
    expect(rolloutFraction(50)).toBe(0.5);
    expect(rolloutFraction(150)).toBe(1); // clamped
    expect(rolloutFraction(-10)).toBe(0); // clamped
  });
});
