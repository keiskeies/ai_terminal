import 'dart:async';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

import 'mcp_models.dart';
import 'mcp_store.dart';

/// MCP OAuth 授权码 + PKCE + DCR 的客户端 provider
///
/// mcp_dart 负责发现、DCR、PKCE 和 token 交换；这里负责：
/// - loopback 回调服务器
/// - 打开浏览器（桌面端）/ 把授权链接交给 UI（移动端或打开失败）
/// - token 持久化（CredentialsStore）
class McpOAuthProvider implements OAuthAuthorizationCodeProvider {
  McpOAuthProvider({
    required this.config,
    required this.interactive,
    this.onAuthorizationUrl,
  });

  final McpServerConfig config;
  final bool interactive;
  final void Function(Uri url)? onAuthorizationUrl;

  HttpServer? _server;
  Uri? _redirectUri;
  String _pendingAuthUrl = '';
  bool _disposed = false;
  final Completer<McpOAuthCallback> _callback =
      Completer<McpOAuthCallback>();

  String get pendingAuthUrl => _pendingAuthUrl;

  Future<void> init() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _redirectUri =
        Uri.parse('http://127.0.0.1:${_server!.port}/callback');
    _server!.listen(_handleRequest);
  }

  @override
  String get clientId => config.oauthClientId.trim();

  @override
  Uri get redirectUri {
    final uri = _redirectUri;
    if (uri == null) {
      throw StateError('McpOAuthProvider 尚未初始化');
    }
    return uri;
  }

  @override
  String? get clientSecret {
    final value = config.oauthClientSecret.trim();
    return value.isEmpty ? null : value;
  }

  @override
  List<String> get scopes => config.oauthScopes;

  @override
  Future<OAuthTokens?> tokens() async {
    final data = await McpStore.loadOAuthToken(config.id);
    if (data == null || data.isExpired) return null;
    return OAuthTokens(
      accessToken: data.accessToken,
      refreshToken: data.refreshToken,
    );
  }

  @override
  Future<void> saveTokens(OAuthTokens tokens) async {
    int? expiresAtMs;
    String? issuer;
    String? resource;
    if (tokens is OAuthAuthorizationCodeTokens) {
      final expiresIn = tokens.expiresIn;
      if (expiresIn != null && expiresIn > 0) {
        expiresAtMs =
            DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
      }
    }
    if (tokens is OAuthIssuerBoundAuthorizationCodeTokens) {
      issuer = tokens.authorizationServerIssuer;
      resource = tokens.resource.toString();
    }
    await McpStore.saveOAuthToken(
      config.id,
      McpOAuthTokenData(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAtMs: expiresAtMs,
        issuer: issuer,
        resource: resource,
      ),
    );
  }

  @override
  Future<void> redirectToAuthorization() async {
    // OAuthAuthorizationCodeProvider 走 redirectToAuthorizationUrl；
    // 非授权码流程不应使用本 provider。
  }

  @override
  Future<void> redirectToAuthorizationUrl(Uri authorizationUri) async {
    _pendingAuthUrl = authorizationUri.toString();
    onAuthorizationUrl?.call(authorizationUri);
    if (!interactive) return;
    await _openExternal(authorizationUri);
  }

  Future<McpOAuthCallback> waitForCallback({
    Duration timeout = const Duration(minutes: 5),
  }) {
    if (_disposed) {
      throw StateError('OAuth provider 已关闭');
    }
    return _callback.future.timeout(timeout);
  }

  Future<bool> _openExternal(Uri url) async {
    try {
      if (Platform.isWindows) {
        await Process.start(
          'cmd',
          ['/c', 'start', '', url.toString()],
          runInShell: false,
        );
        return true;
      }
      if (Platform.isMacOS) {
        await Process.start('open', [url.toString()]);
        return true;
      }
      if (Platform.isLinux) {
        await Process.start('xdg-open', [url.toString()]);
        return true;
      }
    } catch (_) {
      // UI 会展示可复制的授权链接
    }
    return false;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path != '/callback') {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final params = request.uri.queryParameters;
    final code = params['code'] ?? '';
    final state = params['state'] ?? '';
    final error = params['error'];
    final errorDescription = params['error_description'];
    response.headers.contentType = ContentType.html;
    if (error != null) {
      response.write(
        '<html><body><h2>MCP 授权失败</h2><p>'
        '${_escapeHtml(error)}：${_escapeHtml(errorDescription ?? '')}'
        '</p><p>可以关闭此页面并回到 AI Terminal 查看详情。</p></body></html>',
      );
    } else {
      response.write(
        '<html><body><h2>MCP 授权完成</h2>'
        '<p>可以关闭此页面并回到 AI Terminal。</p></body></html>',
      );
    }
    await response.close();
    if (!_callback.isCompleted) {
      _callback.complete(McpOAuthCallback(
        code: code,
        state: state,
        error: error,
        errorDescription: errorDescription,
      ));
    }
  }

  String _escapeHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  Future<void> dispose() async {
    _disposed = true;
    await _server?.close(force: true);
    _server = null;
  }
}
