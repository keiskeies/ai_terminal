// test/pty_output_detector_oracle.test.ts - r216.
// Unit cases reproduce Dart behaviors; the oracle re-reads
// services/pty_output_detector.dart and diffs every regex body, enum member
// and reason literal against the port.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {
  CommandFailureKind, PtyOutputDetector,
  detectCommandFailure, SudoPromptResponder,
} from "../src/utils/pty_output_detector.js";
import {CommandFailureKind as ViaTools} from "../src/tools/index.js";

const NL = String.fromCharCode(10);
const ESC = String.fromCharCode(27);
const DQ = String.fromCharCode(34);
const SQ = String.fromCharCode(39);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const DART = readFileSync(HERE + "../../ai_terminal/lib/services/pty_output_detector.dart", "utf-8")
  .split(String.fromCharCode(13) + String.fromCharCode(10)).join(NL);
const reasonRe = /reason: '([^']*)'/g;
const dartReasons = [...DART.matchAll(reasonRe)].map(x => x[1]);

describe("waitsForPager", () => {
  it("pager status lines match only at the tail", () => {
    expect(PtyOutputDetector.waitsForPager("(END)")).toBe(true);
    expect(PtyOutputDetector.waitsForPager("lines 1-20/300")).toBe(true);
    expect(PtyOutputDetector.waitsForPager("--More--(42%)")).toBe(true);
    expect(PtyOutputDetector.waitsForPager("(END) trailing text")).toBe(false);
  });
  it("ANSI-wrapped (END) matches", () => {
    const s = "junk" + ESC + "[7m(END)" + ESC + "[27m  ";
    expect(PtyOutputDetector.waitsForPager(s)).toBe(true);
  });
  it("only the tail 2KB is scanned", () => {
    const pad = "x".repeat(4000);
    expect(PtyOutputDetector.waitsForPager("(END)" + pad)).toBe(false);
  });
});

describe("sudo prompt", () => {
  it("prompt must sit at the buffer end after the colon", () => {
    expect(PtyOutputDetector.waitsForSudoPassword("[sudo] password for cjm:")).toBe(true);
    expect(PtyOutputDetector.waitsForSudoPassword("[sudo] cjm 的密码：")).toBe(true);
    expect(PtyOutputDetector.waitsForSudoPassword("grep " + SQ + "[sudo]" + SQ + " file")).toBe(false);
    expect(PtyOutputDetector.waitsForSudoPassword("[sudo] password for cjm: done")).toBe(false);
  });
  it("responder answers each new prompt exactly once", () => {
    const r = new SudoPromptResponder();
    expect(r.shouldAnswer("[sudo] password for u:")).toBe(true);
    expect(r.shouldAnswer("[sudo] password for u: ")).toBe(false);
    expect(r.shouldAnswer("out" + NL + "[sudo] password for u:")).toBe(true);
    expect(r.shouldAnswer("no prompt here")).toBe(false);
  });
});


