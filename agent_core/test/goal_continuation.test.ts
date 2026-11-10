/**
 * Drift guard + behaviour tests for the goal-continuation port
 * (utils/goal_continuation.ts + utils/agent_goal.ts).
 *
 * The Dart oracle ai_terminal/test/goal_continuation_test.dart is never
 * executed here - there is no Dart SDK on this machine. It is READ, parsed into
 * 73 assertions and replayed against the TypeScript implementation, so the
 * expectations come from the Dart source itself rather than from my retypings.
 *
 * Below the replay sit structural drift guards (branch order, decision notes,
 * guard conditions, prompt text, strip class) that compare the two sources
 * token by token, and finally a handful of TypeScript-side checks that pin
 * things the Dart test could not pin - most notably the real maxRounds clamp,
 * because Dart's own assertion for it reads a static const through an instance
 * and is therefore a tautology (see the note in the interpreter).
 */

import {describe, expect, it} from "vitest";
import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {fileURLToPath} from "node:url";

import {AgentGoal} from "../src/utils/agent_goal.js";
import * as goal from "../src/utils/goal_continuation.js";
import * as utilsBarrel from "../src/utils/index.js";
import * as rootBarrel from "../src/index.js";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const DART_MODULE = HERE + "../../ai_terminal/lib/utils/goal_continuation.dart";
const DART_MODEL = HERE + "../../ai_terminal/lib/models/agent_goal.dart";
const DART_ORACLE = HERE + "../../ai_terminal/test/goal_continuation_test.dart";
const TS_MODULE = HERE + "../src/utils/goal_continuation.ts";
const TS_MODEL = HERE + "../src/utils/agent_goal.ts";

const NL = String.fromCharCode(10);
const DLR = String.fromCharCode(36);

function readText(path: string): string {
  return readFileSync(path, "utf-8").replace(/\r\n/g, NL);
}

function sha12(text: string): string {
  return createHash("sha1").update(text, "utf-8").digest("hex").slice(0, 12);
}

const DART_MODULE_TEXT = readText(DART_MODULE);
const DART_MODEL_TEXT = readText(DART_MODEL);
const DART_ORACLE_TEXT = readText(DART_ORACLE);
const TS_MODULE_TEXT = readText(TS_MODULE);
const TS_MODEL_TEXT = readText(TS_MODEL);

describe("fingerprints of the four drift-relevant files", () => {
  // If any of these change, the parsing below may stop seeing what it thinks it
  // sees. A red fingerprint is a prompt to re-read the Dart side, not to
  // re-pin the hash blindly.
  const pins: Array<[string, string, string]> = [
    ["dart goal_continuation.dart", sha12(DART_MODULE_TEXT), "ddac1bfce83c"],
    ["dart agent_goal.dart", sha12(DART_MODEL_TEXT), "fa87c4cfed91"],
    ["dart oracle test", sha12(DART_ORACLE_TEXT), "35382d3c0203"],
    ["ts goal_continuation.ts", sha12(TS_MODULE_TEXT), "3b9316dce8f6"],
    ["ts agent_goal.ts", sha12(TS_MODEL_TEXT), "f65619dd6571"],
  ];
  for (const [name, actual, want] of pins) {
    it(name + " unchanged", () => {
      expect(actual).toBe(want);
    });
  }
});

// ===========================================================================
// Dart oracle parser + interpreter (lifted verbatim from the scratch probe)
// ===========================================================================

/**
 * Parser for the Dart goal-continuation oracle test.
 *
 * There is no Dart SDK on this machine, so the Dart test can never be executed
 * as an oracle - it can only be READ. This turns every test() body in
 * ai_terminal/test/goal_continuation_test.dart into a flat instruction list
 * that the vitest file replays against the TypeScript port, so the expectations
 * are lifted out of the Dart source at run time rather than retyped by hand.
 *
 * Only the shapes that Dart test actually uses are supported; anything else is
 * a hard parse error, never a silent skip, and the test file additionally
 * asserts that the instruction count matches the number of expect() calls in
 * the file.
 */

export type GoalSpec = {
  roundsUsed?: number;
  maxRounds?: number;
  lastRoundCommands?: number;
  noProgressRounds?: number;
  status?: string;
};

export type DecideSpec = {
  goal: GoalSpec;
  finishState: string | null;
  commandsRun: number;
  hadConfirmTimeout: boolean;
  connectionAlive: boolean;
  isForegroundHost: boolean;
  finishSummary: string | null;
};

export type JsonSpec = Record<string, string | number | null>;

export type DecideBind = {kind: 'decide'; spec: DecideSpec};
export type PromptBind = {kind: 'prompt'; goal: GoalSpec};
export type JsonBind = {kind: 'json'; json: JsonSpec};
export type FromJsonBind = {kind: 'fromJson'; json: JsonSpec | null};
export type EditedBind = {kind: 'edited'; goal: GoalSpec; objective: string};
export type SchedSpec = {
  goal: GoalSpec;
  finishingTaskId: string | null;
  alreadyContinuedTaskId: string | null;
  engineRunning: boolean;
};

export type SchedBind = {kind: 'sched'; spec: SchedSpec};
export type KickBind = {kind: 'kick'; spec: {goalActive: boolean; isForegroundHost: boolean; engineRunning: boolean; connectionAlive: boolean}};

export type AnyBind = DecideBind | PromptBind | JsonBind | FromJsonBind | EditedBind | SchedBind | KickBind;

export type Bind = {name: string; bind: AnyBind};

export type ExprSpec =
  | {t: 'str'; v: string}
  | {t: 'marker'; fn: 'goalMarkedDone' | 'isGoalMarkerOnlyCommand'; arg: string}
  | {t: 'kick'; goalActive: boolean; isForegroundHost: boolean; engineRunning: boolean; connectionAlive: boolean}
  | {t: 'sched'; goal: GoalSpec; finishingTaskId: string | null; alreadyContinuedTaskId: string | null; engineRunning: boolean}
  | {t: 'varRef'; name: string}
  | {t: 'decField'; name: string; path: string}
  | {t: 'prompt'; goal: GoalSpec}
  | {t: 'fromJson'; json: JsonSpec | null}
  | {t: 'editedField'; goal: GoalSpec; objective: string; path: string}
  | {t: 'roundsLeft'; goal: GoalSpec}
  | {t: 'unknown'; text: string}
  | {t: 'bindField'; bind: string; path: string}
  | {t: 'bind'; name: string};

export type Matcher =
  | {m: 'bool'; v: boolean}
  | {m: 'null'}
  | {m: 'str'; v: string}
  | {m: 'num'; v: number}
  | {m: 'enum'; ename: string; v: string}
  | {m: 'maxAllowedRounds'}
  | {m: 'contains'; v: string; fromConst: boolean}
  | {m: 'unknown'; text: string};


/** The kGoalDoneMarker value, read out of the Dart module (not hardcoded). */
export function dartMarkerValue(moduleSrc: string): string {
  const m = /const String kGoalDoneMarker = (['"][^'"]*['"]);/.exec(moduleSrc);
  if (m === null) throw new Error('kGoalDoneMarker declaration not found');
  return dartStr(m[1] as string);
}

function findTopLevelSemi(src: string, from: number): number {
  let i = from;
  let depth = 0;
  while (i < src.length) {
    const ch = src[i] as string;
    if (ch === "'" || ch === String.fromCharCode(34)) {
      const q = ch;
      i += 1;
      while (i < src.length) {
        const c2 = src[i] as string;
        i += 1;
        if (c2 === String.fromCharCode(92)) {
          i += 1;
          continue;
        }
        if (c2 === q) break;
      }
      continue;
    }
    if (ch === '(' || ch === '[' || ch === '{') depth += 1;
    if (ch === ')' || ch === ']' || ch === '}') depth -= 1;
    if (ch === ';' && depth === 0) return i;
    i += 1;
  }
  throw new Error('no top-level ; after ' + from);
}

function callAt(src: string, name: string, idx: number): [string, number] {
  if (!src.slice(idx, idx + name.length).startsWith(name)) {
    throw new Error('expected ' + name + ' at ' + idx);
  }
  const open = src.indexOf('(', idx + name.length);
  if (open < 0) throw new Error('no open paren for ' + name + ' at ' + idx);
  return callArgs(src, open);
}

