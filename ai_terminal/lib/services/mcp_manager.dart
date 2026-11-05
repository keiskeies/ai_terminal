import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mcp_dart/mcp_dart.dart' show LogLevel, setMcpLogHandler;

import 'agent_logger.dart';
import 'agent_tool.dart';
import 'mcp_connection.dart';
import 'mcp_models.dart';
import 'mcp_store.dart';
import 'mcp_tool_adapter.dart';

/// 全局 MCP 管理器
///
/// 负责服务器配置、连接生命周期、能力发现、工具注册同步。
/// UI 通过 [ChangeNotifier] 监听；AgentEngine 在任务开始时调用 [syncRegistry]。
class McpManager extends ChangeNotifier implements McpToolCaller {
  McpManager._();

  static final McpManager instance = McpManager._();
  static const int _globalToolCap = 40;

  final List<McpServerConfig> _configs = [];
  final Map<String, McpServerRuntime> _runtimes = {};
  final Map<String, McpConnection> _connections = {};
  bool _initialized = false;
  bool _disposed = false;
  bool _enabled = true;
  int _toolsetVersion = 0;
  String _lastSignature = '';

  List<McpServerConfig> get configs => List.unmodifiable(_configs);
  Map<String, McpServerRuntime> get runtimes => Map.unmodifiable(_runtimes);
  int get toolsetVersion => _toolsetVersion;
  bool get enabled => _enabled;

  int get connectedCount =>
      _runtimes.values.where((r) => r.isConnected).length;

  int get exposedToolCount => buildAgentTools().length;

  McpServerRuntime? runtimeFor(String id) => _runtimes[id];

  McpServerConfig? configFor(String id) {
    for (final config in _configs) {
      if (config.id == id) return config;
    }
    return null;
  }

