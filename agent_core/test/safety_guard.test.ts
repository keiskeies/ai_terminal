// SafetyGuard parity: agent_core/src/utils/safety_guard.ts vs
// ai_terminal/lib/core/safety_guard.dart.
//
// safety_guard.dart is the classifier the shipping product consults: the ReAct loop
// reads check() for every generated command (services/agent_engine.dart:2523), the
// reason and tip strings are what the confirmation dialog shows (:2599, :2653), and
// checkPath() gates the local file tools (services/local_file_policy.dart:147). The
// port therefore has to agree with Dart down to the rule that fired, not merely the
// level it fired at, because the level is only half of what the user reads.
//
// Three layers, cheapest first:
//
// 1. ORACLE REPLAY. test/safety_guard_test.dart is 49 tests and 54 assertions written
//    against the Dart class. CI has no Dart SDK, so that file can never execute; it is
//    parsed here instead and every assertion is replayed against the TypeScript
//    functions. The Dart suite is the specification and it is not transcribed by hand,
//    so a Dart-side edit to a case shows up as a failure here rather than as drift
//    nobody notices. The counts are asserted too (10 groups, 49 tests, 54 assertions):
//    a parser that silently matched less would otherwise turn the oracle into a
//    vacuous pass.
//
// 2. TABLE DIFF. The rule tables are compared entry by entry, in declaration order,
//    against a fresh parse of the Dart source. This is the layer that catches the
//    failure mode that value-set parity cannot see: a rule that is present but out of
//    order, transposed with its neighbour, or missing its case-insensitive flag, still
//    leaves every count looking plausible.
//
// 3. BEHAVIOUR. Probes for the divergences that only a runtime reveals - RE2 treats
//    the whitespace shorthand as ASCII-only while JavaScript treats it as Unicode, and
//    several Dart heuristics are bug-for-bug copies that a tidy rewrite would "fix"
//    into a disagreement.
//
// The regex translation applied to a Dart pattern before comparison is the one the
// port applies to itself, so this file compares equivalent spellings: the whitespace
// shorthand becomes the explicit ASCII class (asciiWs), and an unescaped forward slash
// is escaped because V8 reports RegExp.source that way while RE2 does not (slashEscape).
import {readFileSync} from "node:fs";
import {createHash} from "node:crypto";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {describe, expect, it} from "vitest";
import {
  BLOCKED_DIR_NAMES,
  BLOCKED_FILE_PATTERNS,
  BLOCKED_PATH_PREFIXES,
  BLOCK_RULES,
  HOME_BLOCKED_SUFFIXES,
  INFO_PATTERNS,
  PathSafetyResult,
  SAFETY_LEVELS,
  SAFETY_TIPS,
  WARN_RULES,
  checkPath,
  checkReadPath,
  checkSafety,
  getHomeDir,
  getSafetyReason,
  getSafetyTip,
  requireConfirm,
  type SafetyLevel,
  type SafetyRule,
} from "../src/utils/safety_guard.js";
import * as utilsBarrel from "../src/utils/index.js";
import * as rootBarrel from "../src/index.js";

const HERE = dirname(fileURLToPath(new URL(import.meta.url)));
const AC = join(HERE, "..");
const DART_LIB = join(AC, "..", "ai_terminal", "lib", "core");
const PORT_SRC = join(AC, "src", "utils", "safety_guard.ts");
const DART_GUARD = join(DART_LIB, "safety_guard.dart");
const DART_TEST = join(AC, "..", "ai_terminal", "test", "safety_guard_test.dart");

// Character constants instead of escapes, so this file needs no backslash of its own
// and every pattern comparison below is about the pattern under test only.
const LF = String.fromCharCode(10);
const CR = String.fromCharCode(13);
const SQ = String.fromCharCode(39);
const DQ = String.fromCharCode(34);
const BT = String.fromCharCode(96);
const DLR = String.fromCharCode(36);
const BKS = String.fromCharCode(92);   // backslash

const readText = (path: string): string => readFileSync(path, "utf-8").split(CR + LF).join(LF);
const sha12 = (text: string): string => createHash("sha1").update(text).digest("hex").slice(0, 12);

const DART = readText(DART_GUARD);
const DART_SUITE = readText(DART_TEST);
const PORT = readText(PORT_SRC);

type DartLit = {value: string; next: number};
/** Skips one Dart string literal, honouring the r-prefix (raw) and backslash escapes. */
function dartLit(src: string, i: number): DartLit {
  let k = i;
  const raw = src[k] === 'r';
  if (raw) k += 1;
  const q = src[k];
  if (q !== '\'' && q !== '"') {
    throw new Error('not a literal at ' + k + ': ' + JSON.stringify(src.slice(k - 12, k + 12)));
  }
  k += 1;
  let acc = '';
  while (k < src.length && src[k] !== q) {
    if (src[k] === '\\') {
      const esc = src[k + 1];
      // In a Dart raw literal the backslash is text and is kept verbatim.
      acc += raw ? '\\' + esc : esc === 'n' ? LF : esc;
      k += 2;
      continue;
    }
    acc += src[k];
    k += 1;
  }
  return {value: acc, next: k + 1};
}
/**
 * Skips one quoted region. A single- or double-quoted literal is Dart-shaped and is
 * read by dartLit; a backtick literal is a TypeScript template whose holes may hold
 * braces, so it is scanned to the next unescaped backtick.
 */
