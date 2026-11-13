// Oracle-replay test for the r206 Dart P1-4 LLM retry + fallback port.
// Re-reads agent_engine.dart at run time and pins the retry constants, the
// fallback-switch control flow, the byte-faithful CJK message segments and the
// _isRetryableError signal set against the Node engine. CJK uses \uXXXX
// escapes per project emit rules; they must decode to the raw Dart bytes.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const srcOf = (rel: string): string => readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL);
const DART = srcOf("../../ai_terminal/lib/services/agent_engine.dart");
const ENGINE = srcOf("../src/react/engine.ts");

// The Node port stores CJK as \uXXXX escape SEQUENCES (two source bytes per
// character pair on purpose); this decodes them back for comparison with the
// raw CJK bytes of the Dart oracle.
const unesc = (s: string): string =>
  s.replace(/\\u([0-9a-fA-F]{4})/g, (_m, h: string) => String.fromCharCode(parseInt(h, 16)));
const ENG = unesc(ENGINE);

// Constant segments of the three Dart messages, split at every interpolation
// point (agent_engine.dart 1698-1706, 1711-1712). Escapes decode to raw CJK.
const SWITCH_LOG = [
  "\u4e3b\u6a21\u578b ",                       // 主模型_ (before activeConfig.modelName)
  " \u91cd\u8bd5 ",                            // _重试_ (before $attempt)
  " \u6b21\u4ecd\u5931\u8d25\uff0c\u5207\u6362 fallback \u6a21\u578b ", // 次仍失败，切换 fallback 模型_
  ": ",                                        // before $e
];
const SWITCH_INFO = [
  "\u26a0\ufe0f \u4e3b\u6a21\u578b ",           // ⚠️ 主模型_ (before _modelConfig.modelName)
  " \u4e0d\u53ef\u7528\uff0c\u5df2\u5207\u6362\u5230\u5907\u7528\u6a21\u578b ", // 不可用，已切换到备用模型_
];
const BACKOFF_LOG = [
  "AI \u6d41\u5efa\u7acb\u5931\u8d25\uff08\u7b2c ", // AI 流建立失败（第_ (before $attempt)
  " \u6b21\uff09\uff0c",                       // _次）， (before backoff seconds)
  "s \u540e\u91cd\u8bd5: ",                    // s 后重试:_ (before $e)
];

const orderedPresence = (src: string, segs: string[]): void => {
  let cur = 0;
  for (const s of segs) {
    const i = src.indexOf(s, cur);
    expect(i, "segment present after position " + cur + ": " + JSON.stringify(s)).toBeGreaterThan(-1);
    cur = i + 1;
  }
};

describe("r206 oracle: LLM retry + fallback (Dart agent_engine.dart 1605-1715)", () => {
  it("constants: maxRetries = 3 and backoff [1s, 2s, 4s] exist in the Dart source", () => {
    expect(DART).toContain("const maxRetries = 3;");
    expect(DART).toContain("Duration(seconds: 1)");
    expect(DART).toContain("Duration(seconds: 2)");
    expect(DART).toContain("Duration(seconds: 4)");
  });

  it("Node retry loop keeps the same constants", () => {
    expect(ENG).toContain("this.maxLlmRetries ?? 3;");
    const m = ENG.match(/const backoffMs = \[([0-9,\s]*)\];/);
    expect(m, "backoffMs array").not.toBeNull();
    expect(m![1].split(",").map((x) => Number(x.trim()))).toEqual([1000, 2000, 4000]);
  });

  it("fallback switch shape: flag guard, counter reset, provider+config swap (Dart 1695-1703)", () => {
    expect(DART).toContain("if (!fallbackAttempted &&");
    expect(DART).toContain("_fallbackProvider != null &&");
    expect(DART).toContain("_fallbackConfig != null) {");
    expect(DART).toContain("fallbackAttempted = true;");
    expect(DART).toContain("attempt = 0;");
    expect(ENG).toContain("!fallbackAttempted && this.fallbackLlm && this.fallbackModelConfig");
    expect(ENG).toContain("fallbackAttempted = true;");
    expect(ENG).toContain("attempt = 0;");
    expect(ENG).toContain("activeLlm = this.fallbackLlm;");
    expect(ENG).toContain("activeConfig = this.fallbackModelConfig;");
  });

  it("exhaustion gate: attempt > maxRetries OR non-retryable (Dart 1693)", () => {
    expect(DART).toContain("if (attempt > maxRetries || !_isRetryableError(e)) {");
    expect(ENG).toContain("if (attempt > maxRetries || !this.isRetryableLlmError(e)) {");
  });

  it("CJK byte-faithfulness: switch log segments (Dart 1698-1699)", () => {
    // raw Dart source holds the same segments between the interpolations
    orderedPresence(DART, SWITCH_LOG);
    // engine source decodes to the same ordered segments
    orderedPresence(ENG, SWITCH_LOG);
  });

  it("CJK byte-faithfulness: UI switch notice segments (Dart 1705-1706)", () => {
    orderedPresence(DART, SWITCH_INFO);
    orderedPresence(ENG, SWITCH_INFO);
  });

  it("CJK byte-faithfulness: per-attempt backoff log segments (Dart 1711-1712)", () => {
    orderedPresence(DART, BACKOFF_LOG);
    orderedPresence(ENG, BACKOFF_LOG);
  });

  it("_isRetryableError signal set is ported (Dart 1560-1577)", () => {
    // Dart message fallback strings
    expect(DART).toContain("msg.contains('connection')");
    expect(DART).toContain("msg.contains('timeout')");
    expect(DART).toContain("msg.contains('reset by peer')");
    expect(DART).toContain("statusCode == 429");
    expect(DART).toContain("statusCode! >= 500");
    // Node: same substrings + same status codes
    expect(ENG).toContain("msg.includes(\"connection\")");
    expect(ENG).toContain("msg.includes(\"timeout\")");
    expect(ENG).toContain("msg.includes(\"reset by peer\")");
    expect(ENG).toContain("=== 429");
    expect(ENG).toContain(">= 500");
  });

  it("trace payload keys match Dart 1636-1642", () => {
    expect(DART).toContain("'attempt': attempt,");
    expect(DART).toContain("'retry': attempt > 1,");
    expect(DART).toContain("'fallback': fallbackAttempted,");
    expect(DART).toContain("'history_len': _conversationHistory.length,");
    expect(ENG).toContain("attempt, retry: attempt > 1, fallback: fallbackAttempted");
    expect(ENG).toContain("history_len: this.conversation.length");
  });
});
