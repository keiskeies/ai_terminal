// Round 131: oracle replay of src/utils/operation_report.ts - the 1:1 port of
// ai_terminal/lib/models/operation_report.dart (OperationBadge 8-19, OperationChange
// 23-75, OperationReport 81-363: ctor 119-139 / getters 141-146 / toJson 148-169 /
// fromJson 171-193 / tolerance helpers 195-237 / extractors 239-363), the plan-step
// wire semantics of plan_step.dart 25-74, and the deterministic conclusion templates
// of agent_engine.dart 3709-3723 - replayed against the five groups of
// ai_terminal/test/operation_report_test.dart (20 tests / 68 assertions).
//
// No Dart SDK runs here: every INPUT and every EXPECTATION below is lifted out of the
// Dart sources at run time, so a Dart-side edit (a renamed section label, a new status
// alias, a reworded conclusion template, a new toJson key) surfaces as a changed needle
// or a hard parse error instead of a stale hand-copied literal. The file is ASCII-pure
// for the same reason - the CJK stays in the oracle.
//
// Two sanctioned skips, each pinned by count so a Dart-side new assertion cannot slip:
//  - group "Agent model metadata" (oracle 175-196): only the failureKind half replays.
//    AgentTask.copyWith(stepIndex / elapsedSeconds) has no Node counterpart - engine.ts
//    tracks operationId but no stepIndex / elapsedSeconds (asserted below), the same gap
//    that keeps the report emit open (docs/agent-core-migration-design.md D3).
//  - group "report event" (oracle 217-234): Node has no AgentEvent.report() factory and
//    event.schema.json declares no report payload. Inventing either before
//    VerificationDetector (agent_engine.dart 2879-2890) and ChangeRecordService
//    (2894-2912, 3150-3172) exist would advertise a sheet with an empty evidence
//    section. The payload SLOT (rpc/schema.ts:108) is exercised by building the event
//    object directly, and the absence of the schema property is pinned - the day the
//    payload lands, that assertion goes red on purpose.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import type {
  AgentEvent, AgentFinishState, OperationBadge, OperationChange, OperationReport, PlanStep,
  PlanStepStatus,
} from "../src/rpc/schema.js";
import {parse as parseStream} from "../src/react/parser.js";
import {CommandFailureKind} from "../src/tools/orchestrator.js";
import {
  CONCLUSION_FALLBACK, MAX_CONCLUSION_CHARS, MAX_DETAILS_CHARS, SECTION_LABELS,
  badgeFromJson, badgeToJson, changeCanRollback, changeFromJson, changeHasDiff, changeToJson,
  cleanAction, clipReportText, cutAtNextSection, defaultConclusion, extractConclusion,
  extractDetails, extractNextActions, extractSection, matchSection, planStepFromJson,
  planStepIsDone, planStepParseStatus, planStepToJson, reportCommandCount, reportFromJson,
  reportToJson, sectionPatternsFor,
} from "../src/utils/operation_report.js";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const linesOf = (rel: string): string[] =>
  readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL).split(NL);

const MODEL = linesOf("../../ai_terminal/lib/models/operation_report.dart");
const PLAN = linesOf("../../ai_terminal/lib/models/plan_step.dart");
const ENGINE = linesOf("../../ai_terminal/lib/services/agent_engine.dart");
const ORACLE = linesOf("../../ai_terminal/test/operation_report_test.dart");
const MINE = linesOf("../src/utils/operation_report.ts");
const ENGINE_TS = linesOf("../src/react/engine.ts");
const SCHEMA_TS = linesOf("../src/rpc/schema.ts");
const EVENT_SCHEMA = readFileSync(HERE + "../schema/event.schema.json", "utf-8");

// ---- Dart literal readers ---------------------------------------------------
const SQ = /'((?:[^'\\]|\\.)*)'/g;
const RQ = /r'([^']*)'/g;
const DQ = /"((?:[^"\\]|\\.)*)"/g;
const NUM = /(-?\d+)/g;
const Q3 = String.fromCharCode(39, 39, 39);

// Dart escape rules for a non-raw single-quoted string. These files use \n, \\
// and \$ only; an unknown escape keeps its character (never happens here).
function dartStr(raw: string): string {
  let out = "";
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] !== "\\") { out += raw[i]; continue; }
    const next = raw[i + 1];
    i++;
    if (next === "n") out += NL;
    else if (next === "r") out += String.fromCharCode(13);
    else if (next === "t") out += String.fromCharCode(9);
    else out += next;
  }
  return out;
}

