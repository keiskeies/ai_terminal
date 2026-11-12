// (162 lines: ChangeWindowConfig 9-61 with the field docs 10-20, the ctor defaults
// 22-27, copyWith 29-41, toJson 43-48, fromJson 50-60; ChangeWindowService 64-160 with
// _key 65, _cache/_loaded 67-68, load 71-81, the config getter 84-87, save 90-98,
// isWithinWindow 101-128, checkCommand 135-153, _fmtHour 155, _fmtWeekdays 157-160)
// plus the engine-side texts of the SAME gate, agent_engine.dart 2573-2588 (the
// 封网期 arm that sits between the audit write and decideCommand).
//
// Storage half: Dart reads SettingsDao / writes SettingsDao.set (Hive). On the Node side
// the store is an injected ChangeWindowSettingsPort. With no store the config stays at
// the defaults, which is what Dart's load() produces when getCached throws (77-79).
//
// Deviations from Dart, all disclosed:
//  1. The config getter keeps Dart's non-awaiting lazy load (84-87): loadChangeWindow is
//     async, getChangeWindowConfig never awaits it, so the first read after a load has
//     been kicked off still returns the previous cache.
//  2. checkCommand returns a discriminated union instead of Dart's (bool, String?)
//     record. Dart's tuple says String? but its only false branch passes a built
//     non-null reason (148-152), so the union's reason is non-null; null stays on the
//     allowed branches, where Dart also puts null.
//  3. DateTime.weekday is 1=Mon..7=Sun; JS getDay() is 0=Sun..6=Sat, so toWeekday maps
//     0 -> 7. Both read LOCAL time, like Dart's DateTime.now() (101-128).
//  4. fromJson keeps Dart's casts as throwing casts: "as bool?" (52) on a String throws
//     rather than defaulting, "as int?" (53-54) rejects a non-integral number, "as List?"
//     (55) rejects a non-list, and int.parse(e.toString()) (56) throws on a non-numeric
//     entry. One bad entry therefore drops the WHOLE config to the default via load()'s
//     catch (77-79) - not just the entry, exactly like Dart. JS has no int/double split:
//     Number.isInteger is the closest reading of "as int?" for a JSON number.
//  5. checkCommand classifies with checkSafety itself (Dart 139 calls SafetyGuard.check),
//     so a gated command is classified twice - Dart classifies twice as well (2523 for
//     the audit write, 139 inside the service).
//  6. The texts Dart inlines in the engine arm (2577/2578/2581/2583) are consts here, so
//     react/engine.ts keeps its ASCII-only invariant. The observation output text (2581)
//     is not reachable at the Node call site: formatObservationFailure only carries the
//     error string - the same shape the permission-reject arm already documents.
//  7. save() without a store updates the cache only (Dart 91 always has Hive behind it);
//     debugPrint becomes console.warn, with Dart's two prefixes kept verbatim (78/95).
//
// Every CJK literal below is re-read from the Dart source at run time by
// test/change_window_oracle.test.ts, so a Dart-side wording change turns that test red.

import {checkSafety} from "./safety_guard.js";
import type {SafetyLevel} from "./safety_guard.js";

export const SETTINGS_KEY = "changeWindowConfig";   // Dart 65
export const DEFAULT_ENABLED = false;               // Dart 23
export const DEFAULT_START_HOUR = 22;               // Dart 24
export const DEFAULT_END_HOUR = 6;                  // Dart 25
export const WEEKDAY_NAME_FALLBACK = "?";           // Dart 159 names[d] ?? '?'

export interface ChangeWindowConfig {
  enabled: boolean;
  startHour: number;
  endHour: number;
  allowedWeekdays: number[];
}

export function defaultChangeWindowConfig(): ChangeWindowConfig {
  return {
    enabled: DEFAULT_ENABLED,
    startHour: DEFAULT_START_HOUR,
    endHour: DEFAULT_END_HOUR,
    allowedWeekdays: [],
  };
}

// Dart copyWith 29-41: every named parameter defaults to the current value, so an
// omitted key keeps it and an explicit undefined keeps it too (JS ?? is Dart ??).
export function copyWithChangeWindow(
  cfg: ChangeWindowConfig,
  patch: Partial<ChangeWindowConfig>,
): ChangeWindowConfig {
  return {
    enabled: patch.enabled ?? cfg.enabled,
    startHour: patch.startHour ?? cfg.startHour,
    endHour: patch.endHour ?? cfg.endHour,
    allowedWeekdays: patch.allowedWeekdays ?? cfg.allowedWeekdays,
  };
}
// Dart toJson 43-48: four keys, this order.
export function changeWindowConfigToJson(cfg: ChangeWindowConfig): Record<string, unknown> {
  return {
    enabled: cfg.enabled,
    startHour: cfg.startHour,
    endHour: cfg.endHour,
    allowedWeekdays: cfg.allowedWeekdays,
  };
}

