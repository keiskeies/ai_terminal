// test/prompts_oracle.test.ts - r211: prompts.ts vs core/prompts.dart.
// Re-reads prompts.dart at run time, interprets the Dart raw blocks the way the
// Dart compiler would, and diffs EVERY exported string byte-for-byte.
import {describe, it, expect, afterEach} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {
  commandFormatRule, agentAutoRule, behaviorBoundaryRule, knowledgeSafetyRule,
  dangerousCommandExplainRule, buildDefaultSystemPrompt, buildContextPrompt,
  getSystemPrompt, saveSystemPrompt, resetSystemPrompt,
} from "../src/utils/prompts.js";

const NL = String.fromCharCode(10);
const TAB = String.fromCharCode(9);
const QUOTE = String.fromCharCode(34);
const BSL = String.fromCharCode(92);
const SQ = String.fromCharCode(39);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const DART = readFileSync(HERE + "../../ai_terminal/lib/core/prompts.dart", "utf-8")
  .replace(new RegExp(String.fromCharCode(13) + String.fromCharCode(10), "g"), NL);

function rawBlock(name: string): string {
  const marker = "const String " + name + " = " + SQ + SQ + SQ;
  const i = DART.indexOf(marker);
  if (i < 0) throw new Error("missing block " + name);
  const open = i + marker.length;
  return DART.slice(open, DART.indexOf("'''", open));
}

// Interpret Dart escapes exactly like the Dart compiler. Any escape outside
// this set throws, so the oracle cannot silently drift on new source text.
function dartValue(raw: string): string {
  let out = "";
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] !== BSL) { out += raw[i]; continue; }
    const c = raw[++i];
    if (c === "n") out += NL;
    else if (c === "t") out += TAB;
    else if (c === "r") out += String.fromCharCode(13);
    else if (c === BSL || c === "$" || c === QUOTE || c === SQ) out += c;
    else throw new Error("unhandled dart escape: " + c);
  }
  return out;
}

function expandInterps(raw: string, leaves: Record<string, string>): string {
  const re = new RegExp("\\$" + "(\\w+)", "g");
  return raw.replace(re, (_m: string, n: string) => {
    if (!(n in leaves)) throw new Error("unknown interp: " + n);
    return leaves[n];
  });
}

const LEAF_NAMES = ["commandFormatRule", "agentAutoRule", "behaviorBoundaryRule", 
  "knowledgeSafetyRule", "dangerousCommandExplainRule"];
const dartLeaves: Record<string, string> = {};
for (const n of LEAF_NAMES) dartLeaves[n] = dartValue(rawBlock(n));
const exported: Record<string, string> = {commandFormatRule, agentAutoRule,
  behaviorBoundaryRule, knowledgeSafetyRule, dangerousCommandExplainRule};

describe("oracle: rule blocks are byte-identical to Dart", () => {
  for (const n of LEAF_NAMES) {
    it(n + " matches", () => {
      expect(exported[n]).toBe(dartLeaves[n]);
      expect(exported[n].length).toBeGreaterThan(100);
    });
  }
});

describe("oracle: platform templates", () => {
  it("unix = Dart defaultSystemPrompt, interps expanded", () => {
    const want = expandInterps(dartValue(rawBlock("defaultSystemPrompt")), dartLeaves);
    expect(buildDefaultSystemPrompt()).toBe(want);
    expect(buildDefaultSystemPrompt(false)).toBe(want);
  });
  it("windows = Dart inline template, interps expanded", () => {
    const fnStart = DART.indexOf("String buildDefaultSystemPrompt");
    const open = DART.indexOf("'''", DART.indexOf("if (isWindows)", fnStart));
    const raw = DART.slice(open + 3, DART.indexOf("'''", open + 3));
    expect(buildDefaultSystemPrompt(true)).toBe(expandInterps(dartValue(raw), dartLeaves));
  });
  it("both templates keep the {context} placeholder", () => {
    expect(buildDefaultSystemPrompt()).toContain("{context}");
    expect(buildDefaultSystemPrompt(true)).toContain("{context}");
  });
  it("windows template diverges from unix (not a copy-paste port)", () => {
    expect(buildDefaultSystemPrompt(true)).not.toBe(buildDefaultSystemPrompt());
  });
});

describe("getSystemPrompt override holder", () => {
  afterEach(() => resetSystemPrompt());
  it("empty override falls back per platform (Dart isNotEmpty)", () => {
    saveSystemPrompt("");
    expect(getSystemPrompt()).toBe(buildDefaultSystemPrompt());
    expect(getSystemPrompt(true)).toBe(buildDefaultSystemPrompt(true));
  });
  it("non-empty override wins until reset", () => {
    saveSystemPrompt("custom prompt");
    expect(getSystemPrompt()).toBe("custom prompt");
    resetSystemPrompt();
    expect(getSystemPrompt()).toBe(buildDefaultSystemPrompt());
  });
});

// The Dart truncation literals, re-extracted rather than retyped.
function truncLits(): [string, string] {
    const m = DART.match(new RegExp("return '([^']*)[$]\\{text\\.length - maxChars\\}([^'$]*)[$]"));
  if (!m) throw new Error("tailTruncate literals not found");
  return [dartValue(m[1]), dartValue(m[2])];
}

describe("buildContextPrompt", () => {
  it("all six labels appear in Dart source order", () => {
    const s = buildContextPrompt({hostName: "web1", hostAddress: "10.0.0.1",
      osInfo: "Ubuntu 22.04", username: "root",
      workingDir: "/etc", shellType: "bash"});
    expect(s).not.toContain("{context}");
    const vals = ["web1", "10.0.0.1", "Ubuntu 22.04", 
      "root", "/etc", "bash"];
    // restrict to the substituted context block: the template itself also
    // contains root/etc words, so a raw indexOf over s would be polluted
    const base = buildDefaultSystemPrompt().split("{context}").join("").length;
    const block = s.slice(base);
    const at = vals.map(v => block.indexOf(v));
    for (const p of at) expect(p).toBeGreaterThan(-1);
    expect(at).toEqual([...at].sort((a, b) => a - b));
    for (const lab of ["服务器名称: ", "服务器地址: ", "操作系统: ", 
      "当前用户: ", "当前目录: ", "Shell类型: "]) {
      expect(s).toContain(lab);
      expect(DART).toContain(lab);
    }
  });
  it("recentOutput over the cap keeps the TAIL with the Dart marker", () => {
    const [pre, post] = truncLits();
    const long = "H".repeat(1500) + "TAIL";
    const s = buildContextPrompt({recentOutput: long});
    const kept = "H".repeat(996) + "TAIL";
    expect(s).toContain(pre + "504" + post + kept);
    expect(s).not.toContain("H".repeat(1000));
  });
  it("short recentOutput passes through with no truncation marker", () => {
    const [pre] = truncLits();
    const s = buildContextPrompt({recentOutput: "uptime: load 0.1"});
    expect(s).toContain("uptime: load 0.1");
    expect(s).not.toContain(pre);
  });
  it("empty options substitute an empty context block", () => {
    expect(buildContextPrompt()).toBe(buildDefaultSystemPrompt().split("{context}").join(""));
  });
  it("output section header comes from the Dart source", () => {
    const s = buildContextPrompt({recentOutput: "x"});
    const hdr = "最近终端输出:";
    expect(DART).toContain(hdr);
    expect(s).toContain(hdr);
  });
});

