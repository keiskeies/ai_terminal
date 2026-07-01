import '../models/agent_memory.dart';
import '../models/agent_state.dart';
import '../models/ai_model_config.dart';
import 'agent_engine.dart';
import 'command_executor.dart';

/// 多 host 状态注册表：管理每个 host 的 Agent 状态和引擎实例
class AgentHostRegistry {
  final Map<String, AgentState> _states = {};
  final Map<String, AgentEngine> _engines = {};
  final Map<String, CommandExecutor?> _executors = {};
  final Map<String, AIModelConfig?> _modelConfigs = {};
  final Map<String, AgentMemory> _memories = {};
  final Map<String, Future<void>> _sysInfoFutures = {};
  String? _activeHostId;

  // Getter 方法
  String? get activeHostId => _activeHostId;
  AgentState? getState(String hostId) => _states[hostId];
  AgentEngine? getEngine(String hostId) => _engines[hostId];
  CommandExecutor? getExecutor(String hostId) => _executors[hostId];
  AIModelConfig? getModelConfig(String hostId) => _modelConfigs[hostId];
  AgentMemory? getMemory(String hostId) => _memories[hostId];
  bool hasState(String hostId) => _states.containsKey(hostId);
  bool hasSysInfoFuture(String hostId) => _sysInfoFutures.containsKey(hostId);
  Future<void>? getSysInfoFuture(String hostId) => _sysInfoFutures[hostId];
  Iterable<AgentEngine> get engines => _engines.values;

  // Setter 方法
  void setState(String hostId, AgentState state) => _states[hostId] = state;
  void setEngine(String hostId, AgentEngine engine) => _engines[hostId] = engine;
  void setExecutor(String hostId, CommandExecutor? executor) => _executors[hostId] = executor;
  void setModelConfig(String hostId, AIModelConfig? config) => _modelConfigs[hostId] = config;
  void setMemory(String hostId, AgentMemory memory) => _memories[hostId] = memory;
  void setSysInfoFuture(String hostId, Future<void> future) => _sysInfoFutures[hostId] = future;

  // 活跃 host 管理
  void setActive(String hostId) => _activeHostId = hostId;

  /// 判断给定 host 是否为当前活跃 host
  bool isActive(String hostId) => _activeHostId == hostId;

  /// 保存当前活跃 host 的状态到缓存
  void saveActiveState(AgentState state) {
    if (_activeHostId != null) {
      _states[_activeHostId!] = state;
    }
  }

  /// 更新非活跃 host 的缓存状态（仅当 host 存在于缓存中时）。
  /// 活跃 host 的状态由 AgentNotifier 通过 state= 直接更新，不经过此方法。
  void updateState(String hostId, AgentState Function(AgentState) updater) {
    if (_states.containsKey(hostId)) {
      _states[hostId] = updater(_states[hostId]!);
    }
  }

  /// 删除 host 的所有状态（若被删除的是活跃 host，同时清除活跃标记）
  void removeHost(String hostId) {
    _states.remove(hostId);
    _engines.remove(hostId);
    _executors.remove(hostId);
    _modelConfigs.remove(hostId);
    _memories.remove(hostId);
    _sysInfoFutures.remove(hostId);
    if (_activeHostId == hostId) {
      _activeHostId = null;
    }
  }

  /// 释放所有资源
  void dispose() {
    _states.clear();
    _engines.clear();
    _executors.clear();
    _modelConfigs.clear();
    _memories.clear();
    _sysInfoFutures.clear();
  }
}