function parseFinishState(v: string): string | null {
  if (v === 'null') return null;
  const m = /^AgentFinishState\.(\w+)$/.exec(v);
  if (m === null) throw new Error('bad finishState: ' + v);
  return m[1] as string;
}

export function parseDecideSpec(args: string): DecideSpec {
  const m = named(splitArgs(args));
  const spec: DecideSpec = {
    goal: m.has('g') ? parseGoalSpec(m.get('g') as string) : {},
    finishState: m.has('finishState') ? parseFinishState(m.get('finishState') as string) : 'success',
    commandsRun: m.has('commandsRun') ? asInt(m.get('commandsRun') as string) : 4,
    hadConfirmTimeout: m.has('hadConfirmTimeout') ? asBool(m.get('hadConfirmTimeout') as string) : false,
    connectionAlive: m.has('connectionAlive') ? asBool(m.get('connectionAlive') as string) : true,
    isForegroundHost: m.has('isForegroundHost') ? asBool(m.get('isForegroundHost') as string) : true,
    finishSummary: m.has('finishSummary') ? dartStr(m.get('finishSummary') as string) : null,
  };
  return spec;
}

function parseSched(args: string): ExprSpec {
  const m = named(splitArgs(args));
  return {
    t: 'sched',
    goal: parseGoalSpec(m.get('goal') as string),
    finishingTaskId: m.get('finishingTaskId') === 'null' ? null : dartStr(m.get('finishingTaskId') as string),
    alreadyContinuedTaskId: m.get('alreadyContinuedTaskId') === 'null' ? null : dartStr(m.get('alreadyContinuedTaskId') as string),
    engineRunning: asBool(m.get('engineRunning') as string),
  };
}

