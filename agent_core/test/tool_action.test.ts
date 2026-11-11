// Port of the Dart e2e oracle test/react_parse_e2e_test.dart (E2E-1/2/3/7/13/14)
// plus unit coverage for ToolCallAccumulator / argument repair / toReActText.
// Dart-side line anchors: agent_engine.dart 2206-2261,
// tool_call_accumulator.dart 17-147. ASCII-only file: every CJK ReAct keyword is
// a unicode escape; the escape decodes to the same code unit the Dart source
// spells natively, so keyword characters match the Dart literals 1:1.
import {describe, it, expect} from "vitest";
import {ToolCallAccumulator, parseToolAction} from "../src/react/tool_action.js";
import type {ToolCall} from "../src/react/tool_action.js";

const ACTION = "\u52a8\u4f5c";            // action keyword (dong-zuo)
const ACTION_FW = "\u52a8\u4f5c\uff1a";   // action keyword + fullwidth colon
const TOOL_KW = "\u5de5\u5177";            // tool keyword (gong-ju)
const ARGS_KW = "\u53c2\u6570";            // args keyword (can-shu)
const THOUGHT_KW = "\u601d\u8003";         // thought keyword (si-kao)
const FULLWIDTH = "\uff1a";
const CJK_PROBE = "\u4e2d\u6587\u6d4b\u8bd5"; // zhong-wen-ce-shi
const CJK_END = "\u7ed3\u675f";             // jie-shu

function findActionLine(lines: readonly string[]): number {
  return lines.findIndex((l) => l.trim().startsWith(ACTION + ":"));
}

describe("parseToolAction - Dart e2e oracle ports", () => {
  it("e2e-1 port: multi-line args, bool/int/list coercion", () => {
    const response =
      THOUGHT_KW + ": need to upload dist to servers\n" +
      ACTION + ": tool\n" +
      TOOL_KW + ": sftp_upload\n" +
      ARGS_KW + ":\n" +
      "  local: /Users/x/proj/dist\n" +
      "  remote: /var/www/myapp\n" +
      "  recursive: true\n" +
      "  exclude: node_modules,.git";
    const lines = response.split("\n");
    const [name, args] = parseToolAction(lines, findActionLine(lines) + 1);
    expect(name).toBe("sftp_upload");
    expect(args).not.toBeNull();
    expect(args!["local"]).toBe("/Users/x/proj/dist");
    expect(args!["remote"]).toBe("/var/www/myapp");
    expect(args!["recursive"]).toBe(true);
    // Dart Bug 2 regression: comma-bearing exclude becomes a real list, not "[a, b]"
    expect(Array.isArray(args!["exclude"])).toBe(true);
    expect(args!["exclude"]).toEqual(["node_modules", ".git"]);
  });

  it("e2e-2 port: fc deltas to react text to parsed args", () => {
    const acc = new ToolCallAccumulator();
    acc.addDelta([
      {
        index: 0,
        id: "call_1",
        function: {
          name: "exec_batch",
          arguments: "{\"hostIds\":\"web1,web2,db1\",\"command\":\"uptime\",\"timeout\":30}",
        },
      },
    ]);
    const calls = acc.finalize();
    const reactText = ToolCallAccumulator.toReActText(calls);
    const lines = reactText.split("\n");
    const idx = lines.findIndex((l) => l.trim() === ACTION + ": tool");
    expect(idx).toBeGreaterThanOrEqual(0);
    const [name, args] = parseToolAction(lines, idx + 1);
    expect(name).toBe("exec_batch");
    expect(args).not.toBeNull();
    expect(Array.isArray(args!["hostIds"])).toBe(true);
    expect(args!["hostIds"]).toEqual(["web1", "web2", "db1"]);
    expect(args!["command"]).toBe("uptime");
    expect(args!["timeout"]).toBe(30);
  });

  it("e2e-3 port: thought prefix concat keeps action line standalone", () => {
    const acc = new ToolCallAccumulator();
    acc.addDelta([
      {
        index: 0,
        id: "call_1",
        function: {
          name: "sftp_upload",
          arguments: "{\"local\":\"/path/to/dist\",\"remote\":\"/var/www\"}",
        },
      },
    ]);
    const reactText = ToolCallAccumulator.toReActText(acc.finalize());
    const fullResponse = "thought text here ok" + reactText; // Dart: fullResponse += chunk
    const lines = fullResponse.split("\n");
    const idx = lines.findIndex((l) => l.trim().startsWith(ACTION + ":"));
    expect(idx).toBeGreaterThanOrEqual(0);
    const [name, args] = parseToolAction(lines, idx + 1);
    expect(name).toBe("sftp_upload");
    expect(args!["local"]).toBe("/path/to/dist");
    expect(args!["remote"]).toBe("/var/www");
  });

  it("e2e-7 port: single hostId stays string", () => {
    const response =
      ACTION + ": tool\n" +
      TOOL_KW + ": exec_on\n" +
      ARGS_KW + ":\n" +
      "  hostId: web1\n" +
      "  command: uptime";
    const lines = response.split("\n");
    const [name, args] = parseToolAction(lines, findActionLine(lines) + 1);
    expect(name).toBe("exec_on");
    expect(args).not.toBeNull();
    expect(typeof args!["hostId"]).toBe("string");
    expect(args!["hostId"]).toBe("web1");
  });

  it("e2e-13 port: cross-line content block yields null args, name kept", () => {
    const response =
      ACTION + ": tool\n" +
      TOOL_KW + ": file_write\n" +
      ARGS_KW + ":\n" +
      "  path: /tmp/ai_terminal_llm_cn.txt\n" +
      "  content: " + CJK_PROBE + "\n" +
      "    emoji A-B\n" +
      "    " + CJK_END + "\n" +
      "  mode: write";
    const lines = response.split("\n");
    let warned = 0;
    const [name, args] = parseToolAction(lines, findActionLine(lines) + 1, () => {
      warned++;
    });
    expect(name).toBe("file_write");
    expect(args).toBeNull();
    expect(warned).toBe(1); // Dart agentLogger.warn path maps to onParseFail
  });

  it("e2e-14 port: single-line literal backslash-n content parses", () => {
    const response =
      ACTION + ": tool\n" +
      TOOL_KW + ": file_write\n" +
      ARGS_KW + ":\n" +
      "  path: /tmp/ai_terminal_llm_cn.txt\n" +
      "  content: " + CJK_PROBE + "\\nemoji X-Y\\n" + CJK_END + "\n" +
      "  mode: write";
    const lines = response.split("\n");
    const [, args] = parseToolAction(lines, findActionLine(lines) + 1);
    expect(args).not.toBeNull();
    const content = args!["content"];
    expect(content).not.toBe(CJK_PROBE);
    expect(content).toBe(CJK_PROBE + "\\nemoji X-Y\\n" + CJK_END);
  });
});

