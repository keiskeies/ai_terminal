// Unit tests for llm/ollama_stream.ts (OllamaStreamClient).
// Hermetic: globalThis.fetch is replaced with a recording fake returning a
// canned SSE Response, so the full request-construction + stream-decoding
// contract is pinned with no network. OllamaStreamClient is a thin subclass
// of OpenAiStreamClient, so the tests focus on exactly what the subclass
// changes: the name, the default base URL, the placeholder API key, and
// option pass-through - plus one end-to-end SSE accumulation to prove the
// inherited pipeline stays wired.

import {describe, it, expect} from "vitest";
import {OllamaStreamClient} from "../src/llm/ollama_stream.js";

interface RecordedRequest {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

function sse(lines: string[]): Response {
  const body = new ReadableStream({
    start(c) {
      for (const l of lines) c.enqueue(new TextEncoder().encode(l + "\n"));
      c.close();
    },
  });
  return new Response(body, {headers: {"content-type": "text/event-stream"}});
}

function setupFetch(response: Response, sink: RecordedRequest[]): () => void {
  const orig = globalThis.fetch;
  globalThis.fetch = (async (url: unknown, init: unknown) => {
    const i = (init ?? {}) as {headers?: Record<string, string>; body?: string};
    sink.push({
      url: String(url),
      headers: i.headers ?? {},
      body: i.body ? JSON.parse(i.body) : {},
    });
    return response;
  }) as typeof fetch;
  return () => { globalThis.fetch = orig; };
}

const opts = {
  modelConfig: {provider: "ollama", model: "qwen2"} as never,
  messages: [{role: "user" as const, content: "hi"}],
};

describe("OllamaStreamClient identity", () => {
  it("is named ollama (not openai)", () => {
    expect(new OllamaStreamClient({model: "qwen2"}).name).toBe("ollama");
  });
});

describe("request construction", () => {
  it("defaults to the local Ollama endpoint with a placeholder bearer key", async () => {
    const reqs: RecordedRequest[] = [];
    const stop = setupFetch(sse(['data: {"choices":[{"delta":{"content":"ok"}}]}']), reqs);
    try {
      const client = new OllamaStreamClient({model: "qwen2"});
      const out = await client.stream(opts);
      expect(out.text).toBe("ok");
      expect(reqs.length).toBe(1);
      expect(reqs[0].url).toBe("http://127.0.0.1:11434/v1/chat/completions");
      expect(reqs[0].headers["Authorization"]).toBe("Bearer ollama");
      expect(reqs[0].headers["Content-Type"]).toBe("application/json");
      expect(reqs[0].body.model).toBe("qwen2");
      expect(reqs[0].body.stream).toBe(true);
      // OpenAI stream_options remain in play (inherited retryable flow).
      expect(reqs[0].body.stream_options).toEqual({include_usage: true});
    } finally {
      stop();
    }
  });

  it("honors a custom baseUrl and strips trailing slashes", async () => {
    const reqs: RecordedRequest[] = [];
    const stop = setupFetch(sse(["data: [DONE]"].map((l) => l)), reqs);
    try {
      const client = new OllamaStreamClient({
        baseUrl: "http://gpu-box:11434/v1/", model: "llama3",
      });
      await client.stream(opts);
      expect(reqs[0].url).toBe("http://gpu-box:11434/v1/chat/completions");
    } finally {
      stop();
    }
  });

  it("passes temperature and maxTokens through as max_tokens", async () => {
    const reqs: RecordedRequest[] = [];
    const stop = setupFetch(sse(["data: [DONE]"]), reqs);
    try {
      const client = new OllamaStreamClient({
        model: "qwen2", temperature: 0.2, maxTokens: 512,
      });
      await client.stream(opts);
      expect(reqs[0].body.temperature).toBe(0.2);
      expect(reqs[0].body.max_tokens).toBe(512);
    } finally {
      stop();
    }
  });

  it("omits temperature / max_tokens when unset", async () => {
    const reqs: RecordedRequest[] = [];
    const stop = setupFetch(sse(["data: [DONE]"]), reqs);
    try {
      const client = new OllamaStreamClient({model: "qwen2"});
      await client.stream(opts);
      expect("temperature" in reqs[0].body).toBe(false);
      expect("max_tokens" in reqs[0].body).toBe(false);
    } finally {
      stop();
    }
  });

  it("skips blank message content (Dart empty-history parity)", async () => {
    const reqs: RecordedRequest[] = [];
    const stop = setupFetch(sse(["data: [DONE]"]), reqs);
    try {
      const client = new OllamaStreamClient({model: "qwen2"});
      await client.stream({
        modelConfig: {provider: "ollama", model: "qwen2"} as never,
        messages: [
          {role: "system", content: "keep"},
          {role: "user", content: "   "},
        ],
      });
      const msgs = reqs[0].body.messages as Array<{role: string; content: string}>;
      expect(msgs.length).toBe(1);
      expect(msgs[0].content).toBe("keep");
    } finally {
      stop();
    }
  });
});

describe("SSE decoding through the inherited pipeline", () => {
  it("accumulates content, reasoning and usage chunks", async () => {
    const reqs: RecordedRequest[] = [];
    const stop = setupFetch(sse([
      'data: {"choices":[{"delta":{"content":"He"}}]}',
      'data: {"choices":[{"delta":{"content":"llo"}}]}',
      'data: {"choices":[{"delta":{"reasoning":"think "}}]}',
      'data: {"usage":{"prompt_tokens":3,"completion_tokens":7}}',
    ]), reqs);
    try {
      const client = new OllamaStreamClient({model: "qwen2"});
      const out = await client.stream(opts);
      expect(out.text).toBe("Hello");
      expect(out.reasoning).toBe("think ");
      expect(out.usage?.promptTokens).toBe(3);
      expect(out.usage?.completionTokens).toBe(7);
    } finally {
      stop();
    }
  });
});
