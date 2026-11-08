import {describe, it, expect} from "vitest";
import {AnthropicStreamClient} from "../../src/llm/anthropic_stream.js";

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
describe("Anthropic stream e2e", () => {
  it("accumulates text + thinking + usage from Anthropic SSE", async () => {
    const lines = [
      'data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}',
      'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"think"}}',
      'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}',
      'data: {"type":"message_delta","usage":{"output_tokens":10}}',
    ];
    const stop = setupFetch(() => sse(lines));
    const c = new AnthropicStreamClient({apiKey:"k",model:"claude-3"});
    const out = await c.stream({modelConfig:{provider:"anthropic",model:"claude-3"},messages:[{role:"user",content:"hi"}]});
    expect(out.text).toBe("Hello");
    expect(out.reasoning).toBe("think");
    expect(out.usage?.promptTokens).toBe(5);
    expect(out.usage?.completionTokens).toBe(10);
    stop();
  });
  it("system message extracted to top-level field", async () => {
    let captured: Record<string, unknown> | null = null;
    const origFetch = globalThis.fetch;
    globalThis.fetch = (async (_u: any, init: any) => {
      if (init?.body) captured = JSON.parse(init.body);
      return sse(['data: {"type":"message_stop"}']);
    }) as typeof fetch;
    const c = new AnthropicStreamClient({apiKey:"k",model:"claude-3"});
    await c.stream({modelConfig:{provider:"anthropic",model:"claude-3"},messages:[
      {role:"system",content:"be brief"},{role:"user",content:"hi"}]});
    globalThis.fetch = origFetch;
    expect(captured?.system).toBe("be brief");
    const msgs = (captured?.messages ?? []) as any[];
    expect(msgs.length).toBe(1);
    expect(msgs[0].role).toBe("user");
  });
});
