// AgentTracer - port of Dart agent_tracer.dart 1-316.
//
// Structured trace events for post-hoc analysis. Writes NDJSON to a daily
// trace file. In the Node port, the file path is injected via setTraceFile()
// (no Flutter path_provider equivalent). When no file is set, all writes
// are no-ops but metrics are still tracked (Dart 184-187).
import {appendFileSync, mkdirSync} from "node:fs";
import {dirname} from "node:path";

export enum TraceEventType {
  taskStart = "taskStart",
  taskEnd = "taskEnd",
  step = "step",
  aiCallStart = "aiCallStart",
  aiCallEnd = "aiCallEnd",
  commandStart = "commandStart",
  commandEnd = "commandEnd",
  toolCall = "toolCall",
  ask = "ask",
  info = "info",
  error = "error",
  cancel = "cancel",
}

export interface TraceEventInput {
  taskId: string;
  hostId?: string;
  type: TraceEventType;
  timestamp?: number;
  generation?: number;
  step?: number;
  payload?: Record<string, unknown>;
}

export class TraceEvent {
  taskId: string;
  hostId?: string;
  type: TraceEventType;
  timestamp: number;
  generation?: number;
  step?: number;
  payload: Record<string, unknown>;

  constructor(input: TraceEventInput) {
    this.taskId = input.taskId;
    this.hostId = input.hostId;
    this.type = input.type;
    this.timestamp = input.timestamp ?? Date.now();
    this.generation = input.generation;
    this.step = input.step;
    this.payload = input.payload ?? {};
  }

  toJson(): Record<string, unknown> {
    const o: Record<string, unknown> = {
      task_id: this.taskId,
      type: this.type,
      ts: new Date(this.timestamp).toISOString(),
    };
    if (this.hostId !== undefined) o["host_id"] = this.hostId;
    if (this.generation !== undefined) o["gen"] = this.generation;
    if (this.step !== undefined) o["step"] = this.step;
    if (Object.keys(this.payload).length > 0) o["payload"] = this.payload;
    return o;
  }

  toNdjson(): string {
    return JSON.stringify(this.toJson());
  }
}

export class TaskMetrics {
  taskId: string;
  goal: string;
  startTime: number;
  endTime?: number;
  status: string = "running";
  stepCount = 0;
  aiCallCount = 0;
  commandCount = 0;
  commandSuccessCount = 0;
  commandFailureCount = 0;
  retryCount = 0;
  tokenUsagePrompt = 0;
  tokenUsageCompletion = 0;
  noCommandRetryCount = 0;
  fallbackModelUsed = 0;

  constructor(taskId: string, goal: string, startTime?: number) {
    this.taskId = taskId;
    this.goal = goal;
    this.startTime = startTime ?? Date.now();
  }

  get durationMs(): number {
    return this.endTime !== undefined ? this.endTime - this.startTime : 0;
  }

  toJson(): Record<string, unknown> {
    return {
      task_id: this.taskId,
      goal: this.goal,
      start_time: new Date(this.startTime).toISOString(),
      end_time: this.endTime !== undefined ? new Date(this.endTime).toISOString() : undefined,
      duration_seconds: Math.round(this.durationMs / 1000),
      status: this.status,
      step_count: this.stepCount,
      ai_call_count: this.aiCallCount,
      command_count: this.commandCount,
      command_success_count: this.commandSuccessCount,
      command_failure_count: this.commandFailureCount,
      retry_count: this.retryCount,
      token_usage_prompt: this.tokenUsagePrompt,
      token_usage_completion: this.tokenUsageCompletion,
      token_usage_total: this.tokenUsagePrompt + this.tokenUsageCompletion,
      no_command_retry_count: this.noCommandRetryCount,
      fallback_model_used: this.fallbackModelUsed,
    };
  }
}

export class AgentTracer {
  private _disabled = false;
  private _traceFile: string | null = null;
  private _writeBuffer = "";
  private _flushTimer: ReturnType<typeof setTimeout> | null = null;
  private _writing = false;
  private readonly _activeMetrics = new Map<string, TaskMetrics>();

  // Dart 136-138: enable/disable (test env can disable to avoid file pollution)
  setDisabled(disabled: boolean): void {
    this._disabled = disabled;
  }

  // Dart 141-146: trace file path (for /export)
  tracePath(): string | null {
    if (this._disabled) return null;
    return this._traceFile;
  }

