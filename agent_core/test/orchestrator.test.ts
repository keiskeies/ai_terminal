// Orchestrator tool layer unit test (Phase 2 W5: exec_on / exec_batch /
// check_connectivity + ReverseRpcOrchestrator adapter).
//
// A real Dart SSH pool cannot exist in CI, so the tools are driven by a fake
// OrchestratorExecutor that returns canned OrchestratorResult shapes, and the
// ReverseRpcOrchestrator adapter is driven by a fake ReverseRpcClient.
import { describe, it, expect } from 'vitest';
import {
  ExecOnTool,
  ExecBatchTool,
  CheckConnectivityTool,
  ReverseRpcOrchestrator,
  CommandFailureKind,
  isReadOnlyCommand,
  isValidHost,
} from '../src/tools/orchestrator.js';
import type {
  OrchestratorExecutor,
  OrchestratorResult,
  OrchestratorConnectivity,
  ExecuteBatchOptions,
} from '../src/tools/orchestrator.js';
import { ToolArgs } from '../src/tools/tool_args.js';
import type { ToolContext } from '../src/tools/builtin.js';
import type { ReverseRpcClient } from '../src/rpc/client.js';

const ctx: ToolContext = { cancelled: () => false };

function ok(exitCode = 0, stdout = '', stderr = ''): OrchestratorResult {
  return { stdout, stderr, exitCode, durationMs: 12, success: exitCode === 0, failureKind: CommandFailureKind.none };
}
function fail(stderr = 'boom', exitCode = 1, kind?: string): OrchestratorResult {
  return { stdout: '', stderr, exitCode, durationMs: 8, success: false, failureKind: kind ?? CommandFailureKind.unknown };
}

class FakeExecutor implements OrchestratorExecutor {
  calls: Array<{ method: string; host?: string; command?: string }> = [];
  onOne?: (hostId: string, command: string) => OrchestratorResult | null;
  async executeOn(hostId: string, command: string): Promise<OrchestratorResult | null> {
    this.calls.push({ method: 'executeOn', host: hostId, command });
    return this.onOne ? this.onOne(hostId, command) : ok();
  }
  async executeBatch(hostIds: string[], command: string, opts: ExecuteBatchOptions): Promise<Map<string, OrchestratorResult>> {
    this.calls.push({ method: 'executeBatch', command });
    const m = new Map<string, OrchestratorResult>();
    for (const h of hostIds) m.set(h, this.onOne ? this.onOne(h, command) ?? fail('not connected', -1) : ok());
    return m;
  }
  async checkConnectivity(o: { fromHostId: string; targetHost: string; port: number }): Promise<OrchestratorConnectivity> {
    this.calls.push({ method: 'checkConnectivity', host: o.fromHostId });
    return {
      fromHostId: o.fromHostId, targetHost: o.targetHost, port: o.port,
      reachable: o.port > 0, detail: o.port > 0 ? undefined : 'unreachable',
      elapsedMs: 3,
      summary: (o.port > 0 ? '✓' : '✗') + ' ' + o.fromHostId + ' -> ' + o.targetHost + ':' + o.port,
    };
  }
}

describe('ExecOnTool (exec_on)', () => {
  it('succeeds and folds output into a result', async () => {
    const ex = new FakeExecutor();
    ex.onOne = () => ok(0, 'hello world');
    const t = new ExecOnTool(ex);
    expect(t.name).toBe('exec_on');
    const res = await t.execute(ToolArgs.wrap({ hostId: 'web1', command: 'echo hi' }), ctx);
    expect(res.success).toBe(true);
    expect(res.output).toContain('[web1]');
    expect(res.output).toContain('hello world');
    expect(ex.calls[0].method).toBe('executeOn');
    expect(ex.calls[0].host).toBe('web1');
  });

  it('reports non-zero exit as a failure', async () => {
    const ex = new FakeExecutor();
    ex.onOne = () => fail('perm denied', 127, 'permissionDenied');
    const t = new ExecOnTool(ex);
    const res = await t.execute(ToolArgs.wrap({ hostId: 'db1', command: 'x' }), ctx);
    expect(res.success).toBe(false);
    expect(res.error).toContain('db1');
    expect(res.error).toContain('permissionDenied');
  });

  it('surfaces not-connected when the executor returns null', async () => {
    const ex = new FakeExecutor();
    ex.onOne = () => null;
    const t = new ExecOnTool(ex);
    const res = await t.execute(ToolArgs.wrap({ hostId: 'ghost', command: 'x' }), ctx);
    expect(res.success).toBe(false);
    expect(res.error).toContain('未连接或不存在');
  });

  it('rejects missing required params', async () => {
    const t = new ExecOnTool(new FakeExecutor());
    const res = await t.execute(ToolArgs.EMPTY, ctx);
    expect(res.success).toBe(false);
    expect(res.error).toContain('参数缺失');
  });
});