function litsOpt(src: string[], lineNo: number): string[] {
  const line = src[lineNo - 1];
  if (line === undefined) throw new Error("no Dart line " + lineNo);
  SQ.lastIndex = 0;
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = SQ.exec(line)) !== null) out.push(dartStr(m[1]));
  return out;
}

function lits(src: string[], lineNo: number): string[] {
  const out = litsOpt(src, lineNo);
  if (out.length === 0) throw new Error("no Dart string literal on line " + lineNo);
  return out;
}

function lit(src: string[], lineNo: number, idx = 0): string {
  const v = lits(src, lineNo)[idx];
  if (v === undefined) throw new Error("no Dart literal #" + idx + " on line " + lineNo);
  return v;
}

function rawlits(src: string[], lineNo: number): string[] {
  const line = src[lineNo - 1];
  if (line === undefined) throw new Error("no Dart line " + lineNo);
  RQ.lastIndex = 0;
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = RQ.exec(line)) !== null) out.push(m[1]);
  if (out.length === 0) throw new Error("no Dart raw literal on line " + lineNo);
  return out;
}

function rawlit(src: string[], lineNo: number, idx = 0): string {
  const v = rawlits(src, lineNo)[idx];
  if (v === undefined) throw new Error("no Dart raw literal #" + idx + " on line " + lineNo);
  return v;
}

function tsLit(src: string[], lineNo: number, idx = 0): string {
  const line = src[lineNo - 1];
  if (line === undefined) throw new Error("no TS line " + lineNo);
  DQ.lastIndex = 0;
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = DQ.exec(line)) !== null) out.push(JSON.parse(m[0]) as string);
  const v = out[idx];
  if (v === undefined) throw new Error("no TS string literal #" + idx + " on line " + lineNo);
  return v;
}

// Name-anchored so the TS port can gain or lose header lines without breaking.
function tsNamed(name: string): string {
  const re = new RegExp("^(?:export )?const " + name + " =");
  const line = MINE.find((l) => re.test(l));
  if (line === undefined) throw new Error("no such const in the TS port: " + name);
  DQ.lastIndex = 0;
  const m = DQ.exec(line);
  if (m === null) throw new Error("no string literal on the const line for " + name);
  return JSON.parse(m[0]) as string;
}

function nums(src: string[], lineNo: number): number[] {
  const line = src[lineNo - 1];
  if (line === undefined) throw new Error("no Dart line " + lineNo);
  NUM.lastIndex = 0;
  const out: number[] = [];
  let m: RegExpExecArray | null;
  while ((m = NUM.exec(line)) !== null) out.push(Number(m[1]));
  if (out.length === 0) throw new Error("no number on Dart line " + lineNo);
  return out;
}

function num(src: string[], lineNo: number, idx = 0): number {
  const v = nums(src, lineNo)[idx];
  if (v === undefined) throw new Error("no number #" + idx + " on Dart line " + lineNo);
  return v;
}

// A Dart triple-quoted fixture, body only: the code before the opening quotes and the
// trailing quote plus semicolon are dropped.
function tripleBlock(src: string[], from: number, to: number): string {
  const body = src.slice(from - 1, to).join(NL);
  const open = body.indexOf(Q3);
  if (open < 0) throw new Error("no triple quote at Dart line " + from);
  const rest = body.slice(open + 3);
  const close = rest.lastIndexOf(Q3);
  if (close < 0) throw new Error("unterminated triple quote before Dart line " + to);
  return rest.slice(0, close);
}

// Fill one Dart interpolation hole: 'a $name b' -> 'a' + value + 'b'.
function interp(text: string, marker: string, value: string): string {
  const parts = text.split(marker);
  if (parts.length !== 2) {
    throw new Error("expected exactly one " + marker + " in " + JSON.stringify(text));
  }
  return parts[0] + value + parts[1];
}

function statusAt(src: string[], lineNo: number): PlanStepStatus {
  const m = /PlanStepStatus\.(\w+)/.exec(src[lineNo - 1] ?? "");
  if (m === null) throw new Error("no PlanStepStatus on Dart line " + lineNo);
  return m[1] as PlanStepStatus;
}

// plan_step.dart 18-23: the constructor default, lifted rather than typed.
function ctorStatus(): PlanStepStatus {
  for (let n = 18; n <= 23; n++) {
    const m = /this\.status = PlanStepStatus\.(\w+)/.exec(PLAN[n - 1]);
    if (m !== null) return m[1] as PlanStepStatus;
  }
  throw new Error("no status default in plan_step.dart 18-23");
}

