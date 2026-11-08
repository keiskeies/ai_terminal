// MCP OAuth provider — ported from ai_terminal/lib/services/mcp_oauth.dart
//
// The Dart version implemented mcp_dart's OAuthAuthorizationCodeProvider. The
// Node SDK instead expects an OAuthClientProvider, so this port implements that
// interface (redirectUrl / clientMetadata / clientInformation / tokens /
// saveTokens / redirectToAuthorization / saveCodeVerifier / codeVerifier) while
// keeping the loopback HTTP callback server and the persisted token model
// (McpOAuthTokenData) byte-faithful to the Dart source.

import * as http from 'node:http';
import type { AddressInfo } from 'node:net';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';

import type { OAuthClientProvider } from '@modelcontextprotocol/sdk/client/auth';
import type {
  OAuthClientInformation,
  OAuthClientInformationMixed,
  OAuthClientMetadata,
  OAuthTokens,
} from '@modelcontextprotocol/sdk/shared/auth';

import type { McpOAuthCallback, McpOAuthTokenData, McpServerConfig } from './models.js';
import { mcpOAuthTokenIsExpired } from './models.js';

/** Persistence port of McpStore.loadOAuthToken / saveOAuthToken. */
export interface McpOAuthTokenStore {
  load(serverId: string): Promise<McpOAuthTokenData | null>;
  save(serverId: string, data: McpOAuthTokenData): Promise<void>;
}

export interface McpOAuthProviderOptions {
  config: McpServerConfig;
  interactive: boolean;
  store: McpOAuthTokenStore;
  onAuthorizationUrl?: (url: string) => void;
}

export class McpOAuthProvider implements OAuthClientProvider {
  readonly config: McpServerConfig;
  private readonly interactive: boolean;
  private readonly store: McpOAuthTokenStore;
  private readonly onAuthorizationUrl?: (url: string) => void;

  private server: http.Server | null = null;
  private redirectUri: string | null = null;
  private authUrlValue = '';
  private disposed = false;
  private callbackPromise: Promise<McpOAuthCallback> | null = null;
  private callbackResolve: ((cb: McpOAuthCallback) => void) | null = null;
  private codeVerifierValue = '';
  private stateValue = randomBytes(16).toString('hex');

  constructor(options: McpOAuthProviderOptions) {
    this.config = options.config;
    this.interactive = options.interactive;
    this.store = options.store;
    this.onAuthorizationUrl = options.onAuthorizationUrl;
    // Seed the lazily-created callback promise.
    this.callbackPromise = new Promise<McpOAuthCallback>((resolve) => {
      this.callbackResolve = resolve;
    });
  }

  get pendingAuthUrl(): string {
    return this.authUrlValue;
  }

  /** Binds the loopback HTTP callback server (port 0 = ephemeral). */
  async init(): Promise<void> {
    this.server = http.createServer((req, res) => {
      void this.handleRequest(req, res);
    });
    await new Promise<void>((resolve, reject) => {
      this.server!.once('error', reject);
      this.server!.listen(0, '127.0.0.1', () => {
        this.server!.removeListener('error', reject);
        resolve();
      });
    });
    const address = this.server.address() as AddressInfo;
    this.redirectUri = 'http://127.0.0.1:' + address.port + '/callback';
  }

  // ── OAuthClientProvider ────────────────────────────────────────────────

  get redirectUrl(): string | URL | undefined {
    return this.redirectUri ?? undefined;
  }

  get clientMetadata(): OAuthClientMetadata {
    const meta: OAuthClientMetadata = {
      redirect_uris: this.redirectUri != null ? [this.redirectUri] : [],
      grant_types: ['authorization_code'],
      response_types: ['code'],
      client_name: 'AI Terminal',
    };
    const secret = this.config.oauthClientSecret.trim();
    meta.token_endpoint_auth_method = secret ? 'client_secret_basic' : 'none';
    const scope = this.config.oauthScopes.filter((s) => s.trim().length > 0).join(' ');
    if (scope) meta.scope = scope;
    return meta;
  }

  async clientInformation(): Promise<OAuthClientInformationMixed | undefined> {
    const clientId = this.config.oauthClientId.trim();
    if (!clientId) return undefined;
    const info: OAuthClientInformation = { client_id: clientId };
    const secret = this.config.oauthClientSecret.trim();
    if (secret) info.client_secret = secret;
    return info;
  }

