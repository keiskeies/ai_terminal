/**
 * 工具动作数据入口链路（round 121）。
 *
 * Dart 锚点：
 *   - AgentEngine.parseToolAction  agent_engine.dart 2206-2261（静态方法，
 *     Dart 侧注释明确说明抽成静态就是为了端到端测试覆盖解析链路）
 *   - ToolCallAccumulator          utils/tool_call_accumulator.dart 17-147
 *   - ToolCall                     utils/tool_call_accumulator.dart 155-168
 *
 * 链路形状（R9 回归的正是这条链，见 ai_terminal/test/react_parse_e2e_test.dart）：
 *   OpenAI FC 流式 tool_calls delta → ToolCallAccumulator.addDelta 增量拼接
 *   → finalize → ToolCallAccumulator.toReActText 生成 ReAct 文本
 *   →（与 thought 增量拼接，开头自带换行保证 动作: tool 独立成行）
 *   → engine 扫到 动作: tool 行 → parseToolAction → toolName/toolArgs
 *
 * Node 侧现状：engine.run() 的动作路由尚未接线 tool 分支（下一轮），本文件先把
 * 纯函数与累积器按 Dart 逐分支 1:1 落好，测试直接对 parseToolAction 复现
 * Dart e2e 断言。parser.ts 对 工具:/参数: 行的吞弃行为保持不变（Dart 同构：
 * ReActStreamParser 不提取动作类型，动作由 engine 单独解析）。
 */
import {ToolArgsParser} from "../tools/tool_args.js";

/** Dart ToolCall（tool_call_accumulator.dart 155-168）。arguments 为 JSON 原文或修复后的 JSON。 */
export interface ToolCall {
  id: string;
  name: string;
  arguments: string;
}

/** Dart 记录类型 (String?, Map<String, dynamic>?) 的等价返回形状。 */
export type ToolActionResult = [toolName: string | null, toolArgs: Record<string, unknown> | null];

function isPlainRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/**
 * 复现 Dart 插值字符串里 value 的 toString 形状（jsonToKeyValue 用）。
 * Dart jsonDecode 对 JSON 整数给 int（30 → 30），小数给 double；List 元素
 * 逐个 toString；嵌套 Map 打印为 {key: value, key2: value2}（Dart Map.toString
 * 的无引号形状，不是 JSON）。JSON 无法表达 Dart 其余类型，故其余分支不可达。
 */
function dartValueToString(v: unknown): string {
  if (v === null || v === undefined) return "null";
  if (typeof v === "string") return v;
  if (typeof v === "number") return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (Array.isArray(v)) return v.map((e) => dartValueToString(e)).join(",");
  if (isPlainRecord(v)) {
    const parts: string[] = [];
    for (const key of Object.keys(v)) parts.push(key + ": " + dartValueToString(v[key]));
    return "{" + parts.join(", ") + "}";
  }
  return String(v);
}

/**
 * 把 JSON arguments 字符串转换为多行 key:value 格式（Dart _jsonToKeyValue，
 * tool_call_accumulator.dart 99-120）。List 输出为逗号分隔（与 ToolArgsParser
 * 的列表字段约定一致）；JSON 解析失败或非对象 → 空字符串（回退路径：toReActText
 * 只写一行空的 参数:，ToolArgsParser 对空缓冲返回 null，engine 侧走纠错观测）。
 */
function jsonToKeyValue(jsonArgs: string): string {
  const trimmed = jsonArgs.trim();
  if (trimmed === "" || trimmed === "{}") return "";
  let decoded: unknown;
  try {
    decoded = JSON.parse(trimmed);
  } catch {
    // JSON 解析失败 — 尝试按 key:value 直接解析（罕见情况）
    return "";
  }
  if (!isPlainRecord(decoded)) return "";
  let buffer = "";
  for (const key of Object.keys(decoded)) {
    const value = decoded[key];
    if (Array.isArray(value)) {
      buffer += "  " + key + ": " + value.map((e) => dartValueToString(e)).join(",") + "\n";
    } else {
      buffer += "  " + key + ": " + dartValueToString(value) + "\n";
    }
  }
  return buffer;
}

