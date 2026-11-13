// test/terminal_text_actions.test.ts - r209 port of terminal_text_actions.dart.
// Unit pins for each pure judge + oracle block re-reading the Dart file:
// the regex literals, the zh UiText branches and the path-priority rules.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {
  detectUrl, detectPath, looksLikeError, isMultiLine, looksLikeCommand,
  stripPromptPrefix, agentExplainPrompt, agentErrorPrompt, directoryOfPath,
} from "../src/utils/terminal_text_actions.js";

const NL = String.fromCharCode(10);
const BT = String.fromCharCode(96);
const FENCE_OPEN = NL + BT.repeat(3) + NL;
const FENCE_CLOSE = NL + BT.repeat(3);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const DART = readFileSync(HERE + "../../ai_terminal/lib/utils/terminal_text_actions.dart", "utf-8").replace(/\r\n/g, NL);

describe("detectUrl", () => {
  it("finds the first http(s) url and trims trailing punctuation", () => {
    expect(detectUrl("see https://example.com/a, ok")).toBe("https://example.com/a");
    expect(detectUrl("no url here")).toBeNull();
  });
  it("bare scheme prefix with no body is not a url", () => {
    expect(detectUrl("http://")).toBeNull();
  });
});

describe("detectPath", () => {
  it("windows drive path wins over posix", () => {
    expect(detectPath("copy C:\\deploy\\app.jar to /srv/app.jar")).toBe("C:\\deploy\\app.jar");
  });
  it("posix absolute, tilde, dot-dot forms", () => {
    expect(detectPath("tail /var/log/syslog")).toBe("/var/log/syslog");
    expect(detectPath("cd ~/projects")).toBe("~/projects");
    expect(detectPath("ls ../src")).toBe("../src");
  });
  it("word-adjacent slashes are not paths (the negative lookbehind)", () => {
    expect(detectPath("ratio 3/4 ok")).toBeNull();
  });
});

describe("looksLikeError", () => {
  it("matches EN and zh failure words case-insensitively", () => {
    expect(looksLikeError("FATAL: connection denied")).toBe(true);
    // 'refused' is NOT in the Dart alternation - loose-by-design means exact-list
    expect(looksLikeError("Connection REFUSED by host")).toBe(false);
    expect(looksLikeError("\u8FDE\u63A5\u8D85\u65F6")).toBe(true);
  });
  it("file names containing error do NOT count (URLs/paths stripped first)", () => {
    expect(looksLikeError("/var/log/nginx/error.log")).toBe(false);
    expect(looksLikeError("opened https://site/error.html")).toBe(false);
  });
  it("plain output is not an error", () => {
    expect(looksLikeError("total 42")).toBe(false);
  });
});

describe("isMultiLine", () => {
  it("LF, CR and U+2028 all count as multi-line", () => {
    expect(isMultiLine("a" + NL + "b")).toBe(true);
    expect(isMultiLine("a\rb")).toBe(true);
    expect(isMultiLine("a\u2028b")).toBe(true);
    expect(isMultiLine("single")).toBe(false);
  });
});

describe("looksLikeCommand", () => {
  it("strips prompt prefixes then checks the first token shape", () => {
    expect(looksLikeCommand("$ systemctl restart nginx")).toBe(true);
    expect(looksLikeCommand("PS C:\\> dir")).toBe(true);
    expect(looksLikeCommand("user@host:~$ ls -l")).toBe(true);
  });
  it("zh prose excluded; plain ASCII words pass (Dart charset is broader than the comment)", () => {
    expect(looksLikeCommand("\u5E2E\u6211\u770B\u770B \u65E5\u5FD7")).toBe(false);
    // Dart charset [A-Za-z0-9_./~\\:$-]* matches plain lowercase words: ASCII
    // prose like 'the server is down' is NOT excluded - the zh comment overstates it.
    expect(looksLikeCommand("the server is down")).toBe(true);
    expect(looksLikeCommand("Wait, check the logs")).toBe(false);
  });
  it("error-looking single lines are never commands", () => {
    expect(looksLikeCommand("command not found")).toBe(false);
  });
  it("multi-line and over-long first tokens are rejected", () => {
    expect(looksLikeCommand("a" + NL + "b")).toBe(false);
    expect(looksLikeCommand("x".repeat(201))).toBe(false);
  });
});

describe("helpers", () => {
  it("stripPromptPrefix removes prefix and trailing whitespace", () => {
    expect(stripPromptPrefix("$ ls -la   ")).toBe("ls -la");
  });
  it("directoryOfPath arithmetic", () => {
    expect(directoryOfPath("/a/b/c.log")).toBe("/a/b");
    expect(directoryOfPath("~/x")).toBe("~");
    expect(directoryOfPath("C:\\a\\b")).toBe("C:/a");
    expect(directoryOfPath("/x")).toBe("/");
    expect(directoryOfPath("bare")).toBe(".");
  });
  it("agent prompts embed the trimmed selection inside a fence", () => {
    expect(agentExplainPrompt("  some output  ").endsWith(FENCE_OPEN + "some output" + FENCE_CLOSE)).toBe(true);
    expect(agentErrorPrompt(" boom ").endsWith(FENCE_OPEN + "boom" + FENCE_CLOSE)).toBe(true);
  });
});


// Exact zh/error-term bytes, extracted from the Dart oracle when this test was
// written. If the Dart literal drifts, the DART.toContain pins below fail, and
// if the Node port drifts, the startsWith pins fail - faithful in both.
const ZH_EXPLAIN = "解释下面这段终端输出，指出关键信息、风险和下一步建议：";
const ZH_ERROR = "这段终端报错是什么意思？给出原因、影响和修复步骤：";
const ERROR_TERMS = "错误|失败|异常|拒绝|超时|不存在";

describe("oracle: terminal_text_actions.dart", () => {
  it("url scheme literal is pinned verbatim", () => {
    expect(DART).toContain("RegExp('https?://')");
  });
  it("zh UiText branches are byte-faithful across the port", () => {
    expect(DART).toContain(ZH_EXPLAIN);
    expect(DART).toContain(ZH_ERROR);
    expect(agentExplainPrompt("S").startsWith(ZH_EXPLAIN)).toBe(true);
    expect(agentErrorPrompt("L").startsWith(ZH_ERROR)).toBe(true);
  });
  it("six zh error terms in the failure alternation", () => {
    expect(DART).toContain(ERROR_TERMS);
  });
  it("prompt-prefix structure (PS / user@host forms) preserved", () => {
    expect(DART).toContain("PS [^>]*>");
    expect(DART).toContain("@[A-Za-z0-9_.-]+");
  });
  it("looksLikeCommand arithmetic pins (200 cap, split, token charset)", () => {
    expect(DART).toContain("if (firstToken.length > 200) return false;");
    expect(DART).toContain("final firstToken = stripped.split(RegExp(r'\\s+')).first;");
    expect(DART).toContain("A-Za-z0-9_./~");
  });
  it("multi-line detection includes LF, CR and U+2028", () => {
    expect(DART).toContain("text.contains('\\n') || text.contains('\\r') || text.contains('\\u2028');");
  });
  it("directoryOfPath arithmetic matches the Dart source", () => {
    expect(DART).toContain("if (idx > 0) return normalized.substring(0, idx);");
    expect(DART).toContain("if (idx == 0) return '/';");
  });
});

