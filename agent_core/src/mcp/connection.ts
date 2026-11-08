// MCP connection — ported from ai_terminal/lib/services/mcp_connection.dart
// Owns transport/client lifecycle, capability discovery, notifications,
// tool calls and OAuth. Pushes state to the manager/UI via onRuntime.

import { Client } from '@modelcontextprotocol/sdk/client';
import type { Implementation, JSONRPCMessage } from '@modelcontextprotocol/sdk/types';
import {
  UnauthorizedError,
} from '@modelcontextprotocol/sdk/client/auth';
import { McpError } from '@modelcontextprotocol/sdk/types';
import { StdioClientTransport, type StdioServerParameters } from '@modelcontextprotocol/sdk/client/stdio';
import { SSEClientTransport, type SSEClientTransportOptions } from '@modelcontextprotocol/sdk/client/sse';
import {
  StreamableHTTPClientTransport,
  type StreamableHTTPClientTransportOptions,
} from '@modelcontextprotocol/sdk/client/streamableHttp';
import {
  PromptListChangedNotificationSchema,
  ResourceListChangedNotificationSchema,
  ToolListChangedNotificationSchema,
} from '@modelcontextprotocol/sdk/types';
import type { Readable } from 'node:stream';

import {
  McpAuthRequiredException,
  McpCallResult,
  McpPromptArgumentDescriptor,
  McpPromptDescriptor,
  McpResourceDescriptor,
  McpServerConfig,
  McpServerRuntime,
  McpServerStatus,
  McpToolDescriptor,
  McpTransportKind,
  encodeMcpJson,
  mcpServerConfigEndpointLabel,
} from './models.js';
import { McpOAuthProvider } from './oauth.js';
import type { McpOAuthTokenStore } from './oauth.js';

export interface McpConnectionOptions {
  config: McpServerConfig;
  onRuntime: (runtime: McpServerRuntime) => void;
  onAuthUrl?: (url: string) => void;
  tokenStore?: McpOAuthTokenStore;
  /** When set, this factory is used instead of the built-in transport creation. */
  transportFactory?: () => Promise<McpTransport> | McpTransport;
}

/** Node SDK transport surface shared by all three transports. */
export interface McpTransport {
  start(): Promise<void>;
  send(message: JSONRPCMessage): Promise<void>;
  close(): Promise<void>;
  onclose?: (() => void) | undefined;
  onerror?: ((error: Error) => void) | undefined;
}

type HttpTransport = McpTransport & {
  finishAuth(code: string): Promise<void>;
};

export class McpConnection {
  readonly config: McpServerConfig;
  private readonly onRuntime: (runtime: McpServerRuntime) => void;
  private readonly onAuthUrl?: (url: string) => void;
  private readonly tokenStore?: McpOAuthTokenStore;
  private readonly transportFactory?: () => Promise<McpTransport> | McpTransport;

  private client: Client | null = null;
  private transport: McpTransport | null = null;
  private httpTransport: HttpTransport | null = null;
  private oauthProvider: McpOAuthProvider | null = null;
  private stderrStream: Readable | null = null;
  private refreshTimer: ReturnType<typeof setTimeout> | null = null;
  private connectTimer: ReturnType<typeof setTimeout> | null = null;

  private status: McpServerStatus = McpServerStatus.disconnected;
  private error = '';
  private pendingAuthUrl = '';
  private tools: McpToolDescriptor[] = [];
  private resources: McpResourceDescriptor[] = [];
  private prompts: McpPromptDescriptor[] = [];
  private logs: string[] = [];
  private connectedAt: number | null = null;
  private disposed = false;
  private refreshing = false;

  constructor(options: McpConnectionOptions) {
    this.config = options.config;
    this.onRuntime = options.onRuntime;
    this.onAuthUrl = options.onAuthUrl;
    this.tokenStore = options.tokenStore;
    this.transportFactory = options.transportFactory;
  }

  get runtime(): McpServerRuntime {
    return {
      config: this.config,
      status: this.status,
      error: this.error,
      pendingAuthUrl: this.pendingAuthUrl,
      tools: this.tools,
      resources: this.resources,
      prompts: this.prompts,
      logs: this.logs,
      connectedAt: this.connectedAt,
    };
  }

