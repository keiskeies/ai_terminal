// Cross-language protocol enum parity.
//
// The wire contract has three independent spellings of the SAME value sets:
//   1. the Dart engine (ai_terminal/lib/...) - the producer on the Flutter side
//   2. agent_core/schema/*.json - the frozen JSON-Schema contract (D7)
//   3. agent_core/src/rpc/schema.ts - the TypeScript contract both sides compile
// Nothing in the repo compared them. D7's check-schema-compat.mjs only checks
// enum STRUCTURE and that a hardcoded list of names stays present, so an enum
// whose values were never the other language's values passed green forever.
//
// That was not hypothetical: permissionMode was frozen as
//   "safe" | "standard" | "dangerous" | "yolo"
// while Dart's actual wire ids are AgentPermissionMode.id =
// readOnly | ask | auto | fullAuto. Those are different id spaces with no
// mapping anywhere in the repo, so the first real startTask that carried a
// permission mode would have been rejected by our own schema while every
// compile-time and schema check kept passing. It is realigned to Dart in this
// commit and pinned below.
//
// Order is asserted, not just set membership, because Dart serialises these
// enums by name but stores AgentEvent through Hive adapters generated in
// declaration order: reordering an enum silently renumbers persisted values.
import {readFileSync, readdirSync, statSync, writeFileSync, rmSync} from "node:fs";
import {dirname, join, relative, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {tmpdir} from "node:os";
import {describe, it, expect} from "vitest";

const HERE = dirname(fileURLToPath(new URL(import.meta.url)));
const AC = join(HERE, "..");
const REPO = join(AC, "..");
const DART = join(REPO, "ai_terminal", "lib");

const read = (p: string) => readFileSync(p, "utf-8");
const schema = (name: string) => JSON.parse(read(join(AC, "schema", name)));

// Dart: enum Name { a, b } -> declared value names, in declaration order.
// Line comments are stripped BEFORE splitting on commas: they carry Chinese risk
// labels whose punctuation contains commas and spaces, so without stripping them
// one member would read as several values. Every surviving token must then be
// identifier-shaped, or we fail loudly - a lenient filter would silently shrink
// the list and turn this parity test into a guard that compares nothing.
function dartEnum(file: string, name: string): string[] {
  const srcText = read(resolve(DART, file));
  const m = new RegExp("enum\\s+" + name + "\\s*\\{([\\s\\S]*?)\\}").exec(srcText);
  if (!m) throw new Error("Dart enum not found: " + name + " in " + file);
  // Line comments first: they hold the Chinese risk labels, then split on commas.
  const body = m[1].replace(/\/\/[^\n]*/g, "");
  const values = body
    .split(",")
    .map((t) => t.trim())
    .filter((t) => t.length > 0);
  for (const v of values) {
    if (!/^[A-Za-z_]\w*$/.test(v)) {
      throw new Error("unparsable Dart enum member in " + file + ":" + name + " -> " + JSON.stringify(v));
    }
  }
  return values;
}

// Dart: extension ... { String get id { switch (this) { case X.a: return "a";
// ... } } } - the ids actually put on the wire.
function dartIdStrings(file: string): string[] {
  const srcText = read(resolve(DART, file));
  return [...srcText.matchAll(/return\s+'([^']+)';/g)].map((m) => m[1]);
}

function dartConstStrings(file: string, prefix: string): string[] {
  const srcText = read(resolve(DART, file));
  const re = new RegExp("const\\s+String\\s+" + prefix + "\\w*\\s*=\\s*'([^']+)';", "g");
  return [...srcText.matchAll(re)].map((m) => m[1]);
}

// TypeScript: export type X = "a" | "b";  (also handles a multi-line union)
function tsUnion(name: string): string[] {
  const srcText = read(join(AC, "src", "rpc", "schema.ts"));
  const one = new RegExp("export\\s+type\\s+" + name + "\\s*=\\s*([^;]+);").exec(srcText);
  if (!one) throw new Error("TS union not found: " + name);
  return [...one[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}

// Every comparison below goes through this helper. A lenient deep-equal would pass
// on two empty arrays, which is exactly how a silently broken extractor looks like
// a passing test, so non-empty is asserted rather than assumed.
function expectSameValues(got: string[], want: string[], label: string) {
  expect(got.length, label + ": contract side empty").toBeGreaterThan(0);
  expect(want.length, label + ": counterpart side empty").toBeGreaterThan(0);
  expect(got, label).toEqual(want);
}

const eventSchema = schema("event.schema.json");
const requestSchema = schema("request.schema.json");
const startTaskBranch = requestSchema.oneOf.find((b: any) => b?.properties?.method?.const === "rpc:startTask");

function enumIn(obj: unknown, key: string): string[] {
  const stack: unknown[] = [obj];
  while (stack.length > 0) {
    const cur = stack.pop() as Record<string, unknown> | undefined;
    if (!cur || typeof cur !== "object") continue;
    for (const [k, v] of Object.entries(cur)) {
      if (k === key && v && typeof v === "object" && Array.isArray((v as any).enum)) return (v as any).enum as string[];
      stack.push(v);
    }
  }
  throw new Error("no enum named " + key + " in schema");
}

const SCHEMA_EVENT_TYPE = eventSchema.properties.type.enum as string[];
const SCHEMA_FINISH_STATE = eventSchema.properties.finishState.enum as string[];
const SCHEMA_RISK_LEVEL = eventSchema.properties.riskLevel.enum as string[];
const SCHEMA_PERM_DECISION = eventSchema.properties.permissionDecision.enum as string[];
const SCHEMA_PERM_MODE = startTaskBranch.properties.params.properties.permissionMode.enum as string[];

describe("protocol enum parity (schema vs Dart vs TypeScript)", () => {
  it("schema event type enum matches Dart AgentEventType exactly", () => {
    expectSameValues(SCHEMA_EVENT_TYPE, dartEnum("models/agent_event.dart", "AgentEventType"), "AgentEventType");
  });

  it("schema finishState enum matches Dart AgentFinishState exactly", () => {
    expectSameValues(SCHEMA_FINISH_STATE, dartEnum("models/agent_event.dart", "AgentFinishState"), "AgentFinishState");
  });

  it("schema riskLevel enum matches Dart SafetyLevel exactly", () => {
    expectSameValues(SCHEMA_RISK_LEVEL, dartEnum("core/safety_guard.dart", "SafetyLevel"), "SafetyLevel");
  });

  it("schema permissionDecision enum matches Dart's stable kPermissionDecision constants", () => {
    // Dart deliberately does NOT send the bare enum name here - permission_policy.dart
    // defines string constants "for events that are persisted and replayed in
    // history, so they cannot be renamed with the enum". Pin the constants.
    expectSameValues(SCHEMA_PERM_DECISION, dartConstStrings("core/permission_policy.dart", "kPermissionDecision"), "permissionDecision");
  });

  it("schema permissionMode enum matches Dart AgentPermissionMode.id exactly", () => {
    expectSameValues(SCHEMA_PERM_MODE, dartIdStrings("models/agent_permission_mode.dart"), "permissionMode");
  });

  it("TypeScript contract repeats the same value sets as the schema", () => {
    expectSameValues(tsUnion("AgentEventType"), SCHEMA_EVENT_TYPE, "TS AgentEventType");
    expectSameValues(tsUnion("AgentFinishState"), SCHEMA_FINISH_STATE, "TS AgentFinishState");
    expectSameValues(tsUnion("PermissionMode"), SCHEMA_PERM_MODE, "TS PermissionMode");
    const agentEvent = read(join(AC, "src", "rpc", "schema.ts"));
    const risk = /riskLevel\?:([^;]+);/.exec(agentEvent);
    const decision = /permissionDecision\?:([^;]+);/.exec(agentEvent);
    if (!risk || !decision) throw new Error("riskLevel/permissionDecision fields missing from AgentEvent");
    expectSameValues([...risk[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]), SCHEMA_RISK_LEVEL, "TS riskLevel");
    expectSameValues([...decision[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]), SCHEMA_PERM_DECISION, "TS permissionDecision");
  });

  it("real serialized events only use values the schema allows", () => {
    // Third source of truth: fixtures captured from the ported pipeline.
    const files: string[] = [];
    const walkDir = (dir: string) => {
      for (const entry of readdirSync(dir)) {
        const fp = join(dir, entry);
        if (statSync(fp).isDirectory()) walkDir(fp);
        else if (entry.endsWith(".json")) files.push(fp);
      }
    };
    walkDir(join(HERE, "e2e", "fixtures"));
    expect(files.length).toBeGreaterThan(0);
    let seenTypes = 0;
    for (const f of files) {
      const collected: string[] = [];
      const stack: unknown[] = [JSON.parse(read(f))];
      while (stack.length > 0) {
        const cur = stack.pop() as Record<string, unknown> | undefined;
        if (!cur || typeof cur !== "object") continue;
        for (const [k, v] of Object.entries(cur)) {
          if (k === "type" && typeof v === "string") collected.push(v);
          if (k === "finishState" && typeof v === "string") {
            expect(SCHEMA_FINISH_STATE, relative(AC, f) + " finishState=" + v).toContain(v);
          }
          if (v && typeof v === "object") stack.push(v);
        }
      }
      for (const t of collected) {
        expect(SCHEMA_EVENT_TYPE, relative(AC, f) + " type=" + t).toContain(t);
        seenTypes++;
      }
    }
    expect(seenTypes).toBeGreaterThan(0);
  });

  it("the guard itself is wired to files that exist", () => {

    // Guards against silently comparing against a stale/renamed Dart file.
    for (const f of ["models/agent_event.dart", "core/safety_guard.dart", "core/permission_policy.dart", "models/agent_permission_mode.dart"]) {
      expect(read(join(DART, f)).length, f).toBeGreaterThan(100);
    }
  });

  it("a Dart source that does not parse is reported instead of silently trimmed", () => {
    // The validator branch is never hit by the real files, so it is exercised here:
    // if it degrades, a future Dart-side edit stops being compared rather than being
    // reported. tmpdir() is used because resolve(DART, absolute) === absolute.
    const junk = join(tmpdir(), "ac_enum_junk_" + process.pid + ".dart");
    writeFileSync(
      junk,
      "enum AgentEventType {\n  thought, // a comment, with commas and spaces\n  ?? broken token ??\n}\n",
      "utf-8",
    );
    try {
      expect(() => dartEnum(junk, "AgentEventType")).toThrow(/unparsable Dart enum member/);
      expect(() => dartEnum(junk, "NoSuchEnumType")).toThrow(/Dart enum not found/);
      // A broken enum-name lookup must be an error, never an empty list: an empty
      // list on both sides would make the parity comparisons agree vacuously.
      // And the string-constant extractors must report "nothing matched" as an empty
      // list that the parity helper rejects, not as agreement between two empty lists.
      expect(dartConstStrings(junk, "kPermissionDecision")).toEqual([]);
      expect(dartIdStrings(junk)).toEqual([]);
    } finally {
      rmSync(junk, {force: true});
    }
  });
});