// plan_step.dart 48-74: the alias groups of parseStatus, as Dart wrote them.
function aliasGroups(): {status: PlanStepStatus; aliases: string[]}[] {
  const groups: {status: PlanStepStatus; aliases: string[]}[] = [];
  let cur: string[] = [];
  for (let n = 49; n <= 73; n++) {
    const cm = /^case '([^']*)':$/.exec(PLAN[n - 1].trim());
    if (cm !== null) { cur.push(cm[1]); continue; }
    const rm = /^return PlanStepStatus\.(\w+);$/.exec(PLAN[n - 1].trim());
    if (rm !== null) { groups.push({status: rm[1] as PlanStepStatus, aliases: cur}); cur = []; }
  }
  return groups;
}

const LABELS = [...SECTION_LABELS];

// ============================================================================
describe("oracle census: the Dart sources we replay against", () => {
  const count = (src: string[], re: RegExp): number => src.join(NL).split(re).length - 1;

  it("Dart oracle shape: 5 groups / 20 tests / 68 assertions", () => {
    expect(count(ORACLE, /[^A-Za-z_]group\(/g)).toBe(5);
    expect(count(ORACLE, /[^A-Za-z_]test\(/g)).toBe(20);
    expect(count(ORACLE, /expect\(/g)).toBe(68);
  });

  it("Dart model shape: 3 classes, 3 toJson, 3 fromJson, 17 statics, 7 getters", () => {
    expect(count(MODEL, /^class /gm)).toBe(3);
    expect(count(MODEL, /Map<String, dynamic> toJson/g)).toBe(3);
    expect(count(MODEL, /factory \w+\.fromJson/g)).toBe(3);
    expect(count(MODEL, /^  static /gm)).toBe(17);
    expect(count(MODEL, /  static const /g)).toBe(3);
    expect(count(MODEL, /  bool get |  int get /g)).toBe(7);
  });

  it("Dart plan-step shape: 5 statuses, 17 aliases, 5 return arms", () => {
    expect(count(PLAN, /^  [a-zA-Z]+,$/gm)).toBe(5);
    expect(count(PLAN, /case '/g)).toBe(17);
    expect(count(PLAN, /return PlanStepStatus\./g)).toBe(5);
  });

  it("engine has one defaultConclusion helper and one call site for it", () => {
    expect(count(ENGINE, /_defaultConclusion/g)).toBe(2);
    expect(count(ENGINE, /String _defaultConclusion\(/g)).toBe(1);
  });
});

// ============================================================================
describe("constants and regex drift lock (model 244-246, 250, 262-270, 330-363)", () => {
  it("the four section labels equal Dart 244, in order", () => {
    expect(LABELS).toEqual(lits(MODEL, 244));
    expect(LABELS.length).toBe(4);
  });

  it("the two clipping budgets equal Dart 245-246", () => {
    expect(MAX_CONCLUSION_CHARS).toBe(num(MODEL, 245));
    expect(MAX_DETAILS_CHARS).toBe(num(MODEL, 246));
    expect(MAX_CONCLUSION_CHARS).toBe(600);
    expect(MAX_DETAILS_CHARS).toBe(8000);
  });

  it("the conclusion fallback equals Dart 250", () => {
    expect(CONCLUSION_FALLBACK).toBe(lit(MODEL, 250));
  });

  it("clipReportText trims first, then cuts at max with the Dart ellipsis (359-363)", () => {
    const template = lit(MODEL, 362); // the _clip return template
    const ellipsis = template.slice(template.lastIndexOf("}") + 1);
    expect(ellipsis.length).toBe(1);
    const long = "x".repeat(MAX_CONCLUSION_CHARS + 7);
    expect(clipReportText(long, MAX_CONCLUSION_CHARS))
      .toBe("x".repeat(MAX_CONCLUSION_CHARS) + ellipsis);
    expect(clipReportText("   keep me   ", 30)).toBe("keep me");
    expect(clipReportText("short", 5)).toBe("short");
  });

  it("the two placeholder next-actions equal Dart 322", () => {
    const ph1 = lit(MODEL, 322, 0);
    const ph2 = lit(MODEL, 322, 1);
    const raw = LABELS[0] + ": ok" + NL + LABELS[3] + ": " + ph1 + NL + "- " + ph2;
    expect(extractNextActions(raw)).toEqual([]);
  });

  it("the five helper regex bodies equal the Dart raw literals (source level)", () => {
    expect(tsNamed("PARAGRAPH_BREAK")).toBe(rawlit(MODEL, 262));
    expect(tsNamed("HEADING_PREFIX")).toBe(rawlit(MODEL, 336));
    expect(tsNamed("NEXT_SECTION_MARK")).toBe(rawlit(MODEL, 330));
    expect(tsNamed("BULLET_PREFIX")).toBe(rawlit(MODEL, 354));
    expect(tsNamed("NUMBERED_PREFIX")).toBe(rawlit(MODEL, 355));
    expect(rawlit(MODEL, 270)).toBe(rawlit(MODEL, 262)); // both call sites agree
    expect(rawlit(MODEL, 264)).toBe(rawlit(MODEL, 336));
  });

  it("the four section patterns equal Dart 339-342 with the label filled in", () => {
    const dartTexts = [339, 340, 341, 342].map((n) => lit(MODEL, n));
    const label = LABELS[0];
    dartTexts.forEach((t, i) => {
      expect(sectionPatternsFor(label)[i].source).toBe(interp(t, "$label", label));
    });
    expect(sectionPatternsFor(label)[0].source).toContain("(.*)");
    expect(sectionPatternsFor(label)[1].source).toContain("()");
  });

  it("matchSection reads all four label shapes (model 335-350)", () => {
    // The full-width colon is read out of the Dart character class, never typed here.
    const body = /\[(.+?)\]/.exec(lit(MODEL, 339)) ?? [];
    expect(body[1].length).toBe(2); // ASCII colon plus the full-width one
    expect(matchSection(LABELS[0] + ": value one")).toEqual([LABELS[0], "value one"]);
    expect(matchSection(LABELS[1] + body[1][1] + "value two"))
      .toEqual([LABELS[1], "value two"]);
    expect(matchSection("## " + LABELS[1])).toEqual([LABELS[1], ""]);
    expect(matchSection("**" + LABELS[2] + "** inline")).toEqual([LABELS[2], "inline"]);
    expect(matchSection(LABELS[3])).toEqual([LABELS[3], ""]);
    expect(matchSection("nothing to see")).toBeNull();
  });

  it("cutAtNextSection and cleanAction equal model 329-333 / 352-357", () => {
    // The oracle's own inline row (105) and its expectation (106) bracket the cut.
    const row = lit(ORACLE, 105); // one line with all four labels
    expect(cutAtNextSection(row)).toBe(row.slice(0, row.indexOf(LABELS[1])));
    expect(cutAtNextSection(row).endsWith(lit(ORACLE, 106))).toBe(true);
    expect(cutAtNextSection("plain text stays")).toBe("plain text stays");
    expect(cleanAction("1. numbered")).toBe("numbered");
    expect(cleanAction("2) parenthesised")).toBe("parenthesised");
    expect(cleanAction("- bulleted")).toBe("bulleted");
    expect(cleanAction("* bulleted ")).toBe("bulleted");
  });
});

// ============================================================================
// The Dart fixture of oracle 12-48, lifted field by field from the oracle lines.
function dartReport(): OperationReport {
  return {
    operationId: lit(ORACLE, 13),
    taskId: lit(ORACLE, 14),
    goal: lit(ORACLE, 15),
    hostId: lit(ORACLE, 16),
    elapsedSeconds: num(ORACLE, 17),
    stepIndex: num(ORACLE, 18),
    commandSuccessCount: num(ORACLE, 19),
    commandFailureCount: num(ORACLE, 20),
    conclusion: lit(ORACLE, 21),
    answerBody: lit(ORACLE, 22),
    details: lit(ORACLE, 23),
    stateBadges: [
      {text: lit(ORACLE, 25, 0), level: lit(ORACLE, 25, 1) as OperationBadge["level"]},
    ],
    changeRecordIds: [lit(ORACLE, 27)],
    changes: [{
      id: lit(ORACLE, 30), command: lit(ORACLE, 31), type: lit(ORACLE, 32),
      rollbackCommand: lit(ORACLE, 33), success: true,
      additions: num(ORACLE, 35), deletions: num(ORACLE, 36),
    }],
    plan: [
      {title: lit(ORACLE, 40), status: statusAt(ORACLE, 40)},
      {title: lit(ORACLE, 41), status: statusAt(ORACLE, 41)},
      {title: lit(ORACLE, 42), status: ctorStatus()},
    ],
    nextActions: [lit(ORACLE, 44)],
    verified: true,
    aiGenerated: true,
    finishState: lit(ORACLE, 47) as AgentFinishState,
  };
}

describe("OperationReport round-trip (oracle 11-93)", () => {
  const restored = reportFromJson(reportToJson(dartReport()));

  it("scalars survive the round-trip (oracle 52-62)", () => {
    expect(restored.operationId).toBe(lit(ORACLE, 52));
    expect(restored.taskId).toBe(lit(ORACLE, 53));
    expect(restored.goal).toBe(lit(ORACLE, 54));
    expect(restored.hostId).toBe(lit(ORACLE, 55));
    expect(restored.elapsedSeconds).toBe(num(ORACLE, 56));
    expect(restored.stepIndex).toBe(num(ORACLE, 57));
    expect(restored.commandSuccessCount).toBe(num(ORACLE, 58));
    expect(restored.commandFailureCount).toBe(num(ORACLE, 59));
    expect(restored.conclusion).toBe(lit(ORACLE, 60));
    expect(restored.answerBody).toBe(lit(ORACLE, 61));
    expect(restored.details ?? "").toContain(lit(ORACLE, 62));
  });

  it("badges and change records survive, derived bits included (oracle 63-73)", () => {
    expect(restored.stateBadges ?? []).toHaveLength(num(ORACLE, 63));
    expect((restored.stateBadges ?? [])[0].text).toBe(lit(ORACLE, 64));
    expect((restored.stateBadges ?? [])[0].level).toBe(lit(ORACLE, 65));
    expect(restored.changeRecordIds).toEqual([lit(ORACLE, 66)]);
    expect(restored.changes ?? []).toHaveLength(num(ORACLE, 67));
    const c = (restored.changes ?? [])[0];
    expect(c.command).toBe(lit(ORACLE, 68));
    expect(changeCanRollback(c)).toBe(true);
    expect(c.rollbackCommand).toBe(lit(ORACLE, 70));
    expect(c.additions).toBe(num(ORACLE, 71));
    expect(c.deletions).toBe(num(ORACLE, 72));
    expect(changeHasDiff(c)).toBe(true);
  });

  it("the plan keeps its three statuses and the rest of the sheet (oracle 74-83)", () => {
    expect(restored.plan ?? []).toHaveLength(num(ORACLE, 74));
    expect((restored.plan ?? [])[0].title).toBe(lit(ORACLE, 75));
    expect((restored.plan ?? [])[0].status).toBe(statusAt(ORACLE, 76));
    expect((restored.plan ?? [])[1].status).toBe(statusAt(ORACLE, 77));
    expect((restored.plan ?? [])[2].status).toBe(statusAt(ORACLE, 78));
    expect(restored.nextActions).toEqual([lit(ORACLE, 79)]);
    expect(restored.verified).toBe(true);
    expect(restored.aiGenerated).toBe(true);
    expect(restored.finishState).toBe(lit(ORACLE, 82));
    // model 146: the command count is a derived getter, never a stored field.
    expect(reportCommandCount(restored)).toBe(num(ORACLE, 83));
    expect(reportCommandCount(restored)).toBe(num(ORACLE, 58) + num(ORACLE, 59));
  });

  it("fromJson tolerates a missing or old payload (oracle 86-93)", () => {
    const empty = reportFromJson({});
    expect(empty.operationId).toBe(lit(ORACLE, 88));
    expect(empty.conclusion).toBe(lit(ORACLE, 89));
    expect(empty.elapsedSeconds).toBe(num(ORACLE, 90));
    expect(empty.finishState).toBe(lit(ORACLE, 91));
    expect(empty.changeRecordIds).toEqual([]);
    expect(empty.taskId).toBeUndefined();
    expect(empty.stateBadges).toEqual([]);
    expect(empty.plan).toEqual([]);
  });

  it("blank plan titles and non-map list entries are dropped (model 195-237)", () => {
    const out = reportFromJson({
      plan: [{title: "   "}, {title: "kept"}, "junk"],
      changes: [7, {id: "c", command: "x", type: "t"}],
      stateBadges: ["plain badge", 3, {text: "map badge", level: "warning"}],
      changeRecordIds: ["a", 4, "b"],
    });
    expect((out.plan ?? []).map((s) => s.title)).toEqual(["kept"]);
    expect((out.changes ?? []).map((c) => c.id)).toEqual(["c"]);
    expect((out.stateBadges ?? []).map((b) => b.text)).toEqual(["plain badge", "map badge"]);
    const plain = (out.stateBadges ?? [])[0];
    expect(plain.level).toBeUndefined(); // the entry was a bare String, not a map
    expect(badgeToJson(plain).level).toBe(lit(MODEL, 17, 1)); // Dart's ctor default lands here
    expect((out.stateBadges ?? [])[1].level).toBe("warning");
    expect(out.changeRecordIds).toEqual(["a", "b"]);
    expect((out.changes ?? [])[0].type).toBe("t"); // supplied, kept verbatim
    const noType = changeFromJson({id: "c2", command: "x"});
    expect(noType.type).toBe(lit(MODEL, 67, 1)); // model 67: a missing type reads as the default
  });

  it("a non-numeric diff cell reads as absent where the Dart cast would throw (71-72)", () => {
    const c = changeFromJson({id: "c", command: "x", type: "t", additions: "3", deletions: null});
    expect(c.additions).toBeUndefined();
    expect(c.deletions).toBeUndefined();
    expect(changeHasDiff(c)).toBe(false);
    const zero = changeFromJson({id: "c", command: "x", type: "t", additions: 0});
    expect(zero.additions).toBe(0);
    expect(changeHasDiff(zero)).toBe(true);
  });
});

// ============================================================================
describe("extractConclusion (model 248-273, oracle 95-157)", () => {
  it("reads the first section out of a four-section summary (oracle 95-102)", () => {
    expect(extractConclusion(tripleBlock(ORACLE, 96, 99))).toBe(lit(ORACLE, 101));
  });

  it("cuts an inline four-section row at the next label (oracle 104-107)", () => {
    expect(extractConclusion(lit(ORACLE, 105))).toBe(lit(ORACLE, 106));
  });

  it("reads a bare label line plus its following lines (oracle 109-115)", () => {
    expect(extractConclusion(tripleBlock(ORACLE, 110, 113))).toBe(lit(ORACLE, 114));
  });

  it("falls back to the first paragraph (oracle 117-122)", () => {
    expect(extractConclusion(tripleBlock(ORACLE, 118, 120))).toBe(lit(ORACLE, 121));
  });

  it("returns the fallback for null or blank input (oracle 124-127)", () => {
    expect(extractConclusion(null, {fallback: lit(ORACLE, 125, 1)})).toBe(lit(ORACLE, 125, 1));
    expect(extractConclusion(lit(ORACLE, 126, 0), {fallback: lit(ORACLE, 126, 1)}))
      .toBe(lit(ORACLE, 126, 1));
    expect(CONCLUSION_FALLBACK).toBe(lit(MODEL, 250));
  });

  it("prefers the written conclusion over the answer body (oracle 129-139)", () => {
    expect(extractConclusion(lit(ORACLE, 130), {answerBody: lit(ORACLE, 134)}))
      .toBe(lit(ORACLE, 136));
  });

  it("uses the answer first paragraph when the section is missing (oracle 141-150)", () => {
    expect(extractConclusion(lit(ORACLE, 143), {answerBody: lit(ORACLE, 144)}))
      .toBe(lit(ORACLE, 147));
  });

  it("keeps the thought text when the answer is empty (oracle 152-157)", () => {
    expect(extractConclusion(lit(ORACLE, 154))).toBe(lit(ORACLE, 155));
  });

  it("strips a markdown heading from the answer paragraph (model 262-265)", () => {
    const answer = "## Heading line" + NL + NL + "body text";
    expect(extractConclusion("no section here", {answerBody: answer})).toBe("Heading line");
  });

  it("extractSection is undefined for an empty or absent section (model 276-291)", () => {
    const block = tripleBlock(ORACLE, 96, 99);
    const second = block.split(NL)[1];
    expect(extractSection(block, LABELS[1])).toBe(second.slice(second.indexOf(":") + 1).trim());
    expect(extractSection(block, "not a label")).toBeUndefined();
    expect(extractSection(LABELS[1] + ":", LABELS[1])).toBeUndefined();
  });
});

// ============================================================================
describe("extractNextActions and extractDetails (model 293-325, oracle 159-172)", () => {
  it("reads the last section and filters the placeholders (oracle 159-166)", () => {
    expect(extractNextActions(tripleBlock(ORACLE, 160, 164)))
      .toEqual([lit(ORACLE, 165, 0), lit(ORACLE, 165, 1)]);
  });

  it("caps the list at the Dart default max (model 301 / 319 / 323)", () => {
    const max = num(MODEL, 301);
    const raw = LABELS[3] + ":" + [1, 2, 3, 4, 5, 6].map((i) => NL + "- action " + i).join("");
    expect(extractNextActions(raw)).toHaveLength(max);
    expect(extractNextActions(raw, 2)).toEqual(["action 1", "action 2"]);
    expect(extractNextActions("")).toEqual([]);
    expect(extractNextActions("   ")).toEqual([]);
    expect(extractNextActions(null)).toEqual([]);
  });

  it("details equal to the conclusion are dropped (oracle 168-172)", () => {
    expect(extractDetails(lit(ORACLE, 169, 0), {conclusion: lit(ORACLE, 169, 1)})).toBeUndefined();
    expect(extractDetails(lit(ORACLE, 171, 0)) ?? "").toContain(lit(ORACLE, 171, 1));
    expect(extractDetails("")).toBeUndefined();
    expect(extractDetails(null)).toBeUndefined();
  });

  it("details clip at the Dart budget with the Dart ellipsis (model 293-299)", () => {
    const ellipsis = lit(MODEL, 362);
    const mark = ellipsis.slice(ellipsis.lastIndexOf("}") + 1);
    const long = extractDetails("y".repeat(MAX_DETAILS_CHARS + 40)) ?? "";
    expect(long).toBe("y".repeat(MAX_DETAILS_CHARS) + mark);
  });
});

// ============================================================================
describe("defaultConclusion templates (agent_engine.dart 3709-3723)", () => {
  it("the Dart switch covers exactly the four Node finish states", () => {
    const body = ENGINE.slice(3708, 3723).join(NL);
    const arms = body.match(/case AgentFinishState\.(\w+)/g) ?? [];
    expect(arms.length).toBe(4);
    const union = /export type AgentFinishState = ([^;]+);/.exec(SCHEMA_TS.join(NL));
    if (union === null) throw new Error("AgentFinishState union not found in rpc/schema.ts");
    const states = union[1].split("|").map((s) => s.trim().replace(/"/g, ""));
    expect(states.length).toBe(4);
    for (const arm of arms) {
      expect(states).toContain(arm.replace("case AgentFinishState.", ""));
    }
  });

  it("each template equals the Dart string with its interpolation filled in", () => {
    const stepHi = interp(lit(ENGINE, 3710, 0), "$_currentStepCount", "4");
    const stepLo = lit(ENGINE, 3710, 1);
    const zero = num(ENGINE, 3713, 0); // the "?? 0" fallback of the Dart counter
    const ran = zero + 7;
    expect(defaultConclusion("success", {successCount: ran}))
      .toBe(interp(lit(ENGINE, 3714, 0), "$count", String(ran)));
    expect(defaultConclusion("success", {successCount: zero})).toBe(lit(ENGINE, 3714, 1));
    expect(defaultConclusion("success")).toBe(lit(ENGINE, 3714, 1));
    expect(defaultConclusion("cancelled", {stepCount: 4}))
      .toBe(interp(lit(ENGINE, 3716, 0), "$step", stepHi));
    expect(defaultConclusion("cancelled")).toBe(interp(lit(ENGINE, 3716, 0), "$step", stepLo));
    expect(defaultConclusion("failed", {reason: lit(ENGINE, 3718, 0)}))
      .toBe(lit(ENGINE, 3719, 0));
    expect(defaultConclusion("failed", {reason: "boom"}))
      .toBe(interp(lit(ENGINE, 3719, 1), "$r", "boom"));
    expect(defaultConclusion("interrupted", {stepCount: 4}))
      .toBe(interp(lit(ENGINE, 3721, 0), "$step", stepHi));
    expect(defaultConclusion("interrupted"))
      .toBe(interp(lit(ENGINE, 3721, 0), "$step", stepLo));
  });

  it("no arm returns the accumulated ReAct text (engine 3647-3648 discipline)", () => {
    const thought = tripleBlock(ORACLE, 96, 99);
    const states: AgentFinishState[] = ["success", "cancelled", "failed", "interrupted"];
    for (const state of states) {
      const out = defaultConclusion(state, {stepCount: 3, successCount: 3});
      expect(out.length).toBeGreaterThan(0);
      expect(out).not.toBe(thought);
      expect(out).not.toContain(lit(ORACLE, 101)); // the model's own conclusion text
    }
  });
});

// ============================================================================
// The localRestore fixture of oracle 240-251: a local file change has no shell
// rollback command, so the restore affordance rides entirely on this one bit.
function dartChange(rollbackCommand?: string, localRestore?: boolean): OperationChange {
  const c: OperationChange = {
    id: lit(ORACLE, 245), command: lit(ORACLE, 246), type: lit(ORACLE, 247), success: true,
  };
  if (rollbackCommand !== undefined) c.rollbackCommand = rollbackCommand;
  if (localRestore !== undefined) c.localRestore = localRestore;
  return c;
}

describe("OperationChange.localRestore (oracle 236-282)", () => {
  it("localRestore alone is restorable, with no rollback command (oracle 253-257)", () => {
    const c = dartChange(undefined, true);
    expect(c.rollbackCommand).toBeUndefined();
    expect(changeCanRollback(c)).toBe(true);
  });

  it("toJson/fromJson keeps localRestore (oracle 259-264)", () => {
    const back = changeFromJson(changeToJson(dartChange(undefined, true)));
    expect(back.localRestore).toBe(true);
    expect(changeCanRollback(back)).toBe(true);
  });

  it("legacy data without the key is not restorable, no claim (oracle 266-276)", () => {
    const legacy = {
      id: lit(ORACLE, 268, 1), command: lit(ORACLE, 269, 1), type: lit(ORACLE, 270, 1),
      success: true,
    };
    const back = changeFromJson(legacy);
    expect(back.localRestore).toBe(false);
    expect(changeCanRollback(back)).toBe(false);
  });

  it("a blank rollback command does not count (oracle 278-281)", () => {
    expect(changeCanRollback(dartChange(lit(ORACLE, 279)))).toBe(false);
    expect(changeCanRollback(dartChange(lit(ORACLE, 279), false))).toBe(false);
    expect(changeCanRollback(dartChange(lit(ORACLE, 280)))).toBe(true);
  });
});

// ============================================================================
describe("ReAct finish-summary pipeline (oracle 198-215)", () => {
  it("a four-section finish thought survives parsing and becomes the conclusion", () => {
    const response = tripleBlock(ORACLE, 201, 205);
    const events = parseStream(response);
    const thoughts = events.filter((e) => e.type === "thought").map((e) => e.text ?? "");
    expect(thoughts.length).toBeGreaterThan(0);
    const thought = thoughts[thoughts.length - 1];
    expect(thought).toContain(lit(ORACLE, 212));
    expect(extractConclusion(thought)).toBe(lit(ORACLE, 213));
    expect(events.some((e) => e.type === "finish")).toBe(true);
  });
});

// ============================================================================
describe("report event slot (rpc/schema.ts 7-9 and 108) - partial by design", () => {
  it("the Node event type admits report and carries the payload object", () => {
    const report: OperationReport = {
      operationId: lit(ORACLE, 220),
      goal: lit(ORACLE, 221),
      elapsedSeconds: num(ORACLE, 222),
      stepIndex: num(ORACLE, 223),
      commandSuccessCount: num(ORACLE, 224),
      commandFailureCount: num(ORACLE, 225),
      conclusion: lit(ORACLE, 226),
      finishState: lit(ORACLE, 227) as AgentFinishState,
    };
    const event: AgentEvent = {
      type: "report", id: "e1", operationReport: report, hostId: lit(ORACLE, 232),
    };
    expect(event.type).toBe("report");
    expect(event.operationReport?.operationId).toBe(lit(ORACLE, 231));
    expect(event.hostId).toBe(lit(ORACLE, 232));
    expect(reportCommandCount(event.operationReport ?? report))
      .toBe(num(ORACLE, 224) + num(ORACLE, 225));
    expect(reportFromJson(reportToJson(report)).finishState).toBe(lit(ORACLE, 227));
  });

  it("the declared-but-unshipped state is pinned (sanctioned skip)", () => {
    // rpc/schema.ts has the payload field; event.schema.json does not, because the emit
    // path (VerificationDetector / ChangeRecordService) does not exist yet. Flip this
    // assertion the day the emit lands, together with the schema and the D3 record.
    expect(SCHEMA_TS.some((l) => l.includes("operationReport?"))).toBe(true);
    expect(EVENT_SCHEMA.includes("operationReport")).toBe(false);
    expect(EVENT_SCHEMA.includes("\"report\"")).toBe(true);
    expect(MINE.some((l) => l.includes("_emitOperationReport"))).toBe(true); // header note
  });
});

// ============================================================================
describe("Agent model metadata (oracle 175-196) - failureKind half only", () => {
  it("the Node failure-kind domain admits the Dart value (oracle 184-195)", () => {
    expect(CommandFailureKind.permissionDenied).toBe(lit(ORACLE, 191));
    expect(CommandFailureKind.none).toBe("none");
    expect(CommandFailureKind.cancelled).toBe("cancelled");
  });

  it("stepIndex / elapsedSeconds have no Node counterpart yet (sanctioned skip)", () => {
    // oracle 176-182 exercises AgentTask.copyWith(stepIndex, elapsedSeconds); the Node
    // engine tracks the operation id but no per-task step or clock counter, which is
    // exactly why the report emit is still open. Pin the Dart side so the day the
    // engine grows these fields this test goes red and the replay gets completed.
    const taskGroup = ORACLE.slice(175, 182).join(NL);
    expect(taskGroup).toContain("copyWith");
    expect(taskGroup).toContain("stepIndex");
    expect(taskGroup).toContain("elapsedSeconds");
    expect(ENGINE_TS.some((l) => l.includes("operationId"))).toBe(true);
    expect(ENGINE_TS.some((l) => l.includes("stepIndex"))).toBe(false);
    expect(ENGINE_TS.some((l) => l.includes("elapsedSeconds"))).toBe(false);
  });
});