describe('ExecBatchTool (exec_batch)', () => {
  it('aggregates all-success batch with per-host results', async () => {
    const ex = new FakeExecutor();
    ex.onOne = () => ok(0, 'ok');
    const t = new ExecBatchTool(ex);
    const res = await t.execute(ToolArgs.parse('hostIds: web1,web2,db1\ncommand: uptime'), ctx);
    expect(res.success).toBe(true);
    expect(res.output).toContain('结果: 3/3 成功');
    expect(res.hostResults?.['web1']?.success).toBe(true);
    expect(res.hostResults?.['db1']?.success).toBe(true);
    expect(Object.keys(res.hostResults ?? {}).length).toBe(3);
  });

  it('reports partial failure with failure kind carried through', async () => {
    const ex = new FakeExecutor();
    ex.onOne = (h) => (h === 'db1' ? fail('denied', 127, 'permissionDenied') : ok(0, 'fine'));
    const t = new ExecBatchTool(ex);
    const res = await t.execute(ToolArgs.parse('hostIds: web1,web2,db1\ncommand: rm -f x'), ctx);
    expect(res.success).toBe(false);
    expect(res.error).toContain('1/3 台主机执行失败');
    expect(res.hostResults?.['db1']?.success).toBe(false);
    expect(res.hostResults?.['db1']?.failureKind).toBe('permissionDenied');
    expect(res.hostResults?.['web1']?.success).toBe(true);
  });

  it('rejects empty hostIds', async () => {
    const t = new ExecBatchTool(new FakeExecutor());
    const res = await t.execute(ToolArgs.parse('command: uptime'), ctx);
    expect(res.success).toBe(false);
    expect(res.error).toContain('参数缺失');
  });
});

describe('CheckConnectivityTool (check_connectivity)', () => {
  it('succeeds when the probe reports reachable', async () => {
    const ex = new FakeExecutor();
    const t = new CheckConnectivityTool(ex);
    const res = await t.execute(ToolArgs.wrap({ fromHostId: 'web1', targetHost: '10.0.0.5', port: 3306 }), ctx);
    expect(res.success).toBe(true);
  });

  it('rejects non-positive port', async () => {
    const t = new CheckConnectivityTool(new FakeExecutor());
    const res = await t.execute(ToolArgs.wrap({ fromHostId: 'w', targetHost: 'a', port: 0 }), ctx);
    expect(res.success).toBe(false);
    expect(res.error).toContain('参数缺失或无效');
  });

  it('fails with detail when the probe is unreachable', async () => {
    // a dedicated executor that reports unreachable with a detail string
    const ex: OrchestratorExecutor = {
      executeOn: async () => ok(),
      executeBatch: async (hids, _cmd) => { const m = new Map<string, OrchestratorResult>(); for (const h of hids) m.set(h, ok()); return m; },
      checkConnectivity: async (o) => ({
        fromHostId: o.fromHostId, targetHost: o.targetHost, port: o.port,
        reachable: false, detail: '连接超时或被拒绝', elapsedMs: 5002,
        summary: o.fromHostId + ' -> ' + o.targetHost + ':' + o.port + ' ✗',
      }),
    };
    const t = new CheckConnectivityTool(ex);
    const res = await t.execute(ToolArgs.wrap({ fromHostId: 'web1', targetHost: 'db.local', port: 3306 }), ctx);
    expect(res.success).toBe(false);
    expect(res.error).toBe('连接超时或被拒绝');
  });
});

