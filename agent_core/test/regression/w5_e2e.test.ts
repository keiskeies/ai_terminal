// W5 e2e: tool execution + multi-host + streaming cancel (AGENTS.md R9 e2e rule).
//
// These five cases exercise the assembled pipeline end-to-end (free-text args ->
// ToolArgs parse -> tool -> dispatcher result event; and the engine's R1
// generation guard), not just the individual units. They cover the three W5
// categories called out in docs/agent-core-migration-design.md.
import {describe, it, expect} from 'vitest';
import {ToolDispatcher} from '../../src/tools/dispatcher.js';
import {buildDefaultToolRegistry, registerOrchestratorTools} from '../../src/tools/index.js';
import {
  ExecOnTool, ExecBatchTool, CommandFailureKind,
} from '../../src/tools/orchestrator.js';
import type {
  OrchestratorExecutor, OrchestratorResult, OrchestratorConnectivity, ExecuteBatchOptions,
} from '../../src/tools/orchestrator.js';
import {ReActEngine} from '../../src/react/engine.js';
import type {LlmClient} from '../../src/llm/clients.js';
import {ModelConfig, AgentEvent} from '../../src/rpc/schema.js';

const NL = String.fromCharCode(10);
const mc: ModelConfig = {provider: 'openai', model: 'gpt-e2e'};
const CMD_KW = '命令:';

// ── canned result helpers (mirror orchestrator.ts shapes) ──
function ok(stdout = '', exitCode = 0): OrchestratorResult {
  return {stdout, stderr: '', exitCode, durationMs: 5, success: exitCode === 0, failureKind: CommandFailureKind.none};
}
function failed(stderr: string, exitCode = 1, kind: string = 'unknown'): OrchestratorResult {
  return {stdout: '', stderr, exitCode, durationMs: 5, success: false, failureKind: kind};
}
function skipped(): OrchestratorResult {
  return {stdout: '', stderr: '已跳过（前序主机失败）', exitCode: -1, durationMs: 0, success: false};
}

// A fake executor that drives the two exec tools. The batch path honours
// stopOnFailure the same way the real ReverseRpcOrchestrator serial loop does,
// so the e2e can assert the skipped-host marker survives into the tool output.
class FakeExecutor implements OrchestratorExecutor {
  constructor(private readonly one: Record<string, OrchestratorResult | null> = {}) {}
  async executeOn(hostId: string): Promise<OrchestratorResult | null> {
    // 'in' (not '??') so an explicit null (not-connected marker) is returned verbatim.
    return hostId in this.one ? this.one[hostId] : ok();
  }
  async executeBatch(hostIds: string[], _cmd: string, opts: ExecuteBatchOptions): Promise<Map<string, OrchestratorResult>> {
    const m = new Map<string, OrchestratorResult>();
    for (let i = 0; i < hostIds.length; i++) {
      const h = hostIds[i];
      const r = h in this.one ? this.one[h] : ok();
      m.set(h, r);
      const stopNow = opts.stopOnFailure && !r.success;
      if (stopNow) {
        for (let j = i + 1; j < hostIds.length; j++) m.set(hostIds[j], skipped());
        break;
      }
    }
    return m;
  }
  async checkConnectivity(_o: {fromHostId: string; targetHost: string; port: number; timeoutMs?: number}): Promise<OrchestratorConnectivity> {
    return {fromHostId: 'w', targetHost: 't', port: 1, reachable: true, elapsedMs: 1, summary: 'w -> t:1 ✓'};
  }
}

function fullRegistry(exec: OrchestratorExecutor) {
  const reg = buildDefaultToolRegistry();
  registerOrchestratorTools(reg, exec);
  return reg;
}

