// Unit tests for react/regex.ts - the shared ReAct parser patterns.
// parser.ts consumes these module-level regexes; a regression here silently
// drops tool calls or plan steps (see R9: parser-format changes need tests).
// These pin each pattern's matches, capture groups, anchors and negatives,
// plus the global-flag contract (replace-only usage, stateless across inputs).

import {describe, it, expect} from "vitest";
import {
  XML_FENCED, XML_BARE, RESIDUAL_SEP,
  CODE_FENCE_PREFIX, CODE_FENCE_SUFFIX,
  PLAN_BULLET, PLAN_STATUS_BOX, PLAN_TITLE_PREFIX,
} from "../src/react/regex.js";

// CJK / special characters used by the patterns, built ASCII-safe.
const BULLET = String.fromCodePoint(0x2022);            // bullet glyph
const IDEOGRAPHIC_COMMA = String.fromCodePoint(0x3001); // CJK enumeration comma
const OPEN_BOX = String.fromCodePoint(0x3010);          // left lenticular bracket
const CLOSE_BOX = String.fromCodePoint(0x3011);         // right lenticular bracket
const OPEN_FULL = String.fromCodePoint(0xFF08);         // left fullwidth paren
const CLOSE_FULL = String.fromCodePoint(0xFF09);        // right fullwidth paren
const DONE = String.fromCodePoint(0x5B8C, 0x6210);      // done marker text
const EN_DASH = String.fromCodePoint(0x2013);
const EM_DASH = String.fromCodePoint(0x2014);
const FULLWIDTH_COLON = String.fromCodePoint(0xFF1A);

function fencedXml(func: string, cmd: string): string {
  return "---\n<function=" + func + ">\n<parameter=command>" + cmd + "</parameter>\n</function>\n---";
}
function bareXml(func: string, cmd: string): string {
  return "<function=" + func + ">\n<parameter=command>" + cmd + "</parameter>\n</function>";
}
// Capture the first replacement callback (how parser.ts actually uses them).
function captureFirst(pattern: RegExp, src: string): string[] | null {
  let captured: string[] | null = null;
  src.replace(pattern, (m: string, a: string, b: string) => {
    if (captured === null) captured = [m, a, b];
    return m;
  });
  return captured;
}

describe("global-flag contract (replace-only usage)", () => {
  it("XML/block patterns are global, plan/suffix patterns are not", () => {
    expect(XML_FENCED.global).toBe(true);
    expect(XML_BARE.global).toBe(true);
    expect(RESIDUAL_SEP.global).toBe(true);
    expect(CODE_FENCE_PREFIX.global).toBe(true);
    expect(CODE_FENCE_SUFFIX.global).toBe(false);
    expect(PLAN_BULLET.global).toBe(false);
    expect(PLAN_STATUS_BOX.global).toBe(false);
    expect(PLAN_TITLE_PREFIX.global).toBe(false);
  });
  it("reusing a global pattern across two inputs captures both (no lastIndex leak)", () => {
    // replace() resets lastIndex; this pins the module contract parser.ts relies on.
    const a = captureFirst(XML_BARE, bareXml("terminal", "ls"));
    const b = captureFirst(XML_BARE, bareXml("execute", "pwd"));
    expect(a!.length).toBe(3);
    expect(b![1]).toBe("execute");
    expect(b![2]).toBe("pwd");
  });
});

describe("XML_FENCED", () => {
  it("matches a fully fenced tool-call block and captures func + command", () => {
    const src = "before\n" + fencedXml("terminal", "ls -la") + "\nafter";
    const cap = captureFirst(XML_FENCED, src);
    expect(cap).not.toBeNull();
    expect(cap![1]).toBe("terminal");
    expect(cap![2]).toBe("ls -la");
  });
  it("captures multi-line commands", () => {
    const cap = captureFirst(XML_FENCED, fencedXml("run_command", "line1\nline2"));
    expect(cap![2]).toBe("line1\nline2");
  });
  it("does NOT match an unfenced block", () => {
    expect(captureFirst(XML_FENCED, bareXml("terminal", "ls"))).toBeNull();
  });
});

describe("XML_BARE", () => {
  it("matches a bare tool-call block", () => {
    const cap = captureFirst(XML_BARE, "x " + bareXml("execute", "pwd"));
    expect(cap![1]).toBe("execute");
    expect(cap![2]).toBe("pwd");
  });
  it("also matches inside a fenced block (parser replaces FENCED first)", () => {
    const cap = captureFirst(XML_BARE, fencedXml("terminal", "ls"));
    expect(cap![1]).toBe("terminal");
  });
});

