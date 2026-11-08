// InMemoryTransport-based unit test for McpManager.
//
// Strategy: build a REAL SDK McpServer (one tool, one resource, one prompt)
// and connect it to the client side of an InMemoryTransport linked pair. The
// manager is handed the client transport via the transportFactory injection
// point, so no network / stdio process is spawned.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp';
import type { Implementation } from '@modelcontextprotocol/sdk/types';
import { z } from 'zod';

import {
  McpManager,
  InMemoryMcpStore,
  McpServerStatus,
  McpTransportKind,
  McpToolExposure,
  type McpServerConfig,
} from '../src/mcp/index.js';

const SERVER_ID = 'test-srv';
const RES_URI = 'memory://test/res.txt';

const serverImpl: Implementation = { name: 'test-mcp-server', version: '0.0.1' };

function makeConfig(): McpServerConfig {
  return {
    id: SERVER_ID,
    name: 'Test Server',
    enabled: true,
    autoConnect: false,
    // transport kind is irrelevant when a transportFactory is supplied, but
    // the config must still be a valid streamable-http shape.
    transport: McpTransportKind.streamableHttp,
    url: 'http://in-memory.test/mcp',
    command: '',
    args: [],
    workingDirectory: '',
    headers: {},
    env: {},
    timeoutMs: 5000,
    proxy: '',
    oauth: false,
    oauthScopes: [],
    oauthClientId: '',
    oauthClientSecret: '',
    toolExposure: McpToolExposure.all,
    allowedTools: [],
    maxTools: 20,
    exposeResources: true,
    exposePrompts: true,
  };
}

let clientTransport: InMemoryTransport;
let serverTransport: InMemoryTransport;
let server: McpServer;
let manager: McpManager;

beforeAll(async () => {
  [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

  server = new McpServer(serverImpl);

  // Tool 1: no-arg
  server.registerTool('echo', { description: 'Echo back a fixed string' }, () => ({
    content: [{ type: 'text' as const, text: 'echoed' }],
  }));

  // Tool 2: zod input schema so call args round-trip and get validated.
  server.registerTool(
    'sum',
    {
      description: 'Add two numbers',
      inputSchema: { a: z.number(), b: z.number() },
    },
    (args) => ({
      content: [{ type: 'text' as const, text: String(args.a + args.b) }],
    }),
  );

  // Resource
  server.registerResource('res', RES_URI, { mimeType: 'text/plain' }, () => ({
    contents: [{ uri: RES_URI, mimeType: 'text/plain', text: 'hello from resource' }],
  }));

  // Prompt
  server.registerPrompt('greet', { description: 'A greeting prompt' }, () => ({
    messages: [
      {
        role: 'user' as const,
        content: { type: 'text' as const, text: 'hello prompt' },
      },
    ],
  }));

  await server.connect(serverTransport);

  manager = new McpManager({
    store: new InMemoryMcpStore(),
    transportFactory: async () => clientTransport,
  });
  manager.loadConfigsForTesting([makeConfig()]);
}, 15000);

afterAll(async () => {
  await manager.disconnect(SERVER_ID);
  await server.close();
  await clientTransport.close().catch(() => {});
  await serverTransport.close().catch(() => {});
});

describe('McpManager over InMemoryTransport', () => {
  it('connects and populates tools / resources / prompts', async () => {
    await manager.connect(SERVER_ID);
    const runtime = manager.runtimeFor(SERVER_ID);
    expect(runtime).not.toBeNull();
    expect(runtime!.status).toBe(McpServerStatus.connected);

    const toolNames = runtime!.tools.map((t) => t.name).sort();
    expect(toolNames).toContain('echo');
    expect(toolNames).toContain('sum');

    expect(runtime!.resources.length).toBe(1);
    expect(runtime!.resources[0].uri).toBe(RES_URI);

    expect(runtime!.prompts.length).toBe(1);
    expect(runtime!.prompts[0].name).toBe('greet');
  });

  it('buildAgentTools exposes mcp__ adapters + side-tools', () => {
    const tools = manager.buildAgentTools();
    expect(tools.length).toBeGreaterThan(0);
    const names = tools.map((t) => t.name);
    expect(names.some((n) => n.includes('echo'))).toBe(true);
    expect(names.some((n) => n.includes('sum'))).toBe(true);
    // resource side-tools
    expect(names.some((n) => n.includes('list_resources'))).toBe(true);
    expect(names.some((n) => n.includes('read_resource'))).toBe(true);
    // prompt side-tools
    expect(names.some((n) => n.includes('list_prompts'))).toBe(true);
    expect(names.some((n) => n.includes('get_prompt'))).toBe(true);
  });

  it('callMcpTool round-trips typed args (sum 3+4 -> 7)', async () => {
    const result = await manager.callMcpTool(SERVER_ID, 'sum', { a: 3, b: 4 });
    expect(result.isError).toBe(false);
    expect(result.text).toBe('7');
  });

  it('callMcpTool returns no-arg tool text', async () => {
    const result = await manager.callMcpTool(SERVER_ID, 'echo', {});
    expect(result.isError).toBe(false);
    expect(result.text).toBe('echoed');
  });

  it('readMcpResource returns resource text', async () => {
    const text = await manager.readMcpResource(SERVER_ID, RES_URI);
    expect(text).toContain('hello from resource');
  });

  it('getMcpPrompt returns prompt text', async () => {
    const text = await manager.getMcpPrompt(SERVER_ID, 'greet');
    expect(text).toContain('hello prompt');
  });

  it('disconnect marks runtime disconnected and clears tools', async () => {
    await manager.disconnect(SERVER_ID);
    const runtime = manager.runtimeFor(SERVER_ID);
    expect(runtime).not.toBeNull();
    expect(runtime!.status).toBe(McpServerStatus.disconnected);
    expect(runtime!.tools.length).toBe(0);
  });
});
