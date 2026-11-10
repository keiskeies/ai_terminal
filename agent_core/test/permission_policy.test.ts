// Gate-matrix parity: agent_core/src/utils/permission_policy.ts vs
// ai_terminal/lib/core/permission_policy.dart.
//
// protocol_enum_parity.test.ts pins the three VALUE SETS (SafetyLevel,
// permissionDecision, permissionMode) across Dart, the frozen schema and TypeScript.
// It cannot pin the MATRIX: which pair of (level, mode) yields which decision. A
// transposed condition is invisible to value-set parity because every value still
// shows up somewhere - the engine would simply confirm the wrong cells.
//
// CI has no Dart runtime, so the matrix is pinned twice over:
//   1. all 16 cells against a table transcribed from the Dart function,
//   2. the Dart function itself scanned structurally (guard order, and which
//      decision each branch may return), so a Dart-side edit invalidates the table
//      loudly instead of leaving it silently stale.
//
// The scanners below are string-based rather than regex-based on purpose: they stay
// honest about which characters they depend on, and the enum reader keeps the two
// lessons from protocol_enum_parity.test.ts - strip line comments before splitting
// on commas, and refuse anything that is not identifier-shaped.
import {readFileSync} from "node:fs";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {describe, it, expect} from "vitest";
import {
  decideCommand,
  destructiveToolNeedsConfirm,
  SAFETY_LEVELS,
  GATE_DECISIONS,
  PERMISSION_DECISION_EXECUTE,
  PERMISSION_DECISION_CONFIRM,
  PERMISSION_DECISION_REJECT,
} from "../src/utils/permission_policy.js";
import type {SafetyLevel, CommandGateDecision} from "../src/utils/permission_policy.js";
import type {PermissionMode} from "../src/rpc/schema.js";

const HERE = dirname(fileURLToPath(new URL(import.meta.url)));
const AC = join(HERE, "..");
const DART = join(AC, "..", "ai_terminal", "lib");
const LF = String.fromCharCode(10);
const SQ = String.fromCharCode(39);
const dartText = (rel: string) => readFileSync(resolve(DART, rel), "utf-8");
const schemaJson = (name: string) => JSON.parse(readFileSync(join(AC, "schema", name), "utf-8"));

function isIdentifier(v: string): boolean {
  if (v.length === 0) return false;
  const head = v.charCodeAt(0);
  const okHead = (head >= 65 && head <= 90) || (head >= 97 && head <= 122) || head === 95;
  if (!okHead) return false;
  for (let i = 1; i < v.length; i++) {
    const c = v.charCodeAt(i);
    const ok = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c === 95;
    if (!ok) return false;
  }
  return true;
}

function stripLineComments(text: string): string {
  return text
    .split(LF)
    .map((row) => {
      const cc = row.indexOf("//");
      return cc >= 0 ? row.slice(0, cc) : row;
    })
    .join(LF);
}

// Dart enum member names, in declaration order. The SafetyLevel declarations carry
// Chinese risk labels behind a line comment, and those labels contain commas, so
// comments must go first or one member reads as several values. A non-identifier
// survivor is an error: a lenient filter would silently shorten the list and let the
// comparison agree against too little.
function dartEnumValues(file: string, name: string): string[] {
  const srcText = dartText(file);
  const head = "enum " + name + " {";
  const at = srcText.indexOf(head);
  if (at < 0) throw new Error("Dart enum not found: " + name + " in " + file);
  const close = srcText.indexOf("}", at);
  if (close < 0) throw new Error("unterminated Dart enum: " + name + " in " + file);
  const values: string[] = [];
  for (const row of stripLineComments(srcText.slice(at + head.length, close)).split(LF)) {
    for (const part of row.split(",")) {
      const v = part.trim();
      if (v.length === 0) continue;
      if (!isIdentifier(v)) throw new Error("unparsable Dart enum member in " + file + ": " + v);
      values.push(v);
    }
  }
  if (values.length === 0) throw new Error("no members parsed for " + name + " in " + file);
  return values;
}

