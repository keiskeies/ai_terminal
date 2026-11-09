// llm/openai_stream.ts - OpenAI-compatible streaming client using native fetch
// Mirrors Dart's OpenAIProvider._postChatCompletions + SSE line parsing.
// No new dependencies: Node 18+ global fetch.

import {LlmClient, LlmResponseOptions, LlmResult} from "./clients.js";
import {StreamAccumulator, shouldRetryWithoutStreamOptions} from "./stream.js";

export interface OpenAiStreamConfig {
  apiKey: string;
  baseUrl?: string;      // e.g. https://api.openai.com/v1
  model: string;
  temperature?: number;
  maxTokens?: number;
  reasoningEffort?: string; // off/low/medium/high
}
export class OpenAiStreamClient implements LlmClient {
  readonly name: string = "openai";  constructor(private readonly config: OpenAiStreamConfig) {}

  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    return this.stream(opts);
  }

  async stream(opts: LlmResponseOptions): Promise<LlmResult> {
    const acc = new StreamAccumulator();
    let usage: LlmResult['usage'];

    const base = (this.config.baseUrl ?? "https://api.openai.com/v1").replace(/\/+$/, "");
    const url = base + "/chat/completions";

    const body: Record<string, unknown> = {
      model: this.config.model,
      messages: this.buildMessages(opts),
      stream: true,
    };
    if (this.config.temperature != null) body.temperature = this.config.temperature;
    if (this.config.maxTokens != null) body.max_tokens = this.config.maxTokens;
    const effort = (this.config.reasoningEffort ?? "").trim();
    if (effort) body.reasoning_effort = effort;
    if (opts.tools && opts.tools.length) body.tools = opts.tools;

    const headers = {
      "Authorization": "Bearer " + this.config.apiKey,
      "Content-Type": "application/json",
    };

    // First try with stream_options; on 400, retry without (Dart parity)
    const result = await this.doFetch(url, headers, body, true, opts, acc, (u) => { usage = u; });
    if (!result.ok) {
      if (shouldRetryWithoutStreamOptions(true, result.statusCode)) {
        const r2 = await this.doFetch(url, headers, body, false, opts, acc, (u) => { usage = u; });
        if (!r2.ok) throw new Error("LLM HTTP " + r2.statusCode + ": " + (r2.body ?? "").slice(0, 500));
      } else {
        throw new Error("LLM HTTP " + result.statusCode + ": " + (result.body ?? "").slice(0, 500));
      }
    }

    const out = acc.getResult();
    const llmResult: LlmResult = {text: out.text, reasoning: out.reasoning};
    if (usage) llmResult.usage = usage;
    return llmResult;
  }
  private buildMessages(opts: LlmResponseOptions): Array<Record<string, unknown>> {
    const msgs: Array<Record<string, unknown>> = [];
    for (const m of opts.messages) {
      if (!m.content.trim()) continue; // Dart: skip empty history
      msgs.push({role: m.role, content: m.content});
    }
    return msgs;
  }

  private async doFetch(
    url: string,
    headers: Record<string, string>,
    body: Record<string, unknown>,
    withStreamOptions: boolean,
    opts: LlmResponseOptions,
    acc: StreamAccumulator,
    onUsage: (u: LlmResult['usage']) => void,
  ): Promise<{ok: boolean; statusCode: number | null; body?: string}> {
    const payload = {...body};
    if (withStreamOptions) payload.stream_options = {include_usage: true};

    const ctrl = new AbortController();
    const onSignalAbort = () => ctrl.abort();
    if (opts.signal) {
      if (opts.signal.aborted) return {ok: false, statusCode: null};
      opts.signal.addEventListener("abort", onSignalAbort);
    }

    let resp: Response;
    try {
      resp = await fetch(url, {
        method: "POST",
        headers,
        body: JSON.stringify(payload),
        signal: ctrl.signal,
      });
    } catch (e: any) {
      return {ok: false, statusCode: null, body: e.message ?? String(e)};
    } finally {
      opts.signal?.removeEventListener("abort", onSignalAbort);
    }

    if (!resp.ok) {
      const text = await resp.text().catch(() => "");
      return {ok: false, statusCode: resp.status, body: text};
    }

    // Parse SSE stream
    const reader = resp.body?.getReader();
    if (!reader) return {ok: true, statusCode: resp.status};

    const decoder = new TextDecoder("utf-8");
    let buf = "";
    while (true) {
      const {value, done} = await reader.read();
      if (done) break;
      buf += decoder.decode(value, {stream: true});
      let nl: number;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        this.processSseLine(line, acc, onUsage, opts);
      }
    }
    return {ok: true, statusCode: resp.status};
  }

  private processSseLine(line: string, acc: StreamAccumulator, onUsage: (u: LlmResult["usage"]) => void, opts: LlmResponseOptions): void {
    // Port of Dart processLine (ai_service.dart 221-284). tool_calls deferred to Phase 2.
    const data = line.startsWith("data: ") ? line.substring(6) : null;
    if (!data) return;
    let json: any;
    try { json = JSON.parse(data); } catch { return; }
    if (typeof json !== "object" || json === null) return;
    const usage = json.usage;
    if (usage && typeof usage === "object") {
      onUsage({
        promptTokens: usage.prompt_tokens ?? 0,
        completionTokens: usage.completion_tokens ?? 0,
        cachedTokens: usage.prompt_tokens_details?.cached_tokens,
      });
    }
    const choices = json.choices;
    if (!Array.isArray(choices) || choices.length === 0) return;
    const delta = choices[0].delta;
    if (!delta || typeof delta !== "object") return;
    const reasoning = delta.reasoning_content ?? delta.reasoning;
    if (typeof reasoning === "string" && reasoning.length > 0) {
      opts.onReasoningDelta?.(reasoning);
      acc.pushReasoningDelta(reasoning);
    }
    const content = delta.content;
    // R8 + Dart parity: gate on non-empty content (was leaking empty deltas)
    if (content != null && String(content).length > 0) acc.pushText(String(content));
  }
}
