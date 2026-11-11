// utils/context_trim.ts - port of AgentEngine._trimMessages (ai_terminal/lib/services/
// agent_engine.dart:4612-4671) plus the two Dart constants it reads (376, 379) and the
// effectiveContextWindow fallback (lib/models/ai_model_config.dart:102-103 with
// kDefaultContextWindow = 262144 from lib/models/ai_endpoint.dart:253).
//
// AGENTS.md R8 (unbounded buffers): Node had NO bound on engine conversation history
// at all before this file - one long-running task with chatty LLM rounds grows the
// prompt sent on EVERY step quadratically and eventually outgrows the model context
// with an opaque provider error. Dart defends with three layers; this is a 1:1 port:
//   L1 per-message tail truncation over MAX_MESSAGE_CHARS, fence-rebalanced
//   L2 round-count backstop at MAX_CONVERSATION_ROUNDS * 2
//   L3 token-aware drop (never below 2 messages) via the token_estimator port
// system messages are pinned at the head and never truncated, exactly like Dart.
//
// Byte-faithfulness notes (char codes recovered from the Dart source, not retyped):
//   L1 prefix  0x2e 0x2e 0x2e 0x28 0x5df2 0x622a 0x65ad 0x524d 0x20 ... 0x20 0x5b57 0x7b26 0x29 0x0a
//   L2 log     0x8f6e 0x6570 0x88c1 0x526a 0x3a 0x20 ... 0x20 0x2192 0x20 ... 0x20 0x6761
//   L3 log     token-aware 0x88c1 0x526a 0x3a 0x20 ... 0x20 0x2192 0x20 ... 0x20 0x6761 0x2c 0x20
//              then tokens=... /budget (ctx=...)

import {estimateHistory, estimateMessage} from "./token_estimator.js";

/** Structural view: works on ChatMsg without importing llm/clients (cycle-proof). */
export interface TrimMessage {
  role: string;
  content: string;
}

/** Dart _maxConversationRounds (agent_engine.dart:376). */
export const MAX_CONVERSATION_ROUNDS = 40;
/** Dart _maxMessageChars (agent_engine.dart:379). */
export const MAX_MESSAGE_CHARS = 4000;
/** Dart kDefaultContextWindow (ai_endpoint.dart:253), used by effectiveContextWindow. */
export const DEFAULT_CONTEXT_WINDOW = 262144;
/** Dart: tokenBudget = (contextWindow * 0.7).round() (agent_engine.dart:4648). */
export const CONTEXT_TOKEN_RATIO = 0.7;

/** Dart AIModelConfig.effectiveContextWindow: contextWindow greater than 0 ? it : fallback. */
export function effectiveContextWindow(contextWindow: number | undefined): number {
  return contextWindow !== undefined && contextWindow > 0 ? contextWindow : DEFAULT_CONTEXT_WINDOW;
}

// The three-code-tick code fence, built at runtime (project emit rule bans the literal).
const FENCE = String.fromCharCode(96, 96, 96);

/**
 * L1: one message down to MAX_MESSAGE_CHARS, TAIL retained (Dart substring(len - cap)
 * on line 4621 - the most RECENT characters survive; dropping the head is the whole
 * point of R8: the tail is what the model still needs to act on).
 * Fence rebalance (Dart 4622-4626): a tail cut can leave an ODD number of fence
 * tokens; append one to keep the block closed, otherwise every later prompt carries
 * a broken code block. Dart allMatches is non-overlapping left-to-right; a split on
 * the fence counts the same occurrences.
 * Exported for direct testing; the wire-visible prefix string must stay byte-exact.
 */
export function truncateOneMessage(content: string): string {
  if (content.length <= MAX_MESSAGE_CHARS) return content; // Dart truncates only above the cap
  const cut = content.length - MAX_MESSAGE_CHARS;
  let t = content.substring(cut);
  const fences = t.split(FENCE).length - 1; // non-overlapping occurrences
  if (fences % 2 !== 0) {
    t = t + String.fromCharCode(10) + FENCE;
  }
  // "...(yi jie duan qian N zi fu)\n" - byte-faithful to Dart 4629
  return "...(\u5DF2\u622A\u65AD\u524D " + cut + " \u5B57\u7B26)\n" + t;
}

/**
 * The three-layer trim, applied IN PLACE (Dart mutates its list via clear() plus
 * addAll(), agent_engine.dart:4667-4670 - keeping in-place semantics matters: the
 * engine holds the array by reference and every checkpoint snapshot maps over it).
 * Returns the log lines Dart would have sent to agentLogger with tag TrimMsgs - the
 * engine forwards them to its own stderr logger; an empty array means nothing dropped.
 */
export function trimConversation(messages: TrimMessage[], contextWindow: number): string[] {
  const logs: string[] = [];
  const systemMsgs = messages.filter((m) => m.role === "system");
  const nonSystemMsgs = messages.filter((m) => m.role !== "system");

  // L1: per-message truncation BEFORE any token math (Dart 4617-4634: one huge
  // message must not blow the budget while the estimator still sees its full size).
  const truncated: TrimMessage[] = [];
  for (const msg of nonSystemMsgs) {
    if (msg.content.length > MAX_MESSAGE_CHARS) {
      truncated.push({role: msg.role, content: truncateOneMessage(msg.content)});
    } else {
      truncated.push(msg);
    }
  }

  // L2: round-count backstop (Dart 4636-4644). kept = last MAX*2 non-system messages.
  const maxNonSystem = MAX_CONVERSATION_ROUNDS * 2;
  let kept = truncated.length > maxNonSystem
      ? truncated.slice(truncated.length - maxNonSystem)
      : truncated;
  if (kept.length !== truncated.length) {
    // "lun shu cai jian: A -> B tiao" - byte-faithful to Dart 4643 (U+2192 arrow)
    logs.push("\u8F6E\u6570\u88C1\u526A: " + truncated.length + " \u2192 " + kept.length + " \u6761");
  }

  // L3: token-aware drop, oldest first, floor of 2 messages (Dart 4646-4665).
  // Dart precomputes the drop index before sublist - mirror it, no O(n^2) splice.
  const tokenBudget = Math.round(contextWindow * CONTEXT_TOKEN_RATIO);
  let totalTokens = estimateHistory(kept);
  if (totalTokens > tokenBudget) {
    const originalCount = kept.length;
    let drop = 0;
    while (drop < kept.length - 2 && totalTokens > tokenBudget) {
      totalTokens -= estimateMessage(kept[drop]);
      drop++;
    }
    if (drop > 0) kept = kept.slice(drop);
    // Dart concatenates the two adjacent literals into ONE log line (4660-4664):
    logs.push(
      "token-aware \u88C1\u526A: " + originalCount + " \u2192 " + kept.length + " \u6761, " +
      "tokens=" + totalTokens + "/" + tokenBudget + " (ctx=" + contextWindow + ")",
    );
  }

  // In-place rewrite, same shape as Dart: system head first, kept tail after.
  messages.length = 0;
  for (const m of systemMsgs) messages.push(m);
  for (const m of kept) messages.push(m);
  return logs;
}
