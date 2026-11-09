import {describe, it, expect, vi} from 'vitest';
import {ReActEngine, CommandExecResult} from '../src/react/engine.js';
import {MockLlmClient} from '../src/llm/clients.js';

function makeTask(goal: string) {
  return {taskId:'t1', operationId:'op1', hostId:'h1', goal, modelProvider:'openai', model:'gpt-4o', temperature:0.2, maxSteps:10} as any;
}

describe('Phase-2 engine command dispatch', () => {

  it('injects real executor output into result event (no more [stub])', async () => {
    const calls: Array<{cmd:string; cancelled?:()=>boolean; hostId?:string}> = [];
    const executor = async (cmd: string, ctx: any): Promise<CommandExecResult> => {
      calls.push({cmd, cancelled: ctx.cancelled, hostId: ctx.hostId});
      return {stdout: 'hello world', stderr: '', exitCode: 0, durationMs: 12, success: true};
    };
    const llm = new MockLlmClient([
      '\u601d\u8003: run the command\n\u52a8\u4f5c: execute\n\u547d\u4ee4: echo hello world\n',
      '\u56de\u7b54: done\n\u52a8\u4f5c: finish\n',
    ]);
    const events: any[] = [];
    const engine = new ReActEngine(llm, {model: 'gpt-4o'} as any, {
      onEvent: (e: any) => events.push(e),
      onFinished: () => {},
    }, {commandExecutor: executor} as any);

    const state = await engine.run(makeTask('say hello'), 10);
    expect(state).toBe('success');
    expect(calls.length).toBe(1);
    expect(calls[0].cmd).toContain('echo hello world');
    expect(calls[0].hostId).toBe('h1');
    expect(typeof calls[0].cancelled).toBe('function');

    const resultEvt = events.find((e: any) => e.type === 'result')!;
    expect(resultEvt.success).toBe(true);
    expect(resultEvt.output).toContain('hello world');
    expect(resultEvt.exitCode).toBe(0);
    expect(resultEvt.durationMs).toBe(12);
    expect(JSON.stringify(events)).not.toContain('[stub]');
  });

  it('non-zero exit -> success=false, exitCode and error in result event', async () => {
    const executor = async (): Promise<CommandExecResult> => ({
      stdout: '', stderr: 'permission denied', exitCode: 13, durationMs: 5, success: false,
    });
    const llm = new MockLlmClient([
      '\u601d\u8003: try\n\u52a8\u4f5c: execute\n\u547d\u4ee4: sudo thing\n',
      '\u56de\u7b54: gave up\n\u52a8\u4f5c: finish\n',
    ]);
    const events: any[] = [];
    const engine = new ReActEngine(llm, {model: 'gpt-4o'} as any, {
      onEvent: (e: any) => events.push(e), onFinished: () => {},
    }, {commandExecutor: executor} as any);
    await engine.run(makeTask('x'), 10);
    const resultEvt = events.find((e: any) => e.type === 'result')!;
    expect(resultEvt.success).toBe(false);
    expect(resultEvt.exitCode).toBe(13);
    expect(resultEvt.error).toContain('code 13');
  });

  it('no executor -> stub fallback (backward compat, rpc_start_task unchanged)', async () => {
    const llm = new MockLlmClient([
      '\u601d\u8003: run\n\u52a8\u4f5c: execute\n\u547d\u4ee4: ls /\n',
      '\u56de\u7b54: done\n\u52a8\u4f5c: finish\n',
    ]);
    const events: any[] = [];
    const engine = new ReActEngine(llm, {model: 'gpt-4o'} as any, {
      onEvent: (e: any) => events.push(e), onFinished: () => {},
    });
    await engine.run(makeTask('x'), 10);
    const resultEvt = events.find((e: any) => e.type === 'result')!;
    expect(resultEvt.success).toBe(true); // stub fallback success=true
    expect(resultEvt.exitCode).toBe(0);
  });

  it('cancelled() is wired into executor ctx (R1: cancel observable mid-dispatch)', async () => {
    let observedCancelled: boolean | undefined;
    const llm = new MockLlmClient([
      '\u601d\u8003: run\n\u52a8\u4f5c: execute\n\u547d\u4ee4: ls\n',
      '\u56de\u7b54: done\n\u52a8\u4f5c: finish\n',
    ]);
    const engine = new ReActEngine(llm, {model: 'gpt-4o'} as any, {
      onEvent: () => {}, onFinished: () => {},
    }, {commandExecutor: async (_cmd: string, ctx: any): Promise<CommandExecResult> => {
      observedCancelled = ctx.cancelled ? ctx.cancelled() : undefined;
      return {stdout: '', stderr: '', exitCode: 0, durationMs: 0, success: true};
    }} as any);
    await engine.run(makeTask('x'), 10);
    // During normal (non-cancelled) execution cancelled() returns false
    expect(observedCancelled).toBe(false);
  });

});