describe("detectCommandFailure", () => {
  it("completed marker+digits suppresses everything", () => {
    const buf = "-bash: syntax error near unexpected token" + NL + "EXITCODE_3:0";
    const d = detectCommandFailure({buffer: buf, marker: "EXITCODE_3:",
      elapsedMs: 5000, isWindows: false});
    expect(d).toBeNull();
  });
  it("marker echo without digits does NOT count as completion", () => {
    // AGENTS.md R8: bare marker echo must not gate detection off
    const buf = "echo EXITCODE_1:$?" + NL + "-bash: syntax error near '&&'";
    const d = detectCommandFailure({buffer: buf, marker: "EXITCODE_1:",
      elapsedMs: 400, isWindows: false});
    expect(d!.kind).toBe(CommandFailureKind.syntaxError);
  });
  it("under 150ms is quiet", () => {
    const d = detectCommandFailure({buffer: "bash: syntax error near 'x'",
      marker: "EXITCODE_9:", elapsedMs: 100, isWindows: false});
    expect(d).toBeNull();
  });
  it("syntax error kind + English reason prefix", () => {
    const buf = "$ ls &;" + NL + "-bash: syntax error near unexpected token";
    const d = detectCommandFailure({buffer: buf, marker: "EXITCODE_1:",
      elapsedMs: 400, isWindows: false});
    expect(d!.kind).toBe(CommandFailureKind.syntaxError);
    expect(d!.reason.startsWith("Shell syntax error: ")).toBe(true);
    expect(d!.reason).toContain("syntax error near unexpected token");
  });
  it("uppercase SYNTAX ERROR matches (case-insensitive keyword)", () => {
    const d = detectCommandFailure({buffer: "bash: SYNTAX ERROR near 'x'",
      marker: "EXITCODE_1:", elapsedMs: 400, isWindows: false});
    expect(d!.kind).toBe(CommandFailureKind.syntaxError);
  });
  it("command not found is NOT a syntax error", () => {
    const d = detectCommandFailure({buffer: "bash: line 1: foo: command not found",
      marker: "EXITCODE_1:", elapsedMs: 400, isWindows: false});
    expect(d).toBeNull();
  });
  it("PS2 prompt fires after 500ms with the Dart zh reason", () => {
    const buf = "$ echo " + DQ + NL + "> ";
    const mk = (ms: number) => detectCommandFailure({buffer: buf,
      marker: "EXITCODE_1:", elapsedMs: ms, isWindows: false});
    expect(mk(300)).toBeNull();
    const d = mk(600);
    expect(d!.kind).toBe(CommandFailureKind.syntaxError);
    expect(d!.reason).toBe(dartReasons[1]);
  });
  it("dquote> prompt variant matches", () => {
    const buf = "$ cat " + DQ + NL + "dquote> ";
    const d = detectCommandFailure({buffer: buf, marker: "EXITCODE_1:",
      elapsedMs: 800, isWindows: false});
    expect(d!.kind).toBe(CommandFailureKind.syntaxError);
  });
  it("ssh passphrase prompt after 300ms on windows too", () => {
    const d = detectCommandFailure({buffer: "Enter passphrase for key ': ",
      marker: "EXITCODE_1:", elapsedMs: 400, isWindows: true});
    expect(d!.kind).toBe(CommandFailureKind.interactivePrompt);
  });
  it("yes/no confirmation prompt matches at line start", () => {
    const d = detectCommandFailure({buffer: "overwrite? " + NL + "  (yes/no) ",
      marker: "EXITCODE_1:", elapsedMs: 400, isWindows: false});
    expect(d!.kind).toBe(CommandFailureKind.interactivePrompt);
  });
  it("sudo prompt: fails unanswerable, silent when answered", () => {
    const buf = "[sudo] password for u:";
    const a = detectCommandFailure({buffer: buf, marker: "EXITCODE_1:",
      elapsedMs: 400, isWindows: false});
    expect(a!.kind).toBe(CommandFailureKind.interactivePrompt);
    expect(a!.reason).toBe(dartReasons[2]);
    const b = detectCommandFailure({buffer: buf, marker: "EXITCODE_1:",
      elapsedMs: 400, isWindows: false, sudoPromptWillBeAnswered: true});
    expect(b).toBeNull();
  });
  it("windows skips POSIX shell checks", () => {
    const d = detectCommandFailure({buffer: "-bash: syntax error near 'x'",
      marker: "EXITCODE_1:", elapsedMs: 400, isWindows: true});
    expect(d).toBeNull();
  });
  it("custom donePattern overrides marker escaping", () => {
    const d = detectCommandFailure({buffer: "DONE-9 Password: ",
      marker: "DONE-9:", elapsedMs: 400, isWindows: false,
      donePattern: /DONE-9 OK/});
    expect(d!.kind).toBe(CommandFailureKind.interactivePrompt);
    const d2 = detectCommandFailure({buffer: "DONE-9 OK password: x",
      marker: "DONE-9:", elapsedMs: 400, isWindows: false,
      donePattern: /DONE-9 OK/});
    expect(d2).toBeNull();
  });
});

