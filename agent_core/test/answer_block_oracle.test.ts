// Round 130: oracle replay of src/utils/answer_block.ts - the 1:1 port of the two
// extractor helpers of ai_terminal/lib/services/agent_engine.dart - 2103-2124 (the
// two RegExp constants, the clip helper and _firstColonIndex), 2126-2153
// parseAnswerBlock and 2159-2198 parseReportSections - replayed against the six
// E2E cases of ai_terminal/test/react_parse_e2e_test.dart (group 302-418).
//
// No Dart SDK runs here: every INPUT and every EXPECTATION below is lifted out of
// the Dart sources at run time, so a Dart-side edit surfaces as a changed needle or
// a hard parse error instead of a stale hand-copied literal. The file is ASCII-pure
// for the same reason - the CJK stays in the oracle.
//
// One sanctioned skip: the OperationReport.extractConclusion expectation of E2E-15
// (oracle 403-406). OperationReport is the D3 subsystem of
// docs/agent-core-migration-design.md and is not ported yet; the skip is pinned by
// count so a Dart-side new assertion can never slip through un-checked.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {
  ANSWER_STOP_LINE,
  SECTION_START_LINE,
  MAX_ANSWER_CHARS,
  clipAnswerText,
  firstColonIndex,
  parseAnswerBlock,
  parseReportSections,
} from "../src/utils/answer_block.js";
import {parse as parseStream} from "../src/react/parser.js";

const NL = String.fromCharCode(10);
const BSN = String.fromCharCode(92) + "n";
const HERE = fileURLToPath(new URL(".", import.meta.url));
const dartLines = (rel: string): string[] =>
  readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL).split(NL);

const ORACLE = dartLines("../../ai_terminal/test/react_parse_e2e_test.dart");
const ENGINE_DART = dartLines("../../ai_terminal/lib/services/agent_engine.dart");

// ---- the oracle group (react_parse_e2e_test.dart 302-418) -------------------
function groupRange(): {from: number; to: number} {
  const from = ORACLE.findIndex((l) => l.indexOf("test('E2E-8") >= 0) - 1;
  if (from < 1 || ORACLE[from].indexOf("group(") < 0) throw new Error("oracle group anchor missing");
  let depth = 0;
  for (let i = from; i < ORACLE.length; i++) {
    for (const c of ORACLE[i]) {
      if (c === "{") depth++;
      else if (c === "}") depth--;
    }
    if (depth === 0 && i > from) return {from, to: i};
  }
  throw new Error("oracle group never closes");
}
const GROUP = groupRange();
const GROUP_TEXT = ORACLE.slice(GROUP.from, GROUP.to + 1).join(NL);

function caseLines(tag: string): string[] {
  const head = "test('E2E-" + tag + ":";
  const start = ORACLE.findIndex((l, i) => i >= GROUP.from && i <= GROUP.to && l.indexOf(head) >= 0);
  if (start < 0) throw new Error("oracle case E2E-" + tag + " missing");
  let depth = 0;
  for (let i = start; i <= GROUP.to; i++) {
    for (const c of ORACLE[i]) {
      if (c === "{") depth++;
      else if (c === "}") depth--;
    }
    if (depth === 0 && i > start) return ORACLE.slice(start, i + 1);
  }
  throw new Error("oracle case E2E-" + tag + " never closes");
}

// Triple-quoted Dart string. Either delimiter can carry content: E2E-9/E2E-10 open
// inline, and E2E-8/E2E-11/E2E-15 CLOSE AT THE END of the last content line, where
// the action line lives. Dropping that foot silently loses the finish line, so both
// ends are kept.
function tripleText(lines: string[]): string {
  const open = lines.findIndex((l) => l.indexOf("= '''") >= 0);
  if (open < 0) throw new Error("no triple-quoted response in the oracle case");
  const head = lines[open].split("'''")[1];
  let close = open + 1;
  while (close < lines.length && lines[close].indexOf("'''") < 0) close++;
  if (close >= lines.length) throw new Error("unterminated triple-quoted response");
  const foot = lines[close].split("'''")[0];
  const parts = head === "" ? lines.slice(open + 1, close) : [head].concat(lines.slice(open + 1, close));
  if (foot !== "") parts.push(foot);
  return parts.join(NL);
}

// E2E-11 builds its input by chunk concatenation - the R9 historical bug shape.
function joinedChunks(lines: string[]): string {
  const open = lines.findIndex((l) => l.indexOf("chunks = [") >= 0);
  if (open < 0) throw new Error("no chunk list in the oracle case");
  let close = open;
  while (close < lines.length && lines[close].indexOf("]") < 0) close++;
  const body = lines.slice(open, close + 1).join(NL);
  const re = /'((?:[^'\\]|\\.)*)'/g;
  let out = "";
  let m: RegExpExecArray | null;
  while ((m = re.exec(body)) !== null) out += m[1].split(BSN).join(NL);
  return out;
}

