// Hermetic tests for mcp/models.ts pure functions + tool_adapter execute paths.
// No I/O, no network, no MCP SDK connection — only the pure value-shaping
// helpers and the adapter argument-reading / kind / schema logic.

import {describe, it, expect} from "vitest";
import {
  McpTransportKind, mcpTransportKindFromString, mcpTransportKindLabel,
  McpToolExposure, mcpToolExposureFromString,
  McpServerStatus, mcpServerStatusLabel,
  mcpSlug, mcpToolFullName, mcpServerConfigEndpointLabel, mcpServerConfigCopyWith,
  presetFilesystem, presetContext7,
  McpServerRuntime, mcpServerRuntimeCopyWith, mcpServerRuntimeIsConnected,
  McpOAuthTokenData, mcpOAuthTokenIsExpired, mcpOAuthTokenToJson, mcpOAuthTokenFromJson,
  McpAuthRequiredException, encodeMcpJson,
  McpToolDescriptor, McpCallResult, McpServerConfig,
} from "../src/mcp/models.js";
import {ToolResult, ToolKind, ToolSource} from "../src/tools/builtin.js";
import {ToolArgs} from "../src/tools/tool_args.js";
import {McpToolAdapter, McpSideToolAdapter, McpSideToolKind, McpToolCaller} from "../src/mcp/tool_adapter.js";

describe("mcpSlug", () => {
  it("lowercases, trims, replaces non-alnum runs with underscore, strips leading/trailing _", () => {
    expect(mcpSlug("  My Server  ")).toBe("my_server");
    expect(mcpSlug("a-b_c")).toBe("a-b_c");
    expect(mcpSlug("")).toBe("server");
  });
  it("truncates to maxLength (default 40, custom 20/36)", () => {
    expect(mcpSlug("a".repeat(50)).length).toBe(40);
    expect(mcpSlug("x".repeat(30), 20).length).toBe(20);
  });
});

describe("mcpToolFullName", () => {
  it("mcp__ + serverSlug20 + __ + toolSlug36, capped at 64 chars", () => {
    expect(mcpToolFullName("myserver", "mytool")).toBe("mcp__myserver__mytool");
    const name = mcpToolFullName("s".repeat(30), "t".repeat(30));
    expect(name.length).toBeLessThanOrEqual(64);
  });
});

describe("mcpTransportKindFromString / Label", () => {
  it("parses sse/stdio/streamableHttp (default)", () => {
    expect(mcpTransportKindFromString("sse")).toBe(McpTransportKind.sse);
    expect(mcpTransportKindFromString("stdio")).toBe(McpTransportKind.stdio);
    expect(mcpTransportKindFromString(undefined)).toBe(McpTransportKind.streamableHttp);
    expect(mcpTransportKindFromString("bogus")).toBe(McpTransportKind.streamableHttp);
  });
  it("returns the CJK label for each kind", () => {
    expect(mcpTransportKindLabel(McpTransportKind.streamableHttp)).toBe("Streamable HTTP");
    expect(mcpTransportKindLabel(McpTransportKind.sse)).toBe("HTTP + SSE\uFF08\u65E7\u7248\uFF09");
    expect(mcpTransportKindLabel(McpTransportKind.stdio)).toBe("stdio\uFF08\u672C\u5730\u8FDB\u7A0B\uFF09");
  });
});

describe("mcpToolExposureFromString", () => {
  it("parses readOnly (default) / all / custom", () => {
    expect(mcpToolExposureFromString(undefined)).toBe(McpToolExposure.readOnly);
    expect(mcpToolExposureFromString("all")).toBe(McpToolExposure.all);
    expect(mcpToolExposureFromString("custom")).toBe(McpToolExposure.custom);
  });
});

describe("mcpServerStatusLabel", () => {
  it("returns the CJK label for each status", () => {
    expect(mcpServerStatusLabel(McpServerStatus.disabled)).toBe("\u5DF2\u505C\u7528");
    expect(mcpServerStatusLabel(McpServerStatus.disconnected)).toBe("\u672A\u8FDE\u63A5");
    expect(mcpServerStatusLabel(McpServerStatus.connecting)).toBe("\u8FDE\u63A5\u4E2D");
    expect(mcpServerStatusLabel(McpServerStatus.connected)).toBe("\u5DF2\u8FDE\u63A5");
    expect(mcpServerStatusLabel(McpServerStatus.authRequired)).toBe("\u9700\u8981\u6388\u6743");
    expect(mcpServerStatusLabel(McpServerStatus.error)).toBe("\u8FDE\u63A5\u5931\u8D25");
  });
});

