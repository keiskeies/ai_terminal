// utils/compact.ts - port of Dart ai_terminal/lib/services/agent_engine.dart 3986-4054
// (the _compactOnce method) + 4059-4110 (_parseCompactJson).
//
// The Dart compact method is a private engine method that builds a compression
// prompt, streams the AI response, and parses the JSON array of summaries.
// Node's LLM layer is injected (llm/chat.ts), so this port takes the LLM
// provider as a parameter and returns the parsed summaries.
//
// Oracle: the CJK literals in the prompt are byte-faithful to the Dart source
// (3990-4003). The prompt is ASCII-safe here via \uXXXX escapes.
//
// Numbered deviations from the Dart original:
//   1. Dart uses _aiProvider.chatStream (a Flutter/Dio stream); Node uses the
//      injected LLM provider's chatStream (llm/chat.ts). The streaming logic
//      (chunk accumulation + timeout) is identical.
//   2. Dart's stream.timeout() (4033-4039) is replaced by a Promise.race with
//      a setTimeout - the same semantic: on timeout, use the collected content.
//   3. Dart's _parseCompactJson (4059-4110) handles markdown code fences and
//      JSON extraction; the Node port is byte-identical.

import {agentLogger} from "./agent_logger.js";

/**
 * One (index, summary) pair from a compact pass.
 */
export interface CompactSummary {
  index: number;
  summary: string;
}

/**
 * A message to be compacted. Mirrors the Dart ChatMessage shape the compact
 * prompt reads from (3982: messages param; 4006-4013: role/command fields).
 */
export interface CompactMessage {
  index: number;
  role: "user" | "assistant";
  content: string;
  command?: string;
  commandSuccess?: boolean | null;
}

/**
 * LLM provider for compact. Matches the minimal interface the compact path
 * needs (Dart _aiProvider.chatStream at 4023).
 */
export interface CompactLlmProvider {
  chatStream(params: {
    systemPrompt: string;
    prompt: string;
    responseTimeoutMs?: number;
  }): Promise<string>;
}

/**
 * CJK literals from the Dart compact prompt (3990-4003), byte-faithful.
 */
