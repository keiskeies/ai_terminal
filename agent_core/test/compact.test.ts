// test/compact.test.ts - port of Dart ai_terminal/lib/services/agent_engine.dart
// 3986-4054 (_compactOnce) + 4059-4110 (_parseCompactJson) tests.

import {describe, it, expect} from "vitest";
import {compactOnce, buildCompactPrompt, parseCompactJson} from "../src/utils/compact.js";

describe("buildCompactPrompt", () => {
  it("includes the head line", () => {
    const p = buildCompactPrompt([]);
    expect(p).toContain("\u4f60\u662f\u5bf9\u8bdd\u538b\u7f29\u52a9\u624b"); // decoded: 你是对话压缩助手
  });

  it("includes rules", () => {
    const p = buildCompactPrompt([]);
    expect(p).toContain("\u538b\u7f29\u89c4\u5219"); // decoded: 压缩规则
    expect(p).toContain("ls/cat/ps/grep/find/df");
  });

  it("includes message history with command status", () => {
    const p = buildCompactPrompt([
      {index: 0, role: "user", content: "hello", command: "ls", commandSuccess: true},
      {index: 1, role: "assistant", content: "done"},
    ]);
    expect(p).toContain("[0] \u7528\u6237: hello"); // decoded: 用户
    expect(p).toContain("[1] AI: done");
    expect(p).toContain("[\u547d\u4ee4] ls \u2192 \u6210\u529f"); // decoded: 命令 ls → 成功
  });
});

describe("parseCompactJson", () => {
  it("parses a valid JSON array", () => {
    const r = parseCompactJson('[{"index":0,"summary":"a"},{"index":1,"summary":"b"}]');
    expect(r).not.toBeNull();
    expect(r!.length).toBe(2);
    expect(r![0].index).toBe(0);
    expect(r![0].summary).toBe("a");
  });

  it("returns null for empty", () => {
    expect(parseCompactJson("")).toBeNull();
  });

  it("returns null for invalid JSON", () => {
    expect(parseCompactJson("not json")).toBeNull();
  });

  it("handles markdown code fences", () => {
    const r = parseCompactJson('```json\n[{"index":0,"summary":"x"}]\n```');
    expect(r).not.toBeNull();
    expect(r!.length).toBe(1);
  });

  it("skips invalid elements", () => {
    const r = parseCompactJson('[{"index":0,"summary":"ok"},"bad",{"index":1}]');
    expect(r).not.toBeNull();
    expect(r!.length).toBe(1);
    expect(r![0].index).toBe(0);
  });
});

describe("compactOnce", () => {
  it("returns null for empty messages", async () => {
    const llm = {chatStream: async () => ""};
    const r = await compactOnce([], llm as never);
    expect(r).toBeNull();
  });

  it("returns null on LLM error", async () => {
    const llm = {chatStream: async () => { throw new Error("fail"); }};
    const r = await compactOnce([{index: 0, role: "user", content: "x"}], llm as never);
    expect(r).toBeNull();
  });

  it("returns parsed summaries on success", async () => {
    const llm = {chatStream: async () => JSON.stringify([{index: 0, summary: "ok"}])};
    const r = await compactOnce([{index: 0, role: "user", content: "x"}], llm as never);
    expect(r).not.toBeNull();
    expect(r!.length).toBe(1);
    expect(r![0].summary).toBe("ok");
  });
});