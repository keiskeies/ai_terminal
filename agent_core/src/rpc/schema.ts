// Agent Core - JSON-RPC schema types
// Single source of truth: agent_core/schema/*.json
// This file is hand-maintained; CI check-schema-compat validates against the .json files.

// ─── Shared ───────────────────────────────────────────

export type AgentEventType =
  | "thought" | "command" | "result" | "ask"
  | "finish" | "text" | "info" | "report" | "plan";

export type AgentFinishState = "success" | "cancelled" | "failed" | "interrupted";

export type PlanStepStatus = "pending" | "inProgress" | "completed" | "failed" | "skipped";

export interface PlanStep {
  title: string;
  status?: PlanStepStatus;
  hostIds?: string[];
  note?: string;
}

export interface HostExecutionResult {
  hostId: string;
  success: boolean;
  output?: string;
  error?: string;
  exitCode?: number;
  durationMs?: number;
  failureKind?: string;
}

export interface OperationBadge {
  text: string;
  level?: "success" | "info" | "warning";
}

export interface OperationChange {
  id: string;
  command: string;
  type: string;
  rollbackCommand?: string;
  localRestore?: boolean;
  success?: boolean;
  additions?: number;
  deletions?: number;
}

export interface OperationReport {
  operationId: string;
  taskId?: string;
  goal: string;
  hostId?: string;
  elapsedSeconds: number;
  stepIndex: number;
  commandSuccessCount: number;
  commandFailureCount: number;
  conclusion: string;
  answerBody?: string;
  details?: string;
  stateBadges?: OperationBadge[];
  changeRecordIds?: string[];
  changes?: OperationChange[];
  plan?: PlanStep[];
  nextActions?: string[];
  verified?: boolean;
  aiGenerated?: boolean;
  finishState: AgentFinishState;
}

export interface AgentEvent {
  id: string;
  type: AgentEventType;
  timestamp: number; // epoch ms
  // thought / text / info
  text?: string;
  // command / result
  command?: string;
  description?: string;
  commandId?: string;
  // command
  dangerous?: boolean;
  blocked?: boolean;
  toolName?: string;
  riskLevel?: "safe" | "info" | "warn" | "blocked";
  permissionDecision?: "execute" | "confirm" | "reject";
  hostId?: string;
  // result
  success?: boolean;
  output?: string;
  error?: string;
  durationMs?: number;
  exitCode?: number;
  failureKind?: string;
  outputTotalChars?: number;
  outputTruncated?: boolean;
  outputTail?: string;
  diffAdditions?: number;
  diffDeletions?: number;
  hostResults?: Record<string, HostExecutionResult>;
  // ask
  options?: string[];
  question?: string;
  chosenAnswer?: string;
  // finish
  summary?: string;
  finishState?: AgentFinishState;
  // report
  operationReport?: OperationReport;
  // plan
  planSteps?: PlanStep[];
  // streaming flag
  isStreaming?: boolean;
}

// ─── Parent → Child Requests ──────────────────────────

export interface ModelConfig {
  provider: "openai" | "anthropic" | "ollama" | "openai_compatible" | "deepseek";
  model: string;
  apiKey?: string;
  baseUrl?: string;
  temperature?: number;
  maxTokens?: number;
  systemPrompt?: string;
}

export type PermissionMode = "safe" | "standard" | "dangerous" | "yolo";

export interface StartTaskParams {
  taskId: string;
  operationId?: string;
  goal: string;
  hostId: string; // Frozen at task start (R3)
  modelConfig: ModelConfig;
  permissionMode?: PermissionMode;
  maxSteps?: number;
  rounds?: number;
  existingEvents?: AgentEvent[];
  resumeFromCheckpoint?: boolean;
}

export interface CancelTaskParams {
  taskId: string;
  reason?: "user_cancel" | "switch_tab" | "remove_tab" | "app_exit" | "model_switch";
}

export interface ConfirmParams {
  taskId: string;
  confirmId: string;
  decision: "ok" | "reject" | "timeout";
  chosenOption?: string;
}

export interface GetStateParams {
  taskId: string;
}

export interface RegisterLocalToolParams {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  scope?: "local" | "remote" | "all";
}

// ─── Child → Parent Notifications ─────────────────────

export interface AgentEventNotification {
  taskId: string;
  event: AgentEvent;
}

export interface ThinkingChunkNotification {
  taskId: string;
  text: string;
  isReasoning?: boolean;
}

export interface ToolResultFrame {
  taskId: string;
  commandId: string;
  chunk: number;
  total: number;
  data: string;
  isLast?: boolean;
}

export interface ConfirmRequestNotification {
  taskId: string;
  confirmId: string;
  prompt: string;
  options?: string[];
  timeoutMs?: number;
  riskLevel?: "safe" | "info" | "warn" | "blocked";
}

export type TaskState =
  | "running" | "thinking" | "executing" | "waiting_confirm"
  | "completed" | "failed" | "cancelled" | "interrupted";

export interface TaskStateNotification {
  taskId: string;
  state: TaskState;
  summary?: string;
}

export interface UncaughtNotification {
  message: string;
  stack?: string;
  taskId?: string;
}

// ─── Child → Parent Reverse Requests ──────────────────

export interface InvokeSshParams {
  hostId: string;
  command: string;
  timeoutMs?: number;
  workDir?: string;
  shell?: "bash" | "sh" | "zsh" | "powershell" | "cmd";
}

export interface InvokeSshResult {
  exitCode: number;
  output: string;
  error?: string;
  durationMs: number;
  failureKind?: string;
}

export interface InvokeSftpParams {
  hostId: string;
  op: "upload" | "download" | "list" | "mkdir" | "delete" | "rename";
  remotePath?: string;
  localPath?: string;
  targetPath?: string;
}

export interface InvokeSftpResult {
  success: boolean;
  output?: string;
  error?: string;
}

export interface QueryKnowledgeParams {
  query: string;
  limit?: number;
  category?: string;
}

export interface KnowledgeHit {
  id: string;
  title: string;
  content: string;
  score: number;
}

export interface QueryKnowledgeResult {
  hits: KnowledgeHit[];
}

export interface SaveSessionParams {
  taskId: string;
  events: AgentEvent[];
  checkpointData?: Record<string, unknown>;
}

export interface CallDartToolParams {
  toolName: string;
  args: Record<string, unknown>;
}

export interface CallDartToolResult {
  success: boolean;
  output?: string;
  error?: string;
}

// ─── Tool Descriptor ──────────────────────────────────

export type ToolKind = "read" | "write" | "destructive" | "network" | "orchestration";
export type ToolSource = "builtin" | "mcpServer" | "dart";
export type ToolScope = "local" | "remote" | "all";

export interface AgentTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  kind?: ToolKind;
  source?: ToolSource;
  scope?: ToolScope;
  idempotent?: boolean;
}

// ─── JSON-RPC 2.0 Envelope ────────────────────────────

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: string;
  method: string;
  params?: unknown;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: string;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

export type JsonRpcMessage = JsonRpcRequest | JsonRpcResponse | JsonRpcNotification;
