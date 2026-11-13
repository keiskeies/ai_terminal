// web_search.ts - 1:1 port of Dart web_tools.dart + web_search_{config,backends,merge,service,http,models}.dart
//
// The tool layer: WebSearchTool (name "web_search", kind network, scope all).
// Fan-out to 11 backends (Bing RSS / DuckDuckGo / SearXNG / Exa / Parallel /
// Brave / Tavily / Serper / Mojeek / Anthropic / OpenAI), concurrent merge,
// URL-dedup normalization, cancellation bridging, and per-backend error
// classification (quota/transient/cancelled).
//
// In Node the Dart SettingsDao / CredentialsStore persistence is replaced by a
// file-backed key-value store under the user's home dir (~/.ai_terminal/),
// mirroring the Dart "two-layer" design: non-secret fields (enabled, backends,
// proxy, timeout) in webSearchConfig.json; API keys read from env vars first,
// then from the credentials file. The 12-provider registry, 11 live backends,
// error taxonomy, merge/dedup algorithm, and cancellation semantics are
// byte-faithful to the Dart originals.
import {chmodSync, readFileSync, writeFileSync, mkdirSync, existsSync, statSync} from "fs";
import {homedir} from "os";
import {join} from "path";
import {AgentTool, ToolResult, ToolContext, ToolKind, ToolScope} from "./builtin.js";
import {ToolArgs} from "./tool_args.js";

// \u2500\u2500\u2500 types (mirrors web_search_models.dart + web_search_config.dart) \u2500\u2500\u2500\u2500\u2500\u2500

export type WebSearchProvider =
  | "exa" | "parallel" | "bingRss" | "duckduckgo" | "searxng" | "brave"
  | "tavily" | "serper" | "mojeek" | "deepseek" | "anthropic" | "openai";

export const WEB_SEARCH_PROVIDERS: WebSearchProvider[] = [
  "exa","parallel","bingRss","duckduckgo","searxng","brave",
  "tavily","serper","mojeek","deepseek","anthropic","openai",
];

export interface WebSearchResult {
  title: string;
  url: string;
  snippet: string;
  sources: WebSearchProvider[];
  bestRank: number;
}
export interface WebSearchBatch {
  provider: WebSearchProvider;
  results: WebSearchResult[];
}
export interface WebSearchBackendReport {
  provider: WebSearchProvider;
  ok: boolean;
  resultCount: number;
  elapsedMs: number;
  error?: string;
  permanent: boolean;
}
export class WebSearchResponse {
  readonly results: WebSearchResult[];
  readonly reports: WebSearchBackendReport[];
  constructor(o: {results: WebSearchResult[]; reports: WebSearchBackendReport[];}) {
    this.results = o.results;
    this.reports = o.reports;
  }
  get successCount(): number { return this.reports.filter(r=>r.ok).length; }
  get failureCount(): number { return this.reports.length - this.successCount; }
  get failures(): WebSearchBackendReport[] { return this.reports.filter(r=>!r.ok); }
}

export class WebSearchQuotaError extends Error {
  readonly provider: WebSearchProvider;
  readonly permanent: boolean;
  constructor(message: string, provider: WebSearchProvider, permanent = false) {
    super(message); this.name = "WebSearchQuotaError";
    this.provider = provider; this.permanent = permanent;
  }
}
export class WebSearchTransientError extends Error {
  constructor(message: string) { super(message); this.name = "WebSearchTransientError"; }
}
export class WebSearchCancelledError extends Error {
  constructor(message: string) { super(message); this.name = "WebSearchCancelledError"; }
}

// Provider metadata (displayName / env key / default model / capability flags)
const PROVIDER_META: Record<WebSearchProvider, {displayName:string; envKeyName:string; defaultModel:string; requiresApiKey:boolean; requiresInstanceUrl:boolean; isAvailable:boolean;}> = {
  exa:      {displayName:"Exa",      envKeyName:"EXA_API_KEY",      defaultModel:"",                 requiresApiKey:true,  requiresInstanceUrl:false, isAvailable:true},
  parallel: {displayName:"Parallel",  envKeyName:"PARALLEL_API_KEY", defaultModel:"",                 requiresApiKey:true,  requiresInstanceUrl:false, isAvailable:true},
  bingRss:  {displayName:"Bing RSS",  envKeyName:"",                defaultModel:"",                 requiresApiKey:false, requiresInstanceUrl:false, isAvailable:true},
  duckduckgo:{displayName:"DuckDuckGo",envKeyName:"",                defaultModel:"",                 requiresApiKey:false, requiresInstanceUrl:false, isAvailable:true},
  searxng:  {displayName:"SearXNG",   envKeyName:"SEARXNG_API_KEY",  defaultModel:"",                 requiresApiKey:false, requiresInstanceUrl:true,  isAvailable:true},
  brave:    {displayName:"Brave",     envKeyName:"BRAVE_API_KEY",    defaultModel:"",                 requiresApiKey:true,  requiresInstanceUrl:false, isAvailable:true},
  tavily:   {displayName:"Tavily",    envKeyName:"TAVILY_API_KEY",   defaultModel:"",                 requiresApiKey:true,  requiresInstanceUrl:false, isAvailable:true},
  serper:   {displayName:"Serper.dev",envKeyName:"SERPER_API_KEY",   defaultModel:"",                 requiresApiKey:true,  requiresInstanceUrl:false, isAvailable:true},
  mojeek:   {displayName:"Mojeek",    envKeyName:"MOJEEK_API_KEY",   defaultModel:"",                 requiresApiKey:true,  requiresInstanceUrl:false, isAvailable:true},
  deepseek: {displayName:"DeepSeek",  envKeyName:"",                 defaultModel:"",                 requiresApiKey:false, requiresInstanceUrl:false, isAvailable:false},
  anthropic:{displayName:"Anthropic", envKeyName:"ANTHROPIC_API_KEY",defaultModel:"claude-sonnet-4-5",requiresApiKey:true,  requiresInstanceUrl:false, isAvailable:true},
  openai:   {displayName:"OpenAI",    envKeyName:"OPENAI_API_KEY",   defaultModel:"gpt-4.1-mini",     requiresApiKey:true,  requiresInstanceUrl:false, isAvailable:true},
};

