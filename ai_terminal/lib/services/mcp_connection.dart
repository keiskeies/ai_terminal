import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'mcp_models.dart';
import 'mcp_oauth.dart';

/// 一个 MCP 服务器的连接
///
/// 负责 transport/client 生命周期、能力发现、通知、工具调用与 OAuth。
/// 通过 [onRuntime] 把状态推给 McpManager/UI。
class McpConnection {
  McpConnection({
    required this.config,
    required this.onRuntime,
    this.onAuthUrl,
  });

  final McpServerConfig config;
  final void Function(McpServerRuntime runtime) onRuntime;
  final void Function(String url)? onAuthUrl;

  McpClient? _client;
  Transport? _transport;
  McpOAuthProvider? _oauthProvider;
  StreamSubscription<List<int>>? _stderrSub;
  Timer? _refreshTimer;
  Timer? _connectTimer;

  McpServerStatus _status = McpServerStatus.disconnected;
  String _error = '';
  String _pendingAuthUrl = '';
  List<McpToolDescriptor> _tools = const [];
  List<McpResourceDescriptor> _resources = const [];
  List<McpPromptDescriptor> _prompts = const [];
  List<String> _logs = const [];
  DateTime? _connectedAt;
  bool _disposed = false;
  bool _refreshing = false;

  McpServerRuntime get runtime => McpServerRuntime(
        config: config,
        status: _status,
        error: _error,
        pendingAuthUrl: _pendingAuthUrl,
        tools: _tools,
        resources: _resources,
        prompts: _prompts,
        logs: _logs,
        connectedAt: _connectedAt,
      );

  void _emit() {
    if (_disposed) return;
    onRuntime(runtime);
  }

  void _addLog(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    final next = [
      ..._logs,
      '${DateTime.now().toIso8601String().substring(11, 19)} $trimmed',
    ];
    _logs = next.length > 50 ? next.sublist(next.length - 50) : next;
    _emit();
  }

  /// 连接（幂等：已连接直接返回）
  Future<void> connect({bool interactiveAuth = false}) async {
    if (_disposed) return;
    if (_status == McpServerStatus.connected) return;
    _status = McpServerStatus.connecting;
    _error = '';
    _pendingAuthUrl = '';
    _emit();
    _addLog('正在连接 ${config.endpointLabel}');
    try {
      await _connectOnce(interactiveAuth: interactiveAuth);
      _status = McpServerStatus.connected;
      _connectedAt = DateTime.now();
      _error = '';
      _pendingAuthUrl = '';
      _emit();
      _addLog('连接成功：${_tools.length} 个工具，${_resources.length} 个资源，'
          '${_prompts.length} 个提示词');
    } on McpAuthRequiredException catch (e) {
      _pendingAuthUrl = e.authUrl;
      _status = McpServerStatus.authRequired;
      _error = e.message;
      _emit();
      _addLog(e.message);
      await _closeTransportOnly();
    } catch (e) {
      _status = McpServerStatus.error;
      _error = _friendlyError(e);
      _emit();
      _addLog('连接失败：$_error');
      await _closeTransportOnly();
    }
  }