function makeConfig(overrides: Partial<McpServerConfig> = {}): McpServerConfig {
  return {
    id: "s1", name: "S", enabled: true, autoConnect: true,
    transport: McpTransportKind.streamableHttp, url: "https://x.com",
    command: "", args: [], workingDirectory: "", headers: {}, env: {},
    timeoutMs: 5000, proxy: "", oauth: false, oauthScopes: [],
    oauthClientId: "", oauthClientSecret: "", toolExposure: McpToolExposure.readOnly,
    allowedTools: [], maxTools: 20, exposeResources: true, exposePrompts: true,
    ...overrides,
  };
}

describe("mcpServerConfigEndpointLabel / CopyWith", () => {
  it("stdio: joins command + args (skipping blank)", () => {
    const c = makeConfig({transport: McpTransportKind.stdio, command: "npx", args: ["-y", "pkg"]});
    expect(mcpServerConfigEndpointLabel(c)).toBe("npx -y pkg");
  });
  it("http/sse: returns the url", () => {
    expect(mcpServerConfigEndpointLabel(makeConfig({url: "https://y.com"}))).toBe("https://y.com");
  });
  it("CopyWith shallow-merges overrides", () => {
    const c2 = mcpServerConfigCopyWith(makeConfig(), {name: "New", enabled: false});
    expect(c2.name).toBe("New");
    expect(c2.enabled).toBe(false);
    expect(c2.id).toBe("s1");
  });
});

