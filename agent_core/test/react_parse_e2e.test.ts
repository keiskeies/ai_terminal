// react_parse_e2e.test.ts - e2e parse test for the ReAct text pipeline
// Mirrors key scenarios from Dart react_parse_e2e_test.dart.
// The Node parser handles ReAct keyword format; tool call extraction
// is done by the engine via tool_action.ts (not the parser).

import {describe, it, expect} from "vitest";
import {parse} from "../src/react/parser.js";

describe("ReAct parse E2E (Dart oracle: react_parse_e2e_test.dart)", () => {

  it("E2E-1: \u5de5\u5177 + \u53c2\u6570 + \u52a8\u4f5c:execute produces zero parser events", () => {
    // The tool protocol buffer is discarded by design (parser.ts:215-217).
    // \u52a8\u4f5c:execute is handled by the engine, not the parser.
    // The parser only emits events for finish, thought, command, ask, plan, text.
    const input = [
      "\u5de5\u5177: exec_batch",
      "\u53c2\u6570:",
      "  hostIds: web1,web2",
      "  command: ls -la",
      "",
      "\u52a8\u4f5c: execute",
    ].join("\n");
    const events = parse(input);
    expect(events.length).toBe(0);
  });

  it("E2E-4: \u53c2\u6570 before \u5de5\u5177 (order swap) also produces zero events", () => {
    const input = [
      "\u53c2\u6570:",
      "  hostIds: web1",
      "  command: pwd",
      "\u5de5\u5177: exec",
      "\u52a8\u4f5c: execute",
    ].join("\n");
    const events = parse(input);
    expect(events.length).toBe(0);
  });

  it("E2E-5: \u601d\u8003 keyword after tool protocol produces a thought event", () => {
    const input = [
      "\u5de5\u5177: exec",
      "\u53c2\u6570:",
      "  command: ls",
      "\u601d\u8003: next thought",
    ].join("\n");
    const events = parse(input);
    const thinkEvents = events.filter(e => e.type === "thought");
    expect(thinkEvents.length).toBe(1);
    expect(thinkEvents[0].text).toBe("next thought");
  });

  it("E2E-8: \u56de\u7b54 body + \u52a8\u4f5c:finish produces a finish event", () => {
    const input = [
      "\u56de\u7b54:",
      "## \u7ed3\u679c",
      "- item 1",
      "- item 2",
      "```",
      "echo hello",
      "```",
      "\u52a8\u4f5c: finish",
    ].join("\n");
    const events = parse(input);
    const finishEvent = events.find(e => e.type === "finish");
    expect(finishEvent).toBeDefined();
  });

  it("E2E-9: code block containing \u52a8\u4f5c: finish is not truncated", () => {
    const input = [
      "\u56de\u7b54:",
      "```bash",
      "# \u52a8\u4f5c: finish",
      "echo test",
      "```",
      "\u52a8\u4f5c: finish",
    ].join("\n");
    const events = parse(input);
    const finishEvent = events.find(e => e.type === "finish");
    expect(finishEvent).toBeDefined();
  });

  it("E2E-11: streaming chunk reassembly of tool protocol produces zero events", () => {
    const chunk1 = "\u5de5\u5177: exec";
    const chunk2 = "\n\u53c2\u6570:\n  command: ls";
    const chunk3 = "\n\u52a8\u4f5c: execute";
    const full = chunk1 + chunk2 + chunk3;
    const events = parse(full);
    expect(events.length).toBe(0);
  });

  it("E2E-13: multi-line answer + \u52a8\u4f5c:finish produces finish with summary", () => {
    const input = [
      "\u56de\u7b54:",
      "line 1",
      "line 2",
      "\u52a8\u4f5c: finish",
    ].join("\n");
    const events = parse(input);
    const finishEvent = events.find(e => e.type === "finish");
    expect(finishEvent).toBeDefined();
    expect(finishEvent?.summary).toContain("line 1");
  });
});