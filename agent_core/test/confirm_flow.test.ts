// confirm_flow.test.ts - the Dart confirmation oracle replayed against the port.
//
// Source of truth: ai_terminal/test/tool_contract_test.dart, group
// "破坏性工具确认通道" (line 447) and group "暂停/恢复不得丢弃等待中的 awaiter（R1）"
// (line 544). There is no Dart SDK here, so the Dart side is never executed: every
// expectation below is lifted out of the Dart source by the parser further down and
// then asserted against src/react/confirm_flow.ts. A Dart expectation this file
// cannot read is a hard parse error, never a silent skip, and a red fingerprint is a
// prompt to re-read the Dart side - not to re-pin the hash blindly.
//
// The four Dart tests are T0 448..495, T1 497..541, T2 545..600, T3 602..638.
// Their structural counts (expect / reason: / await) are pinned, so a Dart edit that
// quietly adds or removes an assertion shows up as a parse-integrity failure instead
// of a smaller replay.

import {describe, it, expect} from "vitest";
import {readFileSync, readdirSync} from "node:fs";
import {createHash} from "node:crypto";
import {fileURLToPath} from "node:url";
import {
  ConfirmFlow,
  CONFIRM_TIMEOUT_MS,
  BLOCKED_COMMAND_REASONS,
  isBlockedCommandReason,
  CONFIRM_REASON_GENERATION_INVALID,
  CONFIRM_REASON_CANCELLED,
  CONFIRM_REASON_TIMEOUT,
  CONFIRM_REASON_USER_REJECTED,
  CONFIRM_REASON_PERMISSION_CHANGED,
} from "../src/react/confirm_flow.js";
import type {
  ConfirmFlowContext,
  ConfirmFlowEvents,
  ConfirmTimerHandle,
  CommandConfirmOutcome,
} from "../src/react/confirm_flow.js";
import type {PermissionMode} from "../src/rpc/schema.js";
import * as reactBarrel from "../src/react/index.js";
import * as rootBarrel from "../src/index.js";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const DART_TEST = HERE + "../../ai_terminal/test/tool_contract_test.dart";
const DART_ENGINE = HERE + "../../ai_terminal/lib/services/agent_engine.dart";
const TS_FLOW = HERE + "../src/react/confirm_flow.ts";
const TS_INDEX = HERE + "../src/index.ts";
const SRC_DIR = fileURLToPath(new URL("../src", import.meta.url));
const REACT_INDEX = HERE + "../src/react/index.ts";
const POLICY = HERE + "../src/utils/permission_policy.ts";
const ENGINE_TS = HERE + "../src/react/engine.ts";

const NL = String.fromCharCode(10);
const DLR = String.fromCharCode(36);
const BSL = String.fromCharCode(92);
const SQ = String.fromCharCode(39);
const DQ = String.fromCharCode(34);

function readText(path: string): string {
  return readFileSync(path, "utf-8").replace(/\r\n/g, NL);
}
function sha12(text: string): string {
  return createHash("sha1").update(text, "utf-8").digest("hex").slice(0, 12);
}

const DART_TEST_TEXT = readText(DART_TEST);
const DART_ENGINE_TEXT = readText(DART_ENGINE);
const TS_FLOW_TEXT = readText(TS_FLOW);
const TS_INDEX_TEXT = readText(TS_INDEX);
const REACT_INDEX_TEXT = readText(REACT_INDEX);
const DART_TEST_LINES = DART_TEST_TEXT.split(NL);
const DART_ENGINE_LINES = DART_ENGINE_TEXT.split(NL);
const TS_FLOW_LINES = TS_FLOW_TEXT.split(NL);
const TS_INDEX_LINES = TS_INDEX_TEXT.split(NL);
const POLICY_LINES = readText(POLICY).split(NL);

/** Inclusive 1-based line span of a module, joined back with NL. */
function span(lines: string[], from: number, to: number): string {
  return lines.slice(from - 1, to).join(NL);
}

/*
 * ---------------------------------------------------------------------------
 * Dart-source parsers.
 *
 * Three traps, all learned the hard way and all still live in these helpers:
 *  1. Comments are blanked with equal-length spaces BEFORE any literal is read.
 *     Dart comments carry apostrophes ("don't"), which desync any quote-aware
 *     scanner that reads them.
 *  2. The comment blanker leaves the outer cursor PAST the closing quote of a
 *     literal it skipped, because the outer loop has no implicit i++.
 *  3. A bare dollar-sign at the START of a pattern is an end-of-line anchor, never a
 *     dollar sign, so interpolation patterns are spelled from \x24.
 * ---------------------------------------------------------------------------
 */

