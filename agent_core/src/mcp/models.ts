// MCP models — ported from ai_terminal/lib/services/mcp_models.dart
// CJK literals are byte-faithful to the Dart source.

// ─── Enums ────────────────────────────────────────────────────────────────

export enum McpTransportKind {
  streamableHttp = 'streamableHttp',
  sse = 'sse',
  stdio = 'stdio',
}

export function mcpTransportKindFromString(value: string | undefined): McpTransportKind {
  switch (value) {
    case 'sse':
      return McpTransportKind.sse;
    case 'stdio':
      return McpTransportKind.stdio;
    default:
      return McpTransportKind.streamableHttp;
  }
}

export function mcpTransportKindLabel(kind: McpTransportKind): string {
  switch (kind) {
    case McpTransportKind.streamableHttp:
      return 'Streamable HTTP';
    case McpTransportKind.sse:
      return 'HTTP + SSE（旧版）';
    case McpTransportKind.stdio:
      return 'stdio（本地进程）';
  }
}

export enum McpToolExposure {
  readOnly = 'readOnly',
  all = 'all',
  custom = 'custom',
}

export function mcpToolExposureFromString(value: string | undefined): McpToolExposure {
  switch (value) {
    case 'all':
      return McpToolExposure.all;
    case 'custom':
      return McpToolExposure.custom;
    default:
      return McpToolExposure.readOnly;
  }
}

export enum McpServerStatus {
  disabled = 'disabled',
  disconnected = 'disconnected',
  connecting = 'connecting',
  connected = 'connected',
  authRequired = 'authRequired',
  error = 'error',
}

export function mcpServerStatusLabel(status: McpServerStatus): string {
  switch (status) {
    case McpServerStatus.disabled:
      return '已停用';
    case McpServerStatus.disconnected:
      return '未连接';
    case McpServerStatus.connecting:
      return '连接中';
    case McpServerStatus.connected:
      return '已连接';
    case McpServerStatus.authRequired:
      return '需要授权';
    case McpServerStatus.error:
      return '连接失败';
  }
}

// ─── Config ───────────────────────────────────────────────────────────────

export interface McpServerConfig {
  id: string;
  name: string;
  enabled: boolean;
  autoConnect: boolean;
  transport: McpTransportKind;
  url: string;
  command: string;
  args: string[];
  workingDirectory: string;
  headers: Record<string, string>;
  env: Record<string, string>;
  timeoutMs: number;
  proxy: string;
  oauth: boolean;
  oauthScopes: string[];
  oauthClientId: string;
  oauthClientSecret: string;
  toolExposure: McpToolExposure;
  allowedTools: string[];
  maxTools: number;
  exposeResources: boolean;
  exposePrompts: boolean;
}

export function mcpServerConfigEndpointLabel(config: McpServerConfig): string {
  if (config.transport === McpTransportKind.stdio) {
    const parts = [config.command, ...config.args].filter((s) => s.trim().length > 0);
    return parts.join(' ');
  }
  return config.url;
}

export function mcpServerConfigCopyWith(config: McpServerConfig, overrides: Partial<McpServerConfig>): McpServerConfig {
  return { ...config, ...overrides };
}

export function presetFilesystem(dir: string): McpServerConfig {
  return {
    id: mcpSlug('fs-' + dir.replace(/[\/]+/g, '_')),
    name: 'Filesystem',
    enabled: true,
    autoConnect: true,
    transport: McpTransportKind.stdio,
    url: '',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-filesystem', dir],
    workingDirectory: '',
    headers: {},
    env: {},
    timeoutMs: 30000,
    proxy: '',
    oauth: false,
    oauthScopes: [],
    oauthClientId: '',
    oauthClientSecret: '',
    toolExposure: McpToolExposure.readOnly,
    allowedTools: [],
    maxTools: 20,
    exposeResources: true,
    exposePrompts: true,
  };
}

export function presetContext7(): McpServerConfig {
  return {
    id: mcpSlug('context7'),
    name: 'Context7',
    enabled: true,
    autoConnect: true,
    transport: McpTransportKind.stdio,
    url: '',
    command: 'npx',
    args: ['-y', '@upstash/context7-mcp'],
    workingDirectory: '',
    headers: {},
    env: {},
    timeoutMs: 30000,
    proxy: '',
    oauth: false,
    oauthScopes: [],
    oauthClientId: '',
    oauthClientSecret: '',
    toolExposure: McpToolExposure.readOnly,
    allowedTools: [],
    maxTools: 20,
    exposeResources: true,
    exposePrompts: true,
  };
}