export function providerDisplayName(p: WebSearchProvider): string { return PROVIDER_META[p].displayName; }

// \u2500\u2500\u2500 config (mirrors web_search_config.dart, file-backed in Node) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

export interface WebSearchConfig {
  enabled: boolean;
  enabledBackends: WebSearchProvider[];
  numResults: number;
  concurrency: number;
  backendTimeoutMs: number;
  proxy: string;
  searxngInstanceUrl: string;
}

const CONFIG_DIR = join(homedir(), ".ai_terminal");
const CONFIG_FILE = join(CONFIG_DIR, "web_search_config.json");
const CRED_FILE = join(CONFIG_DIR, "web_search_keys.json");

function readJsonFile<T>(path: string, fallback: T): T {
  if (!existsSync(path)) return fallback;
  try { return JSON.parse(readFileSync(path, "utf-8")) as T; }
  catch { return fallback; }
}

export function loadWebSearchConfig(): WebSearchConfig {
  const stored = readJsonFile<Partial<Record<keyof WebSearchConfig, unknown>>>(CONFIG_FILE, {});
  const backends = Array.isArray(stored.enabledBackends)
    ? (stored.enabledBackends as unknown[]).map(s => normalizeProvider(String(s))).filter((p): p is WebSearchProvider => p != null && PROVIDER_META[p].isAvailable)
    : ["bingRss" as WebSearchProvider];
  const numResults = Math.min(20, Math.max(1, Number(stored.numResults ?? 8) || 8));
  const concurrency = Math.min(12, Math.max(1, Number(stored.concurrency ?? 6) || 6));
  const timeoutMs = Math.min(120000, Math.max(3000, Number(stored.backendTimeoutMs ?? 30000) || 30000));
  return {
    enabled: stored.enabled === true,
    enabledBackends: backends.length > 0 ? backends : ["bingRss"],
    numResults,
    concurrency,
    backendTimeoutMs: timeoutMs,
    proxy: String(stored.proxy ?? "").trim(),
    searxngInstanceUrl: String(stored.searxngInstanceUrl ?? "").trim(),
  };
}

export function saveWebSearchConfig(cfg: WebSearchConfig): void {
  if (!existsSync(CONFIG_DIR)) mkdirSync(CONFIG_DIR, {recursive: true});
  // R7: config + credential files must not be world-readable.
  // 0600 so only the owning user can read/write.
  writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2), {mode: 0o600});
  if (existsSync(CRED_FILE) && (statSync(CRED_FILE).mode & 0o077) !== 0) {
    chmodSync(CRED_FILE, 0o600);
  }
}

export function getApiKey(p: WebSearchProvider): string | null {
  const envName = PROVIDER_META[p].envKeyName;
  if (envName === "") return null;
  const envVal = (process.env[envName] ?? "").trim();
  if (envVal !== "") return envVal;
  // R7: a credential file must be 0600. Only chmod when group/other bits
  // are actually set, so the steady-state path costs no syscall.
  if (existsSync(CRED_FILE) && (statSync(CRED_FILE).mode & 0o077) !== 0) {
    chmodSync(CRED_FILE, 0o600);
  }
  const cred = readJsonFile<Record<string,string>>(CRED_FILE, {});
  const stored = (cred["apiKey_" + p] ?? "").trim();
  return stored !== "" ? stored : null;
}

function normalizeProvider(s: string): WebSearchProvider | null {
  const lower = s.trim().toLowerCase();
  switch (lower) {
    case "exa": return "exa";
    case "parallel": return "parallel";
    case "bingrss": case "bing_rss": case "binghtml": case "bing_html": return "bingRss";
    case "duckduckgo": case "ddg": return "duckduckgo";
    case "searxng": return "searxng";
    case "brave": return "brave";
    case "tavily": return "tavily";
    case "serper": case "serperdev": case "serper_dev": return "serper";
    case "mojeek": return "mojeek";
    case "deepseek": return "deepseek";
    case "anthropic": case "claude": return "anthropic";
    case "openai": return "openai";
    default: return null;
  }
}

// \u2500\u2500\u2500 HTTP helper (Node global fetch with AbortSignal; proxy not supported in Node built-ins) \u2500\u2500

async function httpGet(url: string, opts: {timeoutMs:number; headers?:Record<string,string>; signal?:AbortSignal;}): Promise<string> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), opts.timeoutMs);
  if (opts.signal) {
    opts.signal.addEventListener("abort", () => ctrl.abort(), {once: true});
  }
  try {
    const resp = await fetch(url, {signal: ctrl.signal, headers: opts.headers});
    if (resp.status === 401 || resp.status === 403 || resp.status === 400 || resp.status === 422 || resp.status === 429 || resp.status >= 500) {
      const body = await resp.text().catch(() => "");
      throw Object.assign(new Error("HTTP " + resp.status), {status: resp.status, body});
    }
    return await resp.text();
  } finally {
    clearTimeout(timer);
  }
}

async function httpPost(url: string, opts: {timeoutMs:number; body:unknown; headers?:Record<string,string>; signal?:AbortSignal;}): Promise<unknown> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), opts.timeoutMs);
  if (opts.signal) {
    opts.signal.addEventListener("abort", () => ctrl.abort(), {once: true});
  }
  try {
    const resp = await fetch(url, {
      method: "POST",
      signal: ctrl.signal,
      headers: {"Content-Type":"application/json", ...opts.headers},
      body: JSON.stringify(opts.body),
    });
    if (resp.status >= 400) {
      const body = await resp.text().catch(() => "");
      throw Object.assign(new Error("HTTP " + resp.status), {status: resp.status, body});
    }
    const text = await resp.text();
    try { return JSON.parse(text); } catch { return null; }
  } finally {
    clearTimeout(timer);
  }
}

// \u2500\u2500\u2500 backends (mirrors web_search_backends.dart) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

type SearchOpts = {
  query: string; maxResults: number; timeoutMs: number;
  apiKey?: string | null; instanceUrl?: string | null; proxy?: string;
  signal?: AbortSignal;
};