  Future<void> init() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    // mcp_dart 默认把 SDK 日志写到 stderr；Windows GUI 版没有控制台句柄，
    // 每次写入都抛 FileSystemException 冒到 Zone 兜底，agent.log 被 20 行栈刷屏。
    // 只把 warn/error 收进我们自己的日志，debug/info 属于 SDK 内部流程，不进文件。
    setMcpLogHandler((name, level, message) {
      if (level == LogLevel.error) {
        agentLogger.warn('MCP', '[$name] $message');
      } else if (level == LogLevel.warn) {
        agentLogger.debug('MCP', '[$name] $message');
      }
    });
    try {
      _enabled = McpStore.loadGlobalEnabled();
      final loaded = await McpStore.loadAll();
      _configs
        ..clear()
        ..addAll(loaded);
      for (final config in loaded) {
        _runtimes[config.id] = McpServerRuntime(
          config: config,
          status: !_enabled
              ? McpServerStatus.disconnected
              : config.enabled
                  ? McpServerStatus.disconnected
                  : McpServerStatus.disabled,
        );
      }
      if (!_disposed) notifyListeners();
      if (!_enabled) return;
      for (final config in loaded) {
        if (config.enabled && config.autoConnect) {
          unawaited(connect(config.id));
        }
      }
    } catch (e) {
      debugPrint('[McpManager] 初始化失败: $e');
    }
  }

  /// 全局开关：关闭时断开所有连接并隐藏所有 MCP 工具，但保留服务器配置
  Future<void> setGlobalEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    await McpStore.saveGlobalEnabled(value);
    if (!value) {
      final ids = _connections.keys.toList();
      for (final id in ids) {
        final connection = _connections.remove(id);
        if (connection != null) await connection.disconnect();
      }
      for (final config in _configs) {
        _runtimes[config.id] = McpServerRuntime(
          config: config,
          status: McpServerStatus.disconnected,
        );
      }
    } else {
      for (final config in _configs) {
        if (config.enabled) {
          unawaited(connect(config.id));
        } else {
          _runtimes[config.id] = McpServerRuntime(
            config: config,
            status: McpServerStatus.disabled,
          );
        }
      }
    }
    _bumpVersionIfNeeded();
    if (!_disposed) notifyListeners();
  }

  Future<void> connect(String id, {bool interactiveAuth = false}) async {
    if (_disposed || !_enabled) return;
    final index = _configs.indexWhere((c) => c.id == id);
    if (index < 0) return;
    var config = _configs[index];
    if (!config.enabled) {
      config = config.copyWith(enabled: true);
      _configs[index] = config;
      try {
        await McpStore.saveConfigs(_configs);
      } catch (e) {
        debugPrint('[McpManager] 保存启用状态失败: $e');
      }
    }

    final old = _connections.remove(id);
    if (old != null) {
      await old.disconnect();
    }

    final previous = _runtimes[id];
    _runtimes[id] = McpServerRuntime(
      config: config,
      status: McpServerStatus.connecting,
      tools: previous?.tools ?? const [],
      resources: previous?.resources ?? const [],
      prompts: previous?.prompts ?? const [],
      logs: previous?.logs ?? const [],
    );
    notifyListeners();

    late final McpConnection connection;
    connection = McpConnection(
      config: config,
      onRuntime: (runtime) {
        if (_disposed || !identical(_connections[id], connection)) return;
        _runtimes[id] = runtime;
        _bumpVersionIfNeeded();
        notifyListeners();
      },
    );
    _connections[id] = connection;
    await connection.connect(interactiveAuth: interactiveAuth);
  }

  Future<void> login(String id) => connect(id, interactiveAuth: true);

  Future<void> disconnect(String id) async {
    final connection = _connections.remove(id);
    if (connection != null) {
      await connection.disconnect();
    }
    final config = configFor(id);
    if (config != null) {
      _runtimes[id] = McpServerRuntime(
        config: config,
        status: config.enabled
            ? McpServerStatus.disconnected
            : McpServerStatus.disabled,
      );
    }
    _bumpVersionIfNeeded();
    if (!_disposed) notifyListeners();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final index = _configs.indexWhere((c) => c.id == id);
    if (index < 0) return;
    final next = [..._configs];
    next[index] = next[index].copyWith(enabled: enabled);
    await McpStore.saveConfigs(next);
    _configs
      ..clear()
      ..addAll(next);
    if (!enabled) {
      await disconnect(id);
    } else if (_enabled) {
      unawaited(connect(id));
    } else {
      final runtime = _runtimes[id];
      if (runtime != null) {
        _runtimes[id] = runtime.copyWith(
          status: McpServerStatus.disconnected,
          error: '',
          pendingAuthUrl: '',
          clearConnectedAt: true,
        );
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> saveServer(McpServerConfig config) async {
    final next = <McpServerConfig>[];
    var replaced = false;
    for (final existing in _configs) {
      if (existing.id == config.id) {
        next.add(config);
        replaced = true;
      } else {
        next.add(existing);
      }
    }
    if (!replaced) next.add(config);
    await McpStore.saveAll(next);

    _configs
      ..clear()
      ..addAll(next);
    final old = _connections.remove(config.id);
    if (old != null) await old.disconnect();

    _runtimes[config.id] = McpServerRuntime(
      config: config,
      status: config.enabled
          ? McpServerStatus.disconnected
          : McpServerStatus.disabled,
    );
    _bumpVersionIfNeeded();
    notifyListeners();
    if (config.enabled) {
      unawaited(connect(config.id));
    }
  }

  Future<void> deleteServer(String id) async {
    final next = _configs.where((c) => c.id != id).toList();
    await McpStore.saveAll(next, removedIds: [id]);
    final connection = _connections.remove(id);
    if (connection != null) await connection.disconnect();
    _configs
      ..clear()
      ..addAll(next);
    _runtimes.remove(id);
    _bumpVersionIfNeeded();
    if (!_disposed) notifyListeners();
  }

  /// 只更新 custom 模式的白名单，不重连
  Future<void> setAllowedTools(String id, List<String> allowed) async {
    final index = _configs.indexWhere((c) => c.id == id);
    if (index < 0) return;
    final next = [..._configs];
    next[index] = next[index].copyWith(allowedTools: allowed);
    await McpStore.saveConfigs(next);
    _configs
      ..clear()
      ..addAll(next);
    final runtime = _runtimes[id];
    if (runtime != null) {
      _runtimes[id] = runtime.copyWith(config: _configs[index]);
    }
    _bumpVersionIfNeeded();
    if (!_disposed) notifyListeners();
  }

  List<AgentTool> buildAgentTools() {
    if (!_enabled) return const [];
    final out = <AgentTool>[];
    final usedNames = <String>{};
    for (final runtime in _runtimes.values) {
      if (!runtime.isConnected) continue;
      final config = runtime.config;
      final allowed = runtime.tools
          .where((tool) => isToolExposed(config, tool))
          .take(config.maxTools);
      for (final tool in allowed) {
        if (out.length >= _globalToolCap) break;
        final base = mcpToolFullName(config.id, tool.name);
        final name = _uniqueName(base, usedNames);
        out.add(McpToolAdapter(
          caller: this,
          serverId: config.id,
          serverName: config.name,
          descriptor: tool,
          nameOverride: name,
        ));
      }
      if (out.length >= _globalToolCap) break;
      if (config.exposeResources && runtime.resources.isNotEmpty) {
        for (final kind in [
          McpSideToolKind.listResources,
          McpSideToolKind.readResource,
        ]) {
          final suffix = kind == McpSideToolKind.listResources
              ? 'list_resources'
              : 'read_resource';
          final name = _uniqueName(
            mcpToolFullName(config.id, suffix),
            usedNames,
          );
          out.add(McpSideToolAdapter(
            caller: this,
            serverId: config.id,
            serverName: config.name,
            sideKind: kind,
            nameOverride: name,
          ));
        }
      }
      if (out.length >= _globalToolCap) break;
      if (config.exposePrompts && runtime.prompts.isNotEmpty) {
        for (final kind in [
          McpSideToolKind.listPrompts,
          McpSideToolKind.getPrompt,
        ]) {
          final suffix =
              kind == McpSideToolKind.listPrompts ? 'list_prompts' : 'get_prompt';
          final name = _uniqueName(
            mcpToolFullName(config.id, suffix),
            usedNames,
          );
          out.add(McpSideToolAdapter(
            caller: this,
            serverId: config.id,
            serverName: config.name,
            sideKind: kind,
            nameOverride: name,
          ));
        }
      }
    }
    return out.take(_globalToolCap).toList();
  }

  bool isToolExposed(McpServerConfig config, McpToolDescriptor tool) {
    switch (config.toolExposure) {
      case McpToolExposure.readOnly:
        return tool.readOnly;
      case McpToolExposure.all:
        return true;
      case McpToolExposure.custom:
        return config.allowedTools.contains(tool.name);
    }
  }

  String _uniqueName(String base, Set<String> used) {
    if (used.add(base)) return base;
    for (var i = 2; i < 100; i++) {
      final suffix = '_$i';
      final candidate = base.length + suffix.length <= 64
          ? '$base$suffix'
          : '${base.substring(0, 64 - suffix.length)}$suffix';
      if (used.add(candidate)) return candidate;
    }
    return base;
  }

  /// 把当前 MCP 工具同步到某个 AgentEngine 的注册表
  int syncRegistry(AgentToolRegistry registry) {
    registry.unregisterPrefix('mcp__');
    final tools = buildAgentTools();
    for (final tool in tools) {
      registry.register(tool, scope: ToolScope.all);
    }
    final signature = _signatureOf(tools);
    if (signature != _lastSignature) {
      _lastSignature = signature;
      _toolsetVersion++;
    }
    return _toolsetVersion;
  }

  void _bumpVersionIfNeeded() {
    final signature = _signatureOf(buildAgentTools());
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    _toolsetVersion++;
  }

  String _signatureOf(List<AgentTool> tools) => tools
      .map((tool) => '${tool.name}:${tool.kind.name}:${tool.source.name}')
      .join(';');

  @override
  McpServerRuntime? mcpRuntime(String serverId) => _runtimes[serverId];

  @override
  Future<McpCallResult> callMcpTool(
    String serverId,
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final connection = _connections[serverId];
    if (connection == null) {
      return const McpCallResult(
        isError: true,
        text: 'MCP 服务器未连接，请在设置中重新连接。',
      );
    }
    return connection.callTool(toolName, arguments);
  }

  @override
  Future<String> readMcpResource(String serverId, String uri) async {
    final connection = _connections[serverId];
    if (connection == null) return 'MCP 服务器未连接';
    return connection.readResource(uri);
  }

  @override
  Future<String> getMcpPrompt(
    String serverId,
    String name, {
    Map<String, String> arguments = const {},
  }) async {
    final connection = _connections[serverId];
    if (connection == null) return 'MCP 服务器未连接';
    return connection.getPrompt(name, arguments: arguments);
  }

  @visibleForTesting
  void setRuntimeForTesting(McpServerRuntime runtime) {
    _initialized = true;
    _configs.removeWhere((c) => c.id == runtime.config.id);
    _configs.add(runtime.config);
    _runtimes[runtime.config.id] = runtime;
  }

  @visibleForTesting
  void loadConfigsForTesting(List<McpServerConfig> configs) {
    _enabled = true;
    for (final connection in _connections.values.toList()) {
      unawaited(connection.disconnect());
    }
    _connections.clear();
    _configs
      ..clear()
      ..addAll(configs);
    _runtimes.clear();
    for (final config in configs) {
      _runtimes[config.id] = McpServerRuntime(
        config: config,
        status: config.enabled
            ? McpServerStatus.disconnected
            : McpServerStatus.disabled,
      );
    }
    _initialized = true;
  }

  @visibleForTesting
  Future<void> reloadForTests() async {
    for (final connection in _connections.values.toList()) {
      await connection.disconnect();
    }
    _connections.clear();
    _configs.clear();
    _runtimes.clear();
    _initialized = false;
    _lastSignature = '';
    await init();
  }

  /// 应用退出时等待连接关闭 / stdio 子进程结束
  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    final connections = _connections.values.toList();
    _connections.clear();
    await Future.wait(connections.map((c) => c.disconnect()));
    super.dispose();
  }

  @override
  // shutdown() 在异步断开连接后调用 super.dispose()，这里不能同步重复调用
  // ignore: must_call_super
  void dispose() {
    unawaited(shutdown());
  }
}
