// MCP subsystem barrel — 1:1 Node/TypeScript port of the Dart ai_terminal MCP
// subsystem (mcp_manager / mcp_connection / mcp_models / mcp_tool_adapter /
// mcp_oauth) built on @modelcontextprotocol/sdk.
//
// SDK import rule (locked): subpath imports only (bare-root .d.ts absent under
// Node10). Everything below re-exports the public surface.

export {
  McpTransportKind,
  McpToolExposure,
  McpServerStatus,
  mcpTransportKindFromString,
  mcpTransportKindLabel,
  mcpToolExposureFromString,
  mcpServerStatusLabel,
  McpAuthRequiredException,
  mcpServerConfigEndpointLabel,
  mcpServerConfigCopyWith,
  mcpServerRuntimeCopyWith,
  mcpServerRuntimeIsConnected,
  mcpOAuthTokenIsExpired,
  mcpOAuthTokenToJson,
  mcpOAuthTokenFromJson,
  presetFilesystem,
  presetContext7,
  mcpSlug,
  mcpToolFullName,
  encodeMcpJson,
} from './models.js';
export type {
  McpServerConfig,
  McpToolDescriptor,
  McpResourceDescriptor,
  McpPromptArgumentDescriptor,
  McpPromptDescriptor,
  McpCallResult,
  McpServerRuntime,
  McpOAuthCallback,
  McpOAuthTokenData,
} from './models.js';

export { McpConnection } from './connection.js';
export type { McpConnectionOptions } from './connection.js';

export { McpOAuthProvider } from './oauth.js';
export type { McpOAuthProviderOptions, McpOAuthTokenStore } from './oauth.js';

export { McpManager, InMemoryMcpStore } from './manager.js';
export type { McpStore, McpManagerOptions } from './manager.js';

export { McpToolAdapter, McpSideToolAdapter, McpSideToolKind } from './tool_adapter.js';
export type { McpToolCaller } from './tool_adapter.js';
