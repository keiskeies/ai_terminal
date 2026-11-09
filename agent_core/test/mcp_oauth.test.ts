// Hermetic tests for mcp/oauth.ts (McpOAuthProvider).
// No real OAuth server and no browser: the provider is driven with
// interactive:false (so redirectToAuthorization never spawns a child) and
// an in-memory McpOAuthTokenStore. Pure getters (clientMetadata,
// clientInformation, tokens, saveTokens, codeVerifier, state, pendingAuthUrl)
// and the waitForCallback guards (disposed / timeout) are asserted directly.

import {describe, it, expect, beforeEach, afterEach} from "vitest";
import {McpOAuthProvider} from "../src/mcp/oauth.js";
import type {McpOAuthTokenStore} from "../src/mcp/oauth.js";
import {
  McpTransportKind, McpToolExposure, McpOAuthTokenData,
} from "../src/mcp/models.js";
import type {McpServerConfig} from "../src/mcp/models.js";

function makeConfig(overrides: Partial<McpServerConfig> = {}): McpServerConfig {
  return {
    id: "s1", name: "S", enabled: true, autoConnect: true,
    transport: McpTransportKind.streamableHttp, url: "https://x.com",
    command: "", args: [], workingDirectory: "", headers: {}, env: {},
    timeoutMs: 5000, proxy: "", oauth: true, oauthScopes: [],
    oauthClientId: "", oauthClientSecret: "", toolExposure: McpToolExposure.readOnly,
    allowedTools: [], maxTools: 20, exposeResources: true, exposePrompts: true,
    ...overrides,
  };
}

// In-memory McpOAuthTokenStore.
class MemStore implements McpOAuthTokenStore {
  private data = new Map<string, McpOAuthTokenData>();
  saved: Array<{ serverId: string; token: McpOAuthTokenData }> = [];
  load(serverId: string): Promise<McpOAuthTokenData | null> {
    return Promise.resolve(this.data.get(serverId) ?? null);
  }
  save(serverId: string, t: McpOAuthTokenData): Promise<void> {
    this.data.set(serverId, t);
    this.saved.push({ serverId, token: t });
    return Promise.resolve();
  }
  seed(serverId: string, t: McpOAuthTokenData): void { this.data.set(serverId, t); }
}

let provider: McpOAuthProvider;
let store: MemStore;

beforeEach(() => {
  store = new MemStore();
  provider = new McpOAuthProvider({ config: makeConfig(), interactive: false, store });
});

afterEach(async () => {
  await provider.dispose();
});

describe("clientMetadata", () => {
  it("defaults to public client (token_endpoint_auth_method=none, no scope)", () => {
    const meta = provider.clientMetadata;
    expect(meta.token_endpoint_auth_method).toBe("none");
    expect(meta.grant_types).toEqual(["authorization_code"]);
    expect(meta.response_types).toEqual(["code"]);
    expect(meta.client_name).toBe("AI Terminal");
    // redirectUrl undefined before init() -> redirect_uris is empty
    expect(meta.redirect_uris).toEqual([]);
    expect(meta.scope).toBeUndefined();
  });

  it("uses client_secret_basic when a client secret is set", () => {
    const p = new McpOAuthProvider({ config: makeConfig({ oauthClientSecret: "sh" }), interactive: false, store });
    expect(p.clientMetadata.token_endpoint_auth_method).toBe("client_secret_basic");
  });

  it("joins non-blank oauthScopes into scope with single spaces", () => {
    const p = new McpOAuthProvider({ config: makeConfig({ oauthScopes: ["a", " ", "b c"] }), interactive: false, store });
    expect(p.clientMetadata.scope).toBe("a b c");
  });
});