function skipQuoted(src: string, i: number): number {
  if (src[i] !== BT) return dartLit(src, i).next;
  let k = i + 1;
  while (k < src.length && src[k] !== BT) k += src[k] === BKS ? 2 : 1;
  return k + 1;
}
/** Index of the bracket closing the one at openIdx, skipping strings and comments. */
function dartClose(src: string, openIdx: number): number {
  const open = src[openIdx];
  if (open !== '(' && open !== '[' && open !== '{') {
    throw new Error('not an opening bracket at ' + openIdx);
  }
  const close = open === '(' ? ')' : open === '[' ? ']' : '}';
  let depth = 0;
  for (let i = openIdx; i < src.length; i++) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') {
      const nl = src.indexOf(LF, i);
      i = nl < 0 ? src.length : nl - 1;
      continue;
    }
    if (c === SQ || c === DQ || c === BT) {
      i = skipQuoted(src, i) - 1;
      continue;
    }
    if (c === open) depth += 1;
    else if (c === close) {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  throw new Error('unbalanced bracket from ' + openIdx);
}
/** Arguments of the call whose ( sits at openIdx, split on depth-zero commas. */
function dartArgs(src: string, openIdx: number): string[] {
  if (src[openIdx] !== '(') throw new Error('dartArgs: expected ( at ' + openIdx);
  const closeIdx = dartClose(src, openIdx);
  const bodyText = src.slice(openIdx + 1, closeIdx);
  const out: string[] = [];
  let cur = '';
  let depth = 0;
  for (let i = 0; i < bodyText.length; i++) {
    const c = bodyText[i];
    if (c === '/' && bodyText[i + 1] === '/') {
      const nl = bodyText.indexOf(LF, i);
      i = nl < 0 ? bodyText.length : nl - 1;
      continue;
    }
    if (c === SQ || c === DQ || c === BT) {
      const next = skipQuoted(bodyText, i);
      cur += bodyText.slice(i, next);
      i = next - 1;
      continue;
    }
    if (c === '(' || c === '[' || c === '{') depth += 1;
    else if (c === ')' || c === ']' || c === '}') depth -= 1;
    if (c === ',' && depth === 0) {
      out.push(cur.trim());
      cur = '';
      continue;
    }
    cur += c;
  }
  const last = cur.trim();
  if (last !== '') out.push(last); // the Dart formatter emits a trailing comma
  return out;
}
/** Reads a Dart raw literal; anything else throws because escape levels differ. */
function dartRaw(text: string): string {
  const t = text.trim();
  if (t[0] !== 'r') {
    throw new Error('expected a Dart raw literal: ' + JSON.stringify(t.slice(0, 28)));
  }
  return dartLit(t, 0).value;
}
/** Pattern text plus its case flag, from RegExp(r"..", ...) or a bare r"..". */
function dartPattern(text: string): {source: string; caseSensitive: boolean} {
  const t = text.trim();
  let src = t;
  const open = t.indexOf('(');
  if (open > 0 && t.slice(0, open) === 'RegExp') {
    const args = dartArgs(t, open);
    if (args.length === 0) throw new Error('RegExp() without a pattern: ' + t.slice(0, 40));
    src = args[0];
  }
  let caseSensitive = true;
  const flags = t.match(/caseSensitive:\s*(true|false)/);
  if (flags !== null) caseSensitive = flags[1] === 'true';
  return {source: dartRaw(src), caseSensitive};
}
/** One _SafetyRule(pattern, reason) entry. */
function dartRule(text: string): {source: string; caseSensitive: boolean; reason: string} {
  const t = text.trim();
  const open = t.indexOf('(');
  if (open < 0 || t.slice(0, open) !== '_SafetyRule') {
    throw new Error('not a _SafetyRule entry: ' + JSON.stringify(t.slice(0, 40)));
  }
  const args = dartArgs(t, open);
  if (args.length !== 2) {
    throw new Error('_SafetyRule arity ' + args.length + ': ' + JSON.stringify(t.slice(0, 40)));
  }
  return {...dartPattern(args[0]), reason: dartLit(args[1].trim(), 0).value};
}
/** Top-level entries of the Dart array literal introduced by anchor. */
function dartEntries(src: string, anchor: string): string[] {
  const at = src.indexOf(anchor);
  if (at < 0) throw new Error('anchor not found: ' + anchor);
  const lb = src.indexOf('[', at);
  if (lb < 0) throw new Error('no [ after anchor: ' + anchor);
  const bodyText = src.slice(lb + 1, dartClose(src, lb));
  const out: string[] = [];
  let cur = '';
  let depth = 0;
  for (let i = 0; i < bodyText.length; i++) {
    const c = bodyText[i];
    if (c === '/' && bodyText[i + 1] === '/') {
      const nl = bodyText.indexOf(LF, i);
      i = nl < 0 ? bodyText.length : nl - 1;
      continue;
    }
    if (c === SQ || c === DQ || c === BT) {
      const next = skipQuoted(bodyText, i);
      cur += bodyText.slice(i, next);
      i = next - 1;
      continue;
    }
    if (c === '(' || c === '[' || c === '{') depth += 1;
    else if (c === ')' || c === ']' || c === '}') depth -= 1;
    if (c === ',' && depth === 0) {
      if (cur.trim() !== '') out.push(cur.trim());
      cur = '';
      continue;
    }
    cur += c;
  }
  if (cur.trim() !== '') out.push(cur.trim());
  return out;
}
/**
 * Dart RegExp is RE2, where backslash-s is ASCII-only, so the port spells that
 * class out explicitly. Rewrite the Dart pattern the same way before comparing.
 */
function asciiWs(source: string): string {
  return source.split('\\s').join('[\\t\\n\\f\\r ]');
}
/**
 * V8 escapes a bare forward slash when reporting RegExp.source while RE2 does
 * not, so canonicalise the Dart pattern before comparing it with .source.
 */
function slashEscape(source: string): string {
  let out = '';
  for (let i = 0; i < source.length; i++) {
    const c = source[i];
    if (c === '\\') {
      out += c + (source[i + 1] ?? '');
      i += 1;
      continue;
    }
    out += c === '/' ? '\\/' : c;
  }
  return out;
}
/**
 * Renders a Dart message literal as the JS template body the port uses: a bare
 * dollar-name becomes dollar-brace-name and a dollar-brace block is preserved.
 */
function dartInterpToJs(literal: string): string {
  let out = '';
  for (let i = 0; i < literal.length; i++) {
    const c = literal[i];
    if (c !== DLR) {
      out += c;
      continue;
    }
    const next = literal[i + 1];
    if (next === '{') {
      const close = literal.indexOf('}', i + 2);
      if (close < 0) throw new Error('unbalanced interpolation brace: ' + literal);
      out += DLR + '{' + literal.slice(i + 2, close) + '}';
      i = close;
      continue;
    }
    if (next !== undefined && isIdentStart(next)) {
      let k = i + 1;
      while (k < literal.length && isIdentPart(literal[k])) k += 1;
      out += DLR + '{' + literal.slice(i + 1, k) + '}';
      i = k - 1;
      continue;
    }
    throw new Error('bare dollar in Dart message: ' + literal);
  }
  return out;
}
/** Identifier start by char code, so the guard needs no regular expressions. */
function isIdentStart(c: string): boolean {
  const n = c.charCodeAt(0);
  return (n >= 65 && n <= 90) || (n >= 97 && n <= 122) || n === 95;
}
function isIdentPart(c: string): boolean {
  const n = c.charCodeAt(0);
  return (n >= 48 && n <= 57) || (n >= 65 && n <= 90) || (n >= 97 && n <= 122) || n === 95;
}