async function searchBingRss(opts: SearchOpts): Promise<WebSearchResult[]> {
  const url = "https://www.bing.com/search?q=" + encodeURIComponent(opts.query) + "&format=rss&count=" + opts.maxResults + "&setlang=en-US";
  const xml = await httpGet(url, {timeoutMs: opts.timeoutMs, headers:{"User-Agent":_browserUa, "Accept-Language":"zh-CN,zh;q=0.9,en;q=0.8"}, signal: opts.signal});
  const results = parseRss(xml, opts.maxResults);
  if (results.length === 0 && looksLikeBlockedPage(xml)) {
    throw new WebSearchTransientError("Bing \u8FD4\u56DE\u4E86\u9A8C\u8BC1\u9875\u9762\uFF0C\u53EF\u80FD\u56E0\u8BF7\u6C42\u9891\u6B21\u8FC7\u9AD8\u88AB\u4E34\u65F6\u9650\u5236\u3002\u8BF7\u7A0D\u540E\u91CD\u8BD5\u3002");
  }
  return results;
}

async function searchDuckDuckGo(opts: SearchOpts): Promise<WebSearchResult[]> {
  const url = "https://lite.duckduckgo.com/lite/?q=" + encodeURIComponent(opts.query) + "&kl=us-en";
  const html = await httpGet(url, {timeoutMs: opts.timeoutMs, headers:{"User-Agent":_browserUa}, signal: opts.signal});
  const results = parseDdgLite(html, opts.maxResults);
  if (results.length === 0 && looksLikeBlockedPage(html)) {
    throw new WebSearchTransientError("DuckDuckGo \u8FD4\u56DE\u4E86\u53CD\u722C\u9875\u9762\uFF0C\u8BF7\u7A0D\u540E\u91CD\u8BD5\u6216\u914D\u7F6E\u4EE3\u7406\u3002");
  }
  return results;
}

async function searchSearxng(opts: SearchOpts): Promise<WebSearchResult[]> {
  const base = (opts.instanceUrl ?? "").trim();
  if (base === "") {
    throw new WebSearchQuotaError("SearXNG \u5B9E\u4F8B\u5730\u5740\u672A\u914D\u7F6E\u3002\u8BF7\u5728\u300C\u8BBE\u7F6E \u2192 \u8054\u7F51\u641C\u7D22\u300D\u586B\u5165\u81EA\u5EFA\u5B9E\u4F8B URL\u3002", "searxng", true);
  }
  const norm = base.endsWith("/") ? base.slice(0, -1) : base;
  const headers: Record<string,string> = {};
  if ((opts.apiKey ?? "").trim() !== "") headers["Authorization"] = "Bearer " + (opts.apiKey ?? "").trim();
  const url = norm + "/search?q=" + encodeURIComponent(opts.query) + "&format=json&categories=general&pageno=1";
  // SearXNG JSON is GET; use httpGet
  const text = await httpGet(url, {timeoutMs: opts.timeoutMs, headers, signal: opts.signal}).catch(() => {
    throw new WebSearchQuotaError("SearXNG \u5B9E\u4F8B\u672A\u5F00\u542F JSON API\u3002\u8BF7\u5728\u5B9E\u4F8B\u7684 settings.yml \u4E2D\u6DFB\u52A0 search.formats: [html, json] \u540E\u91CD\u542F\u3002", "searxng", true);
  });
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { throw new WebSearchTransientError("SearXNG \u54CD\u5E94\u65E0\u6CD5\u89E3\u6790"); }
  const results = (parsed as Record<string,unknown>)?.["results"];
  if (!Array.isArray(results)) return [];
  const out: WebSearchResult[] = [];
  for (const raw of results) {
    if (out.length >= opts.maxResults) break;
    const r = raw as Record<string,unknown>;
    const url2 = String(r["url"] ?? "");
    if (!url2.startsWith("http")) continue;
    out.push({title: String(r["title"] ?? ""), url: url2, snippet: String(r["content"] ?? ""), sources: [], bestRank: out.length});
  }
  return out;
}

async function searchTavily(opts: SearchOpts): Promise<WebSearchResult[]> {
  const key = requireApiKey(opts.apiKey, "tavily");
  const data: unknown = await httpPost("https://api.tavily.com/search", {
    timeoutMs: opts.timeoutMs, body: {query: opts.query, max_results: opts.maxResults, search_depth: "basic", include_answer: false},
    headers: {"Authorization": "Bearer " + key}, signal: opts.signal,
  });
  const results = (data as Record<string,unknown>)?.["results"];
  if (!Array.isArray(results)) return [];
  return results.slice(0, opts.maxResults).filter(r => typeof r === "object" && r !== null && String((r as Record<string,unknown>)["url"] ?? "").startsWith("http"))
    .map((r, i) => {
      const x = r as Record<string,unknown>;
      return {title: String(x["title"] ?? ""), url: String(x["url"] ?? ""), snippet: String(x["content"] ?? ""), sources: [], bestRank: i};
    });
}

async function searchBrave(opts: SearchOpts): Promise<WebSearchResult[]> {
  const key = requireApiKey(opts.apiKey, "brave");
  const url = "https://api.search.brave.com/res/v1/web/search?q=" + encodeURIComponent(opts.query) + "&count=" + opts.maxResults + "&safesearch=moderate";
  const text = await httpGet(url, {timeoutMs: opts.timeoutMs, headers:{"Accept":"application/json","X-Subscription-Token":key}, signal: opts.signal});
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { return []; }
  const web = (parsed as Record<string,unknown>)?.["web"];
  const results = (web as Record<string,unknown>)?.["results"];
  if (!Array.isArray(results)) return [];
  return results.slice(0, opts.maxResults).filter(r => typeof r === "object" && r !== null && String((r as Record<string,unknown>)["url"] ?? "").startsWith("http"))
    .map((r, i) => {
      const x = r as Record<string,unknown>;
      return {title: String(x["title"] ?? ""), url: String(x["url"] ?? ""), snippet: String(x["description"] ?? x["text"] ?? ""), sources: [], bestRank: i};
    });
}