// ── 1 + 2: tool execution (exec_on success / not-connected) ──
describe('W5 e2e — tool execution', () => {
  it('exec_on success folds host + output into a stable result event', async () => {
    const d = new ToolDispatcher(fullRegistry(new FakeExecutor({web1: ok('ok out')})));
    const o = await d.dispatch({toolName: 'exec_on', argsText: 'hostId: web1' + NL + 'command: echo hi', hostId: 'web1'});
    expect(o.executed).toBe(true);
    expect(o.event.success).toBe(true);
    expect(o.event.output).toContain('[web1]');
    expect(o.event.output).toContain('ok out');
  });

  it('exec_on not-connected surfaces a failed result (success=false)', async () => {
    const d = new ToolDispatcher(fullRegistry(new FakeExecutor({ghost: null})));
    const o = await d.dispatch({toolName: 'exec_on', argsText: 'hostId: ghost' + NL + 'command: x', hostId: 'ghost'});
    expect(o.executed).toBe(true);
    expect(o.event.success).toBe(false);
    expect(o.event.failureKind).toBeUndefined(); // not a dispatcher-level failure
    expect((o.event as {error?: string}).error).toContain('未连接或不存在');
  });
});

// ── 3 + 4: multi-host (batch aggregation + stopOnFailure skip) ──
describe('W5 e2e — multi-host', () => {
  it('exec_batch aggregates per-host results with one host failing', async () => {
    const d = new ToolDispatcher(fullRegistry(new FakeExecutor({web1: ok(), web2: ok(), db1: failed('denied', 127, 'permissionDenied')})));
    const o = await d.dispatch({toolName: 'exec_batch', argsText: 'hostIds: web1,web2,db1' + NL + 'command: rm -rf x'});
    expect(o.executed).toBe(true);
    expect(o.event.success).toBe(false);
    const hr = o.event.hostResults as Record<string, {success: boolean; failureKind?: string}>;
    expect(hr.web1.success).toBe(true);
    expect(hr.db1.success).toBe(false);
    expect(hr.db1.failureKind).toBe('permissionDenied');
    expect(Object.keys(hr).length).toBe(3);
  });

  it('exec_batch stopOnFailure marks the remaining hosts skipped', async () => {
    const d = new ToolDispatcher(fullRegistry(new FakeExecutor({a: failed('boom'), b: ok(), c: ok()})));
    const o = await d.dispatch({toolName: 'exec_batch', argsText: 'hostIds: a,b,c' + NL + 'command: rm -rf x' + NL + 'stopOnFailure: true'});
    const hr = o.event.hostResults as Record<string, {success: boolean}>;
    expect(hr.a.success).toBe(false);
    expect(hr.b.success).toBe(false); // skipped, not ok
    expect(hr.c.success).toBe(false);
    expect(o.event.output).toContain('已跳过');
  });
});

// ── 5: streaming cancel (R1 generation guard) ──
class GatedLlm implements LlmClient {
  readonly name = 'gated';
  private release!: () => void;
  private readonly gate: Promise<void> = new Promise<void>((r) => { this.release = r; });
  constructor(private readonly text: string) {}
  async chatStream(): Promise<{text: string; reasoning: string}> {
    await this.gate; // the stream is in flight here
    return {text: this.text, reasoning: ''};
  }
  open() { this.release(); }
}

describe('W5 e2e — streaming cancel', () => {
  it('engine.cancel() mid-stream -> interrupted, no result/finish emitted', async () => {
    const emitted: AgentEvent[] = [];
    const finished: string[] = [];
    const llm = new GatedLlm(CMD_KW + ' ls -la');
    const engine = new ReActEngine(llm, mc, {onEvent: (e) => emitted.push(e), onFinished: (s) => finished.push(s)});
    const runP = engine.run({taskId: 't', goal: 'list files', hostId: 'h1', modelConfig: mc}, 3);
    llm.open();      // let the in-flight stream resolve
    engine.cancel(); // bump the generation + set cancelled while the await is settling
    const state = await runP;
    expect(state).toBe('interrupted');
    // R1: the post-await generation check dropped the stale write -> no command/result/finish
    expect(emitted.find((e) => e.type === 'result')).toBeUndefined();
    expect(emitted.find((e) => e.type === 'finish')).toBeUndefined();
    expect(finished).toEqual([]);
  });
});