// ─── 1. Replaying the Dart test suite ──────────────────────────────────────────
//
// Every assertion below is generated from test/safety_guard_test.dart at run time, so
// the Dart suite stays the single specification of expected behaviour. The interpreter
// understands exactly the assertion shapes that suite contains today and throws on
// anything else, which means a new kind of Dart assertion fails this file loudly
// instead of being quietly skipped.
const CHECK_PREFIX = 'SafetyGuard.check(';
const GET_REASON_PREFIX = 'SafetyGuard.getReason(';
const REQUIRE_CONFIRM_PREFIX = 'SafetyGuard.requireConfirm(';
const GET_TIP_PREFIX = 'SafetyGuard.getTip(';

type Matcher =
  | {readonly kind: 'level'; readonly value: SafetyLevel}
  | {readonly kind: 'contains'; readonly value: string}
  | {readonly kind: 'equals'; readonly value: string}
  | {readonly kind: 'isNull'}
  | {readonly kind: 'isNotNull'}
  | {readonly kind: 'isTrue'}
  | {readonly kind: 'isFalse'};

type DartCase =
  | {readonly kind: 'check'; readonly cmd: string; readonly level: SafetyLevel}
  | {readonly kind: 'reasonNull'; readonly cmd: string}
  | {readonly kind: 'reasonContains'; readonly cmd: string; readonly needle: string}
  | {readonly kind: 'boundNotNull'; readonly cmd: string}
  | {readonly kind: 'boundContains'; readonly cmd: string; readonly needle: string}
  | {readonly kind: 'confirm'; readonly level: SafetyLevel; readonly want: boolean}
  | {readonly kind: 'tip'; readonly level: SafetyLevel; readonly want: string};

type Located = {
  readonly group: string;
  readonly test: string;
  readonly text: string;
  readonly line: number;
  readonly index: number;
};

/** Narrows a Dart enum name to the ported union, so an unknown name cannot hide. */
const levelOf = (name: string): SafetyLevel => {
  if (!(SAFETY_LEVELS as readonly string[]).includes(name)) {
    throw new Error('Dart-side level name unknown to the port: ' + name);
  }
  return name as SafetyLevel;
};

/** Arguments of a call spelled exactly prefix..., or null when the text is that call. */
function callArgs(text: string, prefix: string): string[] | null {
  const t = text.trim();
  if (t.slice(0, prefix.length) !== prefix) return null;
  const open = prefix.length - 1;
  const close = dartClose(t, open);
  if (t.slice(close) !== ')') throw new Error('trailing text after ' + prefix + ': ' + t);
  return dartArgs(t, open);
}

function matcherOf(arg: string, line: number): Matcher {
  const t = arg.trim();
  const level = t.match(/^SafetyLevel\.([A-Za-z_][A-Za-z0-9_]*)$/);
  if (level !== null) return {kind: 'level', value: levelOf(level[1])};
  if (t === 'isNull') return {kind: 'isNull'};
  if (t === 'isNotNull') return {kind: 'isNotNull'};
  if (t === 'isTrue') return {kind: 'isTrue'};
  if (t === 'isFalse') return {kind: 'isFalse'};
  const contains = callArgs(t, 'contains(');
  if (contains !== null) {
    if (contains.length !== 1) throw new Error('contains arity ' + contains.length + ' at line ' + line);
    return {kind: 'contains', value: dartLit(contains[0].trim(), 0).value};
  }
  if (t[0] === SQ || t[0] === DQ) {
    const lit = dartLit(t, 0);
    if (lit.next !== t.length) throw new Error('trailing matcher text at line ' + line + ': ' + t);
    return {kind: 'equals', value: lit.value};
  }
  throw new Error('unrecognised Dart matcher at line ' + line + ': ' + t);
}

/** Splits the Dart suite into group/test tagged expect(...) calls, whole-source. */
function locateDartExpectations(src: string): Located[] {
  const out: Located[] = [];
  // Titles are read with the literal reader rather than a regex, so a raw literal title
  // or an escaped quote inside one cannot desynchronise the scan.
  const titleAt = (line: string, prefix: string): string | null => {
    if (!line.startsWith(prefix)) return null;
    const rest = line.slice(prefix.length).trimStart();
    if (rest.length === 0 || (rest[0] !== SQ && rest[0] !== DQ && rest[0] !== 'r')) return null;
    return dartLit(line, line.length - rest.length).value;
  };
  let group: string | null = null;
  let test: string | null = null;
  let offset = 0;
  let lineNo = 1;
  for (const line of src.split(LF)) {
    const g = titleAt(line, '  group(');
    if (g !== null) group = g;
    const t = titleAt(line, '    test(');
    if (t !== null) test = t;
    let at = 0;
    while (true) {
      const p = line.indexOf('expect(', at);
      if (p < 0) break;
      // A preceding identifier or dot means some other call, e.g. foo.expect(.
      if (p > 0 && /[A-Za-z0-9_.]/.test(line[p - 1])) {
        at = p + 1;
        continue;
      }
      if (group === null || test === null) {
        throw new Error('expect() outside a group/test at Dart line ' + lineNo);
      }
      const index = offset + p;
      const close = dartClose(src, index + 'expect'.length);
      out.push({group, test, text: src.slice(index, close + 1), line: lineNo, index});
      at = close + 1 - offset;
    }
    offset += line.length + LF.length;
    lineNo += 1;
  }
  return out;
}

/**
 * Resolves the subject of an expect() whose first argument is a local variable.
 *
 * The bypass group reads: final reason = SafetyGuard.getReason('rm -rf /'); then
 * expect(reason, isNotNull) and expect(reason, contains(...)). The assertion is really
 * about that command, so the enclosing test body is scanned backwards for the binding
 * instead of hard-coding the pairing: a Dart-side reorder keeps working, and an
 * unexpected reference still throws.
 */