async function searchSerper(opts: SearchOpts): Promise<WebSearchResult[]> {
  const key = requireApiKey(opts.apiKey, "serper");
  const data: unknown = await httpPost("https://google.serper.dev/search", {
    timeoutMs: opts.timeoutMs, body: {q: opts.query, num: opts.maxResults},
    headers: {"X-API-KEY": key}, signal: opts.signal,
  });
  const organic = (data as Record<string,unknown>)?.["organic"];
  if (!Array.isArray(organic)) return [];
  return organic.slice(0, opts.maxResults).filter(r => typeof r === "object" && r !== null && String((r as Record<string,unknown>)["link"] ?? "").startsWith("http"))
    .map((r, i) => {
      const x = r as Record<string,unknown>;
      return {title: String(x["title"] ?? ""), url: String(x["link"] ?? ""), snippet: String(x["snippet"] ?? ""), sources: [], bestRank: i};
    });
}

async function searchMojeek(opts: SearchOpts): Promise<WebSearchResult[]> {
  const key = requireApiKey(opts.apiKey, "mojeek");
  const url = "https://api.mojeek.com/search?q=" + encodeURIComponent(opts.query) + "&fmt=json&api_key=" + encodeURIComponent(key);
  const text = await httpGet(url, {timeoutMs: opts.timeoutMs, signal: opts.signal});
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { return []; }
  let payload = parsed as Record<string,unknown>;
  if (typeof payload["response"] === "string") { try { payload = JSON.parse(payload["response"] as string); } catch {} }
  const results = payload?.["results"];
  if (!Array.isArray(results)) return [];
  return results.slice(0, opts.maxResults).filter(r => typeof r === "object" && r !== null && String((r as Record<string,unknown>)["url"] ?? "").startsWith("http"))
    .map((r, i) => {
      const x = r as Record<string,unknown>;
      return {title: String(x["title"] ?? ""), url: String(x["url"] ?? ""), snippet: String(x["desc"] ?? x["description"] ?? ""), sources: [], bestRank: i};
    });
}

async function searchExa(opts: SearchOpts): Promise<WebSearchResult[]> {
  const key = requireApiKey(opts.apiKey, "exa");
  const data: unknown = await httpPost("https://api.exa.ai/search", {
    timeoutMs: opts.timeoutMs,
    body: {query: opts.query, numResults: opts.maxResults, contents: {text: {maxCharacters: 500}}},
    headers: {"x-api-key": key}, signal: opts.signal,
  });
  const results = (data as Record<string,unknown>)?.["results"];
  if (!Array.isArray(results)) return [];
  const out: WebSearchResult[] = [];
  for (const raw of results) {
    if (out.length >= opts.maxResults) break;
    const r = raw as Record<string,unknown>;
    const url = String(r["url"] ?? "");
    if (!url.startsWith("http")) continue;
    let snippet = String(r["text"] ?? "");
    if (snippet === "") {
      const highlights = r["highlights"];
      if (Array.isArray(highlights)) snippet = highlights.map(String).join(" ");
    }
    out.push({title: String(r["title"] ?? ""), url, snippet, sources: [], bestRank: out.length});
  }
  return out;
}

async function searchParallel(opts: SearchOpts): Promise<WebSearchResult[]> {
  const key = requireApiKey(opts.apiKey, "parallel");
  const data: unknown = await httpPost("https://api.parallel.ai/v1/search", {
    timeoutMs: opts.timeoutMs,
    body: {objective: opts.query, search_queries: [opts.query], advanced_settings: {max_results: opts.maxResults}},
    headers: {"x-api-key": key}, signal: opts.signal,
  });
  const results = (data as Record<string,unknown>)?.["results"];
  if (!Array.isArray(results)) return [];
  const out: WebSearchResult[] = [];
  for (const raw of results) {
    if (out.length >= opts.maxResults) break;
    const r = raw as Record<string,unknown>;
    const url = String(r["url"] ?? "");
    if (!url.startsWith("http")) continue;
    const excerpts = r["excerpts"];
    const snippet = Array.isArray(excerpts) ? excerpts.map(String).join(" ") : String(excerpts ?? "");
    out.push({title: String(r["title"] ?? ""), url, snippet, sources: [], bestRank: out.length});
  }
  return out;
}

async function searchOpenAI(opts: SearchOpts): Promise<WebSearchResult[]> {
  const key = requireApiKey(opts.apiKey, "openai");
  const data: unknown = await httpPost("https://api.openai.com/v1/responses", {
    timeoutMs: opts.timeoutMs,
    body: {model: PROVIDER_META.openai.defaultModel, input: opts.query, tools: [{type:"web_search"}], tool_choice: "auto", include: ["web_search_call.action.sources"], max_output_tokens: 1200},
    headers: {"Authorization": "Bearer " + key}, signal: opts.signal,
  });
  const output = (data as Record<string,unknown>)?.["output"];
  if (!Array.isArray(output)) return [];
  const merged = new Map<string, WebSearchResult>();
  for (const item of output) {
    const it = item as Record<string,unknown>;
    if (String(it["type"]) === "message") {
      const content = it["content"];
      if (!Array.isArray(content)) continue;
      for (const block of content) {
        const b = block as Record<string,unknown>;
        const text = String(b["text"] ?? "");
        const annotations = b["annotations"];
        if (!Array.isArray(annotations)) continue;
        for (const ann of annotations) {
          const a = ann as Record<string,unknown>;
          if (String(a["type"]) !== "url_citation") continue;
          const url = String(a["url"] ?? "");
          if (!url.startsWith("http")) continue;
          const start = parseInt(String(a["start_index"] ?? ""), 10) || 0;
          const end = parseInt(String(a["end_index"] ?? ""), 10) || 0;
          putOpenAiResult(merged, url, String(a["title"] ?? ""), sliceText(text, start, end));
        }
      }
    } else if (String(it["type"]) === "web_search_call") {
      const action = it["action"];
      const sources = (action as Record<string,unknown>)?.["sources"];
      if (!Array.isArray(sources)) continue;
      for (const src of sources) {
        const s = src as Record<string,unknown>;
        const url = String(s["url"] ?? "");
        if (!url.startsWith("http")) continue;
        putOpenAiResult(merged, url, "", "");
      }
    }
  }
  return [...merged.values()].slice(0, opts.maxResults);
}