function caseText(tag: string): string {
  const lines = caseLines(tag);
  return lines.some((l) => l.indexOf("chunks = [") >= 0) ? joinedChunks(lines) : tripleText(lines);
}

// ---- Dart-side constants, read from the oracle rather than re-pinned ---------
function dartRegExpBody(decl: string): string {
  const i = ENGINE_DART.findIndex((l) => l.indexOf("RegExp " + decl) >= 0 || l.indexOf(decl + " = RegExp(") >= 0);
  if (i < 0) throw new Error("Dart regex decl not found: " + decl);
  const flat = ENGINE_DART.slice(i, i + 4).join(" ");
  const m = /RegExp\(\s*r'([^']*)'/.exec(flat);
  if (!m) throw new Error("Dart RegExp literal not found for " + decl);
  return m[1];
}

function dartMaxAnswerChars(): number {
  const m = /static const _maxAnswerChars = (\d+);/.exec(ENGINE_DART.join(NL));
  if (!m) throw new Error("Dart _maxAnswerChars not found");
  return Number(m[1]);
}

// Dart 2112-2115: the clip keeps the HEAD and appends one marker literal.
function dartClipMarker(): string {
  const i = ENGINE_DART.findIndex((l) => l.indexOf("String _clipAnswerText(") >= 0);
  if (i < 0) throw new Error("Dart _clipAnswerText not found");
  const seg = ENGINE_DART.slice(i, i + 6).join(NL);
  const anchor = "text.substring(0, _maxAnswerChars)}";
  const at = seg.indexOf(anchor);
  if (at < 0) throw new Error("Dart clip interpolation not found");
  const rest = seg.slice(at + anchor.length);
  const end = rest.indexOf("';");
  if (end < 0) throw new Error("Dart clip literal not closed");
  return rest.slice(0, end).split(BSN).join(NL);
}

// Dart 2127-2131: the two accepted forms of the answer label.
function dartAnswerStarts(): string[] {
  const i = ENGINE_DART.findIndex((l) => /^(static )?String\? parseAnswerBlock\(/.test(l.trim()));
  if (i < 0) throw new Error("Dart parseAnswerBlock not found");
  const flat = ENGINE_DART.slice(i, i + 24).join(NL).replace(/\s+/g, " ");
  const m = /startsWith\('([^']*)'\) \|\| t\.startsWith\('([^']*)'\)/.exec(flat);
  if (!m) throw new Error("Dart answer-start literals not found");
  return [m[1], m[2]];
}

// ---- expectations -----------------------------------------------------------
type Needle = {target: string; kind: string; text: string};

const NEEDLE_RE = /expect\(\s*(answer|sections|thoughts)\s*,\s*(isNotNull|isNull|contains\('([^']*)'\)|isNot\(contains\('([^']*)'\)\)|'([^']*)')(?:\s*,\s*reason:\s*'[^']*')?\s*\)/g;

function needlesOf(tag: string): {ported: Needle[]; skipped: string[]} {
  const body = caseLines(tag).join(NL);
  const skipped: string[] = [];
  let work = body.replace(
    /expect\(\s*OperationReport\.extractConclusion\([^)]*\),\s*'([^']*)',\s*\);/,
    (_m: string, lit: string): string => {
      skipped.push(lit);
      return "";
    },
  );
  // E2E-12 calls the extractor INSIDE expect(); fold it onto the answer target
  work = work.replace(/expect\(\s*AgentEngine\.parseAnswerBlock\((?:[^()]|\([^()]*\))*\)\s*,/g, "expect(answer,");
  const ported: Needle[] = [];
  NEEDLE_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = NEEDLE_RE.exec(work)) !== null) {
    const target = m[1];
    const matcher = m[2];
    if (matcher === "isNotNull") ported.push({target, kind: "notNull", text: ""});
    else if (matcher === "isNull") ported.push({target, kind: "isNull", text: ""});
    else if (matcher.indexOf("isNot(") === 0) ported.push({target, kind: "notContains", text: String(m[4])});
    else if (matcher.indexOf("contains(") === 0) ported.push({target, kind: "contains", text: String(m[3])});
    else ported.push({target, kind: "equals", text: String(m[5])});
  }
  const total = (work.match(/expect\(/g) || []).length;
  if (total !== ported.length) {
    throw new Error("E2E-" + tag + ": " + (total - ported.length) + " expectation(s) unclassified - re-read the Dart oracle");
  }
  return {ported, skipped};
}

