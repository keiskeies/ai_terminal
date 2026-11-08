// MCP manager — ported from ai_terminal/lib/services/mcp_manager.dart
// Owns server config, connection lifecycle, capability discovery and tool
// registration sync. The Dart version was a ChangeNotifier singleton backed
// by Hive; this Node port is instantiable (for tests) and takes an injectable
// McpStore persistence adapter (no global singleton by default).

import type {
  AgentTool,
  AgentToolRegistry,
} from '../tools/builtin.js';
import { ToolScope } from '../tools/builtin.js';
import {
  McpAuthRequiredException,
  McpCallResult,
  McpOAuthTokenData,
  McpServerConfig,
  McpServerRuntime,
  McpServerStatus,
  McpToolDescriptor,
  McpToolExposure,
  mcpServerRuntimeCopyWith,
  mcpToolExposureFromString,
  mcpServerConfigCopyWith,
  mcpSlug,
  mcpToolFullName,
} from './models.js';
import { McpConnection } from './connection.js';
import type { McpOAuthTokenStore } from './oauth.js';
import {
  McpSideToolAdapter,
  McpSideToolKind,
  McpToolAdapter,
  McpToolCaller,
} from './tool_adapter.js';

/** Node persistence port of the Dart Hive-backed McpStore. */
export interface McpStore {
  loadGlobalEnabled(): Promise<boolean>;
  saveGlobalEnabled(value: boolean): Promise<void>;
  loadAll(): Promise<McpServerConfig[]>;
  saveConfigs(configs: McpServerConfig[]): Promise<void>;
  saveAll(configs: McpServerConfig[], removedIds?: string[]): Promise<void>;
  loadOAuthToken(serverId: string): Promise<McpOAuthTokenData | null>;
  saveOAuthToken(serverId: string, data: McpOAuthTokenData): Promise<void>;
  deleteOAuthToken(serverId: string): Promise<void>;
}

/** An in-memory McpStore (default + test double). */
export class InMemoryMcpStore implements McpStore {
  private configs: McpServerConfig[] = [];
  private globalEnabled = true;
  private tokens = new Map<string, McpOAuthTokenData>();

  async loadGlobalEnabled(): Promise<boolean> {
    return this.globalEnabled;
  }
  async saveGlobalEnabled(value: boolean): Promise<void> {
    this.globalEnabled = value;
  }
  async loadAll(): Promise<McpServerConfig[]> {
    return this.configs.map((c) => ({ ...c }));
  }
  async saveConfigs(configs: McpServerConfig[]): Promise<void> {
    this.configs = configs.map((c) => ({ ...c }));
  }
  async saveAll(configs: McpServerConfig[], removedIds?: string[]): Promise<void> {
    this.configs = configs.map((c) => ({ ...c }));
    for (const id of removedIds ?? []) this.tokens.delete(id);
  }
  async loadOAuthToken(serverId: string): Promise<McpOAuthTokenData | null> {
    return this.tokens.get(serverId) ?? null;
  }
  async saveOAuthToken(serverId: string, data: McpOAuthTokenData): Promise<void> {
    this.tokens.set(serverId, data);
  }
  async deleteOAuthToken(serverId: string): Promise<void> {
    this.tokens.delete(serverId);
  }
}

function makeOAuthTokenStore(store: McpStore): McpOAuthTokenStore {
  return {
    load: (serverId) => store.loadOAuthToken(serverId),
    save: (serverId, data) => store.saveOAuthToken(serverId, data),
  };
}

export interface McpManagerOptions {
  store: McpStore;
  /** When set, this factory is used to create MCP transports instead of the built-in ones. */
  transportFactory?: () => Promise<import('./connection.js').McpTransport> | import('./connection.js').McpTransport;
}

export class McpManager implements McpToolCaller {
  private static readonly globalToolCap = 40;

  private readonly store: McpStore;
  private readonly transportFactory?: () => Promise<import('./connection.js').McpTransport> | import('./connection.js').McpTransport;
  private readonly _configs: McpServerConfig[] = [];
  private readonly _runtimes = new Map<string, McpServerRuntime>();
  private readonly connections = new Map<string, McpConnection>();
  private readonly listeners: Array<() => void> = [];