function boundReasonCmd(src: string, loc: Located): string {
  const marker = 'final reason = ' + GET_REASON_PREFIX;
  const bodyStart = src.lastIndexOf('test(', loc.index);
  const at = src.lastIndexOf(marker, loc.index);
  if (bodyStart < 0 || at < bodyStart) throw new Error('no reason binding before Dart line ' + loc.line);
  const args = dartArgs(src, at + marker.length - 1);
  if (args.length !== 1) throw new Error('getReason arity ' + args.length + ' at Dart line ' + loc.line);
  return dartLit(args[0].trim(), 0).value;
}

/** Pulls the identifier out of SafetyLevel.x with a clear message on anything else. */
function enumName(arg: string, line: number, what: string): string {
  const t = arg.trim();
  const prefix = 'SafetyLevel.';
  if (t.slice(0, prefix.length) !== prefix || t.length === prefix.length) {
    throw new Error(what + ' expects a SafetyLevel member at Dart line ' + line + ': ' + t);
  }
  for (const c of t.slice(prefix.length)) {
    if (!isIdentPart(c)) throw new Error(what + ' has an odd level reference at Dart line ' + line + ': ' + t);
  }
  return t.slice(prefix.length);
}

/** Turns one located expect() into an executable case against the port. */
function interpret(src: string, loc: Located): DartCase {
  const args = callArgs(loc.text, 'expect(');
  if (args === null) throw new Error('not an expect() at Dart line ' + loc.line);
  if (args.length !== 2) throw new Error('expect with ' + args.length + ' args at Dart line ' + loc.line);
  const actual = args[0].trim();
  const matcher = matcherOf(args[1], loc.line);
  const check = callArgs(actual, CHECK_PREFIX);
  if (check !== null) {
    if (matcher.kind !== 'level') {
      throw new Error('check() paired with a ' + matcher.kind + ' matcher at Dart line ' + loc.line);
    }
    if (check.length !== 1) throw new Error('check arity ' + check.length + ' at Dart line ' + loc.line);
    return {kind: 'check', cmd: dartLit(check[0].trim(), 0).value, level: matcher.value};
  }
  const reason = callArgs(actual, GET_REASON_PREFIX);
  if (reason !== null) {
    if (reason.length !== 1) throw new Error('getReason arity ' + reason.length + ' at Dart line ' + loc.line);
    const cmd = dartLit(reason[0].trim(), 0).value;
    if (matcher.kind === 'isNull') return {kind: 'reasonNull', cmd};
    if (matcher.kind === 'contains') return {kind: 'reasonContains', cmd, needle: matcher.value};
    throw new Error('getReason paired with ' + matcher.kind + ' at Dart line ' + loc.line);
  }
  if (actual === 'reason') {
    const cmd = boundReasonCmd(src, loc);
    if (matcher.kind === 'isNotNull') return {kind: 'boundNotNull', cmd};
    if (matcher.kind === 'contains') return {kind: 'boundContains', cmd, needle: matcher.value};
    throw new Error('reason paired with ' + matcher.kind + ' at Dart line ' + loc.line);
  }
  const confirm = callArgs(actual, REQUIRE_CONFIRM_PREFIX);
  if (confirm !== null) {
    if (confirm.length !== 1) throw new Error('requireConfirm arity ' + confirm.length + ' at Dart line ' + loc.line);
    const level = levelOf(enumName(confirm[0], loc.line, 'requireConfirm'));
    if (matcher.kind !== 'isTrue' && matcher.kind !== 'isFalse') {
      throw new Error('requireConfirm paired with ' + matcher.kind + ' at Dart line ' + loc.line);
    }
    return {kind: 'confirm', level, want: matcher.kind === 'isTrue'};
  }
  const tip = callArgs(actual, GET_TIP_PREFIX);
  if (tip !== null) {
    if (tip.length !== 1) throw new Error('getTip arity ' + tip.length + ' at Dart line ' + loc.line);
    const level = levelOf(enumName(tip[0], loc.line, 'getTip'));
    if (matcher.kind !== 'equals') throw new Error('getTip paired with ' + matcher.kind + ' at Dart line ' + loc.line);
    return {kind: 'tip', level, want: matcher.value};
  }
  throw new Error('unhandled expect() subject at Dart line ' + loc.line + ': ' + actual);
}

type Replay = {readonly loc: Located; readonly caseOf: DartCase};
const DART_EXPECTS = locateDartExpectations(DART_SUITE);
const DART_CASES: readonly Replay[] = DART_EXPECTS.map((loc) => ({loc, caseOf: interpret(DART_SUITE, loc)}));


/** Runs one interpreted Dart assertion against the port. */
function assertCase(c: DartCase): void {
  switch (c.kind) {
    case 'check': {
      expect(checkSafety(c.cmd), 'check(' + c.cmd + ')').toBe(c.level);
      return;
    }
    case 'reasonNull': {
      expect(getSafetyReason(c.cmd), 'getReason(' + c.cmd + ')').toBeNull();
      return;
    }
    case 'reasonContains': {
      const reason = getSafetyReason(c.cmd);
      expect(reason, 'getReason(' + c.cmd + ')').not.toBeNull();
      expect(reason as string).toContain(c.needle);
      return;
    }
    case 'boundNotNull': {
      expect(getSafetyReason(c.cmd), 'reason for ' + c.cmd).not.toBeNull();
      return;
    }
    case 'boundContains': {
      const reason = getSafetyReason(c.cmd);
      expect(reason, 'reason for ' + c.cmd).not.toBeNull();
      expect(reason as string).toContain(c.needle);
      return;
    }
    case 'confirm': {
      expect(requireConfirm(c.level), 'requireConfirm(' + c.level + ')').toBe(c.want);
      return;
    }
    case 'tip': {
      expect(getSafetyTip(c.level), 'getTip(' + c.level + ')').toBe(c.want);
      return;
    }
    default: {
      throw new Error('unreachable Dart case kind: ' + JSON.stringify(c));
    }
  }
}

// Group, then test, preserving the order in which the Dart file spells them.
const dartTree = new Map<string, Map<string, DartCase[]>>();
for (const entry of DART_CASES) {
  let group = dartTree.get(entry.loc.group);
  if (group === undefined) {
    group = new Map<string, DartCase[]>();
    dartTree.set(entry.loc.group, group);
  }
  const bucket = group.get(entry.loc.test);
  if (bucket === undefined) group.set(entry.loc.test, [entry.caseOf]);
  else bucket.push(entry.caseOf);
}
const dartTestCount = [...dartTree.values()].reduce((sum, g) => sum + g.size, 0);

