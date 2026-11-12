// ai_terminal/lib/services/change_window_service.dart (162 lines: ChangeWindowConfig
// 9-61 with ctor defaults 22-27 / copyWith 29-41 / toJson 43-48 / fromJson 50-60, and
// ChangeWindowService 64-160: store key + statics 65-68, load 71-81, config getter
// 84-87, save 90-98, isWithinWindow 101-128, checkCommand 135-153, _fmtHour 155,
// _fmtWeekdays 157-160) - plus the four texts of the window-blocking arm of
// agent_engine.dart 2573-2588 (log line 2577, info event 2578, observation output 2581,
// fallback error 2583) and its metric name 2585.
//
// This service has NO Dart unit test. Every .dart file below ai_terminal/test was read
// (count pinned below) and none mentions ChangeWindow / changeWindow / the two-character
// blocking keyword (built from char codes here, so this file stays ASCII). There is
// therefore no group / assertion census to replay: instead every expectation below is
// lifted out of the two Dart SOURCES at run time - the four toJson / fromJson keys and
// their order, the three ctor defaults, the weekday name map with its "?" fallback and
// "/" join, the branch structure of isWithinWindow, each static fragment of the refusal
// sentence (service 148-151), the two debugPrint prefixes (78 / 95), and the whole
// engine arm. A Dart-side rewording shows up as a changed fragment or a parse error,
// never as a stale hand-copied literal.
//
// Deviations replayed as assertions (numbered in the module header):
//  1. the config getter fires the load without awaiting it, so a synchronous read never
//     sees what the store holds - the same shape as Dart 84-87;
//  2. the Dart (bool, String?) record becomes the ChangeWindowCheck union: reason is
//     null exactly when allowed is true;
//  3. Dart now.weekday (1=Mon..7=Sun) becomes getDay() with Sunday mapped to 7, checked
//     against the seven real days of one week;
//  4. Dart int.parse THROWS while Number.parseInt would yield NaN - the throw is ported,
//     so a single bad weekday entry drops the whole stored config and load() keeps the
//     previous cache, which is what the debugPrint prefix pins;
//  5. the classification comes from the shared utils/safety_guard.ts, so checkSafety and
//     checkChangeWindowCommand agree on the same command;
//  6. the engine texts become exported consts so the engine arm can stay ASCII - the
//     absence of that arm in src/react/engine.ts is pinned here and goes red on purpose
//     the round the arm is wired;
//  7. SettingsDao becomes an injected ChangeWindowSettingsPort: with no port load()
//     keeps the default and save() only touches the cache.
import {describe, it, expect} from "vitest";
import {readFileSync, readdirSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {checkSafety} from "../src/utils/safety_guard.js";
import {
  DEFAULT_ENABLED, DEFAULT_END_HOUR, DEFAULT_START_HOUR, LOAD_FAIL_PREFIX, REASON_HEAD,
  REASON_HOUR_SEP, REASON_HOUR_TAIL, REASON_TAIL, REASON_WEEKDAY_SEP, SAVE_FAIL_PREFIX,
  SETTINGS_KEY, WEEKDAY_NAMES, WEEKDAY_NAME_FALLBACK, WINDOW_FALLBACK_REASON,
  WINDOW_INFO_HEAD, WINDOW_INFO_TAIL, WINDOW_LOG_WARN, WINDOW_OBS_OUTPUT,
  changeWindowConfigFromJson, changeWindowConfigToJson, changeWindowReason,
  checkChangeWindowCommand, copyWithChangeWindow, defaultChangeWindowConfig, fmtHour,
  fmtWeekdays, getChangeWindowConfig, isWithinWindow, loadChangeWindow, saveChangeWindow,
  setChangeWindowStore, toWeekday,
} from "../src/utils/change_window.js";
import type {ChangeWindowConfig, ChangeWindowSettingsPort} from "../src/utils/change_window.js";

const NL = String.fromCharCode(10);
const SQO = String.fromCharCode(39);
const DOLLAR = String.fromCharCode(36);
const OBRACE = String.fromCharCode(123);
const CBRACE = String.fromCharCode(125);
const BSLASH = String.fromCharCode(92);
const BTICK = String.fromCharCode(96);
const MARK = "\u0001";   // stands for one Dart dollar-brace interpolation
const HERE = fileURLToPath(new URL(".", import.meta.url));
const linesOf = (rel: string): string[] => readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL).split(NL);
const SVC = linesOf("../../ai_terminal/lib/services/change_window_service.dart");
const ENG = linesOf("../../ai_terminal/lib/services/agent_engine.dart");
const ENGINE_TS = readFileSync(HERE + "../src/react/engine.ts", "utf-8");