  Future<void> _connectOnce({required bool interactiveAuth}) async {
    McpOAuthProvider? oauth;
    if (config.oauth && config.transport == McpTransportKind.streamableHttp) {
      oauth = McpOAuthProvider(
        config: config,
        interactive: interactiveAuth,
        onAuthorizationUrl: (url) {
          _pendingAuthUrl = url.toString();
          _emit();
          onAuthUrl?.call(url.toString());
        },
      );
      await oauth.init();
      _oauthProvider = oauth;
    }

    final transport = await _createTransport(oauth);
    _transport = transport;
    final client = McpClient(
      const Implementation(name: 'AI Terminal', version: '1.4.0'),
      // legacy initialize profile：兼容 2025-11-25 / 2025-06-18 / 2025-03-26 /
      // 2024-11-05 等绝大多数 server，并使用全局 list_changed 通知；
      // 2026 stateless 的 subscriptions/listen 暂未接入。
      options: const McpClientOptions(protocol: McpProtocol.legacy),
    );
    _client = client;

    _connectTimer = Timer(Duration(milliseconds: config.timeoutMs), () {
      // 连接阶段没有可取消的 public handle；到点后关闭 transport 让 future 结束
      unawaited(_closeTransportOnly());
    });

    try {
      await client.connect(transport).timeout(
            Duration(milliseconds: config.timeoutMs),
          );
    } on UnauthorizedError {
      if (oauth != null && interactiveAuth) {
        final callback = await oauth.waitForCallback();
        if (callback.error != null) {
          throw McpAuthRequiredException(
            'OAuth 授权失败：${callback.error}'
            '${callback.errorDescription == null ? '' : '（${callback.errorDescription}）'}',
          );
        }
        if (transport is! StreamableHttpClientTransport) {
          throw const McpAuthRequiredException('当前传输方式不支持 OAuth');
        }
        await transport.finishAuthRedirect(
          callback.code,
          state: callback.state,
        );
        await _closeTransportOnly();
        await _connectOnce(interactiveAuth: false);
        return;
      }
      throw McpAuthRequiredException(
        oauth == null
            ? '服务器要求 OAuth 授权，请编辑服务器并开启 OAuth 后重试'
            : '需要 OAuth 授权',
        authUrl: oauth?.pendingAuthUrl ?? '',
      );
    } finally {
      _connectTimer?.cancel();
      _connectTimer = null;
    }

    _listen(client, transport);
    await _refreshAll();
  }

