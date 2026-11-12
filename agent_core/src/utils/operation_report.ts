// utils/operation_report.ts - 1:1 port of ai_terminal/lib/models/operation_report.dart
// (the behaviour Dart carries in that file: OperationBadge 10-19, OperationChange
// 35-74, OperationReport 119-146 / toJson 148-169 / fromJson 171-193 / the tolerance
// helpers 195-237, and the four-section summary extractors 239-363) plus the
// deterministic non-success conclusion templates from agent_engine.dart 3709-3723.
// The plan-step wire aliases are plan_step.dart 25-26 / 28-33 / 35-46 / 48-74.
//
// Dart keeps the model behaviour next to the wire types; on the Node side the TYPES
// were already declared in rpc/schema.ts (OperationBadge 32-35, OperationChange 37-46,
// OperationReport 48-68, AgentEvent.operationReport 108) with none of the behaviour.
// This file supplies what was missing: the JSON tolerance rules (_str/_int/_strList/
// _badges/_plan/_changes), the derived canRollback/hasDiff bits, and the section
// extraction that a finish summary is turned into an operation sheet with.
//
// Deliberately NOT ported here: agent_engine.dart 3649-3707 _emitOperationReport.
// It fills stateBadges from VerificationDetector (2879-2890) and changeRecordIds/
// changes from ChangeRecordService (2894-2912, 3154-3172) - a deterministic output
// checker and a Hive-backed change ledger, neither of which exists on the Node side
// yet. Emitting the event before they exist would advertise a sheet with an empty
// evidence section, and event.schema.json's payload would be invented on this side.
// Until then no report event is emitted and no report payload field is declared.
//
// Deviations from Dart, all disclosed:
//  1. 141-144 (isSuccess/isFailed/isCancelled/isInterrupted) are not ported: Node's
//     finishState is a typed union (rpc/schema.ts:11), Dart's is a raw String, so the
//     getters would only restate the comparison.
//  2. Dart's OperationBadge.level is a free String; rpc/schema.ts:34 narrows it to
//     success|info|warning, so badgeFromJson casts the value it read.
//     A bare-String list entry (209-237) gets no level in memory; the default is
//     materialized by badgeToJson, so the serialized bytes match Dart's ctor default.
//  3. finishState is passed through unchecked, exactly like Dart's
//     _str(json['finishState']) ?? 'success': a legacy or foreign value keeps its text.
//     event.schema.json enumerates the four states; that enum is the contract.
//  4. defaultConclusion takes stepCount/successCount/reason as arguments - Dart reads
//     _currentStepCount / _currentTask.successCount / the caller's reason line, and the
//     Node engine has no such fields until the report emit is wired.
//  5. extractSection/matchSection/cutAtNextSection/cleanAction are exported where Dart
//     keeps them private, so the oracle replay can pin them against the Dart source.
//  6. Dart builds the section body with StringBuffer.writeln (element + newline); here
//     the elements are joined with the same newline and clipReportText trims - same bytes.
//
// Every CJK literal and regex below is compared with the Dart source at run time by
// test/operation_report_oracle.test.ts, so a Dart-side rename turns that test red.

import type {
  AgentFinishState, OperationBadge, OperationChange, OperationReport, PlanStep, PlanStepStatus,
} from "../rpc/schema.js";

// Dart 244-246: the four section labels, in the order the prompt asks the model for
// them, plus the two clipping budgets.
export const SECTION_LABELS = ["结论", "现状", "变更", "建议"] as const;
export const MAX_CONCLUSION_CHARS = 600;
export const MAX_DETAILS_CHARS = 8000;
// Dart 250: the conclusion fallback the caller gets when there is nothing to say.
export const CONCLUSION_FALLBACK = "任务已结束，详见执行记录";
// Dart 322: the two placeholder answers that are not actually a next action.
const ACTION_PLACEHOLDERS = ["无", "暂无"];
// Dart 362: the ellipsis that marks a clipped value.
const ELLIPSIS = "…";