// ---- Dart string reader: static text with MARK for each interpolation, plus the
// string literals nested inside those interpolations (service 150 needs them). -------
function dartStr(raw: string): string {
  let out = "";
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] !== BSLASH) { out += raw[i]; continue; }
    const next = raw[i + 1];
    i++;
    if (next === "n") out += NL;
    else if (next === "r") out += String.fromCharCode(13);
    else if (next === "t") out += String.fromCharCode(9);
    else out += next;
  }
  return out;
}

function parseInterp(line: string, i: number): {end: number; nested: string[]} {
  // i is the character after an opening dollar-brace; runs to its closing brace.
  let depth = 1;
  const nested: string[] = [];
  while (i < line.length) {
    const c = line[i];
    if (c === SQO) { const s = parseStr(line, i); nested.push(s.text); i = s.end; continue; }
    if (c === OBRACE) depth++;
    else if (c === CBRACE) { depth--; if (depth === 0) return {end: i + 1, nested}; }
    i++;
  }
  throw new Error("unterminated Dart interpolation: " + line);
}

function parseStr(line: string, i: number): {text: string; nested: string[]; end: number} {
  // i is the opening single quote of a Dart string literal.
  let text = "";
  const nested: string[] = [];
  i++;
  while (i < line.length) {
    const c = line[i];
    if (c === BSLASH) { text += c + line[i + 1]; i += 2; continue; }
    if (c === SQO) return {text: dartStr(text), nested, end: i + 1};
    if (c === DOLLAR && line[i + 1] === OBRACE) {
      const inner = parseInterp(line, i + 2);
      text += MARK;
      for (const n of inner.nested) nested.push(n);
      i = inner.end;
      continue;
    }
    text += c;
    i++;
  }
  throw new Error("unterminated Dart string: " + line);
}

function topStrings(line: string): {text: string; nested: string[]}[] {
  const out: {text: string; nested: string[]}[] = [];
  for (let i = 0; i < line.length; i++) {
    if (line[i] === SQO) { const s = parseStr(line, i); out.push({text: s.text, nested: s.nested}); i = s.end - 1; }
  }
  return out;
}

function strAt(src: string[], lineNo: number, idx = 0): string {
  const line = src[lineNo - 1];
  if (line === undefined) throw new Error("no Dart line " + lineNo);
  const all = topStrings(line);
  const hit = all[idx];
  if (hit === undefined) throw new Error("no Dart string literal #" + idx + " on line " + lineNo);
  return hit.text;
}

function trimAt(src: string[], lineNo: number): string {
  const line = src[lineNo - 1];
  if (line === undefined) throw new Error("no Dart line " + lineNo);
  return line.trim();
}

const win = (y: number, mo: number, d: number, h: number): Date => new Date(y, mo, d, h, 0, 0);
const cfgAt = (start: number, end: number, weekdays: number[] = []): ChangeWindowConfig => ({
  enabled: true, startHour: start, endHour: end, allowedWeekdays: weekdays,
});
// 2026-11-07 is a Saturday, 11-08 a Sunday, 11-09 a Monday - asserted below, and the
// month index (10 = November) keeps these dates local-midnight safe.
const SAT = 7, SUN = 8, MON = 9, NOV = 10;

