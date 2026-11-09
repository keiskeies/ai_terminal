// tools/index.ts - facade: re-export the tool framework + a ready default registry.
// W4 concrete pure-Node tools live in ./builtin.ts. W5 (SSH/SFTP/orchestrator/MCP)
// will register more here once the reverse-RPC bridge + node-pty land.

export {
  ToolKind, ToolSource, ToolScope,
  ToolResult, AgentTool, AgentToolRegistry,
  LocalFileReadTool, LocalDirListTool, FetchUrlTool, LocalExecTool,
  LocalFileSearchTool, LocalFileWriteTool, LocalFilePatchTool,
  LocalFileMoveTool, LocalFileDeleteTool,
} from "./builtin.js";
import {WebSearchTool} from "./web_search.js";
export type {HostExecutionResult, ToolContext} from "./builtin.js";
export {ToolArgs, ToolArgsParser, ToolArgException} from "./tool_args.js";
export {WebSearchTool, webSearchService, loadWebSearchConfig, saveWebSearchConfig, getApiKey, normalizeSearchUrl, mergeSearchResults, WebSearchQuotaError, WebSearchTransientError, WebSearchCancelledError, providerDisplayName} from "./web_search.js";
export type {WebSearchProvider, WebSearchResult, WebSearchBatch, WebSearchBackendReport, WebSearchResponse, WebSearchConfig} from "./web_search.js";

export {ReverseRpcOrchestrator, ExecOnTool, ExecBatchTool, CheckConnectivityTool, buildOrchestratorTools, registerOrchestratorTools, CommandFailureKind, isReadOnlyCommand, isValidHost} from "./orchestrator.js";
export type {OrchestratorExecutor, OrchestratorResult, OrchestratorConnectivity, ExecuteBatchOptions} from "./orchestrator.js";

import {
  AgentToolRegistry, ToolScope,
  LocalFileReadTool, LocalDirListTool, FetchUrlTool, LocalExecTool,
  LocalFileSearchTool, LocalFileWriteTool, LocalFilePatchTool,
  LocalFileMoveTool, LocalFileDeleteTool,
} from "./builtin.js";

/**
 * Build the default tool registry: all pure-Node W4 tools, plus local_exec
 * exposed only in SSH sessions (mirrors Dart: in a local session the exec
 * entry is the PTY, so local_exec would just confuse the model).
 */
export function buildDefaultToolRegistry(): AgentToolRegistry {
  const r = new AgentToolRegistry();
  r.register(new LocalFileReadTool(), ToolScope.all);
  r.register(new LocalDirListTool(), ToolScope.all);
  r.register(new LocalFileSearchTool(), ToolScope.all);
  r.register(new LocalFileWriteTool(), ToolScope.localSession);
  r.register(new LocalFilePatchTool(), ToolScope.localSession);
  r.register(new LocalFileMoveTool(), ToolScope.localSession);
  r.register(new LocalFileDeleteTool(), ToolScope.localSession);
  r.register(new WebSearchTool(), ToolScope.all);
  r.register(new FetchUrlTool(), ToolScope.all);
  // local_exec only makes sense when the session is NOT local (i.e. SSH);
  // in a local session the built-in terminal already executes locally.
  r.register(new LocalExecTool(), ToolScope.sshSession);
  return r;
}

import {ReverseRpcClient} from "../rpc/client.js";
import {registerOrchestratorTools, ReverseRpcOrchestrator} from "./orchestrator.js";

/**
 * Build the full tool registry: all W4 pure-Node tools plus the W5 orchestrator
 * trio (exec_on/exec_batch/check_connectivity) routed through the reverse-RPC
 * bridge back to the Dart parent.
 */
export function buildFullToolRegistry(reverse: ReverseRpcClient): AgentToolRegistry {
  const r = buildDefaultToolRegistry();
  registerOrchestratorTools(r, new ReverseRpcOrchestrator(reverse));
  return r;
}
