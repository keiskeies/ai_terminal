// llm/stream.ts - Streaming LLM response accumulation with reasoning_content support
//
// Mirrors Dart's reasoningDeltaOf + chunk concatenation logic from ai_service.dart.
// Usage:
//   const acc = new StreamAccumulator();
//   for await (const chunk of llmStream) {
//     acc.push(chunk);
//   }
//   const {text, reasoning} = acc.getResult();

export interface StreamAccumulatorOptions {
  /** Max characters retained in the tail buffer for the accumulated text. 0 = unlimited. */
  tailCap?: number;
}

export interface StreamResult {
  /** Full accumulated assistant text (may be truncated to tailCap). */
  text: string;
  /** Full accumulated reasoning text. */
  reasoning: string;
  /** Whether at least one reasoning delta was received. */
  hasReasoning: boolean;
}

export class StreamAccumulator {
  private textParts: string[] = [];
  private reasoningParts: string[] = [];
  private hasReasoningDelta = false;
  private readonly tailCap: number;

  constructor(opts: StreamAccumulatorOptions = {}) {
    this.tailCap = opts.tailCap ?? 0;
  }

  /** Push a text delta (assistant body). */
  pushText(delta: string): void {
    if (delta) this.textParts.push(delta);
  }

  /**
   * Push a reasoning delta. Accepts both OpenAI-style \`reasoning_content\\`
   * and Anthropic-style \`thinking\\` field names. Non-string or empty
   * values are treated as \`no reasoning\\` and ignored.
   */
  pushReasoningDelta(delta: unknown): void {
    if (typeof delta === "string" && delta.length > 0) {
      this.reasoningParts.push(delta);
      this.hasReasoningDelta = true;
    }
  }

  /** Convenience: extract reasoning delta from a raw JSON chunk. */
  pushRawChunk(chunk: Record<string, unknown>): void {
    const body = (chunk["choices"] as Array<Record<string, unknown>> | undefined)?.[0];
    const delta = body?.["delta"] as Record<string, unknown> | undefined;
    if (!delta) return;
    const text = delta["content"];
    if (typeof text === "string") this.pushText(text);
    // reasoning_content (DeepSeek/OpenAI) or reasoning (some gateways)
    const rc = delta["reasoning_content"] ?? delta["reasoning"];
    this.pushReasoningDelta(rc);
  }

  getResult(): StreamResult {
    let text = this.textParts.join("");
    if (this.tailCap > 0 && text.length > this.tailCap) {
      text = text.slice(text.length - this.tailCap);
    }
    return {
      text,
      reasoning: this.reasoningParts.join(""),
      hasReasoning: this.hasReasoningDelta,
    };
  }
}

/**
 * Should we retry without \`stream_options\\` after a 400?
 * Mirrors Dart's shouldRetryWithoutStreamOptions: only 400 + we sent stream_options.
 */
export function shouldRetryWithoutStreamOptions(
  sentStreamOptions: boolean,
  statusCode: number | null,
): boolean {
  return sentStreamOptions && statusCode === 400;
}
