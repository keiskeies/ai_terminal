// conversation_export.test.ts
// Mirrors Dart conversation_export_test.dart (52 lines) + operation report copy tests.

import {describe, it, expect} from "vitest";
import {
  formatConversationForExport,
  formatOperationReportCopy,
  formatAnswerForCopy,
} from "../src/utils/conversation_export.js";

describe("formatConversationForExport (Dart oracle)", () => {

  it("role-labeled alternating user/agent transcript", () => {
    const text = formatConversationForExport([
      {role: "user", content: "看下磁盘"},
      {role: "assistant", content: "磁盘剩余 40G"},
    ]);
    expect(text).toContain("## 你");
    expect(text).toContain("看下磁盘");
    expect(text).toContain("## Agent");
    expect(text).toContain("磁盘剩余 40G");
    expect(text.indexOf("看下磁盘") < text.indexOf("磁盘剩余 40G")).toBe(true);
  });

  it("empty and whitespace-only items produce no paragraph", () => {
    const text = formatConversationForExport([
      {role: "assistant", content: ""},
      {role: "user", content: "   \n  "},
    ]);
    expect(text).toBe("");
  });

  it("streamingContent fallback when content is empty", () => {
    const text = formatConversationForExport([
      {role: "user", content: "", streamingContent: "in-flight text"},
    ]);
    expect(text).toContain("in-flight text");
  });
});

describe("formatOperationReportCopy (Dart oracle)", () => {

  it("goal + conclusion + changes with rollback hints", () => {
    const text = formatOperationReportCopy({
      goal: "启动 nginx",
      conclusion: "成功启动",
      answerBody: undefined,
      changes: [
        {command: "systemctl start nginx", canRollback: true, rollbackCommand: "systemctl stop nginx"},
        {command: "rm -rf /tmp/x", canRollback: false},
      ],
    });
    expect(text).toContain("目标：启动 nginx");
    expect(text).toContain("结论：成功启动");
    expect(text).toContain("变更：");
    expect(text).toContain("systemctl stop nginx");
    expect(text).toContain("无自动回滚");
  });
});

describe("formatAnswerForCopy (Dart oracle)", () => {

  it("extracts answer from events, excludes result/report/plan", () => {
    const text = formatAnswerForCopy({
      events: [
        {id: "e1", type: "thought", timestamp: 1, text: "thinking..."},
        {id: "e2", type: "command", timestamp: 2, command: "ls -la"},
        {id: "e3", type: "result", timestamp: 3, commandId: "e2", success: true},
        {id: "e4", type: "finish", timestamp: 4, summary: "done"},
      ],
    });
    expect(text).toContain("thinking...");
    expect(text).toContain("$ ls -la");
    expect(text).toContain("done");
    // result/report should not add content
    expect(text).not.toContain("result");
  });

  it("falls back to content when no events", () => {
    const text = formatAnswerForCopy({
      events: [],
      content: "plain answer",
    });
    expect(text).toContain("plain answer");
  });
});