// Blank line and block comments, preserving every other byte and every offset.
function blankComments(text: string): string {
  const chars = text.split("");
  const put = (from: number, to: number): void => {
    for (let k = from; k < to && k < chars.length; k++) {
      if (chars[k] !== NL) chars[k] = " ";
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
    if (ch === SQ || ch === DQ || ch === String.fromCharCode(96)) {
      const q3 = ch + ch + ch;
      if (text.slice(i, i + 3) === q3 || text.slice(i, i + 4) === "r" + q3) {
        const start = (text[i] as string) === "r" ? i + 1 : i;
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
      // Stop PAST the closing quote: the outer loop below does not add its own i++.
      i = j;
      continue;
    }
    i += 1;
  }
  return chars.join("");
}

const DART_TEST_BLANK = blankComments(DART_TEST_TEXT);
const DART_ENGINE_BLANK = blankComments(DART_ENGINE_TEXT);
const DART_ENGINE_BLANK_LINES = DART_ENGINE_BLANK.split(NL);

/** Read a quoted literal starting at src[i]; returns body and cursor past it. */
function quoteAt(src: string, i: number): [string, number] {
  const q = src[i] as string;
  let j = i + 1;
  let out = "";
  while (j < src.length) {
    const c = src[j] as string;
    if (c === BSL) {
      out += src[j + 1];
      j += 2;
      continue;
    }
    if (c === q) return [out, j + 1];
    out += c;
    j += 1;
  }
  throw new Error("unterminated quote at " + String(i));
}

/** The first positional argument of a call when it is a plain string literal. */
function firstArgString(src: string, openParen: number): string {
  let i = openParen + 1;
  while (i < src.length && /\s/.test(src[i] as string)) i += 1;
  const ch = src[i] as string;
  if (ch !== SQ && ch !== DQ) {
    throw new Error("first argument is not a string literal at " + String(i));
  }
  return quoteAt(src, i)[0];
}

/** Open-paren offset of every top-level call of name( : not preceded by an
 *  identifier char and not by a dot, so .group(1) never counts as a group(. */
function calls(src: string, name: string): number[] {
  const re = new RegExp("(^|[^A-Za-z0-9_.])" + name + "\\(", "g");
  const out: number[] = [];
  let m = re.exec(src);
  while (m !== null) {
    // Report the open paren: firstArgString() needs it, and the call name, the
    // "(" and the first argument always sit on the same Dart line, so lineOf() still
    // reports the call site either way.
    out.push(m.index + m[0].length - 1);
    m = re.exec(src);
  }
  return out;
}

function lineOf(src: string, idx: number): number {
  return src.slice(0, idx).split(NL).length;
}

/** Count occurrences of a fixed needle (never a regex, never a silent zero). */
function count(needle: string, src: string): number {
  return src.split(needle).length - 1;
}

/** 1-based lines where src contains needle. */
function linesWith(needle: string, lines: string[]): number[] {
  const out: number[] = [];
  lines.forEach((t, i) => {
    if (t.includes(needle)) out.push(i + 1);
  });
  return out;
}

/** Byte offset of needle in src, asserting it occurs at least once. */
function offset(src: string, needle: string, what: string): number {
  const i = src.indexOf(needle);
  if (i < 0) throw new Error("missing " + what + ": " + needle);
  return i;
}


/* ===========================================================================*
 * 1. Fingerprints of the four files this oracle reads.
 *
 * Every span below is a span the replay depends on: wake-path bodies, the two
 * wait bodies whose accounting order differs on purpose, the refusal-text
 * bodies, the blocked-reason set and the four Dart confirm tests. A red hash
 * means the source moved; re-read the Dart and re-derive the replay, do not
 * re-pin the hash to make the test green.
 * ===========================================================================*/

type SpanPin = [string, number, number, string];

const DART_TEST_FILE_SHA = "53bafa8f924f";
const DART_ENGINE_FILE_SHA = "ad7e7cca87de";
const TS_FLOW_FILE_SHA = "69dc5b337734";
const TS_INDEX_FILE_SHA = "e9f17e4945b6";   // startTask now injects the flow + counters into the engine

const DART_ENGINE_SPANS: SpanPin[] = [
  ["TOOL wait",405,446,"6295febbdc34"],
  ["AWAITTOOL",433,444,"16967bb302f8"],
  ["EXPIRE",446,460,"841ca5d094e4"],
  ["CANCEL",695,720,"0570e57f7cd9"],
  ["TERM",925,945,"0e61ed253281"],
  ["PAUSE",1040,1062,"f7e63fc223fb"],
  ["CONFREJ",1150,1168,"9a2743ae9b5c"],
  ["SET",2370,2377,"8ee8ff8abae8"],
  ["CMD gate",2631,2726,"21343d7fd75e"],
  ["AWAITCMD",2668,2676,"e1fbeaabaf83"],
  ["TOOLGATE",3410,3420,"2d9cebe7590a"],
  ["TOOLREF",3418,3440,"2cd9756306ee"],
  ["FIN",3805,3815,"108813bfb5d7"],
];

const TS_FLOW_SPANS: SpanPin[] = [
["arm",231,250,"f0fc772acf82"],
["begin",254,271,"6ea92ddbca05"],
["waitForCommandConfirm",279,361,"a51c955fb75e"],
["confirmToolExecution",365,393,"455c45ebd74d"],
["toolRefusal",398,407,"09eb268cce1a"],
["confirmReject",429,442,"c92fd81f4e82"],
["expire",416,426,"2fc60571d82f"],
["wakeForCancelTask",445,455,"e027e703f653"],
["wakeForCancelledFinish",463,472,"ccfb08457c4c"],
["wakeForPause",479,486,"b429f967b78d"],
["finishCleanup",493,496,"fbf1b92d5efb"],
["formatObservationFailure",148,154,"7c96f8453de9"],
];

const DART_TEST_SPANS: SpanPin[] = [
  ["T0",448,495,"f7bdce9b4868"],
  ["T1",497,541,"7cf21766006c"],
  ["T2",545,600,"fca4d3825f3b"],
  ["T3",602,638,"8d94ed663059"],
];

describe("fingerprints of the files this oracle reads", () => {
  it("whole files unchanged", () => {
    expect(sha12(DART_TEST_TEXT)).toBe(DART_TEST_FILE_SHA);
    expect(sha12(DART_ENGINE_TEXT)).toBe(DART_ENGINE_FILE_SHA);
    expect(sha12(TS_FLOW_TEXT)).toBe(TS_FLOW_FILE_SHA);
    expect(sha12(TS_INDEX_TEXT)).toBe(TS_INDEX_FILE_SHA);
  });

  const pinSpan = (label: string, lines: string[], pins: SpanPin[]): void => {
    for (const [name, from, to, want] of pins) {
      it(label + " span " + name + " " + from + ".." + to + " unchanged", () => {
        const text = span(lines, from, to);
        expect(text.split(NL).length).toBe(to - from + 1);
        expect(sha12(text)).toBe(want);
      });
    }
  };

  pinSpan("dart agent_engine", DART_ENGINE_LINES, DART_ENGINE_SPANS);
  pinSpan("ts confirm_flow", TS_FLOW_LINES, TS_FLOW_SPANS);
  pinSpan("dart tool_contract_test", DART_TEST_LINES, DART_TEST_SPANS);
});

/* ===========================================================================*
 * 2. Parse integrity of the Dart oracle.
 *
 * The Dart test file is never executed here (no Dart SDK). Its shape is what
 * ties the replay below to the real thing: group count, test count, expect
 * count and the per-test assertion counts. Counters are taken on the BLANKED
 * source, with one documented exception. group( is the exception worth naming:
 * the raw substring count is 8 while there are 7 group calls, because line 311
 * contains a RegExp .group(1) access. The blanked-source call scan is the
 * authoritative one, and the extra raw hit is asserted rather than ignored.
 * ===========================================================================*/

describe("Dart oracle parse integrity", () => {
  it("seven groups, and the eighth group( substring is a RegExp access", () => {
    const gs = calls(DART_TEST_BLANK, "group");
    expect(gs.length).toBe(7);
    expect(count("group(", DART_TEST_TEXT)).toBe(8);
    expect(count(".group(", DART_TEST_BLANK)).toBe(1);
    expect(linesWith(".group(", DART_TEST_LINES)).toEqual([311]);
    const names = gs.map((i) => firstArgString(DART_TEST_BLANK, i));
    expect(names).toEqual([
      "ToolArgs 类型化访问",
      "注册表作用域与 kind 派生",
      "system prompt 与注册表一致性（D1/D2 回归守卫）",
      "只读模式拦截工具（D3）",
      "破坏性工具确认通道",
      "暂停/恢复不得丢弃等待中的 awaiter（R1）",
      "provide_password",
    ]);
    expect(gs.map((i) => lineOf(DART_TEST_BLANK, i))).toEqual([121, 188, 294, 378, 447, 544, 641]);
  });

  it("twenty-seven tests, and the four confirm tests are the ones expected", () => {
    expect(calls(DART_TEST_BLANK, "test").length).toBe(27);
    expect(calls(DART_TEST_BLANK, "test").map((i) => lineOf(DART_TEST_BLANK, i))).toEqual([
      122, 133, 142, 155, 165, 171, 178, 189, 206, 218, 228, 267, 283, 295, 325, 340, 355,
      379, 417, 448, 497, 545, 602, 642, 657, 669, 678,
    ]);
    const confirmNames = calls(DART_TEST_BLANK, "test")
      .map((i) => ({line: lineOf(DART_TEST_BLANK, i), name: firstArgString(DART_TEST_BLANK, i)}))
      .filter((t) => t.line >= 447 && t.line <= 638)
      .map((t) => t.name);
    expect(confirmNames).toEqual([
      "local_file_delete 必须等用户确认，拒绝时不执行",
      "用户确认后工具才真正执行",
      "等确认时暂停再恢复，旧的确认等待要被唤醒而不是被丢弃",
      "确认超时不得写成用户拒绝",
    ]);
  });

  it("one hundred and six expect calls on every counter basis", () => {
    expect(count("expect(", DART_TEST_TEXT)).toBe(106);
    expect(calls(DART_TEST_BLANK, "expect").length).toBe(106);
    expect(calls(DART_TEST_TEXT, "expect").length).toBe(106);
  });

  it("each confirm test carries the pinned number of assertions, reasons and awaits", () => {
    const rows: Array<[string, number, number, number, number]> = [
      ["T0", 6, 3, 3, 3],
      ["T1", 6, 2, 4, 4],
      ["T2", 6, 4, 6, 9],
      ["T3", 4, 1, 3, 3],
    ];
    const spans = new Map<string, string>(
      DART_TEST_SPANS.map(([n, a, b]) => [n, span(DART_TEST_LINES, a, b)] as [string, string]),
    );
    for (const [name, expects, reasons, awaitsBlank, awaitsRaw] of rows) {
      const raw = spans.get(name) as string;
      const blank = blankComments(raw);
      expect(calls(blank, "expect").length).toBe(expects);
      expect((blank.match(/(^|[^A-Za-z0-9_.])reason:/g) ?? []).length).toBe(reasons);
      // The blanked count is authoritative: T2 keeps three awaits inside comments
      // that name pauseTask/resumeTask, and a raw count would credit them to the
      // test body as if they were real suspension points.
      expect((blank.match(/\bawait\b/g) ?? []).length).toBe(awaitsBlank);
      expect((raw.match(/\bawait\b/g) ?? []).length).toBe(awaitsRaw);
    }
  });

  it("the R1 test is the one that reads the awaiter itself", () => {
    // Blanked: the R1 test names pauseTask/resumeTask inside comments, and a
    // raw needle count would credit those prose mentions to the test body.
    const t2 = blankComments(span(DART_TEST_LINES, 545, 600));
    expect(count("pendingConfirmForTesting", t2)).toBe(1);
    expect(count("isCompleted", t2)).toBe(1);
    expect(count("await pending.future", t2)).toBe(1);
    expect(count("pauseTask", t2)).toBe(1);
    expect(count("resumeTask", t2)).toBe(1);
    expect(count("cancelTask", t2)).toBe(1);
    // Dart's engine exposes isPaused; the port has no such flag. Recorded here so
    // the substitution in the replay below is visible rather than silent.
    expect(count("isPaused", t2)).toBe(1);
    expect(count("isPaused", DART_ENGINE_BLANK)).toBeGreaterThan(0);
    expect(count("isPaused", TS_FLOW_TEXT)).toBe(0);
  });

  it("the timeout test drives the shared timeout collapse, not a fake timer", () => {
    // Blanked: the R1 test names pauseTask/resumeTask inside comments, and a
    // raw needle count would credit those prose mentions to the test body.
    const t3 = blankComments(span(DART_TEST_LINES, 602, 638));
    expect(count("expireConfirmTimeoutForTesting", t3)).toBe(1);
    expect(count("hasPendingConfirm", t3)).toBe(1);
    expect(count("confirmWaitSeconds", t3)).toBe(0);
    expect(count("expireConfirmTimeoutForTesting", DART_ENGINE_BLANK)).toBe(1);
  });

  it("the reject test asserts the observation reaches the model", () => {
    // Blanked: the R1 test names pauseTask/resumeTask inside comments, and a
    // raw needle count would credit those prose mentions to the test body.
    const t0 = blankComments(span(DART_TEST_LINES, 448, 495));
    expect(count("rejectDangerousCommand", t0)).toBe(1);
    expect(count("receivedHistories", t0)).toBe(1);
    expect(count("用户拒绝执行", t0)).toBeGreaterThan(0);
    expect(count("isNot(contains('local_file_delete'))", t0)).toBe(1);
  });

  it("the accept test is the one that really waits", () => {
    // Blanked: the R1 test names pauseTask/resumeTask inside comments, and a
    // raw needle count would credit those prose mentions to the test body.
    const t1 = blankComments(span(DART_TEST_LINES, 497, 541));
    expect(count("confirmDangerousCommand", t1)).toBe(1);
    expect(count("Duration(milliseconds: 1100)", t1)).toBe(1);
    expect(count("confirmWaitSeconds", t1)).toBe(2);
    expect(count("greaterThanOrEqualTo(1)", t1)).toBe(2);
  });
});

/* ===========================================================================*
 * 3. Replaying the four Dart confirm tests against the port.
 *
 * The Dart tests drive a whole AgentEngine through a mock LLM; here the same
 * assertions land on the extracted state machine, which is where that state
 * lives in the port. Timers and the clock are injected, so the ten-minute
 * timeout and the "really wait 1.1s" accounting are decided by the test rather
 * than by wall-clock luck.
 * ===========================================================================*/

class FakeTimer implements ConfirmTimerHandle {
  readonly ms: number;
  cancelled = false;
  fired = false;
  constructor(private readonly fn: () => void, ms: number) {
    this.ms = ms;
  }
  get hasFired(): boolean {
    return this.fired;
  }
  cancel(): void {
    this.cancelled = true;
  }
  /** Fire the callback the way Dart's Timer fires it, to test the identity guard. */
  fire(): void {
    this.fired = true;
    this.fn();
  }
}

interface Harness {
  flow: ConfirmFlow;
  timers: FakeTimer[];
  infos: string[];
  waiting: string[];
  requests: Array<{confirmId: string; prompt: string; timeoutMs?: number; riskLevel?: string}>;
  logs: Array<[string, string]>;
  ctx: {gen: number; mode: PermissionMode; cancelled: boolean; bumps: number};
  clock: {t: number};
  lastTimer: () => FakeTimer;
}

function harness(seedMode?: PermissionMode): Harness {
  const timers: FakeTimer[] = [];
  const infos: string[] = [];
  const waiting: string[] = [];
  const requests: Harness["requests"] = [];
  const logs: Array<[string, string]> = [];
  const ctx = {gen: 7, mode: (seedMode ?? "ask") as PermissionMode, cancelled: false, bumps: 0};
  const clock = {t: 1_000_000};
  const context: ConfirmFlowContext = {
    currentGeneration: () => ctx.gen,
    permissionMode: () => ctx.mode,
    isCancelled: () => ctx.cancelled,
    bumpGeneration: () => {
      ctx.gen += 1;
      ctx.bumps += 1;
    },
  };
  const events: ConfirmFlowEvents = {
    onInfo: (text: string) => infos.push(text),
    onWaitingConfirm: (step: string) => waiting.push(step),
    onConfirmRequest: (req) => requests.push(req as Harness["requests"][number]),
    onLog: (level: "info" | "warn", message: string) => logs.push([level, message]),
  };
  const flow = new ConfirmFlow({
    context,
    events,
    setTimer: (fn: () => void, ms: number): ConfirmTimerHandle => {
      const t = new FakeTimer(fn, ms);
      timers.push(t);
      return t;
    },
    now: () => clock.t,
    newConfirmId: () => "confirm_test_" + String(timers.length + 1),
  });
  return {
    flow,
    timers,
    infos,
    waiting,
    requests,
    logs,
    ctx,
    clock,
    lastTimer: (): FakeTimer => timers[timers.length - 1] as FakeTimer,
  };
}

describe("T0 replay: a destructive tool stops at the confirmation, nothing runs", () => {
  it("hasPendingConfirm is true while the awaiter is unresolved", async () => {
    const h = harness();
    let settled = false;
    const p = h.flow.confirmToolExecution("local_file_delete", "path: /tmp/x.txt").then((v: boolean) => {
      settled = true;
      return v;
    });
    // Dart 466: the tool must stop on the confirmation, it may not run past it.
    expect(h.flow.hasPendingConfirm).toBe(true);
    await new Promise((r) => setTimeout(r, 5));
    // "settled" stands in for the Dart "no result event while waiting" assertion:
    // an execution result can only exist once the awaiter has been resolved.
    expect(settled).toBe(false);
    expect(h.flow.pendingConfirmCommand).toBe("path: /tmp/x.txt");
    h.flow.rejectDangerousCommand();
    expect(await p).toBe(false);
    expect(settled).toBe(true);
  });

  it("the confirmation asks the user in words the user recognises", async () => {
    const h = harness();
    const p = h.flow.confirmToolExecution("local_file_delete", "path: /tmp/x.txt");
    expect(h.infos.some((s) => s.includes("需要确认"))).toBe(true);
    expect(h.infos[0]).toContain("该操作会改动本机文件");
    expect(h.requests.length).toBe(1);
    expect(h.requests[0].timeoutMs).toBe(CONFIRM_TIMEOUT_MS);
    // Dart arms the tool wait without a risk level: only the command path knows the
    // SafetyGuard verdict, so the tool request stays level-free.
    expect(h.requests[0].riskLevel).toBeUndefined();
    expect(h.waiting).toEqual(["等待确认: local_file_delete"]);
    h.flow.rejectDangerousCommand();
    await p;
  });

  it("a refusal feeds the model an observation and never runs the tool", async () => {
    const h = harness();
    const p = h.flow.confirmToolExecution("local_file_delete", "path: /tmp/x.txt");
    h.flow.rejectDangerousCommand();
    expect(await p).toBe(false);
    const refusal = h.flow.toolRefusal(false);
    expect(refusal.reason).toBe("用户拒绝执行该操作");
    expect(refusal.info).toContain("\u274c");
    expect(refusal.observation).toContain("用户拒绝执行该操作");
    // Dart 3425-3439: the model must be told the user refused, or it retries the
    // same delete forever.
    expect(refusal.observation).toContain("观测:");
    expect(refusal.observation).toContain("请用 ask 询问用户希望如何进行");
    expect(refusal.observation).toContain("不要重复尝试");
    expect(h.flow.confirmTimedOut).toBe(false);
    expect(h.flow.taskHadConfirmTimeout).toBe(false);
  });

  it("the tool refusal and the command refusal are one word apart, on purpose", () => {
    const h = harness();
    const toolWording = h.flow.toolRefusal(false).reason;
    expect(toolWording).toBe("用户拒绝执行该操作");
    // Dart asserts both spellings separately (T0 and T2 each check their own), so
    // neither may be folded into a shared constant.
    expect(count("用户拒绝执行此命令", TS_FLOW_TEXT)).toBe(1);
    expect(count("用户拒绝执行该操作", TS_FLOW_TEXT)).toBe(1);
    expect(count("用户拒绝执行此命令", span(TS_FLOW_LINES, 396, 405))).toBe(0);
  });
});

describe("T1 replay: the tool runs only after the user confirms", () => {
  it("confirmDangerousCommand resolves the wait with true", async () => {
    const h = harness();
    const pending = h.flow.confirmToolExecution("local_file_delete", "path: D:\\x\\a.txt");
    expect(h.flow.hasPendingConfirm).toBe(true);
    const awaiter = h.flow.pendingConfirmForTesting;
    expect(awaiter).not.toBeNull();
    h.flow.confirmDangerousCommand();
    expect((awaiter as NonNullable<typeof awaiter>).isDone).toBe(true);
    expect(await pending).toBe(true);
  });

  it("the human reaction time is metered into confirmWaitSeconds", async () => {
    // Dart waits a real 1100ms and asserts >= 1; the injected clock makes the same
    // assertion deterministic. Dart also copies the value onto the task so the tok/s
    // denominator can subtract it - the port has no such field on TaskState, which is
    // a disclosed gap rather than something to fake here.
    const h = harness();
    const pending = h.flow.confirmToolExecution("local_file_delete", "path: /tmp/y.txt");
    h.clock.t += 1100;
    h.flow.confirmDangerousCommand();
    expect(await pending).toBe(true);
    expect(h.flow.confirmWaitSeconds).toBeGreaterThanOrEqual(1);
    h.flow.resetConfirmWaitSeconds();
    expect(h.flow.confirmWaitSeconds).toBe(0);
  });

  it("a superseded task's wait is not charged to the new one", async () => {
    const h = harness();
    const pending = h.flow.confirmToolExecution("local_file_delete", "path: /tmp/z.txt");
    h.ctx.gen += 1;
    h.clock.t += 5000;
    h.flow.wakeForCancelledFinish();
    expect(await pending).toBe(false);
    expect(h.flow.confirmWaitSeconds).toBe(0);
  });

  it("the command path meters the same way and re-validates the mode after the wait", async () => {
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./build-cache", "warn");
    const wait = h.flow.waitForCommandConfirm(h.ctx.gen, "warn");
    h.clock.t += 2000;
    h.flow.confirmDangerousCommand();
    const out = await wait;
    expect(out.kind).toBe("proceed");
    expect(out.reasonCode).toBeNull();
    expect(out.info).toContain("用户已确认");
    expect(h.flow.confirmWaitSeconds).toBe(2);
    h.flow.resetConfirmWaitSeconds();

    const h2 = harness();
    h2.flow.beginDangerousCommand("rm -rf ./build-cache", "warn");
    const wait2 = h2.flow.waitForCommandConfirm(h2.ctx.gen, "warn");
    h2.ctx.mode = "readOnly";
    h2.flow.confirmDangerousCommand();
    const out2 = await wait2;
    // A confirmation dialog raised before the mode switch may not survive it.
    expect(out2.kind).toBe("permission_changed");
    expect(out2.reasonCode).toBe(CONFIRM_REASON_PERMISSION_CHANGED);
    expect(out2.shouldContinue).toBe(true);
    expect(out2.error).toBe("权限档位切换");
    expect(out2.info).toContain("只读");
    expect(out2.observation).toContain("等待确认期间权限档位已切换为只读，命令未执行");
    expect(out2.timedOut).toBe(false);
  });
});

describe("T2 replay (R1): pause wakes the old awaiter instead of dropping it", () => {
  it("wakeForPause completes the captured awaiter with false", async () => {
    const h = harness();
    let settled = false;
    const pending = h.flow.confirmToolExecution("local_file_delete", "path: /tmp/p.txt").then((v: boolean) => {
      settled = true;
      return v;
    });
    expect(h.flow.hasPendingConfirm).toBe(true);
    const awaiter = h.flow.pendingConfirmForTesting;
    expect(awaiter).not.toBeNull();
    h.flow.wakeForPause();
    // Dart 578: complete-before-null is the whole rule; hasPendingConfirm going false
    // cannot tell "woken" from "dropped", so the awaiter itself is inspected.
    expect((awaiter as NonNullable<typeof awaiter>).isDone).toBe(true);
    expect(await pending).toBe(false);
    expect(settled).toBe(true);
    // Dart 581: a reset confirmation closes as "not approved" - never as an implicit
    // grant of a destructive operation.
    expect(await (awaiter as NonNullable<typeof awaiter>).promise).toBe(false);
  });

  it("wakeForPause does not bump the generation and fabricates no refusal", async () => {
    const h = harness();
    const pending = h.flow.confirmToolExecution("local_file_delete", "path: /tmp/p2.txt");
    const genBefore = h.ctx.gen;
    h.flow.wakeForPause();
    expect(h.ctx.gen).toBe(genBefore);
    expect(h.ctx.bumps).toBe(0);
    await pending;
    // Dart 588-592 asserts no info event says 用户拒绝执行此操作. That spelling is only
    // ever written by the Dart test itself - three times there, zero in the engine and
    // zero in the port - so the assertion is vacuous. It is kept tautological here
    // rather than quietly dropped, and the load-bearing half follows below.
    expect(h.infos.join(NL).includes("用户拒绝执行此操作")).toBe(false);
    expect(count("用户拒绝执行此操作", TS_FLOW_TEXT)).toBe(0);
    expect(count("用户拒绝执行此操作", DART_ENGINE_BLANK)).toBe(0);
    // Three raw hits in the Dart test, two of them outside a comment: the event
    // probe and the reason label of its own expect. The third sits in the timeout
    // test's prose comment, so the blanked count is two - the engine and the port
    // both write zero, which is what makes the Dart assertion vacuous.
    expect(count("用户拒绝执行此操作", DART_TEST_TEXT)).toBe(3);
    expect(count("用户拒绝执行此操作", DART_TEST_BLANK)).toBe(2);

    // The real constraint: a pause-driven wake reaches the rejection branch as an
    // ordinary refusal on the command path too - never as a timeout, never silently.
    const h2 = harness();
    h2.flow.beginDangerousCommand("rm -rf ./pause-cmd", "warn");
    const waitCmd = h2.flow.waitForCommandConfirm(h2.ctx.gen, "warn");
    h2.flow.wakeForPause();
    const out = await waitCmd;
    expect(out.kind).toBe("rejected");
    expect(out.timedOut).toBe(false);
    expect(out.reasonCode).toBe(CONFIRM_REASON_USER_REJECTED);
    expect(out.shouldContinue).toBe(true);
    expect(out.observation).toContain("用户拒绝执行此命令");
  });

  it("wakeForPause leaves the pending wait resumable, per Dart", () => {
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./keep", "warn");
    const idBefore = h.flow.pendingConfirmId;
    expect(idBefore).not.toBeNull();
    expect(h.flow.pendingConfirmCommand).toBe("rm -rf ./keep");
    h.flow.wakeForPause();
    // Dart nulls neither the completer field nor the label on the pause path, which is
    // what keeps a later resume coherent; hasPendingConfirm flips only because the
    // awaiter is now completed.
    expect(h.flow.pendingConfirmId).toBe(idBefore);
    expect(h.flow.pendingConfirmCommand).toBe("rm -rf ./keep");
    expect(h.flow.hasPendingConfirm).toBe(false);
    h.flow.wakeForCancelTask();
  });

  it("the confirmation timer is cancelled on the pause path (R2)", () => {
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./timer", "warn");
    const timer = h.lastTimer();
    expect(timer.cancelled).toBe(false);
    h.flow.wakeForPause();
    expect(timer.cancelled).toBe(true);
    timer.fire();
    expect(h.flow.confirmTimedOut).toBe(false);
    h.flow.wakeForCancelTask();
  });

  it("cancelTask wakes the awaiter and drops the pending state (Dart 701-707)", async () => {
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./cancel", "warn");
    const wait = h.flow.waitForCommandConfirm(h.ctx.gen, "warn");
    const awaiter = h.flow.pendingConfirmForTesting;
    expect(awaiter).not.toBeNull();
    const genBefore = h.ctx.gen;
    // Dart cancelTask flips the task status to cancelled before it completes the
    // future, which is what the flow reads through ctx.isCancelled().
    h.ctx.cancelled = true;
    h.flow.wakeForCancelTask();
    expect((awaiter as NonNullable<typeof awaiter>).isDone).toBe(true);
    // Dart 699-714 carries no generation bump: the caller bumps, in its own frame.
    expect(h.ctx.bumps).toBe(0);
    expect(h.ctx.gen).toBe(genBefore);
    expect(h.flow.pendingConfirmId).toBeNull();
    expect(h.flow.pendingConfirmCommand).toBeNull();
    const out = await wait;
    // A cancel wake is reported as a cancellation, never as a refusal the user did
    // not make, and the loop stops instead of re-asking.
    expect(out.kind).toBe("cancelled");
    expect(out.reasonCode).toBe(CONFIRM_REASON_CANCELLED);
    expect(out.shouldContinue).toBe(false);
    expect(out.timedOut).toBe(false);
    expect(h.lastTimer().cancelled).toBe(true);
  });

  it("terminal cancel bumps the generation before it wakes (Dart 930-939)", async () => {
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./term", "warn");
    const genBefore = h.ctx.gen;
    const wait = h.flow.waitForCommandConfirm(genBefore, "warn");
    h.flow.wakeForCancelledFinish();
    expect(h.ctx.gen).toBe(genBefore + 1);
    expect(h.ctx.bumps).toBe(1);
    // Ordering is the whole point: the bump lands in the same frame as the wake, while
    // the await continuation runs later - so the old loop exits at its generation check
    // and never labels this wake a refusal the user did not make (the V3-shaped bug).
    // Observed before awaiting: the wait's own teardown nulls these fields afterwards,
    // and that teardown is Dart 2669-2671, not the wake path.
    const awaiter = h.flow.pendingConfirmForTesting;
    expect(awaiter).not.toBeNull();
    expect((awaiter as NonNullable<typeof awaiter>).isDone).toBe(true);
    expect(h.flow.pendingConfirmId).not.toBeNull();
    expect(h.flow.pendingConfirmCommand).toBeNull();
    const out = await wait;
    expect(out.kind).toBe("generation_invalid");
    expect(out.reasonCode).toBe(CONFIRM_REASON_GENERATION_INVALID);
    expect(out.shouldContinue).toBe(false);
    expect(out.timedOut).toBe(false);
    expect(out.info).toBeNull();
    expect(out.observation).toBeNull();
    expect(h.lastTimer().cancelled).toBe(true);
    h.flow.wakeForCancelTask();
  });

  it("finishCleanup touches only the timer (Dart 3809-3811)", () => {
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./fin", "warn");
    const idBefore = h.flow.pendingConfirmId;
    const timer = h.lastTimer();
    h.flow.finishCleanup();
    expect(timer.cancelled).toBe(true);
    // Deliberate: _finishTask runs after the wait has been exited, so the awaiter is
    // left alone. Do not "tidy" this path into the other wake paths.
    expect(h.flow.pendingConfirmId).toBe(idBefore);
    expect(h.flow.hasPendingConfirm).toBe(true);
    expect(h.ctx.bumps).toBe(0);
    h.flow.wakeForCancelTask();
  });
});

describe("T3 replay: a confirmation timeout is not written as a user refusal", () => {
  it("expireConfirmTimeoutForTesting logs a timeout and resolves false", () => {
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./t3", "warn");
    expect(h.flow.hasPendingConfirm).toBe(true);
    // src/index.ts reads the label off the flow when collapsing a timeout, so the
    // log line names the command that is actually waiting, not an arbitrary string.
    h.flow.expireConfirmTimeoutForTesting(h.flow.pendingConfirmCommand ?? "");
    const logged = h.logs.map((entry: [string, string]) => entry[1]).join(NL);
    expect(logged).toContain("超时");
    expect(logged).toContain("确认超时(10min)，自动拒绝: rm -rf ./t3");
    expect(logged.includes("用户拒绝")).toBe(false);
    expect(h.flow.confirmTimedOut).toBe(true);
    expect(h.flow.taskHadConfirmTimeout).toBe(true);
    expect(h.flow.hasPendingConfirm).toBe(false);
    h.flow.wakeForCancelTask();
  });

  it("the wait closes as a timeout, and the timer is not left armed (R2)", async () => {
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./t3b", "blocked");
    const timer = h.lastTimer();
    expect(timer.ms).toBe(CONFIRM_TIMEOUT_MS);
    const wait = h.flow.waitForCommandConfirm(h.ctx.gen, "blocked");
    h.flow.expireConfirmTimeoutForTesting("rm -rf ./t3b");
    const out = await wait;
    expect(out.kind).toBe("rejected");
    expect(out.timedOut).toBe(true);
    expect(out.reasonCode).toBe(CONFIRM_REASON_TIMEOUT);
    expect(out.error).toBe("确认超时");
    expect(out.info).toContain("超时");
    expect((out.info as string).includes("用户拒绝")).toBe(false);
    expect(timer.cancelled).toBe(true);
    h.flow.wakeForCancelTask();
  });

  it("a timeout refusal tells the model to restate, not to give up", () => {
    const h = harness();
    const refusal = h.flow.toolRefusal(true);
    expect(refusal.reason).toBe("确认超时（10 分钟无响应），已自动拒绝");
    expect(refusal.info.startsWith(String.fromCharCode(0x23f1))).toBe(true);
    expect(refusal.observation).toContain("用户可能只是暂时离开");
    expect(refusal.observation).toContain("重申一次");
    expect(refusal.observation.includes("不要重复尝试")).toBe(false);
  });

  it("a stale timer cannot mislabel the next real refusal", async () => {
    // Dart clears _confirmTimedOut at every new wait for exactly this reason: a
    // leftover true turns the next genuine "user refused" into a timeout.
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./first", "warn");
    const first = h.lastTimer();
    const w1 = h.flow.waitForCommandConfirm(h.ctx.gen, "warn");
    h.flow.expireConfirmTimeoutForTesting("rm -rf ./first");
    const o1 = await w1;
    expect(o1.timedOut).toBe(true);
    expect(h.flow.confirmTimedOut).toBe(true);
    h.flow.beginDangerousCommand("rm -rf ./second", "warn");
    expect(h.flow.confirmTimedOut).toBe(false);
    const w2 = h.flow.waitForCommandConfirm(h.ctx.gen, "warn");
    first.fire();
    expect(h.flow.confirmTimedOut).toBe(false);
    h.flow.rejectDangerousCommand();
    const o2 = await w2;
    expect(o2.timedOut).toBe(false);
    expect(o2.reasonCode).toBe(CONFIRM_REASON_USER_REJECTED);
    h.flow.wakeForCancelTask();
  });

  it("the identity guard makes an old timer a no-op even while a new wait runs", () => {
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./guard", "warn");
    const stale = h.lastTimer();
    h.flow.wakeForCancelTask();
    h.flow.beginDangerousCommand("rm -rf ./guard2", "warn");
    const live = h.lastTimer();
    expect(live).not.toBe(stale);
    stale.fire();
    expect(h.flow.confirmTimedOut).toBe(false);
    expect(h.flow.hasPendingConfirm).toBe(true);
    live.fire();
    expect(h.flow.confirmTimedOut).toBe(true);
    expect(h.flow.hasPendingConfirm).toBe(false);
    h.flow.wakeForCancelTask();
  });

  it("the per-task timeout flag survives until the task restarts", () => {
    const h = harness();
    h.flow.beginDangerousCommand("rm -rf ./sticky", "warn");
    h.flow.expireConfirmTimeoutForTesting("rm -rf ./sticky");
    expect(h.flow.taskHadConfirmTimeout).toBe(true);
    h.flow.beginDangerousCommand("rm -rf ./later", "warn");
    h.flow.rejectDangerousCommand();
    expect(h.flow.taskHadConfirmTimeout).toBe(true);
    h.flow.resetTaskHadConfirmTimeout();
    expect(h.flow.taskHadConfirmTimeout).toBe(false);
    h.flow.wakeForCancelTask();
  });
});

/* ===========================================================================*
 * 4. Structural isomorphism with the Dart engine.
 *
 * These assertions compare shapes, not behaviour: who is allowed to write each
 * transient field, in what order the post-wait branches run, which reason codes
 * are in the blocked-command set. They are the guard that keeps a future "tidy
 * up" in TypeScript from quietly re-introducing the hang or the fabricated
 * refusal. Line-number tables were measured off the fingerprints above; if a
 * hash is still green and a table is red, the table was wrong - fix the table.
 * ===========================================================================*/

describe("Dart/TS writer census for the confirmation transients", () => {
  it("the completer is nulled by exactly three writers on each side", () => {
    // Dart: the tool-wait teardown (441), cancelTask (706), the command-wait teardown
    // (2671). TS: waitForCommandConfirm teardown (285), confirmToolExecution teardown
    // (386), wakeForCancelTask (449). Three each, and nothing else - which is the hard
    // proof that pause, terminal cancel and _finishTask never drop the awaiter.
    expect(linesWith("_confirmCompleter = null;", DART_ENGINE_LINES)).toEqual([441, 706, 2671]);
    expect(linesWith("this._confirmCompleter = null;", TS_FLOW_LINES)).toEqual([287, 388, 451]);
  });

  it("pause, terminal cancel and finishCleanup never null the completer", () => {
    for (const [name, from, to] of [
      ["wakeForPause", 479, 486],
      ["wakeForCancelledFinish", 463, 472],
      ["finishCleanup", 493, 496],
    ] as Array<[string, number, number]>) {
      expect(count("this._confirmCompleter = null;", span(TS_FLOW_LINES, from, to))).toBe(0);
      expect(count("resolve(", span(TS_FLOW_LINES, from, to))).toBe(name === "wakeForPause" || name === "wakeForCancelledFinish" ? 1 : 0);
    }
    // Dart's two pause/cancel wake paths mirror it: complete, then reset the fields.
    expect(count("_confirmCompleter!.complete(false)", span(DART_ENGINE_LINES, 1040, 1062))).toBe(1);
      expect(count("_confirmCompleter", span(DART_ENGINE_LINES, 1040, 1062))).toBe(3);
    expect(count("_confirmCompleter = null", span(DART_ENGINE_LINES, 1040, 1062))).toBe(0);
    expect(count("_confirmCompleter!.complete(false)", span(DART_ENGINE_LINES, 925, 945))).toBe(1);
    expect(count("_confirmCompleter = null", span(DART_ENGINE_LINES, 925, 945))).toBe(0);
      // Blanked basis: the raw Dart span still mentions the field in the comment that
      // explains why it is NOT cleared ("不清 _confirmCompleter / _choiceCompleter"),
      // which is itself the evidence - the assertion below is about code, not prose.
      expect(count("_confirmCompleter", span(DART_ENGINE_BLANK_LINES, 3805, 3815))).toBe(0);
      expect(count("_confirmCompleter", span(DART_ENGINE_LINES, 3805, 3815))).toBe(1);
  });

  it("every wake path pairs a timer cancel with a timer null (R2)", () => {
    // Seven cancel()/null pairs on each side, each on consecutive lines in TS.
    expect(linesWith("_confirmTimeoutTimer?.cancel();", DART_ENGINE_LINES)).toEqual([439, 456, 704, 938, 1054, 2669, 3809]);
    expect(linesWith("_confirmTimeoutTimer = null;", DART_ENGINE_LINES)).toEqual([440, 457, 705, 939, 1055, 2670, 3810]);
    expect(linesWith("this._confirmTimeoutTimer?.cancel();", TS_FLOW_LINES)).toEqual([285, 386, 423, 449, 470, 484, 494]);
    expect(linesWith("this._confirmTimeoutTimer = null;", TS_FLOW_LINES)).toEqual([286, 387, 424, 450, 471, 485, 495]);
  });

  it("the per-wait timeout flag is cleared before every new wait", () => {
    // Dart resets it twice (412 tool timer, 2639 command timer) plus the field
    // declaration; TS converges both sites into one arm() line. That is a deliberate
    // collapse, not an omission: one timer, one reset, still inside the arm.
    expect(linesWith("_confirmTimedOut = false;", DART_ENGINE_LINES)).toEqual([86, 412, 2639]);
    expect(linesWith("this._confirmTimedOut = false;", TS_FLOW_LINES)).toEqual([238]);
    expect(offset(span(TS_FLOW_LINES, 231, 250), "this._confirmCompleter = new CompleterLike", "arm creates the awaiter")).toBeGreaterThanOrEqual(0);
    expect(count("this._confirmTimedOut = false;", span(TS_FLOW_LINES, 231, 250))).toBe(1);
  });

  it("both waits await the same completer and meter the same way", () => {
    expect(linesWith("await _confirmCompleter!.future", DART_ENGINE_LINES)).toEqual([433, 2668]);
    expect(linesWith("_confirmWaitSeconds +=", DART_ENGINE_LINES)).toEqual([437, 2674]);
    expect(linesWith("this._confirmWaitSeconds +=", TS_FLOW_LINES)).toEqual([291, 384]);
    // TS: the command wait accumulates before it branches (teardown-then-accumulate),
    // the tool wait accumulates before it tears down - Dart's own two orders, kept
    // distinct on purpose because the tool path also nulls the label.
    expect(count("this._confirmWaitSeconds +=", span(TS_FLOW_LINES, 279, 361))).toBe(1);
    expect(count("this._confirmWaitSeconds +=", span(TS_FLOW_LINES, 365, 393))).toBe(1);
    expect(span(TS_FLOW_LINES, 365, 393).indexOf("this._confirmWaitSeconds +=") <
      span(TS_FLOW_LINES, 365, 393).indexOf("this._confirmCompleter = null;")).toBe(true);
    expect(span(TS_FLOW_LINES, 279, 361).indexOf("this._confirmCompleter = null;") <
      span(TS_FLOW_LINES, 279, 361).indexOf("this._confirmWaitSeconds +=")).toBe(true);
  });

  it("generation bumps: one inside the flow, the rest with the callers", () => {
    // Dart bumps at 770 (startTask), 931 (terminal cancel) and 1096 (resumeTask).
    expect(linesWith("_currentTaskGeneration++", DART_ENGINE_LINES)).toEqual([770, 931, 1096]);
    // The flow owns only the terminal-cancel bump, and it owns it FIRST inside the wake
    // (462, before the resolve at 464). startTask / resume bumps belong to the caller, and
    // the port keeps exactly two write sites in src/index.ts: the flow context (181) and
    // the GenerationSource injected into the engine (249). engine.run() bumps THAT one, so
    // Dart’s single bump per startTask survives without the server advancing a second,
    // parallel counter - the gate’s post-await check would then always look current (R1).
    expect(linesWith("this.ctx.bumpGeneration();", TS_FLOW_LINES)).toEqual([464]);
    const wake = span(TS_FLOW_LINES, 463, 472);
    expect(wake.indexOf("this.ctx.bumpGeneration()")).toBeLessThan(wake.indexOf("this._confirmCompleter.resolve("));
    expect(linesWith("serverGeneration++", TS_INDEX_LINES)).toEqual([181, 249]);
  });

  it("post-wait branch order matches Dart", () => {
    const dartCmd = span(DART_ENGINE_LINES, 2631, 2726);
    const dartOrder = [
      offset(dartCmd, "onSuccess(false, 'generation_invalid_during_confirm'", "dart generation branch"),
      offset(dartCmd, "'cancelled_during_confirm'", "dart cancelled branch"),
      offset(dartCmd, "onSuccess(false, timedOut ? 'confirm_timeout' : 'user_rejected'", "dart refusal branch"),
      offset(dartCmd, "CommandGateDecision.reject", "dart permission re-validation"),
      offset(dartCmd, "onSuccess(false, 'permission_changed_during_confirm'", "dart permission branch"),
    ];
    for (let i = 1; i < dartOrder.length; i++) {
      expect(dartOrder[i] as number).toBeGreaterThan(dartOrder[i - 1] as number);
    }
    const tsCmd = span(TS_FLOW_LINES, 279, 361);
    const tsOrder = [
      offset(tsCmd, "CONFIRM_REASON_GENERATION_INVALID", "ts generation branch"),
      offset(tsCmd, "CONFIRM_REASON_CANCELLED", "ts cancelled branch"),
      offset(tsCmd, "CONFIRM_REASON_TIMEOUT", "ts timeout reason"),
      offset(tsCmd, "CONFIRM_REASON_PERMISSION_CHANGED", "ts permission branch"),
      offset(tsCmd, "kind: \"proceed\"", "ts proceed tail"),
    ];
    for (let i = 1; i < tsOrder.length; i++) {
      expect(tsOrder[i] as number).toBeGreaterThan(tsOrder[i - 1] as number);
    }
    // Re-validating the gate after the wait is what stops a pre-switch dialog from
    // executing under a newly read-only mode; both sides must re-decide, not reuse.
    expect(count("decideCommand(", span(TS_FLOW_LINES, 279, 361))).toBe(1);
    expect(count("decideCommand(safetyLevel, _permissionMode)", span(DART_ENGINE_LINES, 2631, 2726))).toBe(1);
  });

  it("the blocked-reason set is the same six members on both sides", () => {
    const setSpan = span(DART_ENGINE_LINES, 2370, 2377);
    const members: string[] = [];
    const re = /'([a-z_]+)'/g;
    let m = re.exec(setSpan);
    while (m !== null) {
      members.push(m[1] as string);
      m = re.exec(setSpan);
    }
    expect(members).toEqual([...BLOCKED_COMMAND_REASONS]);
    expect(BLOCKED_COMMAND_REASONS.length).toBe(6);
    for (const reason of BLOCKED_COMMAND_REASONS) expect(isBlockedCommandReason(reason)).toBe(true);
    // The seventh reason is deliberately outside the set: a superseded attempt does
    // not count as this task's step.
    expect(members.includes(CONFIRM_REASON_GENERATION_INVALID)).toBe(false);
    expect(isBlockedCommandReason(CONFIRM_REASON_GENERATION_INVALID)).toBe(false);
    expect(isBlockedCommandReason("cancelled_during_confirm")).toBe(false);
    expect(count("_blockedCommandReasons", DART_ENGINE_BLANK)).toBe(2);
  });

  it("refusal spellings stay separate across the port", () => {
    // Dart writes 用户拒绝执行此命令 on the command path and 用户拒绝执行该操作 on the tool
    // path; the port keeps both, once each, and never merges them into a constant.
    expect(count("用户拒绝执行此命令", DART_ENGINE_TEXT)).toBe(1);
    expect(count("用户拒绝执行该操作", DART_ENGINE_TEXT)).toBe(1);
    expect(count("用户拒绝执行此命令", TS_FLOW_TEXT)).toBe(1);
    expect(count("用户拒绝执行该操作", TS_FLOW_TEXT)).toBe(1);
    expect(count("确认超时（10 分钟无响应），已自动拒绝", DART_ENGINE_TEXT)).toBe(2);
    expect(count("确认超时（10 分钟无响应），已自动拒绝", TS_FLOW_TEXT)).toBe(2);
    // Disclosed deviation: Dart spells the tool timer's log line differently from the
    // command timer's ("工具确认超时(10min)..." once, at agent_engine.dart 415). The port
    // arms one shared timer through arm(), so the 工具 variant has no TS counterpart
    // while the plain form still appears twice - once from arm(), once from
    // expireConfirmTimeoutForTesting.
    expect(count("确认超时(10min)，自动拒绝: ", DART_ENGINE_TEXT)).toBe(3);
    expect(count("工具确认超时(10min)，自动拒绝: ", DART_ENGINE_TEXT)).toBe(1);
    expect(count("确认超时(10min)，自动拒绝: ", TS_FLOW_TEXT)).toBe(2);
    expect(count("工具确认超时(10min)，自动拒绝: ", TS_FLOW_TEXT)).toBe(0);
    expect(linesWith("确认超时(10min)，自动拒绝: ", TS_FLOW_LINES)).toEqual([243, 420]);
  });

  it("the barrel exports every runtime value confirm_flow exports", () => {
    const exported: string[] = [];
    for (const line of TS_FLOW_LINES) {
      const m = /^export (?:const|function|class) ([A-Za-z_][A-Za-z0-9_]*)/.exec(line);
      if (m !== null) exported.push(m[1] as string);
    }
    expect(exported.sort()).toEqual([
      "BLOCKED_COMMAND_REASONS",
      "CONFIRM_REASON_CANCELLED",
      "CONFIRM_REASON_GENERATION_INVALID",
      "CONFIRM_REASON_PERMISSION_CHANGED",
      "CONFIRM_REASON_TIMEOUT",
      "CONFIRM_REASON_USER_REJECTED",
      "CONFIRM_TIMEOUT_MS",
      "ConfirmFlow",
      "formatObservationFailure",
      "isBlockedCommandReason",
    ]);
    const missingReact = exported.filter((n) => !(n in reactBarrel));
    const missingRoot = exported.filter((n) => !(n in rootBarrel));
    expect(missingReact).toEqual([]);
    expect(missingRoot).toEqual([]);
    // Types are erased at runtime, so their surface is checked textually instead.
    const typeNames = [
      "BlockedCommandReason", "ConfirmOutcomeKind", "CommandConfirmOutcome", "ConfirmRequestShape",
      "ConfirmFlowContext", "ConfirmFlowEvents", "ConfirmTimerHandle", "ConfirmFlowOptions",
    ];
    for (const t of typeNames) {
      expect(count(t, REACT_INDEX_TEXT)).toBeGreaterThanOrEqual(1);
      expect(count(t, TS_INDEX_TEXT)).toBeGreaterThanOrEqual(1);
    }
  });

  it("two callers wire the flow: the RPC host owns it, the engine is injected with it", () => {
    // src/index.ts still OWNS the instance (the flow singleton, the rpc:confirm handler
    // and the task-start wake/reset trio live there), and it hands the SAME instance to
    // the engine at construction time. Dart has one _confirmCompleter: two ConfirmFlow
    // objects would let rpc:confirm answer a wait the engine is not awaiting.
    expect(linesWith("confirmFlow.wakeForCancelTask()", TS_INDEX_LINES)).toEqual([269]);
    expect(linesWith("confirmFlow.reset", TS_INDEX_LINES)).toEqual([271, 272]);
    expect(linesWith("finishCleanup()", TS_INDEX_LINES)).toEqual([286]);
    expect(linesWith("new ConfirmFlow", TS_INDEX_LINES)).toEqual([175]);
    expect(linesWith("confirmFlowForTesting", TS_INDEX_LINES)).toEqual([406]);
    expect(count("expireConfirmTimeoutForTesting", TS_INDEX_TEXT)).toBe(3);
    // rpc:cancelTask wakes through the optional chain (confirmFlow ? .), a DIFFERENT
    // needle that is not counted above: cancel delegates to engine.cancel(), which
    // wakes only when a wait is outstanding (Dart guards nothing at 699-707 / 933-936).
    // so the two wake needles below stay distinguishable.
    const files: string[] = [];
    const walk = (dir: string): void => {
      for (const entry of readdirSync(dir, {withFileTypes: true})) {
        const p = dir + "/" + entry.name;
        if (entry.isDirectory()) walk(p);
        else if (entry.name.endsWith(".ts")) files.push(p);
      }
    };
    walk(SRC_DIR);
    const namers = files
      .filter((f) => readText(f).includes("confirm_flow"))
      .map((f) => f.slice(SRC_DIR.length + 1).split("\\").join("/"))
      .sort();
    expect(namers).toEqual(["index.ts", "react/confirm_flow.ts", "react/engine.ts", "react/index.ts", "utils/permission_policy.ts"]);
    // react/engine.ts now names it exactly ONCE - the import that brings ConfirmFlow
    // and formatObservationFailure into the command gate. More than one occurrence would
    // mean a second wiring point; zero would mean the gate lost its flow.
    // permission_policy.ts mentions the module only in a comment explaining why the gate
    // lives there rather than inside the flow.
    expect(count("confirm_flow", readText(ENGINE_TS))).toBe(1);
    expect(count("confirm_flow", readText(POLICY))).toBe(1);
    expect(count("import", span(POLICY_LINES, 21, 21))).toBe(0);
  });
});
