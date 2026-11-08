import {describe, it, expect} from "vitest";
import {OpenAiStreamClient} from "../../src/llm/openai_stream.js";

function sse(lines: string[]): Response {
  const body = new ReadableStream({start(c){
for(const l of lines)c.enqueue(new TextEncoder().encode(l+"\n"));c.close();}});
  return new Response(body,{headers:{"content-type":"text/event-stream"}});
}

function setupFetch(fn: () => Response): () => void {
  const orig = globalThis.fetch;
  globalThis.fetch = (async () => fn()) as typeof fetch;
  return () => { globalThis.fetch = orig; };
}

describe("R9 stream pipeline e2e", () => {
  it("accumulates content + reasoning + usage", async () => {
    const stop = setupFetch(() => sse([
      'data: {"choices":[{"delta":{"content":"Hi"}}]}',
      'data: {"choices":[{"delta":{"reasoning_content":"x"}}]}',
      'data: {"usage":{"prompt_tokens":5,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":2}}}',
    ]));
    const client = new OpenAiStreamClient({apiKey:"k",model:"gpt-4o"});
    const out = await client.stream({modelConfig:{provider:"openai",model:"gpt-4o"},messages:[{role:"user",content:"hi"}]});
    expect(out.text).toBe("Hi");
    expect(out.reasoning).toBe("x");
    expect(out.usage?.promptTokens).toBe(5);
    expect(out.usage?.completionTokens).toBe(10);
    expect(out.usage?.cachedTokens).toBe(2);
    stop();
  });
});