describe("clientInformation", () => {
  it("returns undefined when no client id is configured", async () => {
    expect(await provider.clientInformation()).toBeUndefined();
  });

  it("returns client_id (+ client_secret only when set)", async () => {
    const p = new McpOAuthProvider({ config: makeConfig({ oauthClientId: "cid" }), interactive: false, store });
    expect(await p.clientInformation()).toEqual({ client_id: "cid" });
    const p2 = new McpOAuthProvider({ config: makeConfig({ oauthClientId: "cid", oauthClientSecret: "sh" }), interactive: false, store });
    expect(await p2.clientInformation()).toEqual({ client_id: "cid", client_secret: "sh" });
  });
});

describe("tokens / saveTokens", () => {
  it("returns undefined when no token is persisted", async () => {
    expect(await provider.tokens()).toBeUndefined();
  });

  it("returns undefined for an EXPIRED token (mcpOAuthTokenIsExpired)", async () => {
    store.seed("s1", { accessToken: "old", expiresAtMs: 1 });
    expect(await provider.tokens()).toBeUndefined();
  });

  it("returns Bearer tokens (refresh + issuer carried through when present)", async () => {
    store.seed("s1", { accessToken: "AT", refreshToken: "RT", issuer: "iss", expiresAtMs: Date.now() + 60_000 });
    const t = await provider.tokens();
    expect(t).toEqual({ access_token: "AT", token_type: "Bearer", refresh_token: "RT", issuer: "iss" });
  });

  it("saveTokens computes expiresAtMs from expires_in and persists the model", async () => {
    await provider.saveTokens({ access_token: "A", refresh_token: "R", issuer: "i", expires_in: 120 });
    expect(store.saved.length).toBe(1);
    expect(store.saved[0].serverId).toBe("s1");
    expect(store.saved[0].token.accessToken).toBe("A");
    expect(store.saved[0].token.refreshToken).toBe("R");
    expect(store.saved[0].token.issuer).toBe("i");
    // expires_in 120s -> a finite expiresAtMs in the future
    const e = store.saved[0].token.expiresAtMs as number;
    expect(e).toBeGreaterThan(Date.now());
    // round-trip: tokens() now returns the freshly saved access token
    expect(await provider.tokens()).toEqual({ access_token: "A", token_type: "Bearer", refresh_token: "R", issuer: "i" });
  });

  it("saveTokens with no expires_in omits expiresAtMs", async () => {
    await provider.saveTokens({ access_token: "A" });
    expect(store.saved[0].token.expiresAtMs).toBeUndefined();
  });
});

describe("codeVerifier / state / pendingAuthUrl", () => {
  it("saveCodeVerifier + codeVerifier round-trip", () => {
    expect(provider.codeVerifier()).toBe("");
    provider.saveCodeVerifier("pkce-verifier");
    expect(provider.codeVerifier()).toBe("pkce-verifier");
  });

  it("state() is a stable non-empty hex string (randomBytes seed)", () => {
    const s1 = provider.state();
    expect(s1.length).toBe(32); // 16 random bytes -> 32 hex chars
    expect(/^[0-9a-f]{32}$/.test(s1)).toBe(true);
    expect(provider.state()).toBe(s1); // stable for the lifetime of the instance
  });

  it("redirectToAuthorization (interactive:false) records pendingAuthUrl + fires onAuthorizationUrl, no spawn", async () => {
    const seen: string[] = [];
    provider = new McpOAuthProvider({ config: makeConfig(), interactive: false, store, onAuthorizationUrl: (u) => seen.push(u) });
    await provider.redirectToAuthorization(new URL("https://auth.example/authorize?x=1"));
    expect(provider.pendingAuthUrl).toBe("https://auth.example/authorize?x=1");
    expect(seen).toEqual(["https://auth.example/authorize?x=1"]);
  });
});

describe("waitForCallback", () => {
  it("rejects after the timeout when no callback has arrived", async () => {
    await expect(provider.waitForCallback(20)).rejects.toThrow("回调超时");
  });

  it("throws a StateError when called after dispose()", async () => {
    await provider.dispose();
    expect(() => provider.waitForCallback(1000)).toThrow("已关闭");
  });
});