// Body of Dart decideCommand(), braces balanced by counting.
function dartGateBody(): string {
  const srcText = dartText("core/permission_policy.dart");
  const at = srcText.indexOf("CommandGateDecision decideCommand(");
  if (at < 0) throw new Error("decideCommand() not found in permission_policy.dart");
  const open = srcText.indexOf("{", at);
  let depth = 0;
  let end = -1;
  for (let i = open; i < srcText.length; i++) {
    if (srcText.charAt(i) === "{") depth++;
    else if (srcText.charAt(i) === "}") {
      depth--;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }
  if (end < 0) throw new Error("unbalanced braces reading decideCommand()");
  return stripLineComments(srcText.slice(open + 1, end));
}

const MODES: PermissionMode[] = ["readOnly", "ask", "auto", "fullAuto"];
const LEVELS: SafetyLevel[] = ["safe", "info", "warn", "blocked"];

// Expected matrix, transcribed cell by cell from decideCommand():
//   readOnly -> only safe executes, everything else is REJECTED, not confirmed;
//   blocked  -> confirms unless fullAuto;
//   warn     -> confirms only under ask;
//   everything else executes.
const EXPECTED: Record<PermissionMode, Record<SafetyLevel, CommandGateDecision>> = {
  readOnly: {safe: "execute", info: "reject", warn: "reject", blocked: "reject"},
  ask: {safe: "execute", info: "execute", warn: "confirm", blocked: "confirm"},
  auto: {safe: "execute", info: "execute", warn: "execute", blocked: "confirm"},
  fullAuto: {safe: "execute", info: "execute", warn: "execute", blocked: "execute"},
};

describe("permission policy matrix matches Dart decideCommand", () => {
  it("all 16 cells agree with the transcribed Dart matrix", () => {
    let seen = 0;
    for (const mode of MODES) {
      for (const level of LEVELS) {
        seen++;
        expect(decideCommand(level, mode), mode + " / " + level).toBe(EXPECTED[mode][level]);
      }
    }
    expect(seen).toBe(16);
  });

  it("readOnly hard-refuses unsafe commands instead of asking", () => {
    // The most consequential cell. A read-only session must never emit a
    // confirmation prompt: handing the user a button for it is an invitation to
    // escalate a mode that is supposed to be incapable of writing.
    for (const level of ["info", "warn", "blocked"] as SafetyLevel[]) {
      expect(decideCommand(level, "readOnly"), level).toBe("reject");
    }
    expect(decideCommand("safe", "readOnly")).toBe("execute");
  });

  it("only fullAuto runs a blocked command without asking", () => {
    expect(MODES.filter((m) => decideCommand("blocked", m) === "confirm")).toEqual(["ask", "auto"]);
    expect(decideCommand("blocked", "readOnly")).toBe("reject");
    expect(decideCommand("blocked", "fullAuto")).toBe("execute");
  });

  it("warn confirms only under ask", () => {
    expect(MODES.filter((m) => decideCommand("warn", m) === "confirm")).toEqual(["ask"]);
  });

  it("safe and info never confirm", () => {
    for (const level of ["safe", "info"] as SafetyLevel[]) {
      for (const mode of MODES) {
        expect(decideCommand(level, mode), mode + " / " + level).not.toBe("confirm");
      }
    }
  });

  it("every cell yields one of the three Dart gate decisions", () => {
    for (const mode of MODES) {
      for (const level of LEVELS) {
        expect(GATE_DECISIONS as readonly string[]).toContain(decideCommand(level, mode));
      }
    }
  });
});

describe("permission policy value sets match Dart and the frozen schema", () => {
  it("SafetyLevel tuple equals Dart declaration order, not just membership", () => {
    expect(SAFETY_LEVELS as readonly string[]).toEqual(dartEnumValues("core/safety_guard.dart", "SafetyLevel"));
  });

  it("schema riskLevel enum equals the SafetyLevel tuple", () => {
    expect(schemaJson("event.schema.json").properties.riskLevel.enum).toEqual([...SAFETY_LEVELS]);
  });

  it("schema permissionDecision enum equals the Dart kPermissionDecision constants", () => {
    const srcText = dartText("core/permission_policy.dart");
    const marker = "const String kPermissionDecision";
    const consts: string[] = [];
    let from = 0;
    for (;;) {
      const at = srcText.indexOf(marker, from);
      if (at < 0) break;
      const q1 = srcText.indexOf(SQ, at);
      const q2 = srcText.indexOf(SQ, q1 + 1);
      consts.push(srcText.slice(q1 + 1, q2));
      from = q2;
    }
    expect(consts.length).toBe(3);
    expect(schemaJson("event.schema.json").properties.permissionDecision.enum).toEqual(consts);
    expect([
      PERMISSION_DECISION_EXECUTE,
      PERMISSION_DECISION_CONFIRM,
      PERMISSION_DECISION_REJECT,
    ]).toEqual(consts);
    expect(GATE_DECISIONS as readonly string[]).toEqual(
      dartEnumValues("core/permission_policy.dart", "CommandGateDecision"),
    );
  });

  it("the module only speaks schema-approved permission modes", () => {
    const rs = schemaJson("request.schema.json");
    const branch = rs.oneOf.find((b: any) => b?.properties?.method?.const === "rpc:startTask");
    expect(branch.properties.params.properties.permissionMode.enum).toEqual(MODES);
  });
});

describe("Dart decideCommand still has the shape this table was read from", () => {
  const body = dartGateBody();

  it("guards fire in the order readOnly, blocked, warn", () => {
    const readOnly = body.indexOf("AgentPermissionMode.readOnly");
    const blocked = body.indexOf("SafetyLevel.blocked");
    const warn = body.indexOf("SafetyLevel.warn");
    expect(readOnly).toBeGreaterThan(-1);
    expect(blocked).toBeGreaterThan(readOnly);
    expect(warn).toBeGreaterThan(blocked);
  });

  it("the readOnly branch may reject but must never confirm", () => {
    const start = body.indexOf("AgentPermissionMode.readOnly");
    const end = body.indexOf("}", start);
    expect(end).toBeGreaterThan(start);
    const seg = body.slice(start, end);
    expect(seg).toContain("CommandGateDecision.reject");
    expect(seg).not.toContain("CommandGateDecision.confirm");
  });

  it("blocked keys off fullAuto and warn keys off ask", () => {
    const bStart = body.indexOf("SafetyLevel.blocked");
    const bSeg = body.slice(bStart, body.indexOf("}", bStart));
    expect(bSeg).toContain("AgentPermissionMode.fullAuto");
    expect(bSeg).toContain("CommandGateDecision.confirm");
    const wStart = body.indexOf("SafetyLevel.warn");
    const wSeg = body.slice(wStart, body.indexOf("}", wStart));
    expect(wSeg).toContain("AgentPermissionMode.ask");
    expect(wSeg).toContain("CommandGateDecision.confirm");
  });

  it("fallthrough executes and destructiveToolNeedsConfirm is still not-fullAuto", () => {
    expect(body.trim().endsWith("return CommandGateDecision.execute;")).toBe(true);
    const srcText = dartText("core/permission_policy.dart");
    const at = srcText.indexOf("bool destructiveToolNeedsConfirm(");
    expect(at).toBeGreaterThan(-1);
    expect(srcText.slice(at, at + 160)).toContain("mode != AgentPermissionMode.fullAuto;");
  });
});

describe("destructiveToolNeedsConfirm", () => {
  it("only fullAuto skips confirmation", () => {
    expect(destructiveToolNeedsConfirm("fullAuto")).toBe(false);
    const others = MODES.filter((m) => m !== "fullAuto");
    expect(others.length).toBe(3);
    for (const mode of others) {
      expect(destructiveToolNeedsConfirm(mode), mode).toBe(true);
    }
  });
});

