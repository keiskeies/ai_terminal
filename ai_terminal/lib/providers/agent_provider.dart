import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/agent_model.dart';
import '../models/agent_memory.dart';
import '../models/ai_model_config.dart';
import '../services/agent_engine.dart';
import '../services/ai_service.dart';
import '../services/ssh_service.dart';
import '../services/command_executor.dart';
import '../core/hive_init.dart';

/// Agent 状态
class AgentState {
  final AgentMode mode;
  final AgentStatus status;
  final AgentTask? currentTask;
  final String? lastMessage;
  final List<ChatItem> chatItems; // 统一的消息列表，包含用户和AI消息
  final String? error;
  final int maxSteps;

  AgentState({
    this.mode = AgentMode.assistant,
    this.status = AgentStatus.idle,
    this.currentTask,
    this.lastMessage,
    List<ChatItem>? chatItems,
    this.error,
    this.maxSteps = 10,
  }) : chatItems = chatItems ?? [];

  bool get isRunning =>
      status == AgentStatus.thinking || status == AgentStatus.executing;

  AgentState copyWith({
    AgentMode? mode,
    AgentStatus? status,
    AgentTask? currentTask,
    String? lastMessage,
    List<ChatItem>? chatItems,
    String? error,
    int? maxSteps,
  }) {
    return AgentState(
      mode: mode ?? this.mode,
      status: status ?? this.status,
      currentTask: currentTask ?? this.currentTask,
      lastMessage: lastMessage ?? this.lastMessage,
      chatItems: chatItems ?? this.chatItems,
      error: error,
      maxSteps: maxSteps ?? this.maxSteps,
    );
  }

  String get statusText {
    switch (status) {
      case AgentStatus.idle:
        return '就绪';
      case AgentStatus.thinking:
        return '🤔 思考中...';
      case AgentStatus.executing:
        return '⚡ 执行中...';
      case AgentStatus.waitingConfirm:
        return '⏳ 等待确认';
      case AgentStatus.completed:
        return '✅ 完成';
      case AgentStatus.failed:
        return '❌ 失败';
      case AgentStatus.cancelled:
        return '🚫 已取消';
    }
  }
}

/// 统一的聊天项，支持用户和AI消息
class ChatItem {
  final String role; // 'user' | 'assistant'
  final String content;
  final bool isStreaming;

  ChatItem({
    required this.role,
    required this.content,
    this.isStreaming = false,
  });
}

/// Agent Provider — 每个 tab 独立 Agent 状态
class AgentNotifier extends StateNotifier<AgentState> {
  final AgentMemory _memory;
  AgentEngine? _engine;
  CommandExecutor? _executor;
  AIModelConfig? _modelConfig;

  /// 每个 tab 的 Agent 状态缓存
  final Map<String, AgentState> _tabStates = {};

  /// 每个 tab 的引擎和命令执行器（SSH 或本地 PTY）
  final Map<String, AgentEngine> _tabEngines = {};
  final Map<String, CommandExecutor?> _tabExecutors = {};
  final Map<String, AIModelConfig?> _tabModelConfigs = {};

  /// 每个 tab 是否已收集过系统信息
  final Map<String, bool> _tabSysInfoCollected = {};

  /// 当前活跃的 tabId
  String? _activeTabId;

  /// 当前引擎所属的 tabId（用于回调路由）
  String? _engineTabId;

  AgentNotifier(this._memory) : super(AgentState());