function replay(tag: string): void {
  const text = caseText(tag);
  const lines = text.split(NL);
  const values: Record<string, string | null> = {
    answer: parseAnswerBlock(lines),
    sections: parseReportSections(lines),
    // the E2E-15 thought expectation runs on the ported stream parser
    thoughts: parseStream(text).filter((e) => e.type === "thought").map((e) => e.text ?? "").join(NL),
  };
  const {ported, skipped} = needlesOf(tag);
  expect(skipped).toHaveLength(tag === "15" ? 1 : 0);
  expect(ported.length).toBeGreaterThan(0);
  for (const n of ported) {
    const v = values[n.target];
    if (n.kind === "isNull") expect(v).toBeNull();
    else if (n.kind === "notNull") expect(v).not.toBeNull();
    else if (n.kind === "contains") expect(v ?? "").toContain(n.text);
    else if (n.kind === "notContains") expect(v ?? "").not.toContain(n.text);
    else expect(v).toBe(n.text);
  }
}

describe("answer-block extractors vs the Dart oracle", () => {
  it("oracle group intact: 302-418, six cases, 22 expectations", () => {
    expect(GROUP.from + 1).toBe(302);
    expect(GROUP.to + 1).toBe(418);
    const ids = ORACLE.slice(GROUP.from, GROUP.to + 1)
      .filter((l) => l.indexOf("test('E2E-") >= 0)
      .map((l) => String(/E2E-(\d+)/.exec(l)?.[1]));
    expect(ids).toEqual(["8", "9", "10", "11", "12", "15"]);
    expect((GROUP_TEXT.match(/expect\(/g) || []).length).toBe(22);
    expect((GROUP_TEXT.match(/OperationReport\./g) || []).length).toBe(1);
    expect((GROUP_TEXT.match(/ReActStreamParser\./g) || []).length).toBe(1);
  });

  it("pattern sources are byte-identical to the Dart RegExp literals", () => {
    expect(ANSWER_STOP_LINE.source).toBe(dartRegExpBody("_answerStopLine"));
    expect(SECTION_START_LINE.source).toBe(dartRegExpBody("_sectionStartLine"));
  });

  it("cap and clip marker byte-match the Dart constants", () => {
    expect(MAX_ANSWER_CHARS).toBe(dartMaxAnswerChars());
    const marker = dartClipMarker();
    expect(marker.length).toBeGreaterThan(1);
    expect(clipAnswerText("y".repeat(MAX_ANSWER_CHARS + 1)).slice(MAX_ANSWER_CHARS)).toBe(marker);
  });

  it("clipAnswerText keeps the exact cap boundary and the HEAD (R8)", () => {
    const exact = "y".repeat(MAX_ANSWER_CHARS);
    expect(clipAnswerText(exact)).toBe(exact);
    const over = clipAnswerText("y".repeat(MAX_ANSWER_CHARS + 1));
    expect(over.length).toBe(MAX_ANSWER_CHARS + dartClipMarker().length);
    expect(over.slice(0, MAX_ANSWER_CHARS)).toBe(exact);
  });

  it("firstColonIndex follows the Dart helper (2118-2124)", () => {
    const pat = dartRegExpBody("_answerStopLine");
    const at = pat.indexOf("[:");
    if (at < 0) throw new Error("colon class missing in the Dart pattern");
    const fullwidth = pat.slice(at + 2, pat.length - 1);
    expect(fullwidth.length).toBe(1);
    expect(firstColonIndex("ab" + fullwidth + "cd")).toBe(2);
    expect(firstColonIndex("a:bc")).toBe(1);
    expect(firstColonIndex("nothing to split")).toBe(-1);
  });

  it("an oversized answer block clips at MAX plus the Dart marker", () => {
    const starts = dartAnswerStarts();
    expect(starts).toHaveLength(2);
    const long = starts[0] + "x".repeat(MAX_ANSWER_CHARS + 500);
    const got = parseAnswerBlock(long.split(NL));
    expect(typeof got).toBe("string");
    expect((got as string).length).toBe(MAX_ANSWER_CHARS + dartClipMarker().length);
    expect((got as string).slice(0, MAX_ANSWER_CHARS)).toBe("x".repeat(MAX_ANSWER_CHARS));
    expect((got as string).endsWith(dartClipMarker())).toBe(true);
  });

  it("E2E-8: headings, lists and fenced code survive inside the answer", () => replay("8"));
  it("E2E-9: an action line inside a fence does not end the answer", () => replay("9"));
  it("E2E-10: bold field-like lines are not mistaken for sections", () => replay("10"));
  it("E2E-11: chunk-concatenated reply still yields the answer (R9 bug shape)", () => replay("11"));
  it("E2E-12: no answer block -> null, the old format is untouched", () => replay("12"));
  it("E2E-15: answer and four-field report split apart, thought stays clean", () => replay("15"));
});
