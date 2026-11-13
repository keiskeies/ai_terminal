// conversation_export.ts - formats conversation/report/answer text for clipboard export
//
// 1:1 port of Dart utils/conversation_export.dart (198 lines).
//
// Three export functions:
//   formatConversationForExport - role-labeled chat transcript
//   formatOperationReportCopy - goal + conclusion + answer + changes
//   formatAnswerForCopy - per-event answer with dedup

import type {AgentEvent} from "../rpc/schema.js";

/**
 * Format a list of chat items into exportable text.
 * User items get "## 你", assistant items get "## Agent".
 * Empty/whitespace-only items are skipped.
 */
export function formatConversationForExport(items: Array<{role: string; content: string; streamingContent?: string}>): string {
  const buffer: string[] = [];
  for (const item of items) {
    const content = item.content?.trim() ? item.content : (item.streamingContent ?? "");
    if (content.trim().length === 0) continue;
    buffer.push(item.role === "user" ? "## 你" : "## Agent");
    buffer.push(content.trim());
    buffer.push("");
  }
  return buffer.join("\n").replace(/[\n\s]+$/g, "");
}

/**
 * Format an operation report for clipboard copy.
 * Includes goal, conclusion, answer body, and change list with rollback hints.
 */
export function formatOperationReportCopy(report: {
  goal: string;
  conclusion: string;
  answerBody?: string;
  changes: Array<{command: string; canRollback: boolean; localRestore?: boolean; rollbackCommand?: string}>;
}): string {
  const buffer: string[] = [];
  if (report.goal.trim()) buffer.push("目标：" + report.goal.trim());
  buffer.push("结论：" + report.conclusion.trim());
  const answerBody = report.answerBody?.trim();
  if (answerBody && answerBody.length > 0 && !sameText(answerBody, report.conclusion)) {
    buffer.push("");
    buffer.push(answerBody);
  }
  if (report.changes.length > 0) {
    buffer.push("变更：");
    for (const change of report.changes) {
      const rollback = change.canRollback
        ? (change.localRestore && !(change.rollbackCommand ?? "").trim()
            ? "（可回滚：从备份/回收区移回）"
            : "（可回滚：" + change.rollbackCommand + "）")
        : "（无自动回滚）";
      buffer.push("- " + change.command + rollback);
    }
  }
  return buffer.join("\n").replace(/[\n\s]+$/g, "");
}

/**
 * Format a single Agent answer for the "copy answer" button.
 * Command output is excluded (it is evidence on screen, not part of the answer).
 * Dedup: lines already emitted via the operation report are not repeated.
 */
export function formatAnswerForCopy(opts: {
  events: AgentEvent[];
  content?: string;
  streamingContent?: string;
}): string {
  const {events, content = "", streamingContent = ""} = opts;
  const buffer: string[] = [];
  const emitted = new Set<string>();

  const hasStructuredCards = events.some((e) => e.type === "command" || e.type === "ask");

  function emit(raw: string | undefined | null): void {
    const source = (raw ?? "").replace(/\r\n/g, "\n");
    if (source.trim().length === 0) return;
    const kept: string[] = [];
    const keys: string[] = [];
    let contentLines = 0;
    let dropped = 0;
    for (const line of source.split("\n")) {
      if (line.trim().length === 0) { kept.push(""); continue; }
      contentLines++;
      if (hasStructuredCards && REACT_CONTROL_LINE_RE.test(line)) { dropped++; continue; }
      const value = line.replace(REACT_LABEL_RE, "").replace(/[\t ]+$/g, "");
      const key = dedupKey(value);
      if (value.length === 0) { dropped++; continue; }
      if (key.length > 12 && emitted.has(key)) { dropped++; continue; }
      kept.push(value);
      if (key.length > 12) keys.push(key);
    }
    if (contentLines > 0 && dropped * 2 >= contentLines) return;
    const text = kept.join("\n").trim().replace(/\n{3,}/g, "\n\n");
    if (text.length === 0) return;
    keys.forEach((k) => emitted.add(k));
    buffer.push(text, "");
  }

  // Emit operation report copy first (if present)
  let report: AgentEvent["operationReport"] | undefined;
  for (const event of events) {
    if (event.type === "report" && (event as any).operationReport) {
      report = (event as any).operationReport;
    }
  }
  if (report) {
    emit(formatOperationReportCopy({
      goal: (report as any).goal ?? "",
      conclusion: (report as any).conclusion ?? "",
      answerBody: (report as any).answerBody,
      changes: (report as any).changes ?? [],
    }));
  }

  // Skip "you chose X" notes when the ask event already has a chosenAnswer
  const hasRecordedChoice = events.some((e) => e.type === "ask" && ((e as any).chosenAnswer ?? "").trim().length > 0);

  for (const event of events) {
    switch (event.type) {
      case "thought":
      case "text":
        emit(event.text);
        break;
      case "info": {
        const text = (event.text ?? "").trim();
        const isChoiceNote = text.includes("你选择了") || text.includes("You chose");
        if (isChoiceNote && hasRecordedChoice) break;
        emit(event.text);
        break;
      }
      case "command": {
        const command = (event.command ?? "").trim();
        if (command.length === 0) break;
        const description = (event.description ?? "").trim();
        if (description.length > 0) emit("> " + description);
        const tool = event.toolName;
        if (tool === undefined || tool === "exec_command") {
          emit("$ " + command);
        } else {
          emit("› " + (command.startsWith(tool) ? command : tool + " " + command));
        }
        break;
      }
      case "ask": {
        const options = event.options ?? [];
        const parts: string[] = [];
        if ((event.question ?? "").trim()) parts.push((event.question as string).trim());
        if (options.length > 0) parts.push(options.map((o) => "- " + o).join("\n"));
        const chosen = (event as any).chosenAnswer;
        if ((chosen ?? "").trim()) parts.push("> " + chosen.trim());
        emit(parts.join("\n"));
        break;
      }
      case "finish":
        emit(event.summary);
        break;
      case "result":
      case "report":
      case "plan":
        break;
    }
  }

  // Fallback: no events → use persisted content or streaming content
  if (buffer.join("").trim().length === 0) {
    emit(content.trim() ? content : streamingContent);
  }
  return buffer.join("\n").replace(/[\n\s]+$/g, "");
}

// ReAct protocol control lines: duplicate when structured cards exist
const REACT_CONTROL_LINE_RE = /^\s*(?:动作|说明|命令|选项|工具)\s*[:：]/;

// Paragraph labels: strip to match body text with prior output
const REACT_LABEL_RE = /^\s*(?:思考|回答)\s*[:：]\s*/;

function dedupKey(text: string): string {
  return text
    .replace(/^(目标|结论|变更)\s*[:：]\s*/, "")
    .replace(/^#{1,6}\s*/gm, "")
    .replace(/^[-*]\s*/gm, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function sameText(a: string, b: string): boolean {
  return dedupKey(a) === dedupKey(b);
}