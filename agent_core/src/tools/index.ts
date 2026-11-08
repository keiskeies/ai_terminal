// tools/index.ts - facade: re-export the tool framework + a ready default registry.
// W4 concrete pure-Node tools live in ./builtin.ts. W5 (SSH/SFTP/orchestrator/MCP)
// will register more here once the reverse-RPC bridge + node-pty land.
export {
  ToolKind, ToolSource, ToolScope,
  ToolResult, AgentTool, AgentToolRegistry,
} from "./builtin.js";
export type {HostExecutionResult, ToolContext} from "./builtin.js";
export {ToolArgs, ToolArgsParser, ToolArgException} from "./tool_args.js";

import {
  AgentToolRegistry, ToolScope,
  LocalFileReadTool, LocalDirListTool, FetchUrlTool, LocalExecTool,
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
  r.register(new FetchUrlTool(), ToolScope.all);
  // local_exec only makes sense when the session is NOT local (i.e. SSH);
  // in a local session the built-in terminal already executes locally.
  r.register(new LocalExecTool(), ToolScope.sshSession);
  return r;
}
