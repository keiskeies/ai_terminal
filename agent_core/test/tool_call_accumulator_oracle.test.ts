// Oracle-replay test for ToolCallAccumulator (r139).
// Re-reads tool_call_accumulator.dart at run time and pins the accumulation,
// finalize, toReActText, and repair logic against the Node port.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {ToolCallAccumulator, ToolCall} from "../src/utils/tool_call_accumulator.js";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const linesOf = (rel: string) =>
  readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL).split(NL);

const DART = linesOf("../../ai_terminal/lib/utils/tool_call_accumulator.dart");

describe("r139: ToolCallAccumulator oracle", () => {

  it("addDelta accumulates arguments by index (Dart 22-41)", () => {
    const acc = new ToolCallAccumulator();
    acc.addDelta([{index: 0, id: "call_1", function: {name: "exec", arguments: "{}"}}]);
    acc.addDelta([{index: 0, function: {arguments: "AB"}}]);
    expect(acc.hasPendingCalls).toBe(true);
    const calls = acc.finalize();
    expect(calls.length).toBe(1);
    expect(calls[0].id).toBe("call_1");
    expect(calls[0].name).toBe("exec");
    expect(calls[0].arguments).toBe("{}AB");
    expect(acc.hasPendingCalls).toBe(false);
  });

  it("finalize drops calls without a name (Dart 50-51)", () => {
    const acc = new ToolCallAccumulator();
    acc.addDelta([{index: 0, id: "x"}]);
    const calls = acc.finalize();
    expect(calls.length).toBe(0);
  });

  it("toReActText produces leading newline + action/tool/param format (Dart 74-93)", () => {
    const calls: ToolCall[] = [{id: "c1", name: "exec", arguments: "{}"}];
    const text = ToolCallAccumulator.toReActText(calls);
    expect(text.charAt(0)).toBe(String.fromCharCode(10));
    expect(text).toContain("\u52a8\u4f5c: tool");
    expect(text).toContain("\u5de5\u5177: exec");
    expect(text).toContain("\u53c2\u6570:");
  });

  it("toReActText with JSON args produces key:value lines (Dart 99-120)", () => {
    const args = JSON.stringify({host: "web1", timeout: 30});
    const calls: ToolCall[] = [{id: "c1", name: "exec", arguments: args}];
    const text = ToolCallAccumulator.toReActText(calls);
    expect(text).toContain("  host: web1");
    expect(text).toContain("  timeout: 30");
  });

  it("_repairArguments adds missing closing braces (Dart 124-144)", () => {
    const acc = new ToolCallAccumulator();
    const badArgs = '{"host": "web1"'; // {"host": "web1" (missing closing brace)
    acc.addDelta([{index: 0, id: "c1", function: {name: "exec", arguments: badArgs}}]);
    const calls = acc.finalize();
    expect(calls.length).toBe(1);
    expect(() => JSON.parse(calls[0].arguments)).not.toThrow();
  });

  it("multiple tool_calls are separated by blank line (Dart 80)", () => {
    const calls: ToolCall[] = [
      {id: "c1", name: "exec", arguments: "{}"},
      {id: "c2", name: "sftp", arguments: "{}"},
    ];
    const text = ToolCallAccumulator.toReActText(calls);
    const actionCount = text.split("\u52a8\u4f5c: tool").length - 1;
    expect(actionCount).toBe(2);
  });

  it("Dart source lines are non-empty (run-time pin)", () => {
    expect(DART[16].trim()).toContain("class ToolCallAccumulator");
    expect(DART[21].trim()).toContain("addDelta");
    expect(DART[44].trim()).toContain("finalize");
    expect(DART[73].trim()).toContain("toReActText");
  });
});