// Regex bodies, transcribed from the Dart literals (raw strings keep their
// backslashes, so the TS literals below double them for the same pattern text).
const PARAGRAPH_BREAK = "\\n\\s*\\n";   // Dart 262 / 270: the paragraph break
const HEADING_PREFIX = "^#{1,6}\\s*";   // Dart 264 / 336: an ATX heading prefix
const NEXT_SECTION_MARK = "\\s*(?:现状|变更|建议)\\s*[:：]";   // Dart 330: inline four-section rows
const BULLET_PREFIX = "^[-*•]\\s*";   // Dart 354
const NUMBERED_PREFIX = "^\\d+[.)、]\\s*";   // Dart 355

const NL = "\n";

// Dart 253 / 260 / 294 / 302: the incoming text may carry CR - normalise it first.
function toLf(s: string): string {
  return s.replace(/\r\n/g, NL);
}

// ─── Dart 195-237: JSON tolerance helpers ──────────────────────────────────────
// Dart _str 195-196: a blank/whitespace-only string counts as absent, never as "".
function strVal(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() !== "" ? v : undefined;
}

// Dart _int 198-202: int / num -> int, anything else 0.
function intVal(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : 0;
}

// Dart _strList 204-207: non-list -> empty; non-strings are dropped, not stringified.
function strList(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v.filter((e): e is string => typeof e === "string");
}

