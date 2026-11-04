import '../models/agent_memory.dart';
import '../models/agent_state.dart';
import '../models/ai_model_config.dart';
import 'agent_engine.dart';
import 'command_executor.dart';

/// Agent 状态注册表：按 **scopeId（终端 tab 的 id）** 隔离 Agent 状态和引擎。
///
/// 一个服务器（hostId）可以同时打开多个 tab。过去这里按 hostId 存储，导致
/// 同一服务器的第二个 tab 会直接加载第一个 tab 正在执行的 Agent 状态，且共享
/// 引擎的 `isRunning` 会拒绝第二个 tab 的任务。现在每个 tab 拥有独立的
/// state / engine / executor / memory，同时记录 scope → hostId，供知识库、
/// 审计、多机编排等仍以“服务器”为单位的逻辑使用。
class AgentHostRegistry {
  /// scopeId(tabId) → hostId
  final Map<String, String> _scopeHosts = {};
  final Map<String, AgentState> _states = {};
  final Map<String, AgentEngine> _engines = {};
  final Map<String, CommandExecutor?> _executors = {};
  final Map<String, AIModelConfig?> _modelConfigs = {};
  final Map<String, AgentMemory> _memories = {};
  final Map<String, Future<void>> _sysInfoFutures = {};

  /// 仅用于多机编排/旧调用方：hostId → executor。
  /// 正常情况下优先从活跃 scope 或同 host 的其他 scope 解析，见 [getExecutor]。
  final Map<String, CommandExecutor?> _hostExecutors = {};
  String? _activeScopeId;

  // Getter 方法
  String? get activeScopeId => _activeScopeId;
  String? getHostId(String scopeId) => _scopeHosts[scopeId];
  AgentState? getState(String scopeId) => _states[scopeId];
  AgentEngine? getEngine(String scopeId) => _engines[scopeId];

  Iterable<String> scopesForHost(String hostId) => _scopeHosts.entries
      .where((entry) => entry.value == hostId)
      .map((entry) => entry.key);

  /// 获取指定 tab 自己的命令执行器。
  ///
  /// 历史问题：registry 持有的 executor 引用可能因 tab 关闭/重连/空闲清理
  /// 而变成陈旧快照（SSHService 已 dispose、isConnected=false）。编排层
  /// 拿到这种陈旧引用会误报"主机未连接"，而 UI 端从 terminalProvider.tabs
  /// 取的是新 tab 的实时状态，造成"UI 显示已连接、编排却报未连接"。
  ///
  /// 修复：实时校验 isConnected，断开则自愈清理引用并返回 null，让调用方
  /// 走"未连接"分支而不是拿陈旧 executor 假装能跑。
  CommandExecutor? getScopeExecutor(String scopeId) {
    final executor = _executors[scopeId];
    if (executor != null && !executor.isConnected) {
      _executors[scopeId] = null;
      return null;
    }
    return executor;
  }

  /// 按 hostId 解析 executor（多机编排使用）。
  /// 优先活跃 tab，其次同 host 的其他 tab，最后回退到旧的 host 级注册。
  CommandExecutor? getExecutor(String hostId) {
    final active = _activeScopeId;
    if (active != null && _scopeHosts[active] == hostId) {
      final executor = getScopeExecutor(active);
      if (executor != null) return executor;
    }
    for (final scopeId in scopesForHost(hostId)) {
      if (scopeId == active) continue;
      final executor = getScopeExecutor(scopeId);
      if (executor != null) return executor;
    }

    final executor = _hostExecutors[hostId];
    if (executor != null && !executor.isConnected) {
      _hostExecutors[hostId] = null;
      return null;
    }
    return executor;
  }

  AIModelConfig? getModelConfig(String scopeId) => _modelConfigs[scopeId];
  AIModelConfig? getModelConfigForHost(String hostId) {
    for (final scopeId in scopesForHost(hostId)) {
      final config = _modelConfigs[scopeId];
      if (config != null) return config;
    }
    return null;
  }
  AgentMemory? getMemory(String scopeId) => _memories[scopeId];
  bool hasState(String scopeId) => _states.containsKey(scopeId);
  bool hasSysInfoFuture(String scopeId) => _sysInfoFutures.containsKey(scopeId);
  Future<void>? getSysInfoFuture(String scopeId) => _sysInfoFutures[scopeId];
  Iterable<AgentEngine> get engines => _engines.values;
  Iterable<String> get scopeIds => _states.keys;

  // Setter 方法
  void setScopeHost(String scopeId, String hostId) => _scopeHosts[scopeId] = hostId;
  void setState(String scopeId, AgentState state) => _states[scopeId] = state;
  void setEngine(String scopeId, AgentEngine engine) => _engines[scopeId] = engine;
  void setExecutor(String hostId, CommandExecutor? executor) =>
      _hostExecutors[hostId] = executor;
  void setScopeExecutor(String scopeId, CommandExecutor? executor) =>
      _executors[scopeId] = executor;
  void setModelConfig(String scopeId, AIModelConfig? config) =>
      _modelConfigs[scopeId] = config;
  void setMemory(String scopeId, AgentMemory memory) => _memories[scopeId] = memory;
  void setSysInfoFuture(String scopeId, Future<void> future) =>
      _sysInfoFutures[scopeId] = future;

  // 活跃 scope 管理
  void setActive(String scopeId) => _activeScopeId = scopeId;

  /// 判断给定 scope 是否为当前活跃 scope
  bool isActive(String scopeId) => _activeScopeId == scopeId;

  /// 保存当前活跃 scope 的状态到缓存
  void saveActiveState(AgentState state) {
    if (_activeScopeId != null) {
      _states[_activeScopeId!] = state;
    }
  }

  /// 更新非活跃 scope 的缓存状态（仅当 scope 存在于缓存中时）。
  /// 活跃 scope 的状态由 AgentNotifier 通过 state= 直接更新，不经过此方法。
  void updateState(String scopeId, AgentState Function(AgentState) updater) {
    if (_states.containsKey(scopeId)) {
      _states[scopeId] = updater(_states[scopeId]!);
    }
  }

  /// 删除单个 tab 的所有状态；若删除的是活跃 scope，同时清除活跃标记
  void removeScope(String scopeId) {
    _states.remove(scopeId);
    _engines.remove(scopeId);
    _executors.remove(scopeId);
    _modelConfigs.remove(scopeId);
    _memories.remove(scopeId);
    _sysInfoFutures.remove(scopeId);
    final hostId = _scopeHosts.remove(scopeId);
    if (hostId != null && scopesForHost(hostId).isEmpty) {
      // 该 host 已没有其他 tab，旧的 host 级 executor 不能再指向已释放的连接
      _hostExecutors.remove(hostId);
    }
    if (_activeScopeId == scopeId) {
      _activeScopeId = null;
    }
  }

  /// 删除某 host 的所有 tab 状态（关闭服务器相关资源时使用）
  void removeHost(String hostId) {
    for (final scopeId in scopesForHost(hostId).toList()) {
      removeScope(scopeId);
    }
    _hostExecutors.remove(hostId);
  }

  /// 释放所有资源
  void dispose() {
    _scopeHosts.clear();
    _states.clear();
    _engines.clear();
    _executors.clear();
    _hostExecutors.clear();
    _modelConfigs.clear();
    _memories.clear();
    _sysInfoFutures.clear();
    _activeScopeId = null;
  }
}
