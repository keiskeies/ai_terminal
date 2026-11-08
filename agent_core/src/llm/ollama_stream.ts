// llm/ollama_stream.ts - Ollama streaming client (OpenAI-compatible, native fetch).
// Ollama exposes /v1/chat/completions with the same SSE shape as OpenAI.
// No new deps. Documented deviation from @ai-sdk/openai-compatible.

import {OpenAiStreamClient, OpenAiStreamConfig} from "./openai_stream.js";

export interface OllamaStreamConfig {
  /** Ollama server base URL. Default http://127.0.0.1:11434/v1 */
  baseUrl?: string;
  model: string;
  temperature?: number;
  maxTokens?: number;
}

export class OllamaStreamClient extends OpenAiStreamClient {
  readonly name = "ollama";
  constructor(config: OllamaStreamConfig) {
    const base: OpenAiStreamConfig = {
      apiKey: "ollama", // Ollama ignores auth; keep non-empty
      baseUrl: config.baseUrl ?? "http://127.0.0.1:11434/v1",
      model: config.model,
      temperature: config.temperature,
      maxTokens: config.maxTokens,
    };
    super(base);
  }
}