function isMap(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// ─── OperationBadge (Dart 10-19) ───────────────────────────────────────────────
export function badgeFromJson(json: Record<string, unknown>): OperationBadge {
  // Dart 16-17: both values go through _str, so a blank level falls back to info.
  // The cast is deviation 2 above: rpc/schema.ts:34 narrows the level domain.
  return {
    text: strVal(json["text"]) ?? "",
    level: (strVal(json["level"]) ?? "info") as OperationBadge["level"],
  };
}

export function badgeToJson(b: OperationBadge): Record<string, unknown> {
  return {text: b.text, level: b.level ?? "info"}; // Dart 12 always writes the level
}

// ─── OperationChange (Dart 35-74) ──────────────────────────────────────────────
export function changeFromJson(json: Record<string, unknown>): OperationChange {
  const change: OperationChange = {
    id: strVal(json["id"]) ?? "",
    command: strVal(json["command"]) ?? "",
    // Dart 67: an unlabelled change is "other", never an empty type.
    type: strVal(json["type"]) ?? "other",
    localRestore: json["localRestore"] === true,
    // Dart 70: only an explicit false means failure - a record written before the
    // field existed stays a success record instead of turning into an unknown one.
    success: json["success"] !== false,
  };
  const rollbackCommand = strVal(json["rollbackCommand"]);
  if (rollbackCommand !== undefined) change.rollbackCommand = rollbackCommand;
  // Dart 71-72: num -> int. A non-numeric cell reads as absent here, where Dart's
  // "as num?" cast would have thrown and taken the whole event down with it.
  const additions = json["additions"];
  if (typeof additions === "number") change.additions = intVal(additions);
  const deletions = json["deletions"];
  if (typeof deletions === "number") change.deletions = intVal(deletions);
  return change;
}

export function changeToJson(c: OperationChange): Record<string, unknown> {
  // Dart 52-61: every key is written, absent ones as null, so a reader sees the same
  // shape it always saw (same rule as reportToJson).
  return {
    id: c.id,
    command: c.command,
    type: c.type,
    rollbackCommand: c.rollbackCommand ?? null,
    localRestore: c.localRestore === true,
    success: c.success !== false,
    additions: c.additions ?? null,
    deletions: c.deletions ?? null,
  };
}

// Dart 46: derived from the diff counters, never stored.
export function changeHasDiff(c: OperationChange): boolean {
  return c.additions !== undefined || c.deletions !== undefined;
}

// Dart 48-50: a blank rollback command does not count as rollback capability. The
// localRestore flag is what keeps a local file operation restorable when there is no
// shell command that undoes it (a copy-back), which is why it is its own field.
export function changeCanRollback(c: OperationChange): boolean {
  return (c.rollbackCommand !== undefined && c.rollbackCommand.trim() !== "")
    || c.localRestore === true;
}

// ─── PlanStep (plan_step.dart 25-74) ───────────────────────────────────────────
// plan_step.dart 25-26: a step counts as settled when it is done OR deliberately
// skipped - the sheet's progress line counts it that way, not "completed" alone.
export function planStepIsDone(s: PlanStep): boolean {
  const status = s.status ?? "pending";
  return status === "completed" || status === "skipped";
}

// plan_step.dart 28-33: title/status/hostIds always, note only when present.
export function planStepToJson(s: PlanStep): Record<string, unknown> {
  const out: Record<string, unknown> = {
    title: s.title,
    status: s.status ?? "pending",
    hostIds: s.hostIds ?? [],
  };
  if (s.note !== undefined) out["note"] = s.note;
  return out;
}

// plan_step.dart 35-46: a non-String title becomes empty, hostIds keeps only strings,
// and an empty-string note is kept (no _str tolerance on that one).
export function planStepFromJson(json: Record<string, unknown>): PlanStep {
  const step: PlanStep = {
    title: typeof json["title"] === "string" ? (json["title"] as string) : "",
    status: planStepParseStatus(
      typeof json["status"] === "string" ? (json["status"] as string) : null,
    ),
    hostIds: Array.isArray(json["hostIds"])
      ? (json["hostIds"] as unknown[]).filter((e): e is string => typeof e === "string")
      : [],
  };
  if (typeof json["note"] === "string") step.note = json["note"] as string;
  return step;
}

// plan_step.dart 48-74: the aliases a persisted or wire status may carry. This is a
// different table from react/parser.ts parsePlanMarker (47-64), which mirrors Dart's
// _parsePlanSteps checkbox markers; this one decodes the stored/on-the-wire value.
export function planStepParseStatus(raw: string | null): PlanStepStatus {
  const v = (raw ?? "").trim().toLowerCase();
  switch (v) {
    case "inprogress":
    case "in_progress":
    case "in-progress":
    case "current":
    case "doing":
    case "进行中":
      return "inProgress";
    case "completed":
    case "complete":
    case "done":
    case "完成":
    case "已完成":
      return "completed";
    case "failed":
    case "fail":
    case "失败":
      return "failed";
    case "skipped":
    case "skip":
    case "跳过":
      return "skipped";
    default:
      return "pending";
  }
}

// ─── OperationReport (Dart 119-237) ────────────────────────────────────────────
// Dart 146: the count is a getter, not a stored field.
export function reportCommandCount(r: OperationReport): number {
  return r.commandSuccessCount + r.commandFailureCount;
}

export function reportFromJson(json: Record<string, unknown>): OperationReport {
  // Dart 171-193, in the Dart field order; the required fields fall back to empty
  // values rather than failing, so a legacy row still renders a sheet.
  const report: OperationReport = {
    operationId: strVal(json["operationId"]) ?? "",
    goal: strVal(json["goal"]) ?? "",
    elapsedSeconds: intVal(json["elapsedSeconds"]),
    stepIndex: intVal(json["stepIndex"]),
    commandSuccessCount: intVal(json["commandSuccessCount"]),
    commandFailureCount: intVal(json["commandFailureCount"]),
    conclusion: strVal(json["conclusion"]) ?? "",
    stateBadges: badgesFromJson(json["stateBadges"]),
    changeRecordIds: strList(json["changeRecordIds"]),
    changes: changesFromJson(json["changes"]),
    plan: planStepsFromJson(json["plan"]),
    nextActions: strList(json["nextActions"]),
    verified: json["verified"] === true,
    aiGenerated: json["aiGenerated"] === true,
    // Deviation 3: passed through unchecked exactly like Dart's
    // _str(...) ?? 'success' - event.schema.json's finishState enum is the contract.
    finishState: (strVal(json["finishState"]) ?? "success") as AgentFinishState,
  };
  const taskId = strVal(json["taskId"]);
  if (taskId !== undefined) report.taskId = taskId;
  const hostId = strVal(json["hostId"]);
  if (hostId !== undefined) report.hostId = hostId;
  const answerBody = strVal(json["answerBody"]);
  if (answerBody !== undefined) report.answerBody = answerBody;
  const details = strVal(json["details"]);
  if (details !== undefined) report.details = details;
  return report;
}

export function reportToJson(r: OperationReport): Record<string, unknown> {
  // Dart 148-169: all 19 keys, absent ones as null. Dart writes the same keys an
  // older build reads, which is what lets a history row from before the event exist.
  return {
    operationId: r.operationId,
    taskId: r.taskId ?? null,
    goal: r.goal,
    hostId: r.hostId ?? null,
    elapsedSeconds: r.elapsedSeconds,
    stepIndex: r.stepIndex,
    commandSuccessCount: r.commandSuccessCount,
    commandFailureCount: r.commandFailureCount,
    conclusion: r.conclusion,
    answerBody: r.answerBody ?? null,
    details: r.details ?? null,
    stateBadges: (r.stateBadges ?? []).map(badgeToJson),
    changeRecordIds: r.changeRecordIds ?? [],
    changes: (r.changes ?? []).map(changeToJson),
    plan: (r.plan ?? []).map(planStepToJson),
    nextActions: r.nextActions ?? [],
    verified: r.verified === true,
    aiGenerated: r.aiGenerated === true,
    finishState: r.finishState,
  };
}

// Dart 209-220 _badges: a bare non-blank string in the list still becomes a badge
// (level defaults to info); anything else in the list is dropped.
function badgesFromJson(v: unknown): OperationBadge[] {
  if (!Array.isArray(v)) return [];
  const out: OperationBadge[] = [];
  for (const item of v) {
    if (isMap(item)) out.push(badgeFromJson(item));
    else if (typeof item === "string" && item.trim() !== "") out.push({text: item.trim()});
  }
  return out;
}

// Dart 231-237 _changes: non-map entries dropped, no title filter.
function changesFromJson(v: unknown): OperationChange[] {
  if (!Array.isArray(v)) return [];
  return v.filter(isMap).map(changeFromJson);
}

// Dart 222-229 _plan: PlanStep.fromJson first, then drop the blank titles.
function planStepsFromJson(v: unknown): PlanStep[] {
  if (!Array.isArray(v)) return [];
  return v.filter(isMap).map(planStepFromJson).filter((s) => s.title.trim() !== "");
}

// ─── summary-text extractors (Dart 239-363) ────────────────────────────────────
// The model is asked to finish with the four-section form; when it does, the
// conclusion is that section and the details are the whole text. When it does not,
// the conclusion degrades to the first paragraph - never to the whole ReAct dump.

// Dart 335-350 _matchSection: (label, value) for one line, or null. Four shapes per
// label, in order: label + colon, label alone on a line (empty capture), bold label
// with an optional colon, and the bracketed form.
export function sectionPatternsFor(label: string): RegExp[] {
  return [
    new RegExp("^" + label + "\\s*[:：]\\s*(.*)$"),
    new RegExp("^" + label + "\\s*()$"),
    new RegExp("^\\*\\*" + label + "\\*\\*\\s*[:：]?\\s*(.*)$"),
    new RegExp("^【" + label + "】\\s*(.*)$"),
  ];
}

export type SectionMatch = readonly [label: string, value: string];

export function matchSection(line: string): SectionMatch | null {
  const trimmed = line.trim().replace(new RegExp(HEADING_PREFIX), "");
  for (const label of SECTION_LABELS) {
    for (const p of sectionPatternsFor(label)) {
      const m = p.exec(trimmed);
      if (m !== null) return [label, (m[1] ?? "").trim()];
    }
  }
  return null;
}

// Dart 327-333: the model sometimes puts the four sections on one line - cut the
// value off before the next label.
export function cutAtNextSection(text: string): string {
  const m = new RegExp(NEXT_SECTION_MARK).exec(text);
  if (m === null) return text;
  return text.substring(0, m.index).replace(/\s+$/, "");
}

// Dart 352-357: strip a bullet or an enumeration prefix from a suggested action.
export function cleanAction(s: string): string {
  return s.replace(new RegExp(BULLET_PREFIX), "").replace(new RegExp(NUMBERED_PREFIX), "").trim();
}

// Dart 359-363: trim, then clip to max chars with the ellipsis.
export function clipReportText(s: string, max: number): string {
  const value = s.trim();
  if (value.length <= max) return value;
  return value.substring(0, max) + ELLIPSIS;
}

// Dart 276-291: the value of one section - the label's own text plus every following
// line up to the next section label.
export function extractSection(text: string, label: string): string | undefined {
  const lines = text.split(NL);
  for (let i = 0; i < lines.length; i++) {
    const m = matchSection(lines[i]);
    if (m === null || m[0] !== label) continue;
    const buf: string[] = [];
    if (m[1] !== "") buf.push(cutAtNextSection(m[1]));
    for (let j = i + 1; j < lines.length; j++) {
      if (matchSection(lines[j]) !== null) break;
      buf.push(cutAtNextSection(lines[j]));
    }
    const value = clipReportText(buf.join(NL), MAX_CONCLUSION_CHARS);
    return value === "" ? undefined : value;
  }
  return undefined;
}

// Dart 248-273 extractConclusion.
export function extractConclusion(
  raw: string | null | undefined,
  opts: {fallback?: string; answerBody?: string | null} = {},
): string {
  const fallback = opts.fallback ?? CONCLUSION_FALLBACK;
  const text = toLf(raw ?? "").trim();
  const sectionValue = extractSection(text, SECTION_LABELS[0]);
  if (sectionValue !== undefined) return sectionValue;
  // Dart 258-259: with no four-section form, the first paragraph of the answer is a
  // better conclusion than the finish thought - the thought is the reasoning the model
  // wrote for itself, the answer is the sentence written for the user.
  const answer = toLf(opts.answerBody ?? "").trim();
  if (answer !== "") {
    const firstParagraph = answer.split(new RegExp(PARAGRAPH_BREAK))[0].trim();
    const cleaned = firstParagraph.replace(new RegExp(HEADING_PREFIX), "").trim();
    if (cleaned !== "") return clipReportText(cleaned, MAX_CONCLUSION_CHARS);
  }
  if (text === "") return fallback;
  // Dart 269: no four-section form - first paragraph, then fall back to the first line.
  const firstParagraph = text.split(new RegExp(PARAGRAPH_BREAK))[0].trim();
  const value = clipReportText(firstParagraph, MAX_CONCLUSION_CHARS);
  return value === "" ? fallback : value;
}

// Dart 293-299 extractDetails: the evidence layer, null when the clipped text would
// only repeat the conclusion the sheet already shows.
export function extractDetails(
  raw: string | null | undefined,
  opts: {conclusion?: string} = {},
): string | undefined {
  const text = toLf(raw ?? "").trim();
  if (text === "") return undefined;
  const clipped = clipReportText(text, MAX_DETAILS_CHARS);
  if (opts.conclusion !== undefined && clipped === opts.conclusion.trim()) return undefined;
  return clipped;
}

// Dart 301-325 extractNextActions: up to max follow-ups from the last section.
export function extractNextActions(raw: string | null | undefined, max = 4): string[] {
  const text = toLf(raw ?? "");
  if (text.trim() === "") return [];
  const lines = text.split(NL);
  const actions: string[] = [];
  let inSection = false;
  for (const line of lines) {
    const m = matchSection(line);
    if (m !== null) {
      inSection = m[0] === SECTION_LABELS[3];
      if (inSection && m[1] !== "") actions.push(cleanAction(m[1]));
      continue;
    }
    if (!inSection) continue;
    const trimmed = line.trim();
    if (trimmed === "") continue;
    const cleaned = cleanAction(trimmed);
    if (cleaned !== "") actions.push(cleaned);
    if (actions.length >= max) break;
  }
  return actions
    .filter((a) => a !== "" && a !== ACTION_PLACEHOLDERS[0] && a !== ACTION_PLACEHOLDERS[1])
    .slice(0, max);
}

// Dart 3709-3723 defaultConclusion. The cancel/limit templates name the step the task
// stopped at, the failure template carries the reason line. Never fall back to the
// accumulated ReAct text on these paths (agent_engine.dart 3647-3648).
export function defaultConclusion(
  state: AgentFinishState,
  opts: {reason?: string | null; stepCount?: number; successCount?: number} = {},
): string {
  const stepCount = opts.stepCount ?? 0;
  const step = stepCount > 0 ? "第 " + stepCount + " 步" : "当前步骤";
  if (state === "success") {
    const count = opts.successCount ?? 0;
    return count > 0 ? "任务已完成，共执行 " + count + " 条命令。" : "任务已完成。";
  }
  if (state === "cancelled") return "任务已取消于" + step + "。";
  if (state === "failed") {
    const r = (opts.reason ?? "").trim();
    return r === "" ? "任务执行失败。" : "任务执行失败：" + r;
  }
  // Dart 3720-3721: the remaining arm of Dart's exhaustive enum switch.
  return "任务在" + step + "达到步数上限后中断。";
}
