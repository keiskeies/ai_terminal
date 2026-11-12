// ASCII-only file per project emit rules; CJK literals are \uXXXX escapes
// byte-compared against the Dart oracle where stated.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));

import {isQueryCommand, QUERY_PREFIXES, INTERACTIVE_PREFIXES, isTaskComplete, TASK_COMPLETE_KEYWORDS, TASK_COMPLETE_START, TASK_COMPLETE_END} from "../src/utils/command_heuristics.js";

function dartHeur(): string {
  return readFileSync(HERE + "../../ai_terminal/lib/utils/command_heuristics.dart", "utf-8").replace(/\r\n/g, NL);
}
// single-quoted literals between two markers, Dart backslash-n resolved
function dartLiterals(src: string, startMark: string, endMark: string): string[] {
  const a = src.indexOf(startMark);
  const b = src.indexOf(endMark, a);
  if (a < 0 || b < 0) throw new Error("oracle markers not found");
  const body = src.slice(a, b);
  const out: string[] = [];
  const re = /'((?:[^'\\]|\\.)*)'/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(body)) !== null) out.push(m[1].replace(/\\n/g, NL));
  return out;
}
// Round 127: the two anchored per-line patterns of isTaskComplete. Dart builds
// each one from literal fragments around _taskCompleteKeywords.join('|'); the
// join call is cut out first so its own '|' literal is never mistaken for a
// fragment. Raw (r'..') fragments keep their backslashes, exactly like the
// RegExp.source they must match.
function dartRegexFragments(src: string, decl: string): string[] {
  const at = src.indexOf(decl);
  if (at < 0) throw new Error("regex decl not found: " + decl);
  const end = src.indexOf(NL + ");", at);
  if (end < 0) throw new Error("regex decl not closed: " + decl);
  const SQ = String.fromCharCode(39);
  const JOIN = "join(" + SQ + "|" + SQ + ")";
  const block = src.slice(at, end).split(JOIN).join("");
  const out: string[] = [];
  for (const line of block.split(NL)) {
    let i = 0;
    while (i < line.length) {
      if (line[i] === "r" && line[i + 1] === SQ) {
        const q = line.indexOf(SQ, i + 2);
        out.push(line.slice(i + 2, q));
        i = q + 1;
        continue;
      }
      if (line[i] === SQ) {
        const q = line.indexOf(SQ, i + 1);
        out.push(line.slice(i + 1, q));
        i = q + 1;
        continue;
      }
      i++;
    }
  }
  if (out.length !== 2) throw new Error("expected 2 fragments for " + decl + ", got " + out.length);
  return out;
}


describe("isQueryCommand oracle parity (command_heuristics.dart 40-117)", () => {
  it("query prefix table equals the Dart literal list, order included", () => {
    const oracle = dartLiterals(dartHeur(), "final queryPrefixes = [", NL + "  ];");
    expect(QUERY_PREFIXES.length).toBeGreaterThan(100);
    expect(QUERY_PREFIXES).toEqual(oracle);
  });
  it("interactive exclusion table equals the Dart literal list", () => {
    const oracle = dartLiterals(dartHeur(), "const interactivePrefixes = [", NL + "  ];");
    expect(INTERACTIVE_PREFIXES).toEqual(oracle);
  });
});

describe("isQueryCommand behaviour", () => {
  it("bare interactive names are rejected outright", () => {
    for (const c of ["top", "less", "more", "vi", "vim", "nano"]) {
      expect(isQueryCommand(c)).toBe(false);
    }
  });
  it("interactive prefixes rejected even with args", () => {
    expect(isQueryCommand("tail -f app.log")).toBe(false);
    expect(isQueryCommand("  tail --follow x")).toBe(false);
    expect(isQueryCommand("tailf app.log")).toBe(false);
    expect(isQueryCommand("less /var/log/syslog")).toBe(false);
    expect(isQueryCommand("vim /etc/hosts")).toBe(false);
  });
  it("plain tail and head are queries", () => {
    expect(isQueryCommand("tail -n 50 app.log")).toBe(true);
    expect(isQueryCommand("head -100 big.csv")).toBe(true);
  });
  it("sub-command granularity mirrors Dart", () => {
    expect(isQueryCommand("systemctl status nginx")).toBe(true);
    expect(isQueryCommand("systemctl restart nginx")).toBe(false);
    expect(isQueryCommand("docker ps -a")).toBe(true);
    expect(isQueryCommand("docker rm web1")).toBe(false);
    expect(isQueryCommand("git log --oneline -5")).toBe(true);
    expect(isQueryCommand("git commit -m x")).toBe(false);
    expect(isQueryCommand("iptables -nL")).toBe(true);
    expect(isQueryCommand("iptables -F")).toBe(false);
    expect(isQueryCommand("sed -n 10p f")).toBe(true);
    expect(isQueryCommand("sed -i s/a/b/ f")).toBe(false);
  });
  it("leading whitespace and case are normalised like Dart", () => {
    expect(isQueryCommand("   CAT NOTES.md")).toBe(true);
    expect(isQueryCommand(NL + "  PS aux")).toBe(true);
  });
  it("documented quirk kept 1:1: bare w prefix swallows write- verbs", () => {
    // The Dart table has a bare "w" (for who), so startsWith matches "wall" /
    // "write-item". Parity beats intuition: fixing it needs a Dart-side change
    // first, never a silent one-sided Node fix.
    expect(isQueryCommand("write-item foo")).toBe(true);
  });
});