  /// 切换到指定 tab（保存当前状态，加载目标 tab 状态）
  void switchTab(String tabId) {
    // 保存当前 tab 状态
    if (_activeTabId != null) {
      _tabStates[_activeTabId!] = state;
    }

    _activeTabId = tabId;

    // 加载目标 tab 状态（若无则创建新的）
    if (_tabStates.containsKey(tabId)) {
      state = _tabStates[tabId]!;
      _engine = _tabEngines[tabId];
      _executor = _tabExecutors[tabId];
      _modelConfig = _tabModelConfigs[tabId];
    } else {
      // 新 tab：全新空状态，但保留 mode、maxSteps 和模型配置
      final prevMode = state.mode;
      final prevMaxSteps = state.maxSteps;
      final prevModelConfig = _modelConfig;
      state = AgentState(mode: prevMode, maxSteps: prevMaxSteps);
      _engine = null;
      _executor = null;
      _modelConfig = prevModelConfig; // 继承模型配置
      // 为新 tab 初始化引擎
      _reinitEngineForCurrentTab();
    }
  }

  /// 关闭 tab 时清除其状态
  void removeTab(String tabId) {
    _tabStates.remove(tabId);
    _tabEngines.remove(tabId);
    _tabExecutors.remove(tabId);
    _tabModelConfigs.remove(tabId);
    _tabSysInfoCollected.remove(tabId);
    if (_activeTabId == tabId) {
      _activeTabId = null;
    }
  }

  /// 为当前 tab 重新初始化引擎（如果有模型配置）
  void _reinitEngineForCurrentTab() {
    if (_modelConfig != null) {
      final aiProvider = AIService.create(_modelConfig!);
      _engine = AgentEngine(
        aiProvider: aiProvider,
        modelConfig: _modelConfig!,
        memory: _memory,
        maxSteps: state.maxSteps,
      );
      _setupEngineCallbacks(_activeTabId!);
      if (_activeTabId != null) {
        _tabEngines[_activeTabId!] = _engine!;
        _tabModelConfigs[_activeTabId!] = _modelConfig;
      }
    }
  }

  /// tab-aware 状态更新：如果回调所属 tab 是当前活跃 tab，更新 state；
  /// 否则只更新 _tabStates 中的缓存，避免跨 tab 污染
  void _updateTabState(String tabId, AgentState Function(AgentState) updater) {
    if (_activeTabId == tabId) {
      state = updater(state);
    } else if (_tabStates.containsKey(tabId)) {
      _tabStates[tabId] = updater(_tabStates[tabId]!);
    }
  }

  /// 初始化 Agent
  void init({
    required AIModelConfig modelConfig,
    required AIProvider aiProvider,
  }) {
    _modelConfig = modelConfig;
    _engine = AgentEngine(
      aiProvider: aiProvider,
      modelConfig: modelConfig,
      memory: _memory,
      maxSteps: state.maxSteps,
    );

    _setupEngineCallbacks(_activeTabId ?? '');

    // 保存到当前 tab
    if (_activeTabId != null) {
      _tabEngines[_activeTabId!] = _engine!;
      _tabModelConfigs[_activeTabId!] = _modelConfig;
    }
  }

  void _setupEngineCallbacks(String tabId) {
    _engineTabId = tabId;
    _engine!.onThinking = (msg) {
      _updateTabState(tabId, (s) => s.copyWith(status: AgentStatus.thinking));
    };

    _engine!.onMessage = (msg) {
      _updateTabState(tabId, (s) {
        final currentLast = s.lastMessage ?? '';
        final newLast = currentLast + msg;
        final items = [...s.chatItems];
        if (items.isNotEmpty && items.last.role == 'assistant') {
          items[items.length - 1] = ChatItem(
            role: 'assistant',
            content: newLast,
            isStreaming: s.isRunning,
          );
        }
        return s.copyWith(lastMessage: newLast, chatItems: items);
      });
    };

    _engine!.onCommandGenerated = (cmd) {
      _updateTabState(tabId, (s) => s.copyWith(status: AgentStatus.executing));
    };

    _engine!.onCommandExecuted = (result) {
      // 执行结果已通过 onMessage 累积
    };

    _engine!.onError = (error) {
      _updateTabState(tabId, (s) => s.copyWith(error: error));
    };

    _engine!.onTaskUpdated = (task) {
      _updateTabState(tabId, (s) => s.copyWith(currentTask: task, status: task.status));
    };

    _engine!.onCompleted = (fullMessage) {
      _updateTabState(tabId, (s) {
        final items = [...s.chatItems];
        if (items.isNotEmpty && items.last.role == 'assistant') {
          items[items.length - 1] = ChatItem(
            role: 'assistant',
            content: items.last.content,
            isStreaming: false,
          );
        }
        return s.copyWith(chatItems: items);
      });
    };
  }