  Future<Transport> _createTransport(McpOAuthProvider? oauth) async {
    switch (config.transport) {
      case McpTransportKind.streamableHttp:
        final uri = _parseHttpUri(config.url);
        final options = StreamableHttpClientTransportOptions(
          requestInit:
              config.headers.isEmpty ? null : {'headers': config.headers},
          authProvider: oauth,
        );
        final proxy = config.proxy.trim();
        if (proxy.isEmpty) {
          return StreamableHttpClientTransport(uri, opts: options);
        }
        // mcp_dart 的 Streamable HTTP transport 内部创建 http.Client，
        // 只能在构造时用 HttpOverrides 注入代理。
        return HttpOverrides.runZoned(
          () => StreamableHttpClientTransport(uri, opts: options),
          createHttpClient: (_) => _createProxiedHttpClient(
            proxy,
            Duration(milliseconds: config.timeoutMs),
          ),
        );
      case McpTransportKind.sse:
        final uri = _parseHttpUri(config.url);
        if (config.oauth) {
          throw const McpAuthRequiredException(
            '旧版 HTTP+SSE 传输不支持 OAuth，请在 headers 中配置 Authorization',
          );
        }
        // ignore: deprecated_member_use
        return SseClientTransport(
          uri,
          // ignore: deprecated_member_use
          opts: SseClientTransportOptions(headers: config.headers),
        );
      case McpTransportKind.stdio:
        if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
          throw UnsupportedError('stdio MCP 仅支持桌面端');
        }
        if (oauth != null) {
          throw const McpAuthRequiredException('stdio MCP 不支持 OAuth');
        }
        final command = _resolveStdioCommand(config.command);
        if (command.isEmpty) {
          throw ArgumentError('stdio MCP 未配置启动命令');
        }
        final params = StdioServerParameters(
          command: command,
          args: config.args,
          environment: config.env.isEmpty ? null : config.env,
          includeParentEnvironment: true,
          workingDirectory: config.workingDirectory.trim().isEmpty
              ? null
              : config.workingDirectory.trim(),
          stderrMode: ProcessStartMode.normal,
        );
        final stdio = StdioClientTransport(params);
        final stderr = stdio.stderr;
        if (stderr != null) {
          _stderrSub = stderr.listen((bytes) {
            final text = utf8.decode(bytes, allowMalformed: true).trim();
            if (text.isNotEmpty) _addLog('[stderr] $text');
          });
        }
        return stdio;
    }
  }

  Uri _parseHttpUri(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw ArgumentError('MCP URL 无效：$raw');
    }
    return uri;
  }

  String _resolveStdioCommand(String raw) {
    var command = raw.trim();
    if (Platform.isWindows &&
        RegExp(r'^(npx|pnpm|yarn|uvx)$').hasMatch(command)) {
      command = '$command.cmd';
    }
    return command;
  }

  HttpClient _createProxiedHttpClient(String proxy, Duration timeout) {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    final hostPort = _parseProxyHostPort(proxy);
    if (hostPort != null) {
      client.findProxy = (_) => 'PROXY $hostPort';
    }
    return client;
  }

  String? _parseProxyHostPort(String raw) {
    final withScheme = raw.contains('://') ? raw : 'http://$raw';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http') return null;
    if (uri.userInfo.isNotEmpty) return null;
    return '${uri.host}:${uri.hasPort ? uri.port : 80}';
  }

  void _listen(McpClient client, Transport transport) {
    client.setNotificationHandler<JsonRpcToolListChangedNotification>(
      Method.notificationsToolsListChanged,
      (notification) async => _scheduleRefresh(),
      (params, meta) => JsonRpcToolListChangedNotification(meta: meta),
    );
    client.setNotificationHandler<JsonRpcResourceListChangedNotification>(
      Method.notificationsResourcesListChanged,
      (notification) async => _scheduleRefresh(),
      (params, meta) => JsonRpcResourceListChangedNotification(meta: meta),
    );
    client.setNotificationHandler<JsonRpcPromptListChangedNotification>(
      Method.notificationsPromptsListChanged,
      (notification) async => _scheduleRefresh(),
      (params, meta) => JsonRpcPromptListChangedNotification(meta: meta),
    );
    transport.onclose = () {
      if (_disposed || _status != McpServerStatus.connected) return;
      _status = McpServerStatus.disconnected;
      _error = '连接已关闭';
      _emit();
    };
    transport.onerror = (error) {
      _addLog('传输错误：$error');
    };
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_refreshAll());
    });
  }

  Future<void> _refreshAll() async {
    final client = _client;
    if (client == null || _refreshing || _disposed) return;
    _refreshing = true;
    try {
      final caps = client.getServerCapabilities();
      var tools = _tools;
      var resources = _resources;
      var prompts = _prompts;

      if (caps?.tools != null) {
        try {
          tools = await _listTools(client);
        } catch (e) {
          _addLog('工具发现失败：${_friendlyError(e)}');
        }
      } else {
        tools = const [];
      }

      if (caps?.resources != null) {
        try {
          final direct = await _listResources(client);
          final templates = await _listResourceTemplates(client);
          resources = [...direct, ...templates];
        } catch (e) {
          _addLog('资源发现失败：${_friendlyError(e)}');
        }
      } else {
        resources = const [];
      }

      if (caps?.prompts != null) {
        try {
          prompts = await _listPrompts(client);
        } catch (e) {
          _addLog('提示词发现失败：${_friendlyError(e)}');
        }
      } else {
        prompts = const [];
      }

      _tools = tools;
      _resources = resources;
      _prompts = prompts;
      _error = '';
      _emit();
    } on UnauthorizedError {
      _status = McpServerStatus.authRequired;
      _error = 'OAuth 授权已过期，请重新登录';
      _emit();
    } catch (e) {
      _addLog('刷新能力失败：${_friendlyError(e)}');
    } finally {
      _refreshing = false;
    }
  }

  Future<List<McpToolDescriptor>> _listTools(McpClient client) async {
    final out = <McpToolDescriptor>[];
    String? cursor;
    for (var page = 0; page < 10; page++) {
      final result = await client.listTools(
        params: cursor == null ? null : ListToolsRequest(cursor: cursor),
        options: _requestOptions(),
      );
      out.addAll(result.tools.map(_mapTool));
      cursor = result.nextCursor;
      if (cursor == null || cursor.isEmpty) break;
    }
    return out;
  }

  Future<List<McpResourceDescriptor>> _listResources(McpClient client) async {
    final out = <McpResourceDescriptor>[];
    String? cursor;
    for (var page = 0; page < 10; page++) {
      final result = await client.listResources(
        params: cursor == null ? null : ListResourcesRequest(cursor: cursor),
        options: _requestOptions(),
      );
      out.addAll(result.resources.map((r) => McpResourceDescriptor(
            uri: r.uri,
            name: r.name,
            title: r.title ?? r.name,
            description: r.description ?? '',
            mimeType: r.mimeType ?? '',
          )));
      cursor = result.nextCursor;
      if (cursor == null || cursor.isEmpty) break;
    }
    return out;
  }

  Future<List<McpResourceDescriptor>> _listResourceTemplates(
    McpClient client,
  ) async {
    final out = <McpResourceDescriptor>[];
    String? cursor;
    for (var page = 0; page < 10; page++) {
      final result = await client.listResourceTemplates(
        params: cursor == null
            ? null
            : ListResourceTemplatesRequest(cursor: cursor),
        options: _requestOptions(),
      );
      out.addAll(result.resourceTemplates.map((r) => McpResourceDescriptor(
            uri: r.uriTemplate,
            name: r.name,
            title: r.title ?? r.name,
            description: r.description ?? '',
            mimeType: r.mimeType ?? '',
            isTemplate: true,
          )));
      cursor = result.nextCursor;
      if (cursor == null || cursor.isEmpty) break;
    }
    return out;
  }

  Future<List<McpPromptDescriptor>> _listPrompts(McpClient client) async {
    final out = <McpPromptDescriptor>[];
    String? cursor;
    for (var page = 0; page < 10; page++) {
      final result = await client.listPrompts(
        params: cursor == null ? null : ListPromptsRequest(cursor: cursor),
        options: _requestOptions(),
      );
      out.addAll(result.prompts.map((p) => McpPromptDescriptor(
            name: p.name,
            title: p.title ?? p.name,
            description: p.description ?? '',
            arguments: (p.arguments ?? [])
                .map((a) => McpPromptArgumentDescriptor(
                      name: a.name,
                      description: a.description ?? '',
                      required: a.required == true,
                    ))
                .toList(),
          )));
      cursor = result.nextCursor;
      if (cursor == null || cursor.isEmpty) break;
    }
    return out;
  }

  McpToolDescriptor _mapTool(Tool tool) {
    final annotations = tool.annotations;
    final schema = tool.inputSchema.toJson();
    return McpToolDescriptor(
      name: tool.name,
      title: tool.title ?? tool.name,
      description: tool.description ?? '',
      inputSchema: Map<String, dynamic>.from(schema),
      readOnly: annotations?.readOnlyHint ?? false,
      // MCP 规范默认 destructiveHint = true；缺省按最保守处理
      destructive: annotations?.destructiveHint ?? true,
      idempotent: annotations?.idempotentHint ?? false,
      openWorld: annotations?.openWorldHint ?? true,
    );
  }

  RequestOptions _requestOptions() => RequestOptions(
        timeout: Duration(milliseconds: config.timeoutMs),
      );

  Future<McpCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final client = _client;
    if (client == null) {
      return const McpCallResult(isError: true, text: 'MCP 服务器未连接');
    }
    try {
      final result = await client.callTool(
        CallToolRequest(name: toolName, arguments: arguments),
        options: _requestOptions(),
      );
      return McpCallResult(
        isError: result.isError,
        text: _callResultText(result),
      );
    } on UnauthorizedError {
      _status = McpServerStatus.authRequired;
      _error = 'OAuth 授权已过期，请重新登录';
      _emit();
      throw const McpAuthRequiredException('OAuth 授权已过期，请重新登录');
    } catch (e) {
      return McpCallResult(
        isError: true,
        text: 'MCP 调用失败：${_friendlyError(e)}',
      );
    }
  }

  String _callResultText(CallToolResult result) {
    final buffer = StringBuffer();
    for (final content in result.content) {
      final text = _contentText(content);
      if (text.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.write(text);
    }
    if (buffer.isEmpty && result.hasStructuredContent) {
      buffer.write(encodeMcpJson(result.structuredContentJson?.toJson()));
    }
    if (buffer.isEmpty) return '（MCP 工具返回空结果）';
    return _cap(buffer.toString(), 20000);
  }

  String _contentText(Content content) {
    if (content is TextContent) return content.text;
    if (content is ImageContent) {
      return '[图片 ${content.mimeType}，${content.data.length} base64 字符]';
    }
    if (content is AudioContent) {
      return '[音频 ${content.mimeType}，${content.data.length} base64 字符]';
    }
    if (content is EmbeddedResource) {
      final resource = content.resource;
      if (resource is TextResourceContents) {
        return '[资源 ${resource.uri}]\n${resource.text}';
      }
      if (resource is BlobResourceContents) {
        return '[二进制资源 ${resource.uri}，${resource.blob.length} base64 字符]';
      }
      return '[资源 ${resource.uri}]';
    }
    if (content is ResourceLink) {
      return '[资源链接] ${content.name}: ${content.uri}';
    }
    return '';
  }

  Future<String> readResource(String uri) async {
    final client = _client;
    if (client == null) return 'MCP 服务器未连接';
    try {
      final result = await client.readResource(
        ReadResourceRequest(uri: uri),
        _requestOptions(),
      );
      final buffer = StringBuffer();
      for (final content in result.contents) {
        if (content is TextResourceContents) {
          buffer.writeln('[${content.uri}]');
          buffer.writeln(content.text);
        } else if (content is BlobResourceContents) {
          buffer.writeln(
            '[二进制资源 ${content.uri}，${content.blob.length} base64 字符]',
          );
        } else {
          buffer.writeln('[资源 ${content.uri}]');
        }
      }
      return _cap(buffer.toString().trimRight(), 20000);
    } on UnauthorizedError {
      throw const McpAuthRequiredException('OAuth 授权已过期，请重新登录');
    } catch (e) {
      return '读取资源失败：${_friendlyError(e)}';
    }
  }

  Future<String> getPrompt(
    String name, {
    Map<String, String> arguments = const {},
  }) async {
    final client = _client;
    if (client == null) return 'MCP 服务器未连接';
    try {
      final result = await client.getPrompt(
        GetPromptRequest(name: name, arguments: arguments),
        _requestOptions(),
      );
      final buffer = StringBuffer();
      if (result.description != null && result.description!.isNotEmpty) {
        buffer.writeln(result.description);
        buffer.writeln();
      }
      for (final message in result.messages) {
        buffer.writeln('[${message.role.name}]');
        final text = _contentText(message.content);
        if (text.isNotEmpty) buffer.writeln(text);
        buffer.writeln();
      }
      return _cap(buffer.toString().trimRight(), 20000);
    } on UnauthorizedError {
      throw const McpAuthRequiredException('OAuth 授权已过期，请重新登录');
    } catch (e) {
      return '获取提示词失败：${_friendlyError(e)}';
    }
  }

  Future<void> disconnect() async {
    if (_status == McpServerStatus.connected) {
      _addLog('断开连接');
    }
    await _closeTransportOnly();
    _status = McpServerStatus.disconnected;
    _error = '';
    _pendingAuthUrl = '';
    _connectedAt = null;
    _disposed = true;
    _emit();
  }

  Future<void> _closeTransportOnly() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.close();
      } catch (e) {
        debugPrint('[McpConnection] 关闭 client 失败: $e');
      }
    }
    final transport = _transport;
    _transport = null;
    if (transport != null) {
      try {
        await transport.close();
      } catch (e) {
        debugPrint('[McpConnection] 关闭 transport 失败: $e');
      }
    }
    final oauth = _oauthProvider;
    _oauthProvider = null;
    await oauth?.dispose();
  }

  String _friendlyError(Object error) {
    if (error is McpAuthRequiredException) return error.message;
    if (error is TimeoutException) return '连接/调用超时';
    if (error is UnauthorizedError) return '需要 OAuth 授权';
    if (error is SocketException) return '网络错误：${error.message}';
    if (error is McpError) return error.message;
    if (error is ArgumentError) return error.message.toString();
    return error.toString();
  }

  String _cap(String input, int max) {
    if (input.length <= max) return input;
    return '${input.substring(0, max)}\n...(已截断，共 ${input.length} 字符)';
  }
}
