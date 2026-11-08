// llm/anthropic_stream.ts - Anthropic Messages API streaming client (native fetch + SSE).
// Mirrors OpenAiStreamClient structure; reasoning maps from extended-thinking deltas.
// No new deps (Node 18+ global fetch). Documented deviation from @ai-sdk/anthropic.

import {LlmClient, LlmResponseOptions, LlmResult} from "./clients.js";
import {StreamAccumulator} from "./stream.js";

export interface AnthropicStreamConfig {
  apiKey: string;
  baseUrl?: string; // default https://api.anthropic.com
  model: string;
  maxTokens?: number;
  temperature?: number;
  thinkingBudgetTokens?: number; // enable extended thinking (reasoning)
}
export class AnthropicStreamClient implements LlmClient {
  readonly name = "anthropic";
  constructor(private readonly config: AnthropicStreamConfig) {}

  async chatStream(opts: LlmResponseOptions): Promise<LlmResult> {
    return this.stream(opts);
  }
  async stream(opts: LlmResponseOptions): Promise<LlmResult> {
    const acc = new StreamAccumulator();
    let inp=0,out=0;
    const base = (this.config.baseUrl ?? "https://api.anthropic.com").replace(/\/+$/, "");
    const url = base + "/v1/messages";
    const body: Record<string, unknown> = {
      model: this.config.model,
      max_tokens: this.config.maxTokens ?? 4096,
      messages: this.buildMessages(opts),
      stream: true,
    };
    const sys = this.extractSystem(opts);
    if (sys) body.system = sys;
    if (this.config.temperature != null) body.temperature = this.config.temperature;
    if (this.config.thinkingBudgetTokens) {
      body.thinking = {type: "enabled", budget_tokens: this.config.thinkingBudgetTokens};
    }
    const headers: Record<string, string> = {
      "x-api-key": this.config.apiKey,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    };
    let resp: Response;
    try {
      resp = await fetch(url, {method: "POST", headers, body: JSON.stringify(body), signal: opts.signal});
    } catch (e: any) {
      return {text: "", reasoning: ""};
    }
    if (!resp.ok) {
      const text = await resp.text().catch(() => "");
      throw new Error("LLM HTTP " + resp.status + ": " + text.slice(0, 500));
    }
    const reader = resp.body?.getReader();
    if (reader) {
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
          this.processSseLine(line, acc, (i,o) => { if(i!=null)inp=i; if(o!=null)out=o; }, opts);
        }
      }
    }
    const res = acc.getResult();
    const llmResult: LlmResult = {text: res.text, reasoning: res.reasoning};
    if (inp || out) llmResult.usage = {promptTokens: inp, completionTokens: out};
    return llmResult;
  }
  private buildMessages(opts: LlmResponseOptions): Array<Record<string, unknown>> {
    const msgs: Array<Record<string, unknown>> = [];
    for (const m of opts.messages) {
      if (!m.content.trim() || m.role === "system") continue;
      msgs.push({role: m.role, content: m.content});
    }
    return msgs;
  }
  private extractSystem(opts: LlmResponseOptions): string {
    const s = opts.messages.find((m) => m.role === "system" && m.content.trim());
    return s ? s.content.trim() : "";
  }

  private processSseLine(
    line: string,
    acc: StreamAccumulator,
    onUsage: (input?: number, output?: number) => void,
    opts: LlmResponseOptions,
  ): void {
    const data = line.startsWith("data: ") ? line.substring(6) : null;
    if (!data) return;
    let json: any;
    try { json = JSON.parse(data); } catch { return; }
    if (typeof json !== "object" || json === null) return;
    const t = json.type;
    if (t === "message_start") {
      const u = json.message?.usage;
      if (u) onUsage(u.input_tokens ?? 0, undefined);
    } else if (t === "content_block_delta") {
      const d = json.delta;
      if (!d) return;
      if (d.type === "text_delta" && typeof d.text === "string") acc.pushText(d.text);
      else if (d.type === "thinking_delta" && typeof d.thinking === "string") {
        opts.onReasoningDelta?.(d.thinking); acc.pushReasoningDelta(d.thinking);
      }
    } else if (t === "message_delta") {
      const u = json.usage;
      if (u) onUsage(undefined, u.output_tokens ?? 0);
    }
  }
}