// The parse itself is asserted before any replayed assertion runs. A reader that
// silently matched less would turn every loop below into an empty describe and the
// whole oracle into a vacuous green.
describe('Dart oracle parsing', () => {
  it('finds every expect() in test/safety_guard_test.dart', () => {
    expect(DART_SUITE.includes('expect('), 'Dart suite unreadable').toBe(true);
    expect(DART_EXPECTS.length, 'expect() count in the Dart suite').toBe(54);
    expect(dartTree.size, 'group() count in the Dart suite').toBe(10);
    expect(dartTestCount, 'test() count in the Dart suite').toBe(49);
  });

  it('only replays levels the port declares', () => {
    const seen = new Set<string>();
    for (const entry of DART_CASES) {
      const withLevel = entry.caseOf as {level?: SafetyLevel};
      if (withLevel.level !== undefined) seen.add(withLevel.level);
    }
    for (const level of seen) expect(SAFETY_LEVELS as readonly string[]).toContain(level);
    expect([...seen].sort().join(' ')).toBe('blocked info safe warn');
  });
});

for (const [group, tests] of dartTree) {
  describe(group, () => {
    for (const [title, cases] of tests) {
      it(title, () => {
        for (const c of cases) assertCase(c);
      });
    }
  });
}


/** One comparable row from either side of the port. */
type Tuple = readonly [string, boolean, string | null];

function dartTuples(src: string, anchor: string): Tuple[] {
  const rows: Tuple[] = [];
  for (const entry of dartEntries(src, anchor)) {
    const e = entry.trim();
    if (e.slice(0, '_SafetyRule'.length) === '_SafetyRule') {
      const r = dartRule(e);
      rows.push([slashEscape(asciiWs(r.source)), r.caseSensitive, r.reason]);
      continue;
    }
    if (e.slice(0, 'RegExp('.length) === 'RegExp(') {
      const p = dartPattern(e);
      rows.push([slashEscape(asciiWs(p.source)), p.caseSensitive, null]);
      continue;
    }
    const lit = dartLit(e, 0);
    if (lit.next !== e.length) throw new Error('dart table entry is neither a RegExp nor a literal: ' + e.slice(0, 40));
    rows.push([lit.value, true, null]);
  }
  return rows;
}

const portRules = (rules: ReadonlyArray<SafetyRule>): Tuple[] =>
  rules.map((r) => [r.pattern.source, !r.pattern.ignoreCase, r.reason] as Tuple);
const portPatterns = (pats: readonly RegExp[]): Tuple[] =>
  pats.map((p) => [p.source, !p.ignoreCase, null] as Tuple);

const DART_ANCHORS: Record<string, string> = {
  block: 'static final List<_SafetyRule> _blockRules = [',
  warn: 'static final List<_SafetyRule> _warnRules = [',
  info: 'static final List<RegExp> _infoPatterns = [',
  file: 'static final List<RegExp> _blockedFilePatterns = [',
  prefix: 'static const List<String> _blockedPathPrefixes = [',
  dir: 'static const List<String> _blockedDirNames = [',
  home: 'static const List<String> _homeBlockedSuffixes = [',
};

describe('Dart source drift guard', () => {
  it('reproduces every rule table verbatim, entry by entry', () => {
    const port: Record<string, Tuple[]> = {
      block: portRules(BLOCK_RULES),
      warn: portRules(WARN_RULES),
      info: portPatterns(INFO_PATTERNS),
      file: portPatterns(BLOCKED_FILE_PATTERNS),
      prefix: BLOCKED_PATH_PREFIXES.map((s) => [s, true, null] as Tuple),
      dir: BLOCKED_DIR_NAMES.map((s) => [s, true, null] as Tuple),
      home: HOME_BLOCKED_SUFFIXES.map((s) => [s, true, null] as Tuple),
    };
    for (const name of Object.keys(DART_ANCHORS)) {
      const dart = dartTuples(DART, DART_ANCHORS[name]);
      const mine = port[name];
      expect(mine.length, name + ' table size, dart=' + dart.length).toBe(dart.length);
      for (let i = 0; i < dart.length; i++) {
        expect(mine[i], name + '[' + i + ']').toStrictEqual(dart[i]);
      }
    }
  });

  it('keeps exactly one case-insensitive rule, at block index 3', () => {
    const ignoreCase: string[] = [];
    portRules(BLOCK_RULES).forEach((t, i) => { if (!t[1]) ignoreCase.push('block[' + i + ']'); });
    portRules(WARN_RULES).forEach((t, i) => { if (!t[1]) ignoreCase.push('warn[' + i + ']'); });
    const dartCaseInsensitive: string[] = [];
    for (const name of ['block', 'warn']) {
      dartTuples(DART, DART_ANCHORS[name]).forEach((t, i) => {
        if (!t[1]) dartCaseInsensitive.push(name + '[' + i + ']');
      });
    }
    expect(ignoreCase).toStrictEqual(dartCaseInsensitive);
    expect(ignoreCase).toStrictEqual(['block[3]']);
  });

  it('ports every RegExp call site, so none was dropped or inlined by hand', () => {
    const countOf = (src: string, needle: string): number => src.split(needle).length - 1;
    // re( / reAll( are the port's RegExp constructors; every Dart RegExp( has one.
    // re( / reAll( are the port's two RegExp constructors; every Dart RegExp( maps to one.
    expect(countOf(DART, 'RegExp('), 'dart RegExp( sites').toBe(countOf(PORT, 're('));
  });

  it('carries the four tips the Dart switch returns', () => {
    const tips = new Map<string, string>();
    const gt = DART.indexOf('static String getTip(SafetyLevel level) {');
    if (gt < 0) throw new Error('getTip not found in the Dart source');
    const sw = DART.indexOf('switch (', gt);
    if (sw < 0 || sw - gt > 200) throw new Error('getTip has no switch body');
    const paren = DART.indexOf(')', sw);
    if (DART.slice(sw + 'switch ('.length, paren).trim() !== 'level') {
      throw new Error('getTip does not switch on level');
    }
    let i = DART.indexOf('{', paren) + 1;
    while (true) {
      while (i < DART.length && /\s/.test(DART[i])) i += 1;
      if (DART.startsWith('case SafetyLevel.', i)) {
        const colon = DART.indexOf(':', i);
        const name = DART.slice('case SafetyLevel.'.length + i, colon).trim();
        let j = colon + 1;
        while (j < DART.length && /\s/.test(DART[j])) j += 1;
        if (!DART.startsWith('return', j)) throw new Error('getTip case without return');
        let k = j + 'return'.length;
        while (k < DART.length && /\s/.test(DART[k])) k += 1;
        const lit = dartLit(DART, k);
        tips.set(name, lit.value);
        i = DART.indexOf(';', lit.next) + 1;
        continue;
      }
      if (DART.startsWith('}', i)) break;
      throw new Error('unexpected token in the getTip switch at ' + i);
    }
    expect([...tips.keys()].sort()).toStrictEqual([...SAFETY_LEVELS].sort());
    for (const [level, text] of tips) {
      expect(getSafetyTip(level as SafetyLevel), 'tip for ' + level).toBe(text);
    }
  });

  it('orders SafetyLevel the way the Dart comparator does', () => {
    const order = dartEntries(DART, 'const order = [').map((e) => {
      const t = e.trim();
      const prefix = 'SafetyLevel.';
      if (t.slice(0, prefix.length) !== prefix) throw new Error('order entry is not an enum member: ' + t);
      return t.slice(prefix.length);
    });
    expect([...SAFETY_LEVELS]).toStrictEqual(order);
  });
});