  /// 设置命令执行器（SSH 或本地 PTY，仅首次连接时收集系统信息）
  void setExecutor(CommandExecutor? executor) {
    _executor = executor;
    if (_activeTabId != null) {
      _tabExecutors[_activeTabId!] = executor;
    }
    if (executor != null && _engine != null) {
      // 每个 tab 只收集一次系统信息
      if (_activeTabId != null && !_tabSysInfoCollected.containsKey(_activeTabId)) {
        _tabSysInfoCollected[_activeTabId!] = true;
        _engine!.collectSystemInfo(executor);
      }
    }
  }

  /// 切换模式
  void toggleMode() {
    final newMode = state.mode == AgentMode.assistant
        ? AgentMode.automatic
        : AgentMode.assistant;
    state = state.copyWith(mode: newMode);
    _engine?.setMode(newMode);
  }

  /// 设置模式
  void setMode(AgentMode mode) {
    state = state.copyWith(mode: mode);
    _engine?.setMode(mode);
  }

  /// 设置最大步骤数
  void setMaxSteps(int steps) {
    state = state.copyWith(maxSteps: steps);
    _engine?.maxSteps = steps;
    // 持久化
    try {
      HiveInit.settingsBox.put('agentMaxSteps', steps);
    } catch (_) {}
  }

  /// 加载设置
  void loadSettings() {
    try {
      final saved = HiveInit.settingsBox.get('agentMaxSteps');
      if (saved != null) {
        final steps = (saved is int) ? saved : (saved as num).toInt();
        state = state.copyWith(maxSteps: steps);
        _engine?.maxSteps = steps;
      }
    } catch (_) {}
  }

  /// 开始任务
  Future<void> startTask(String goal) async {
    if (_engine == null) {
      // 尝试为当前 tab 初始化引擎
      if (_modelConfig != null) {
        _reinitEngineForCurrentTab();
      }
      if (_engine == null) {
        state = state.copyWith(error: '请先配置 AI 模型');
        return;
      }
    }

    // 添加用户消息到 chatItems
    final items = [...state.chatItems, ChatItem(role: 'user', content: goal)];

    state = state.copyWith(
      status: AgentStatus.thinking,
      chatItems: items,
      lastMessage: '',
      currentTask: null,
      error: null,
    );

    // 添加一条空的 AI 消息占位
    final itemsWithAI = [...state.chatItems, ChatItem(role: 'assistant', content: '', isStreaming: true)];
    state = state.copyWith(chatItems: itemsWithAI);

    await _engine!.startTask(goal, _executor);
  }

  /// 取消任务
  void cancel() {
    _engine?.cancelTask();
  }

  /// 确认执行危险命令（辅助模式）
  Future<void> confirmDangerousCommand(String command) async {
    if (_executor != null) {
      state = state.copyWith(status: AgentStatus.executing);
      _executor!.execute(command);
    }
  }

  /// 清空消息
  void clearMessages() {
    state = state.copyWith(chatItems: [], lastMessage: '');
  }

  /// 清空记忆
  Future<void> clearMemory() async {
    await _memory.clear();
    state = state.copyWith(error: null);
  }
}

/// Provider
final agentMemoryProvider = Provider<AgentMemory>((ref) {
  return AgentMemory();
});

final agentProvider = StateNotifierProvider<AgentNotifier, AgentState>((ref) {
  final memory = ref.watch(agentMemoryProvider);
  return AgentNotifier(memory);
});