describe("oracle: diff against dart source", () => {
  it("dart exposes exactly 4 reason literals and 6 regexes", () => {
    expect(dartReasons.length).toBe(4);
    const decls = [...DART.matchAll(/static final ([A-Za-z0-9_]+) = RegExp[(]/g)].map(x => x[1]);
    expect(decls.length).toBe(6);
  });
  it("all 6 regex bodies byte-identical + flags match", () => {
    const pairs: Array<[string, RegExp]> = [
      ["_syntaxErrorPattern", PtyOutputDetector.syntaxErrorPattern],
      ["_syntaxErrorKeyword", PtyOutputDetector.syntaxErrorKeyword],
      ["_ps2PromptPattern", PtyOutputDetector.ps2PromptPattern],
      ["_interactivePromptPattern", PtyOutputDetector.interactivePromptPattern],
      ["_sudoPromptAtEnd", PtyOutputDetector.sudoPromptAtEnd],
      ["_pagerStatusAtEnd", PtyOutputDetector.pagerStatusAtEnd],
    ];
    for (const [dartName, re] of pairs) {
      const i = DART.indexOf("static final " + dartName + " = RegExp(");
      expect(i, dartName).toBeGreaterThan(-1);
      const nf = DART.indexOf("static final", i + 1);
      const nd = DART.indexOf(NL + "  ///", i);
      const cands = [nf, nd].filter(x => x > i);
      const segEnd = cands.length ? Math.min(...cands) : DART.length;
      const seg = DART.slice(i, segEnd);
      const chunks = [...seg.matchAll(/r'([^']*)'/g)].map(x => x[1]);
      expect(chunks.length, dartName).toBeGreaterThan(0);
      expect(re.source, dartName).toBe(new RegExp(chunks.join(""), re.flags).source);
      const wantI = seg.includes("caseSensitive: false");
      const wantM = seg.includes("multiLine: true");
      expect(re.flags.includes("i"), dartName).toBe(wantI);
      expect(re.flags.includes("m"), dartName).toBe(wantM);
    }
  });
  it("enum members match dart declaration order", () => {
    const body = DART.slice(DART.indexOf("enum CommandFailureKind {"));
    const inner = body.slice(0, body.indexOf(String.fromCharCode(10) + "}"));
    const dartOrder = inner.split(NL).map(l => l.trim())
      .filter(l => l.endsWith(",") && /^[a-zA-Z0-9_]+,$/.test(l))
      .map(l => l.slice(0, -1));
    expect(dartOrder.length).toBe(8);
    expect(Object.values(CommandFailureKind)).toEqual(dartOrder);
    expect(ViaTools).toBe(CommandFailureKind);
  });
  it("dart reason literals appear verbatim in the port", () => {
    const port = readFileSync(HERE + "../src/utils/pty_output_detector.ts", "utf-8");
    expect(port.includes("Shell syntax error: ")).toBe(true);
    for (const lit of dartReasons.slice(1)) {
      expect(port.includes(lit), lit.slice(0, 12)).toBe(true);
    }
  });
  it("thresholds 150/300/500 and pager tail 2048 pinned in both sources", () => {
    const port = readFileSync(HERE + "../src/utils/pty_output_detector.ts", "utf-8");
    for (const n of ["150", "300", "500", "2048"]) {
      expect(DART.includes(n), "dart " + n).toBe(true);
      expect(port.includes(n), "port " + n).toBe(true);
    }
  });
  it("decision order pinned: completed-check before elapsed-gate before platform-branch", () => {
    const port = readFileSync(HERE + "../src/utils/pty_output_detector.ts", "utf-8");
    const a = port.indexOf("completedPattern.test(");
    const b = port.indexOf("elapsedMs < 150");
    const c = port.indexOf("o.isWindows)");
    const d = port.indexOf("elapsedMs > 500");
    const e = port.indexOf("elapsedMs > 300");
    expect(a).toBeLessThan(b);
    expect(b).toBeLessThan(c);
    expect(c).toBeLessThan(d);
    expect(d).toBeLessThan(e);
  });
});
