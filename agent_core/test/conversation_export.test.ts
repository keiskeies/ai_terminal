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
      {role: "user", content: "\u770b\u4e0b\u78c1\u76d8"},
      {role: "assistant", content: "\u78c1\u76d8\u5269\u4f59 40G"},
    ]);
    expect(text).toContain("## \u4f60");
    expect(text).toContain("\u770b\u4e0b\u78c1\u76d8");
    expect(text).toContain("## Agent");
    expect(text).toContain("\u78c1\u76d8\u5269\u4f59 40G");
    expect(text.indexOf("\u770b\u4e0b\u78c1\u76d8") < text.indexOf("\u78c1\u76d8\u5269\u4f59 40G")).toBe(true);
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
      goal: "\u542f\u52a8 nginx",
      conclusion: "\u6210\u529f\u542f\u52a8",
      answerBody: undefined,
      changes: [
        {command: "systemctl start nginx", canRollback: true, rollbackCommand: "systemctl stop nginx"},
        {command: "rm -rf /tmp/x", canRollback: false},
      ],
    });
    expect(text).toContain("\u76ee\u6807\uff1a\u542f\u52a8 nginx");
    expect(text).toContain("\u7ed3\u8bba\uff1a\u6210\u529f\u542f\u52a8");
    expect(text).toContain("\u53d8\u66f4\uff1a");
    expect(text).toContain("systemctl stop nginx");
    expect(text).toContain("\u65e0\u81ea\u52a8\u56de\u6eda");
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