  // Node: set the trace file path (replaces Dart's _ensureFile which uses path_provider)
  setTraceFile(path: string): void {
    if (this._disabled) return;
    const dir = dirname(path);
try { mkdirSync(dir, {recursive: true}); } catch (e) { console.warn("[agent-tracer] init failed: " + String(e)); }
    this._traceFile = path;
  }

  // Dart 168-181: record a trace event (async, non-blocking)
  async emit(event: TraceEvent): Promise<void> {
    if (this._disabled) return;
    try {
      if (this._traceFile) {
        appendFileSync(this._traceFile, event.toNdjson() + String.fromCharCode(10));
      }
      this._updateMetrics(event);
    } catch (e) {
      // Dart 179: trace failure must not affect the main flow
      console.warn("[agent-tracer] write failed: " + String(e));
    }
  }

  // Dart 185-193: synchronous version (metrics always updated, file write is buffered)
  emitSync(event: TraceEvent): void {
    this._updateMetrics(event);
    if (this._disabled || !this._traceFile) return;
    this._writeBuffer += event.toNdjson() + String.fromCharCode(10);
    this._scheduleFlush();
  }

  // Dart 195-198: schedule a 300ms flush
  private _scheduleFlush(): void {
    if (this._flushTimer !== null) return;
    this._flushTimer = setTimeout(() => { void this._flush(); }, 300);
  }

  // Dart 200-224: flush the write buffer
  private async _flush(): Promise<void> {
    this._flushTimer = null;
    if (this._writing) { this._scheduleFlush(); return; }
    if (this._writeBuffer.length === 0) return;
    const pending = this._writeBuffer;
    this._writeBuffer = "";
    const file = this._traceFile;
    if (!file) return;
    this._writing = true;
    try {
      appendFileSync(file, pending);
    } catch (e) {
      console.warn("[agent-tracer] flush failed: " + String(e));
    } finally {
      this._writing = false;
    }
  }

  // Dart 227-266: update metrics from a trace event
  private _updateMetrics(event: TraceEvent): void {
    const m = this._activeMetrics.get(event.taskId);
    if (!m) return;
    switch (event.type) {
      case TraceEventType.taskStart:
        break;
      case TraceEventType.taskEnd:
      case TraceEventType.cancel:
        m.endTime = Date.now();
        m.status = (event.payload["status"] as string) ?? event.type;
        break;
      case TraceEventType.step:
        m.stepCount = event.step ?? m.stepCount;
        break;
      case TraceEventType.aiCallStart:
        m.aiCallCount++;
        break;
      case TraceEventType.aiCallEnd:
        m.tokenUsagePrompt += (event.payload["prompt_tokens"] as number) ?? 0;
        m.tokenUsageCompletion += (event.payload["completion_tokens"] as number) ?? 0;
        if (event.payload["retry"] === true) m.retryCount++;
        if (event.payload["fallback"] === true) m.fallbackModelUsed++;
        break;
      case TraceEventType.commandStart:
        m.commandCount++;
        break;
      case TraceEventType.commandEnd:
        if (event.payload["success"] === true) m.commandSuccessCount++;
        else m.commandFailureCount++;
        break;
      default:
        break;
    }
  }

  // Dart 269-282: register a new task
  startTask(taskId: string, goal: string, hostId?: string): void {
    const m = new TaskMetrics(taskId, goal);
    this._activeMetrics.set(taskId, m);
    this.emitSync(new TraceEvent({taskId, hostId, type: TraceEventType.taskStart, payload: {goal}}));
  }

  // Dart 285-306: end a task
  endTask(taskId: string, status: string, summary?: string, hostId?: string): void {
    const m = this._activeMetrics.get(taskId);
    if (m) { m.endTime ??= Date.now(); m.status = status; }
    const payload: Record<string, unknown> = {status};
    if (summary !== undefined) payload["summary"] = summary;
    if (m) payload["metrics"] = m.toJson();
    this.emitSync(new TraceEvent({taskId, hostId, type: TraceEventType.taskEnd, payload}));
    // Dart 303: delayed removal (30s) to let async events attribute
    setTimeout(() => { this._activeMetrics.delete(taskId); }, 30000);
  }

  // Dart 309: get task metrics
  getMetrics(taskId: string): TaskMetrics | undefined {
    return this._activeMetrics.get(taskId);
  }

  // Dart 312-314: clear all metrics (test helper)
  reset(): void {
    this._activeMetrics.clear();
  }
}

// Singleton (Dart 118-121: AgentTracer.instance)
export const agentTracer = new AgentTracer();