/**
 * 工具调用 JSON 校验：arguments 非法 JSON 时尝试补全尾部右花括号
 * （Dart _repairArguments，tool_call_accumulator.dart 124-144：OpenAI 流式
 * 拼接有时会丢失尾部闭合括号）。修复失败返回原始串（由 ToolArgsParser 走
 * 多行 key:value 格式兜底）。
 */
function repairArguments(args: string): string {
  if (args === "") return "{}";
  try {
    JSON.parse(args);
    return args;
  } catch {
    // 继续走补全
  }
  let openCount = 0;
  let closeCount = 0;
  for (const ch of args) {
    if (ch === "{") openCount++;
    else if (ch === "}") closeCount++;
  }
  if (openCount > closeCount) {
    const repaired = args + "}".repeat(openCount - closeCount);
    try {
      JSON.parse(repaired);
      return repaired;
    } catch {
      // 修复失败，返回原始（由 ToolArgsParser 走多行格式）
    }
  }
  return args;
}

interface PartialToolCall {
  id?: string;
  name?: string;
  args: string[];
}

/**
 * 累积 OpenAI 流式响应中的 tool_calls（Dart ToolCallAccumulator，
 * tool_call_accumulator.dart 17-147）。同一 tool_call 的 arguments 按 index
 * 分片拼接；finalize 只返回有 name 的（无 name 视为不完整，丢弃），并清空
 * 累积器防止 finish_reason 与 DONE 双触发时重复投递 ReAct 文本。
 */
export class ToolCallAccumulator {
  /** index -> partial（Dart _partials；finalize 按 index 数字序，与插入序无关） */
  private readonly partials = new Map<number, PartialToolCall>();

  /** 处理 delta.tool_calls（每个 chunk 的 delta 数组）。非对象项与缺 index 项跳过。 */
  addDelta(toolCallsDelta?: readonly unknown[] | null): void {
    if (toolCallsDelta == null) return;
    for (const raw of toolCallsDelta) {
      if (!isPlainRecord(raw)) continue;
      const index = raw["index"];
      if (typeof index !== "number" || !Number.isInteger(index)) continue;
      let partial = this.partials.get(index);
      if (partial === undefined) {
        partial = {args: []};
        this.partials.set(index, partial);
      }
      const id = raw["id"];
      if (typeof id === "string" && id !== "") partial.id = id;
      const fn = raw["function"];
      if (fn !== undefined && isPlainRecord(fn)) {
        const name = fn["name"];
        if (typeof name === "string" && name !== "") partial.name = name;
        const argsChunk = fn["arguments"];
        if (typeof argsChunk === "string" && argsChunk !== "") partial.args.push(argsChunk);
      }
    }
  }

  /** 流结束时返回所有累积完成的 tool_calls，随后清空累积器。 */
  finalize(): ToolCall[] {
    const result: ToolCall[] = [];
    const indices = [...this.partials.keys()].sort((a, b) => a - b);
    for (const idx of indices) {
      const p = this.partials.get(idx);
      if (p === undefined || p.name === undefined) continue;
      result.push({
        id: p.id ?? "call_" + idx,
        name: p.name,
        arguments: repairArguments(p.args.join("")),
      });
    }
    this.partials.clear();
    return result;
  }

  /**
   * 将 tool_calls 转换为 ReAct 文本格式（Dart toReActText，
   * tool_call_accumulator.dart 74-93；多个 tool_call 之间用空行分隔）。
   *
   * 关键两处（都是历史 Bug 的回归点）：
   *   1) arguments 必须从 JSON 转成多行 key:value —— ToolArgsParser 已弃用
   *      JSON（以 左花括号 开头会被拒绝）；JSON 解析失败时只写一行空的 参数:
   *      （与 Dart 的回退一致：宁可让 engine 走纠错观测，不带着坏参数执行）。
   *   2) 开头自带换行：FC 协议允许 delta.content 与 delta.tool_calls 同时存在，
   *      thought 文本在前时不加换行会拼成 好的，我来执行工具动作: tool，
   *      动作行不再独立成行，工具调用会被整体忽略（Bug 3 同型）。
   */
  static toReActText(calls: readonly ToolCall[]): string {
    let buffer = "\n";
    for (let i = 0; i < calls.length; i++) {
      const c = calls[i];
      if (i > 0) buffer += "\n";
      buffer += "动作: tool\n";
      buffer += "工具: " + c.name + "\n";
      const argsText = jsonToKeyValue(c.arguments);
      buffer += "参数:\n";
      if (argsText !== "") buffer += argsText;
    }
    return buffer.trimEnd();
  }

