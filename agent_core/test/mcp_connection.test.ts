// Hermetic tests for mcp/connection.ts (McpConnection).
// No live MCP server / no real transport: the connection is driven with a
// rejecting transportFactory (so connect() never reaches a real Client
// handshake) and, for the not-connected guards, before any connection is made.
// Covers the public, deterministic surface: runtime getter, the three not-
// connected tool/resource/prompt guards, the connect() error path, idempotent
// re-entry, disconnect() lifecycle, and the 50-entry log tail cap.

import {describe, it, expect} from "vitest";
import {McpConnection} from "../src/mcp/connection.js";
import type {McpTransport} from "../src/mcp/connection.js";
import {
  McpTransportKind, McpToolExposure, McpServerStatus, McpServerConfig,
} from "../src/mcp/models.js";
import type {McpServerRuntime} from "../src/mcp/models.js";

// CJK literals (byte-faithful to connection.ts). Built via codepoints so this
// test file stays ASCII; the emitted values are identical to the source strings.
const NOT_CONNECTED = [0x4D,0x43,0x50,0x20,0x670D,0x52A1,0x5668,0x672A,0x8FDE,0x63A5].map((c) => String.fromCodePoint(c)).join("");
const FAIL_PREFIX = [0x8FDE,0x63A5,0x5931,0x8D25,0xFF1A].map((c) => String.fromCodePoint(c)).join("");

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

function makeConn(overrides: Partial<McpServerConfig> = {}): {
  conn: McpConnection; runtimes: McpServerRuntime[];
} {
  const runtimes: McpServerRuntime[] = [];
  const conn = new McpConnection({
    config: makeConfig(overrides),
    onRuntime: (r) => runtimes.push(r),
    // Rejecting factory: connect() awaits it first, so no real Client is ever
    // constructed and no network / handshake happens. The promise rejects with
    // a plain Error -> friendlyError picks its .message -> status = error.
    transportFactory: async () => {
      throw new Error("injected transport failure");
    },
  });
  return { conn, runtimes };
}

describe("runtime getter", () => {
  it("exposes the initial disconnected state with empty capability arrays", () => {
    const { conn } = makeConn();
    const rt = conn.runtime;
    expect(rt.status).toBe(McpServerStatus.disconnected);
    expect(rt.error).toBe("");
    expect(rt.pendingAuthUrl).toBe("");
    expect(rt.tools).toEqual([]);
    expect(rt.resources).toEqual([]);
    expect(rt.prompts).toEqual([]);
    expect(rt.connectedAt).toBeNull();
    expect(rt.config.id).toBe("s1");
  });
});

describe("not-connected guards (client is null)", () => {
  it("callTool reports the server not connected", async () => {
    const { conn } = makeConn();
    const r = await conn.callTool("someTool", {});
    expect(r.isError).toBe(true);
    expect(r.text).toBe(NOT_CONNECTED);
  });

  it("readResource reports the server not connected", async () => {
    const { conn } = makeConn();
    expect(await conn.readResource("file:///x")).toBe(NOT_CONNECTED);
  });

  it("getPrompt reports the server not connected", async () => {
    const { conn } = makeConn();
    expect(await conn.getPrompt("p")).toBe(NOT_CONNECTED);
  });
});

describe("connect() error path via rejecting transportFactory", () => {
  it("transitions connecting -> error and emits a runtime with the friendly error", async () => {
    const { conn, runtimes } = makeConn();
    await conn.connect();
    expect(conn.runtime.status).toBe(McpServerStatus.error);
    expect(conn.runtime.error).toBe("injected transport failure");
    expect(conn.runtime.connectedAt).toBeNull();
    const statuses = runtimes.map((r) => r.status);
    expect(statuses[0]).toBe(McpServerStatus.connecting);
    expect(statuses[statuses.length - 1]).toBe(McpServerStatus.error);
  });

  it("connect() after a failure retries (not already-connected, so it re-runs)", async () => {
    const { conn, runtimes } = makeConn();
    await conn.connect();
    const before = runtimes.length;
    await conn.connect();
    expect(runtimes.length).toBeGreaterThan(before);
    expect(conn.runtime.status).toBe(McpServerStatus.error);
  });

  it("the connection log is tail-capped at 50 entries", async () => {
    const { conn } = makeConn();
    for (let i = 0; i < 30; i++) await conn.connect();
    const logs = conn.runtime.logs;
    expect(logs.length).toBeLessThanOrEqual(50);
    expect(logs[logs.length - 1]).toContain(FAIL_PREFIX);
  });
});

describe("disconnect() lifecycle", () => {
  it("a never-connected disconnect() marks the instance disposed + disconnected", async () => {
    const { conn } = makeConn();
    await conn.disconnect();
    expect(conn.runtime.status).toBe(McpServerStatus.disconnected);
    expect(conn.runtime.connectedAt).toBeNull();
    expect(conn.runtime.error).toBe("");
  });

  it("connect() after dispose() is a no-op (disposed guard returns immediately)", async () => {
    const { conn, runtimes } = makeConn();
    await conn.disconnect();
    const before = runtimes.length;
    await conn.connect();
    expect(runtimes.length).toBe(before);
    expect(conn.runtime.status).toBe(McpServerStatus.disconnected);
  });
});

describe("transportFactory seam (inert transport bounds the handshake)", () => {
  it("an inert transport (send resolves, never replies) hits the error state via timeout", async () => {
    const inert: McpTransport = {
      async start() { /* no-op */ },
      async send(_m: unknown) { /* resolve, never reply */ },
      async close() { /* no-op */ },
    };
    const runtimes: McpServerRuntime[] = [];
    const conn = new McpConnection({
      config: makeConfig({ timeoutMs: 500 }),
      onRuntime: (r) => runtimes.push(r),
      transportFactory: async () => inert,
    });
    const t0 = Date.now();
    await conn.connect();
    const elapsed = Date.now() - t0;
    expect(conn.runtime.status).toBe(McpServerStatus.error);
    expect(elapsed).toBeLessThan(4000);
    expect(runtimes[runtimes.length - 1].status).toBe(McpServerStatus.error);
  });
});
