import 'dart:convert';

/// MCP 传输方式
enum McpTransportKind {
  streamableHttp,
  sse,
  stdio;

  static McpTransportKind fromString(String? value) {
    switch (value) {
      case 'sse':
        return McpTransportKind.sse;
      case 'stdio':
        return McpTransportKind.stdio;
      case 'streamableHttp':
      case 'streamable_http':
      default:
        return McpTransportKind.streamableHttp;
    }
  }

  String get label {
    switch (this) {
      case McpTransportKind.streamableHttp:
        return 'Streamable HTTP';
      case McpTransportKind.sse:
        return 'HTTP + SSE（旧版）';
      case McpTransportKind.stdio:
        return 'stdio（本地进程）';
    }
  }
}

/// 工具暴露策略
enum McpToolExposure {
  readOnly,
  all,
  custom;

  static McpToolExposure fromString(String? value) {
    switch (value) {
      case 'all':
        return McpToolExposure.all;
      case 'custom':
        return McpToolExposure.custom;
      case 'readOnly':
      case 'read_only':
      default:
        return McpToolExposure.readOnly;
    }
  }
}

/// MCP 服务器配置（非敏感部分）
class McpServerConfig {
  final String id;
  final String name;
  final bool enabled;
  final bool autoConnect;
  final McpTransportKind transport;
  final String url;
  final String command;
  final List<String> args;
  final String workingDirectory;
  final Map<String, String> headers;
  final Map<String, String> env;
  final int timeoutMs;
  final String proxy;
  final bool oauth;
  final List<String> oauthScopes;
  final String oauthClientId;
  final String oauthClientSecret;
  final McpToolExposure toolExposure;
  final List<String> allowedTools;
  final int maxTools;
  final bool exposeResources;
  final bool exposePrompts;

  const McpServerConfig({
    required this.id,
    required this.name,
    this.enabled = false,
    this.autoConnect = false,
    this.transport = McpTransportKind.streamableHttp,
    this.url = '',
    this.command = '',
    this.args = const [],
    this.workingDirectory = '',
    this.headers = const {},
    this.env = const {},
    this.timeoutMs = 30000,
    this.proxy = '',
    this.oauth = false,
    this.oauthScopes = const [],
    this.oauthClientId = '',
    this.oauthClientSecret = '',
    this.toolExposure = McpToolExposure.readOnly,
    this.allowedTools = const [],
    this.maxTools = 20,
    this.exposeResources = true,
    this.exposePrompts = true,
  });

  String get endpointLabel {
    switch (transport) {
      case McpTransportKind.stdio:
        return [command, ...args].where((s) => s.isNotEmpty).join(' ');
      case McpTransportKind.streamableHttp:
      case McpTransportKind.sse:
        return url;
    }
  }