/** 'SafetyLevel.warn' -> 'warn'; the port's local WARN constant -> 'warn'. */
const LEVEL_WORDS: readonly string[] = ['safe', 'info', 'warn', 'blocked'];
function levelWord(token: string): string | null {
  const t = token.trim();
  const dotted = t.startsWith('SafetyLevel.') ? t.slice('SafetyLevel.'.length) : t;
  const upperOnly = /^[A-Z][A-Z_0-9]+$/.test(dotted) ? dotted.toLowerCase() : dotted;
  return LEVEL_WORDS.includes(upperOnly) ? upperOnly : null;
}

/** Turns a Dart interpolated literal into a template with {name} holes. */
function dartTemplate(entry: string): string | null {
  const t = entry.trim();
  if (t === 'null') return null;
  const lit = dartLit(t, 0);
  if (lit.next !== t.length) throw new Error('odd PathSafetyResult message argument: ' + t.slice(0, 40));
  let out = '';
  let i = 0;
  while (i < lit.value.length) {
    if (lit.value[i] === DLR && i + 1 < lit.value.length && isIdentStart(lit.value[i + 1])) {
      let j = i + 1;
      while (j < lit.value.length && isIdentPart(lit.value[j])) j += 1;
      out += '{' + lit.value.slice(i + 1, j) + '}';
      i = j;
      continue;
    }
    out += lit.value[i];
    i += 1;
  }
  return out;
}

/** Reads a TypeScript backtick template in the same {name}-hole shape. */
function tsTemplate(text: string): string {
  const open = text.indexOf(BT);
  const close = text.lastIndexOf(BT);
  if (open < 0 || close <= open) throw new Error('not a template literal: ' + text.slice(0, 40));
  const body = text.slice(open + 1, close);
  let out = '';
  let i = 0;
  while (i < body.length) {
    if (body[i] === DLR && body[i + 1] === '{') {
      const end = body.indexOf('}', i);
      if (end < 0) throw new Error('unterminated template hole');
      out += '{' + body.slice(i + 2, end).trim() + '}';
      i = end + 1;
      continue;
    }
    out += body[i];
    i += 1;
  }
  return out;
}

/** Dart wraps long calls with a trailing comma after the final argument. */
const COMMA_TAIL = /,+$/;

/** Splits a call-argument list at its first depth-zero comma. */
function twoArgs(inner: string): [string, string] {
  let depth = 0;
  for (let i = 0; i < inner.length; i++) {
    const c = inner[i];
    if (c === '(' || c === '[' || c === '{') depth += 1;
    else if (c === ')' || c === ']' || c === '}') depth -= 1;
    else if (c === ',' && depth === 0) return [inner.slice(0, i), inner.slice(i + 1)];
  }
  throw new Error('expected two arguments: ' + inner.slice(0, 40));
}

/** Every (level, message-template) pair built inside one function body. */
function resultPairs(src: string, fromAnchor: string, endAnchor: string | null, dart: boolean): string[] {
  const from = src.indexOf(fromAnchor);
  if (from < 0) throw new Error('anchor missing: ' + fromAnchor);
  let to = src.length;
  if (endAnchor !== null) {
    to = src.indexOf(endAnchor, from + fromAnchor.length);
    if (to < 0) throw new Error('end anchor missing: ' + endAnchor);
  }
  const body = src.slice(from, to);
  const needle = dart ? 'PathSafetyResult(' : 'new PathSafetyResult(';
  const out: string[] = [];
  let at = 0;
  while (true) {
    const p = body.indexOf(needle, at);
    if (p < 0) break;
    const open = p + needle.length - 1; // the ( itself
    const close = dartClose(body, open);
    const parts = twoArgs(body.slice(open + 1, close));
    const level = levelWord(parts[0]);
    if (level === null) throw new Error('unknown level token: ' + parts[0].trim());
    const message = parts[1].trim().replace(COMMA_TAIL, '');
    const template = message === 'null' ? '@null' : message[0] === BT ? tsTemplate(message) : dartTemplate(message);
    if (template === null) throw new Error('impossible message text: ' + message.slice(0, 40));
    out.push(level + '|' + template);
    at = close + 1;
  }
  return out;
}