// 3990: 你是对话压缩助手。请将以下对话历史逐条压缩为简洁摘要。
const COMPACT_PROMPT_HEAD = "\u4f60\u662f\u5bf9\u8bdd\u538b\u7f29\u52a9\u624b\u3002\u8bf7\u5c06\u4ee5\u4e0b\u5bf9\u8bdd\u5386\u53f2\u9010\u6761\u538b\u7f29\u4e3a\u7b80\u6d01\u6458\u8981\u3002";
// 3992: 压缩规则：
const COMPACT_RULES_HEAD = "\u538b\u7f29\u89c4\u5219\uff1a";
// 3993: - 用户的废话/寒暄/重复表述压缩为一句话意图
const COMPACT_RULE_1 = "- \u7528\u6237\u7684\u5e9f\u8bdd/\u5bd2\u6085/\u91cd\u590d\u8868\u8ff0\u538b\u7f29\u4e3a\u4e00\u53e5\u8bdd\u610f\u56fe";
// 3994: - 查询类命令（ls/cat/ps/grep/find/df 等）的输出结果：只保留关键结论，冗长输出直接丢弃
const COMPACT_RULE_2 = "- \u67e5\u8be2\u7c7b\u547d\u4ee4\uff08ls/cat/ps/grep/find/df \u7b49\uff09\u7684\u8f93\u51fa\u7ed3\u679c\uff1a\u53ea\u4fdd\u7559\u5173\u952e\u7ed3\u8bba\uff0c\u5197\u957f\u8f93\u51fa\u76f4\u63a5\u4e22\u5f03";
// 3996: - 修改类命令（install/restart/stop/rm/config 等）：只保留"执行成功"或"失败原因"
const COMPACT_RULE_3 = "- \u4fee\u6539\u7c7b\u547d\u4ee4\uff08install/restart/stop/rm/config \u7b49\uff09\uff1a\u53ea\u4fdd\u7559\"\u6267\u884c\u6210\u529f\"\u6216\"\u5931\u8d25\u539f\u56e0\"";
// 3997: - AI 的思考和推理：压缩为关键决策和结论，去掉推理过程
const COMPACT_RULE_4 = "- AI \u7684\u601d\u8003\u548c\u63a8\u7406\uff1a\u538b\u7f29\u4e3a\u5173\u952e\u51b3\u7b56\u548c\u7ed3\u8bba\uff0c\u53bb\u6389\u63a8\u7406\u8fc7\u7a0b";
// 3998: - 保留所有关键信息：用户目标、已执行命令、系统状态、遗留问题、下一步计划
const COMPACT_RULE_5 = "- \u4fdd\u7559\u6240\u6709\u5173\u952e\u4fe1\u606f\uff1a\u7528\u6237\u76ee\u6807\u3001\u5df2\u6267\u884c\u547d\u4ee4\u3001\u7cfb\u7edf\u72b6\u6001\u3001\u9057\u7559\u95ee\u9898\u3001\u4e0b\u4e00\u6b65\u8ba1\u5212";
// 3999: - 每条摘要控制在 200 字以内
const COMPACT_RULE_6 = "- \u6bcf\u6761\u6458\u8981\u63a7\u5236\u5728 200 \u5b57\u4ee5\u5185";
// 4000: - 不要编造未出现的信息
const COMPACT_RULE_7 = "- \u4e0d\u8981\u7f16\u9020\u672a\u51fa\u73b0\u7684\u4fe1\u606f";
// 4002: 输出格式：JSON 数组，每个元素 {"index": 消息序号, "summary": "压缩摘要"}
const COMPACT_FORMAT = "\u8f93\u51fa\u683c\u5f0f\uff1aJSON \u6570\u7ec4\uff0c\u6bcf\u4e2a\u5143\u7d20 {\"index\": \u6d88\u606f\u5e8f\u53f7, \"summary\": \"\u538b\u7f29\u6458\u8981\"}";
// 4003: 只输出 JSON，不要解释，不要 markdown 代码块标记。
const COMPACT_JSON_ONLY = "\u53ea\u8f93\u51fa JSON\uff0c\u4e0d\u8981\u89e3\u91ca\uff0c\u4e0d\u8981 markdown \u4ee3\u7801\u5757\u6807\u8bb0\u3002";
// 4005: === 对话历史 ===
const COMPACT_HISTORY_HEAD = "=== \u5bf9\u8bdd\u5386\u53f2 ===";
// 4007: 用户 / AI
const LABEL_USER = "\u7528\u6237";
const LABEL_AI = "AI";
// 4011: 成功 / 失败 / 未知
const CMD_SUCCESS = "\u6210\u529f";
const CMD_FAIL = "\u5931\u8d25";
const CMD_UNKNOWN = "\u672a\u77e5";

/**
 * Build the compact prompt for the given messages (Dart 3988-4016).
 * @returns the full prompt string ready for the LLM.
 */
export function buildCompactPrompt(messages: readonly CompactMessage[]): string {
  const NL = String.fromCharCode(10);
  const parts: string[] = [];
  parts.push(COMPACT_PROMPT_HEAD, "");
  parts.push(COMPACT_RULES_HEAD);
  parts.push(COMPACT_RULE_1);
  parts.push(COMPACT_RULE_2);
  parts.push(COMPACT_RULE_3);
  parts.push(COMPACT_RULE_4);
  parts.push(COMPACT_RULE_5);
  parts.push(COMPACT_RULE_6);
  parts.push(COMPACT_RULE_7);
  parts.push("", COMPACT_FORMAT, COMPACT_JSON_ONLY, "");
  parts.push(COMPACT_HISTORY_HEAD);
  for (const m of messages) {
    const label = m.role === "user" ? LABEL_USER : LABEL_AI;
    parts.push("[" + m.index + "] " + label + ": " + m.content);
    if (m.command !== undefined && m.command !== "") {
      const status = m.commandSuccess === true ? CMD_SUCCESS : m.commandSuccess === false ? CMD_FAIL : CMD_UNKNOWN;
      parts.push("  [\u547d\u4ee4] " + m.command + " \u2192 " + status);
    }
    parts.push("---");
  }
  return parts.join(NL);
}