describe("the oracle for this service is the Dart source, not a Dart test", () => {
  const walk = (dir: string): string[] => {
    const out: string[] = [];
    for (const e of readdirSync(dir, {withFileTypes: true})) {
      const p = dir + "/" + e.name;
      if (e.isDirectory()) out.push(...walk(p));
      else if (e.isFile() && e.name.endsWith(".dart")) out.push(p);
    }
    return out;
  };
  const dartTests = walk(HERE + "../../ai_terminal/test");
  const KEYWORD = String.fromCharCode(0x5c01, 0x7f51);   // blocking keyword, by code point

  it("162 service lines, 91 Dart test files, none of them about this service", () => {
    expect(SVC.length).toBe(162);
    expect(dartTests.length).toBe(91);
    const hits = dartTests.filter((p) => {
      const t = readFileSync(p, "utf-8");
      return t.includes("ChangeWindow") || t.includes("changeWindow") || t.includes(KEYWORD);
    });
    expect(hits).toEqual([]);
  });

  it("the Dart arm sits between the safety level and the permission gate", () => {
    const region = ENG.slice(2572, 2588).join(" ");
    for (const needle of [
      "if (!windowAllowed) {",
      "agentLogger.warn(",
      "onEvent?.call(AgentEvent.info(",
      "final observation = ReActObservation(",
      "command: command,",
      "success: false,",
      "onSuccess(false, ",
      "return _EarlyExecutionResult(",
      "shouldContinue: true",
    ]) expect(region).toContain(needle);
    expect(strAt(ENG, 2585, 0)).toBe("window_blocked");
    const levelLine = ENG.findIndex((l) => l.includes("SafetyGuard.check(command)"));
    const armLine = ENG.findIndex((l) => l.includes("ChangeWindowService.checkCommand(command)"));
    const gateLine = ENG.findIndex((l) => l.includes("final decision = decideCommand(safetyLevel"));
    expect(levelLine).toBeGreaterThan(-1);
    expect(armLine).toBeGreaterThan(levelLine);
    expect(gateLine).toBeGreaterThan(armLine);
    // The Node engine has no arm yet: round 133 wires it. This pin goes red then, on
    // purpose, so the wiring cannot land without revisiting this file.
    expect(ENGINE_TS).not.toContain("changeWindow");
  });
});

describe("ChangeWindowConfig (service 9-61)", () => {
  it("defaults come from the Dart ctor (22-27)", () => {
    expect(trimAt(SVC, 23)).toBe("this.enabled = false,");
    expect(trimAt(SVC, 24)).toBe("this.startHour = 22,");
    expect(trimAt(SVC, 25)).toBe("this.endHour = 6,");
    expect(trimAt(SVC, 26)).toBe("this.allowedWeekdays = const [],");
    expect(DEFAULT_ENABLED).toBe(false);
    expect(DEFAULT_START_HOUR).toBe(22);
    expect(DEFAULT_END_HOUR).toBe(6);
    const empty = {enabled: false, startHour: 22, endHour: 6, allowedWeekdays: []};
    expect(defaultChangeWindowConfig()).toEqual(empty);
    expect(changeWindowConfigFromJson({})).toEqual(empty);
    expect(copyWithChangeWindow(empty, {})).toEqual(empty);
  });

  it("toJson and fromJson use exactly the four Dart keys, in Dart order (43-60)", () => {
    const keys = [44, 45, 46, 47].map((n) => strAt(SVC, n));
    expect(keys).toEqual(["enabled", "startHour", "endHour", "allowedWeekdays"]);
    expect([52, 53, 54, 55].map((n) => strAt(SVC, n))).toEqual(keys);
    expect(Object.keys(changeWindowConfigToJson(defaultChangeWindowConfig()))).toEqual(keys);
    const cfg = cfgAt(20, 4, [1, 3, 5]);
    expect(changeWindowConfigFromJson(changeWindowConfigToJson(cfg))).toEqual(cfg);
  });

  it("fromJson keeps the Dart cast semantics (50-60), deviation 4", () => {
    expect(trimAt(SVC, 56)).toBe("?.map((e) => int.parse(e.toString()))");
    expect(changeWindowConfigFromJson({
      enabled: true, startHour: 20, endHour: 4, allowedWeekdays: ["3", 5, "-1", "+2"],
    })).toEqual({enabled: true, startHour: 20, endHour: 4, allowedWeekdays: [3, 5, -1, 2]});
    expect(changeWindowConfigFromJson({startHour: null, endHour: undefined})).toEqual(defaultChangeWindowConfig());
    const bad: Record<string, unknown>[] = [
      {enabled: "yes"},
      {enabled: 1},
      {startHour: "22"},
      {startHour: 22.5},
      {endHour: Number.NaN},
      {allowedWeekdays: "3"},
      {allowedWeekdays: ["x"]},
      {allowedWeekdays: ["3.5"]},
      {allowedWeekdays: [null]},
    ];
    expect(bad.length).toBe(9);
    for (const json of bad) expect(() => changeWindowConfigFromJson(json)).toThrow();
  });

  it("copyWith keeps every omitted field (29-41)", () => {
    for (const [lineNo, decl] of [[30, "bool? enabled,"], [31, "int? startHour,"],
      [32, "int? endHour,"], [33, "List<int>? allowedWeekdays,"]] as [number, string][]) {
      expect(trimAt(SVC, lineNo)).toBe(decl);
    }
    const base = cfgAt(20, 4, [1]);
    expect(copyWithChangeWindow(base, {startHour: 9})).toEqual({enabled: true, startHour: 9, endHour: 4, allowedWeekdays: [1]});
    expect(copyWithChangeWindow(base, {enabled: false, allowedWeekdays: []})).toEqual({enabled: false, startHour: 20, endHour: 4, allowedWeekdays: []});
    expect(copyWithChangeWindow(base, {endHour: undefined})).toEqual(base);
  });
});