  McpServerConfig copyWith({
    String? id,
    String? name,
    bool? enabled,
    bool? autoConnect,
    McpTransportKind? transport,
    String? url,
    String? command,
    List<String>? args,
    String? workingDirectory,
    Map<String, String>? headers,
    Map<String, String>? env,
    int? timeoutMs,
    String? proxy,
    bool? oauth,
    List<String>? oauthScopes,
    String? oauthClientId,
    String? oauthClientSecret,
    McpToolExposure? toolExposure,
    List<String>? allowedTools,
    int? maxTools,
    bool? exposeResources,
    bool? exposePrompts,
  }) {
    return McpServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      autoConnect: autoConnect ?? this.autoConnect,
      transport: transport ?? this.transport,
      url: url ?? this.url,
      command: command ?? this.command,
      args: args ?? this.args,
      workingDirectory: workingDirectory ?? this.workingDirectory,
      headers: headers ?? this.headers,
      env: env ?? this.env,
      timeoutMs: timeoutMs ?? this.timeoutMs,
      proxy: proxy ?? this.proxy,
      oauth: oauth ?? this.oauth,
      oauthScopes: oauthScopes ?? this.oauthScopes,
      oauthClientId: oauthClientId ?? this.oauthClientId,
      oauthClientSecret: oauthClientSecret ?? this.oauthClientSecret,
      toolExposure: toolExposure ?? this.toolExposure,
      allowedTools: allowedTools ?? this.allowedTools,
      maxTools: maxTools ?? this.maxTools,
      exposeResources: exposeResources ?? this.exposeResources,
      exposePrompts: exposePrompts ?? this.exposePrompts,
    );
  }

  /// 不含 headers/env/clientSecret；敏感值由 McpStore 单独存取
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'autoConnect': autoConnect,
        'transport': transport.name,
        'url': url,
        'command': command,
        'args': args,
        'workingDirectory': workingDirectory,
        'timeoutMs': timeoutMs,
        'proxy': proxy,
        'oauth': oauth,
        'oauthScopes': oauthScopes,
        'oauthClientId': oauthClientId,
        'toolExposure': toolExposure.name,
        'allowedTools': allowedTools,
        'maxTools': maxTools,
        'exposeResources': exposeResources,
        'exposePrompts': exposePrompts,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    return McpServerConfig(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'MCP Server',
      enabled: json['enabled'] == true,
      autoConnect: json['autoConnect'] == true,
      transport: McpTransportKind.fromString(json['transport']?.toString()),
      url: json['url']?.toString() ?? '',
      command: json['command']?.toString() ?? '',
      args: _stringList(json['args']),
      workingDirectory: json['workingDirectory']?.toString() ?? '',
      timeoutMs: _intValue(json['timeoutMs'], 30000).clamp(3000, 120000),
      proxy: json['proxy']?.toString() ?? '',
      oauth: json['oauth'] == true,
      oauthScopes: _stringList(json['oauthScopes']),
      oauthClientId: json['oauthClientId']?.toString() ?? '',
      toolExposure:
          McpToolExposure.fromString(json['toolExposure']?.toString()),
      allowedTools: _stringList(json['allowedTools']),
      maxTools: _intValue(json['maxTools'], 20).clamp(1, 40),
      exposeResources: json['exposeResources'] != false,
      exposePrompts: json['exposePrompts'] != false,
    );
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is List) {
      return raw.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    }
    return const [];
  }

  static int _intValue(dynamic raw, int fallback) {
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '') ?? fallback;
  }

  static McpServerConfig presetExa() => const McpServerConfig(
        id: 'exa',
        name: 'Exa',
        transport: McpTransportKind.streamableHttp,
        url: 'https://mcp.exa.ai/mcp',
        enabled: true,
        autoConnect: true,
        toolExposure: McpToolExposure.readOnly,
      );

  static McpServerConfig presetParallel() => const McpServerConfig(
        id: 'parallel',
        name: 'Parallel',
        transport: McpTransportKind.streamableHttp,
        url: 'https://search.parallel.ai/mcp',
        enabled: true,
        autoConnect: true,
        toolExposure: McpToolExposure.readOnly,
      );
}

/// 服务器连接状态
enum McpServerStatus {
  disabled,
  disconnected,
  connecting,
  connected,
  authRequired,
  error;