describe("parseToolAction - keyword and colon behaviour", () => {
  it("fullwidth colon variants parse name and args", () => {
    const response =
      ACTION_FW + "tool\n" +
      TOOL_KW + FULLWIDTH + "sftp_download\n" +
      ARGS_KW + FULLWIDTH + "remote: /var/log/syslog";
    const lines = response.split("\n");
    const idx = lines.findIndex((l) => l.trim().startsWith(ACTION_FW));
    const [name, args] = parseToolAction(lines, idx + 1);
    expect(name).toBe("sftp_download");
    expect(args).not.toBeNull();
    expect(args!["remote"]).toBe("/var/log/syslog");
  });

  it("inline first arg on the args keyword line is collected too", () => {
    const response = TOOL_KW + ": run_backup\n" + ARGS_KW + ": target: /data";
    const [name, args] = parseToolAction(response.split("\n"), 0);
    expect(name).toBe("run_backup");
    expect(args).not.toBeNull();
    expect(args!["target"]).toBe("/data");
  });

  it("bare tool keyword with empty value yields empty-string name, not null", () => {
    const [name] = parseToolAction([TOOL_KW + ":"], 0);
    expect(name).toBe(""); // Dart slice(sep+1).trim() of an empty remainder
  });

  it("break keywords stop the scan; tool keyword itself never breaks", () => {
    // Dart Bug 1 guard: the tool keyword MUST NOT be in the break list - if it
    // were, the name branch below it would be dead code (the historical bug).
    const blocked = [THOUGHT_KW + ": something", TOOL_KW + ": never_read"].join("\n");
    const [name1] = parseToolAction(blocked.split("\n"), 0);
    expect(name1).toBeNull();
    const afterTool =
      [TOOL_KW + ": probe_tool", THOUGHT_KW + ": stop", ARGS_KW + ":", "  x: 1"].join("\n");
    const [name2, args2] = parseToolAction(afterTool.split("\n"), 0);
    expect(name2).toBe("probe_tool");
    expect(args2).toBeNull(); // thought keyword cut the scan before the args block
  });

  it("unknown keyword line ends the scan; blank lines are skipped", () => {
    const response =
      "\n" +
      TOOL_KW + ": probe_two\n" +
      "random prose, not a keyword line\n" +
      ARGS_KW + ":\n" +
      "  x: 1";
    const [name, args] = parseToolAction(response.split("\n"), 0);
    expect(name).toBe("probe_two");
    expect(args).toBeNull(); // prose line breaks before args are ever seen
  });

  it("startIndex past the end yields nulls", () => {
    const [name, args] = parseToolAction([], 0);
    expect(name).toBeNull();
    expect(args).toBeNull();
  });

  it("indented collection stops at the first non-indented non-blank line", () => {
    const lines =
      [ARGS_KW + ":", "  a: 1", "", "\tb: 2", "non-indented tail", "  c: 3"];
    const [, args] = parseToolAction(lines, 0);
    expect(args).not.toBeNull();
    expect(args!["a"]).toBe(1);
    expect(args!["b"]).toBe(2);
    expect(args!["c"]).toBeUndefined(); // never reached: scan broke at the tail line
  });
});