describe("isWithinWindow (service 101-128)", () => {
  it("keeps all five Dart branches (101-128)", () => {
    const region = SVC.slice(100, 128);
    for (const needle of [
      "if (!cfg.enabled) return true;",
      "if (cfg.allowedWeekdays.isNotEmpty) {",
      "if (!cfg.allowedWeekdays.contains(now.weekday)) {",
      "if (start == end) {",
      "if (start < end) {",
      "return hour >= start && hour < end;",
      "return hour >= start || hour < end;",
    ]) expect(region.join(" ")).toContain(needle);
    expect(region.filter((l) => l.trim().startsWith("if (")).length).toBe(5);
  });

  it("maps getDay() onto the Dart 1=Mon..7=Sun convention (deviation 3)", () => {
    const week = [2, 3, 4, 5, 6, 7, 8];   // 2026-11-02 .. 11-08 are Mon .. Sun
    expect(week.map((d) => win(2026, NOV, d, 12).getDay())).toEqual([1, 2, 3, 4, 5, 6, 0]);
    expect(week.map((d) => toWeekday(win(2026, NOV, d, 12)))).toEqual([1, 2, 3, 4, 5, 6, 7]);
  });

  it("the hour table of Dart 117-127 replays hour by hour", () => {
    const hours = [0, 1, 5, 6, 7, 11, 12, 21, 22, 23];
    const wrap = cfgAt(22, 6);
    expect(hours.map((h) => isWithinWindow(win(2026, NOV, MON, h), wrap))).toEqual([true, true, true, false, false, false, false, false, true, true]);
    const same = cfgAt(9, 18);
    expect(hours.map((h) => isWithinWindow(win(2026, NOV, MON, h), same))).toEqual([false, false, false, false, false, true, true, false, false, false]);
    expect(hours.map((h) => isWithinWindow(win(2026, NOV, MON, h), cfgAt(9, 9)))).toEqual(hours.map(() => true));
    expect(isWithinWindow(win(2026, NOV, MON, 22), wrap)).toBe(true);   // hour == start is inside
    expect(isWithinWindow(win(2026, NOV, MON, 6), wrap)).toBe(false);   // hour == end is outside
    expect(isWithinWindow(win(2026, NOV, MON, 9), same)).toBe(true);
    expect(isWithinWindow(win(2026, NOV, MON, 18), same)).toBe(false);
  });

  it("an empty weekday list skips the day branch, a listed day must match (106-111)", () => {
    const monOnly = cfgAt(22, 6, [1]);
    expect(isWithinWindow(win(2026, NOV, MON, 23), monOnly)).toBe(true);
    expect(isWithinWindow(win(2026, NOV, SUN, 23), monOnly)).toBe(false);
    expect(isWithinWindow(win(2026, NOV, SAT, 23), monOnly)).toBe(false);
    const everyDay = cfgAt(22, 6, [1, 2, 3, 4, 5, 6, 7]);
    expect([SUN, MON, SAT].map((d) => isWithinWindow(win(2026, NOV, d, 23), everyDay))).toEqual([true, true, true]);
  });

  it("a disabled window allows everything, and that is the Node default (103)", () => {
    const off = {...defaultChangeWindowConfig(), startHour: 9, endHour: 9, allowedWeekdays: [1]};
    expect(off.enabled).toBe(false);
    expect(isWithinWindow(win(2026, NOV, SAT, 12), off)).toBe(true);
    expect(isWithinWindow(win(2026, NOV, SAT, 12))).toBe(true);   // default param -> the store cache
  });
});