  String get label {
    switch (this) {
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
}

/// 工具描述（不依赖 mcp_dart，便于 UI/测试）
class McpToolDescriptor {
  final String name;
  final String title;
  final String description;
  final Map<String, dynamic> inputSchema;
  final bool readOnly;
  final bool destructive;
  final bool idempotent;
  final bool openWorld;

  const McpToolDescriptor({
    required this.name,
    required this.title,
    required this.description,
    required this.inputSchema,
    required this.readOnly,
    required this.destructive,
    required this.idempotent,
    required this.openWorld,
  });
}

class McpResourceDescriptor {
  final String uri;
  final String name;
  final String title;
  final String description;
  final String mimeType;
  final bool isTemplate;

  const McpResourceDescriptor({
    required this.uri,
    required this.name,
    required this.title,
    required this.description,
    required this.mimeType,
    this.isTemplate = false,
  });
}

class McpPromptArgumentDescriptor {
  final String name;
  final String description;
  final bool required;

  const McpPromptArgumentDescriptor({
    required this.name,
    required this.description,
    required this.required,
  });
}

class McpPromptDescriptor {
  final String name;
  final String title;
  final String description;
  final List<McpPromptArgumentDescriptor> arguments;

  const McpPromptDescriptor({
    required this.name,
    required this.title,
    required this.description,
    required this.arguments,
  });
}

/// MCP 调用结果（已转成文本）
class McpCallResult {
  final bool isError;
  final String text;

  const McpCallResult({required this.isError, required this.text});
}

/// 服务器运行时状态
class McpServerRuntime {
  final McpServerConfig config;
  final McpServerStatus status;
  final String error;
  final String pendingAuthUrl;
  final List<McpToolDescriptor> tools;
  final List<McpResourceDescriptor> resources;
  final List<McpPromptDescriptor> prompts;
  final List<String> logs;
  final DateTime? connectedAt;

  const McpServerRuntime({
    required this.config,
    this.status = McpServerStatus.disconnected,
    this.error = '',
    this.pendingAuthUrl = '',
    this.tools = const [],
    this.resources = const [],
    this.prompts = const [],
    this.logs = const [],
    this.connectedAt,
  });

  bool get isConnected => status == McpServerStatus.connected;

  McpServerRuntime copyWith({
    McpServerConfig? config,
    McpServerStatus? status,
    String? error,
    String? pendingAuthUrl,
    List<McpToolDescriptor>? tools,
    List<McpResourceDescriptor>? resources,
    List<McpPromptDescriptor>? prompts,
    List<String>? logs,
    DateTime? connectedAt,
    bool clearConnectedAt = false,
  }) {
    return McpServerRuntime(
      config: config ?? this.config,
      status: status ?? this.status,
      error: error ?? this.error,
      pendingAuthUrl: pendingAuthUrl ?? this.pendingAuthUrl,
      tools: tools ?? this.tools,
      resources: resources ?? this.resources,
      prompts: prompts ?? this.prompts,
      logs: logs ?? this.logs,
      connectedAt: clearConnectedAt ? null : (connectedAt ?? this.connectedAt),
    );
  }
}

class McpOAuthCallback {
  final String code;
  final String state;
  final String? error;
  final String? errorDescription;

  const McpOAuthCallback({
    required this.code,
    required this.state,
    this.error,
    this.errorDescription,
  });
}

/// 需要用户完成 OAuth 授权
class McpAuthRequiredException implements Exception {
  final String message;
  final String authUrl;

  const McpAuthRequiredException(this.message, {this.authUrl = ''});

  @override
  String toString() => message;
}

class McpOAuthTokenData {
  final String accessToken;
  final String? refreshToken;
  final int? expiresAtMs;
  final String? issuer;
  final String? resource;

  const McpOAuthTokenData({
    required this.accessToken,
    this.refreshToken,
    this.expiresAtMs,
    this.issuer,
    this.resource,
  });

  bool get isExpired =>
      expiresAtMs != null && DateTime.now().millisecondsSinceEpoch >= expiresAtMs!;

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        if (refreshToken != null) 'refreshToken': refreshToken,
        if (expiresAtMs != null) 'expiresAtMs': expiresAtMs,
        if (issuer != null) 'issuer': issuer,
        if (resource != null) 'resource': resource,
      };

  factory McpOAuthTokenData.fromJson(Map<String, dynamic> json) {
    return McpOAuthTokenData(
      accessToken: json['accessToken']?.toString() ?? '',
      refreshToken: json['refreshToken']?.toString(),
      expiresAtMs: json['expiresAtMs'] is int
          ? json['expiresAtMs'] as int
          : int.tryParse(json['expiresAtMs']?.toString() ?? ''),
      issuer: json['issuer']?.toString(),
      resource: json['resource']?.toString(),
    );
  }
}

/// 把 MCP 名称清洗为 OpenAI function name 允许的形状
String mcpSlug(String value, {int maxLength = 40}) {
  final normalized = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final slug = normalized.isEmpty ? 'server' : normalized;
  return slug.length <= maxLength ? slug : slug.substring(0, maxLength);
}

String mcpToolFullName(String serverId, String toolName) {
  final server = mcpSlug(serverId, maxLength: 20);
  final tool = mcpSlug(toolName, maxLength: 36);
  var full = 'mcp__${server}__$tool';
  if (full.length > 64) {
    full = full.substring(0, 64);
  }
  return full;
}

String encodeMcpJson(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}