describe('pure helpers', () => {
  it('classifies read-only vs mutating commands', () => {
    // Existing baseline cases
    expect(isReadOnlyCommand('ls -la /tmp')).toBe(true);
    expect(isReadOnlyCommand('cat /etc/hosts')).toBe(true);
    expect(isReadOnlyCommand('rm -rf /x')).toBe(false);
    expect(isReadOnlyCommand('apt update && apt install foo')).toBe(false);
    expect(isReadOnlyCommand('echo hi > out')).toBe(false);
  });

  it('R7: mutating flags/subcommands on read-only heads force serial (never parallel)', () => {
    // find with mutating flags
    expect(isReadOnlyCommand('find / -delete')).toBe(false);
    expect(isReadOnlyCommand('find / -exec rm {} \\;')).toBe(false);
    expect(isReadOnlyCommand('find / -ok rm {} \\;')).toBe(false);
    expect(isReadOnlyCommand('find / -execdir echo {}')).toBe(false);
    // mount with mutating flags
    expect(isReadOnlyCommand('mount -o remount /')).toBe(false);
    expect(isReadOnlyCommand('mount -t ext4 /dev/sda1 /mnt')).toBe(false);
    expect(isReadOnlyCommand('mount --bind /src /dst')).toBe(false);
    expect(isReadOnlyCommand('mount -u /mnt')).toBe(false);
    // docker mutating subcommands
    expect(isReadOnlyCommand('docker rm c')).toBe(false);
    expect(isReadOnlyCommand('docker stop c')).toBe(false);
    expect(isReadOnlyCommand('docker kill c')).toBe(false);
    expect(isReadOnlyCommand('docker exec c cmd')).toBe(false);
    expect(isReadOnlyCommand('docker build -t img .')).toBe(false);
    expect(isReadOnlyCommand('docker push img')).toBe(false);
    // kubectl mutating subcommands
    expect(isReadOnlyCommand('kubectl delete pod x')).toBe(false);
    expect(isReadOnlyCommand('kubectl apply -f x.yaml')).toBe(false);
    expect(isReadOnlyCommand('kubectl create ns x')).toBe(false);
    expect(isReadOnlyCommand('kubectl scale --replicas=2 x')).toBe(false);
    // systemctl mutating subcommands
    expect(isReadOnlyCommand('systemctl stop ssh')).toBe(false);
    expect(isReadOnlyCommand('systemctl enable ssh')).toBe(false);
    expect(isReadOnlyCommand('systemctl restart ssh')).toBe(false);
    expect(isReadOnlyCommand('systemctl mask ssh')).toBe(false);
    // git mutating subcommands
    expect(isReadOnlyCommand('git push origin main')).toBe(false);
    expect(isReadOnlyCommand('git commit -m x')).toBe(false);
    expect(isReadOnlyCommand('git checkout main')).toBe(false);
    expect(isReadOnlyCommand('git reset --hard')).toBe(false);
    expect(isReadOnlyCommand('git clean -f')).toBe(false);
    expect(isReadOnlyCommand('git rebase main')).toBe(false);
    expect(isReadOnlyCommand('git merge main')).toBe(false);
    expect(isReadOnlyCommand('git stash')).toBe(false);
  });

  it('R7: read-only multi-subcommand heads are recognized as parallel-safe', () => {
    // docker read-only subcommands
    expect(isReadOnlyCommand('docker ps')).toBe(true);
    expect(isReadOnlyCommand('docker images')).toBe(true);
    expect(isReadOnlyCommand('docker logs c')).toBe(true);
    expect(isReadOnlyCommand('docker inspect c')).toBe(true);
    expect(isReadOnlyCommand('docker port c')).toBe(true);
    expect(isReadOnlyCommand('docker top c')).toBe(true);
    expect(isReadOnlyCommand('docker history c')).toBe(true);
    // kubectl read-only subcommands
    expect(isReadOnlyCommand('kubectl get pods')).toBe(true);
    expect(isReadOnlyCommand('kubectl describe pod x')).toBe(true);
    expect(isReadOnlyCommand('kubectl logs pod x')).toBe(true);
    expect(isReadOnlyCommand('kubectl top pods')).toBe(true);
    // systemctl read-only subcommands
    expect(isReadOnlyCommand('systemctl status ssh')).toBe(true);
    expect(isReadOnlyCommand('systemctl show ssh')).toBe(true);
    expect(isReadOnlyCommand('systemctl is-active ssh')).toBe(true);
    expect(isReadOnlyCommand('systemctl is-enabled ssh')).toBe(true);
    // git read-only subcommands
    expect(isReadOnlyCommand('git log')).toBe(true);
    expect(isReadOnlyCommand('git status')).toBe(true);
    expect(isReadOnlyCommand('git diff')).toBe(true);
    expect(isReadOnlyCommand('git show')).toBe(true);
    expect(isReadOnlyCommand('git branch')).toBe(true);
    expect(isReadOnlyCommand('git tag')).toBe(true);
    // ip / ss read-only
    expect(isReadOnlyCommand('ip addr')).toBe(true);
    expect(isReadOnlyCommand('ip route')).toBe(true);
    expect(isReadOnlyCommand('ip link')).toBe(true);
    expect(isReadOnlyCommand('ss -tlnp')).toBe(true);
    // single-word read-only heads with non-mutating flags
    expect(isReadOnlyCommand('ps -o user,cmd')).toBe(true);
    expect(isReadOnlyCommand('top -b -n1')).toBe(true);
    expect(isReadOnlyCommand('journalctl -u sshd --since 1h')).toBe(true);
    expect(isReadOnlyCommand('ifconfig eth0')).toBe(true);
    expect(isReadOnlyCommand('uname -a')).toBe(true);
    expect(isReadOnlyCommand('df -h')).toBe(true);
    expect(isReadOnlyCommand('du -sh /tmp')).toBe(true);
    expect(isReadOnlyCommand('grep -r foo /etc')).toBe(true);
    expect(isReadOnlyCommand('tail -n 20 /var/log/x')).toBe(true);
    expect(isReadOnlyCommand('head -n 10 /var/log/x')).toBe(true);
    expect(isReadOnlyCommand('stat /tmp')).toBe(true);
    expect(isReadOnlyCommand('free -m')).toBe(true);
    expect(isReadOnlyCommand('which curl')).toBe(true);
    expect(isReadOnlyCommand('whoami')).toBe(true);
    expect(isReadOnlyCommand('hostname')).toBe(true);
    expect(isReadOnlyCommand('pwd')).toBe(true);
    expect(isReadOnlyCommand('env')).toBe(true);
    expect(isReadOnlyCommand('uptime')).toBe(true);
    expect(isReadOnlyCommand('netstat -tlnp')).toBe(true);
  });

  it('R7: compound/redirect/backtick commands are never read-only', () => {
    expect(isReadOnlyCommand('ls; rm -rf /')).toBe(false);
    expect(isReadOnlyCommand('ls | rm')).toBe(false);
    expect(isReadOnlyCommand('ls && rm -rf /')).toBe(false);
    expect(isReadOnlyCommand('cat /etc/passwd > /tmp/x')).toBe(false);
    expect(isReadOnlyCommand('echo $(rm -rf /)')).toBe(false);
    expect(isReadOnlyCommand('echo `rm -rf /`')).toBe(false);
    expect(isReadOnlyCommand('')).toBe(false);
    expect(isReadOnlyCommand('   ')).toBe(false);
  });


  it('validates target hosts strictly (R7)', () => {
    expect(isValidHost('10.0.0.1')).toBe(true);
    expect(isValidHost('db.local')).toBe(true);
    expect(isValidHost('a|rm -rf /')).toBe(false);
    expect(isValidHost('$(evil)')).toBe(false);
    expect(isValidHost('')).toBe(false);
  });
});

