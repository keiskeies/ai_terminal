// react/parser.ts - 1:1 port of react_stream_parser.dart
// stableId via stable_hash (byte-identical to Dart).

import {AgentEvent, PlanStep, PlanStepStatus} from "../rpc/schema.js";
import {fnv1a64DartCompat} from "../utils/stable_hash.js";
import {
  XML_FENCED, XML_BARE, RESIDUAL_SEP,
  CODE_FENCE_PREFIX, CODE_FENCE_SUFFIX,
  PLAN_BULLET, PLAN_STATUS_BOX, PLAN_TITLE_PREFIX,
} from "./regex.js";

// Keyword list (must match Dart _keywords exactly, same order)
const KEYWORDS: string[] = [
  "思考:", "思考：",
  "计划:", "计划：",
  "说明:", "说明：",
  "动作:", "动作：",
  "命令:", "命令：",
  "选项:", "选项：",
  "工具:", "工具：",
  "参数:", "参数：",
  "回答:", "回答：",
];

// Field enum (mirrors Dart _FieldType)
enum Field {
  Thought      = "thought",
  Description  = "description",
  Command      = "command",
  Options      = "options",
  Text         = "text",
  Plan         = "plan",
  ToolProtocol = "toolProtocol",
  Answer       = "answer",
}

// Helpers
function stableId(type: string, content: string): string {
  return "evt_" + fnv1a64DartCompat(type + ":" + content).toString(16);
}

function clip(s: string, max: number): string {
  if (s.length <= max) return s;
  return s.substring(0, max) + "…";
}

function parsePlanMarker(raw: string): PlanStepStatus {
  const m = raw.trim().toLowerCase();
  switch (m) {
    case "x": case "✓": case "√":
    case "完成": case "已完成": case "done": case "completed":
      return "completed";
    case ">": case "→":
    case "进行中": case "当前": case "doing": case "current":
    case "inprogress": case "in progress":
      return "inProgress";
    case "!": case "失败": case "failed":
      return "failed";
    case "-": case "跳过": case "skipped":
      return "skipped";
    default:
      return "pending";
  }
}
// parsePlanSteps - mirrors Dart _parsePlanSteps
function parsePlanSteps(block: string): PlanStep[] {
  const steps: PlanStep[] = [];
  const BT3 = String.fromCharCode(96).repeat(3);
  for (const rawLine of block.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.startsWith(BT3)) continue;

    const bulletM = line.match(PLAN_BULLET);
    let rest = bulletM ? line.substring(bulletM[0].length) : line;
    let status: PlanStepStatus = "pending";

    const boxM = rest.match(PLAN_STATUS_BOX);
    if (boxM) {
      status = parsePlanMarker(boxM[1]);
      rest = rest.substring(boxM[0].length).trim();
    } else if (!bulletM) {
      continue;
    }

    rest = rest.replace(PLAN_TITLE_PREFIX, "").trim();
    if (!rest) continue;
    steps.push({title: clip(rest, 160), status});
    if (steps.length >= 30) break;
  }
  return steps;
}

// cleanCommand - mirrors Dart _cleanCommand
function cleanCommand(cmd: string): string {
  return cmd
    .replace(CODE_FENCE_PREFIX, "")
    .replace(CODE_FENCE_SUFFIX, "")
    .trim();
}

// splitLineByKeywords - mirrors Dart _splitLineByKeywords
interface KMatch { pos: number; kw: string; }