function asBool(value: unknown): boolean | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "boolean") throw new TypeError("[ChangeWindow] not a bool: " + typeof value);
  return value;
}

function asInt(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new TypeError("[ChangeWindow] not an int: " + String(value));
  }
  return value;
}

function asList(value: unknown): unknown[] | null {
  if (value === null || value === undefined) return null;
  if (!Array.isArray(value)) throw new TypeError("[ChangeWindow] not a List: " + typeof value);
  return value;
}
// Dart 56 int.parse(e.toString()): an optional sign plus digits, everything else throws
// (FormatException). Number.parseInt would silently return NaN, which is NOT Dart's
// behaviour, so the throw is ported explicitly - load() then drops the whole config.
function parseIntDart(value: unknown): number {
  const s = String(value);
  if (!/^[+-]?[0-9]+$/.test(s)) throw new TypeError(LOAD_PARSE_FAIL + s);
  return Number.parseInt(s, 10);
}

// Dart fromJson 50-60. The casts throw on a wrong type (deviation 4), and the weekday
// entries go through int.parse(e.toString()) - so a numeric string "3" is accepted while
// "x" throws.
export function changeWindowConfigFromJson(json: Record<string, unknown>): ChangeWindowConfig {
  const weekdays = asList(json.allowedWeekdays);
  return {
    enabled: asBool(json.enabled) ?? DEFAULT_ENABLED,
    startHour: asInt(json.startHour) ?? DEFAULT_START_HOUR,
    endHour: asInt(json.endHour) ?? DEFAULT_END_HOUR,
    allowedWeekdays: weekdays === null ? [] : weekdays.map((e) => parseIntDart(e)),
  };
}

// Dart _fmtHour 155: padLeft(2, "0").
export function fmtHour(hour: number): string {
  return String(hour).padStart(2, "0");
}

// Dart _fmtWeekdays 157-160: the name map is 1=Mon..7=Sun, a missing key falls back to "?".
export const WEEKDAY_NAMES: Record<number, string> = {
  1: "周一",
  2: "周二",
  3: "周三",
  4: "周四",
  5: "周五",
  6: "周六",
  7: "周日",
};

export function fmtWeekdays(days: number[]): string {
  return days.map((d) => WEEKDAY_NAMES[d] ?? WEEKDAY_NAME_FALLBACK).join("/");
}

// Deviation 3: Dart now.weekday is 1=Mon..7=Sun (the map above), JS getDay() is
// 0=Sun..6=Sat, so Sunday becomes 7. Both read local time.
export function toWeekday(now: Date): number {
  const js = now.getDay();
  return js === 0 ? 7 : js;
}

export function isWithinWindow(now: Date, cfg: ChangeWindowConfig = getChangeWindowConfig()): boolean {
  if (!cfg.enabled) return true;                       // Dart 103
  if (cfg.allowedWeekdays.length > 0) {                // Dart 107-112
    if (!cfg.allowedWeekdays.includes(toWeekday(now))) {
      return false;
    }
  }
  const hour = now.getHours();                         // Dart 114
  const start = cfg.startHour;                         // Dart 115
  const end = cfg.endHour;                             // Dart 116
  if (start === end) return true;                      // Dart 117-121
  if (start < end) {                                   // Dart 122-124
    return hour >= start && hour < end;
  }
  return hour >= start || hour < end;                  // Dart 125-127
}

// The reason sentence, Dart 148-151, split at its interpolations so every static
// fragment is a const the oracle test compares with the Dart source.
export const REASON_HEAD = "当前处于封网期（允许变更窗口: ";                 // Dart 148
export const REASON_HOUR_SEP = ":00 - ";                // Dart 149
export const REASON_HOUR_TAIL = ":00";              // Dart 149
export const REASON_WEEKDAY_SEP = ", 仅 ";               // Dart 150
export const REASON_TAIL = "），修改性命令被拒绝执行。当前命令安全等级: ";   // Dart 151 up to ${level.name}