// ─── Descriptors ──────────────────────────────────────────────────────────

export interface McpToolDescriptor {
  name: string;
  title: string;
  description: string;
  inputSchema: Record<string, unknown>;
  readOnly: boolean;
  destructive: boolean;
  idempotent: boolean;
  openWorld: boolean;
}

export interface McpResourceDescriptor {
  uri: string;
  name: string;
  title: string;
  description: string;
  mimeType: string;
  isTemplate: boolean;
}

export interface McpPromptArgumentDescriptor {
  name: string;
  description: string;
  required: boolean;
}

export interface McpPromptDescriptor {
  name: string;
  title: string;
  description: string;
  arguments: McpPromptArgumentDescriptor[];
}

export interface McpCallResult {
  isError: boolean;
  text: string;
}

// ─── Runtime ─────────────────────────────────────────────────────────────

export interface McpServerRuntime {
  config: McpServerConfig;
  status: McpServerStatus;
  error: string;
  pendingAuthUrl: string;
  tools: McpToolDescriptor[];
  resources: McpResourceDescriptor[];
  prompts: McpPromptDescriptor[];
  logs: string[];
  connectedAt: number | null;
}

export function mcpServerRuntimeCopyWith(
  runtime: McpServerRuntime,
  overrides: Partial<McpServerRuntime> & { clearConnectedAt?: boolean },
): McpServerRuntime {
  const { clearConnectedAt, ...rest } = overrides;
  return {
    ...runtime,
    ...rest,
    connectedAt: clearConnectedAt ? null : (rest.connectedAt ?? runtime.connectedAt),
  };
}

export function mcpServerRuntimeIsConnected(runtime: McpServerRuntime): boolean {
  return runtime.status === McpServerStatus.connected;
}

// ─── OAuth callback ──────────────────────────────────────────────────────

export interface McpOAuthCallback {
  code: string;
  state: string;
  error?: string;
  errorDescription?: string;
}

// ─── Exception ───────────────────────────────────────────────────────────

export class McpAuthRequiredException extends Error {
  readonly authUrl: string;
  constructor(message: string, authUrl = '') {
    super(message);
    this.name = 'McpAuthRequiredException';
    this.authUrl = authUrl;
  }
}

// ─── OAuth token data (persisted model) ─────────────────────────────────

export interface McpOAuthTokenData {
  accessToken: string;
  refreshToken?: string;
  expiresAtMs?: number;
  issuer?: string;
  resource?: string;
}

export function mcpOAuthTokenIsExpired(token: McpOAuthTokenData): boolean {
  if (token.expiresAtMs == null) return false;
  return Date.now() >= token.expiresAtMs;
}

export function mcpOAuthTokenToJson(token: McpOAuthTokenData): Record<string, unknown> {
  const out: Record<string, unknown> = { access_token: token.accessToken };
  if (token.refreshToken) out.refresh_token = token.refreshToken;
  if (token.expiresAtMs != null) out.expires_at_ms = token.expiresAtMs;
  if (token.issuer) out.issuer = token.issuer;
  if (token.resource) out.resource = token.resource;
  return out;
}

export function mcpOAuthTokenFromJson(raw: Record<string, unknown>): McpOAuthTokenData {
  const accessToken = (raw.access_token as string) ?? '';
  const refreshToken = raw.refresh_token as string | undefined;
  let expiresAtMs: number | undefined;
  const rawExpiry = raw.expires_at_ms;
  if (typeof rawExpiry === 'number') {
    expiresAtMs = rawExpiry;
  } else if (typeof rawExpiry === 'string') {
    const parsed = parseInt(rawExpiry, 10);
    if (!isNaN(parsed)) expiresAtMs = parsed;
  }
  const issuer = raw.issuer as string | undefined;
  const resource = raw.resource as string | undefined;
  return { accessToken, refreshToken, expiresAtMs, issuer, resource };
}

// ─── Helpers ─────────────────────────────────────────────────────────────

export function mcpSlug(value: string, maxLength = 40): string {
  let slug = value.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, '_').replace(/^_+|_+$/g, '');
  if (slug.length === 0) slug = 'server';
  if (slug.length > maxLength) slug = slug.slice(0, maxLength);
  return slug;
}

export function mcpToolFullName(serverId: string, toolName: string): string {
  const slug20 = mcpSlug(serverId, 20);
  const slug36 = mcpSlug(toolName, 36);
  let name = 'mcp__' + slug20 + '__' + slug36;
  if (name.length > 64) name = name.slice(0, 64);
  return name;
}

export function encodeMcpJson(value: unknown): string {
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}