describe("isTaskComplete oracle parity (command_heuristics.dart 119-163)", () => {
  it("completion keyword table equals the Dart literal list, order included", () => {
    // Dart closes this table at column 0, unlike the indented interactive table
    const oracle = dartLiterals(dartHeur(), "const _taskCompleteKeywords = [", NL + "];");
    expect(oracle.length).toBe(10);
    expect(TASK_COMPLETE_KEYWORDS).toEqual(oracle);
  });
  it("line-start pattern .source is Dart 127-131 rebuilt from its fragments", () => {
    const f = dartRegexFragments(dartHeur(), "final RegExp _taskCompleteStartRegex = RegExp(");
    const want = f[0] + TASK_COMPLETE_KEYWORDS.join("|") + f[1];
    expect(TASK_COMPLETE_START.source).toBe(want);
  });
  it("line-end pattern .source is Dart 133-135 rebuilt from its fragments", () => {
    const f = dartRegexFragments(dartHeur(), "final RegExp _taskCompleteEndRegex = RegExp(");
    expect(f[0]).toBe("^.{0,30}?("); // the {0,30} cap head is a normal Dart literal
    const want = f[0] + TASK_COMPLETE_KEYWORDS.join("|") + f[1];
    expect(TASK_COMPLETE_END.source).toBe(want);
  });
  it("both Dart patterns share the tail class the port shares", () => {
    const src = dartHeur();
    const s = dartRegexFragments(src, "final RegExp _taskCompleteStartRegex = RegExp(");
    const e = dartRegexFragments(src, "final RegExp _taskCompleteEndRegex = RegExp(");
    expect(s[1]).toBe(e[1]); // Dart writes the same tail twice; the port shares it
  });
});

describe("isTaskComplete behaviour (Dart oracle test/command_heuristics_test.dart 385-451)", () => {
  it("the 9 completion-sounding oracle cases return true", () => {
    const yes: Array<[string, boolean]> = [
      ["\u4EFB\u52A1\u5B8C\u6210", true],
      ["\u4EFB\u52A1\u5DF2\u5B8C\u6210", true],
      ["\u2705 \u4EFB\u52A1\u5B8C\u6210", true],
      ["\u5B89\u88C5\u5DF2\u5B8C\u6210", true],
      ["\u64CD\u4F5C\u5B8C\u6210", true],
      ["\u90E8\u7F72\u5B8C\u6210", true],
      ["\u5B89\u88C5\u5DF2\u5B8C\u6210", true],
      ["\u90E8\u7F72\u5B8C\u6210\u3002", true],
      ["\u2705 \u4EFB\u52A1\u5B8C\u6210\u3002", true],
    ];
    for (const [input, want] of yes) expect(isTaskComplete(input)).toBe(want);
  });
  it("the 7 non-completion oracle cases return false", () => {
    // Dart oracle 434: a keyword mentioned inside a thought, or followed by more
    // words, must NOT read as done; the 57-cjk-char long line trips the cap.
    const no: Array<[string, boolean]> = [
      ["\u6B63\u5728\u6267\u884C\u547D\u4EE4", false],
      ["task done", false],
      ["", false],
      ["\u6211\u4F1A\u68C0\u67E5\u4EFB\u52A1\u5B8C\u6210\u60C5\u51B5", false],
      ["\u5982\u679C\u5B89\u88C5\u5B8C\u6210\u5219\u7EE7\u7EED", false],
      ["\u5DF2\u5B8C\u6210\u4E86\u4E0A\u8FF0\u6B65\u9AA4", false],
      ["\u6211\u73B0\u5728\u9700\u8981\u68C0\u67E5\u7CFB\u7EDF\u72B6\u6001\uFF0C\u5305\u62EC\u670D\u52A1\u8FD0\u884C\u60C5\u51B5\u3001\u65E5\u5FD7\u8F93\u51FA\u3001\u7AEF\u53E3\u76D1\u542C\u7B49\uFF0C\u4EFB\u52A1\u5B8C\u6210\u60C5\u51B5\u7684\u8BC4\u4F30\u9700\u8981\u7B49\u6240\u6709\u68C0\u67E5\u90FD\u505A\u5B8C\u624D\u80FD\u4E0B\u7ED3\u8BBA\u3002", false],
    ];
    for (const [input, want] of no) expect(isTaskComplete(input)).toBe(want);
  });
  it("Node-only edge: CRLF splits the turn, a lone CR does not", () => {
    // Dart 136 _lineBreakRegex is RegExp(r'\r?\n') - inlined at the split, so the
    // engine can hand us its raw CRLF response without faking a second line.
    const A = "\u4EFB\u52A1\u5B8C\u6210"; // ren wu wan cheng
    const B = "\u5B89\u88C5\u5DF2\u5B8C\u6210"; // an zhuang yi wan cheng
    expect(isTaskComplete(A + "\r\n" + B)).toBe(true);
    // one long unbroken line that merely mentions both keywords -> no match
    expect(isTaskComplete(A + "\r" + B)).toBe(false);
  });
  it("Node-only edge: the line cap is > 60, not >= 60 (Dart 158)", () => {
    const A = "\u4EFB\u52A1\u5B8C\u6210";
    const mid = "\u00B7"; // filler the tail class treats as punctuation
    expect(Array.from(A + mid.repeat(56)).length).toBe(60);
    expect(isTaskComplete(A + mid.repeat(56))).toBe(true);
    expect(Array.from(A + mid.repeat(57)).length).toBe(61);
    expect(isTaskComplete(A + mid.repeat(57))).toBe(false);
  });
  it("Node-only edge: blank turns are false, a padded keyword line is not", () => {
    expect(isTaskComplete("")).toBe(false);
    expect(isTaskComplete("   ")).toBe(false);
    expect(isTaskComplete(NL + NL + "  \u4EFB\u52A1\u5B8C\u6210  " + NL)).toBe(true);
  });
});