  private initialized = false;
  private disposed = false;
  private _enabled = true;
  private _toolsetVersion = 0;
  private lastSignature = '';

  constructor(options: McpManagerOptions) {
    this.store = options.store;
    this.transportFactory = options.transportFactory;
  }

  // ── ChangeNotifier-equivalent listener plumbing ───────────────────────

  addListener(fn: () => void): void {
    this.listeners.push(fn);
  }
  removeListener(fn: () => void): void {
    const i = this.listeners.indexOf(fn);
    if (i >= 0) this.listeners.splice(i, 1);
  }
  private notifyListeners(): void {
    if (this.disposed) return;
    for (const fn of [...this.listeners]) fn();
  }

  // ── Read-only views ───────────────────────────────────────────────────

  get configs(): McpServerConfig[] {
    return this._configs.map((c) => mcpServerConfigCopyWith(c, {}));
  }
  get runtimes(): Map<string, McpServerRuntime> {
    return new Map(this._runtimes);
  }
  get toolsetVersion(): number {
    return this._toolsetVersion;
  }
  get enabled(): boolean {
    return this._enabled;
  }
  get connectedCount(): number {
    return [...this._runtimes.values()].filter((r) => r.status === McpServerStatus.connected).length;
  }
  get exposedToolCount(): number {
    return this.buildAgentTools().length;
  }

