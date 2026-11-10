// Guard for docs/agent-core-migration-design.md - the 6.2 regression manifest.
//
// 6.2 names the nine regression files that pin one AGENTS.md rule each, and 6.3
// tracks each one's status. That pairing drifted for real: four rules were already
// covered under other filenames while 6.2/6.3 still advertised them as missing, so
// the doc overstated the gap and hid which file owns which contract - a reader
// cannot tell a TODO from a rename.
//
// So parse the 6.2 list out of the design doc and assert each named file exists
// next to this test, and that 6.3 does not call an existing file pending. Both
// directions are cheap and both broke during this migration.
//
// Deliberately NOT one of the nine: this guards the manifest, it pins no AGENTS.md
// rule. The rule -> file map lives in the 6.3 table.

import {describe, it, expect} from "vitest";
import {existsSync, readFileSync, readdirSync} from "node:fs";
import {fileURLToPath} from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url)); // agent_core/test/regression/
const DOC = fileURLToPath(new URL("../../../docs/agent-core-migration-design.md", import.meta.url));

// CJK by codepoint (project convention: no raw CJK in test sources).
const PENDING = "\u5f85\u8865"; // "to be filled" - the owed marker
const DONE = "\u5df2\u843d\u5730"; // "landed"

/** Filename entries inside the 6.2 fenced list, in document order. */
function declaredManifest(doc: string): string[] {
  const lines = doc.split(/\r?\n/);
  const h = lines.findIndex((l) => /^### 6\.2\b/.test(l));
  expect(h, "the 6.2 heading vanished from the design doc").toBeGreaterThan(-1);
  const names: string[] = [];
  for (let i = h + 1; i < lines.length; i++) {
    const l = lines[i];
    // the bold CI paragraph and any following heading end the list
    if (/^#{2,4} /.test(l) || l.trim().startsWith("**")) break;
    const m = /^\s*([a-z0-9_]+\.test\.ts)/.exec(l); // fence/parent dirs never match
    if (m) names.push(m[1]);
  }
  return names;
}

/** Rows of the 6.3 status table, up to the first 6.3.x subsection. */
function statusRows(doc: string): string[][] {
  const lines = doc.split(/\r?\n/);
  const h = lines.findIndex((l) => /^### 6\.3\b/.test(l));
  expect(h, "the 6.3 heading vanished from the design doc").toBeGreaterThan(-1);
  const rows: string[][] = [];
  for (let i = h; i < lines.length; i++) {
    if (i > h && /^#{2,4} /.test(lines[i])) break;
    const l = lines[i];
    if (l.trim().startsWith("|") && l.includes(".test.ts")) rows.push(l.split("|").map((c) => c.trim()));
  }
  return rows;
}

describe("docs 6.2 regression manifest", () => {
  const doc = readFileSync(DOC, "utf-8");
  const declared = declaredManifest(doc);

  it("still lists exactly the nine rule files, one per AGENTS.md rule", () => {
    // The set IS the contract: 6.2 exists to map one file per rule. Renaming or
    // splitting a rule file means updating 6.2 and this list together.
    expect(declared).toEqual([
      "r1_generation_check.test.ts",
      "r1_stream_cancel.test.ts",
      "r1_then_onerror.test.ts",
      "r2_lifecycle.test.ts",
      "r3_multi_host.test.ts",
      "r4_stable_id.test.ts",
      "r5_terminal_whitelist.test.ts",
      "r6_shell_fork.test.ts",
      "r9_stream_e2e.test.ts",
    ]);
  });

  for (const name of declared) {
    it("declared file " + name + " is on disk", () => {
      expect(existsSync(HERE + name), name + " is listed in 6.2 but does not exist").toBe(true);
    });
  }

  it("6.3 calls no existing file pending", () => {
    const stale = statusRows(doc)
      .filter((cells) => cells.includes(PENDING))
      .map((cells) => /([a-z0-9_]+\.test\.ts)/.exec(cells.join("|"))?.[1])
      .filter((n): n is string => !!n)
      .filter((n) => existsSync(HERE + n));
    expect(stale, "landed but still marked pending: " + stale.join(", ")).toEqual([]);
  });

  it("every 6.3 row carries exactly one known status", () => {
    // A third status word would silently mean "nobody knows", defeating the point
    // of the table: a row is either done or openly still owed.
    const rows = statusRows(doc);
    expect(rows.length).toBe(9);
    for (const cells of rows) {
      const known = cells.filter((c) => c === DONE || c === PENDING);
      expect(known.length, "status column unreadable in: " + cells[1]).toBe(1);
    }
  });

  it("no rule-shaped test file hides outside the manifest", () => {
    // An r<N>_*.test.ts that 6.2 omits reads like an unassigned rule: either list
    // it or name it something clearly extra (anthropic_e2e / w5_e2e are extras).
    const ruleShaped = readdirSync(HERE).filter((f) => /^r[0-9]_.*\.test\.ts$/.test(f));
    expect(ruleShaped.slice().sort()).toEqual(declared.slice().sort());
  });
});
