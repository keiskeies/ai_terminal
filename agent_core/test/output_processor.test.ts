// ASCII-only file per project emit rules; CJK literals are \uXXXX escapes
// byte-compared against the Dart oracle where stated.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));

// no-output marker (zh), escaped
const NO_OUT = "(\u65E0\u8F93\u51FA)";
// truncation notice prefix (zh), escaped
const PRE = "...(\u8F93\u51FA\u8FC7\u957F\uFF0C\u5DF2\u622A\u65AD\u524D ";
// suffix for char counts (zh), escaped
const SUF_CHARS = " \u5B57\u7B26)";
// suffix for line counts (zh), escaped
const SUF_LINES = " \u884C)";
// bare notice variant without a counter (zh), escaped
const BARE = "...(\u8F93\u51FA\u8FC7\u957F\uFF0C\u5DF2\u622A\u65AD)";
import {truncateOutput, truncateQueryOutput, MAX_QUERY_OUTPUT_CHARS} from "../src/utils/output_processor.js";

function dartTruncOracle(): string {
  return readFileSync(HERE + "../../ai_terminal/lib/utils/output_processor.dart", "utf-8").replace(/\r\n/g, NL);
}
function dartEngineOracle(): string {
  return readFileSync(HERE + "../../ai_terminal/lib/services/agent_engine.dart", "utf-8").replace(/\r\n/g, NL);
}

describe("truncateOutput (output_processor.dart 1-21, 1:1)", () => {
  it("null, undefined and empty collapse to the zh no-output marker", () => {
    expect(truncateOutput(null)).toBe(NO_OUT);
    expect(truncateOutput(undefined)).toBe(NO_OUT);
    expect(truncateOutput("")).toBe(NO_OUT);
    // byte parity: the same literal, quote-wrapped, sits in the Dart source
    expect(dartTruncOracle().includes("'" + NO_OUT + "'")).toBe(true);
  });
  it("output at or under maxChars passes verbatim", () => {
    expect(truncateOutput("abc" + NL + "def")).toBe("abc" + NL + "def");
    expect(truncateOutput("z".repeat(600))).toBe("z".repeat(600));
  });
  it("few long lines: counted char variant keeps the 600-char tail", () => {
    // 5 lines x 200 chars = 1004 chars > 600, line count 5 <= 8
    const big = ["L".repeat(200), "M".repeat(200), "N".repeat(200), "O".repeat(200), "P".repeat(200)].join(NL);
    const r = truncateOutput(big);
    expect(r.startsWith(PRE + (big.length - 600) + SUF_CHARS + NL)).toBe(true);
    expect(r.endsWith(big.slice(big.length - 600))).toBe(true);
    expect(r.length).toBe(PRE.length + String(big.length - 600).length + SUF_CHARS.length + 1 + 600);
  });
  it("many lines whose 8-line tail still busts maxChars: bare notice", () => {
    // 30 lines x 80 chars: tail 8 lines = 647 chars > 600
    const many = Array.from({length: 30}, (_, i) => ("x" + i).padEnd(80, "y")).join(NL);
    const r = truncateOutput(many);
    expect(r.startsWith(BARE + NL)).toBe(true);
    expect(r.length).toBe(BARE.length + 1 + 600);
    // last line "x29" + pad: 3 chars + 77 y -> tail ends with 77 y
    expect(r.endsWith("y".repeat(77))).toBe(true);
    expect(r.endsWith("y".repeat(78))).toBe(false);
  });
  it("many lines with a fitting tail: counted line variant", () => {
    // 20 lines x 30 chars = 619 > 600; tail 8 lines = 247 <= 600
    const many = Array.from({length: 20}, (_, i) => ("l" + i).padEnd(30, "x")).join(NL);
    const r = truncateOutput(many);
    expect(r.startsWith(PRE + (20 - 8) + SUF_LINES + NL)).toBe(true);
    expect(r.endsWith("l19" + "x".repeat(27))).toBe(true);
  });
  it("custom caps honoured (Dart named args maxLines / maxChars)", () => {
    const r = truncateOutput("aaaa" + NL + "bbbb" + NL + "cccc", 2, 5);
    // tail 2 lines is 9 chars > 5 -> bare notice + 5-char tail
    expect(r.startsWith(BARE + NL)).toBe(true);
    expect(r.endsWith("cccc")).toBe(true);
  });
});

describe("truncateQueryOutput (agent_engine.dart 2957-2965, 1:1)", () => {
  it("R8 cap constant is exactly 20000", () => {
    expect(MAX_QUERY_OUTPUT_CHARS).toBe(20000);
  });
  it("empty and null use the zh marker; exactly-20000 passes verbatim", () => {
    expect(truncateQueryOutput("")).toBe(NO_OUT);
    expect(truncateQueryOutput(null)).toBe(NO_OUT);
    expect(truncateQueryOutput("x".repeat(20000))).toBe("x".repeat(20000));
  });
  it("20001 chars trips the cap: counted notice plus tail 20000", () => {
    const s = "a" + "b".repeat(20000); // 20001
    const r = truncateQueryOutput(s);
    expect(r.startsWith(PRE + (20001 - 20000) + SUF_CHARS + NL)).toBe(true);
    expect(r.endsWith("b".repeat(20000))).toBe(true);
    expect(r.length).toBe(PRE.length + String(1).length + SUF_CHARS.length + 1 + 20000);
  });
  it("notice sentence is byte-identical to the Dart interpolation", () => {
    // Dart oracle holds: quote + notice prefix + count interpolation + suffix
    // + escaped newline + quote. Rebuild it from our escaped constants so
    // this file stays ASCII while comparing against real CJK bytes.
    const needle = "'" + PRE + "${output.length - _maxQueryOutputChars}" + SUF_CHARS + "\\n'";
    expect(dartEngineOracle().includes(needle)).toBe(true);
  });
});