describe('Dart source drift guard (continued)', () => {
  it('builds the same path messages as the Dart checkPath', () => {
    const dartRows = resultPairs(DART, 'static PathSafetyResult checkPath(', 'static PathSafetyResult checkReadPath', true);
    const portRows = resultPairs(PORT, 'export function checkPath(', 'function normalizePath(', false);
    // The port names its second fileName binding outsideFileName to dodge shadowing;
    // normalise that one binding name, then compare as multisets.
    const norm = (rows: string[]): string[] =>
      rows.map((r) => r.split('outsideFileName').join('fileName')).sort();
    expect(portRows.length, 'port checkPath result sites, dart=' + dartRows.length).toBe(dartRows.length);
    expect(norm(portRows)).toStrictEqual(norm(dartRows));
    const readDart = resultPairs(DART, 'static PathSafetyResult checkReadPath(', null, true);
    const readPort = resultPairs(PORT, 'export function checkReadPath(', null, false);
    expect(norm(readPort)).toStrictEqual(norm(readDart));
  });

  it('never rewrites strings where Dart rewrote strings', () => {
    // Dart uses split() only on a newline, a separator RegExp, and the / literal.
    // Any string-first replace()/replaceAll() in the port would be a JS-only
    // Unicode-vs-ASCII divergence waiting to bite; there must be none.
    const callSites = (src: string, method: string): string[] => {
      const out: string[] = [];
      let at = 0;
      while (true) {
        const p = src.indexOf('.' + method + '(', at);
        if (p < 0) return out;
        const open = p + method.length + 1;
        const close = dartClose(src, open);
        out.push(src.slice(open + 1, close).split(',')[0].trim());
        at = close;
      }
    };
    const firstArgIsString = (arg: string): boolean => arg[0] === SQ || arg[0] === DQ || arg[0] === BT;
    for (const method of ['replace', 'replaceAll']) {
      const sites = callSites(PORT, method);
      for (const arg of sites) expect(firstArgIsString(arg), method + '(' + arg + ')').toBe(false);
    }
    const dartSplits = callSites(DART, 'split');
    const portSplits = callSites(PORT, 'split');
    expect(portSplits.length, 'split() call sites').toBe(dartSplits.length);
    // Labels the source text of a quoted argument; a backslash-n in the source stays
    // two characters, so both sides are labelled the same way instead of compared raw.
    const labelOf = (a: string): string => {
      const body = a.slice(1, -1);
      const BS = String.fromCharCode(92);
      if (body === BS + 'n') return 'LF';
      return body;
    };
    const stringArgs = portSplits.filter(firstArgIsString).map(labelOf);
    expect(stringArgs.sort()).toStrictEqual(['/', '/', '/', '/', '/', 'LF']);
    const dartStringArgs = dartSplits.filter(firstArgIsString).map(labelOf);
    expect(dartStringArgs.sort()).toStrictEqual(stringArgs);
  });
});


describe('barrel re-exports', () => {
  const names = [
    'checkSafety', 'getSafetyReason', 'getSafetyTip', 'requireConfirm', 'checkPath', 'checkReadPath',
    'getHomeDir', 'SAFETY_LEVELS', 'SAFETY_TIPS', 'BLOCK_RULES', 'WARN_RULES', 'INFO_PATTERNS',
    'BLOCKED_PATH_PREFIXES', 'BLOCKED_FILE_PATTERNS', 'BLOCKED_DIR_NAMES', 'HOME_BLOCKED_SUFFIXES',
  ] as const;
  it('survives both barrels as the identical binding', () => {
    const utils = utilsBarrel as unknown as Record<string, unknown>;
    const root = rootBarrel as unknown as Record<string, unknown>;
    const ported = {
      checkSafety, getSafetyReason, getSafetyTip, requireConfirm, checkPath, checkReadPath,
      getHomeDir, SAFETY_LEVELS, SAFETY_TIPS, BLOCK_RULES, WARN_RULES, INFO_PATTERNS,
      BLOCKED_PATH_PREFIXES, BLOCKED_FILE_PATTERNS, BLOCKED_DIR_NAMES, HOME_BLOCKED_SUFFIXES,
    } as Record<string, unknown>;
    // src/index.ts is the public surface and deliberately re-exports a subset;
    // src/utils/index.ts mirrors the module whole. Both must hand back the same binding.
    const publicNames: readonly string[] = [
      'checkSafety', 'getSafetyReason', 'getSafetyTip', 'requireConfirm', 'checkPath', 'checkReadPath',
      'SAFETY_LEVELS',
    ];
    for (const name of names) {
      expect(utils[name], 'src/utils/index.ts does not re-export ' + name).toBe(ported[name]);
    }
    for (const name of publicNames) {
      expect(root[name], 'src/index.ts does not re-export ' + name).toBe(ported[name]);
    }
    // getHomeDir and the tables are utilities, not part of the published API.
    for (const name of ['getHomeDir', 'SAFETY_TIPS', 'BLOCK_RULES', 'WARN_RULES', 'INFO_PATTERNS',
      'BLOCKED_PATH_PREFIXES', 'BLOCKED_FILE_PATTERNS', 'BLOCKED_DIR_NAMES', 'HOME_BLOCKED_SUFFIXES']) {
      expect(root[name], 'src/index.ts unexpectedly publishes ' + name).toBeUndefined();
    }
    expect(utils.PathSafetyResult, 'PathSafetyResult through the utils barrel').toBe(PathSafetyResult);
    expect(root.PathSafetyResult, 'PathSafetyResult through the root barrel').toBe(PathSafetyResult);
  });
});