describe("the refusal sentence and checkCommand (service 135-160)", () => {
  it("the two formatters replay the Dart map (155-160)", () => {
    expect(trimAt(SVC, 155)).toBe("static String _fmtHour(int h) => h.toString().padLeft(2, '0');");
    expect(strAt(SVC, 155, 0)).toBe("0");
    expect(fmtHour(0)).toBe("00");
    expect(fmtHour(9)).toBe("09");
    expect(fmtHour(22)).toBe("22");
    const pairs = Array.from(SVC[157].matchAll(/([1-7]): '((?:[^'\\]|\\.)*)'/g));
    expect(pairs.length).toBe(7);
    pairs.forEach((m, i) => expect(WEEKDAY_NAMES[i + 1]).toBe(dartStr(m[2])));
    expect(Object.keys(WEEKDAY_NAMES).map(Number).sort((a, b) => a - b)).toEqual([1, 2, 3, 4, 5, 6, 7]);
    expect(strAt(SVC, 159, 0)).toBe("?");
    expect(strAt(SVC, 159, 1)).toBe("/");
    expect(WEEKDAY_NAME_FALLBACK).toBe("?");
    expect(fmtWeekdays([1, 2, 7])).toBe([WEEKDAY_NAMES[1], WEEKDAY_NAMES[2], WEEKDAY_NAMES[7]].join("/"));
    expect(fmtWeekdays([8, 0])).toBe(WEEKDAY_NAME_FALLBACK + "/" + WEEKDAY_NAME_FALLBACK);
    expect(fmtWeekdays([])).toBe("");
    expect([2, 3, 4, 5, 6, 7, 8].map((d) => WEEKDAY_NAMES[toWeekday(win(2026, NOV, d, 12))])).toEqual(pairs.map((m) => dartStr(m[2])));
  });

  it("every static fragment of the sentence equals the Dart source (148-151)", () => {
    expect(strAt(SVC, 148)).toBe(REASON_HEAD);
    const hours = strAt(SVC, 149).split(MARK);
    expect(hours.length).toBe(3);
    expect(hours[0]).toBe("");
    expect(REASON_HOUR_SEP).toBe(hours[1]);
    expect(REASON_HOUR_TAIL).toBe(hours[2]);
    const cond = topStrings(SVC[149])[0];
    expect(cond.text).toBe(MARK);
    expect(cond.nested.length).toBe(2);
    const wd = cond.nested[0].split(MARK);
    expect(wd.length).toBe(2);
    expect(wd[1]).toBe("");
    expect(REASON_WEEKDAY_SEP).toBe(wd[0]);
    expect(cond.nested[1]).toBe("");
    const tail = strAt(SVC, 151).split(MARK);
    expect(tail.length).toBe(2);
    expect(tail[1]).toBe("");
    expect(REASON_TAIL).toBe(tail[0]);
  });

  it("the composition pads hours, adds the day clause only when the list is set, ends with the level", () => {
    const build = (cfg: ChangeWindowConfig, level: string): string =>
      REASON_HEAD + fmtHour(cfg.startHour) + REASON_HOUR_SEP + fmtHour(cfg.endHour) + REASON_HOUR_TAIL +
      (cfg.allowedWeekdays.length > 0 ? REASON_WEEKDAY_SEP + fmtWeekdays(cfg.allowedWeekdays) : "") +
      REASON_TAIL + level;
    const cfgs = [cfgAt(22, 6), cfgAt(0, 0), cfgAt(9, 18, [1, 2, 3, 4, 5]), cfgAt(8, 20, [7])];
    for (const cfg of cfgs) for (const level of ["info", "warn", "blocked"]) {
      expect(changeWindowReason(cfg, level as SafetyLevel)).toBe(build(cfg, level));
    }
    expect(changeWindowReason(cfgAt(22, 6, [7]), "warn")).toContain("22:00 - 06:00");
    expect(changeWindowReason(cfgAt(22, 6, [7]), "warn").endsWith("warn")).toBe(true);
    expect(changeWindowReason(cfgAt(9, 18, []), "blocked")).toContain("09:00 - 18:00");
    expect(changeWindowReason(cfgAt(9, 18, []), "blocked")).not.toContain(REASON_WEEKDAY_SEP);
    expect(changeWindowReason(cfgAt(0, 0, []), "info")).toContain("00:00 - 00:00");
  });

  it("checkCommand replays the Dart order 136-152 (deviation 2, deviation 5)", () => {
    const region = SVC.slice(134, 153).join(" ");
    for (const needle of [
      "final cfg = config;",
      "if (!cfg.enabled) return (true, null);",
      "final level = SafetyGuard.check(command);",
      "if (level == SafetyLevel.safe) return (true, null);",
      "if (isWithinWindow(DateTime.now())) {",
      "return (false, reason);",
    ]) expect(region).toContain(needle);
    expect((region.match(/\(true, null\)/g) || []).length).toBe(3);
    const cfg = cfgAt(22, 6);
    const outside = win(2026, NOV, MON, 12);
    const inside = win(2026, NOV, MON, 23);
    expect(checkSafety("ls -la")).toBe("safe");
    expect(checkSafety("rm -rf tmp")).toBe("warn");
    expect(checkChangeWindowCommand("ls -la", {config: cfg, now: outside})).toEqual({allowed: true, reason: null});
    expect(checkChangeWindowCommand("rm -rf tmp", {config: cfg, now: inside})).toEqual({allowed: true, reason: null});
    const blocked = checkChangeWindowCommand("rm -rf tmp", {config: cfg, now: outside});
    expect(blocked.allowed).toBe(false);
    if (blocked.allowed === false) expect(blocked.reason).toBe(changeWindowReason(cfg, "warn"));
    expect(checkChangeWindowCommand("rm -rf /", {config: {...cfg, enabled: false}, now: outside})).toEqual({allowed: true, reason: null});
    expect(checkSafety("rm -rf /")).toBe("blocked");
    const hard = checkChangeWindowCommand("rm -rf /", {config: cfg, now: outside});
    if (hard.allowed === false) expect(hard.reason.endsWith("blocked")).toBe(true);
  });
});