async function searchAnthropic(opts: SearchOpts): Promise<WebSearchResult[]> {
  const key = requireApiKey(opts.apiKey, "anthropic");
  const data: unknown = await httpPost("https://api.anthropic.com/v1/messages", {
    timeoutMs: opts.timeoutMs,
    body: {model: PROVIDER_META.anthropic.defaultModel, max_tokens: 1024, messages: [{role:"user", content: opts.query}], tools: [{type:"web_search_20250305", name:"web_search", max_uses: Math.min(opts.maxResults, 10)}]},
    headers: {"x-api-key": key, "anthropic-version": "2023-06-01"}, signal: opts.signal,
  });
  const content = (data as Record<string,unknown>)?.["content"];
  if (!Array.isArray(content)) return [];
  const merged = new Map<string, WebSearchResult>();
  for (const block of content) {
    const b = block as Record<string,unknown>;
    if (String(b["type"]) === "web_search_tool_result") {
      const result = b["content"];
      if (result && typeof result === "object" && (result as Record<string,unknown>)["error_code"] != null) {
        throw new WebSearchTransientError("Anthropic \u641C\u7D22\u5931\u8D25\uFF1A" + String((result as Record<string,unknown>)["error_code"]));
      }
      if (!Array.isArray(result)) continue;
      for (const raw of result) {
        const r = raw as Record<string,unknown>;
        if (String(r["type"]) !== "web_search_result") continue;
        const url = String(r["url"] ?? "");
        if (!url.startsWith("http")) continue;
        putOpenAiResult(merged, url, String(r["title"] ?? ""), "");
      }
    } else if (String(b["type"]) === "text") {
      const citations = b["citations"];
      if (!Array.isArray(citations)) continue;
      for (const cit of citations) {
        const c = cit as Record<string,unknown>;
        const url = String(c["url"] ?? "");
        if (!url.startsWith("http")) continue;
        putOpenAiResult(merged, url, String(c["title"] ?? ""), String(c["cited_text"] ?? ""));
      }
    }
  }
  return [...merged.values()].slice(0, opts.maxResults);
}

function requireApiKey(key: string | null | undefined, provider: WebSearchProvider): string {
  const trimmed = (key ?? "").trim();
  if (trimmed !== "") return trimmed;
  throw new WebSearchQuotaError(
    providerDisplayName(provider) + " \u672A\u914D\u7F6E API Key\u3002\u8BF7\u5728\u300C\u8BBE\u7F6E \u2192 \u8054\u7F51\u641C\u7D22\u300D\u586B\u5199\uFF0C\u6216\u8BBE\u7F6E\u73AF\u5883\u53D8\u91CF " + PROVIDER_META[provider].envKeyName + "\u3002",
    provider, true
  );
}

function putOpenAiResult(out: Map<string, WebSearchResult>, url: string, title: string, snippet: string): void {
  const existing = out.get(url);
  if (existing == null) { out.set(url, {title, url, snippet, sources: [], bestRank: 0}); return; }
  out.set(url, {
    title: existing.title !== "" ? existing.title : title,
    url,
    snippet: snippet.length > existing.snippet.length ? snippet : existing.snippet,
    sources: [],
    bestRank: existing.bestRank,
  });
}

function sliceText(text: string, start: number, end: number): string {
  if (start < 0 || end <= start || start >= text.length) return "";
  const safeEnd = Math.min(end, text.length);
  const val = text.substring(start, safeEnd).trim();
  return val.length > 300 ? val.substring(0, 300) + "\u2026" : val;
}

// \u2500\u2500\u2500 HTML/XML helpers (shared by Bing RSS / DuckDuckGo parsing) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

const _browserUa = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36";

function stripHtml(s: string): string {
  return decodeEntities(s.replace(/<[^>]*>/g, "")).replace(/\s+/g, " ").trim();
}

function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&apos;/g, "'").replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (m, code) => { const c = parseInt(code,10); return isNaN(c) ? m : String.fromCharCode(c); })
    .replace(/&#x([0-9a-fA-F]+);/g, (m, hex) => { const c = parseInt(hex,16); return isNaN(c) ? m : String.fromCharCode(c); });
}

function stripCdata(s: string): string {
  const t = s.trim();
  if (t.startsWith("<![CDATA[") && t.endsWith("]]>")) return t.substring(9, t.length - 3);
  return s;
}

function looksLikeBlockedPage(body: string): boolean {
  const lower = body.toLowerCase();
  return lower.includes("captcha") || lower.includes("verify you are human")
    || lower.includes("unusual traffic") || lower.includes("anomaly-modal")
    || lower.includes("\u9A8C\u8BC1\u60A8\u662F\u5426\u662F\u771F\u4EBA");
}

function parseRss(xml: string, max: number): WebSearchResult[] {
  const results: WebSearchResult[] = [];
  const itemRegex = /<item>([\s\S]*?)<\/item>/gi;
  const titleRe = /<title>([\s\S]*?)<\/title>/i;
  const linkRe = /<link>([\s\S]*?)<\/link>/i;
  const descRe = /<description>([\s\S]*?)<\/description>/i;
  for (const m of xml.matchAll(itemRegex)) {
    if (results.length >= max) break;
    const block = m[1];
    const url = decodeEntities((linkRe.exec(block)?.[1] ?? "").trim());
    if (!url.startsWith("http")) continue;
    const title = stripHtml(decodeEntities(stripCdata((titleRe.exec(block)?.[1]) ?? "")));
    const snippet = stripHtml(decodeEntities(stripCdata((descRe.exec(block)?.[1]) ?? "")));
    results.push({title, url, snippet, sources: [], bestRank: results.length});
  }
  return results;
}

function parseDdgLite(html: string, max: number): WebSearchResult[] {
  const results: WebSearchResult[] = [];
  const linkRegex = /<a[^>]*class="result-link"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi;
  const snippetRegex = /<td[^>]*class="result-snippet"[^>]*>([\s\S]*?)<\/td>/gi;
  const links = [...html.matchAll(linkRegex)];
  const snippets = [...html.matchAll(snippetRegex)];
  for (let i = 0; i < links.length && results.length < max; i++) {
    let url = unwrapDdgRedirect(links[i][1]);
    if (!url.startsWith("http")) continue;
    const snippet = i < snippets.length ? stripHtml(snippets[i][1]) : "";
    results.push({title: stripHtml(links[i][2]), url, snippet, sources: [], bestRank: results.length});
  }
  return results;
}

