// llm/clients.ts - LLM provider clients
//
// Phase 0: define the interface and a mock client for testing.
// Phase 1: wire up @ai-sdk/openai, @ai-sdk/anthropic, @ai-sdk/openai-compatible.

import {ModelConfig} from "../rpc/schema.js";

export interface LlmResponseOptions {
  modelConfig: ModelConfig;
  messages: ChatMsg[];
  /** Abort signal for cancellation. */
  signal?: AbortSignal;
  /** Idle timeout: max ms between two chunks. 0 = no timeout. */
  idleTimeoutMs?: number;
  /** Optional tool schemas (OpenAI tools API format). */
  tools?: Array<{type: "function"; function: {name: string; description?: string; parameters: Record<string, unknown>}}>;
  onReasoningDelta?: (delta: string) => void;
}

export interface LlmResult {
  text: string;
  reasoning: string;
  usage?: {promptTokens: number; completionTokens: number; cachedTokens?: number};
}

export interface ChatMsg {
  role: "system" | "user" | "assistant";
  content: string;
  /** Tool-call message (only for assistant role when FC is enabled). */
  toolCalls?: Array<{id: string; name: string; arguments: string}>;
}

export interface LlmClient {
  readonly name: string;
  chatStream(opts: LlmResponseOptions): Promise<LlmResult>;
}

// ─── Mock client for Phase 0 testing ─────────────────

export class MockLlmClient implements LlmClient {
  readonly name = "mock";
  constructor(private readonly responses: string[] = []) {}

  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    // Return the next canned response
    const resp = this.responses.shift() ?? "";
    void opts;
    return {text: resp, reasoning: ""};
  }
}

// ─── Real OpenAI client (Phase 1, placeholder for now) ─────────────────
// Will use @ai-sdk/openai once we wire up dependencies.

export interface OpenAIClientConfig {
  apiKey: string;
  baseUrl?: string;
  model: string;
  temperature?: number;
  maxTokens?: number;
}

/**
 * Phase 1 stub - replace with @ai-sdk/openai in Phase 1.
 * This class exists so the engine can reference a unified interface.
 */
export class OpenAiClient implements LlmClient {
  readonly name = "openai";
  /** Reserved for Phase 1; kept for interface compatibility. */
  readonly config: OpenAIClientConfig;
  constructor(config: OpenAIClientConfig) {
    this.config = config;
  }

  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    // Phase 1: wire to @ai-sdk/openai
    throw new Error("OpenAiClient not yet implemented — Phase 1 task");
  }
}
