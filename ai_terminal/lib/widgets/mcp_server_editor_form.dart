import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../services/mcp_models.dart';
import 'inline_form.dart';

/// 新建 MCP 服务器时用的 id
String newMcpServerId() => 'mcpx_${const Uuid().v4().substring(0, 8)}';

/// MCP 服务器编辑器（抽屉内联版）。
///
/// 传输方式决定字段组：stdio 要命令/参数/环境变量，HTTP 要 URL/代理/headers。
/// 全部字段都在这块里，保存后由调用方写回 [McpManager]。
class McpServerEditorForm extends StatefulWidget {
  const McpServerEditorForm({
    super.key,
    this.initial,
    required this.onSave,
    required this.onCancel,
  });

  final McpServerConfig? initial;
  final ValueChanged<McpServerConfig> onSave;
  final VoidCallback onCancel;

  @override
  State<McpServerEditorForm> createState() => _McpServerEditorFormState();
}

class _McpServerEditorFormState extends State<McpServerEditorForm> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _command;
  late final TextEditingController _args;
  late final TextEditingController _workdir;
  late final TextEditingController _headers;
  late final TextEditingController _env;
  late final TextEditingController _timeout;
  late final TextEditingController _maxTools;
  late final TextEditingController _proxy;
  late final TextEditingController _scopes;
  late final TextEditingController _clientId;
  late final TextEditingController _clientSecret;
  late McpTransportKind _transport;
  late McpToolExposure _exposure;
  late bool _enabled;
  late bool _autoConnect;
  late bool _oauth;
  late bool _exposeResources;
  late bool _exposePrompts;
  String? _error;

  McpServerConfig get _base =>
      widget.initial ??
      McpServerConfig(
        id: newMcpServerId(),
        name: UiText.t('新 MCP 服务器', 'New MCP server'),
        enabled: true,
        autoConnect: true,
      );

  bool get _isNew => widget.initial == null;

  @override
  void initState() {
    super.initState();
    final c = _base;
    _name = TextEditingController(text: c.name);
    _url = TextEditingController(text: c.url);
    _command = TextEditingController(text: c.command);
    _args = TextEditingController(text: c.args.join('\n'));
    _workdir = TextEditingController(text: c.workingDirectory);
    _headers = TextEditingController(
        text: c.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n'));
    _env = TextEditingController(
        text: c.env.entries.map((e) => '${e.key}=${e.value}').join('\n'));
    _timeout = TextEditingController(text: '${c.timeoutMs}');
    _maxTools = TextEditingController(text: '${c.maxTools}');
    _proxy = TextEditingController(text: c.proxy);
    _scopes = TextEditingController(text: c.oauthScopes.join(' '));
    _clientId = TextEditingController(text: c.oauthClientId);
    _clientSecret = TextEditingController(text: c.oauthClientSecret);
    _transport = c.transport;
    _exposure = c.toolExposure;
    _enabled = c.enabled;
    _autoConnect = c.autoConnect;
    _oauth = c.oauth;
    _exposeResources = c.exposeResources;
    _exposePrompts = c.exposePrompts;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _url,
      _command,
      _args,
      _workdir,
      _headers,
      _env,
      _timeout,
      _maxTools,
      _proxy,
      _scopes,
      _clientId,
      _clientSecret,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = UiText.t('名称不能为空', 'Name is required'));
      return;
    }
    if (_transport == McpTransportKind.stdio) {
      if (_command.text.trim().isEmpty) {
        setState(() => _error = UiText.t(
            'stdio 传输需要启动命令', 'stdio transport requires a start command'));
        return;
      }
    } else {
      final uri = Uri.tryParse(_url.text.trim());
      if (uri == null ||
          !uri.hasScheme ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        setState(() => _error = UiText.t(
            '服务器 URL 必须是 http(s) 地址',
            'Server URL must be an http(s) address'));
        return;
      }
    }
    final timeout = int.tryParse(_timeout.text.trim());
    if (timeout == null || timeout < 3000 || timeout > 120000) {
      setState(() => _error = UiText.t(
          '超时需在 3000-120000ms 之间',
          'Timeout must be between 3000 and 120000 ms'));
      return;
    }
    final maxTools = int.tryParse(_maxTools.text.trim());
    if (maxTools == null || maxTools < 1 || maxTools > 40) {
      setState(() => _error = UiText.t(
          '工具上限需在 1-40 之间', 'Tool limit must be between 1 and 40'));
      return;
    }
    final proxyRaw = _proxy.text.trim();
    final proxy = _normalizeProxy(proxyRaw);
    if (proxyRaw.isNotEmpty && proxy == null) {
      setState(() => _error = UiText.t('代理仅支持 http://host:port',
          'Proxy only supports http://host:port'));
      return;
    }

    widget.onSave(_base.copyWith(
      name: name,
      enabled: _enabled,
      autoConnect: _autoConnect,
      transport: _transport,
      url: _url.text.trim(),
      command: _command.text.trim(),
      args: _parseArgs(_args.text),
      workingDirectory: _workdir.text.trim(),
      headers: _parseHeaders(_headers.text),
      env: _parseEnv(_env.text),
      timeoutMs: timeout,
      proxy: proxy ?? '',
      oauth: _oauth,
      oauthScopes: _parseScopes(_scopes.text),
      oauthClientId: _clientId.text.trim(),
      oauthClientSecret: _clientSecret.text.trim(),
      toolExposure: _exposure,
      maxTools: maxTools,
      exposeResources: _exposeResources,
      exposePrompts: _exposePrompts,
    ));
  }

  String? _normalizeProxy(String raw) {
    if (raw.isEmpty) return '';
    final withScheme = raw.contains('://') ? raw : 'http://$raw';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http') return null;
    if (uri.userInfo.isNotEmpty) return null;
    return withScheme;
  }

  List<String> _parseArgs(String text) => text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  List<String> _parseScopes(String text) => text
      .split(RegExp(r'[\s,]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();

  Map<String, String> _parseHeaders(String text) {
    final out = <String, String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      var index = line.indexOf(':');
      if (index < 0) index = line.indexOf('=');
      if (index <= 0) continue;
      final key = line.substring(0, index).trim();
      final value = line.substring(index + 1).trim();
      if (key.isNotEmpty) out[key] = value;
    }
    return out;
  }

  Map<String, String> _parseEnv(String text) {
    final out = <String, String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final index = line.indexOf('=');
      if (index <= 0) continue;
      final key = line.substring(0, index).trim();
      final value = line.substring(index + 1).trim();
      if (key.isNotEmpty) out[key] = value;
    }
    return out;
  }

  String _transportLabel(McpTransportKind kind) {
    switch (kind) {
      case McpTransportKind.streamableHttp:
        return 'Streamable HTTP';
      case McpTransportKind.sse:
        return UiText.t('HTTP + SSE（旧版）', 'HTTP + SSE (legacy)');
      case McpTransportKind.stdio:
        return UiText.t('stdio（本地进程）', 'stdio (local process)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final stdio = _transport == McpTransportKind.stdio;
    return InlineSheet(
      title: _isNew
          ? UiText.t('添加 MCP 服务器', 'Add MCP server')
          : UiText.t('编辑 MCP 服务器', 'Edit MCP server'),
      onBack: widget.onCancel,
      error: _error,
      actions: [
        InlineButton(
            label: UiText.t('取消', 'Cancel'), onTap: widget.onCancel),
        InlineButton(
          label: _enabled
              ? UiText.t('保存并连接', 'Save & connect')
              : UiText.t('保存', 'Save'),
          primary: true,
          onTap: _save,
        ),
      ],
      children: [
        InlineField(label: UiText.t('名称', 'Name'), controller: _name),
        const SizedBox(height: 10),
        InlineSelect<McpTransportKind>(
          label: UiText.t('传输方式', 'Transport'),
          value: _transport,
          items: [
            for (final t in McpTransportKind.values)
              (t, _transportLabel(t)),
          ],
          onChanged: (v) => setState(() => _transport = v),
        ),
        const SizedBox(height: 10),
        if (stdio) ...[
          InlineField(
            label: UiText.t('启动命令', 'Start command'),
            controller: _command,
            mono: true,
            hint: 'npx',
          ),
          const SizedBox(height: 10),
          InlineField(
            label: UiText.t('参数（每行一个）', 'Arguments (one per line)'),
            controller: _args,
            mono: true,
            maxLines: 4,
            hint: '-y\n@modelcontextprotocol/server-filesystem\nD:\\data',
          ),
          const SizedBox(height: 10),
          InlineField(
            label: UiText.t('工作目录（可选）', 'Working directory'),
            controller: _workdir,
            mono: true,
          ),
          const SizedBox(height: 10),
          InlineField(
            label: UiText.t('环境变量（每行 KEY=VALUE）',
                'Environment (KEY=VALUE per line)'),
            controller: _env,
            mono: true,
            maxLines: 3,
          ),
          const SizedBox(height: 6),
          Text(
            UiText.t(
              '需要本机安装 Node.js。filesystem 传允许目录，可多个；context7 可无 Key 使用。',
              'Node.js is required. filesystem takes allowed folders (multiple allowed); '
                  'context7 works without a key.',
            ),
            style: TextStyle(fontSize: fMicro, color: tc.textMuted, height: 1.4),
          ),
        ] else ...[
          InlineField(
            label: UiText.t('服务器 URL', 'Server URL'),
            controller: _url,
            mono: true,
            hint: 'https://example.com/mcp',
          ),
          const SizedBox(height: 10),
          InlineField(
            label: UiText.t('出站代理（可选）', 'Outbound proxy'),
            controller: _proxy,
            mono: true,
            hint: 'http://127.0.0.1:7890',
          ),
          const SizedBox(height: 10),
          InlineField(
            label: UiText.t('Headers（每行 Key: Value）', 'Headers'),
            controller: _headers,
            mono: true,
            maxLines: 3,
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: InlineField(
                  label: UiText.t('超时（ms）', 'Timeout (ms)'),
                  controller: _timeout),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InlineField(
                  label: UiText.t('工具上限', 'Tool limit'),
                  controller: _maxTools),
            ),
          ],
        ),
        const SizedBox(height: 10),
        InlineSelect<McpToolExposure>(
          label: UiText.t('Agent 可用工具', 'Tools available to the Agent'),
          value: _exposure,
          items: [
            (McpToolExposure.readOnly,
                UiText.t('只读工具（推荐）', 'Read-only tools (recommended)')),
            (McpToolExposure.all, UiText.t('全部工具', 'All tools')),
            (McpToolExposure.custom,
                UiText.t('自定义（连接后勾选）', 'Custom (pick after connect)')),
          ],
          onChanged: (v) => setState(() => _exposure = v),
        ),
        const SizedBox(height: 8),
        InlineSwitchRow(
          label: UiText.t('启用服务器', 'Enable server'),
          value: _enabled,
          onChanged: (v) => setState(() => _enabled = v),
        ),
        InlineSwitchRow(
          label: UiText.t('应用启动时自动连接', 'Auto-connect on app start'),
          value: _autoConnect,
          onChanged: (v) => setState(() => _autoConnect = v),
        ),
        InlineSwitchRow(
          label: UiText.t('允许 Agent 使用资源', 'Allow the Agent to use resources'),
          value: _exposeResources,
          onChanged: (v) => setState(() => _exposeResources = v),
        ),
        InlineSwitchRow(
          label: UiText.t('允许 Agent 使用提示词', 'Allow the Agent to use prompts'),
          value: _exposePrompts,
          onChanged: (v) => setState(() => _exposePrompts = v),
        ),
        if (_transport == McpTransportKind.streamableHttp) ...[
          const SizedBox(height: 4),
          InlineSwitchRow(
            label: UiText.t('使用 OAuth 授权', 'Use OAuth authorization'),
            value: _oauth,
            onChanged: (v) => setState(() => _oauth = v),
          ),
          if (_oauth) ...[
            const SizedBox(height: 6),
            InlineField(
              label: UiText.t('OAuth scopes（空格/逗号分隔）', 'OAuth scopes'),
              controller: _scopes,
              mono: true,
            ),
            const SizedBox(height: 10),
            InlineField(
              label: UiText.t('OAuth clientId（留空走 DCR）', 'OAuth clientId'),
              controller: _clientId,
              mono: true,
            ),
            const SizedBox(height: 10),
            InlineField(
              label: UiText.t('OAuth clientSecret（可选）', 'OAuth clientSecret'),
              controller: _clientSecret,
              obscure: true,
            ),
          ],
        ],
        const SizedBox(height: 8),
        Text(
          UiText.t(
            'MCP 返回的工具描述属于外部内容，存在注入风险。先用只读策略确认行为；headers/env 存在本机加密凭据库。',
            'Tool descriptions from MCP servers are external content. Start read-only; '
                'headers/env live in the local encrypted credential store.',
          ),
          style: TextStyle(fontSize: fMicro, color: tc.textMuted, height: 1.4),
        ),
      ],
    );
  }
}