describe('ReverseRpcOrchestrator (adapter)', () => {
  function fakeClient(reply: { exitCode?: number; output?: string; error?: string; failureKind?: string }) {
    const c = {
      invokeSsh: async (_p: { hostId: string; command: string; timeoutMs?: number }) => ({
        exitCode: reply.exitCode ?? 0,
        output: reply.output ?? '',
        error: reply.error,
        durationMs: 4,
        failureKind: reply.failureKind,
      }),
    };
    return c as unknown as ReverseRpcClient;
  }

  it('maps a successful invokeSsh to a success result', async () => {
    const ex = new ReverseRpcOrchestrator(fakeClient({ exitCode: 0, output: 'done' }));
    const r = await ex.executeOn('web1', 'echo done');
    expect(r).not.toBeNull();
    expect(r!.success).toBe(true);
    expect(r!.stdout).toBe('done');
  });

  it('maps a timeout failureKind to timedOut + non-success', async () => {
    const ex = new ReverseRpcOrchestrator(fakeClient({ exitCode: 124, output: '', failureKind: 'timeout' }));
    const r = await ex.executeOn('web1', 'slow');
    expect(r!.success).toBe(false);
    expect(r!.timedOut).toBe(true);
    expect(r!.failureKind).toBe(CommandFailureKind.timeout);
  });

  it('treats an RPC refusal as not-connected (null)', async () => {
    const c = {
      invokeSsh: async () => { throw new Error('RPC error -32601: host not connected'); },
    } as unknown as ReverseRpcClient;
    const ex = new ReverseRpcOrchestrator(c);
    expect(await ex.executeOn('ghost', 'x')).toBeNull();
  });

  it('skips remaining serial hosts when stopOnFailure triggers', async () => {
    let calls = 0;
    const c = {
      invokeSsh: async (p: { hostId: string }) => ({
        exitCode: p.hostId === 'a' ? 1 : 0,
        output: '',
        durationMs: 1,
        failureKind: 'unknown',
      }),
    } as unknown as ReverseRpcClient;
    const ex = new ReverseRpcOrchestrator(c);
    const m = await ex.executeBatch(['a', 'b', 'c'], 'rm -rf x', { stopOnFailure: true, timeoutMs: 1000 });
    // mutating command -> serial; host a fails -> b and c are skipped
    expect(m.get('a')!.success).toBe(false);
    expect(m.get('b')!.stderr).toContain('已跳过');
    expect(m.get('c')!.stderr).toContain('已跳过');
    void calls;
  });

  it('runs read-only commands in parallel (all hosts present)', async () => {
    const c = {
      invokeSsh: async (p: { hostId: string }) => ({ exitCode: 0, output: 'ok', durationMs: 1, failureKind: 'none' }),
    } as unknown as ReverseRpcClient;
    const ex = new ReverseRpcOrchestrator(c);
    const m = await ex.executeBatch(['a', 'b', 'c'], 'uptime', { timeoutMs: 1000 });
    expect([...m.values()].every((r) => r.success)).toBe(true);
  });
});