describe("RESIDUAL_SEP", () => {
  it("removes standalone --- lines", () => {
    expect("a\n---\nb".replace(RESIDUAL_SEP, "")).toBe("a\n\nb");
  });
  it("allows trailing whitespace on the separator line", () => {
    // ^---\s*$ with m flag: the \s* absorbs the spaces/tabs before the line end.
    expect("a\n--- \t\nb".replace(RESIDUAL_SEP, "")).toBe("a\n\nb");
  });
  it("does NOT touch inline --- inside a line", () => {
    expect("a---b".replace(RESIDUAL_SEP, "")).toBe("a---b");
  });
  it("does NOT match a 4-dash rule or an indented separator", () => {
    expect("----".replace(RESIDUAL_SEP, "")).toBe("----");
    expect("  ---".replace(RESIDUAL_SEP, "")).toBe("  ---");
  });
});

describe("CODE_FENCE_PREFIX / CODE_FENCE_SUFFIX (cleanCommand)", () => {
  it("strips a language-tagged fence around a command", () => {
    const cleaned = "```bash\nls\n```"
      .replace(CODE_FENCE_PREFIX, "")
      .replace(CODE_FENCE_SUFFIX, "")
      .trim();
    expect(cleaned).toBe("ls");
  });
  it("strips a bare fence pair", () => {
    const cleaned = "```\nnpm i\n```"
      .replace(CODE_FENCE_PREFIX, "")
      .replace(CODE_FENCE_SUFFIX, "")
      .trim();
    expect(cleaned).toBe("npm i");
  });
  it("prefix is anchored: a fence mid-string is left alone", () => {
    expect("a\n```x".replace(CODE_FENCE_PREFIX, "")).toBe("a\n```x");
  });
  it("suffix is anchored at end: trailing junk blocks the match", () => {
    expect("\n```x".replace(CODE_FENCE_SUFFIX, "")).toBe("\n```x");
  });
});

describe("PLAN_BULLET", () => {
  const bullets = ["- ", "* ", BULLET + " ", "1. ", "2) ", "3" + IDEOGRAPHIC_COMMA + " "];
  bullets.forEach((b) => {
    it("matches bullet " + JSON.stringify(b) + " at line start", () => {
      const m = (b + "task").match(PLAN_BULLET);
      expect(m).not.toBeNull();
      expect(m![0]).toBe(b);
    });
  });
  it("does NOT match bare text, unspaced dash, or mid-line dash", () => {
    expect("task".match(PLAN_BULLET)).toBeNull();
    expect("-task".match(PLAN_BULLET)).toBeNull();
    expect("foo - task".match(PLAN_BULLET)).toBeNull();
  });
});

describe("PLAN_STATUS_BOX", () => {
  const boxes: Array<[string, string]> = [
    ["[x] do", "x"],
    [OPEN_BOX + DONE + CLOSE_BOX + " do", DONE],
    ["(doing) do", "doing"],
    [OPEN_FULL + "doing" + CLOSE_FULL + " do", "doing"],
  ];
  boxes.forEach(([src, inner]) => {
    it("captures inner marker from " + JSON.stringify(src), () => {
      const m = src.match(PLAN_STATUS_BOX);
      expect(m).not.toBeNull();
      expect(m![1]).toBe(inner);
    });
  });
  it("does NOT match an empty box", () => {
    expect("[] do".match(PLAN_STATUS_BOX)).toBeNull();
  });
  it("open/close classes are lenient (open [ with close))", () => {
    expect("[x) do".match(PLAN_STATUS_BOX)).not.toBeNull();
  });
  it("quirk: the capture excludes only CLOSING brackets, so a nested box"
     + " captures from the first opener to the first closer", () => {
    // Faithful port of the Dart pattern: for "(【x】)" the capture starts after "
    // "(", tolerates 【 (not in the negated class) and stops at 】 => "【x".
    const m = ("(" + OPEN_BOX + "x" + CLOSE_BOX + ") do").match(PLAN_STATUS_BOX);
    expect(m).not.toBeNull();
    expect(m![1]).toBe(OPEN_BOX + "x");
  });
});

describe("PLAN_TITLE_PREFIX", () => {
  ["- ", EN_DASH + " ", EM_DASH + " ", ": ", FULLWIDTH_COLON + " "].forEach((p) => {
    it("strips leading " + JSON.stringify(p), () => {
      expect((p + "Title").replace(PLAN_TITLE_PREFIX, "")).toBe("Title");
    });
  });
  it("leaves a plain title untouched", () => {
    expect("Title".replace(PLAN_TITLE_PREFIX, "")).toBe("Title");
  });
});

describe("plan-line pipeline (bullet -> box -> title, mirrors parsePlanSteps)", () => {
  it("- [x] - Step one parses to title Step one", () => {
    const line = "- [x] - Step one";
    const bm = line.match(PLAN_BULLET);
    expect(bm).not.toBeNull();
    let rest = line.substring(bm![0].length);
    const box = rest.match(PLAN_STATUS_BOX);
    expect(box).not.toBeNull();
    expect(box![1]).toBe("x");
    rest = rest.substring(box![0].length).trim();
    rest = rest.replace(PLAN_TITLE_PREFIX, "").trim();
    expect(rest).toBe("Step one");
  });
});