describe("the static store trio (service 65-98), deviation 1 and deviation 7", () => {
  const stored: ChangeWindowConfig = {enabled: true, startHour: 11, endHour: 12, allowedWeekdays: [3]};
  const memStore = (values: Map<string, unknown>): ChangeWindowSettingsPort => ({
    getCached: (key: string) => values.get(key),
    set: (key: string, value: Record<string, unknown>) => { values.set(key, value); },
  });

  async function captureWarn<T>(fn: () => Promise<T>): Promise<{result: T; logs: string[]}> {
    const original = console.warn;
    const logs: string[] = [];
    console.warn = (...args: unknown[]) => { logs.push(args.map((a) => String(a)).join(" ")); };
    try { return {result: await fn(), logs}; } finally { console.warn = original; }
  }

  it("the store key is the Dart private key (65)", () => {
    expect(trimAt(SVC, 65)).toBe("static const _key = 'changeWindowConfig';");
    expect(SETTINGS_KEY).toBe(strAt(SVC, 65));
    expect(trimAt(SVC, 67)).toBe("static ChangeWindowConfig _cache = const ChangeWindowConfig();");
    expect(trimAt(SVC, 68)).toBe("static bool _loaded = false;");
  });

  it("the config getter fires the load without awaiting it (84-87)", async () => {
    expect(trimAt(SVC, 85)).toBe("if (!_loaded) load();");
    const values = new Map<string, unknown>([[SETTINGS_KEY, changeWindowConfigToJson(stored)]]);
    setChangeWindowStore(memStore(values));
    const sync = getChangeWindowConfig();
    expect(sync).not.toEqual(stored);                 // a synchronous read cannot see the store
    expect(sync).toEqual(defaultChangeWindowConfig());
    await loadChangeWindow();                         // the same load, awaited
    expect(getChangeWindowConfig()).toEqual(stored);
  });

  it("load reads exactly the Dart key and accepts a plain map (72-76)", async () => {
    expect(trimAt(SVC, 72)).toBe("try {");
    expect(trimAt(SVC, 73)).toBe("final raw = SettingsDao.getCached(_key);");
    expect(trimAt(SVC, 74)).toBe("if (raw is Map) {");
    expect(trimAt(SVC, 75)).toBe("_cache = ChangeWindowConfig.fromJson(Map<dynamic, dynamic>.from(raw));");
    const seen: string[] = [];
    const values = new Map<string, unknown>([[SETTINGS_KEY, changeWindowConfigToJson(stored)]]);
    const port: ChangeWindowSettingsPort = {
      getCached: (key: string) => { seen.push(key); return values.get(key); },
      set: () => { /* unused */ },
    };
    await loadChangeWindow(port);
    expect(seen).toEqual([SETTINGS_KEY]);
    expect(getChangeWindowConfig()).toEqual(stored);
  });

  it("load keeps the cache when the stored value is not a map (74-76)", async () => {
    for (const raw of [null, undefined, 7, "x", [1, 2]]) {
      await loadChangeWindow({getCached: () => raw, set: () => { /* unused */ }});
      expect(getChangeWindowConfig()).toEqual(stored);
    }
  });

  it("load logs the Dart prefix and keeps the cache on a throwing store (72, 77-80)", async () => {
    const {logs} = await captureWarn(async () => {
      await loadChangeWindow({getCached: () => { throw new Error("hive down"); }, set: () => { /* unused */ }});
    });
    expect(logs.length).toBe(1);
    expect(logs[0].startsWith(LOAD_FAIL_PREFIX)).toBe(true);
    expect(logs[0]).toContain("hive down");
    expect(getChangeWindowConfig()).toEqual(stored);
  });

  it("one bad weekday entry drops the whole stored map, which is the Dart catch (56 / 74-80)", async () => {
    const bad = {enabled: true, startHour: 1, endHour: 2, allowedWeekdays: ["3", "x"]};
    const {logs} = await captureWarn(async () => {
      await loadChangeWindow({getCached: () => bad, set: () => { /* unused */ }});
    });
    expect(logs.length).toBe(1);
    expect(logs[0].startsWith(LOAD_FAIL_PREFIX)).toBe(true);
    expect(getChangeWindowConfig()).toEqual(stored);
  });

  it("both debugPrint prefixes are the Dart strings without the error value (78 / 95)", () => {
    for (const [lineNo, value] of [[78, LOAD_FAIL_PREFIX], [95, SAVE_FAIL_PREFIX]] as [number, string][]) {
      const dart = strAt(SVC, lineNo);
      expect(dart.endsWith(DOLLAR + "e")).toBe(true);
      expect(value).toBe(dart.slice(0, dart.length - (DOLLAR + "e").length));
      expect(value.length).toBeGreaterThan(0);
    }
  });

  it("save caches first, then writes the store as a plain map (90-94)", async () => {
    expect(trimAt(SVC, 91)).toBe("_cache = cfg;");
    expect(trimAt(SVC, 93)).toBe("await SettingsDao.set(_key, cfg.toJson());");
    const values = new Map<string, unknown>();
    const next = cfgAt(1, 2, [6]);
    await saveChangeWindow(next, memStore(values));
    expect(getChangeWindowConfig()).toEqual(next);
    expect(Array.from(values.keys())).toEqual([SETTINGS_KEY]);
    expect(values.get(SETTINGS_KEY)).toEqual(changeWindowConfigToJson(next));
  });

  it("save logs and rethrows, while the cache keeps the new config (92-97)", async () => {
    expect(trimAt(SVC, 96)).toBe("rethrow;");
    let rethrown = "";
    const next: ChangeWindowConfig = {enabled: true, startHour: 5, endHour: 5, allowedWeekdays: []};
    const {logs} = await captureWarn(async () => {
      try {
        await saveChangeWindow(next, {getCached: () => null, set: () => { throw new Error("disk full"); }});
      } catch (e) { rethrown = String(e); }
    });
    expect(rethrown).toContain("disk full");
    expect(logs.length).toBe(1);
    expect(logs[0].startsWith(SAVE_FAIL_PREFIX)).toBe(true);
    expect(getChangeWindowConfig()).toEqual(next);   // Dart 91 assigns before the try
  });

  it("with no port the store is inert: load changes nothing, save only touches the cache", async () => {
    setChangeWindowStore(undefined);
    await loadChangeWindow();
    expect(getChangeWindowConfig()).toEqual({enabled: true, startHour: 5, endHour: 5, allowedWeekdays: []});
    await saveChangeWindow(cfgAt(3, 4, [2]));
    expect(getChangeWindowConfig()).toEqual(cfgAt(3, 4, [2]));
    setChangeWindowStore(undefined);
  });
});

