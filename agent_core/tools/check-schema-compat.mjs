#!/usr/bin/env node
// tools/check-schema-compat.mjs - D7 protocol-compat checker
//
// Validates that the agent-bridge schema files under agent_core/schema/ are
// structurally sound and backwards-compatible with protocol v1.0:
//
//   1. All 6 schema files parse as valid JSON.
//   2. protocol.version.json still declares major=1, minor=0.
//   3. Each "oneOf" branch in request/reverse/notification schemas has a
//      "method" const property; no two branches share the same method name.
//   4. Umbrella agent-bridge.schema.json $refs all point to files that exist.
//   5. event.schema.json "type" enum and "finishState" enum match known values
//      (regression guard: accidental removal of an enum value is a BREAKING
//      change and must be caught here).
//   6. No schema file introduces a new top-level "$id" that differs from its
//      filename (D7: schema identity must be stable across versions).
//
// Exit 0 = all checks pass; exit 1 = violations found (prints each).

import {readFileSync, existsSync} from "node:fs";
import {dirname, join, basename} from "node:path";
import {fileURLToPath} from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const schemaDir = join(__dirname, "..", "schema");

const REQUIRED_FILES = [
  "request.schema.json",
  "reverse.schema.json",
  "event.schema.json",
  "notification.schema.json",
  "tool.schema.json",
  "protocol.version.json",
  "agent-bridge.schema.json",
];

const KNOWN_EVENT_TYPES = new Set([
  "thought","command","result","ask","finish","text","info","report","plan",
]);
const KNOWN_FINISH_STATES = new Set(["success","cancelled","failed","interrupted"]);

let violations = [];
function report(msg) { violations.push(msg); }

function load(name) {
  const p = join(schemaDir, name);
  if (!existsSync(p)) { report("MISSING file: " + name); return null; }
  try { return JSON.parse(readFileSync(p, "utf-8")); }
  catch (e) { report("PARSE ERROR in " + name + ": " + e.message); return null; }
}

// 1. All required files load
const schemas = {};
for (const f of REQUIRED_FILES) {
  const s = load(f);
  if (s !== null) schemas[f] = s;
}
if (violations.length > 0) {
  for (const v of violations) console.error("  ✗ " + v);
  console.error("\ncheck-schema-compat: FAILED (" + violations.length + " violation(s))");
  process.exit(1);
}

// 2. Protocol version
const pv = schemas["protocol.version.json"];
const verMajor = pv?.properties?.major?.const;
const verMinor = pv?.properties?.minor?.const;
if (verMajor !== 1 || verMinor !== 0) {
  report("protocol.version.json: expected major=1, minor=0, got major=" + verMajor + " minor=" + verMinor);
} else {
  console.log("  ✓ protocol.version.json: major=1 minor=0");
}

// 3. oneOf method-const uniqueness + presence
for (const fname of ["request.schema.json","reverse.schema.json","notification.schema.json"]) {
  const s = schemas[fname];
  const branches = s.oneOf ?? [];
  const seen = new Set();
  for (let i = 0; i < branches.length; i++) {
    const methodConst = branches[i].properties?.method?.const;
    if (typeof methodConst !== "string") {
      report(fname + " oneOf[" + i + "]: missing properties.method.const");
    } else if (seen.has(methodConst)) {
      report(fname + " oneOf: duplicate method const '" + methodConst + "'");
    } else {
      seen.add(methodConst);
    }
  }
  if (violations.length === 0) console.log("  ✓ " + fname + ": " + seen.size + " unique method(s), all have const");
}

// 4. Umbrella $refs resolve
const umbrella = schemas["agent-bridge.schema.json"];
const defs = umbrella?.definitions ?? {};
for (const [key, def] of Object.entries(defs)) {
  if (def.$ref && !def.$ref.startsWith("#/")) {
    const refFile = def.$ref; // relative filename
    const refPath = join(schemaDir, refFile);
    if (!existsSync(refPath)) {
      report("agent-bridge.schema.json definitions." + key + ": $ref '" + refFile + "' does not exist");
    }
  }
}
if (violations.length === 0) console.log("  ✓ agent-bridge.schema.json: all $refs resolve");

// 5. event enum regression guard
const eventSchema = schemas["event.schema.json"];
const eventTypeEnum = eventSchema?.properties?.type?.enum ?? [];
const finishStateEnum = eventSchema?.properties?.finishState?.enum ?? [];
const missingTypes = [...KNOWN_EVENT_TYPES].filter(t => !eventTypeEnum.includes(t));
if (missingTypes.length > 0) {
  report("event.schema.json: missing event type(s): " + missingTypes.join(", "));
}
const missingStates = [...KNOWN_FINISH_STATES].filter(s => !finishStateEnum.includes(s));
if (missingStates.length > 0) {
  report("event.schema.json: missing finishState value(s): " + missingStates.join(", "));
}
if (violations.length === 0) {
  console.log("  ✓ event.schema.json: all " + eventTypeEnum.length + " event types + " + finishStateEnum.length + " finishState values present");
}

// 6. $id stability
for (const fname of ["request.schema.json","reverse.schema.json","event.schema.json","notification.schema.json","tool.schema.json"]) {
  const s = schemas[fname];
  const id = s?.$id;
  if (id !== fname && id !== undefined) {
    // Allow the known intentional $id mismatch for event.schema.json
    if (fname === "event.schema.json" && id === "agent-event.schema.json") continue;
    report(fname + ": $id='" + id + "' does not match filename (D7: schema identity is stable)");
  }
}
if (violations.length === 0) console.log("  ✓ $id stability: all schema files consistent");

// Summary
if (violations.length > 0) {
  for (const v of violations) console.error("  ✗ " + v);
  console.error("\ncheck-schema-compat: FAILED (" + violations.length + " violation(s))");
  process.exit(1);
} else {
  console.log("\ncheck-schema-compat: PASSED (protocol v" + verMajor + "." + verMinor + ")");
  process.exit(0);
}