  runtimeFor(id: string): McpServerRuntime | null {
    return this._runtimes.get(id) ?? null;
  }
  configFor(id: string): McpServerConfig | null {
    for (const config of this._configs) {
      if (config.id === id) return config;
    }
    return null;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────

  /**
   * Load global-enabled flag + all configs, then auto-connect the ones marked
   * enabled + autoConnect. (The Dart version also wired setMcpLogHandler to
   * silence mcp_dart's stderr logging on Windows; the Node SDK has no such
   * global log hook, so that step is intentionally omitted.)
   */
  async init(): Promise<void> {
    if (this.initialized || this.disposed) return;
    this.initialized = true;
    try {
      this._enabled = await this.store.loadGlobalEnabled();
      const loaded = await this.store.loadAll();
      this._configs.length = 0;
      this._configs.push(...loaded);
      for (const config of loaded) {
        this._runtimes.set(config.id, {
          config,
          status: !this._enabled
            ? McpServerStatus.disconnected
            : config.enabled
              ? McpServerStatus.disconnected
              : McpServerStatus.disabled,
          error: '',
          pendingAuthUrl: '',
          tools: [],
          resources: [],
          prompts: [],
          logs: [],
          connectedAt: null,
        });
      }
      this.notifyListeners();
      if (!this._enabled) return;
      for (const config of loaded) {
        if (config.enabled && config.autoConnect) {
          this.connect(config.id).catch((e) =>
            console.error('[McpManager] 自动连接失败 ' + config.id + ': ' + e),
          );
        }
      }
    } catch (e) {
      console.error('[McpManager] 初始化失败: ' + e);
    }
  }

  /** Global switch: when off, disconnect all + hide MCP tools, keep configs. */
  async setGlobalEnabled(value: boolean): Promise<void> {
    if (this._enabled === value) return;
    this._enabled = value;
    await this.store.saveGlobalEnabled(value);
    if (!value) {
      const ids = [...this.connections.keys()];
      for (const id of ids) {
        const connection = this.connections.get(id);
        this.connections.delete(id);
        if (connection != null) await connection.disconnect();
      }
      for (const config of this._configs) {
        this._runtimes.set(config.id, this.blankRuntime(config, McpServerStatus.disconnected));
      }
    } else {
      for (const config of this._configs) {
        if (config.enabled) {
          this.connect(config.id).catch((e) =>
            console.error('[McpManager] 连接失败 ' + config.id + ': ' + e),
          );
        } else {
          this._runtimes.set(config.id, this.blankRuntime(config, McpServerStatus.disabled));
        }
      }
    }
    this.bumpVersionIfNeeded();
    this.notifyListeners();
  }

  async connect(id: string, interactiveAuth = false): Promise<void> {
    if (this.disposed || !this._enabled) return;
    const index = this._configs.findIndex((c) => c.id === id);
    if (index < 0) return;
    let config = this._configs[index];
    if (!config.enabled) {
      config = mcpServerConfigCopyWith(config, { enabled: true });
      this._configs[index] = config;
      try {
        await this.store.saveConfigs(this._configs);
      } catch (e) {
        console.error('[McpManager] 保存启用状态失败: ' + e);
      }
    }

    const old = this.connections.get(id);
    this.connections.delete(id);
    if (old != null) await old.disconnect();

    const previous = this._runtimes.get(id);
    this._runtimes.set(id, {
      config,
      status: McpServerStatus.connecting,
      error: '',
      pendingAuthUrl: '',
      tools: previous?.tools ?? [],
      resources: previous?.resources ?? [],
      prompts: previous?.prompts ?? [],
      logs: previous?.logs ?? [],
      connectedAt: previous?.connectedAt ?? null,
    });
    this.notifyListeners();

    const connection = new McpConnection({
      config,
      tokenStore: makeOAuthTokenStore(this.store),
      transportFactory: this.transportFactory,
      onRuntime: (runtime: McpServerRuntime) => {
        if (this.disposed || this.connections.get(id) !== connection) return;
        this._runtimes.set(id, runtime);
        this.bumpVersionIfNeeded();
        this.notifyListeners();
      },
    });
    this.connections.set(id, connection);
    await connection.connect(interactiveAuth);
  }

  async login(id: string): Promise<void> {
    await this.connect(id, true);
  }

  async disconnect(id: string): Promise<void> {
    const connection = this.connections.get(id);
    this.connections.delete(id);
    if (connection != null) await connection.disconnect();
    const config = this.configFor(id);
    if (config != null) {
      this._runtimes.set(
        id,
        this.blankRuntime(config, config.enabled ? McpServerStatus.disconnected : McpServerStatus.disabled),
      );
    }
    this.bumpVersionIfNeeded();
    this.notifyListeners();
  }

  async setEnabled(id: string, enabled: boolean): Promise<void> {
    const index = this._configs.findIndex((c) => c.id === id);
    if (index < 0) return;
    const next = [...this._configs];
    next[index] = mcpServerConfigCopyWith(next[index], { enabled });
    await this.store.saveConfigs(next);
    this._configs.length = 0;
    this._configs.push(...next);
    if (!enabled) {
      await this.disconnect(id);
    } else if (this._enabled) {
      this.connect(id).catch((e) => console.error('[McpManager] 连接失败 ' + id + ': ' + e));
    } else {
      const runtime = this._runtimes.get(id);
      if (runtime != null) {
        this._runtimes.set(
          id,
          mcpServerRuntimeCopyWith(runtime, {
            status: McpServerStatus.disconnected,
            error: '',
            pendingAuthUrl: '',
            clearConnectedAt: true,
          }),
        );
      }
    }
    this.notifyListeners();
  }

  async saveServer(config: McpServerConfig): Promise<void> {
    const next: McpServerConfig[] = [];
    let replaced = false;
    for (const existing of this._configs) {
      if (existing.id === config.id) {
        next.push(config);
        replaced = true;
      } else {
        next.push(existing);
      }
    }
    if (!replaced) next.push(config);
    await this.store.saveAll(next);

    this._configs.length = 0;
    this._configs.push(...next);
    const old = this.connections.get(config.id);
    this.connections.delete(config.id);
    if (old != null) await old.disconnect();

    this._runtimes.set(
      config.id,
      this.blankRuntime(config, config.enabled ? McpServerStatus.disconnected : McpServerStatus.disabled),
    );
    this.bumpVersionIfNeeded();
    this.notifyListeners();
    if (config.enabled) {
      this.connect(config.id).catch((e) =>
        console.error('[McpManager] 连接失败 ' + config.id + ': ' + e),
      );
    }
  }

  async deleteServer(id: string): Promise<void> {
    const next = this._configs.filter((c) => c.id !== id);
    await this.store.saveAll(next, [id]);
    const connection = this.connections.get(id);
    this.connections.delete(id);
    if (connection != null) await connection.disconnect();
    this._configs.length = 0;
    this._configs.push(...next);
    this._runtimes.delete(id);
    this.bumpVersionIfNeeded();
    this.notifyListeners();
  }

  /** Update the custom-mode whitelist only; does not reconnect. */
  async setAllowedTools(id: string, allowed: string[]): Promise<void> {
    const index = this._configs.findIndex((c) => c.id === id);
    if (index < 0) return;
    const next = [...this._configs];
    next[index] = mcpServerConfigCopyWith(next[index], { allowedTools: allowed });
    await this.store.saveConfigs(next);
    this._configs.length = 0;
    this._configs.push(...next);
    const runtime = this._runtimes.get(id);
    if (runtime != null) {
      this._runtimes.set(id, mcpServerRuntimeCopyWith(runtime, { config: this._configs[index] }));
    }
    this.bumpVersionIfNeeded();
    this.notifyListeners();
  }

  // ── Tool building ─────────────────────────────────────────────────────

  buildAgentTools(): AgentTool[] {
    if (!this._enabled) return [];
    const out: AgentTool[] = [];
    const usedNames = new Set<string>();
    for (const runtime of this._runtimes.values()) {
      if (runtime.status !== McpServerStatus.connected) continue;
      const config = runtime.config;
      const allowed = runtime.tools.filter((tool) => this.isToolExposed(config, tool)).slice(0, config.maxTools);
      for (const tool of allowed) {
        if (out.length >= McpManager.globalToolCap) break;
        const base = mcpToolFullName(config.id, tool.name);
        const name = this.uniqueName(base, usedNames);
        out.push(
          new McpToolAdapter({
            caller: this,
            serverId: config.id,
            serverName: config.name,
            descriptor: tool,
            nameOverride: name,
          }),
        );
      }
      if (out.length >= McpManager.globalToolCap) break;
      if (config.exposeResources && runtime.resources.length > 0) {
        for (const kind of [McpSideToolKind.listResources, McpSideToolKind.readResource]) {
          const suffix = kind === McpSideToolKind.listResources ? 'list_resources' : 'read_resource';
          const name = this.uniqueName(mcpToolFullName(config.id, suffix), usedNames);
          out.push(
            new McpSideToolAdapter({
              caller: this,
              serverId: config.id,
              serverName: config.name,
              sideKind: kind,
              nameOverride: name,
            }),
          );
        }
      }
      if (out.length >= McpManager.globalToolCap) break;
      if (config.exposePrompts && runtime.prompts.length > 0) {
        for (const kind of [McpSideToolKind.listPrompts, McpSideToolKind.getPrompt]) {
          const suffix = kind === McpSideToolKind.listPrompts ? 'list_prompts' : 'get_prompt';
          const name = this.uniqueName(mcpToolFullName(config.id, suffix), usedNames);
          out.push(
            new McpSideToolAdapter({
              caller: this,
              serverId: config.id,
              serverName: config.name,
              sideKind: kind,
              nameOverride: name,
            }),
          );
        }
      }
    }
    return out.slice(0, McpManager.globalToolCap);
  }

  isToolExposed(config: McpServerConfig, tool: McpToolDescriptor): boolean {
    switch (config.toolExposure) {
      case McpToolExposure.readOnly:
        return tool.readOnly;
      case McpToolExposure.all:
        return true;
      case McpToolExposure.custom:
        return config.allowedTools.includes(tool.name);
    }
  }

  private uniqueName(base: string, used: Set<string>): string {
    if (used.add(base)) return base;
    for (let i = 2; i < 100; i++) {
      const suffix = '_' + i;
      const candidate =
        base.length + suffix.length <= 64
          ? base + suffix
          : base.substring(0, 64 - suffix.length) + suffix;
      if (used.add(candidate)) return candidate;
    }
    return base;
  }

  /** Sync the current MCP tools into an AgentEngine registry. */
  syncRegistry(registry: AgentToolRegistry): number {
    registry.unregisterPrefix('mcp__');
    const tools = this.buildAgentTools();
    for (const tool of tools) {
      registry.register(tool, ToolScope.all);
    }
    const signature = this.signatureOf(tools);
    if (signature !== this.lastSignature) {
      this.lastSignature = signature;
      this._toolsetVersion++;
    }
    return this._toolsetVersion;
  }

  private bumpVersionIfNeeded(): void {
    const signature = this.signatureOf(this.buildAgentTools());
    if (signature === this.lastSignature) return;
    this.lastSignature = signature;
    this._toolsetVersion++;
  }

  private signatureOf(tools: AgentTool[]): string {
    return tools.map((tool) => tool.name + ':' + tool.kind + ':' + tool.source).join(';');
  }

  private blankRuntime(config: McpServerConfig, status: McpServerStatus): McpServerRuntime {
    return {
      config,
      status,
      error: '',
      pendingAuthUrl: '',
      tools: [],
      resources: [],
      prompts: [],
      logs: [],
      connectedAt: null,
    };
  }

  // ── McpToolCaller (implemented by the manager) ───────────────────────

  mcpRuntime(serverId: string): McpServerRuntime | null {
    return this._runtimes.get(serverId) ?? null;
  }

  async callMcpTool(
    serverId: string,
    toolName: string,
    arguments_: Record<string, unknown>,
  ): Promise<McpCallResult> {
    const connection = this.connections.get(serverId);
    if (connection == null) {
      return { isError: true, text: 'MCP 服务器未连接，请在设置中重新连接。' };
    }
    return connection.callTool(toolName, arguments_);
  }

  async readMcpResource(serverId: string, uri: string): Promise<string> {
    const connection = this.connections.get(serverId);
    if (connection == null) return 'MCP 服务器未连接';
    return connection.readResource(uri);
  }

  async getMcpPrompt(
    serverId: string,
    name: string,
    arguments_: Record<string, string> = {},
  ): Promise<string> {
    const connection = this.connections.get(serverId);
    if (connection == null) return 'MCP 服务器未连接';
    return connection.getPrompt(name, arguments_);
  }

  // ── Test helpers ──────────────────────────────────────────────────────

  setRuntimeForTesting(runtime: McpServerRuntime): void {
    this.initialized = true;
    const idx = this._configs.findIndex((c) => c.id === runtime.config.id);
    if (idx >= 0) this._configs.splice(idx, 1);
    this._configs.push(runtime.config);
    this._runtimes.set(runtime.config.id, runtime);
  }

  loadConfigsForTesting(configs: McpServerConfig[]): void {
    this._enabled = true;
    const connections = [...this.connections.values()];
    this.connections.clear();
    for (const c of connections) c.disconnect().catch(() => {});
    this._configs.length = 0;
    this._configs.push(...configs);
    this._runtimes.clear();
    for (const config of configs) {
      this._runtimes.set(
        config.id,
        this.blankRuntime(config, config.enabled ? McpServerStatus.disconnected : McpServerStatus.disabled),
      );
    }
    this.initialized = true;
  }

  async reloadForTests(): Promise<void> {
    const connections = [...this.connections.values()];
    this.connections.clear();
    for (const c of connections) await c.disconnect();
    this._configs.length = 0;
    this._runtimes.clear();
    this.initialized = false;
    this.lastSignature = '';
    await this.init();
  }

  // ── Shutdown / dispose ────────────────────────────────────────────────

  /** Wait for connections to close / stdio children to exit. */
  async shutdown(): Promise<void> {
    if (this.disposed) return;
    this.disposed = true;
    const connections = [...this.connections.values()];
    this.connections.clear();
    await Promise.all(connections.map((c) => c.disconnect()));
  }

  /** Fire-and-forget shutdown (Dart ChangeNotifier.dispose → unawaited). */
  dispose(): void {
    this.shutdown().catch(() => {});
  }
}

// Re-exported for consumers that build configs/parse exposure strings.
export { mcpSlug, mcpToolExposureFromString, McpAuthRequiredException };
