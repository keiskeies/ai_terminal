// Unit tests for WebSearchTool + the web_search helper functions
// (merge/dedup, URL normalization, error classification, config loading).
// No real HTTP calls are made: backends are mocked where possible; the
// structural helpers (normalizeSearchUrl, mergeSearchResults, error classes)
// are tested directly.
import {describe,it,expect} from "vitest";
import {tmpdir} from "os";
import {join} from "path";
import {
  WebSearchTool,
  normalizeSearchUrl,
  mergeSearchResults,
  WebSearchQuotaError,
  WebSearchTransientError,
  WebSearchCancelledError,
  WebSearchResponse,
  providerDisplayName,
  loadWebSearchConfig,
  type WebSearchResult,
  type WebSearchBatch,
  type WebSearchProvider,
} from "../src/tools/web_search.js";
import {ToolArgs} from "../src/tools/tool_args.js";

function args(obj: Record<string, unknown>): ToolArgs { return ToolArgs.wrap(obj); }

describe("WebSearchTool tool metadata", () => {
  it("has correct name, kind, scope, and param schema", () => {
    const tool = new WebSearchTool();
    expect(tool.name).toBe("web_search");
    expect(tool.kind).toBe("network");
    expect(tool.scope).toBe("all");
    expect(tool.recordsChanges).toBe(false);
    const schema = tool.toJsonSchema()!;
    expect(schema.type).toBe("object");
    expect(schema.required).toContain("query");
  });
  it("rejects empty query", async () => {
    const tool = new WebSearchTool();
    const r = await tool.execute(args({query:""}), {} as any);
    expect(r.success).toBe(false);
    expect(r.error).toContain("query");
  });
});

describe("normalizeSearchUrl", () => {
  it("lowercases host and removes default ports", () => {
    expect(normalizeSearchUrl("HTTPS://WWW.Example.com:443/path")).toBe("example.com/path");
    expect(normalizeSearchUrl("http://Example.com:80/")).toBe("example.com/");
  });
  it("strips tracking parameters", () => {
    const url = normalizeSearchUrl("https://example.com/page?utm_source=x&gclid=y&id=42");
    expect(url).toBe("example.com/page?id=42");
  });
  it("sorts remaining params and lowercases keys", () => {
    expect(normalizeSearchUrl("https://a.com?Zebra=1&apple=2")).toBe("a.com/?apple=2&zebra=1");
  });
  it("returns lowercased non-HTTP scheme URLs unchanged-ish", () => {
    expect(normalizeSearchUrl("ftp://X.com/Y")).toBe("ftp://x.com/y");
  });
  it("trailing slash on root is removed", () => {
    expect(normalizeSearchUrl("https://a.com/")).toBe("a.com/");
    expect(normalizeSearchUrl("https://a.com//")).toBe("a.com/");
  });
});

describe("mergeSearchResults", () => {
  function mkResults(provider: WebSearchProvider, urlToTitle: Record<string,string>): WebSearchResult[] {
    return Object.entries(urlToTitle).map(([url, title], i) => ({
      title, url, snippet: "snip", sources: [], bestRank: i,
    }));
  }
  it("dedupes by normalized URL across backends", () => {
    const a: WebSearchBatch = {provider:"brave", results: mkResults("brave", {"https://x.com/a":"A"})};
    const b: WebSearchBatch = {provider:"tavily", results: mkResults("tavily", {"https://x.com/a":"A2"})};
    const merged = mergeSearchResults([a, b], 10);
    expect(merged.length).toBe(1);
    expect(merged[0].url).toBe("https://x.com/a");
    expect(merged[0].sources).toHaveLength(2);
    expect(merged[0].title).toBe("A");
  });
  it("prefers more-sourced results over fewer", () => {
    const a: WebSearchBatch = {provider:"brave", results: [
      {title:"X1", url:"https://x.com/1", snippet:"", sources:[], bestRank:0},
    ]};
    const b: WebSearchBatch = {provider:"tavily", results: [
      {title:"X2", url:"https://x.com/1", snippet:"", sources:[], bestRank:0},
      {title:"Y",  url:"https://y.com/2", snippet:"", sources:[], bestRank:1},
    ]};
    const merged = mergeSearchResults([a, b], 10);
    expect(merged[0].url).toBe("https://x.com/1");
    expect(merged[0].sources).toHaveLength(2);
    expect(merged[1].url).toBe("https://y.com/2");
    expect(merged[1].sources).toHaveLength(1);
  });
  it("caps at limit (max 20)", () => {
    const many: WebSearchBatch = {provider:"brave", results:
      Array.from({length:25},(_,i)=>({title:"t", url:"https://a.com/"+i, snippet:"", sources:[], bestRank:i}))};
    const merged = mergeSearchResults([many], 100);
    expect(merged.length).toBe(20);
  });
  it("returns empty array for zero limit", () => {
    const merged = mergeSearchResults([], 0);
    expect(merged.length).toBe(0);
  });
});

describe("error classes", () => {
  it("WebSearchQuotaError has provider + permanent flag", () => {
    const e = new WebSearchQuotaError("no key", "exa", true);
    expect(e.provider).toBe("exa");
    expect(e.permanent).toBe(true);
    expect(e.message).toBe("no key");
  });
  it("WebSearchTransientError and WebSearchCancelledError are Error subclasses", () => {
    expect(new WebSearchTransientError("x")).toBeInstanceOf(Error);
    expect(new WebSearchCancelledError("x")).toBeInstanceOf(Error);
  });
});

describe("WebSearchResponse", () => {
  it("exposes successCount/failureCount/failures getters", () => {
    const resp = new WebSearchResponse({
      results: [],
      reports: [
        {provider:"brave", ok:true, resultCount:3, elapsedMs:100, permanent:false},
        {provider:"exa",   ok:false, resultCount:0, elapsedMs:50,  error:"401", permanent:true},
      ],
    });
    expect(resp.successCount).toBe(1);
    expect(resp.failureCount).toBe(1);
    expect(resp.failures).toHaveLength(1);
    expect(resp.failures[0].provider).toBe("exa");
  });
});

describe("loadWebSearchConfig (Node file-backed)", () => {
  it("returns a config with enabledBackends as a non-empty array", () => {
    const cfg = loadWebSearchConfig();
    expect(Array.isArray(cfg.enabledBackends)).toBe(true);
    expect(cfg.enabledBackends.length).toBeGreaterThan(0);
    expect(cfg.numResults).toBeGreaterThanOrEqual(1);
    expect(cfg.numResults).toBeLessThanOrEqual(20);
  });
});

describe("providerDisplayName", () => {
  it("returns readable names for known providers", () => {
    expect(providerDisplayName("exa")).toBe("Exa");
    expect(providerDisplayName("bingRss")).toBe("Bing RSS");
    expect(providerDisplayName("deepseek")).toBe("DeepSeek");
  });
});