  private emit(): void {
    if (this.disposed) return;
    this.onRuntime(this.runtime);
  }

  private addLog(message: string): void {
    const trimmed = message.trim();
    if (trimmed.length === 0) return;
    const stamp = new Date().toISOString().substring(11, 19);
    const next = [...this.logs, stamp + ' ' + trimmed];
    this.logs = next.length > 50 ? next.slice(next.length - 50) : next;
    this.emit();
  }

  /** Connect (idempotent: returns immediately if already connected). */
  async connect(interactiveAuth = false): Promise<void> {
    if (this.disposed) return;
    if (this.status === McpServerStatus.connected) return;
    this.status = McpServerStatus.connecting;
    this.error = '';
    this.pendingAuthUrl = '';
    this.emit();
    this.addLog('正在连接 ' + mcpServerConfigEndpointLabel(this.config));
    try {
      await this.connectOnce(interactiveAuth);
      this.status = McpServerStatus.connected;
      this.connectedAt = Date.now();
      this.error = '';
      this.pendingAuthUrl = '';
      this.emit();
      this.addLog(
        '连接成功：' + this.tools.length + ' 个工具，' +
        this.resources.length + ' 个资源，' + this.prompts.length + ' 个提示词',
      );
    } catch (e) {
      if (e instanceof McpAuthRequiredException) {
        this.pendingAuthUrl = e.authUrl;
        this.status = McpServerStatus.authRequired;
        this.error = e.message;
        this.emit();
        this.addLog(e.message);
        await this.closeTransportOnly();
      } else {
        this.status = McpServerStatus.error;
        this.error = this.friendlyError(e);
        this.emit();
        this.addLog('连接失败：' + this.error);
        await this.closeTransportOnly();
      }
    }
  }

  private async connectOnce(interactiveAuth: boolean): Promise<void> {
    let oauth: McpOAuthProvider | null = null;
    if (this.config.oauth && this.config.transport === McpTransportKind.streamableHttp) {
      oauth = new McpOAuthProvider({
        config: this.config,
        interactive: interactiveAuth,
        store: this.tokenStore ?? (await createNoopTokenStore()),
        onAuthorizationUrl: (url: string) => {
          this.pendingAuthUrl = url;
          this.emit();
          this.onAuthUrl?.(url);
        },
      });
      await oauth.init();
      this.oauthProvider = oauth;
    }

    const transport = this.transportFactory != null
      ? await this.transportFactory()
      : await this.createTransport(oauth);
    this.transport = transport;
    const implementation: Implementation = { name: 'AI Terminal', version: '1.4.0' };
    // legacy initialize profile: compatible with the vast majority of servers;
    // global list_changed notifications are used. The stateless 2026
    // subscriptions/listen flow is not wired in yet.
    const client = new Client(implementation, {
      listChanged: {
        tools: { onChanged: () => this.scheduleRefresh() },
        resources: { onChanged: () => this.scheduleRefresh() },
        prompts: { onChanged: () => this.scheduleRefresh() },
      },
    });
    this.client = client;

    this.connectTimer = setTimeout(() => {
      // No cancellable public handle exists during connect; close the
      // transport at the deadline so the pending future settles.
      this.closeTransportOnly().catch(() => {});
    }, this.config.timeoutMs);

    try {
      await withTimeout(client.connect(transport), this.config.timeoutMs, '连接/调用超时');
    } catch (e) {
      if (e instanceof UnauthorizedError) {
        if (oauth != null && interactiveAuth) {
          const callback = await oauth.waitForCallback();
          if (callback.error != null) {
            throw new McpAuthRequiredException(
              'OAuth 授权失败：' + callback.error +
                (callback.errorDescription ? '（' + callback.errorDescription + '）' : ''),
            );
          }
          if (this.httpTransport == null) {
            throw new McpAuthRequiredException('当前传输方式不支持 OAuth');
          }
          await this.httpTransport.finishAuth(callback.code);
          await this.closeTransportOnly();
          await this.connectOnce(false);
          return;
        }
        throw new McpAuthRequiredException(
          oauth == null
            ? '服务器要求 OAuth 授权，请编辑服务器并开启 OAuth 后重试'
            : '需要 OAuth 授权',
          oauth?.pendingAuthUrl ?? '',
        );
      }
      throw e;
    } finally {
      if (this.connectTimer != null) {
        clearTimeout(this.connectTimer);
        this.connectTimer = null;
      }
    }

    this.listen(client, transport);
    await this.refreshAll();
  }