export function changeWindowReason(cfg: ChangeWindowConfig, level: SafetyLevel): string {
  return REASON_HEAD + fmtHour(cfg.startHour) + REASON_HOUR_SEP + fmtHour(cfg.endHour) + REASON_HOUR_TAIL +
    (cfg.allowedWeekdays.length > 0 ? REASON_WEEKDAY_SEP + fmtWeekdays(cfg.allowedWeekdays) : "") +
    REASON_TAIL + level;
}

// Dart checkCommand 135-153. Deviation 2: the union replaces the (bool, String?) record.
export type ChangeWindowCheck =
  | {allowed: true; reason: null}
  | {allowed: false; reason: string};

export interface ChangeWindowCheckOptions {
  now?: Date;
  config?: ChangeWindowConfig;
}

export function checkChangeWindowCommand(
  command: string,
  opts: ChangeWindowCheckOptions = {},
): ChangeWindowCheck {
  const cfg = opts.config ?? getChangeWindowConfig();            // Dart 136
  if (!cfg.enabled) return {allowed: true, reason: null};        // Dart 137-139
  const level = checkSafety(command);                            // Dart 140-142 (deviation 5)
  if (level === "safe") return {allowed: true, reason: null};    // Dart 143-145
  if (isWithinWindow(opts.now ?? new Date(), cfg)) {             // Dart 146-148
    return {allowed: true, reason: null};
  }
  return {allowed: false, reason: changeWindowReason(cfg, level)};  // Dart 149-152
}

// Dart 65-98: the static store trio. Deviation 7: the Hive DAO becomes an injected
// port; with no port load() keeps the default and save() only updates the cache.
export interface ChangeWindowSettingsPort {
  getCached(key: string): unknown;
  set(key: string, value: Record<string, unknown>): void | Promise<void>;
}

export const LOAD_FAIL_PREFIX = "[ChangeWindow] 加载配置失败: ";   // Dart 78 without the trailing "$e"
const LOAD_PARSE_FAIL = "[ChangeWindow] int.parse failed: ";   // port-side, mirrors the two Dart prefixes
export const SAVE_FAIL_PREFIX = "[ChangeWindow] 保存配置失败: ";   // Dart 95 without the trailing "$e"

let store: ChangeWindowSettingsPort | undefined;
let cache: ChangeWindowConfig = defaultChangeWindowConfig();
let loaded = false;

export function setChangeWindowStore(port: ChangeWindowSettingsPort | undefined): void {
  store = port;
}

// Dart load 71-81. A wrong-typed stored value throws inside fromJson and the catch
// keeps the previous cache, which is the default when nothing was cached before.
export async function loadChangeWindow(port: ChangeWindowSettingsPort | undefined = store): Promise<void> {
  try {
    const raw = port === undefined ? null : port.getCached(SETTINGS_KEY);   // Dart 72
    if (raw !== null && typeof raw === "object" && !Array.isArray(raw)) {   // Dart 73
      cache = changeWindowConfigFromJson(raw as Record<string, unknown>);   // Dart 74-76
    }
  } catch (e) {
    console.warn(LOAD_FAIL_PREFIX + String(e));                             // Dart 77-79
  }
  loaded = true;                                                            // Dart 80
}

// Dart config getter 84-87, including the un-awaited lazy load (deviation 1).
export function getChangeWindowConfig(): ChangeWindowConfig {
  if (!loaded) void loadChangeWindow();
  return cache;
}

// Dart save 90-98: the cache is written first, the store write rethrows after logging.
export async function saveChangeWindow(
  cfg: ChangeWindowConfig,
  port: ChangeWindowSettingsPort | undefined = store,
): Promise<void> {
  cache = cfg;
  loaded = true;
  if (port === undefined) return;
  try {
    await port.set(SETTINGS_KEY, changeWindowConfigToJson(cfg));
  } catch (e) {
    console.warn(SAVE_FAIL_PREFIX + String(e));
    throw e;
  }
}

// The engine arm's texts, agent_engine.dart 2577/2578/2581/2583 (deviation 6).
export const WINDOW_LOG_WARN = "封网期拦截修改性命令: ";   // Dart 2577 up to $command
export const WINDOW_INFO_HEAD = "🚫 封网期拦截\n命令: `";     // Dart 2578 up to the backtick
export const WINDOW_INFO_TAIL = "`\n";     // Dart 2578 backtick + newline
export const WINDOW_OBS_OUTPUT = "封网期内禁止执行修改性命令（仅允许只读命令）";   // Dart 2581
export const WINDOW_FALLBACK_REASON = "封网期拦截"; // Dart 2583

