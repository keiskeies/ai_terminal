import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../services/mcp_manager.dart';
import '../services/mcp_models.dart';
import '../core/app_toast.dart';

/// MCP 服务器设置页
class McpSettingsPage extends StatefulWidget {
  const McpSettingsPage({super.key});

  @override
  State<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends State<McpSettingsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(McpManager.instance.init());
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(UiText.t('MCP 服务器', 'MCP Servers')),
        actions: [
          IconButton(
            tooltip: UiText.t('添加服务器', 'Add server'),
            onPressed: _addCustom,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: McpManager.instance,
        builder: (context, _) {
          final manager = McpManager.instance;
          final runtimes = <McpServerRuntime>[
            for (final config in manager.configs)
              manager.runtimeFor(config.id) ??
                  McpServerRuntime(
                    config: config,
                    status: config.enabled
                        ? McpServerStatus.disconnected
                        : McpServerStatus.disabled,
                  ),
          ];
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: ListView(
                padding: const EdgeInsets.all(pStandard),
                children: [
                  _buildSummary(manager, runtimes, tc),
                  const SizedBox(height: 12),
                  _buildQuickAdd(tc),
                  const SizedBox(height: 16),
                  if (runtimes.isEmpty)
                    _buildEmpty(tc)
                  else
                    for (final runtime in runtimes) ...[
                      _buildServerCard(runtime, tc),
                      const SizedBox(height: 12),
                    ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSummary(
    McpManager manager,
    List<McpServerRuntime> runtimes,
    ThemeColors tc,
  ) {
    final connected = runtimes.where((r) => r.isConnected).length;
    final enabled = manager.enabled;
    return Container(
      padding: const EdgeInsets.all(pStandard),
      decoration: BoxDecoration(
        color: tc.card,
        border: Border.all(color: tc.border),
        borderRadius: BorderRadius.circular(rLarge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_outlined, color: tc.brand, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  enabled
                      ? UiText.t(
                          '已连接 $connected/${runtimes.length} 个服务器 · '
                              'Agent 可用 ${manager.exposedToolCount} 个工具',
                          'Connected $connected/${runtimes.length} servers · '
                              '${manager.exposedToolCount} tools available to the Agent',
                        )
                      : UiText.t(
                          'MCP 总开关已关闭 · 已连接 0/${runtimes.length} 个服务器',
                          'MCP master switch is off · 0/${runtimes.length} servers connected',
                        ),
                  style: TextStyle(
                    color: tc.textMain,
                    fontSize: fBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            UiText.t(
              'MCP 工具通过 Function Calling 提供给 Agent；默认只启用 readOnly 工具，'
                  'destructive 工具会走用户确认，只读模式下非只读工具会被拦截。'
                  'stdio 仅桌面端可用。',
              'MCP tools are exposed to the Agent through Function Calling. Only readOnly tools are enabled by default; '
                  'destructive tools require your confirmation, and non-readonly tools are blocked in read-only mode. '
                  'stdio is desktop-only.',
            ),
            style: TextStyle(color: tc.textSub, fontSize: fSmall, height: 1.5),
          ),
          const SizedBox(height: 6),
          Divider(height: 1, color: tc.hairline),
          Row(
            children: [
              Switch(
                value: enabled,
                onChanged: (value) =>
                    unawaited(_setGlobalEnabled(value)),
                activeThumbColor: tc.brand,
                activeTrackColor: tc.brandBg,
                inactiveThumbColor: tc.textMuted,
                inactiveTrackColor: tc.surface,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  UiText.t(
                    '启用 MCP（总开关）。关闭后断开所有服务器，Agent 不再看到 MCP 工具；'
                        '各服务器的启用配置会保留，重新打开后按配置恢复连接。',
                    'Enable MCP (master switch). Turning it off disconnects every server and hides MCP tools from the Agent; '
                        'per-server settings are kept and connections are restored when you turn it back on.',
                  ),
                  style: TextStyle(
                    color: tc.textSub,
                    fontSize: fSmall,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _setGlobalEnabled(bool value) async {
    try {
      await McpManager.instance.setGlobalEnabled(value);
    } catch (e) {
      _snack(UiText.t('切换 MCP 总开关失败：$e', 'Failed to toggle the MCP master switch: $e'), error: true);
    }
  }

  Widget _buildQuickAdd(ThemeColors tc) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(UiText.t('快速添加：', 'Quick add:'), style: TextStyle(color: tc.textSub, fontSize: fSmall)),
        ActionChip(
          label: const Text('Exa MCP'),
          avatar: const Icon(Icons.add_link, size: 15),
          onPressed: () => _addPreset(McpServerConfig.presetExa()),
        ),
        ActionChip(
          label: const Text('Parallel MCP'),
          avatar: const Icon(Icons.add_link, size: 15),
          onPressed: () => _addPreset(McpServerConfig.presetParallel()),
        ),
        ActionChip(
          label: const Text('Filesystem'),
          avatar: const Icon(Icons.folder_outlined, size: 15),
          onPressed: () => unawaited(_addFilesystemPreset()),
        ),
        ActionChip(
          label: const Text('Context7'),
          avatar: const Icon(Icons.menu_book_outlined, size: 15),
          onPressed: () => _addPreset(McpServerConfig.presetContext7()),
        ),
        ActionChip(
          label: Text(UiText.t('自定义', 'Custom')),
          avatar: const Icon(Icons.edit_outlined, size: 15),
          onPressed: _addCustom,
        ),
      ],
    );
  }

  Widget _buildEmpty(ThemeColors tc) {
    return Container(
      padding: const EdgeInsets.all(pXLarge),
      decoration: BoxDecoration(
        color: tc.card,
        border: Border.all(color: tc.border),
        borderRadius: BorderRadius.circular(rLarge),
      ),
      child: Column(
        children: [
          Icon(Icons.extension_outlined, color: tc.textMuted, size: 34),
          const SizedBox(height: 10),
          Text(
            UiText.t('还没有 MCP 服务器', 'No MCP servers yet'),
            style: TextStyle(
              color: tc.textMain,
              fontSize: fTitle,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            UiText.t(
              '添加远程 Streamable HTTP / 旧版 SSE，或本地 stdio 服务器；'
                  '连接后会自动发现 tools / resources / prompts。',
              'Add a remote Streamable HTTP / legacy SSE server, or a local stdio server. '
                  'Tools / resources / prompts are discovered automatically after connecting.',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: tc.textSub, fontSize: fSmall, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildServerCard(McpServerRuntime runtime, ThemeColors tc) {
    final config = runtime.config;
    final statusColor = _statusColor(runtime.status, tc);
    final globalEnabled = McpManager.instance.enabled;
    return Container(
      decoration: BoxDecoration(
        color: tc.card,
        border: Border.all(color: tc.border),
        borderRadius: BorderRadius.circular(rLarge),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(pStandard, pCompact, pStandard, pSmall),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    config.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tc.textMain,
                      fontSize: fBody,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Switch(
                  value: config.enabled,
                  onChanged: (value) =>
                      unawaited(_setEnabled(config.id, value)),
                  activeThumbColor: tc.brand,
                  activeTrackColor: tc.brandBg,
                  inactiveThumbColor: tc.textMuted,
                  inactiveTrackColor: tc.surface,
                ),
                PopupMenuButton<String>(
                  tooltip: UiText.t('更多', 'More'),
                  icon: Icon(Icons.more_horiz, size: 18, color: tc.textSub),
                  onSelected: (value) {
                    switch (value) {
                      case 'edit':
                        _edit(runtime);
                        break;
                      case 'reconnect':
                        unawaited(McpManager.instance.connect(config.id));
                        break;
                      case 'delete':
                        _delete(runtime);
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'edit', child: Text(UiText.t('编辑', 'Edit'))),
                    PopupMenuItem(value: 'reconnect', child: Text(UiText.t('重新连接', 'Reconnect'))),
                    PopupMenuItem(value: 'delete', child: Text(UiText.t('删除', 'Delete'))),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _pill(_mcpTransportLabel(config.transport), tc.textMuted, tc),
                  _pill(_statusLabel(runtime.status), statusColor, tc),
                  Text(
                    config.endpointLabel.isEmpty
                        ? UiText.t('（未配置端点）', '(no endpoint configured)')
                        : config.endpointLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                  ),
                ],
              ),
            ),
            if (runtime.status == McpServerStatus.authRequired) ...[
              const SizedBox(height: 10),
              _authBanner(runtime, tc),
            ] else if (runtime.error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                runtime.error,
                style: TextStyle(color: tc.error, fontSize: fSmall),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                if (runtime.status == McpServerStatus.connecting)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: !globalEnabled
                        ? null
                        : () {
                            if (runtime.isConnected) {
                              unawaited(
                                  McpManager.instance.disconnect(config.id));
                            } else {
                              unawaited(McpManager.instance.connect(config.id));
                            }
                          },
                    icon: Icon(
                      runtime.isConnected
                          ? Icons.link_off
                          : Icons.play_arrow_outlined,
                      size: 15,
                    ),
                    label: Text(runtime.isConnected ? UiText.t('断开', 'Disconnect') : UiText.t('连接', 'Connect')),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    UiText.t(
                      '工具 ${runtime.tools.length} · 资源 ${runtime.resources.length}'
                          ' · 提示词 ${runtime.prompts.length}',
                      'Tools ${runtime.tools.length} · Resources ${runtime.resources.length}'
                          ' · Prompts ${runtime.prompts.length}',
                    ),
                    style: TextStyle(color: tc.textSub, fontSize: fMicro),
                  ),
                ),
              ],
            ),
            if (runtime.tools.isNotEmpty ||
                runtime.resources.isNotEmpty ||
                runtime.prompts.isNotEmpty ||
                runtime.logs.isNotEmpty) ...[
              const SizedBox(height: 4),
              Material(
                type: MaterialType.transparency,
                child: Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: Text(
                      UiText.t('工具与能力', 'Tools & capabilities'),
                      style: TextStyle(color: tc.textBody, fontSize: fSmall),
                    ),
                    children: [
                      if (runtime.tools.isNotEmpty) _buildTools(runtime, tc),
                      if (runtime.resources.isNotEmpty)
                        _buildResources(runtime, tc),
                      if (runtime.prompts.isNotEmpty)
                        _buildPrompts(runtime, tc),
                      _buildLogs(runtime, tc),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _authBanner(McpServerRuntime runtime, ThemeColors tc) {
    final globalEnabled = McpManager.instance.enabled;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tc.warnBg,
        borderRadius: BorderRadius.circular(rSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            runtime.error.isEmpty ? UiText.t('需要 OAuth 授权', 'OAuth authorization required') : runtime.error,
            style: TextStyle(color: tc.warn, fontSize: fSmall),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: globalEnabled
                    ? () =>
                        unawaited(McpManager.instance.login(runtime.config.id))
                    : null,
                icon: const Icon(Icons.login, size: 15),
                label: Text(UiText.t('登录授权', 'Sign in')),
              ),
              if (runtime.pendingAuthUrl.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _copy(runtime.pendingAuthUrl),
                  icon: const Icon(Icons.copy, size: 15),
                  label: Text(UiText.t('复制授权链接', 'Copy authorization link')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTools(McpServerRuntime runtime, ThemeColors tc) {
    final config = runtime.config;
    final exposure = switch (config.toolExposure) {
      McpToolExposure.readOnly => UiText.t('只读工具', 'Read-only tools'),
      McpToolExposure.all => UiText.t('全部工具', 'All tools'),
      McpToolExposure.custom => UiText.t('自定义', 'Custom'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(UiText.t('工具（${runtime.tools.length}）· $exposure', 'Tools (${runtime.tools.length}) · $exposure'), tc),
        for (final tool in runtime.tools) _buildToolRow(runtime, tool, tc),
      ],
    );
  }

  Widget _buildToolRow(
    McpServerRuntime runtime,
    McpToolDescriptor tool,
    ThemeColors tc,
  ) {
    final config = runtime.config;
    final exposed = McpManager.instance.isToolExposed(config, tool);
    final color = tool.readOnly
        ? tc.ok
        : tool.destructive
            ? tc.error
            : tc.warn;
    final label = tool.readOnly
        ? UiText.t('只读', 'Read-only')
        : tool.destructive
            ? UiText.t('破坏性', 'Destructive')
            : UiText.t('外部', 'External');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            tool.readOnly
                ? Icons.visibility_outlined
                : tool.destructive
                    ? Icons.warning_amber_rounded
                    : Icons.build_outlined,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        tool.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tc.textMain,
                          fontSize: fSmall,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _pill(label, color, tc),
                  ],
                ),
                if (tool.description.isNotEmpty)
                  Text(
                    tool.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (config.toolExposure == McpToolExposure.custom)
            Checkbox(
              value: config.allowedTools.contains(tool.name),
              onChanged: (value) =>
                  unawaited(_toggleTool(config, tool.name, value == true)),
            )
          else
            Text(
              exposed ? UiText.t('Agent 可用', 'Agent available') : UiText.t('未开放', 'Not exposed'),
              style: TextStyle(
                color: exposed ? tc.ok : tc.textMuted,
                fontSize: fMicro,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleTool(
    McpServerConfig config,
    String toolName,
    bool enabled,
  ) async {
    final allowed = [...config.allowedTools];
    if (enabled) {
      if (!allowed.contains(toolName)) allowed.add(toolName);
    } else {
      allowed.remove(toolName);
    }
    try {
      await McpManager.instance.setAllowedTools(config.id, allowed);
    } catch (e) {
      _snack(UiText.t('保存工具开关失败：$e', 'Failed to save the tool switch: $e'), error: true);
    }
  }

  Widget _buildResources(McpServerRuntime runtime, ThemeColors tc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(UiText.t('资源（${runtime.resources.length}）', 'Resources (${runtime.resources.length})'), tc),
        for (final resource in runtime.resources)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              resource.isTemplate
                  ? Icons.data_object_outlined
                  : Icons.description_outlined,
              size: 16,
              color: tc.textSub,
            ),
            title: Text(
              resource.title,
              style: TextStyle(color: tc.textBody, fontSize: fSmall),
            ),
            subtitle: Text(
              resource.uri,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tc.textMuted, fontSize: fMicro),
            ),
            trailing: Icon(Icons.open_in_new, size: 14, color: tc.brand),
            onTap: () => unawaited(_readResource(runtime, resource)),
          ),
      ],
    );
  }

  Widget _buildPrompts(McpServerRuntime runtime, ThemeColors tc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(UiText.t('提示词（${runtime.prompts.length}）', 'Prompts (${runtime.prompts.length})'), tc),
        for (final prompt in runtime.prompts)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.chat_bubble_outline,
              size: 16,
              color: tc.textSub,
            ),
            title: Text(
              prompt.title,
              style: TextStyle(color: tc.textBody, fontSize: fSmall),
            ),
            subtitle: Text(
              prompt.description.isEmpty
                  ? (prompt.arguments.isEmpty
                      ? UiText.t('无参数', 'No arguments')
                      : UiText.t('参数: ', 'Arguments: ') + prompt.arguments.map((a) => a.name).join(', '))
                  : prompt.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tc.textMuted, fontSize: fMicro),
            ),
            trailing: Icon(Icons.open_in_new, size: 14, color: tc.brand),
            onTap: () => unawaited(_getPrompt(runtime, prompt)),
          ),
      ],
    );
  }

  Widget _buildLogs(McpServerRuntime runtime, ThemeColors tc) {
    if (runtime.logs.isEmpty) return const SizedBox.shrink();
    final logs = runtime.logs.length > 8
        ? runtime.logs.sublist(runtime.logs.length - 8)
        : runtime.logs;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(UiText.t('最近日志', 'Recent logs'), tc),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: tc.surface,
              borderRadius: BorderRadius.circular(rSmall),
            ),
            child: SelectableText(
              logs.join('\n'),
              style: TextStyle(
                color: tc.textMuted,
                fontSize: fMicro,
                fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text, ThemeColors tc) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          color: tc.textSub,
          fontSize: fMicro,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _statusLabel(McpServerStatus status) {
    switch (status) {
      case McpServerStatus.disabled:
        return UiText.t('已停用', 'Disabled');
      case McpServerStatus.disconnected:
        return UiText.t('未连接', 'Disconnected');
      case McpServerStatus.connecting:
        return UiText.t('连接中', 'Connecting');
      case McpServerStatus.connected:
        return UiText.t('已连接', 'Connected');
      case McpServerStatus.authRequired:
        return UiText.t('需要授权', 'Authorization required');
      case McpServerStatus.error:
        return UiText.t('连接失败', 'Connection failed');
    }
  }

  Widget _pill(String text, Color color, ThemeColors tc) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(rFull),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: fMicro),
      ),
    );
  }

  Color _statusColor(McpServerStatus status, ThemeColors tc) {
    switch (status) {
      case McpServerStatus.connected:
        return tc.ok;
      case McpServerStatus.connecting:
        return tc.warn;
      case McpServerStatus.authRequired:
        return tc.warn;
      case McpServerStatus.error:
        return tc.error;
      case McpServerStatus.disabled:
      case McpServerStatus.disconnected:
        return tc.textMuted;
    }
  }

  void _addCustom() {
    _openEditor(
      McpServerConfig(
        id: _newId(),
        name: UiText.t('新 MCP 服务器', 'New MCP server'),
        enabled: true,
        autoConnect: true,
      ),
      isNew: true,
    );
  }

  void _addPreset(McpServerConfig preset) {
    _openEditor(preset.copyWith(id: _newId()), isNew: true);
  }

  Future<void> _addFilesystemPreset() async {
    String? directory;
    try {
      directory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: UiText.t('选择 filesystem MCP 允许访问的目录', 'Choose the folder the filesystem MCP may access'),
      );
    } catch (e) {
      _snack(UiText.t('打开目录选择器失败：$e', 'Failed to open the folder picker: $e'), error: true);
      return;
    }
    if (directory == null || directory.trim().isEmpty) return;
    _openEditor(
      McpServerConfig.presetFilesystem(directory.trim())
          .copyWith(id: _newId()),
      isNew: true,
    );
  }

  String _newId() => 'mcpx_${const Uuid().v4().substring(0, 8)}';

  Future<void> _setEnabled(String id, bool value) async {
    try {
      await McpManager.instance.setEnabled(id, value);
    } catch (e) {
      _snack(UiText.t('保存开关失败：$e', 'Failed to save the switch: $e'), error: true);
    }
  }

  Future<void> _edit(McpServerRuntime runtime, {bool isNew = false}) async {
    final updated = await showDialog<McpServerConfig>(
      context: context,
      builder: (context) => _McpServerEditorDialog(
        initial: runtime.config,
        isNew: isNew,
      ),
    );
    if (updated == null) return;
    try {
      await McpManager.instance.saveServer(updated);
    } catch (e) {
      _snack(UiText.t('保存失败：$e', 'Failed to save: $e'), error: true);
    }
  }

  void _openEditor(McpServerConfig config, {bool isNew = false}) {
    unawaited(_edit(McpServerRuntime(config: config), isNew: isNew));
  }

  Future<void> _delete(McpServerRuntime runtime) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(UiText.t('删除 MCP 服务器', 'Delete MCP server')),
        content: Text(UiText.t(
          '确定删除「${runtime.config.name}」？同时会清理本机保存的 headers/env/token。',
          'Delete "${runtime.config.name}"? The headers/env/token saved on this machine will also be removed.',
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(UiText.t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(UiText.t('删除', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await McpManager.instance.deleteServer(runtime.config.id);
    } catch (e) {
      _snack(UiText.t('删除失败：$e', 'Failed to delete: $e'), error: true);
    }
  }

  Future<void> _readResource(
    McpServerRuntime runtime,
    McpResourceDescriptor resource,
  ) async {
    var uri = resource.uri;
    if (resource.isTemplate) {
      final input = await _askText(
        UiText.t('资源 URI', 'Resource URI'),
        '${UiText.t('按模板填写具体 URI', 'Enter a concrete URI for the template')}\n${resource.uri}',
      );
      if (input == null || input.trim().isEmpty) return;
      uri = input.trim();
    }
    final text =
        await McpManager.instance.readMcpResource(runtime.config.id, uri);
    if (!mounted) return;
    await _showText(resource.title, text);
  }

  Future<void> _getPrompt(
    McpServerRuntime runtime,
    McpPromptDescriptor prompt,
  ) async {
    Map<String, String> args = const {};
    if (prompt.arguments.isNotEmpty) {
      final input = await _askText(
        UiText.t('提示词参数', 'Prompt arguments'),
        '${UiText.t('每行一个 key=value', 'One key=value per line')}\n'
            '${prompt.arguments.map((a) => '${a.name}${a.required ? UiText.t('（必填）', ' (required)') : ''}: ${a.description}').join('\n')}',
      );
      if (input == null) return;
      args = _parseEnvInput(input);
    }
    final text = await McpManager.instance.getMcpPrompt(
      runtime.config.id,
      prompt.name,
      arguments: args,
    );
    if (!mounted) return;
    await _showText(prompt.title, text);
  }

  Future<String?> _askText(String title, String hint) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: MediaQuery.sizeOf(context).width * 0.8,
          child: TextField(
            controller: controller,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(hintText: hint),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(UiText.t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(UiText.t('确定', 'OK')),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _showText(String title, String text) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: MediaQuery.sizeOf(context).width * 0.9,
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontSize: fSmall, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(context);
              _snack(UiText.t('内容已复制', 'Content copied'));
            },
            child: Text(UiText.t('复制内容', 'Copy content')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(UiText.t('关闭', 'Close')),
          ),
        ],
      ),
    );
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _snack(UiText.t('已复制', 'Copied'));
  }

  Map<String, String> _parseEnvInput(String text) {
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

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    final tc = ThemeColors.of(context);
    showTopSnackBar(context, 
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? tc.error : null,
      ),
    );
  }
}

/// 添加/编辑服务器
class _McpServerEditorDialog extends StatefulWidget {
  const _McpServerEditorDialog({required this.initial, this.isNew = false});

  final McpServerConfig initial;
  final bool isNew;

  @override
  State<_McpServerEditorDialog> createState() => _McpServerEditorDialogState();
}

class _McpServerEditorDialogState extends State<_McpServerEditorDialog> {
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

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _name = TextEditingController(text: c.name);
    _url = TextEditingController(text: c.url);
    _command = TextEditingController(text: c.command);
    _args = TextEditingController(text: c.args.join('\n'));
    _workdir = TextEditingController(text: c.workingDirectory);
    _headers = TextEditingController(
      text: c.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
    );
    _env =
        TextEditingController(text: c.env.entries.map((e) => '${e.key}=${e.value}').join('\n'));
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

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      child: SizedBox(
        width: size.width > 800 ? 760 : size.width * 0.94,
        height: size.height > 760 ? 680 : size.height * 0.9,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(pStandard, pCompact, pSmall, pSmall),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.isNew ? UiText.t('添加 MCP 服务器', 'Add MCP server') : UiText.t('编辑 MCP 服务器', 'Edit MCP server'),
                      style: TextStyle(
                        color: tc.textMain,
                        fontSize: fTitle,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: tc.hairline),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(pStandard),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _field(UiText.t('名称', 'Name'), _name),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<McpTransportKind>(
                      initialValue: _transport,
                      decoration: InputDecoration(labelText: UiText.t('传输方式', 'Transport')),
                      items: McpTransportKind.values
                          .map((t) => DropdownMenuItem(
                                value: t,
                                child: Text(_mcpTransportLabel(t)),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) setState(() => _transport = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    if (_transport == McpTransportKind.stdio) ...[
                      _field(UiText.t('启动命令', 'Start command'), _command, hint: UiText.t('例如 npx', 'e.g. npx')),
                      const SizedBox(height: 12),
                      _field(UiText.t('参数（每行一个）', 'Arguments (one per line)'), _args, maxLines: 4, hint: '-y\n@modelcontextprotocol/server-filesystem\nD:\\data'),
                      const SizedBox(height: 12),
                      _field(UiText.t('工作目录（可选）', 'Working directory (optional)'), _workdir),
                      const SizedBox(height: 12),
                      _field(UiText.t('环境变量（每行 KEY=VALUE）', 'Environment variables (KEY=VALUE per line)'), _env, maxLines: 3),
                      const SizedBox(height: 6),
                      _hint(
                        UiText.t(
                          '需要本机安装 Node.js。Windows 下 npx/pnpm/yarn/uvx 会自动补 .cmd。\n'
                              'filesystem：npx -y @modelcontextprotocol/server-filesystem <允许目录>，'
                              '可传多个目录（每个参数一个）。\n'
                              'context7：npx -y @upstash/context7-mcp；可无 Key 使用，'
                              '更高额度在环境变量填 CONTEXT7_API_KEY。\n'
                              '首次运行 npx 会联网下载包，可能较慢。',
                          'Node.js must be installed locally. On Windows, npx/pnpm/yarn/uvx automatically resolve .cmd shims.\n'
                              'filesystem: npx -y @modelcontextprotocol/server-filesystem <allowed folder>; '
                              'pass multiple folders as separate arguments.\n'
                              'context7: npx -y @upstash/context7-mcp; works without a key, '
                              'set CONTEXT7_API_KEY for a higher quota.\n'
                              'The first npx run downloads the package, so it may be slow.',
                        ),
                      ),
                    ] else ...[
                      _field(UiText.t('服务器 URL', 'Server URL'), _url, hint: 'https://example.com/mcp'),
                      const SizedBox(height: 12),
                      _field(UiText.t('出站代理（可选）', 'Outbound proxy (optional)'), _proxy, hint: 'http://127.0.0.1:7890'),
                      const SizedBox(height: 12),
                      _field(UiText.t('Headers（每行 Key: Value）', 'Headers (Key: Value per line)'), _headers, maxLines: 3),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _field(UiText.t('超时（ms）', 'Timeout (ms)'), _timeout)),
                        const SizedBox(width: 12),
                        Expanded(child: _field(UiText.t('工具上限', 'Tool limit'), _maxTools)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<McpToolExposure>(
                      initialValue: _exposure,
                      decoration: InputDecoration(labelText: UiText.t('Agent 可用工具', 'Tools available to the Agent')),
                      items: [
                        DropdownMenuItem(
                          value: McpToolExposure.readOnly,
                          child: Text(UiText.t('只读工具（推荐）', 'Read-only tools (recommended)')),
                        ),
                        DropdownMenuItem(
                          value: McpToolExposure.all,
                          child: Text(UiText.t('全部工具', 'All tools')),
                        ),
                        DropdownMenuItem(
                          value: McpToolExposure.custom,
                          child: Text(UiText.t('自定义（连接后在卡片中勾选）', 'Custom (select in the card after connecting)')),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _exposure = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    _switchRow(UiText.t('启用服务器', 'Enable server'), _enabled, (v) => setState(() => _enabled = v)),
                    _switchRow(UiText.t('应用启动时自动连接', 'Auto-connect on app start'), _autoConnect, (v) => setState(() => _autoConnect = v)),
                    _switchRow(UiText.t('允许 Agent 使用资源', 'Allow the Agent to use resources'), _exposeResources, (v) => setState(() => _exposeResources = v)),
                    _switchRow(UiText.t('允许 Agent 使用提示词', 'Allow the Agent to use prompts'), _exposePrompts, (v) => setState(() => _exposePrompts = v)),
                    if (_transport == McpTransportKind.streamableHttp) ...[
                      Divider(color: tc.hairline, height: 24),
                      _switchRow(UiText.t('使用 OAuth 授权', 'Use OAuth authorization'), _oauth, (v) => setState(() => _oauth = v)),
                      if (_oauth) ...[
                        const SizedBox(height: 8),
                        _field(UiText.t('OAuth scopes（空格/逗号分隔，可选）', 'OAuth scopes (space/comma separated, optional)'), _scopes),
                        const SizedBox(height: 12),
                        _field(UiText.t('OAuth clientId（留空走 DCR）', 'OAuth clientId (blank uses DCR)'), _clientId),
                        const SizedBox(height: 12),
                        _field(UiText.t('OAuth clientSecret（可选）', 'OAuth clientSecret (optional)'), _clientSecret, obscure: true),
                      ],
                    ],
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: tc.surface,
                        borderRadius: BorderRadius.circular(rSmall),
                      ),
                      child: Text(
                        UiText.t(
                          'MCP 服务器可以返回工具描述和外部内容，存在 prompt injection 风险。'
                              '建议先用只读策略确认行为；headers/env/secret 保存在本机加密凭据库，编辑页会显示当前值。',
                          'MCP servers can return tool descriptions and external content, so prompt injection is a risk. '
                              'Start with the read-only policy to confirm behavior. Headers/env/secret are stored in the local encrypted credential store; this editor shows their current values.',
                        ),
                        style: TextStyle(color: tc.textSub, fontSize: fMicro, height: 1.5),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _error!,
                        style: TextStyle(color: tc.error, fontSize: fSmall),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: tc.hairline),
            Padding(
              padding: const EdgeInsets.all(pCompact),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(UiText.t('取消', 'Cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: tc.brand,
                      foregroundColor: tc.isLight ? Colors.white : cBg,
                    ),
                    child: Text(_enabled ? UiText.t('保存并连接', 'Save & connect') : UiText.t('保存', 'Save')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    int maxLines = 1,
    bool obscure = false,
  }) {
    return TextField(
      controller: controller,
      maxLines: obscure ? 1 : maxLines,
      obscureText: obscure,
      style: const TextStyle(fontSize: fSmall),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _hint(String text) {
    final tc = ThemeColors.of(context);
    return Text(
      text,
      style: TextStyle(color: tc.textMuted, fontSize: fMicro, height: 1.4),
    );
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) {
    final tc = ThemeColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: tc.textBody, fontSize: fSmall),
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: tc.brand,
          activeTrackColor: tc.brandBg,
          inactiveThumbColor: tc.textMuted,
          inactiveTrackColor: tc.surface,
        ),
      ],
    );
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = UiText.t('名称不能为空', 'Name is required'));
      return;
    }
    if (_transport == McpTransportKind.stdio) {
      if (_command.text.trim().isEmpty) {
        setState(() => _error = UiText.t('stdio 传输需要启动命令', 'stdio transport requires a start command'));
        return;
      }
    } else {
      final uri = Uri.tryParse(_url.text.trim());
      if (uri == null ||
          !uri.hasScheme ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        setState(() => _error = UiText.t('服务器 URL 必须是 http(s) 地址', 'Server URL must be an http(s) address'));
        return;
      }
    }
    final timeout = int.tryParse(_timeout.text.trim());
    if (timeout == null || timeout < 3000 || timeout > 120000) {
      setState(() => _error = UiText.t('超时需在 3000-120000ms 之间', 'Timeout must be between 3000 and 120000 ms'));
      return;
    }
    final maxTools = int.tryParse(_maxTools.text.trim());
    if (maxTools == null || maxTools < 1 || maxTools > 40) {
      setState(() => _error = UiText.t('工具上限需在 1-40 之间', 'Tool limit must be between 1 and 40'));
      return;
    }
    final proxyRaw = _proxy.text.trim();
    final proxy = _normalizeProxy(proxyRaw);
    if (proxyRaw.isNotEmpty && proxy == null) {
      setState(() => _error = '代理仅支持 http://host:port，不支持 SOCKS5/账号密码');
      return;
    }

    final config = widget.initial.copyWith(
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
    );
    Navigator.pop(context, config);
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
}

String _mcpTransportLabel(McpTransportKind kind) {
  switch (kind) {
    case McpTransportKind.streamableHttp:
      return 'Streamable HTTP';
    case McpTransportKind.sse:
      return UiText.t('HTTP + SSE（旧版）', 'HTTP + SSE (legacy)');
    case McpTransportKind.stdio:
      return UiText.t('stdio（本地进程）', 'stdio (local process)');
  }
}