function splitLineByKeywords(line: string): string[] {
  const matches: KMatch[] = [];
  for (const kw of KEYWORDS) {
    let idx = 0;
    while (true) {
      const pos = line.indexOf(kw, idx);
      if (pos < 0) break;
      matches.push({pos, kw});
      idx = pos + kw.length;
    }
  }
  if (matches.length === 0) return [line];
  matches.sort((a, b) => a.pos - b.pos);
  const result: string[] = [];
  let last = 0;
  for (const m of matches) {
    if (m.pos > last) result.push(line.substring(last, m.pos));
    last = m.pos;
  }
  if (last < line.length) result.push(line.substring(last));
  return result;
}
// main parse - mirrors Dart ReActStreamParser.parse
export function parse(fullResponse: string): AgentEvent[] {
  const events: AgentEvent[] = [];
  let content = fullResponse;

  // Preprocess: XML fenced tool_call blocks -> ReAct keyword form
  content = content.replace(XML_FENCED, (_m, funcName: string, cmd: string) => {
    cmd = cmd.trim();
    if (["terminal", "execute", "run_command"].includes(funcName)) {
      return "动作: execute\n命令: " + cmd;
    }
    return cmd;
  });

  // XML bare tool_call blocks
  content = content.replace(XML_BARE, (_m, funcName: string, cmd: string) => {
    cmd = cmd.trim();
    if (["terminal", "execute", "run_command"].includes(funcName)) {
      return "动作: execute\n命令: " + cmd;
    }
    return cmd;
  });

  // Remove residual --- separators (standalone lines only)
  content = content.replace(RESIDUAL_SEP, "");

  let currentField: Field | null = null;
  let buffer = "";
  let pendingOptions: string[] | null = null;
  let lastQuestion: string | null = null;
  let pendingDescription: string | null = null;
  let answerBody: string = "";

  function flush(): void {
    const value = buffer.trim();
    buffer = "";
    if (!value && pendingOptions === null) {
      currentField = null;
      return;
    }
    switch (currentField) {
      case Field.Thought: {
        const id = stableId("thought", value);
        events.push({id, type: "thought", timestamp: Date.now(), text: value});
        if (value) lastQuestion = value;
        pendingDescription = null;
        break;
      }
      case Field.Description: {
        if (value) pendingDescription = value;
        break;
      }
      case Field.Command: {
        const cleaned = cleanCommand(value);
        if (cleaned) {
          const id = stableId("command", cleaned);
          events.push({id, type: "command", timestamp: Date.now(), command: cleaned, description: pendingDescription ?? undefined});
          pendingDescription = null;
        }
        break;
      }
      case Field.Options: {
        if (pendingOptions && pendingOptions.length > 0) {
          const optsStr = pendingOptions.join("|");
          const id = stableId("ask", optsStr);
          events.push({id, type: "ask", timestamp: Date.now(), question: lastQuestion ?? undefined, options: pendingOptions});
        }
        pendingOptions = null;
        lastQuestion = null;
        pendingDescription = null;
        break;
      }
      case Field.Plan: {
        const steps = parsePlanSteps(value);
        if (steps.length > 0) {
          const key = steps.map((s) => s.status + ":" + s.title).join("|");
          const id = stableId("plan", key);
          events.push({id, type: "plan", timestamp: Date.now(), planSteps: steps});
        }
        break;
      }
      case Field.Text: {
        if (value) {
          const id = stableId("text", value);
          events.push({id, type: "text", timestamp: Date.now(), text: value});
        }
        pendingDescription = null;
        break;
      }
      case Field.ToolProtocol: {
        pendingDescription = null;
        break;
      }
      case Field.Answer: {
        // 回答正文不进过程时间线；捕获给 动作: finish 作为 summary（Dart: answerBody → finish summary）
        if (value) answerBody = value;
        pendingDescription = null;
        break;
      }
      case null:
      default:
        break;
    }
    currentField = null;
  }

  const lines = content.split("\n");
  let inCodeBlock = false;
  let codeBlockBuffer = "";
  const BT3 = String.fromCharCode(96).repeat(3);

  for (const line of lines) {
    const trimmed = line.trim();

    // Code fence toggle
    if (trimmed.startsWith(BT3)) {
      if (inCodeBlock) {
        inCodeBlock = false;
        const code = codeBlockBuffer.trim();
        codeBlockBuffer = "";
        if (code) {
          flush();
          const id = stableId("command", code);
          events.push({id, type: "command", timestamp: Date.now(), command: code, description: pendingDescription ?? undefined});
          pendingDescription = null;
        }
      } else {
        flush();
        inCodeBlock = true;
        codeBlockBuffer = "";
      }
      continue;
    }

    if (inCodeBlock) {
      codeBlockBuffer += line + "\n";
      continue;
    }

    const segments = splitLineByKeywords(line);
    for (const seg of segments) {
      const segTrimmed = seg.trim();
      if (!segTrimmed) continue;

      let matchedKeyword: string | null = null;
      for (const kw of KEYWORDS) {
        if (segTrimmed.startsWith(kw)) { matchedKeyword = kw; break; }
      }

      if (matchedKeyword) {
        const contentAfter = segTrimmed.substring(matchedKeyword.length).trim();
        // kwType = keyword without the trailing colon (ASCII ":" or fullwidth "：")
        const kwType = matchedKeyword.substring(0, matchedKeyword.length - 1);
        switch (kwType) {
          case "思考": // 思考
            flush(); currentField = Field.Thought;
            if (contentAfter) buffer += contentAfter + "\n";
            break;
          case "计划": // 计划
            flush(); currentField = Field.Plan;
            if (contentAfter) buffer += contentAfter + "\n";
            break;
          case "说明": // 说明
            flush(); currentField = Field.Description;
            if (contentAfter) buffer += contentAfter + "\n";
            break;
          case "动作": { // 动作
            flush();
            // 动作: finish → 发一条 finish 事件（Dart: actionStr == 'finish' → ActionType.finish）
            // finishState 缺省 → 引擎按 "success" 处理；summary 用捕获到的 回答: 正文
            const actionWord = contentAfter ? contentAfter.trim().toLowerCase() : "";
            if (actionWord === "finish") {
              const id = stableId("finish", answerBody);
              events.push({id, type: "finish", timestamp: Date.now(), summary: answerBody || undefined});
            }
            break;
          }
          case "命令": // 命令
            flush(); currentField = Field.Command;
            if (contentAfter) buffer += contentAfter + "\n";
            break;
          case "选项": // 选项
            flush(); currentField = Field.Options;
            pendingOptions = contentAfter
              .split("|")
              .map((s) => s.trim())
              .filter((s) => s);
            break;
          case "回答": // 回答
            flush(); currentField = Field.Answer;
            if (contentAfter) buffer += contentAfter + "\n";
            break;
          case "工具": // 工具
          case "参数": // 参数
            flush(); currentField = Field.ToolProtocol;
            break;
        }
      } else if (currentField === Field.ToolProtocol) {
        const indented = seg.length > 0 && (seg[0] === " " || seg[0] === "\t");
        if (indented || !seg.trim()) {
          buffer += seg + "\n";
        } else {
          flush();
          currentField = Field.Thought;
          buffer += seg + "\n";
        }
      } else {
        if (currentField === Field.Thought ||
            currentField === Field.Command ||
            currentField === Field.Description ||
            currentField === Field.Text ||
            currentField === Field.Answer ||
            currentField === Field.Plan) {
          buffer += seg + "\n";
        } else if (currentField === Field.Options) {
          flush();
          currentField = Field.Text;
          buffer += seg + "\n";
        } else {
          currentField = Field.Text;
          buffer += seg + "\n";
        }
      }
    }
  }

  // Trailing code block still open
  if (inCodeBlock) {
    const code = codeBlockBuffer.trim();
    if (code) {
      flush();
      const id = stableId("command", code);
      events.push({id, type: "command", timestamp: Date.now(), command: code, description: pendingDescription ?? undefined});
      pendingDescription = null;
    }
  }

  flush();
  return events;
}