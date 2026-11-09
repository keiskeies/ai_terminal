it('each request gets a distinct + monotonically-increasing rev- id (R4)', async () => {
    // The deterministic counter (rev-1, rev-2, ...) guarantees no collision
    // AND stable ordering. This is the invariant the old Math.random() lacked.
    const t = new FakeTransport();
    t.register('rpc:invokeSsh', { exitCode: 0, output: '', durationMs: 0 });
    const client = makeClient(t);
    for (let i = 0; i < 20; i++) await client.invokeSsh({ hostId: 'h' + i, command: 'x' });
    const ids = t.sent.map((r) => r.id);
    for (const id of ids) expect(id).toMatch(/^rev-/);
    expect(new Set(ids).size).toBe(20);
    const nums = ids.map((id) => parseInt(id.slice(4), 36));
    for (let i = 1; i < nums.length; i++) expect(nums[i]).toBe(nums[i - 1] + 1);
  });// Reverse-RPC bridge unit test (Phase 2 W5: rpc:invokeSsh / invokeSftp /
// queryKnowledge / saveSession / callDartTool).
//
// A real Dart parent cannot be spawned in CI, so we drive ReverseRpcClient
// against a fake RpcTransport that records the outgoing request and returns a
// canned response — proving the correlation (rev- id prefix, request shape,
// typed resolution) and the error-rejection path without a live process.
import { describe, it, expect } from 'vitest';
import { ReverseRpcClient } from '../src/rpc/client.js';
import type {
  RpcTransport,
  JsonRpcRequest,
  JsonRpcNotification,
} from '../src/rpc/transport.js';

class FakeTransport implements RpcTransport {
  readonly sent: JsonRpcRequest[] = [];
    private errors = new Map<string, { code: number; message: string }>();
  private _closed = false;

  // Per-method canned results for the test to register.
  register(method: string, result: unknown): void {
    this.byMethod.set(method, result);
  }
  private byMethod = new Map<string, unknown>();

  get closed(): boolean { return this._closed; }

  async request<T>(msg: JsonRpcRequest): Promise<T> {
    this.sent.push(msg);
    // Resolve from the canned per-method result keyed by the request method.
    const key = msg.method;
    const err = this.errors.get(key);
    if (err != null) {
      throw new Error('RPC error ' + err.code + ': ' + err.message);
    }
    const result = this.byMethod.get(key);
    if (result === undefined) {
      throw new Error('no canned response for ' + key);
    }
    return result as T;
  }
  notify(_msg: JsonRpcNotification): void {}
  respond(_id: string, _result: unknown): void {}
  reject(_id: string, _code: number, _message: string, _data?: unknown): void {}
  onNotification(_handler: (n: JsonRpcNotification) => void): void {}
  onRequest(_handler: (r: JsonRpcRequest) => void): void {}
  close(): void { this._closed = true; }
}

function makeClient(transport: FakeTransport): ReverseRpcClient {
  return new ReverseRpcClient(transport as unknown as RpcTransport);
}

describe('ReverseRpcClient (Phase 2 W5)', () => {
  it('invokeSsh sends rpc:invokeSsh with a rev- request id', async () => {
    const t = new FakeTransport();
    t.register('rpc:invokeSsh', { exitCode: 0, output: 'ok', durationMs: 12 });
    const client = makeClient(t);

    const res = await client.invokeSsh({ hostId: 'web1', command: 'uptime' });

    expect(res.exitCode).toBe(0);
    expect(res.output).toBe('ok');
    expect(t.sent.length).toBe(1);
    const req = t.sent[0];
    expect(req.method).toBe('rpc:invokeSsh');
    expect(req.jsonrpc).toBe('2.0');
    expect(req.id).toMatch(/^rev-/);
    expect(req.params).toEqual({ hostId: 'web1', command: 'uptime' });
  });

  it('invokeSftp forwards hostId + op + paths', async () => {
    const t = new FakeTransport();
    t.register('rpc:invokeSftp', { success: true, output: 'transferred' });
    const client = makeClient(t);

    const res = await client.invokeSftp({
      hostId: 'web1',
      op: 'upload',
      localPath: '/tmp/a.txt',
      remotePath: '/remote/a.txt',
    });
    expect(res.success).toBe(true);
    const req = t.sent[0];
    expect(req.method).toBe('rpc:invokeSftp');
    expect(req.params).toEqual({
      hostId: 'web1',
      op: 'upload',
      localPath: '/tmp/a.txt',
      remotePath: '/remote/a.txt',
    });
  });

  it('queryKnowledge returns typed FTS5 hits', async () => {
    const t = new FakeTransport();
    t.register('rpc:queryKnowledge', {
      hits: [{ id: 'k1', title: 'T', content: 'C', score: 0.9 }],
    });
    const client = makeClient(t);

    const res = await client.queryKnowledge({ query: 'ssh', limit: 3 });
    expect(res.hits.length).toBe(1);
    expect(res.hits[0].id).toBe('k1');
    expect(t.sent[0].method).toBe('rpc:queryKnowledge');
  });

  it('saveSession + callDartTool round-trip', async () => {
    const t = new FakeTransport();
    t.register('rpc:saveSession', { ok: true });
    t.register('rpc:callDartTool', { success: true, output: 'done' });
    const client = makeClient(t);

    await client.saveSession({ taskId: 't1', events: [] });
    const tool = await client.callDartTool({ toolName: 'x', args: {} });
    expect(tool.success).toBe(true);
    expect(t.sent.map((r) => r.method)).toEqual(['rpc:saveSession', 'rpc:callDartTool']);
  });

  it('each request gets a distinct rev- id (no correlation collision)', async () => {
    const t = new FakeTransport();
    t.register('rpc:invokeSsh', { exitCode: 0, output: '', durationMs: 0 });
    const client = makeClient(t);
    await client.invokeSsh({ hostId: 'a', command: 'x' });
    await client.invokeSsh({ hostId: 'b', command: 'y' });
    const ids = t.sent.map((r) => r.id);
    expect(new Set(ids).size).toBe(2);
    for (const id of ids) expect(id).toMatch(/^rev-/);
  });

  it('rejects when the Dart side returns an RPC error', async () => {
    const t = new FakeTransport();
    t.errors.set('rpc:invokeSsh', { code: -32601, message: 'method not found' });
    const client = makeClient(t);
    await expect(
      client.invokeSsh({ hostId: 'web1', command: 'uptime' }),
    ).rejects.toThrow(/RPC error -32601/);
  });
});