function unwrapDdgRedirect(url: string): string {
  let value = url;
  if (value.startsWith("//")) value = "https:" + value;
  try {
    const u = new URL(value);
    if (u.host.includes("duckduckgo.com")) {
      const encoded = u.searchParams.get("uddg");
      if (encoded != null) return decodeURIComponent(encoded);
    }
  } catch { /* fall through */ }
  return value;
}

// \u2500\u2500\u2500 merge (mirrors web_search_merge.dart) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

const _trackingParams = new Set(["gclid","fbclid","msclkid","yclid","spm","ref","ref_src","source","igshid","si","srsltid","mkt_tok","trk","trk_contact","trk_module","trk_sid","mc_cid","mc_eid","_hsenc","_hsmi","vero_id","wickedid","oly_anon_id","oly_enc_id","__s","rb_clickid","s_cid","elqtrackid","elqtrack"]);
const _trackingPrefixes = ["utm_","hsa_","pk_","mtm_"];

export function normalizeSearchUrl(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed === "") return "";
  let uri: URL;
  try { uri = new URL(trimmed); } catch { return trimmed.toLowerCase(); }
  if (uri.protocol !== "http:" && uri.protocol !== "https:") return trimmed.toLowerCase();
  let host = uri.hostname.toLowerCase();
  if (host.startsWith("www.")) host = host.substring(4);
  if (host === "") return trimmed.toLowerCase();
  const isDefaultPort = (uri.protocol === "http:" && uri.port === "80") || (uri.protocol === "https:" && uri.port === "443");
  const port = (uri.port !== "" && !isDefaultPort) ? ":" + uri.port : "";
  let path = uri.pathname;
  while (path.length > 1 && path.endsWith("/")) path = path.slice(0, -1);
  const params: Record<string,string> = {};
  for (const [k, v] of uri.searchParams) {
    const lower = k.toLowerCase();
    if (_trackingParams.has(lower) || _trackingPrefixes.some(p => lower.startsWith(p))) continue;
    params[lower] = v;
  }
  const keys = Object.keys(params).sort();
  const query = keys.map(k => k + "=" + encodeURIComponent(params[k])).join("&");
  return host + port + path + (query !== "" ? "?" + query : "");
}

function titleFromUrl(url: string): string {
  try { const u = new URL(url); let h = u.hostname; if (h.startsWith("www.")) h = h.slice(4); return h !== "" ? h : url; }
  catch { return url; }
}

function truncateSnippet(input: string, max: number): string {
  if (input.length <= max) return input;
  let end = max;
  if (end > 0) {
    const last = input.charCodeAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
  }
  return input.substring(0, end) + "\u2026";
}

export function mergeSearchResults(batches: WebSearchBatch[], limit: number): WebSearchResult[] {
  if (limit <= 0) return [];
  const merged = new Map<string, {title:string; url:string; snippet:string; sources:Set<WebSearchProvider>; bestRank:number; firstSeen:number}>();
  let sequence = 0;
  for (const batch of batches) {
    for (let rank = 0; rank < batch.results.length; rank++) {
      const raw = batch.results[rank];
      const key = normalizeSearchUrl(raw.url);
      if (key === "") continue;
      const existing = merged.get(key);
      if (existing == null) {
        merged.set(key, {title: raw.title.trim(), url: raw.url, snippet: truncateSnippet(raw.snippet.trim(), 400), sources: new Set([batch.provider]), bestRank: rank, firstSeen: sequence++});
        continue;
      }
      if (existing.title === "" && raw.title.trim() !== "") existing.title = raw.title.trim();
      const snip = truncateSnippet(raw.snippet.trim(), 400);
      if (snip.length > existing.snippet.length) existing.snippet = snip;
      existing.sources.add(batch.provider);
      if (rank < existing.bestRank) existing.bestRank = rank;
    }
  }
  const ordered = [...merged.values()].sort((a, b) => {
    const bySrc = b.sources.size - a.sources.size;
    if (bySrc !== 0) return bySrc;
    const byRank = a.bestRank - b.bestRank;
    if (byRank !== 0) return byRank;
    return a.firstSeen - b.firstSeen;
  });
  const capped = Math.min(20, Math.max(1, limit));
  return ordered.slice(0, capped).map(m => ({
    title: m.title !== "" ? m.title : titleFromUrl(m.url),
    url: m.url,
    snippet: m.snippet,
    sources: [...m.sources],
    bestRank: m.bestRank,
  }));
}

// \u2500\u2500\u2500 service (mirrors web_search_service.dart: semaphore + fan-out + reports) \u2500\u2500

class Semaphore {
  private active = 0;
  private waiters: Array<() => void> = [];
  constructor(private max: number) {}
  acquire(): Promise<void> {
    if (this.active < this.max) { this.active++; return Promise.resolve(); }
    return new Promise(resolve => this.waiters.push(resolve));
  }
  release(): void {
    if (this.waiters.length > 0) this.waiters.shift()!();
    else if (this.active > 0) this.active--;
  }
}