  private async createTransport(oauth: McpOAuthProvider | null): Promise<McpTransport> {
    switch (this.config.transport) {
      case McpTransportKind.streamableHttp: {
        const url = this.parseHttpUrl(this.config.url);
        const requestInit: RequestInit = {
          headers: { ...this.config.headers },
        };
        const opts: StreamableHTTPClientTransportOptions = {
          requestInit,
          authProvider: oauth ?? undefined,
        };
        // NOTE: config.proxy is not applied here — the Node StreamableHTTP
        // transport does not accept a custom HTTP client/proxy. (The Dart
        // original injected a proxied HttpClient via HttpOverrides, which has
        // no Node equivalent.)
        const transport = new StreamableHTTPClientTransport(new URL(url), opts);
        this.httpTransport = transport as unknown as HttpTransport;
        return transport;
      }
      case McpTransportKind.sse: {
        const url = this.parseHttpUrl(this.config.url);
        if (this.config.oauth) {
          throw new McpAuthRequiredException(
            '旧版 HTTP+SSE 传输不支持 OAuth，请在 headers 中配置 Authorization',
          );
        }
        const sseOpts: SSEClientTransportOptions = {
            requestInit: { headers: { ...this.config.headers } },
          };
        this.httpTransport = null;
        const transport = new SSEClientTransport(new URL(url), sseOpts);
        return transport;
      }
      case McpTransportKind.stdio: {
        // Node has no Flutter platform guard; all platforms that can spawn a
        // process are supported. (Dart only allowed desktop.)
        if (oauth != null) {
          throw new McpAuthRequiredException('stdio MCP 不支持 OAuth');
        }
        const command = this.resolveStdioCommand(this.config.command);
        if (command.length === 0) {
          throw new Error('stdio MCP 未配置启动命令');
        }
        const params: StdioServerParameters = {
          command,
          args: this.config.args,
          env: Object.keys(this.config.env).length > 0 ? { ...this.config.env } : undefined,
          cwd: this.config.workingDirectory.trim() ? this.config.workingDirectory.trim() : undefined,
          stderr: 'pipe',
        };
        const stdio = new StdioClientTransport(params);
        const stderr = stdio.stderr;
        if (stderr != null) {
          this.stderrStream = stderr as Readable;
          this.stderrStream.setEncoding('utf8');
          this.stderrStream.on('data', (chunk: string) => {
            const text = chunk.trim();
            if (text.length > 0) this.addLog('[stderr] ' + text);
          });
        }
        this.httpTransport = null;
        return stdio;
      }
    }
  }

  private parseHttpUrl(raw: string): string {
    let uri: URL | null;
    try {
      uri = new URL(raw.trim());
    } catch {
      throw new Error('MCP URL 无效：' + raw);
    }
    if (uri.protocol !== 'http:' && uri.protocol !== 'https:') {
      throw new Error('MCP URL 无效：' + raw);
    }
    return uri.toString();
  }

  private resolveStdioCommand(raw: string): string {
    let command = raw.trim();
    if (process.platform === 'win32' && /^(npx|pnpm|yarn|uvx)$/.test(command)) {
      command = command + '.cmd';
    }
    return command;
  }