// ReverseRpcOrchestrator.executeBatch: parallel/serial decision paths.
// Drives the REAL adapter through a fake ReverseRpcClient, covering branches
// that the FakeExecutor-based w5_e2e and earlier per-shape tests do not:
//   * read-only => parallel: a single host failure does NOT skip siblings
//   * parallel: an RPC refusal (null) on one host falls back to a skipped marker
//   * serial, no stopOnFailure: a mid-batch failure still runs the remaining hosts
//   * executeOn cancelled-flag short-circuit (no RPC call issued)
//   * checkConnectivity invalid-targetHost guard + source-not-connected

describe('ReverseRpcOrchestrator.executeBatch parallel/serial decision', () => {

  function clientByHost(replies: Record<string, { exitCode?: number; output?: string; error?: string; failureKind?: string }>) {
    const c = {
      invokeSsh: async (p: { hostId: string; command: string; timeoutMs?: number }) => {
        const r = replies[p.hostId];
        return {
          exitCode: r?.exitCode ?? 0,
          output: r?.output ?? "",
          error: r?.error,
          durationMs: 4,
          failureKind: r?.failureKind,
        };
      },
    } as unknown as ReverseRpcClient;
    return c;
  }

  it('read-only batch runs in parallel: a failing host does NOT skip its siblings', async () => {
    const ex = new ReverseRpcOrchestrator(
      clientByHost({
        web1: { exitCode: 0, output: "up1" },
        web2: { exitCode: 124, output: "", failureKind: "timeout" },
        web3: { exitCode: 0, output: "up3" },
      }),
    );
    const m = await ex.executeBatch(["web1", "web2", "web3"], "uptime", { timeoutMs: 1000 });
    expect(m.get("web1")!.success).toBe(true);
    expect(m.get("web2")!.success).toBe(false);
    expect(m.get("web2")!.timedOut).toBe(true);
    expect(m.get("web3")!.success).toBe(true);
    expect(m.get("web3")!.stderr).not.toContain("\u5DF2\u8DF3\u8FC7");
  });

  it('parallel batch: an RPC refusal (null) on one host falls back to a skipped marker', async () => {
    let ghostCalled = false;
    const c = {
      invokeSsh: async (p: { hostId: string }) => {
        if (p.hostId === "ghost") { ghostCalled = true; throw new Error("RPC refused"); }
        return { exitCode: 0, output: "ok", durationMs: 1, failureKind: "none" };
      },
    } as unknown as ReverseRpcClient;
    const ex = new ReverseRpcOrchestrator(c);
    const m = await ex.executeBatch(["ghost", "web1"], "uptime", { timeoutMs: 1000 });
    expect(ghostCalled).toBe(true);
    expect(m.get("ghost")!.success).toBe(false);
    expect(m.get("ghost")!.stderr).toContain("\u5DF2\u8DF3\u8FC7");
    expect(m.get("web1")!.success).toBe(true);
  });

  it('serial batch WITHOUT stopOnFailure still runs remaining hosts after a failure', async () => {
    const ex = new ReverseRpcOrchestrator(
      clientByHost({ a: { exitCode: 1, failureKind: "unknown" }, b: { exitCode: 0, output: "b" }, c: { exitCode: 0, output: "c" } }),
    );
    const m = await ex.executeBatch(["a", "b", "c"], "rm -rf x", { timeoutMs: 1000 });
    expect(m.get("a")!.success).toBe(false);
    expect(m.get("b")!.success).toBe(true);
    expect(m.get("c")!.success).toBe(true);
    for (const r of m.values()) expect(r.stderr).not.toContain("\u5DF2\u8DF3\u8FC7");
  });

  it('executeOn: cancelled flag short-circuits WITHOUT issuing an RPC call', async () => {
    let called = false;
    const c = {
      invokeSsh: async () => { called = true; return { exitCode: 0, output: "", durationMs: 1 }; },
    } as unknown as ReverseRpcClient;
    const ex = new ReverseRpcOrchestrator(c);
    const r = await ex.executeOn("web1", "uptime", 1000, () => true);
    expect(called).toBe(false);
    expect(r!.success).toBe(false);
    expect(r!.failureKind).toBe(CommandFailureKind.cancelled);
    expect(r!.stderr).toBe("cancelled");
  });
});