describe("presetFilesystem / presetContext7", () => {
  it("presetFilesystem: stdio npx @modelcontextprotocol/server-filesystem", () => {
    const c = presetFilesystem("/tmp");
    expect(c.transport).toBe(McpTransportKind.stdio);
    expect(c.command).toBe("npx");
    expect(c.args).toEqual(["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]);
    expect(c.id).toBe("fs-_tmp");
  });
  it("presetContext7: stdio npx @upstash/context7-mcp", () => {
    const c = presetContext7();
    expect(c.command).toBe("npx");
    expect(c.args[1]).toBe("@upstash/context7-mcp");
    expect(c.id).toBe("context7");
  });
});

function makeRuntime(overrides: Partial<McpServerRuntime> = {}): McpServerRuntime {
  return {
    config: makeConfig(), status: McpServerStatus.disconnected, error: "",
    pendingAuthUrl: "", tools: [], resources: [], prompts: [], logs: [],
    connectedAt: null, ...overrides,
  };
}

describe("mcpServerRuntimeCopyWith / IsConnected", () => {
  it("IsConnected is true only for status=connected", () => {
    expect(mcpServerRuntimeIsConnected(makeRuntime({status: McpServerStatus.connected}))).toBe(true);
    expect(mcpServerRuntimeIsConnected(makeRuntime({status: McpServerStatus.disconnected}))).toBe(false);
  });
  it("CopyWith: clearConnectedAt forces null even when a new value is supplied", () => {
    const r0 = makeRuntime({connectedAt: 100});
    expect(mcpServerRuntimeCopyWith(r0, {clearConnectedAt: true, connectedAt: 200}).connectedAt).toBeNull();
    expect(mcpServerRuntimeCopyWith(r0, {connectedAt: 300}).connectedAt).toBe(300);
  });
});

describe("mcpOAuthTokenIsExpired", () => {
  it("no expiresAtMs -> never expired", () => {
    expect(mcpOAuthTokenIsExpired({accessToken: "t"})).toBe(false);
  });
  it("expiresAtMs in the past -> expired", () => {
    expect(mcpOAuthTokenIsExpired({accessToken: "t", expiresAtMs: 1})).toBe(true);
  });
  it("expiresAtMs in the future -> not expired", () => {
    expect(mcpOAuthTokenIsExpired({accessToken: "t", expiresAtMs: Date.now() + 10_000})).toBe(false);
  });
});

describe("mcpOAuthTokenToJson / FromJson round-trip", () => {
  it("round-trips access + refresh + expiry + issuer + resource", () => {
    const tok: McpOAuthTokenData = {accessToken: "AT", refreshToken: "RT", expiresAtMs: 12345, issuer: "iss", resource: "res"};
    const json = mcpOAuthTokenToJson(tok);
    expect(json.access_token).toBe("AT");
    expect(json.refresh_token).toBe("RT");
    expect(json.expires_at_ms).toBe(12345);
    expect(mcpOAuthTokenFromJson(json as Record<string, unknown>)).toEqual(tok);
  });
  it("omits optional fields when not present", () => {
    const json = mcpOAuthTokenToJson({accessToken: "AT"});
    expect("refresh_token" in json).toBe(false);
    expect("expires_at_ms" in json).toBe(false);
  });
  it("FromJson accepts a numeric expires_at_ms as a string", () => {
    const back = mcpOAuthTokenFromJson({access_token: "AT", expires_at_ms: "67890"} as Record<string, unknown>);
    expect(back.expiresAtMs).toBe(67890);
  });
});

describe("McpAuthRequiredException", () => {
  it("carries the authUrl and is an instance of Error", () => {
    const e = new McpAuthRequiredException("need auth", "https://auth.example/cb");
    expect(e instanceof Error).toBe(true);
    expect(e.name).toBe("McpAuthRequiredException");
    expect(e.message).toBe("need auth");
    expect(e.authUrl).toBe("https://auth.example/cb");
  });
});

describe("encodeMcpJson", () => {
  it("stringifies a JSON-serialisable value", () => {
    expect(encodeMcpJson({a: 1})).toBe('{"a":1}');
  });
  it("falls back to String() for cyclic values (no throw)", () => {
    const o: Record<string, unknown> = {};
    o.self = o;
    expect(encodeMcpJson(o).length).toBeGreaterThan(0);
  });
});

function makeDescriptor(overrides: Partial<McpToolDescriptor> = {}): McpToolDescriptor {
  return {
    name: "mytool", title: "My Tool", description: "desc",
    inputSchema: {type: "object", properties: {q: {type: "string"}}},
    readOnly: false, destructive: false, idempotent: true, openWorld: false,
    ...overrides,
  };
}

function makeCaller(overrides: Partial<McpToolCaller> = {}): McpToolCaller {
  return {
    callMcpTool: async () => ({isError: false, text: "ok"} as McpCallResult),
    readMcpResource: async () => "res",
    getMcpPrompt: async () => "prompt",
    mcpRuntime: () => makeRuntime({status: McpServerStatus.connected}) as McpServerRuntime,
    ...overrides,
  };
}

const ctxFalse = {cancelled: () => false} as any;
const ctxTrue = {cancelled: () => true} as any;

describe("McpToolAdapter", () => {
  it("kind: readOnly -> read; destructive -> destructive; else network", () => {
    const c = makeCaller();
    expect(new McpToolAdapter({caller: c, serverId: "s", serverName: "S", descriptor: makeDescriptor({readOnly: true})}).kind).toBe(ToolKind.read);
    expect(new McpToolAdapter({caller: c, serverId: "s", serverName: "S", descriptor: makeDescriptor({destructive: true})}).kind).toBe(ToolKind.destructive);
    expect(new McpToolAdapter({caller: c, serverId: "s", serverName: "S", descriptor: makeDescriptor()}).kind).toBe(ToolKind.network);
  });
  it("name: uses mcpToolFullName(serverId, descriptor.name) when no override", () => {
    const a = new McpToolAdapter({caller: makeCaller(), serverId: "myserver", serverName: "S", descriptor: makeDescriptor()});
    expect(a.name).toBe(mcpToolFullName("myserver", "mytool"));
  });
  it("recordsChanges is false + source is mcpServer", () => {
    const a = new McpToolAdapter({caller: makeCaller(), serverId: "s", serverName: "S", descriptor: makeDescriptor()});
    expect(a.recordsChanges).toBe(false);
    expect(a.source).toBe(ToolSource.mcpServer);
  });
  it("execute: cancelled context short-circuits before calling the MCP tool", async () => {
    let called = false;
    const caller = makeCaller({callMcpTool: async () => { called = true; return {isError: false, text: "ok"}; }});
    const adapter = new McpToolAdapter({caller, serverId: "s", serverName: "S", descriptor: makeDescriptor()});
    const result = await adapter.execute(ToolArgs.EMPTY, ctxTrue);
    expect(result.success).toBe(false);
    expect(called).toBe(false);
  });
  it("execute: json: argument is parsed and forwarded to callMcpTool", async () => {
    let received: Record<string, unknown> | null = null;
    const caller = makeCaller({callMcpTool: async (_s, _t, args) => { received = args; return {isError: false, text: "ok"}; }});
    const adapter = new McpToolAdapter({caller, serverId: "s", serverName: "S", descriptor: makeDescriptor()});
    const result = await adapter.execute(ToolArgs.wrap({json: '{"q":"hello"}'}), ctxFalse);
    expect(result.success).toBe(true);
    expect(received).toEqual({q: "hello"});
  });
  it("execute: invalid json: argument returns a failure with the JSON format hint", async () => {
    const adapter = new McpToolAdapter({caller: makeCaller(), serverId: "s", serverName: "S", descriptor: makeDescriptor()});
    const result = await adapter.execute(ToolArgs.wrap({json: "{not valid json"}), ctxFalse);
    expect(result.success).toBe(false);
    expect(result.error ?? "").toContain("JSON");
  });
  it("execute: isError result is surfaced as a failure with the [MCP server/tool] prefix", async () => {
    const caller = makeCaller({callMcpTool: async () => ({isError: true, text: "tool exploded"})});
    const adapter = new McpToolAdapter({caller, serverId: "s", serverName: "Srv", descriptor: makeDescriptor({name: "do"})});
    const result = await adapter.execute(ToolArgs.EMPTY, ctxFalse);
    expect(result.success).toBe(false);
    expect(result.error ?? "").toContain("[MCP Srv/do]");
    expect((result.error ?? "") + (result.output ?? "")).toContain("tool exploded");
  });
  it("execute: McpAuthRequiredException is caught and returned as a failure", async () => {
    const caller = makeCaller({callMcpTool: async () => { throw new McpAuthRequiredException("need auth", "https://x/cb"); }});
    const adapter = new McpToolAdapter({caller, serverId: "s", serverName: "S", descriptor: makeDescriptor()});
    const result = await adapter.execute(ToolArgs.EMPTY, ctxFalse);
    expect(result.success).toBe(false);
    expect(result.error ?? "").toContain("need auth");
  });
  it("toJsonSchema: returns inputSchema as-is when object, else wraps in {value: schema}", () => {
    const obj = new McpToolAdapter({caller: makeCaller(), serverId: "s", serverName: "S", descriptor: makeDescriptor({inputSchema: {type: "object", properties: {}}})});
    expect(obj.toJsonSchema()).toEqual({type: "object", properties: {}});
    const nonObj = new McpToolAdapter({caller: makeCaller(), serverId: "s", serverName: "S", descriptor: makeDescriptor({inputSchema: {type: "string"} as any})});
    expect(nonObj.toJsonSchema()).toEqual({type: "object", properties: {value: {type: "string"}}, additionalProperties: false});
  });
});

describe("McpSideToolAdapter", () => {
  it("name: uses the suffix for each sideKind", () => {
    const mk = (k: McpSideToolKind) => new McpSideToolAdapter({caller: makeCaller(), serverId: "srv", serverName: "S", sideKind: k});
    expect(mk(McpSideToolKind.listResources).name).toBe(mcpToolFullName("srv", "list_resources"));
    expect(mk(McpSideToolKind.readResource).name).toBe(mcpToolFullName("srv", "read_resource"));
    expect(mk(McpSideToolKind.listPrompts).name).toBe(mcpToolFullName("srv", "list_prompts"));
    expect(mk(McpSideToolKind.getPrompt).name).toBe(mcpToolFullName("srv", "get_prompt"));
  });
  it("kind is always read; recordsChanges is always false", () => {
    const a = new McpSideToolAdapter({caller: makeCaller(), serverId: "s", serverName: "S", sideKind: McpSideToolKind.listResources});
    expect(a.kind).toBe(ToolKind.read);
    expect(a.recordsChanges).toBe(false);
  });
  it("execute: disconnected runtime returns the not-connected failure", async () => {
    const caller = makeCaller({mcpRuntime: () => makeRuntime({status: McpServerStatus.disconnected})});
    const a = new McpSideToolAdapter({caller, serverId: "s", serverName: "Srv", sideKind: McpSideToolKind.listResources});
    const r = await a.execute(ToolArgs.EMPTY, ctxFalse);
    expect(r.success).toBe(false);
    expect(r.error ?? "").toContain("Srv");
  });
  it("execute: listResources returns the empty message when no resources", async () => {
    const caller = makeCaller({mcpRuntime: () => makeRuntime({status: McpServerStatus.connected, resources: []})});
    const a = new McpSideToolAdapter({caller, serverId: "s", serverName: "S", sideKind: McpSideToolKind.listResources});
    const r = await a.execute(ToolArgs.EMPTY, ctxFalse);
    expect(r.success).toBe(true);
  });
  it("execute: readResource forwards the uri to readMcpResource", async () => {
    let uri: string | null = null;
    const caller = makeCaller({
      readMcpResource: async (_s, u) => { uri = u; return "content"; },
      mcpRuntime: () => makeRuntime({status: McpServerStatus.connected}),
    });
    const a = new McpSideToolAdapter({caller, serverId: "s", serverName: "S", sideKind: McpSideToolKind.readResource});
    const r = await a.execute(ToolArgs.wrap({uri: "mem://x"}), ctxFalse);
    expect(r.success).toBe(true);
    expect(uri).toBe("mem://x");
  });
});