/**
 * Parse the AI compact response into (index, summary) pairs (Dart 4059-4110).
 * Handles markdown code fences, extracts the JSON array, and validates each
 * element. Returns null on parse failure (the caller logs and returns null,
 * matching Dart 4045-4047 / 4052).
 */
export function parseCompactJson(raw: string): CompactSummary[] | null {
  // Dart 4062-4070: strip markdown code fences, find the JSON array
  let text = raw.trim();
  const open = text.indexOf("[");
  const close = text.lastIndexOf("]");
  if (open === -1 || close === -1 || close < open) return null;
  text = text.substring(open, close + 1);
  try {
    const arr = JSON.parse(text) as unknown;
    if (!Array.isArray(arr)) return null;
    const result: CompactSummary[] = [];
    for (const item of arr) {
      if (typeof item !== "object" || item === null) continue;
      const o = item as Record<string, unknown>;
      const idx = o["index"];
      const sum = o["summary"];
      if (typeof idx !== "number" || typeof sum !== "string") continue;
      result.push({index: idx, summary: sum});
    }
    return result.length > 0 ? result : null;
  } catch {
    return null;
  }
}

/**
 * Run one compact pass: build the prompt, call the LLM, parse the result.
 * (Dart 3986-4054: _compactOnce).
 *
 * @param messages  the conversation messages to compact
 * @param llm       the LLM provider (injected)
 * @param timeoutMs the AI response timeout in ms (Dart aiResponseTimeout)
 * @returns the summaries, or null on failure/timeout/parse error
 */
export async function compactOnce(
  messages: readonly CompactMessage[],
  llm: CompactLlmProvider,
  timeoutMs: number = 120_000,
): Promise<CompactSummary[] | null> {
  if (messages.length === 0) return null;

  agentLogger.info("Compact", "\u5f00\u59cb\u4e00\u6b21\u6027\u538b\u7f29 " + messages.length + " \u6761\u6d88\u606f"); // Dart 3986

  const prompt = buildCompactPrompt(messages);
  const systemPrompt = "\u4f60\u662f\u5bf9\u8bdd\u538b\u7f29\u52a9\u624b\uff0c\u53ea\u8f93\u51fa JSON \u6570\u7ec4\uff0c\u4e0d\u8981\u89e3\u91ca\u3002"; // Dart 4021

  try {
    // Race the LLM call against a timeout (deviation 2: Dart stream.timeout)
    let raw = "";
    const result = await Promise.race([
      llm.chatStream({systemPrompt, prompt, responseTimeoutMs: timeoutMs}),
      new Promise<string>((resolve) => {
        setTimeout(() => resolve("", ), timeoutMs); // sentinel: empty string means timeout
      }),
    ]);
    raw = result;

    if (raw === "") {
      agentLogger.warn("Compact", "\u538b\u7f29\u6d41\u8d85\u65f6(" + (timeoutMs / 1000) + "s)\uff0c\u7ec8\u6b62\u5e76\u4f7f\u7528\u5df2\u91c7\u96c6\u5185\u5bb9"); // Dart 4036-4037
      return null;
    }

    const parsed = parseCompactJson(raw);
    if (parsed === null || parsed.length === 0) {
      agentLogger.warn("Compact", "\u538b\u7f29\u7ed3\u679c\u89e3\u6790\u5931\u8d25\u6216\u4e3a\u7a7a"); // Dart 4046
      return null;
    }
    agentLogger.info("Compact", "\u538b\u7f29\u5b8c\u6210: " + parsed.length + " \u6761\u6458\u8981"); // Dart 4049
    return parsed;
  } catch (e) {
    agentLogger.error("Compact", "\u538b\u7f29\u5931\u8d25: " + String(e)); // Dart 4052
    return null;
  }
}