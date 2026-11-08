import {describe, it, expect} from "vitest";
import {fnv1a64DartCompat, stableId} from "../src/utils/stable_hash.js";

describe("stable_hash", () => {
  it("empty input returns FNV init", () => {
    expect(fnv1a64DartCompat("").toString(16)).toBe("cbf29ce484222325");
  });

  it("stableId prefixes evt_", () => {
    expect(stableId("thought", "").startsWith("evt_")).toBe(true);
  });

  it("deterministic for same input", () => {
    const a = stableId("command", "ls -la");
    const b = stableId("command", "ls -la");
    expect(a).toBe(b);
  });

  it("differs for different content", () => {
    expect(stableId("command", "ls")).not.toBe(stableId("command", "cd"));
  });
});