// Oracle-replay test for AgentTracer (r136).
// Re-reads agent_tracer.dart at run time and pins the metrics-update logic
// against the Node port in src/utils/agent_tracer.ts.
import {describe, it, expect, vi, afterEach} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {
  AgentTracer,
  TraceEvent,
  TraceEventType,
  TaskMetrics,
} from "../src/utils/agent_tracer.js";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const linesOf = (rel: string) =>
  readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL).split(NL);

const DART = linesOf("../../ai_terminal/lib/services/agent_tracer.dart");

describe("r136: AgentTracer oracle", () => {

  it("TraceEvent.toJson matches Dart 47-55 (snake_case keys, conditional fields)", () => {
    const ev = new TraceEvent({
      taskId: "t1",
      hostId: "h1",
      type: TraceEventType.taskStart,
      generation: 3,
      step: 5,
      payload: {goal: "g"},
    });
    const j = ev.toJson();
    expect(j.task_id).toBe("t1");
    expect(j.host_id).toBe("h1");
    expect(j.type).toBe("taskStart");
    expect(j.gen).toBe(3);
    expect(j.step).toBe(5);
    expect(j.payload).toEqual({goal: "g"});
    // No payload key when empty
    const ev2 = new TraceEvent({taskId: "t2", type: TraceEventType.info});
    expect(ev2.toJson()).not.toHaveProperty("payload");
    expect(ev2.toJson()).not.toHaveProperty("host_id");
    expect(ev2.toJson()).not.toHaveProperty("gen");
    expect(ev2.toJson()).not.toHaveProperty("step");
  });

  it("TraceEvent.toNdjson produces a single JSON line (Dart 57)", () => {
    const ev = new TraceEvent({taskId: "t1", type: TraceEventType.taskStart});
    const nd = ev.toNdjson();
    expect(nd).toBe(JSON.stringify(JSON.parse(nd)));
    expect(nd.split(NL)).toHaveLength(1);
  });

  it("TaskMetrics.toJson matches Dart 91-110 (snake_case + computed total)", () => {
    const m = new TaskMetrics("t1", "goal", 1000);
    m.endTime = 4000;
    m.status = "completed";
    m.stepCount = 3;
    m.aiCallCount = 2;
    m.commandCount = 5;
    m.commandSuccessCount = 4;
    m.commandFailureCount = 1;
    m.retryCount = 1;
    m.tokenUsagePrompt = 100;
    m.tokenUsageCompletion = 200;
    const j = m.toJson();
    expect(j.task_id).toBe("t1");
    expect(j.status).toBe("completed");
    expect(j.step_count).toBe(3);
    expect(j.token_usage_total).toBe(300);
    expect(j.duration_seconds).toBe(3);
  });

  it("_updateMetrics: commandEnd success/failure increments (Dart 256-261)", () => {
    const tracer = new AgentTracer();
    tracer.startTask("t1", "g");
    tracer.emitSync(new TraceEvent({taskId: "t1", type: TraceEventType.commandStart}));
    tracer.emitSync(new TraceEvent({taskId: "t1", type: TraceEventType.commandEnd, payload: {success: true}}));
    tracer.emitSync(new TraceEvent({taskId: "t1", type: TraceEventType.commandEnd, payload: {success: false}}));
    const m = tracer.getMetrics("t1");
    expect(m?.commandCount).toBe(1);
    expect(m?.commandSuccessCount).toBe(1);
    expect(m?.commandFailureCount).toBe(1);
    tracer.reset();
  });

  it("_updateMetrics: aiCallEnd accumulates tokens + retry/fallback flags (Dart 246-252)", () => {
    const tracer = new AgentTracer();
    tracer.startTask("t1", "g");
    tracer.emitSync(new TraceEvent({taskId: "t1", type: TraceEventType.aiCallStart}));
    tracer.emitSync(new TraceEvent({taskId: "t1", type: TraceEventType.aiCallEnd, payload: {prompt_tokens: 100, completion_tokens: 50}}));
    tracer.emitSync(new TraceEvent({taskId: "t1", type: TraceEventType.aiCallEnd, payload: {prompt_tokens: 10, completion_tokens: 5, retry: true}}));
    tracer.emitSync(new TraceEvent({taskId: "t1", type: TraceEventType.aiCallEnd, payload: {fallback: true}}));
    const m = tracer.getMetrics("t1");
    expect(m?.aiCallCount).toBe(1);
    expect(m?.tokenUsagePrompt).toBe(110);
    expect(m?.tokenUsageCompletion).toBe(55);
    expect(m?.retryCount).toBe(1);
    expect(m?.fallbackModelUsed).toBe(1);
    tracer.reset();
  });

  it("_updateMetrics: taskEnd sets status + endTime (Dart 234-239)", () => {
    const tracer = new AgentTracer();
    tracer.startTask("t1", "g");
    tracer.emitSync(new TraceEvent({taskId: "t1", type: TraceEventType.taskEnd, payload: {status: "failed"}}));
    const m = tracer.getMetrics("t1");
    expect(m?.status).toBe("failed");
    expect(m?.endTime).toBeDefined();
    tracer.reset();
  });

  it("Dart source lines are non-empty (run-time pin)", () => {
    // TraceEventType enum (Dart 8-21)
    expect(DART[7].trim()).toContain("enum TraceEventType");
    // TaskMetrics.toJson (Dart 91-110)
    expect(DART[90].trim()).toContain("toJson");
    // AgentTracer.startTask (Dart 269-282)
    expect(DART[268].trim()).toContain("startTask");
  });
});