  /** Dart hasPendingCalls：流中途判断是否有未完结的 tool_call。 */
  get hasPendingCalls(): boolean {
    return this.partials.size > 0;
  }
}

/**
 * 解析 动作: tool 行之后的 工具: 和 参数: 行（Dart AgentEngine.parseToolAction，
 * agent_engine.dart 2206-2261，逐分支 1:1）。返回 [toolName, toolArgs]，
 * 未找到时对应字段为 null。
 *
 * 历史 Bug 1 的守卫在这里成立：break 关键词表里**没有** 工具: —— 它是 tool
 * 动作的必填字段，若把它列进 break 条件，工具名解析分支就是死代码，toolName
 * 永远为 null（Dart e2e 文件头注释记录的正是这条）。
 *
 * 参数解析失败时 Dart 走 agentLogger.warn（agent_engine.dart:2250）。Node 侧
 * 宿主可注入 onParseFail 收集原始缓冲；缺省实现写 stderr 一行（解析本身不抛，
 * 与 Dart 一致：toolArgs 保持 null，下游拒绝带半截参数执行）。
 */
export function parseToolAction(
  lines: readonly string[],
  startIndex: number,
  onParseFail?: (rawArgsText: string) => void,
): ToolActionResult {
  let toolName: string | null = null;
  let toolArgs: Record<string, unknown> | null = null;

  for (let j = startIndex; j < lines.length; j++) {
    const tl = lines[j];
    const tlTrim = tl.trim();
    // 遇到新的 ReAct 关键词行 → 停止收集（工具: 不在此列，见上文 Bug 1 说明）
    if (
      tlTrim.startsWith("思考:") ||
      tlTrim.startsWith("思考：") ||
      tlTrim.startsWith("动作:") ||
      tlTrim.startsWith("动作：") ||
      tlTrim.startsWith("命令:") ||
      tlTrim.startsWith("命令：") ||
      tlTrim.startsWith("选项:") ||
      tlTrim.startsWith("选项：") ||
      tlTrim.startsWith("观测:") ||
      tlTrim.startsWith("观测：")
    ) {
      break;
    }
    if (tlTrim.startsWith("工具:") || tlTrim.startsWith("工具：")) {
      const sep = tlTrim.indexOf(tlTrim.includes("：") ? "：" : ":");
      toolName = tlTrim.slice(sep + 1).trim();
    } else if (tlTrim.startsWith("参数:") || tlTrim.startsWith("参数：")) {
      // 收集参数：参数: 行本身（冒号后的残留）+ 后续所有缩进行（多行 key:value）
      const sep = tlTrim.indexOf(tlTrim.includes("：") ? "：" : ":");
      let argsBuffer = tlTrim.slice(sep + 1) + "\n";
      for (let k = j + 1; k < lines.length; k++) {
        const pl = lines[k];
        if (pl === "") continue;
        // 缩进行：以空格或 Tab 开头且非空
        if (pl.startsWith(" ") || pl.startsWith("\t")) {
          argsBuffer += pl + "\n";
        } else {
          break;
        }
      }
      const parsed = ToolArgsParser.parse(argsBuffer);
      if (parsed !== null) {
        toolArgs = parsed;
      } else if (onParseFail !== undefined) {
        onParseFail(argsBuffer);
      } else {
        // Dart agentLogger.warn 的 Node 等价（agent_engine.dart:2250）
        try {
          process.stderr.write("[agent-core] ReAct warn: 工具参数解析失败, raw=" + argsBuffer + "\n");
        } catch {
          // stderr 关闭不能反噬解析决策：toolArgs 保持 null 才是本分支的目的
        }
      }
      break; // 参数解析完成后停止扫描后续行
    } else if (tlTrim === "") {
      continue;
    } else {
      // 遇到非工具/参数行，停止
      break;
    }
  }
  return [toolName, toolArgs];
}