describe('ReverseRpcOrchestrator.checkConnectivity guards', () => {
  function clientByHost(replies: Record<string, { exitCode?: number; output?: string; failureKind?: string }>) {
    return {
      invokeSsh: async (p: { hostId: string }) => {
        const r = replies[p.hostId];
        return { exitCode: r?.exitCode ?? 0, output: r?.output ?? "", durationMs: 4, failureKind: r?.failureKind ?? "none" };
      },
    } as unknown as ReverseRpcClient;
  }

  it('rejects an invalid targetHost before any RPC is issued', async () => {
    let called = false;
    const c = {
      invokeSsh: async () => { called = true; return { exitCode: 0, output: "", durationMs: 1 }; },
    } as unknown as ReverseRpcClient;
    const ex = new ReverseRpcOrchestrator(c);
    const r = await ex.checkConnectivity({ fromHostId: "w", targetHost: "bad host;rm -rf /", port: 3306, timeoutMs: 1000 });
    expect(called).toBe(false);
    expect(r.reachable).toBe(false);
    expect(r.detail).toContain("\u683C\u5F0F\u975E\u6CD5");
  });

  it('reports the source host not-connected when the probe RPC is refused', async () => {
    const c = {
      invokeSsh: async () => { throw new Error("RPC refused"); },
    } as unknown as ReverseRpcClient;
    const ex = new ReverseRpcOrchestrator(c);
    const r = await ex.checkConnectivity({ fromHostId: "w", targetHost: "10.0.0.1", port: 3306 });
    expect(r.reachable).toBe(false);
    expect(r.detail).toContain("\u672A\u8FDE\u63A5");
  });

  it('reports reachable when the probe stdout carries CONNECT_OK', async () => {
    const ex = new ReverseRpcOrchestrator(
      clientByHost({ w: { output: "CONNECT_OK", exitCode: 0 } }),
    );
    const r = await ex.checkConnectivity({ fromHostId: "w", targetHost: "db.internal", port: 3306 });
    expect(r.reachable).toBe(true);
    expect(r.summary).toContain("\u2713");
  });
});
