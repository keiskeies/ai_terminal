// test/live_thought_streaming_markdown.test.ts - r208 ports of
// utils/live_thought_text.dart + utils/streaming_markdown.dart. Unit pins for
// every documented edge + oracle blocks re-reading both Dart files at run time
// (regex sources, scan window, default caps, boundary semantics).
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {extractLiveThought} from "../src/utils/live_thought_text.js";
import {stableParagraphCut, unclosedFenceSplit} from "../src/utils/streaming_markdown.js";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const read = (rel: string) => readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL);
const DART_LT = read("../../ai_terminal/lib/utils/live_thought_text.dart");
const DART_SM = read("../../ai_terminal/lib/utils/streaming_markdown.dart");

const T = "\u601D\u8003"; // 思考
const A = "\u56DE\u7B54"; // 回答
const ACT = "\u52A8\u4F5C"; // 动作

describe("extractLiveThought", () => {
  it("no thought marker -> the source is returned trimmed", () => {
    expect(extractLiveThought("just prose")).toBe("just prose");
  });

  it("takes the text after the LAST marker", () => {
    const raw = T + ": first\n" + T + ": second";
    expect(extractLiveThought(raw)).toBe("second");
  });

  it("accepts the full-width colon variant", () => {
    expect(extractLiveThought(T + "\uFF1A deep work")).toBe("deep work");
  });

  it("cuts at the next protocol line (Dart: 动作/命令/选项/工具/参数/回答)", () => {
    const raw = T + ": thinking hard" + NL + ACT + ": execute";
    expect(extractLiveThought(raw)).toBe("thinking hard");
    const raw2 = T + ": a" + NL + A + ": long answer";
    expect(extractLiveThought(raw2)).toBe("a");
  });

  it("long text keeps the TAIL beyond maxChars (R8)", () => {
    const long = "x".repeat(2000);
    expect(extractLiveThought(T + ": " + long).length).toBe(1200);
    expect(extractLiveThought(T + ": " + long)).toBe(long.slice(long.length - 1200));
  });

  it("window fallback: marker outside the 4096 tail window still found", () => {
    // 思考: near the head, then a >4096 answer tail - the window has no marker,
    // full scan must kick in and the answer must NOT render as thought.
    const answer = "y".repeat(5000);
    const raw = T + ": plan it\n" + A + ": " + answer;
    expect(extractLiveThought(raw)).toBe("plan it");
  });

  it("marker inside the window: no full rescan, last marker wins", () => {
    const filler = "z".repeat(5000);
    const raw = T + ": old" + NL + filler + NL + T + ": current thought";
    expect(extractLiveThought(raw)).toBe("current thought");
  });
});

describe("stableParagraphCut", () => {
  it("-1 when there is no blank line at all", () => {
    expect(stableParagraphCut("para one\nstill one")).toBe(-1);
  });
  it("cut lands just after the LAST blank line outside a fence", () => {
    const t = "a\n\nb\n\nc";
    const cut = stableParagraphCut(t);
    // cut points just AFTER the blank line's newline, not at the blank.
    expect(cut).toBe("a\n\nb\n\n".length);
    expect(t.slice(cut)).toBe("c");
  });
  it("-1 when every blank line sits inside a code fence", () => {
    expect(stableParagraphCut("```\nblank follows\n\nmore\n```")).toBe(-1);
  });
  it("-1 when the cut would be exactly at text end", () => {
    expect(stableParagraphCut("para\n\n")).toBe(-1);
  });
  it("fence toggle survives an indented fence marker (trimLeft)", () => {
    // "a\n\n```\n  ```\n\nb": the indented  ```  on line 3 CLOSES the fence
    // (trimLeft), so the line-4 blank is a legal boundary; a non-trimming
    // implementation would still be inside the fence and return -1.
    const t = "a\n\n```\n  ```\n\nb";
    expect(stableParagraphCut(t)).toBe(t.length - 1);
  });
  it("blank right after a closed fence cuts; blank while open never does", () => {
    expect(stableParagraphCut("x\n```\n\n```\n\ny")).toBe("x\n```\n\n```\n\n".length);
  });
});

describe("unclosedFenceSplit", () => {
  it("null when no fence at all or the fence is closed", () => {
    expect(unclosedFenceSplit("plain text")).toBeNull();
    expect(unclosedFenceSplit("```\ncode\n```")).toBeNull();
  });
  it("unclosed fence splits into (before, code-without-the-fence-line)", () => {
    const r = unclosedFenceSplit("intro\n```ts\nconst x = 1;");
    expect(r).not.toBeNull();
    expect(r![0]).toBe("intro\n");
    expect(r![1]).toBe("const x = 1;");
  });
  it("fence line with no newline yet -> empty code", () => {
    const r = unclosedFenceSplit("intro\n```ts");
    expect(r).not.toBeNull();
    expect(r![1]).toBe("");
  });
  it("last fence wins: closed-then-open returns the open span", () => {
    const r = unclosedFenceSplit("a\n```\nx\n```\nb\n```\nnewcode");
    expect(r![0]).toBe("a\n```\nx\n```\nb\n");
    expect(r![1]).toBe("newcode");
  });
});

describe("oracle: live_thought_text.dart", () => {
  it("regex sources are character-identical", () => {
    expect(DART_LT).toContain("RegExp(r'" + T + "[:：]')");
    const dProto = DART_LT.match(/RegExp\(r'(\\n[^']*)'\)/);
    expect(dProto, "Dart protocol-line regex").not.toBeNull();
    // Node source holds the same escaped body
    expect(dProto![1]).toBe("\\n\\s*(计划|动作|命令|选项|工具|参数|回答)[:：]");
  });
  it("scan window 4096 and maxChars default 1200 match", () => {
    expect(DART_LT).toContain("const int _scanWindow = 4096;");
    expect(DART_LT).toContain("int maxChars = 1200");
  });
  it("tail-retention + full-rescan fallback exist in Dart text", () => {
    expect(DART_LT).toContain("text.substring(text.length - maxChars)");
    expect(DART_LT).toContain("if (matches.isEmpty && !identical(source, raw))");
  });
});

describe("oracle: streaming_markdown.dart", () => {
  it("boundary guards are the same comparisons", () => {
    expect(DART_SM).toContain("if (lastCut <= 0 || lastCut >= text.length) return -1;");
    expect(DART_SM).toContain("if (!inCode || fenceStart < 0) return null;");
  });
  it("fence detection uses trimLeft + triple backtick, position advances by line+1", () => {
    expect(DART_SM).toContain("line.trimLeft().startsWith('```')");
    expect(DART_SM).toContain("pos += line.length + 1;");
  });
  it("code payload drops the fence line through the first newline", () => {
    expect(DART_SM).toContain("final nl = code.indexOf('\\n');");
    expect(DART_SM).toContain("code = nl < 0 ? '' : code.substring(nl + 1);");
  });
});