  private listen(client: Client, transport: McpTransport): void {
    client.setNotificationHandler(ToolListChangedNotificationSchema, () => {
      this.scheduleRefresh();
    });
    client.setNotificationHandler(ResourceListChangedNotificationSchema, () => {
      this.scheduleRefresh();
    });
    client.setNotificationHandler(PromptListChangedNotificationSchema, () => {
      this.scheduleRefresh();
    });
    transport.onclose = () => {
      if (this.disposed || this.status !== McpServerStatus.connected) return;
      this.status = McpServerStatus.disconnected;
      this.error = '连接已关闭';
      this.emit();
    };
    transport.onerror = (error: Error) => {
      this.addLog('传输错误：' + error);
    };
  }

  private scheduleRefresh(): void {
    if (this.refreshTimer != null) clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => {
      this.refreshAll().catch(() => {});
    }, 300);
  }

  private async refreshAll(): Promise<void> {
    const client = this.client;
    if (client == null || this.refreshing || this.disposed) return;
    this.refreshing = true;
    try {
      const caps = client.getServerCapabilities();
      let tools = this.tools;
      let resources = this.resources;
      let prompts = this.prompts;

      if (caps != null && caps.tools != null) {
        try {
          tools = await this.listTools(client);
        } catch (e) {
          this.addLog('工具发现失败：' + this.friendlyError(e));
        }
      } else {
        tools = [];
      }

      if (caps != null && caps.resources != null) {
        try {
          const direct = await this.listResources(client);
          const templates = await this.listResourceTemplates(client);
          resources = [...direct, ...templates];
        } catch (e) {
          this.addLog('资源发现失败：' + this.friendlyError(e));
        }
      } else {
        resources = [];
      }

      if (caps != null && caps.prompts != null) {
        try {
          prompts = await this.listPrompts(client);
        } catch (e) {
          this.addLog('提示词发现失败：' + this.friendlyError(e));
        }
      } else {
        prompts = [];
      }

      this.tools = tools;
      this.resources = resources;
      this.prompts = prompts;
      this.error = '';
      this.emit();
    } catch (e) {
      if (e instanceof UnauthorizedError) {
        this.status = McpServerStatus.authRequired;
        this.error = 'OAuth 授权已过期，请重新登录';
        this.emit();
      } else {
        this.addLog('刷新能力失败：' + this.friendlyError(e));
      }
    } finally {
      this.refreshing = false;
    }
  }

  private async listTools(client: Client): Promise<McpToolDescriptor[]> {
    const out: McpToolDescriptor[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 10; page++) {
      const result = await client.listTools(
        cursor ? { cursor } : undefined,
        { timeout: this.config.timeoutMs },
      );
      for (const t of result.tools) out.push(this.mapTool(t));
      cursor = result.nextCursor;
      if (!cursor) break;
    }
    return out;
  }

  private async listResources(client: Client): Promise<McpResourceDescriptor[]> {
    const out: McpResourceDescriptor[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 10; page++) {
      const result = await client.listResources(
        cursor ? { cursor } : undefined,
        { timeout: this.config.timeoutMs },
      );
      for (const r of result.resources) {
        out.push({
          uri: r.uri,
          name: r.name,
          title: r.title ?? r.name,
          description: r.description ?? '',
          mimeType: r.mimeType ?? '',
          isTemplate: false,
        });
      }
      cursor = result.nextCursor;
      if (!cursor) break;
    }
    return out;
  }

  private async listResourceTemplates(client: Client): Promise<McpResourceDescriptor[]> {
    const out: McpResourceDescriptor[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 10; page++) {
      const result = await client.listResourceTemplates(
        cursor ? { cursor } : undefined,
        { timeout: this.config.timeoutMs },
      );
      for (const r of result.resourceTemplates) {
        out.push({
          uri: r.uriTemplate,
          name: r.name,
          title: r.title ?? r.name,
          description: r.description ?? '',
          mimeType: r.mimeType ?? '',
          isTemplate: true,
        });
      }
      cursor = result.nextCursor;
      if (!cursor) break;
    }
    return out;
  }

  private async listPrompts(client: Client): Promise<McpPromptDescriptor[]> {
    const out: McpPromptDescriptor[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 10; page++) {
      const result = await client.listPrompts(
        cursor ? { cursor } : undefined,
        { timeout: this.config.timeoutMs },
      );
      for (const p of result.prompts) {
        out.push({
          name: p.name,
          title: p.title ?? p.name,
          description: p.description ?? '',
          arguments: (p.arguments ?? []).map((a): McpPromptArgumentDescriptor => ({
            name: a.name,
            description: a.description ?? '',
            required: a.required === true,
          })),
        });
      }
      cursor = result.nextCursor;
      if (!cursor) break;
    }
    return out;
  }

  private mapTool(tool: {
    name: string;
    title?: string;
    description?: string;
    inputSchema: Record<string, unknown>;
    annotations?: {
      readOnlyHint?: boolean;
      destructiveHint?: boolean;
      idempotentHint?: boolean;
      openWorldHint?: boolean;
    };
  }): McpToolDescriptor {
    const annotations = tool.annotations;
    return {
      name: tool.name,
      title: tool.title ?? tool.name,
      description: tool.description ?? '',
      inputSchema: { ...tool.inputSchema },
      readOnly: annotations?.readOnlyHint ?? false,
      // MCP spec defaults destructiveHint = true; when absent, treat as
      // the most conservative choice.
      destructive: annotations?.destructiveHint ?? true,
      idempotent: annotations?.idempotentHint ?? false,
      openWorld: annotations?.openWorldHint ?? true,
    };
  }

  async callTool(toolName: string, arguments_: Record<string, unknown>): Promise<McpCallResult> {
    const client = this.client;
    if (client == null) {
      return { isError: true, text: 'MCP 服务器未连接' };
    }
    try {
      const result = await client.callTool(
        { name: toolName, arguments: arguments_ },
        undefined,
        { timeout: this.config.timeoutMs },
      );
      return {
        isError: result.isError === true,
        text: this.callResultText(result.content as ContentBlock[], result.structuredContent),
      };
    } catch (e) {
      if (e instanceof UnauthorizedError) {
        this.status = McpServerStatus.authRequired;
        this.error = 'OAuth 授权已过期，请重新登录';
        this.emit();
        throw new McpAuthRequiredException('OAuth 授权已过期，请重新登录');
      }
      return { isError: true, text: 'MCP 调用失败：' + this.friendlyError(e) };
    }
  }

  private callResultText(
    content:
      | ContentBlock[]
      | undefined,
    structuredContent: unknown,
  ): string {
    const buffer: string[] = [];
    if (content != null) {
      for (const c of content) {
        const text = this.contentText(c);
        if (text.length === 0) continue;
        buffer.push(text);
      }
    }
    if (buffer.length === 0 && structuredContent != null && structuredContent !== undefined) {
      buffer.push(encodeMcpJson(structuredContent));
    }
    if (buffer.length === 0) return '（MCP 工具返回空结果）';
    return this.cap(buffer.join('\n'), 20000);
  }

  private contentText(content: ContentBlock): string {
    switch (content.type) {
      case 'text':
        return content.text ?? '';
      case 'image':
        return '[图片 ' + content.mimeType + '，' + (content.data?.length ?? 0) + ' base64 字符]';
      case 'audio':
        return '[音频 ' + content.mimeType + '，' + (content.data?.length ?? 0) + ' base64 字符]';
      case 'resource': {
        const resource = content.resource;
        if (resource == null) return '';
        if ('text' in resource && resource.text != null) {
          return '[资源 ' + resource.uri + ']\n' + resource.text;
        }
        if ('blob' in resource && resource.blob != null) {
          return '[二进制资源 ' + resource.uri + '，' + resource.blob.length + ' base64 字符]';
        }
        return '[资源 ' + resource.uri + ']';
      }
      case 'resource_link':
        return '[资源链接] ' + content.name + ': ' + content.uri;
      default:
        return '';
    }
  }

  async readResource(uri: string): Promise<string> {
    const client = this.client;
    if (client == null) return 'MCP 服务器未连接';
    try {
      const result = await client.readResource({ uri }, { timeout: this.config.timeoutMs });
      const buffer: string[] = [];
      for (const c of result.contents) {
        if ('text' in c && c.text != null) {
          buffer.push('[' + c.uri + ']');
          buffer.push(c.text);
        } else if ('blob' in c && c.blob != null) {
          buffer.push('[二进制资源 ' + c.uri + '，' + c.blob.length + ' base64 字符]');
        } else {
          buffer.push('[资源 ' + c.uri + ']');
        }
      }
      return this.cap(buffer.join('\n').replace(/[\s]+$/, ''), 20000);
    } catch (e) {
      if (e instanceof UnauthorizedError) {
        throw new McpAuthRequiredException('OAuth 授权已过期，请重新登录');
      }
      return '读取资源失败：' + this.friendlyError(e);
    }
  }

  async getPrompt(name: string, arguments_: Record<string, string> = {}): Promise<string> {
    const client = this.client;
    if (client == null) return 'MCP 服务器未连接';
    try {
      const result = await client.getPrompt({ name, arguments: arguments_ }, {
        timeout: this.config.timeoutMs,
      });
      const buffer: string[] = [];
      if (result.description != null && result.description.length > 0) {
        buffer.push(result.description);
        buffer.push('');
      }
      for (const message of result.messages) {
        buffer.push('[' + message.role + ']');
        const content = message.content;
        const text = typeof content === 'string' ? content : this.contentText(content);
        if (text.length > 0) buffer.push(text);
        buffer.push('');
      }
      return this.cap(buffer.join('\n').replace(/[\s]+$/, ''), 20000);
    } catch (e) {
      if (e instanceof UnauthorizedError) {
        throw new McpAuthRequiredException('OAuth 授权已过期，请重新登录');
      }
      return '获取提示词失败：' + this.friendlyError(e);
    }
  }

  async disconnect(): Promise<void> {
    if (this.status === McpServerStatus.connected) {
      this.addLog('断开连接');
    }
    await this.closeTransportOnly();
    this.status = McpServerStatus.disconnected;
    this.error = '';
    this.pendingAuthUrl = '';
    this.connectedAt = null;
    this.disposed = true;
    this.emit();
  }

  private async closeTransportOnly(): Promise<void> {
    if (this.refreshTimer != null) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = null;
    }
    if (this.connectTimer != null) {
      clearTimeout(this.connectTimer);
      this.connectTimer = null;
    }
    if (this.stderrStream != null) {
      this.stderrStream.removeAllListeners('data');
      this.stderrStream = null;
    }
    const client = this.client;
    this.client = null;
    if (client != null) {
      try {
        await client.close();
      } catch (e) {
        console.error('[McpConnection] 关闭 client 失败: ' + e);
      }
    }
    const transport = this.transport;
    this.transport = null;
    this.httpTransport = null;
    if (transport != null) {
      try {
        await transport.close();
      } catch (e) {
        console.error('[McpConnection] 关闭 transport 失败: ' + e);
      }
    }
    const oauth = this.oauthProvider;
    this.oauthProvider = null;
    if (oauth != null) {
      await oauth.dispose();
    }
  }

  private friendlyError(error: unknown): string {
    if (error instanceof McpAuthRequiredException) return error.message;
    if (error instanceof UnauthorizedError) return '需要 OAuth 授权';
    if (error instanceof McpError) return error.message;
    if (error instanceof Error) return error.message;
    return String(error);
  }

  private cap(input: string, max: number): string {
    if (input.length <= max) return input;
    return input.substring(0, max) + '\n...(已截断，共 ' + input.length + ' 字符)';
  }
}

// ─── Local content-block shape (mirrors SDK ContentBlock union) ─────────

interface ContentBlock {
  type: string;
  text?: string;
  data?: string;
  mimeType?: string;
  resource?: Record<string, unknown> & { uri: string; text?: string; blob?: string };
  name?: string;
  uri?: string;
}

// ─── Helpers ─────────────────────────────────────────────────────────────

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(label)), ms);
    promise.then(
      (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      (err) => {
        clearTimeout(timer);
        reject(err);
      },
    );
  });
}

async function createNoopTokenStore(): Promise<McpOAuthTokenStore> {
  return {
    async load() {
      return null;
    },
    async save() {
      /* no-op */
    },
  };
}