describe("ToolCallAccumulator", () => {
  it("accumulates argument fragments per index, finalizes in index order", () => {
    const acc = new ToolCallAccumulator();
    expect(acc.hasPendingCalls).toBe(false);
    acc.addDelta([{index: 1, function: {name: "second", arguments: "{\"a\":"}}]);
    expect(acc.hasPendingCalls).toBe(true);
    acc.addDelta([{index: 1, function: {arguments: "1}"}}]);
    acc.addDelta([{index: 0, id: "call_a", function: {name: "first", arguments: "{}"}}]);
    const calls = acc.finalize();
    expect(calls.map((c) => c.name)).toEqual(["first", "second"]);
    expect(calls[0].id).toBe("call_a");
    expect(calls[1].id).toBe("call_1"); // Dart fallback id: call_ plus index
    expect(calls[1].arguments).toBe("{\"a\":1}");
  });

  it("finalize drops nameless partials and clears state against double delivery", () => {
    const acc = new ToolCallAccumulator();
    acc.addDelta([
      {index: 0, arguments: "dropped-no-name"} as unknown as Record<string, unknown>,
      {index: 1, function: {name: "kept", arguments: "{}"}},
    ]);
    const first = acc.finalize();
    expect(first.map((c) => c.name)).toEqual(["kept"]);
    // Dart fix: finish_reason=tool_calls and DONE both fire finalize - the
    // second call must deliver nothing or the ReAct text would double up.
    expect(acc.finalize()).toEqual([]);
    expect(acc.hasPendingCalls).toBe(false);
  });

  it("addDelta skips null, non-object items and deltas without an integer index", () => {
    const acc = new ToolCallAccumulator();
    acc.addDelta(null);
    acc.addDelta(undefined);
    acc.addDelta([
      "junk",
      {function: {name: "no-index"}},
      {index: "3", function: {name: "string-index"}},
      {index: 1.5, function: {name: "float-index"}},
    ]);
    expect(acc.hasPendingCalls).toBe(false);
  });

  it("empty id and empty name chunks do not clobber earlier values", () => {
    const acc = new ToolCallAccumulator();
    acc.addDelta([{index: 0, id: "x1", function: {name: "n1", arguments: "{}"}}]);
    acc.addDelta([{index: 0, id: "", function: {name: "", arguments: ""}}]);
    const calls = acc.finalize();
    expect(calls[0].id).toBe("x1");
    expect(calls[0].name).toBe("n1");
  });

  it("argument repair closes lost braces, discards unfixable attempts", () => {
    const once = (args: string): string => {
      const acc = new ToolCallAccumulator();
      acc.addDelta([{index: 0, function: {name: "t", arguments: args}}]);
      return acc.finalize()[0].arguments;
    };
    expect(once("{\"a\":1")).toBe("{\"a\":1}"); // trailing brace was lost: repaired
    expect(once("")).toBe("{}"); // empty args: Dart returns the empty object
    expect(once("{bad")).toBe("{bad"); // repair closes but JSON still invalid: keep original
    expect(once("{\"a\":1}}")).toBe("{\"a\":1}}"); // more closers than openers: untouched
  });
});

describe("ToolCallAccumulator.toReActText", () => {
  const mk = (name: string, args: string): ToolCall => ({id: "c", name, arguments: args});

  it("leading newline survives so a glued thought chunk cannot eat the action line", () => {
    const text = ToolCallAccumulator.toReActText([mk("t1", "{}")]);
    expect(text.startsWith("\n")).toBe(true); // Dart buffer starts with writeln; only trimRight
    const joined = "prefix text" + text; // Dart _callAI: fullResponse += chunk
    expect(joined.split("\n").some((l) => l.trim() === ACTION + ": tool")).toBe(true);
  });

  it("multiple calls separated by a blank line, one block each", () => {
    const text = ToolCallAccumulator.toReActText([mk("a1", "{}"), mk("a2", "{}")]);
    const actionLines = text.split("\n").filter((l) => l.trim() === ACTION + ": tool");
    expect(actionLines.length).toBe(2);
  });

  it("empty or brace-empty arguments emit the args keyword with nothing under it", () => {
    const text = ToolCallAccumulator.toReActText([mk("a1", ""), mk("a2", "{}")]);
    const argLines = text.split("\n").filter((l) => l.trim().startsWith(ARGS_KW + ":"));
    expect(argLines.length).toBe(2);
    for (const l of argLines) expect(l.trim()).toBe(ARGS_KW + ":");
  });

  it("invalid JSON arguments degrade to an empty args block, no raw passthrough", () => {
    const text = ToolCallAccumulator.toReActText([mk("a1", "{not json")]);
    expect(text.includes("{not json")).toBe(false);
    expect(text.includes(ARGS_KW + ":")).toBe(true);
  });

  it("json values render in Dart toString shape (list join, nested map, bool, null)", () => {
    const text = ToolCallAccumulator.toReActText([
      mk("a1", JSON.stringify({nums: [1, 2], b: true, nested: {k: 9}, z: null, s: "hi"})),
    ]);
    expect(text).toContain("  nums: 1,2");
    expect(text).toContain("  b: true");
    expect(text).toContain("  nested: {k: 9}"); // Dart Map.toString shape, not JSON
    expect(text).toContain("  z: null");
    expect(text).toContain("  s: hi");
  });
});