export async function webSearchService(
  query: string,
  opts: {maxResults?: number; signal?: AbortSignal; configOverride?: WebSearchConfig; apiKeyOverrides?: Partial<Record<WebSearchProvider,string>>;} = {}
): Promise<WebSearchResponse> {
  const config = opts.configOverride ?? loadWebSearchConfig();
  const finalLimit = (opts.maxResults != null && opts.maxResults > 0)
    ? Math.min(20, Math.max(1, opts.maxResults))
    : Math.min(20, Math.max(1, config.numResults));
  const backends = config.enabledBackends.filter(p => PROVIDER_META[p].isAvailable);
  if (backends.length === 0) {
    throw new WebSearchTransientError("\u672A\u542F\u7528\u4EFB\u4F55\u641C\u7D22\u540E\u7AEF\u3002\u8BF7\u5728\u300C\u8BBE\u7F6E \u2192 \u8054\u7F51\u641C\u7D22\u300D\u52FE\u9009\u81F3\u5C11\u4E00\u4E2A\u540E\u7AEF\u3002");
  }
  const perBackendLimit = Math.min(20, Math.max(finalLimit, Math.ceil(finalLimit * 1.5)));
  const semaphore = new Semaphore(Math.min(12, Math.max(1, config.concurrency)));
  const reports: WebSearchBackendReport[] = [];
  const batches: WebSearchBatch[] = [];

  await Promise.all(backends.map(async (provider) => {
    if (opts.signal?.aborted) return;
    await semaphore.acquire();
    const t0 = Date.now();
    let timedOut = false;
    let cancelled = false;
    try {
      const override = opts.apiKeyOverrides?.[provider];
      const apiKey = (override != null && override !== "") ? override.trim() : (getApiKey(provider) ?? "");
      if (PROVIDER_META[provider].requiresApiKey && apiKey === "") {
        reports.push({provider, ok: false, resultCount: 0, elapsedMs: Date.now()-t0, error: "\u672A\u914D\u7F6E API Key", permanent: true});
        return;
      }
      if (PROVIDER_META[provider].requiresInstanceUrl && config.searxngInstanceUrl.trim() === "") {
        reports.push({provider, ok: false, resultCount: 0, elapsedMs: Date.now()-t0, error: "\u672A\u914D\u7F6E\u5B9E\u4F8B\u5730\u5740", permanent: true});
        return;
      }
      if (opts.signal?.aborted) { cancelled = true; return; }

      const signal = opts.signal;
      const results = await searchProvider(provider, {
        query, maxResults: perBackendLimit, timeoutMs: config.backendTimeoutMs,
        apiKey: apiKey !== "" ? apiKey : null,
        instanceUrl: PROVIDER_META[provider].requiresInstanceUrl ? config.searxngInstanceUrl : null,
        signal,
      });
      reports.push({provider, ok: true, resultCount: results.length, elapsedMs: Date.now()-t0, permanent: false});
      batches.push({provider, results});
    } catch (e: unknown) {
      if (e instanceof WebSearchCancelledError) {
        if (timedOut) reports.push({provider, ok: false, resultCount: 0, elapsedMs: Date.now()-t0, error: "\u8D85\u65F6", permanent: false});
        else if (!cancelled && !opts.signal?.aborted) reports.push({provider, ok: false, resultCount: 0, elapsedMs: Date.now()-t0, error: "\u5DF2\u53D6\u6D88", permanent: false});
      } else if (e instanceof WebSearchQuotaError) {
        reports.push({provider, ok: false, resultCount: 0, elapsedMs: Date.now()-t0, error: e.message, permanent: e.permanent});
      } else if (e instanceof WebSearchTransientError) {
        reports.push({provider, ok: false, resultCount: 0, elapsedMs: Date.now()-t0, error: e.message, permanent: false});
      } else {
        reports.push({provider, ok: false, resultCount: 0, elapsedMs: Date.now()-t0, error: String(e), permanent: false});
      }
    } finally {
      semaphore.release();
    }
  }));

  if (opts.signal?.aborted) throw new WebSearchCancelledError("\u641C\u7D22\u5DF2\u88AB\u53D6\u6D88");
  reports.sort((a, b) => backends.indexOf(a.provider) - backends.indexOf(b.provider));
  if (reports.length > 0 && reports.every(r => !r.ok)) {
    const msg = reports.map(r => providerDisplayName(r.provider) + "(" + (r.error ?? "") + ")").join("\uFF1B");
    if (reports.every(r => r.permanent)) throw new WebSearchQuotaError("\u6240\u6709\u641C\u7D22\u540E\u7AEF\u5747\u5931\u8D25\uFF1A" + msg, reports[0].provider, true);
    throw new WebSearchTransientError("\u6240\u6709\u641C\u7D22\u540E\u7AEF\u5747\u5931\u8D25\uFF1A" + msg);
  }
  const orderedBatches: WebSearchBatch[] = [];
  for (const provider of backends) {
    for (const b of batches) if (b.provider === provider) orderedBatches.push(b);
  }
  return new WebSearchResponse({results: mergeSearchResults(orderedBatches, finalLimit), reports});
}

async function searchProvider(provider: WebSearchProvider, opts: SearchOpts): Promise<WebSearchResult[]> {
  // Check cancellation before each call
  if (opts.signal?.aborted) throw new WebSearchCancelledError("\u641C\u7D22\u5DF2\u88AB\u53D6\u6D88");
  switch (provider) {
    case "bingRss":  return searchBingRss(opts);
    case "duckduckgo": return searchDuckDuckGo(opts);
    case "searxng":  return searchSearxng(opts);
    case "tavily":   return searchTavily(opts);
    case "brave":    return searchBrave(opts);
    case "serper":   return searchSerper(opts);
    case "mojeek":   return searchMojeek(opts);
    case "exa":      return searchExa(opts);
    case "parallel": return searchParallel(opts);
    case "openai":   return searchOpenAI(opts);
    case "anthropic":return searchAnthropic(opts);
    default: throw new WebSearchQuotaError("\u672A\u77E5\u641C\u7D22\u540E\u7AEF: " + provider, provider, true);
  }
}

// \u2500\u2500\u2500 tool (mirrors WebSearchTool in web_tools.dart) \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