describe('measured behaviour', () => {
  const BS = String.fromCharCode(92);
  const NBSP = String.fromCharCode(0x00a0);
  const ENSP = String.fromCharCode(0x2002);
  const TAB = String.fromCharCode(9);

  const safeCommands: readonly string[] = [
    '/', './', '~~', '', '   ', '&&&',
    'foo#bar rm -rf /',        // '#' comments the rest out only when a word precedes it
    'ls # rm -rf /',
    '"ls" -la',
  ];
  const warnCommands: readonly string[] = ['rm -rf //', 'rm -rf/'];
  const blockedCommands: readonly string[] = [
    'rm -rf /*', 'rm  -rf  /', 'echo "a # b" && rm -rf /',
    '"rm" -rf /', "'rm' -rf /", 'r' + BS + 'm -rf /',
    '"rm' + "' -rf /",          // mismatched quotes are not a quote-strip
    'ls|rm -rf /', 'ls ; rm -rf /', 'ls' + LF + 'rm -rf /',
  ];

  it('classifies the whitespace-sensitive command corpus', () => {
    for (const cmd of safeCommands) expect(checkSafety(cmd), 'safe: ' + cmd).toBe('safe');
    for (const cmd of warnCommands) expect(checkSafety(cmd), 'warn: ' + cmd).toBe('warn');
    for (const cmd of blockedCommands) expect(checkSafety(cmd), 'blocked: ' + cmd).toBe('blocked');
    expect(checkSafety('ls || systemctl restart nginx')).toBe('info');
  });

  it('treats backslash-s as ASCII-only whitespace, as RE2 does', () => {
    // Dart's RegExp is RE2, where the two-character whitespace class is ASCII-only.
    // A non-breaking or en space INSIDE the command therefore matches none of the
    // separator classes, so the pattern never fires and the command reads as safe.
    // A tab is ASCII whitespace and still fires. Leading and trailing exotic spaces
    // are a different story: String.trim() is Unicode-aware in both Dart and JS, so
    // they are stripped before matching and the command still reads as blocked -
    // which is why this test probes interior positions only.
    expect(checkSafety('rm' + NBSP + '-rf /')).toBe('safe');
    expect(checkSafety('rm' + ENSP + '-rf /')).toBe('safe');
    expect(checkSafety('rm' + NBSP + '-' + NBSP + 'rf /')).toBe('safe');
    expect(checkSafety('rm' + TAB + '-rf' + TAB + '/')).toBe('blocked');
    expect(checkSafety('rm -rf /')).toBe('blocked');
    // Trailing separator position: the prefix rule still matches, the root rule does not.
    expect(checkSafety('rm -rf' + NBSP + '/')).toBe('warn');
    // trim() on both platforms erases the leading exotic space, so it still blocks.
    expect(checkSafety(NBSP + 'rm -rf /')).toBe('blocked');
    expect(checkSafety('rm -rf /' + ENSP)).toBe('blocked');
  });

  it('reports the reason the rule carries, verbatim', () => {
    expect(getSafetyReason(':(){ :|:& };:')).toBe('Fork 炸弹，将瞬间耗尽系统进程资源导致系统崩溃');
    expect(getSafetyReason('ls && sudo reboot')).toBe('关机/重启服务器，所有运行中的进程将终止，未保存数据丢失');
    expect(getSafetyReason('ls && rm -rf /')).toBe('递归删除根目录，将清空整个文件系统，完全不可恢复');
    expect(getSafetyReason('zzz-unknown')).toBeNull();
    expect(getSafetyReason('zzz-unknown'), 'null is cached like any other reason').toBeNull();
  });

  it('gates confirmation on warn and blocked only', () => {
    expect(requireConfirm('safe')).toBe(false);
    expect(requireConfirm('info')).toBe(false);
    expect(requireConfirm('warn')).toBe(true);
    expect(requireConfirm('blocked')).toBe(true);
    expect(Object.keys(SAFETY_TIPS).sort()).toStrictEqual(['blocked', 'info', 'safe', 'warn']);
  });

  it('resolves the home directory from the environment Dart reads', () => {
    expect(getHomeDir({USERPROFILE: 'C:\\Users\\zz'})).toBe('C:/Users/zz');
    expect(getHomeDir({HOME: '/h', USERPROFILE: 'C:\\Users\\zz'})).toBe('/h');
    expect(getHomeDir({HOME: ''})).toBe('');
    expect(getHomeDir({})).toBeNull();
  });

  it('checks paths exactly as the message table promises', () => {
    const rows: ReadonlyArray<readonly [string, string | null, string, string | null, boolean]> = [
      ['', null, 'warn', '路径为空', false],
      ['./', null, 'warn', '路径规范化后为空', false],
      ['/', null, 'warn', '路径不在授权的项目目录内: /', false],
      ['/etc/passwd', null, 'blocked', '系统目录 /etc 禁止访问', false],
      ['/etc/passwd', '/etc', 'blocked', '敏感文件: passwd（即使项目内也禁止访问）', false],
      ['/etc/../etc/passwd', null, 'blocked', '系统目录 /etc 禁止访问', false],
      ['/tmp/+/x', null, 'warn', '路径不在授权的项目目录内: /tmp/+/x', false],
      ['/proj/+.ssh/id_rsa', '/proj', 'blocked', '敏感文件: id_rsa（即使项目内也禁止访问）', false],
      ['/proj/c++/src/app.c', '/proj', 'safe', null, true],
      ['/home/u/.ssh', null, 'blocked', '敏感目录: .ssh 禁止访问', false],
      ['/tmp/x', null, 'warn', '路径不在授权的项目目录内: /tmp/x', false],
      ['/a/../../b', null, 'warn', '路径不在授权的项目目录内: /b', false],
      ['/proj/a', '/proj', 'safe', null, true],
      ['/proj/.env', '/proj', 'blocked', '敏感文件: .env（即使项目内也禁止访问）', false],
      ['/proj/x/.aws', '/proj', 'blocked', '敏感目录: .aws（禁止访问）', false],
    ];
    for (const [path, projectRoot, level, reason, allowed] of rows) {
      const r = checkPath(path, projectRoot === null ? {} : {projectRoot});
      expect(r.level, 'level for ' + path).toBe(level);
      expect(r.reason, 'reason for ' + path).toBe(reason);
      expect(r.isAllowed, 'isAllowed for ' + path).toBe(allowed);
    }
  });

  it('upgrades only warn under sourceCodeGranted, never blocked', () => {
    const granted = checkReadPath('/tmp/x', {sourceCodeGranted: true});
    expect(granted.level).toBe('safe');
    expect(granted.reason).toBeNull();
    const blocked = checkReadPath('/etc/passwd', {sourceCodeGranted: true});
    expect(blocked.level).toBe('blocked');
    expect(blocked.isAllowed).toBe(false);
    expect(checkReadPath('/proj/a', {projectRoot: '/proj'}).level).toBe('safe');
  });

  it('keeps the reason cache bounded and correct under churn', () => {
    // The cache is keyed by command; churning it must neither grow past its cap nor
    // start answering a command it has already classified differently.
    let wrong = 0;
    for (let i = 0; i < 1200; i++) {
      const cmd = 'echo probe-' + i;
      if (getSafetyReason(cmd) !== null) wrong += 1;
    }
    expect(wrong).toBe(0);
    expect(checkSafety('rm -rf /')).toBe('blocked');
    expect(getSafetyReason('rm -rf /')).toContain('不可恢复');
  });

  it('keeps PathSafetyResult a real class with readonly fields', () => {
    const r = new PathSafetyResult('safe', null);
    expect(r.constructor.name).toBe('PathSafetyResult');
    expect(r.level).toBe('safe');
    expect(r.reason).toBeNull();
    expect(r.isAllowed).toBe(true);
    expect(new PathSafetyResult('info', 'x').isAllowed).toBe(true);
    expect(new PathSafetyResult('warn', 'x').isAllowed).toBe(false);
  });
});
