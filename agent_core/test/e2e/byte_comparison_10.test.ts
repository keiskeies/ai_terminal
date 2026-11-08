// 10-case byte-comparison e2e harness for the Phase-1 ReAct parser port.
//
// CJK case inputs live in ./fixtures/i0..i9.txt (kept OUT of this source so
// the .ts stays pure-ASCII / channel-safe). parse() is the 1:1 port of
// ReActStreamParser; we freeze its full output shape to a golden and assert
// byte-for-byte parity. Two independent guards:
//   1. frozen golden byte-parity (regenerate with WRITE_GOLDEN=1)
//   2. Dart-anchored stableId invariants (locked hex from react_stream_parser.dart)
import {describe, it, expect} from "vitest";
import {readFileSync, writeFileSync, existsSync} from "fs";
import path from "path";
import {fileURLToPath} from "url";
import {parse} from "../../src/react/parser.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const FIX = path.join(here, "fixtures");
const GOLDEN = path.join(here, "fixtures", "golden10.json");

// Stable, serializable fingerprint of one event: keep id/type + meaningful
// content fields, drop volatile `timestamp`. Keys are picked in a fixed order.
function fp(ev: any): any {
  const {id, type} = ev;
  const order = ["text","command","description","options","question","planSteps"] as const;
  const picked: Record<string, unknown> = {};
  for (const k of order) if (ev[k] !== undefined) picked[k] = ev[k];
  return { id, type, ...picked };
}
// The 10 CJK fixtures (files are the source of truth for inputs).
const CASES: {label: string; file: string}[] = [
  {label: "E2E-thought", file: "i0.txt"},
  {label: "E2E-plan", file: "i1.txt"},
  {label: "E2E-16", file: "i2.txt"},
  {label: "E2E-17", file: "i3.txt"},
  {label: "E2E-18", file: "i4.txt"},
  {label: "E2E-options", file: "i5.txt"},
  {label: "E2E-codefence", file: "i6.txt"},
  {label: "E2E-text", file: "i7.txt"},
  {label: "E2E-thought-multiline", file: "i8.txt"},
  {label: "E2E-orphan-desc", file: "i9.txt"},
];

function runAll(): {label: string; events: any[]}[] {
  return CASES.map((c) => {
    const input = readFileSync(path.join(FIX, c.file), "utf-8");
    return {label: c.label, events: parse(input)};
  });
}
describe("ReAct parser 10-case byte-comparison (R9 e2e)", () => {
  it("parse() output is byte-identical to the frozen golden", () => {
    const docs = runAll();
    const doc = JSON.stringify(docs.map((d) => ({label: d.label, events: d.events.map(fp)})), null, 2) + "\n";
    if (process.env.WRITE_GOLDEN === "1") {
      writeFileSync(GOLDEN, doc, "utf-8");
      return; // regeneration pass
    }
    if (!existsSync(GOLDEN)) {
      writeFileSync(GOLDEN, doc, "utf-8");
      throw new Error("golden10.json was missing; generated now. Re-run to verify parity.");
    }
    const golden = readFileSync(GOLDEN, "utf-8");
    expect(doc).toBe(golden);
  });

  it("emits a stable, non-empty event sequence for every case", () => {
    const docs = runAll();
    for (const d of docs) {
      expect(d.events.length, d.label).toBeGreaterThan(0);
      for (const e of d.events) {
        expect(typeof e.id, d.label).toBe("string");
        expect(e.id.startsWith("evt_"), d.label).toBe(true);
        expect(typeof e.type, d.label).toBe("string");
      }
    }
  });
});

// Dart-anchored stableId invariants: these hex values are the locked
// fnv1a64DartCompat outputs from react_stream_parser.dart. If the TS hash
// drifts, these fail independently of the (TS-generated) golden.
describe("Dart-anchored stableId invariants", () => {
  it("thought case: i0 -> locked hex", () => {
    const ev = parse(readFileSync(path.join(FIX, "i0.txt"), "utf-8"));
    const t = ev.find((e) => e.type === "thought");
    expect(t && t.id).toBe("evt_4ab5285dc89fef7b");
  });
  it("text case: i7 -> locked hex", () => {
    const ev = parse(readFileSync(path.join(FIX, "i7.txt"), "utf-8"));
    const t = ev.find((e) => e.type === "text");
    expect(t && t.id).toBe("evt_e3d57f8a36595f0");
  });
  it("codefence command case: i6 -> locked hex", () => {
    const ev = parse(readFileSync(path.join(FIX, "i6.txt"), "utf-8"));
    const c = ev.find((e) => e.type === "command");
    expect(c && c.id).toBe("evt_1a983973eaa2b606");
  });
});