  async tokens(): Promise<OAuthTokens | undefined> {
    const data = await this.store.load(this.config.id);
    if (data == null || mcpOAuthTokenIsExpired(data)) return undefined;
    const out: OAuthTokens = {
      access_token: data.accessToken,
      token_type: 'Bearer',
    };
    if (data.refreshToken) out.refresh_token = data.refreshToken;
    if (data.issuer) out.issuer = data.issuer;
    return out;
  }

  async saveTokens(tokens: OAuthTokens): Promise<void> {
    let expiresAtMs: number | undefined;
    if (typeof tokens.expires_in === 'number' && tokens.expires_in > 0) {
      expiresAtMs = Date.now() + tokens.expires_in * 1000;
    }
    const data: McpOAuthTokenData = {
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token,
      expiresAtMs,
      issuer: tokens.issuer,
    };
    await this.store.save(this.config.id, data);
  }

  async redirectToAuthorization(authorizationUrl: URL): Promise<void> {
    this.authUrlValue = authorizationUrl.toString();
    this.onAuthorizationUrl?.(authorizationUrl.toString());
    if (!this.interactive) return;
    await openExternal(authorizationUrl.toString());
  }

  saveCodeVerifier(codeVerifier: string): void {
    this.codeVerifierValue = codeVerifier;
  }

  codeVerifier(): string {
    return this.codeVerifierValue;
  }

  state(): string {
    return this.stateValue;
  }

  // ── Callback ───────────────────────────────────────────────────────────

  /** Resolves when the loopback callback fires; rejects after timeoutMs. */
  waitForCallback(timeoutMs = 5 * 60 * 1000): Promise<McpOAuthCallback> {
    if (this.disposed) throw new StateError('OAuth provider 已关闭');
    return new Promise<McpOAuthCallback>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error('MCP OAuth 回调超时'));
      }, timeoutMs);
      this.callbackPromise!.then(
        (cb) => {
          clearTimeout(timer);
          resolve(cb);
        },
        () => {
          clearTimeout(timer);
          reject(new Error('MCP OAuth 回调超时'));
        },
      );
    });
  }

  private handleRequest(req: http.IncomingMessage, res: http.ServerResponse): void {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    if (url.pathname !== '/callback') {
      res.statusCode = 404;
      res.end();
      return;
    }
    const code = url.searchParams.get('code') ?? '';
    const state = url.searchParams.get('state') ?? '';
    const error = url.searchParams.get('error') ?? undefined;
    const errorDescription = url.searchParams.get('error_description') ?? undefined;
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    if (error != null) {
      res.write(
        '<html><body><h2>MCP 授权失败</h2><p>' +
          escapeHtml(error) + '：' + escapeHtml(errorDescription ?? '') +
          '</p><p>可以关闭此页面并回到 AI Terminal 查看详情。</p></body></html>',
      );
    } else {
      res.write(
        '<html><body><h2>MCP 授权完成</h2>' +
          '<p>可以关闭此页面并回到 AI Terminal。</p></body></html>',
      );
    }
    res.end();
    this.callbackResolve?.({ code, state, error, errorDescription });
  }

  async dispose(): Promise<void> {
    this.disposed = true;
    if (this.server != null) {
      await new Promise<void>((resolve) => this.server!.close(() => resolve()));
      this.server = null;
    }
  }
}

function openExternal(url: string): Promise<boolean> {
  try {
    let cmd: string;
    let args: string[];
    switch (process.platform) {
      case 'win32':
        cmd = 'cmd';
        args = ['/c', 'start', '', url];
        break;
      case 'darwin':
        cmd = 'open';
        args = [url];
        break;
      default:
        cmd = 'xdg-open';
        args = [url];
        break;
    }
    const child = spawn(cmd, args, { stdio: 'ignore', detached: true });
    child.on('error', () => {
      /* UI shows a copyable auth link instead */
    });
    child.unref();
    return Promise.resolve(true);
  } catch {
    return Promise.resolve(false);
  }
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Minimal StateError so the provider is self-contained (Dart's dart:io
// StateError has no direct Node equivalent).
class StateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'StateError';
  }
}