function parseKick(args: string): ExprSpec {
  const m = named(splitArgs(args));
  return {
    t: 'kick',
    goalActive: asBool(m.get('goalActive') as string),
    isForegroundHost: asBool(m.get('isForegroundHost') as string),
    engineRunning: asBool(m.get('engineRunning') as string),
    connectionAlive: asBool(m.get('connectionAlive') as string),
  };
}
function parseBindValue(value: string, seen: Bind[]): AnyBind | null {
  if (/^decide\s*\(/.test(value)) return {kind: 'decide', spec: parseDecideSpec(callAt(value, 'decide', 0)[0])};
  if (/^shouldScheduleGoalRound\s*\(/.test(value)) {
    return {kind: 'sched', spec: parseSched(callAt(value, 'shouldScheduleGoalRound', 0)[0]) as SchedSpec};
  }
  if (/^shouldKickGoalRound\s*\(/.test(value)) {
    return {kind: 'kick', spec: parseKick(callAt(value, 'shouldKickGoalRound', 0)[0]) as KickBind['spec']};
  }
  if (/^buildGoalContinuationPrompt\s*\(/.test(value)) {
    const inner = callAt(value, 'buildGoalContinuationPrompt', 0)[0];
    return {kind: 'prompt', goal: parseGoalSpec(inner.trim())};
  }
  if (/^AgentGoal\s*\.\s*fromJson\s*\(/.test(value)) {
    const inner = callAt(value.replace(/!$/, ''), 'AgentGoal.fromJson', 0)[0].trim();
    if (inner === 'null') return {kind: 'fromJson', json: null};
    if (inner.startsWith('{')) return {kind: 'fromJson', json: parseJsonSpec(inner)};
    const ref = seen.find((b) => b.name === inner);
    if (ref !== undefined && ref.bind.kind === 'json') return {kind: 'fromJson', json: ref.bind.json};
    return {kind: 'fromJson', json: parseJsonSpec(inner)};
  }
  const edited = /^goal\s*\(/.test(value) && /\.copyWith\s*\(/.test(value);
  if (edited) {
    const goalTxt = value.slice(0, value.indexOf('.copyWith'));
    const dot = value.indexOf('.copyWith');
    const c = callAt(value.slice(dot + 1), 'copyWith', 0)[0];
    const objective = dartStr(named(splitArgs(c)).get('objective') as string);
    return {kind: 'edited', goal: parseGoalSpec(goalTxt), objective};
  }
  return null;
}

function collectBinds(body: string): Bind[] {
  const out: Bind[] = [];
  const re = /final\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(body)) !== null) {
    const start = (m.index as number) + (m[0] as string).length;
    const end = findTopLevelSemi(body, start);
    const value = body.slice(start, end).trim().replace(/\s*,\s*$/, '');
    const name = m[1] as string;
    if (/^\{/.test(value)) {
      out.push({name, bind: {kind: 'json', json: parseJsonSpec(value)}});
      re.lastIndex = end;
      continue;
    }
    const b = parseBindValue(value, out);
    if (b !== null) out.push({name, bind: b});
    re.lastIndex = end;
  }
  return out;
}

function parseActual(text: string, binds: Bind[], marker: string): ExprSpec {
  const t = text.trim();
  if (/^(goalMarkedDone|isGoalMarkerOnlyCommand)\s*\(/.test(t)) {
    const fn = /^goalMarkedDone/.test(t) ? 'goalMarkedDone' : 'isGoalMarkerOnlyCommand';
    const inner = callAt(t, fn, 0)[0].trim();
    if (inner === 'null') return {t: 'marker', fn, arg: String.fromCharCode(0) + 'NULL'};
    return {t: 'marker', fn, arg: dartStr(inner)};
  }
  if (/^shouldKickGoalRound\s*\(/.test(t)) return parseKick(callAt(t, 'shouldKickGoalRound', 0)[0]);
  if (/^shouldScheduleGoalRound\s*\(/.test(t)) return parseSched(callAt(t, 'shouldScheduleGoalRound', 0)[0]);
  if (/^buildGoalContinuationPrompt\s*\(/.test(t)) return {t: 'prompt', goal: parseGoalSpec(callAt(t, 'buildGoalContinuationPrompt', 0)[0].trim())};
  if (/^AgentGoal\s*\.\s*fromJson\s*\(/.test(t)) {
    const inner = callAt(t, 'AgentGoal.fromJson', 0)[0].trim();
    if (inner === 'null') return {t: 'fromJson', json: null};
    const bound = binds.find((b) => b.name === inner);
    if (bound !== undefined && bound.bind.kind === 'json') return {t: 'fromJson', json: bound.bind.json};
    return {t: 'fromJson', json: parseJsonSpec(inner)};
  }
  const rl = /^goal\((.*)\)\s*\.\s*roundsLeft$/s.exec(t);
  if (rl !== null) return {t: 'roundsLeft', goal: parseGoalSpec('goal(' + (rl[1] as string) + ')')};
  const bare = binds.find((b) => b.name === t);
  if (bare !== undefined) return {t: 'bind', name: t};
  const fld = /^([A-Za-z_][A-Za-z0-9_]*)((?:\.[A-Za-z][A-Za-z0-9_]*)+)$/.exec(t);
  if (fld !== null) {
    const name = fld[1] as string;
    const path = fld[2] as string;
    const bound = binds.find((b) => b.name === name);
    if (bound === undefined) throw new Error('unknown variable ' + name + ' in ' + t);
    if (bound.bind.kind === 'prompt') return {t: 'bind', name};
    return {t: 'bindField', bind: name, path: path.replace(/^\./, '')};
  }
  return {t: 'unknown', text: t};
}

function parseMatcher(text: string, marker: string): Matcher {
  const t = text.trim();
  if (t === 'isTrue') return {m: 'bool', v: true};
  if (t === 'isFalse') return {m: 'bool', v: false};
  if (t === 'isNull') return {m: 'null'};
  if (/^-?\d+$/.test(t)) return {m: 'num', v: Number.parseInt(t, 10)};
  const en = /^GoalAction\.(\w+)$/.exec(t);
  if (en !== null) return {m: 'enum', ename: 'GoalAction', v: en[1] as string};
  const st = /^AgentGoalStatus\.(\w+)$/.exec(t);
  if (st !== null) return {m: 'enum', ename: 'AgentGoalStatus', v: st[1] as string};
  if (t === 'AgentGoal.maxAllowedRounds') return {m: 'maxAllowedRounds'};
  const cn = /^contains\((.*)\)$/.exec(t);
  if (cn !== null) {
    const inner = (cn[1] as string).trim();
    if (inner === 'kGoalDoneMarker') return {m: 'contains', v: marker, fromConst: true};
    return {m: 'contains', v: dartStr(inner), fromConst: false};
  }
  if (t.startsWith("'")) return {m: 'str', v: dartStr(t)};
  return {m: 'unknown', text: t};
}

function eachCall(src: string, name: string): Array<[number, string, number]> {
  const out: Array<[number, string, number]> = [];
  const needle = name + '(';
  let i = 0;
  for (;;) {
    const idx = src.indexOf(needle, i);
    if (idx < 0) return out;
    const prev = src[idx - 1] as string;
    if (!/[A-Za-z0-9_.]/.test(prev)) {
      const [args, after] = callArgs(src, idx + name.length);
      out.push([idx, args, after]);
      i = after;
      continue;
    }
    i = idx + needle.length;
  }
}

export function parseDartTests(testSrc: string, marker: string): DartTest[] {
  const out: DartTest[] = [];
  for (const [idx, args] of eachCall(testSrc, 'test')) {
    const parts = splitArgs(args);
    const name = dartStr(parts[0] as string);
    const body = parts.slice(1).join(', ');
    const binds = collectBinds(body);
    const asserts: Assert[] = [];
    for (const [cIdx, cArgs] of eachCall(body, 'expect')) {
      const cp = splitArgs(cArgs);
      if (cp.length !== 2) throw new Error('expect with ' + cp.length + ' args: ' + cArgs.slice(0, 60));
      const line = testSrc.slice(0, idx).split(NL).length;
      asserts.push({
        line,
        actual: parseActual(cp[0] as string, binds, marker),
        matcher: parseMatcher(cp[1] as string, marker),
        text: cArgs.slice(0, 80),
      });
      void cIdx;
    }
    out.push({name, group: groupFor(testSrc, idx, marker), asserts, binds});
  }
  return out;
}

function groupFor(testSrc: string, testIdx: number, marker: string): string {
  const gs = eachCall(testSrc, 'group');
  let best = '';
  for (const [gIdx, gArgs, gAfter] of gs) {
    if (gIdx < testIdx && testIdx < gAfter) best = dartStr(splitArgs(gArgs)[0] as string);
  }
  void marker;
  return best;
}

export type Assert = {line: number; actual: ExprSpec; matcher: Matcher; text: string};
export type DartTest = {name: string; group: string; asserts: Assert[]; binds: Bind[]};

/** Split on top-level commas, skipping Dart string literals and nesting. */
export function splitArgs(src: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let cur = '';
  let i = 0;
  while (i < src.length) {
    const ch = src[i] as string;
    if (ch === "'" || ch === String.fromCharCode(34)) {
      const q = ch;
      cur += ch;
      i += 1;
      while (i < src.length) {
        const c2 = src[i] as string;
        cur += c2;
        i += 1;
        if (c2 === String.fromCharCode(92)) {
          cur += src[i] as string;
          i += 1;
          continue;
        }
        if (c2 === q) break;
      }
      continue;
    }
    if (ch === '(' || ch === '[' || ch === '{') depth += 1;
    if (ch === ')' || ch === ']' || ch === '}') depth -= 1;
    if (ch === ',' && depth === 0) {
      out.push(cur.trim());
      cur = '';
      i += 1;
      continue;
    }
    cur += ch;
    i += 1;
  }
  if (cur.trim().length > 0) out.push(cur.trim());
  return out;
}

/** Balanced-paren call lookup starting at the open paren of args. */
export function callArgs(src: string, openIdx: number): [string, number] {
  let depth = 0;
  let i = openIdx;
  while (i < src.length) {
    const ch = src[i] as string;
    if (ch === "'" || ch === String.fromCharCode(34)) {
      const q = ch;
      i += 1;
      while (i < src.length) {
        const c2 = src[i] as string;
        i += 1;
        if (c2 === String.fromCharCode(92)) {
          i += 1;
          continue;
        }
        if (c2 === q) break;
      }
      continue;
    }
    if (ch === '(' || ch === '[' || ch === '{') depth += 1;
    if (ch === ')' || ch === ']' || ch === '}') {
      depth -= 1;
      if (depth === 0) return [src.slice(openIdx + 1, i), i + 1];
    }
    i += 1;
  }
  throw new Error('unbalanced parens at ' + openIdx);
}

/** Dart single-quoted literal to its value. Interpolation is a hard error. */
export function dartStr(lit: string): string {
  const q = lit[0] as string;
  if (q !== "'" && q !== String.fromCharCode(34)) throw new Error('not a literal: ' + lit.slice(0, 24));
  if (lit[lit.length - 1] !== q) throw new Error('unterminated literal: ' + lit.slice(0, 24));
  const body = lit.slice(1, -1);
  if (body.includes(DLR)) throw new Error('interpolated literal not supported: ' + lit.slice(0, 24));
  let out = '';
  let i = 0;
  while (i < body.length) {
    const c = body[i] as string;
    if (c !== String.fromCharCode(92)) {
      out += c;
      i += 1;
      continue;
    }
    const n = body[i + 1] as string;
    i += 2;
    if (n === 'n') out += NL;
    else if (n === 't') out += String.fromCharCode(9);
    else if (n === 'r') out += String.fromCharCode(13);
    else if (n === "'" || n === String.fromCharCode(34) || n === String.fromCharCode(92)) out += n;
    else out += n;
  }
  return out;
}

function named(args: string[]): Map<string, string> {
  const m = new Map<string, string>();
  for (const a of args) {
    const k = /^([A-Za-z_][A-Za-z0-9_]*)\s*:/.exec(a);
    if (k === null) throw new Error('not a named arg: ' + a.slice(0, 40));
    m.set(k[1] as string, a.slice((k[0] as string).length).trim());
  }
  return m;
}

function asBool(v: string): boolean {
  if (v === 'true') return true;
  if (v === 'false') return false;
  throw new Error('not a bool: ' + v);
}

function asInt(v: string): number {
  if (!/^-?\d+$/.test(v)) throw new Error('not an int: ' + v);
  return Number.parseInt(v, 10);
}

export function parseGoalSpec(text: string): GoalSpec {
  const open = text.indexOf('(');
  if (!/^goal\s*\(/.test(text) || open < 0) throw new Error('not goal(): ' + text.slice(0, 40));
  const [args] = callArgs(text, open);
  const m = named(splitArgs(args));
  const spec: GoalSpec = {};
  if (m.has('roundsUsed')) spec.roundsUsed = asInt(m.get('roundsUsed') as string);
  if (m.has('maxRounds')) spec.maxRounds = asInt(m.get('maxRounds') as string);
  if (m.has('lastRoundCommands')) spec.lastRoundCommands = asInt(m.get('lastRoundCommands') as string);
  if (m.has('noProgressRounds')) spec.noProgressRounds = asInt(m.get('noProgressRounds') as string);
  const st = m.get('status');
  if (st !== undefined) {
    const mm = /^AgentGoalStatus\.(\w+)$/.exec(st);
    if (mm === null) throw new Error('bad status: ' + st);
    spec.status = mm[1] as string;
  }
  return spec;
}

/** Dart map literal with string/number/null values only. */
export function parseJsonSpec(text: string): JsonSpec {
  const body = text.trim().replace(/^\{/, '').replace(/\}$/, '');
  const out: JsonSpec = {};
  for (const pair of splitArgs(body)) {
    if (pair.trim().length === 0) continue;
    const k = /^'([^']*)'\s*:/.exec(pair);
    if (k === null) throw new Error('bad map key: ' + pair.slice(0, 30));
    const raw = pair.slice((k[0] as string).length).trim();
    if (raw === 'null') out[k[1] as string] = null;
    else if (raw.startsWith("'")) out[k[1] as string] = dartStr(raw);
    else out[k[1] as string] = asInt(raw);
  }
  return out;
}

/**
 * Interpreter that runs the parsed Dart oracle against the TypeScript port.
 *
 * Deliberately dependency-free: the implementation is injected. That keeps this
 * file importable from a strip-types probe (which needs .ts specifiers) and from
 * the committed vitest file (which must use .js specifiers) without either one
 * duplicating the logic.
 *
 * Dart semantics reproduced here:
 * - goalMarkedDone/isGoalMarkerOnlyCommand are called with a JS null where the
 *   Dart test passes a null literal.
 * - expect(x, isTrue)/isFalse/isNull map to === true / === false / === null;
 *   nothing here coerces falsiness, so a wrong-but-truthy value fails loudly.
 * - contains(v) on a nullable note: a null note must fail, and does (reading
 *   .includes on null would throw, so null is reported as a mismatch first).
 * - "restored.maxAllowedRounds" is NOT a real instance field. Dart allows
 *   reading a static const through an instance (the static_access_via_instance
 *   lint), which makes that particular Dart assertion a tautology - it compares
 *   the class constant to itself and can never fail regardless of the data. It
 *   is reproduced rather than "fixed" so the replay stays faithful, and the
 *   constraint its author clearly meant to assert (maxRounds clamped to the
 *   ceiling) is asserted separately and for real below.
 */

// (the parser types above live in this same file now)

export type Impl = {
  AgentGoal: any;
  GOAL_DONE_MARKER: string;
  goalMarkedDone: (s: string | null) => boolean;
  isGoalMarkerOnlyCommand: (s: string) => boolean;
  decideGoalContinuation: (o: any) => any;
  shouldScheduleGoalRound: (o: any) => boolean;
  shouldKickGoalRound: (o: any) => boolean;
  buildGoalContinuationPrompt: (g: any) => string;
};

export type Failure = {test: string; group: string; line: number; why: string; text: string};

const NULL_MARK = String.fromCharCode(0) + 'NULL';

function mkGoal(impl: Impl, spec: GoalSpec): any {
  const now = new Date(2026, 10, 1); // Dart helper: DateTime(2026, 11, 1)
  return new impl.AgentGoal({
    id: 'g1',
    hostId: 'web1',
    objective: '把 nginx 日志轮转配好',
    status: spec.status ?? 'active',
    roundsUsed: spec.roundsUsed ?? 0,
    maxRounds: spec.maxRounds ?? 24,
    lastRoundCommands: spec.lastRoundCommands ?? 0,
    noProgressRounds: spec.noProgressRounds ?? 0,
    createdAt: now,
    updatedAt: now,
  });
}

function jsonToJs(json: JsonSpec): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(json)) out[k] = json[k];
  return out;
}

function bindValue(impl: Impl, bind: AnyBind): unknown {
  if (bind.kind === 'decide') {
    return impl.decideGoalContinuation({
      goal: mkGoal(impl, bind.spec.goal),
      finishState: bind.spec.finishState,
      commandsRun: bind.spec.commandsRun,
      hadConfirmTimeout: bind.spec.hadConfirmTimeout,
      connectionAlive: bind.spec.connectionAlive,
      isForegroundHost: bind.spec.isForegroundHost,
      finishSummary: bind.spec.finishSummary,
    });
  }
  if (bind.kind === 'prompt') return impl.buildGoalContinuationPrompt(mkGoal(impl, bind.goal));
  if (bind.kind === 'sched') {
    return impl.shouldScheduleGoalRound({
      goal: mkGoal(impl, bind.spec.goal),
      finishingTaskId: bind.spec.finishingTaskId,
      alreadyContinuedTaskId: bind.spec.alreadyContinuedTaskId,
      engineRunning: bind.spec.engineRunning,
    });
  }
  if (bind.kind === 'kick') {
    return impl.shouldKickGoalRound({
      goalActive: bind.spec.goalActive,
      isForegroundHost: bind.spec.isForegroundHost,
      engineRunning: bind.spec.engineRunning,
      connectionAlive: bind.spec.connectionAlive,
    });
  }
  if (bind.kind === 'json') return jsonToJs(bind.json);
  if (bind.kind === 'fromJson') return impl.AgentGoal.fromJson(bind.json === null ? null : jsonToJs(bind.json));
  if (bind.kind === 'edited') return mkGoal(impl, bind.goal).copyWith({objective: bind.objective});
  throw new Error('unhandled bind kind ' + String((bind as {kind: string}).kind));
}

/** Follow a dotted path, with Dart's read-a-static-through-an-instance quirk. */
function readPath(impl: Impl, obj: unknown, path: string): unknown {
  let cur: any = obj;
  for (const seg of path.split('.')) {
    if (cur === null || cur === undefined) throw new Error('cannot read ' + path + ' of ' + String(cur));
    if (seg === 'maxAllowedRounds' && !(seg in (cur as object))) return impl.AgentGoal.MAX_ALLOWED_ROUNDS;
    if (seg === 'defaultMaxRounds' && !(seg in (cur as object))) return impl.AgentGoal.DEFAULT_MAX_ROUNDS;
    if (typeof cur === 'string' && seg === 'length') {
      cur = (cur as string).length;
      continue;
    }
    if (!(seg in (cur as object))) throw new Error('no member ' + seg + ' on ' + path);
    cur = (cur as Record<string, unknown>)[seg];
  }
  return cur;
}

function show(v: unknown): string {
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'object') return 'obj';
  return String(v);
}

function evalExpr(impl: Impl, e: ExprSpec, binds: DartTest['binds'], jsonCache: Map<string, unknown>): unknown {
  if (e.t === 'marker') {
    const arg = e.arg === NULL_MARK ? null : e.arg;
    return e.fn === 'goalMarkedDone' ? impl.goalMarkedDone(arg as string | null) : impl.isGoalMarkerOnlyCommand(arg as string);
  }
  if (e.t === 'kick') {
    return impl.shouldKickGoalRound({
      goalActive: e.goalActive,
      isForegroundHost: e.isForegroundHost,
      engineRunning: e.engineRunning,
      connectionAlive: e.connectionAlive,
    });
  }
  if (e.t === 'sched') {
    return impl.shouldScheduleGoalRound({
      goal: mkGoal(impl, e.goal),
      finishingTaskId: e.finishingTaskId,
      alreadyContinuedTaskId: e.alreadyContinuedTaskId,
      engineRunning: e.engineRunning,
    });
  }
  if (e.t === 'prompt') return impl.buildGoalContinuationPrompt(mkGoal(impl, e.goal));
  if (e.t === 'fromJson') return impl.AgentGoal.fromJson(e.json === null ? null : jsonToJs(e.json));
  if (e.t === 'roundsLeft') return mkGoal(impl, e.goal).roundsLeft;
  if (e.t === 'bind') {
    const b = binds.find((x) => x.name === e.name);
    if (b === undefined) throw new Error('bind ' + e.name + ' not found');
    return bindValue(impl, b.bind);
  }
  if (e.t === 'bindField') {
    const b = binds.find((x) => x.name === e.bind);
    if (b === undefined) throw new Error('bind ' + e.bind + ' not found');
    const key = e.bind + '.' + e.path;
    if (jsonCache.has(key)) return jsonCache.get(key);
    const v = readPath(impl, bindValue(impl, b.bind), e.path);
    jsonCache.set(key, v);
    return v;
  }
  throw new Error('unhandled expr ' + String((e as {t: string}).t));
}

function check(matcher: Matcher, actual: unknown): string | null {
  if (matcher.m === 'bool') {
    if (actual !== matcher.v) return 'expected ' + String(matcher.v) + ' but got ' + show(actual);
    return null;
  }
  if (matcher.m === 'null') return actual === null ? null : 'expected null but got ' + show(actual);
  if (matcher.m === 'str') {
    if (typeof actual !== 'string') return 'expected string ' + JSON.stringify(matcher.v) + ' but got ' + show(actual);
    return actual === matcher.v ? null : 'expected ' + JSON.stringify(matcher.v) + ' but got ' + JSON.stringify(actual);
  }
  if (matcher.m === 'num') {
    if (typeof actual !== 'number') return 'expected ' + matcher.v + ' but got ' + show(actual);
    return actual === matcher.v ? null : 'expected ' + matcher.v + ' but got ' + String(actual);
  }
  if (matcher.m === 'enum') {
    if (typeof actual !== 'string') return 'expected ' + matcher.ename + '.' + matcher.v + ' but got ' + show(actual);
    return actual === matcher.v ? null : 'expected ' + matcher.ename + '.' + matcher.v + ' but got ' + JSON.stringify(actual);
  }
  if (matcher.m === 'maxAllowedRounds') {
    return typeof actual === 'number' && actual === 256 ? null : 'expected 256 but got ' + show(actual);
  }
  if (matcher.m === 'contains') {
    if (typeof actual !== 'string') return 'contains(' + JSON.stringify(matcher.v) + ') but got ' + show(actual);
    return actual.includes(matcher.v) ? null : 'does not contain ' + JSON.stringify(matcher.v) + ': ' + JSON.stringify(actual);
  }
  throw new Error('unhandled matcher ' + String((matcher as {m: string}).m));
}

export function runDartTests(impl: Impl, tests: DartTest[]): {checked: number; failures: Failure[]} {
  let checked = 0;
  const failures: Failure[] = [];
  for (const t of tests) {
    const jsonCache = new Map<string, unknown>();
    for (const a of t.asserts) {
      checked += 1;
      try {
        const actual = evalExpr(impl, a.actual, t.binds, jsonCache);
        const why = check(a.matcher, actual);
        if (why !== null) failures.push({test: t.name, group: t.group, line: a.line, why, text: a.text});
      } catch (err) {
        failures.push({test: t.name, group: t.group, line: a.line, why: String(err), text: a.text});
      }
    }
  }
  return {checked, failures};
}


// ===========================================================================
// Drift-guard text helpers
// ===========================================================================
/**
 * ---------------------------------------------------------------------------
 * Drift-guard helper layer.
 *
 * Everything below reads the two sources as TEXT and compares them token by
 * token. Three traps shape these helpers, all of them found the hard way:
 *
 *  1. A Dart apostrophe inside a comment ("don't") opens a phantom string for
 *     any quote-aware scanner, so comments are blanked to equal-length spaces
 *     first (offsets survive, indexes printed in failures stay correct).
 *  2. Dart raw literals keep their backslashes; normal single-quoted literals
 *     do not. Only unescape the non-raw ones, and decode \uXXXX / \xNN, because
 *     the TypeScript strip class spells its CJK characters that way.
 *  3. A bare "$" at the START of a pattern is an end-of-line anchor, never a
 *     dollar sign, so the interpolation patterns below are built from DLR and
 *     not from a literal.
 * ---------------------------------------------------------------------------
 */

/** The kGoalDoneMarker value, read out of the Dart module (never hardcoded). */
const DART_MARKER = dartMarkerValue(DART_MODULE_TEXT);

const BSL = String.fromCharCode(92);
const SQ = String.fromCharCode(39);
const DQ = String.fromCharCode(34);
const BT = String.fromCharCode(96);

/** Decode the escapes a non-raw single-quoted literal may contain. */
function unesc(body: string): string {
  let out = "";
  let i = 0;
  while (i < body.length) {
    const c = body[i] as string;
    if (c !== BSL) {
      out += c;
      i += 1;
      continue;
    }
    const n = body[i + 1] as string;
    if (n === "u") {
      out += String.fromCharCode(parseInt(body.slice(i + 2, i + 6), 16));
      i += 6;
      continue;
    }
    if (n === "x") {
      out += String.fromCharCode(parseInt(body.slice(i + 2, i + 4), 16));
      i += 4;
      continue;
    }
    if (n === "n") out += NL;
    else if (n === "t") out += String.fromCharCode(9);
    else if (n === "r") out += String.fromCharCode(13);
    else out += n;
    i += 2;
  }
  return out;
}

/** Replace every comment with spaces, keeping all offsets identical. */
function blankComments(text: string): string {
  const chars = text.split("");
  const put = (from: number, to: number): void => {
    for (let k = from; k < to && k < chars.length; k++) {
      if ((chars[k] as string) !== NL) chars[k] = " ";
    }
  };
  let i = 0;
  while (i < text.length) {
    const ch = text[i] as string;
    if (ch === "/" && text[i + 1] === "/") {
      let j = text.indexOf(NL, i);
      if (j < 0) j = text.length;
      put(i, j);
      i = j;
      continue;
    }
    if (ch === "/" && text[i + 1] === "*") {
      const e = text.indexOf("*/", i + 2);
      const to = e < 0 ? text.length : e + 2;
      put(i, to);
      i = to;
      continue;
    }
    if (ch === SQ || ch === DQ || ch === BT) {
      // Literals are consumed whole: an apostrophe inside a string is not a
      // comment and a "//" inside a string is not a comment either.
      const q3 = ch.repeat(3);
      if (text.slice(i, i + 3) === q3 || text.slice(i, i + 4) === "r" + q3) {
        const start = text[i] === "r" ? i + 1 : i;
        const end = text.indexOf(q3, start + 3);
        i = end < 0 ? text.length : end + 3;
        continue;
      }
      let j = i + 1;
      while (j < text.length) {
        const c = text[j] as string;
        if (c === BSL) {
          j += 2;
          continue;
        }
        if (c === ch) {
          j += 1;
          break;
        }
        j += 1;
      }
      // Stop PAST the closing quote: this loop has no implicit i++ the way
      // the literal scanners below have it, where the loop increment does the
      // step and the cursor must therefore stop one short of the next char.
      i = j;
      continue;
    }
    i += 1;
  }
  return chars.join("");
}

/**
 * Linear literal scanner over comment-blanked text. A global regex over mixed
 * quote styles silently loses its parity, so literals are walked. Dart raw
 * literals (r'', r""", r''') keep their backslashes; ordinary literals are
 * unescaped.
 */
function scanLits(text: string): string[] {
  const out: string[] = [];
  let i = 0;
  while (i < text.length) {
    const ch = text[i] as string;
    if (ch !== SQ && ch !== DQ && ch !== BT) {
      i += 1;
      continue;
    }
    const q3 = ch.repeat(3);
    if (text.slice(i, i + 3) === q3 || text.slice(i, i + 4) === "r" + q3) {
      const start = text[i] === "r" ? i + 1 : i;
      const end = text.indexOf(q3, start + 3);
      if (end < 0) throw new Error("unterminated triple literal at " + start);
      out.push(text.slice(start + 3, end));
      i = end + 3;
      continue;
    }
    if (text[i - 1] === "r") {
      let j = i + 1;
      let body = "";
      while (j < text.length) {
        const c = text[j] as string;
        if (c === BSL) {
          const n = text[j + 1] as string;
          if (n === ch) body += ch;
          else body += c + (n ?? "");
          j += 2;
          continue;
        }
        if (c === ch) break;
        body += c;
        j += 1;
      }
      out.push(body);
      i = j + 1;
      continue;
    }
    let j = i + 1;
    let body2 = "";
    while (j < text.length) {
      const c = text[j] as string;
      if (c === BSL) {
        body2 += c + (text[j + 1] ?? "");
        j += 2;
        continue;
      }
      if (c === ch) break;
      body2 += c;
      j += 1;
    }
    out.push(unesc(body2));
    i = j + 1;
  }
  return out;
}

/** Split a literal body on Dart interpolation, keeping only static pieces. */
function staticPieces(bodies: string[]): string[] {
  // The dollar sign has to be spelled \x24 inside the pattern: a bare "$" at
  // the start of a pattern is an end-of-line anchor, which silently matches
  // nothing and would make every interpolated literal look static.
  const braceForm = new RegExp("\\x24[{][^}]*[}]", "g");
  const bareForm = new RegExp("\\x24[A-Za-z_][A-Za-z0-9_.]*", "g");
  const out: string[] = [];
  for (const b of bodies) {
    const flat = b.replace(braceForm, "\u0000").replace(bareForm, "\u0000");
    for (const piece of flat.split("\u0000")) {
      if (piece.length > 0) out.push(piece);
    }
  }
  return out;
}

/** Capture an argument / property value up to its top-level separator. */
function captureValue(src: string, from: number): [string, number] {
  let depth = 0;
  let cur = "";
  let i = from;
  while (i < src.length) {
    const ch = src[i] as string;
    if (ch === SQ || ch === DQ) {
      const q = ch;
      cur += ch;
      i += 1;
      while (i < src.length) {
        const c2 = src[i] as string;
        cur += c2;
        i += 1;
        if (c2 === BSL) {
          cur += src[i] as string;
          i += 1;
          continue;
        }
        if (c2 === q) break;
      }
      continue;
    }
    if (ch === "(" || ch === "{" || ch === "[") depth += 1;
    if (ch === ")" || ch === "}" || ch === "]") {
      if (depth === 0) break;
      depth -= 1;
    }
    if ((ch === "," || ch === ";") && depth === 0) break;
    cur += ch;
    i += 1;
  }
  return [cur.trim(), i];
}

function valuesForKey(src: string, key: string): string[] {
  const out: string[] = [];
  let i = 0;
  for (;;) {
    const idx = src.indexOf(key, i);
    if (idx < 0) return out;
    const prev = idx === 0 ? "" : (src[idx - 1] as string);
    if (/[A-Za-z0-9_]/.test(prev)) {
      i = idx + key.length;
      continue;
    }
    const pair = captureValue(src, idx + key.length);
    out.push(pair[0]);
    i = pair[1];
  }
}

function tailFrom(src: string, head: string): string {
  const a = src.indexOf(head);
  if (a < 0) throw new Error("head not found: " + head);
  return src.slice(a);
}

function segment(src: string, head: string, stop: string): string {
  const h = tailFrom(src, head);
  const e = h.indexOf(stop, head.length);
  return e < 0 ? h : h.slice(0, e);
}

/** Normalise a guard condition so Dart and JS spellings become comparable. */
function normCond(c: string): string {
  let s = c.replace(/\s+/g, "");
  s = s.replace(/AgentFinishState\./g, "");
  s = s.replace(/\.isNotEmpty/g, ".length>0");
  s = s.replace(/\.trimLeft\(/g, ".trimStart(");
  s = s.replace(/kGoalDoneMarker/g, "GOAL_DONE_MARKER");
  s = s.replace(/!==/g, "\u0001").replace(/===/g, "\u0002");
  s = s.replace(/==/g, "\u0002").replace(/!=/g, "\u0001");
  s = s.replace(/\u0001/g, "!=").replace(/\u0002/g, "==");
  return s.replace(/'/g, "").replace(/"/g, "");
}

function ifConditions(src: string): string[] {
  const out: string[] = [];
  let i = 0;
  for (;;) {
    const j = src.indexOf("if (", i);
    const k = src.indexOf("if(", i);
    const idx = j < 0 ? k : k < 0 ? j : Math.min(j, k);
    if (idx < 0) return out;
    const prev = idx === 0 ? "" : (src[idx - 1] as string);
    if (/[A-Za-z0-9_]/.test(prev)) {
      i = idx + 3;
      continue;
    }
    const pair = callArgs(src, src.indexOf("(", idx));
    out.push(pair[0].trim());
    i = pair[1];
  }
}

/** All literals of a Dart segment, interpolation removed. */
function dartStaticText(seg: string): string[] {
  return staticPieces(scanLits(seg));
}
/** All string literals of a TS segment, concatenation operators ignored. */
function tsStaticText(seg: string): string[] {
  return scanLits(seg);
}

const DART_DECIDE = segment(DART_MODULE_TEXT, "GoalDecision decideGoalContinuation", "bool shouldScheduleGoalRound");
const TS_DECIDE = segment(TS_MODULE_TEXT, "export function decideGoalContinuation", "export function shouldScheduleGoalRound");
const DART_PROMPT = tailFrom(DART_MODULE_TEXT, "String buildGoalContinuationPrompt");
const TS_PROMPT = tailFrom(TS_MODULE_TEXT, "export function buildGoalContinuationPrompt");
const DART_SCHED = segment(DART_MODULE_TEXT, "bool shouldScheduleGoalRound", "bool shouldKickGoalRound");
const TS_SCHED = segment(TS_MODULE_TEXT, "export function shouldScheduleGoalRound", "export function shouldKickGoalRound");
const DART_KICK = tailFrom(DART_MODULE_TEXT, "bool shouldKickGoalRound");
const TS_KICK = tailFrom(TS_MODULE_TEXT, "export function shouldKickGoalRound");


// ===========================================================================
// Assertions
// ===========================================================================
describe("Dart oracle parse integrity", () => {
  const tests = parseDartTests(DART_ORACLE_TEXT, DART_MARKER);

  it("finds exactly the nine expected groups", () => {
    const groups: string[] = [];
    for (const t of tests) if (!groups.includes(t.group)) groups.push(t.group);
    expect(groups).toEqual([
      "达成标记识别",
      "优先级：用户的意图高于一切自动逻辑",
      "无人看管与环境异常一律停",
      "预算与进展",
      "恢复目标必须真的动起来",
      "续跑排队守卫",
      "达成标记不能被当成命令执行",
      "续跑提示词",
      "AgentGoal 自身约束",
    ]);
  });

  it("finds 32 tests and 73 assertions, none unparseable", () => {
    expect(tests.length).toBe(32);
    const total = tests.reduce((n, t) => n + t.asserts.length, 0);
    expect(total).toBe(73);
    // one parsed assertion per expect( in the file: nothing silently dropped
    expect(total).toBe(DART_ORACLE_TEXT.split("expect(").length - 1);
    const unknowns: string[] = [];
    for (const t of tests) {
      for (const a of t.asserts) {
        if (a.actual.t === "unknown") unknowns.push("expr " + a.text);
        if (a.matcher.m === "unknown") unknowns.push("matcher " + a.text);
      }
    }
    expect(unknowns).toEqual([]);
  });

  it("every parsed test sits inside a named group", () => {
    const nameless = tests.filter((t) => t.group.length === 0).map((t) => t.name);
    expect(nameless).toEqual([]);
  });
});

describe("Dart oracle replayed against the TypeScript port", () => {
  const impl: Impl = {
    AgentGoal,
    GOAL_DONE_MARKER: goal.GOAL_DONE_MARKER,
    goalMarkedDone: goal.goalMarkedDone,
    isGoalMarkerOnlyCommand: goal.isGoalMarkerOnlyCommand,
    decideGoalContinuation: goal.decideGoalContinuation,
    shouldScheduleGoalRound: goal.shouldScheduleGoalRound,
    shouldKickGoalRound: goal.shouldKickGoalRound,
    buildGoalContinuationPrompt: goal.buildGoalContinuationPrompt,
  };
  const tests = parseDartTests(DART_ORACLE_TEXT, DART_MARKER);
  const res = runDartTests(impl, tests);

  // Every one of the 73 expectations below comes out of the Dart test file at
  // run time. A failure string therefore names the Dart group, the Dart test
  // name, the Dart line and the Dart source of the assertion.
  it("checks all 73 Dart expectations", () => {
    expect(res.checked).toBe(73);
  });

  it("passes every one of them", () => {
    const pretty = res.failures
      .map((f) => "[" + f.group + "] " + f.test + " @dartline " + f.line + " :: " + f.why + " :: " + f.text)
      .join(NL);
    expect(pretty).toBe("");
  });
});

describe("decision structure is isomorphic to Dart", () => {
  it("the eight guards appear in the same order in both languages", () => {
    // This ordering is the single most important property of the module: a
    // reordered guard silently changes which note the user is shown (budget
    // versus no-progress versus task-failed) and which status the goal lands in.
    const d = ifConditions(blankComments(DART_DECIDE)).map(normCond);
    const t = ifConditions(blankComments(TS_DECIDE)).map(normCond);
    expect(t).toEqual(d);
    expect(d).toEqual([
      "goalMarkedDone(finishSummary)",
      "finishState==cancelled",
      "hadConfirmTimeout",
      "!connectionAlive",
      "!isForegroundHost",
      "goal.budgetExhausted",
      "finishState==failed",
      "noProgressRounds>=2",
    ].map(normCond));
  });

  it("the two queue guards match and the kick guard stays branch-free", () => {
    const d = ifConditions(blankComments(DART_SCHED)).map(normCond);
    const t = ifConditions(blankComments(TS_SCHED)).map(normCond);
    expect(t).toEqual(d);
    expect(d).toEqual([
      "goal?.isActive!=true",
      "finishingTaskId!=null&&finishingTaskId==alreadyContinuedTaskId",
    ].map(normCond));
    // shouldKickGoalRound is one boolean expression in Dart, so no guard at all
    expect(ifConditions(blankComments(DART_KICK))).toEqual([]);
    expect(ifConditions(blankComments(TS_KICK))).toEqual([]);
  });

  it("nine decisions carry the same reason codes in the same order", () => {
    const d = valuesForKey(DART_DECIDE, "reason:").map((v) => dartStaticText(v));
    const t = valuesForKey(TS_DECIDE, "reason:").map((v) => tsStaticText(v));
    expect(t).toEqual(d);
    expect(d.length).toBe(9);
    expect(d[d.length - 1]).toEqual(["progress", "continue"]);
    expect(d[0]).toEqual(["objective_done"]);
  });

  it("every note string is byte-identical to its Dart counterpart", () => {
    // Dart writes each note twice (once on the decision, once on the copyWith
    // goal); the port duplicates it for the same reason, so the sequences must
    // match element for element, duplicated entries included.
    const d = valuesForKey(DART_DECIDE, "note:").map((v) => dartStaticText(v).join(""));
    const t = valuesForKey(TS_DECIDE, "note:").map((v) => tsStaticText(v).join(""));
    expect(t).toEqual(d);
    expect(d.length).toBe(15);
    expect(d.every((x) => x.length > 0)).toBe(true);
  });

  it("actions and statuses match the Dart enum spellings", () => {
    const strip = (v: string): string =>
      v.replace(/GoalAction\./g, "").replace(/AgentGoalStatus\./g, "").replace(/"/g, "").trim();
    const da = valuesForKey(DART_DECIDE, "action:").map(strip);
    const ta = valuesForKey(TS_DECIDE, "action:").map(strip);
    expect(ta).toEqual(da);
    expect(da).toEqual([
      "finish",
      "pause",
      "pause",
      "pause",
      "pause",
      "finish",
      "pause",
      "pause",
      "continueRound",
    ]);
    const ds = valuesForKey(DART_DECIDE, "status:").map(strip);
    const tstat = valuesForKey(TS_DECIDE, "status:").map(strip);
    expect(tstat).toEqual(ds);
    expect(ds).toEqual([
      "finished",
      "paused",
      "paused",
      "paused",
      "paused",
      "finished",
      "paused",
      "paused",
    ]);
  });

  it("the resumption branch clears the note instead of keeping a stale one", () => {
    const d = valuesForKey(DART_DECIDE, "clearNote:");
    const t = valuesForKey(TS_DECIDE, "clearNote:");
    expect(d.length).toBe(1);
    expect(t).toEqual(d);
    expect(t[0]).toContain("true");
  });

  it("the Dart decision tree returns in every branch, so does the port", () => {
    // Nine branch bodies, nine returns: a fallen-through branch would run a
    // second copyWith and overwrite the note the user is about to read.
    expect((DART_DECIDE.split("return GoalDecision(").length - 1)).toBe(9);
    expect((TS_DECIDE.split("return new GoalDecision(").length - 1)).toBe(9);
  });
});

describe("marker detection is isomorphic to Dart", () => {
  it("goalMarkedDone splits on newline and uses startsWith, like Dart", () => {
    const NLlit = String.fromCharCode(92) + "n";
    const SQq = String.fromCharCode(39);
    const DQq = String.fromCharCode(34);
    expect(DART_MODULE_TEXT.includes(".split(" + SQq + NLlit + SQq + ")")).toBe(true);
    expect(TS_MODULE_TEXT.includes(".split(" + DQq + NLlit + DQq + ")")).toBe(true);
    expect(DART_MODULE_TEXT.includes(".trimLeft().startsWith(kGoalDoneMarker)")).toBe(true);
    expect(TS_MODULE_TEXT.includes(".trimStart().startsWith(GOAL_DONE_MARKER)")).toBe(true);
  });

  it("the marker literal itself is identical in both sources", () => {
    expect(goal.GOAL_DONE_MARKER).toBe(DART_MARKER);
    expect(goal.GOAL_DONE_MARKER).toBe("目标已达成");
    expect(goal.GOAL_MARKER_STRIP_PATTERN).not.toBe(goal.GOAL_DONE_MARKER);
  });

  it("the strip class is the exact Dart raw character class", () => {
    // The Dart side is a raw literal, so its backslashes are characters, not
    // escapes, and the port has to carry them. Both are plain literal classes -
    // no shorthand, no range, no anchor - so RE2 and V8 agree on them by
    // construction; asserting byte equality is therefore enough.
    const candidates = scanLits(blankComments(DART_MODULE_TEXT)).filter((x) => x.startsWith("["));
    expect(candidates.length).toBe(1);
    const dArtClass = candidates[0] as string;
    expect(goal.GOAL_MARKER_STRIP_PATTERN).toBe(dArtClass);
    expect(dArtClass.includes(String.fromCharCode(92) + "[")).toBe(true);
    expect(dArtClass.includes(String.fromCharCode(92) + "]")).toBe(true);
    for (const bad of ["d", "w", "s", "S", "p", "D", "W", "b", "u"]) {
      expect(dArtClass.includes(String.fromCharCode(92) + bad)).toBe(false);
    }
    // no range operator: a hyphen would silently swallow a codepoint span
    expect(dArtClass.includes("-")).toBe(false);
    expect(dArtClass.startsWith("[")).toBe(true);
    expect(dArtClass.endsWith("]")).toBe(true);
  });

  it("both strip classes behave identically on real strings", () => {
    const classes = scanLits(blankComments(DART_MODULE_TEXT)).filter((x) => x.startsWith("["));
    const dArtClass = classes[0] as string;
    const dartLike = new RegExp(dArtClass, "g");
    const SQq = String.fromCharCode(39);
    const samples = [
      "目标已达成",
      "「目标已达成」",
      "  「目标已达成」  ",
      "目标已达成。",
      SQq + "目标已达成" + SQq,
      "(目标已达成)",
      "【目标已达成】",
      "『目标已达成』",
      "目标已达成!",
      "目标已达成；下一步",
      "回答：目标已达成",
      "目标 已 达成",
      "rm -rf /",
      "echo 目标已达成",
    ];
    const mismatches: string[] = [];
    for (const s of samples) {
      const a = s.replace(new RegExp(goal.GOAL_MARKER_STRIP_PATTERN, "g"), "").trim();
      const b = s.replace(dartLike, "").trim();
      if (a !== b) mismatches.push(JSON.stringify(s) + " ts=" + JSON.stringify(a) + " dart=" + JSON.stringify(b));
    }
    expect(mismatches).toEqual([]);
  });

  it("a marker-only command is never executed, a marker inside prose is", () => {
    // This is the hard guard the port exists for: on real devices the model
    // writes the marker into a 命令: block and the terminal then tries to run it.
    expect(goal.isGoalMarkerOnlyCommand("  「目标已达成」  ")).toBe(true);
    expect(goal.isGoalMarkerOnlyCommand("目标已达成")).toBe(true);
    expect(goal.isGoalMarkerOnlyCommand("echo 目标已达成")).toBe(false);
    expect(goal.isGoalMarkerOnlyCommand("目标已达成")).toBe(true);
    expect(goal.isGoalMarkerOnlyCommand("")).toBe(false);
    expect(goal.goalMarkedDone("小结" + NL + "目标已达成：日志已按天轮转")).toBe(true);
    expect(goal.goalMarkedDone("我还没有完成，谈不上目标已达成")).toBe(false);
    expect(goal.goalMarkedDone(null)).toBe(false);
  });
});

describe("continuation prompt is isomorphic to Dart", () => {
  it("concatenates the same static fragments in the same order", () => {
    const d = dartStaticText(DART_PROMPT);
    const t = tsStaticText(TS_PROMPT);
    expect(t).toEqual(d);
    // ten fragments: the interpolation sites (the round counter, the objective
    // and the marker) split the Dart string, and the port splits at the same
    // places with concatenation.
    expect(d.length).toBe(10);
  });

  it("numbers the round as roundsUsed + 1 like Dart", () => {
    expect(DART_PROMPT.includes("goal.roundsUsed + 1")).toBe(true);
    expect(TS_PROMPT.includes("goal.roundsUsed + 1")).toBe(true);
  });

  it("never embeds conversation history into the prompt", () => {
    // A续跑 prompt that carries the whole conversation would defeat the point
    // of the round budget: every round would re-send the growing history.
    expect(DART_PROMPT.includes("lastRoundCommands")).toBe(false);
    expect(TS_PROMPT.includes("lastRoundCommands")).toBe(false);
    expect(DART_PROMPT.includes("conversation")).toBe(false);
    expect(TS_PROMPT.includes("conversation")).toBe(false);
  });

  it("renders the marker inside the prompt and counts rounds from one", () => {
    const g = new AgentGoal({
      id: "g1",
      hostId: "web1",
      objective: "把 nginx 日志轮转配好",
      status: "active",
      roundsUsed: 2,
      maxRounds: 24,
      lastRoundCommands: 3,
      noProgressRounds: 0,
      createdAt: new Date(2026, 10, 1),
      updatedAt: new Date(2026, 10, 1),
    });
    const p = goal.buildGoalContinuationPrompt(g);
    expect(p.includes("第 3/24 轮")).toBe(true);
    expect(p.includes(goal.GOAL_DONE_MARKER)).toBe(true);
    expect(p.includes("把 nginx 日志轮转配好")).toBe(true);
    expect(p.includes("命令:")).toBe(true);
  });
});

describe("AgentGoal constraints the Dart test could not express", () => {
  const iso = "2026-11-01T00:00:00.000000";
  const base = (): Record<string, unknown> => ({
    objective: "o",
    createdAt: iso,
    updatedAt: iso,
  });
  const roundTrips = (v: unknown): number | null => {
    const j = base();
    j.maxRounds = v;
    const g = AgentGoal.fromJson(j);
    return g === null ? null : g.maxRounds;
  };

  it("clamps maxRounds for real (the Dart assertion reads a static and is vacuous)", () => {
    // Dart asserts restored.maxAllowedRounds == AgentGoal.maxAllowedRounds, i.e.
    // a class constant against itself. The constraint its author meant to state
    // is that a hand-edited budget cannot exceed the hard ceiling, so assert it
    // here against the parsed value.
    expect(AgentGoal.fromJson({objective: "o", createdAt: iso, updatedAt: iso, maxRounds: 100000})!.maxRounds).toBe(256);
    expect(roundTrips(257)).toBe(256);
    expect(roundTrips(256)).toBe(256);
    expect(roundTrips(-5)).toBe(1);
    expect(roundTrips(0)).toBe(1);
    expect(roundTrips("abc")).toBe(24);
    expect(roundTrips(null)).toBe(24);
    expect(roundTrips(undefined)).toBe(24);
    expect(roundTrips(3.7)).toBe(3);
  });

  it("rejects payloads that cannot describe a goal", () => {
    expect(AgentGoal.fromJson(null)).toBe(null);
    expect(AgentGoal.fromJson({})).toBe(null);
    expect(AgentGoal.fromJson({objective: "   ", createdAt: iso, updatedAt: iso})).toBe(null);
    expect(AgentGoal.fromJson({objective: "o", createdAt: "not-a-date", updatedAt: iso})).toBe(null);
    expect(AgentGoal.fromJson({objective: "o", createdAt: iso})).toBe(null);
  });

  it("treats an unknown status as paused rather than as active", () => {
    // 宁可停下等用户 - a half-parsed status must never auto-resume a task.
    const g = AgentGoal.fromJson({objective: "o", createdAt: iso, updatedAt: iso, status: "running"});
    expect(g === null ? null : g.status).toBe("paused");
    expect(g === null ? null : g.isActive).toBe(false);
    const g2 = AgentGoal.fromJson({objective: "o", createdAt: iso, updatedAt: iso});
    expect(g2 === null ? null : g2.status).toBe("paused");
  });

  it("keeps toJson timestamps free of a zone marker, like Dart", () => {
    const g = AgentGoal.fromJson({objective: "o", createdAt: iso, updatedAt: iso});
    if (g === null) throw new Error("payload should parse");
    const j = g.toJson();
    expect(typeof j.createdAt).toBe("string");
    expect(String(j.createdAt)).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}$/);
    const back = AgentGoal.fromJson(j);
    expect(back === null ? null : back.createdAt.getTime()).toBe(g.createdAt.getTime());
  });

  it("clearNote wins over an explicitly passed note", () => {
    const g = new AgentGoal({
      id: "g",
      hostId: "h",
      objective: "o",
      status: "paused",
      roundsUsed: 0,
      maxRounds: 24,
      lastRoundCommands: 0,
      noProgressRounds: 0,
      note: "旧的暂停原因",
      createdAt: new Date(2026, 10, 1),
      updatedAt: new Date(2026, 10, 1),
    });
    expect(g.copyWith({clearNote: true, note: "新的备注"}).note).toBe(null);
    expect(g.copyWith({note: "新的备注"}).note).toBe("新的备注");
    expect(g.copyWith({}).note).toBe("旧的暂停原因");
  });

  it("roundsLeft never goes negative and budgetExhausted is inclusive", () => {
    const g = new AgentGoal({
      id: "g",
      hostId: "h",
      objective: "o",
      status: "active",
      roundsUsed: 0,
      maxRounds: 2,
      lastRoundCommands: 0,
      noProgressRounds: 0,
      createdAt: new Date(2026, 10, 1),
      updatedAt: new Date(2026, 10, 1),
    });
    expect(g.roundsLeft).toBe(2);
    expect(g.copyWith({roundsUsed: 2}).budgetExhausted).toBe(true);
    expect(g.copyWith({roundsUsed: 2}).roundsLeft).toBe(0);
    expect(g.copyWith({roundsUsed: 9}).roundsLeft).toBe(0);
  });

  it("does not fabricate an updatedAt inside decide", () => {
    // Dart calls DateTime.now() inside the decision and the port keeps that
    // (same signature, same semantics), so the only honest assertion is that
    // the stamp moved forward - never what it equals.
    const g = new AgentGoal({
      id: "g",
      hostId: "h",
      objective: "o",
      status: "active",
      roundsUsed: 0,
      maxRounds: 24,
      lastRoundCommands: 0,
      noProgressRounds: 0,
      createdAt: new Date(2020, 0, 1),
      updatedAt: new Date(2020, 0, 1),
    });
    const d = goal.decideGoalContinuation({
      goal: g,
      finishState: "success",
      commandsRun: 4,
      hadConfirmTimeout: false,
      connectionAlive: true,
      isForegroundHost: true,
      finishSummary: null,
    });
    expect(d.action).toBe("continueRound");
    expect(d.goal.updatedAt.getTime()).toBeGreaterThan(g.updatedAt.getTime());
    expect(d.note).toBe(null);
    expect(d.reason).toBe("progress");
  });
});

describe("the new surface is exported where the rest of the port is", () => {
  const names = [
    "AgentGoal",
    "AGENT_GOAL_STATUSES",
    "GoalDecision",
    "GOAL_ACTIONS",
    "GOAL_DONE_MARKER",
    "decideGoalContinuation",
    "goalMarkedDone",
    "isGoalMarkerOnlyCommand",
    "shouldScheduleGoalRound",
    "shouldKickGoalRound",
    "buildGoalContinuationPrompt",
  ];

  it("is published from the utils barrel", () => {
    const missing = names.filter((n) => !(n in utilsBarrel));
    expect(missing).toEqual([]);
    // the model is reachable through one module only: goal_continuation.ts owns
    // the re-export so the barrels do not name agent_goal.ts at all
    expect("GOAL_MARKER_STRIP_PATTERN" in utilsBarrel).toBe(true);
  });

  it("is published from the root barrel without the internal strip pattern", () => {
    const missing = names.filter((n) => !(n in rootBarrel));
    expect(missing).toEqual([]);
    // the strip class is a drift-guard detail, not public API
    expect("GOAL_MARKER_STRIP_PATTERN" in rootBarrel).toBe(false);
  });

  it("keeps the status and action vocabularies frozen", () => {
    expect([...goal.AGENT_GOAL_STATUSES]).toEqual(["active", "paused", "finished"]);
    expect([...goal.GOAL_ACTIONS]).toEqual(["continueRound", "finish", "pause"]);
    expect(AgentGoal.DEFAULT_MAX_ROUNDS).toBe(24);
    expect(AgentGoal.MAX_ALLOWED_ROUNDS).toBe(256);
  });
});