export class WebSearchTool extends AgentTool {
  readonly name = "web_search";
  readonly description: string =
    "\u8054\u7F51\u641C\u7D22\u6700\u65B0\u4FE1\u606F\uFF08\u5F53\u4F60\u7684\u8BAD\u7EC3\u6570\u636E\u53EF\u80FD\u8FC7\u65F6\u3001\u6216\u9047\u5230\u4E0D\u719F\u6089\u7684\u6982\u5FF5/\u9519\u8BEF/\u7248\u672C\u53F7/\u8F6F\u4EF6\u5305\u65F6\u4F7F\u7528\uFF09\u3002\u4F1A\u5E76\u53D1\u67E5\u8BE2\u591A\u4E2A\u5DF2\u542F\u7528\u540E\u7AEF\uFF0C\u6309 URL \u53BB\u91CD\u5408\u5E76\u540E\u8FD4\u56DE\u6807\u9898+URL+\u6458\u8981\u5217\u8868\uFF0C\u82E5\u9700\u8BE6\u7EC6\u5185\u5BB9\u8BF7\u914D\u5408 fetch_url \u5DE5\u5177\u3002";
  readonly paramSpec: string =
    "\u53C2\u6570\u5217\u8868\uFF08\u591A\u884C key:value \u683C\u5F0F\uFF09\uFF1A\n  query: \u641C\u7D22\u5173\u952E\u8BCD\uFF08\u5FC5\u586B\uFF09\n  max_results: \u8FD4\u56DE\u7ED3\u679C\u6570\uFF08\u53EF\u9009\uFF0C\u9ED8\u8BA4 5\uFF0C\u4E0A\u9650 20\uFF09";
  get kind(): ToolKind { return ToolKind.network; }
  get recordsChanges(): boolean { return false; }
  get scope(): ToolScope { return ToolScope.all; }
  toJsonSchema(): Record<string, unknown> {
    return {
      type: "object",
      properties: {
        query: {type: "string", description: "\u641C\u7D22\u5173\u952E\u8BCD"},
        max_results: {type: "integer", description: "\u8FD4\u56DE\u7ED3\u679C\u6570\uFF08\u9ED8\u8BA4 5\uFF09"},
      },
      required: ["query"],
    };
  }
  async execute(args: ToolArgs, ctx: ToolContext): Promise<ToolResult> {
    const query = args.getString("query").trim();
    const maxResults = args.getInt("max_results", 0);
    if (query === "") return ToolResult.failure("\u53C2\u6570\u7F3A\u5931: query \u4E3A\u5FC5\u586B\u9879");
    if (ctx.cancelled && ctx.cancelled()) return ToolResult.failure("\u641C\u7D22\u5DF2\u88AB\u53D6\u6D88", {output: ""});

    // Bridge ctx.cancelled() to an AbortSignal so in-flight HTTP calls are cancelled
    const ctrl = new AbortController();
    const checkInterval = setInterval(() => {
      if (ctx.cancelled?.()) { ctrl.abort(); clearInterval(checkInterval); }
    }, 250);
    try {
      const resp = await webSearchService(query, {maxResults, signal: ctrl.signal});
      const results = resp.results;
      if (results.length === 0) {
        const failed = resp.failures.map(r => providerDisplayName(r.provider) + "(" + (r.error ?? "") + ")").join("\u3001");
        return ToolResult.success(
          "\u641C\u7D22\u5B8C\u6210\uFF0C\u4F46\u672A\u627E\u5230\u5339\u914D\u7ED3\u679C\uFF08\u5DF2\u5C1D\u8BD5 " + resp.reports.length + " \u4E2A\u540E\u7AEF"
          + (failed !== "" ? "\uFF1B\u5931\u8D25/\u8DF3\u8FC7: " + failed : "") + "\uFF09\u3002\u5EFA\u8BAE\u8C03\u6574\u5173\u952E\u8BCD\u540E\u91CD\u8BD5\u3002"
        );
      }
      const lines: string[] = [];
      lines.push("\u805A\u5408 " + resp.successCount + "/" + resp.reports.length + " \u4E2A\u540E\u7AEF\uFF0C\u53BB\u91CD\u540E " + results.length + " \u6761\u7ED3\u679C\uFF1A");
      if (resp.failures.length > 0) {
        lines.push("\u5931\u8D25/\u8DF3\u8FC7: " + resp.failures.map(r => providerDisplayName(r.provider) + "(" + (r.error ?? "") + ")").join("\u3001"));
      }
      lines.push("");
      for (let i = 0; i < results.length; i++) {
        const r = results[i];
        lines.push("[" + (i + 1) + "] " + (r.title !== "" ? r.title : "\u65E0\u6807\u9898"));
        lines.push("    URL: " + r.url);
        if (r.snippet !== "") lines.push("    \u6458\u8981: " + r.snippet);
        if (r.sources.length > 1) lines.push("    \u6765\u6E90: " + r.sources.map(providerDisplayName).join(" / "));
        lines.push("");
      }
      lines.push("\u63D0\u793A\uFF1A\u82E5\u9700\u8981\u67D0\u6761\u7ED3\u679C\u7684\u8BE6\u7EC6\u5185\u5BB9\uFF0C\u53EF\u7528 fetch_url \u5DE5\u5177\u6293\u53D6\u5176 URL\u3002");
      return ToolResult.success(lines.join("\n").trimEnd());
    } catch (e: unknown) {
      if (e instanceof WebSearchCancelledError) return ToolResult.failure("\u641C\u7D22\u5DF2\u88AB\u53D6\u6D88", {output: ""});
      if (e instanceof WebSearchQuotaError) {
        const hint = e.permanent
          ? "\uFF08\u6B64\u9519\u8BEF\u4E3A\u6C38\u4E45\u6027\uFF0C\u91CD\u8BD5\u672C provider \u4E0D\u4F1A\u6210\u529F\uFF0C\u8BF7\u6539\u7528\u4F60\u5DF2\u6709\u7684\u77E5\u8BC6\u56DE\u7B54\uFF0C\u6216\u63D0\u793A\u7528\u6237\u68C0\u67E5\u914D\u7F6E\uFF09"
          : "\uFF08\u6B64\u9519\u8BEF\u53EF\u7A0D\u540E\u91CD\u8BD5\uFF0C\u4F46\u5EFA\u8BAE\u5148\u7528\u5DF2\u6709\u77E5\u8BC6\u7EE7\u7EED\u4EFB\u52A1\uFF09";
        return ToolResult.failure(e.message + hint);
      }
      if (e instanceof WebSearchTransientError) return ToolResult.failure(e.message + "\uFF08\u77AC\u65F6\u9519\u8BEF\uFF0C\u53EF\u91CD\u8BD5\u4E00\u6B21\uFF09");
      const msg = e instanceof Error ? e.message : String(e);
      return ToolResult.failure("\u641C\u7D22\u5931\u8D25: " + msg);
    } finally {
      clearInterval(checkInterval);
    }
  }
}