describe("the engine arm texts (agent_engine.dart 2573-2588), deviation 6", () => {
  it("the log line is the Dart warn text without the command interpolation", () => {
    const tail = DOLLAR + "command";
    const dart = strAt(ENG, 2577, 1);
    expect(dart.endsWith(tail)).toBe(true);
    expect(WINDOW_LOG_WARN).toBe(dart.substring(0, dart.length - tail.length));
    expect(WINDOW_LOG_WARN.length).toBeGreaterThan(0);
  });

  it("the info event splits around the two Dart interpolations", () => {
    const dart = strAt(ENG, 2578);
    const cmdMark = DOLLAR + "command";
    const reasonMark = DOLLAR + "windowReason";
    const cut = dart.indexOf(cmdMark);
    expect(cut).toBeGreaterThan(-1);
    const head = dart.substring(0, cut);
    const rest = dart.substring(cut + cmdMark.length);
    const cut2 = rest.indexOf(reasonMark);
    expect(cut2).toBeGreaterThan(-1);
    const tail = rest.substring(0, cut2);
    expect(rest.substring(cut2 + reasonMark.length)).toBe("");
    expect(WINDOW_INFO_HEAD).toBe(head);
    expect(WINDOW_INFO_TAIL).toBe(tail);
    expect(WINDOW_INFO_HEAD.endsWith(BTICK)).toBe(true);
    expect(WINDOW_INFO_TAIL).toBe(BTICK + NL);
    // what the arm emits: head + command + tail + reason
    const cmd = "rm -rf tmp";
    const cfg = cfgAt(22, 6, [2]);
    const reason = changeWindowReason(cfg, "warn");
    const emitted = WINDOW_INFO_HEAD + cmd + WINDOW_INFO_TAIL + reason;
    expect(emitted).toContain(cmd);
    expect(emitted.startsWith(head)).toBe(true);
    expect(emitted.endsWith(reason)).toBe(true);
    expect(emitted.split(cmd).length).toBe(2);
  });

  it("the observation output and the fallback error are the two Dart literals (2581 / 2583)", () => {
    expect(WINDOW_OBS_OUTPUT).toBe(strAt(ENG, 2581));
    expect(WINDOW_FALLBACK_REASON).toBe(strAt(ENG, 2583));
    expect(strAt(ENG, 2583).length < strAt(ENG, 2581).length).toBe(true);
    expect(WINDOW_OBS_OUTPUT.length).toBeGreaterThan(0);
  });
});

