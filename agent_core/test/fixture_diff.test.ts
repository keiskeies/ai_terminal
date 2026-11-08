import {describe, it, expect} from "vitest";
import {readFileSync} from "fs";
import {fnv1a64DartCompat} from "../src/utils/stable_hash.js";

const fixture = readFileSync("test/fixtures/stable_id_1000.jsonl", "utf-8")
  .split("\n")
  .filter(Boolean);

describe("stableId 1000-case fixture (Dart byte-compat)", () => {
  it("all 1000 hashes match the Dart reference", () => {
    let pass = 0, fail = 0;
    for (const line of fixture) {
      const evtIdx = line.lastIndexOf(" evt_");
      const input = JSON.parse(line.slice(0, evtIdx).trim());
      const expected = line.slice(evtIdx + 1).trim();
      const got = "evt_" + fnv1a64DartCompat(input).toString(16);
      if (got === expected) pass++; else fail++;
    }
    expect(fail).toBe(0);
    expect(pass).toBe(1000);
  });
});