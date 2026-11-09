import {describe, it, expect} from "vitest";
import {OpenAiStreamClient} from "../../src/llm/openai_stream.js";
import {StreamAccumulator} from "../../src/llm/stream.js";
import {parse} from "../../src/react/parser.js";
import {stableId} from "../../src/utils/stable_hash.js";

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
    it("R8 empty/null content deltas are skipped (Dart toString().isNotEmpty parity)", async () => {
    // Dart gates on content != null && content.toString().isNotEmpty. The client now
    // mirrors that explicitly (pushText self-guards empty pushes too, so this also
    // pins the behavior against future accumulator changes).
    const stop = setupFetch(() => sse([
      'data: {"choices":[{"delta":{"content":""}}]}',
      'data: {"choices":[{"delta":{"content":null}}]}',
      'data: {"choices":[{"delta":{"content":"real"}}]}',
      'data: {"choices":[{"delta":{}}]}',
      'data: {"choices":[{"delta":{"content":""}}]}',
    ]));
    const client = new OpenAiStreamClient({apiKey:"k",model:"gpt-4o"});
    const out = await client.stream({modelConfig:{provider:"openai",model:"gpt-4o"},messages:[{role:"user",content:"hi"}]});
    expect(out.text).toBe("real");
    stop();
  });
  it("R9 multi-line concat: chunked stream reconstructs + parses", () => {
      const full = "\u601d\u8003: check disk\n\u547d\u4ee4: ls -la\n";
      const chunks = [full.slice(0, 2), full.slice(2)];
      const acc = new StreamAccumulator();
      for (const c of chunks) acc.pushText(c);
      expect(acc.getResult().text).toBe(full);
      const evts = parse(full);
      expect(evts.map((e) => e.type)).toEqual(["thought", "command"]);
    });
    it("R9 stableId byte-parity: 64-bit Dart hash, no int32 collisions", () => {
      // Reference values locked against an independent Python FNV-1a-64 oracle
      // that replicates Dart's (hash*0x100000001b3)&0x7FFFFFFFFFFFFFFF loop.
      expect(stableId("thought","\u9700\u8981\u67e5\u770b\u76ee\u5f55")).toBe("evt_4ab5285dc89fef7b");
      expect(stableId("command","ls -la /tmp")).toBe("evt_4126a2a91fa730c9");
      expect(stableId("command","uname -a")).toBe("evt_1a983973eaa2b606");
      expect(stableId("ask","A|B|C")).toBe("evt_57e4ddc57dd32128");
      // Deterministic: same input, same id, across calls.
      expect(stableId("command","uname -a")).toBe(stableId("command","uname -a"));
    });
  });
