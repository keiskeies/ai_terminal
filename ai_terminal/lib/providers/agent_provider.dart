import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/agent_model.dart';
import '../models/agent_event.dart';
import '../models/agent_memory.dart';
import '../models/ai_model_config.dart';
import '../models/conversation.dart';
import '../services/agent_engine.dart';
import '../services/ai_service.dart';
import '../services/command_executor.dart';
import '../services/conversation_service.dart';
import '../utils/react_stream_parser.dart';
import '../core/hive_init.dart';

/// 流式更新节流间隔（毫秒）
const int _agentStreamThrottleMs = 80;

/// 自动压缩阈值：超过 20 轮（40 条 user+assistant）或 30k 字符触发压缩
const int _compactThresholdRounds = 20;
const int _compactThresholdChars = 30000;
/// 压缩后保留的最近原文轮数
const int _compactKeepRounds = 6;

/// Agent 状态
class AgentState {
  final AgentStatus status;
  final AgentTask? currentTask;
  final String? lastMessage;
  final List<ChatItem> chatItems; // 统一的消息列表，包含用户和AI消息
  final String? error;
  final int maxSteps;
  final String? pendingConfirmCommand; // 等待用户确认的危险命令
  final List<String> pendingOptions; // 等待用户选择的选项
  /// 当前会话所属 hostId（'local' 或服务器 id），用于持久化隔离
  final String? hostId;
  /// 当前会话 id（Conversation.id）
  final String? conversationId;
  /// 早期对话摘要（压缩后产生，显示在 UI 上让用户感知）
  final String? summary;
  /// 是否正在压缩
  final bool isCompacting;

  AgentState({
    this.status = AgentStatus.idle,
    this.currentTask,
    this.lastMessage,
    List<ChatItem>? chatItems,
    this.error,
    this.maxSteps = 0,
    this.pendingConfirmCommand,
    List<String>? pendingOptions,
    this.hostId,
    this.conversationId,
    this.summary,
    this.isCompacting = false,
  })  : chatItems = chatItems ?? [],
        pendingOptions = pendingOptions ?? [];

  bool get isRunning =>
      status == AgentStatus.thinking || status == AgentStatus.executing;
  bool get isWaitingConfirm => status == AgentStatus.waitingConfirm && pendingConfirmCommand != null;
  bool get isWaitingChoice => status == AgentStatus.waitingConfirm && pendingOptions.isNotEmpty;

  AgentState copyWith({
    AgentStatus? status,
    AgentTask? currentTask,
    String? lastMessage,
    List<ChatItem>? chatItems,
    String? error,
    int? maxSteps,
    String? pendingConfirmCommand,
    List<String>? pendingOptions,
    String? hostId,
    String? conversationId,
    String? summary,
    bool? isCompacting,
    bool clearPendingConfirm = false,
    bool clearPendingOptions = false,
    bool clearHostId = false,
    bool clearConversationId = false,
    bool clearSummary = false,
  }) {
    return AgentState(
      status: status ?? this.status,
      currentTask: currentTask ?? this.currentTask,
      lastMessage: lastMessage ?? this.lastMessage,
      chatItems: chatItems ?? this.chatItems,
      error: error,
      maxSteps: maxSteps ?? this.maxSteps,
      pendingConfirmCommand: clearPendingConfirm ? null : (pendingConfirmCommand ?? this.pendingConfirmCommand),
      pendingOptions: clearPendingOptions ? [] : (pendingOptions ?? this.pendingOptions),
      hostId: clearHostId ? null : (hostId ?? this.hostId),
      conversationId: clearConversationId ? null : (conversationId ?? this.conversationId),
      summary: clearSummary ? null : (summary ?? this.summary),
      isCompacting: isCompacting ?? this.isCompacting,
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
        if (pendingOptions.isNotEmpty) return '⏳ 等待选择';
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
  /// 关联的命令（若该消息对应一条执行的命令）
  final String? command;
  final bool? commandSuccess;
  /// 结构化事件列表（仅 assistant 消息有）
  /// 流式过程中实时更新，UI 按事件类型分别渲染卡片
  final List<AgentEvent> events;
  /// 当前这一轮流式中尚未解析为事件的增量文本
  /// 流式过程中：events（已完成步骤） + streamingContent（正在生成）
  /// 流式结束后：新内容解析为 events 追加，streamingContent 清空
  final String streamingContent;

  ChatItem({
    required this.role,
    required this.content,
    this.isStreaming = false,
    this.command,
    this.commandSuccess,
    List<AgentEvent>? events,
    this.streamingContent = '',
  }) : events = events ?? [];

  ChatItem copyWith({
    String? role,
    String? content,
    bool? isStreaming,
    String? command,
    bool? commandSuccess,
    List<AgentEvent>? events,
    String? streamingContent,
  }) {
    return ChatItem(
      role: role ?? this.role,
      content: content ?? this.content,
      isStreaming: isStreaming ?? this.isStreaming,
      command: command ?? this.command,
      commandSuccess: commandSuccess ?? this.commandSuccess,
      events: events ?? this.events,
      streamingContent: streamingContent ?? this.streamingContent,
    );
  }

  /// 从持久化的 ConvMessage 转换，优先使用存储的 events，否则重新解析
  factory ChatItem.fromConvMessage(ConvMessage msg) {
    List<AgentEvent> events = const [];
    if (msg.role == 'assistant') {
      // 优先使用存储的 events（包含执行结果等）
      if (msg.events != null && msg.events!.isNotEmpty) {
        events = msg.events!;
      } else if (msg.content.trim().isNotEmpty) {
        // 旧数据没有 events 时，fallback 到重新解析
        try {
          events = ReActStreamParser.parse(msg.content);
        } catch (_) {}
      }
    }
    return ChatItem(
      role: msg.role,
      content: msg.content,
      command: msg.command,
      commandSuccess: msg.commandSuccess,
      events: events,
    );
  }
}

/// Agent Provider — 每个 hostId 独立 Agent 状态和记忆（持久化）
class AgentNotifier extends StateNotifier<AgentState> {
  AgentEngine? _engine;
  CommandExecutor? _executor;
  AIModelConfig? _modelConfig;

  /// 每个 hostId 的 Agent 状态缓存（运行时）
  final Map<String, AgentState> _hostStates = {};

  /// 每个 hostId 的引擎和命令执行器
  final Map<String, AgentEngine> _hostEngines = {};
  final Map<String, CommandExecutor?> _hostExecutors = {};
  final Map<String, AIModelConfig?> _hostModelConfigs = {};

  /// 每个 hostId 独立的记忆实例
  final Map<String, AgentMemory> _hostMemories = {};

  /// 每个 hostId 的系统信息收集 Future（用于等待收集完成）
  final Map<String, Future<void>> _hostSysInfoFutures = {};

  /// 当前活跃的 hostId
  String? _activeHostId;

  /// 当前引擎所属的 hostId（用于回调路由）
  String? _engineHostId;

  /// 每 hostId 的流式累积内容
  final Map<String, String> _hostStreamingContent = {};

  /// 流式输出节流
  Timer? _throttleTimer;

  final ConversationService _convService = ConversationService();

  /// 日志订阅取消函数
  void Function()? _logUnsubscribe;

  AgentNotifier() : super(AgentState()) {
    // 订阅 AgentLogger，将日志写入当前活跃 host 的会话
    _logUnsubscribe = agentLogger.subscribe((level, tag, message, timestamp) {
      final hostId = _activeHostId;
      if (hostId == null) return;
      // 异步写入，不阻塞日志主流程
      _convService.appendAgentLog(hostId, level: level, tag: tag, message: message).catchError((_) {});
    });
  }

  /// 获取当前 host 的记忆实例（不存在则创建）
  AgentMemory _getMemory(String hostId) {
    return _hostMemories.putIfAbsent(hostId, () => AgentMemory());
  }

  /// 切换到指定 host（保存当前状态，加载目标 host 状态）
  /// [tabId] 保留兼容旧调用，实际用 hostId 隔离
  void switchTab(String tabId, {String? hostId}) {
    final effectiveHostId = hostId ?? 'local';

    // 保存当前 host 状态
    if (_activeHostId != null) {
      _hostStates[_activeHostId!] = state;
    }

    _activeHostId = effectiveHostId;

    // 加载目标 host 状态：先从内存缓存读，再从持久化恢复
    if (_hostStates.containsKey(effectiveHostId)) {
      state = _hostStates[effectiveHostId]!;
      _engine = _hostEngines[effectiveHostId];
      _executor = _hostExecutors[effectiveHostId];
      _modelConfig = _hostModelConfigs[effectiveHostId];
    } else {
      // 新 host：从持久化恢复，或创建新会话
      _restoreFromPersistence(effectiveHostId);
      _engine = null;
      _executor = null;
      _modelConfig = _modelConfig; // 保留默认模型配置
      _reinitEngineForCurrentHost();
    }
  }

  /// 从持久化恢复会话到内存状态
  void _restoreFromPersistence(String hostId) {
    final conv = _convService.getActiveSession(hostId);
    if (conv == null) {
      state = AgentState(hostId: hostId, maxSteps: state.maxSteps);
      return;
    }
    final items = conv.messages
        .where((m) => m.role != 'system')
        .map((m) => ChatItem.fromConvMessage(m))
        .toList();
    state = AgentState(
      hostId: hostId,
      conversationId: conv.id,
      chatItems: items,
      summary: conv.summary,
      maxSteps: state.maxSteps,
    );
  }

  /// 关闭 tab/host 时清除其状态和记忆
  void removeTab(String tabId, {String? hostId}) {
    // 旧接口兼容：tabId 不再用于状态隔离，仅清理可能的引用
    if (hostId != null) {
      _hostStates.remove(hostId);
      _hostEngines.remove(hostId);
      _hostExecutors.remove(hostId);
      _hostModelConfigs.remove(hostId);
      _hostMemories.remove(hostId);
      _hostStreamingContent.remove(hostId);
      _hostSysInfoFutures.remove(hostId);
    }
    if (_activeHostId == hostId) {
      _activeHostId = null;
    }
  }

  /// 为当前 host 重新初始化引擎（如果有模型配置）
  void _reinitEngineForCurrentHost() {
    final hostId = _activeHostId;
    if (_modelConfig != null && hostId != null) {
      final memory = _getMemory(hostId);
      final aiProvider = AIService.create(_modelConfig!);
      _engine = AgentEngine(
        aiProvider: aiProvider,
        modelConfig: _modelConfig!,
        memory: memory,
        maxSteps: state.maxSteps,
      );
      _setupEngineCallbacks(hostId);
      _hostEngines[hostId] = _engine!;
      _hostModelConfigs[hostId] = _modelConfig;
    }
  }

  /// tab-aware 状态更新：如果回调所属 host 是当前活跃 host，更新 state；
  /// 否则只更新 _hostStates 中的缓存，避免跨 host 污染
  void _updateHostState(String hostId, AgentState Function(AgentState) updater) {
    if (_activeHostId == hostId) {
      state = updater(state);
    } else if (_hostStates.containsKey(hostId)) {
      _hostStates[hostId] = updater(_hostStates[hostId]!);
    }
  }

  /// 初始化 Agent
  void init({
    required AIModelConfig modelConfig,
    required AIProvider aiProvider,
  }) {
    _modelConfig = modelConfig;

    final hostId = _activeHostId ?? 'local';
    final memory = _getMemory(hostId);

    _engine = AgentEngine(
      aiProvider: aiProvider,
      modelConfig: modelConfig,
      memory: memory,
      maxSteps: state.maxSteps,
    );

    _setupEngineCallbacks(hostId);

    // 保存到当前 host
    if (_activeHostId != null) {
      _hostEngines[_activeHostId!] = _engine!;
      _hostModelConfigs[_activeHostId!] = _modelConfig;
    }
  }

  void _setupEngineCallbacks(String hostId) {
    _engineHostId = hostId;
    _engine!.onThinking = (msg) {
      // 新一轮 AI 流式开始：先把上一轮的 streamingContent 累积到 content 并保存
      _flushStreamingToContent(hostId);
      _hostStreamingContent[hostId] = '';
      _updateHostState(hostId, (s) {
        final items = [...s.chatItems];
        if (items.isNotEmpty && items.last.role == 'assistant') {
          items[items.length - 1] = items.last.copyWith(
            isStreaming: true,
            streamingContent: '',
          );
        }
        return s.copyWith(status: AgentStatus.thinking, chatItems: items);
      });
    };

    _engine!.onMessage = (msg) {
      _hostStreamingContent[hostId] = (_hostStreamingContent[hostId] ?? '') + msg;
      _throttleTimer ??= Timer(
        const Duration(milliseconds: _agentStreamThrottleMs),
        () {
          _throttleTimer = null;
          final content = _hostStreamingContent[hostId];
          if (content != null) {
            _updateHostState(hostId, (s) {
              final items = [...s.chatItems];
              if (items.isNotEmpty && items.last.role == 'assistant') {
                items[items.length - 1] = items.last.copyWith(
                  streamingContent: content,
                  isStreaming: true,
                );
              }
              return s.copyWith(lastMessage: content, chatItems: items);
            });
          }
        },
      );
    };

    /// 结构化事件回调：追加事件（不清空 streamingContent，避免流式过程中闪烁）
    _engine!.onEvent = (event) {
      _updateHostState(hostId, (s) {
        final items = [...s.chatItems];
        if (items.isEmpty || items.last.role != 'assistant') return s;
        final lastItem = items.last;
        final events = [...lastItem.events, event];
        items[items.length - 1] = lastItem.copyWith(
          events: events,
          isStreaming: s.isRunning,
        );
        return s.copyWith(chatItems: items);
      });
    };

    _engine!.onCommandGenerated = (cmd) {
      _updateHostState(hostId, (s) => s.copyWith(status: AgentStatus.executing));
    };

    _engine!.onCommandExecuted = (result) {
      // 执行结果已通过 onEvent(AgentEvent.result) 处理
    };

    _engine!.onError = (error) {
      // 出错时也保存当前内容
      _flushStreamingToContent(hostId);
      _updateHostState(hostId, (s) => s.copyWith(error: error));
    };

    _engine!.onTaskUpdated = (task) {
      _updateHostState(hostId, (s) => s.copyWith(
        currentTask: task,
        status: task.status,
        pendingConfirmCommand: _engine!.pendingConfirmCommand,
        pendingOptions: _engine!.pendingOptions.isNotEmpty ? _engine!.pendingOptions : null,
        clearPendingOptions: _engine!.pendingOptions.isEmpty,
      ));
    };

    _engine!.onCompleted = (fullMessage) {
      // 任务完成：累积最后一轮内容并保存
      _flushStreamingToContent(hostId);
      _updateHostState(hostId, (s) {
        final items = [...s.chatItems];
        if (items.isNotEmpty && items.last.role == 'assistant') {
          final lastItem = items.last;
          items[items.length - 1] = ChatItem(
            role: 'assistant',
            content: lastItem.content,
            isStreaming: false,
            events: lastItem.events,
          );
          // 最后再保存一次（确保 finish 等事件也被持久化）
          _persistAssistantCompletion(hostId, lastItem.content, events: lastItem.events);
        }
        return s.copyWith(chatItems: items);
      });
    };
  }

  /// 将当前流式内容累积到 content 中，并持久化保存
  void _flushStreamingToContent(String hostId) {
    final streamingContent = _hostStreamingContent[hostId];
    if (streamingContent == null || streamingContent.isEmpty) return;

    _updateHostState(hostId, (s) {
      final items = [...s.chatItems];
      if (items.isEmpty || items.last.role != 'assistant') return s;
      final lastItem = items.last;
      final newContent = lastItem.content + streamingContent;
      items[items.length - 1] = lastItem.copyWith(
        content: newContent,
        streamingContent: '',
      );
      // 持久化保存（含 events）
      _persistAssistantCompletion(hostId, newContent, events: lastItem.events);
      return s.copyWith(chatItems: items);
    });

    _hostStreamingContent[hostId] = '';
  }

  /// 持久化 assistant 完整响应（流式结束后回写）
  Future<void> _persistAssistantCompletion(
    String hostId,
    String content, {
    List<AgentEvent>? events,
  }) async {
    try {
      await _convService.updateLastAssistantContent(hostId, content, events: events);
    } catch (_) {}
  }

  /// 设置命令执行器（SSH 或本地 PTY，仅首次连接时收集系统信息）
  void setExecutor(CommandExecutor? executor) {
    _executor = executor;
    if (_activeHostId != null) {
      _hostExecutors[_activeHostId!] = executor;
    }
    if (executor != null && _engine != null) {
      final hostId = _activeHostId;
      if (hostId != null && !_hostSysInfoFutures.containsKey(hostId)) {
        _hostSysInfoFutures[hostId] = _engine!.collectSystemInfo(executor);
      }
    }
  }

  /// 设置最大步骤数
  void setMaxSteps(int steps) {
    state = state.copyWith(maxSteps: steps);
    _engine?.maxSteps = steps;
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
      if (_modelConfig != null) {
        _reinitEngineForCurrentHost();
      }
      if (_engine == null) {
        state = state.copyWith(error: '请先配置 AI 模型');
        return;
      }
    }

    final hostId = _activeHostId ?? 'local';
    _hostStreamingContent[hostId] = '';
    _throttleTimer?.cancel();
    _throttleTimer = null;

    // 持久化用户消息
    try {
      final conv = await _convService.appendMessage(hostId, role: 'user', content: goal);
      // 同步会话 id 到 state（首次创建时）
      if (state.conversationId != conv.id) {
        state = state.copyWith(conversationId: conv.id, hostId: hostId);
      }
    } catch (_) {}

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

    // 持久化 assistant 占位（流式过程中通过 onMessage 累积，结束时回写完整内容）
    try {
      await _convService.appendMessage(hostId, role: 'assistant', content: '');
    } catch (_) {}

    // 如果系统信息还没收集，先收集再开始任务，避免命令混在一起
    if (_executor != null && !_hostSysInfoFutures.containsKey(hostId)) {
      _hostSysInfoFutures[hostId] = _engine!.collectSystemInfo(_executor!);
    }
    final sysInfoFuture = _hostSysInfoFutures[hostId];
    if (sysInfoFuture != null) {
      await sysInfoFuture;
    }

    await _engine!.startTask(goal, _executor);

    // 任务结束后检查是否需要自动压缩
    _maybeAutoCompact();
  }

  /// 取消任务
  void cancel() {
    // 取消前先保存当前内容
    final hostId = _engineHostId;
    if (hostId != null) {
      _flushStreamingToContent(hostId);
    }
    _engine?.cancelTask();
  }

  /// 确认执行危险命令（自动模式）
  void confirmCommand() {
    if (_engine != null && _engine!.hasPendingConfirm) {
      _engine!.confirmDangerousCommand();
      _updateHostState(_engineHostId ?? '', (s) => s.copyWith(
        status: AgentStatus.executing,
        clearPendingConfirm: true,
      ));
    }
  }

  /// 拒绝执行危险命令（自动模式）
  void rejectCommand() {
    if (_engine != null && _engine!.hasPendingConfirm) {
      _engine!.rejectDangerousCommand();
      _updateHostState(_engineHostId ?? '', (s) => s.copyWith(
        status: AgentStatus.thinking,
        clearPendingConfirm: true,
      ));
    }
  }

  /// 用户选择选项
  void selectChoice(String choice) {
    if (_engine != null && _engine!.hasPendingChoice) {
      _engine!.selectChoice(choice);
      _updateHostState(_engineHostId ?? '', (s) => s.copyWith(
        status: AgentStatus.thinking,
        clearPendingOptions: true,
      ));
    }
  }

  /// 清空消息（同时清除引擎对话历史 + 持久化）
  Future<void> clearMessages() async {
    _engine?.clearHistory();
    final hostId = _activeHostId;
    final convId = state.conversationId;
    state = state.copyWith(chatItems: [], lastMessage: '', clearSummary: true);
    if (hostId != null && convId != null) {
      try {
        await _convService.clearMessages(convId);
      } catch (_) {}
    }
  }

  /// 清空当前 host 的记忆
  void clearMemory() {
    if (_activeHostId != null) {
      _getMemory(_activeHostId!).clear();
    }
    state = state.copyWith(error: null);
  }

  // ═══════════════════════════════════════════
  // 会话管理（侧边栏调用）
  // ═══════════════════════════════════════════

  /// 新建会话（结束当前会话，创建空白会话）
  Future<void> newSession() async {
    final hostId = _activeHostId;
    if (hostId == null) return;
    _engine?.clearHistory();
    final conv = _convService.createSession(hostId: hostId);
    _hostStreamingContent[hostId] = '';
    state = AgentState(
      hostId: hostId,
      conversationId: conv.id,
      maxSteps: state.maxSteps,
    );
  }

  /// 切换到指定会话（侧边栏点击）
  Future<void> switchSession(String conversationId) async {
    final hostId = _activeHostId;
    if (hostId == null) return;
    _convService.setActive(hostId, conversationId);
    _engine?.clearHistory();
    _restoreFromPersistence(hostId);
  }

  /// 重命名会话
  Future<void> renameSession(String conversationId, String title) async {
    await _convService.rename(conversationId, title);
  }

  /// 删除会话
  Future<void> deleteSession(String conversationId) async {
    await _convService.delete(conversationId);
    // 如果删除的是当前会话，切到最近的会话或新建
    if (state.conversationId == conversationId) {
      final hostId = _activeHostId;
      if (hostId != null) {
        final sessions = _convService.listSessions(hostId);
        if (sessions.isEmpty) {
          await newSession();
        } else {
          await switchSession(sessions.first.id);
        }
      }
    }
  }

  /// 获取当前 host 的所有会话列表（侧边栏用）
  List<Conversation> listSessions() {
    final hostId = _activeHostId;
    if (hostId == null) return [];
    return _convService.listSessions(hostId);
  }

  // ═══════════════════════════════════════════
  // 记忆压缩
  // ═══════════════════════════════════════════

  /// 判断是否需要自动压缩（任务结束后调用）
  void _maybeAutoCompact() {
    final hostId = _activeHostId;
    if (hostId == null) return;
    final convId = state.conversationId;
    if (convId == null) return;

    final conv = HiveInit.conversationsBox.get(convId);
    if (conv == null) return;

    final rounds = conv.messages.where((m) => m.role != 'system').length ~/ 2;
    final needsCompact = rounds >= _compactThresholdRounds || conv.totalChars >= _compactThresholdChars;
    if (needsCompact && !state.isCompacting) {
      compact().catchError((_) {});
    }
  }

  /// 手动/自动压缩：用 AI 总结早期对话为摘要，保留最近 N 轮原文
  Future<void> compact() async {
    final hostId = _activeHostId;
    final convId = state.conversationId;
    if (hostId == null || convId == null || _engine == null) return;

    final conv = HiveInit.conversationsBox.get(convId);
    if (conv == null) return;

    // 待压缩 = 已摘要后所有消息 - 保留的最近 N 轮
    final allMsgs = conv.messages.where((m) => m.role != 'system').toList();
    final keepCount = _compactKeepRounds * 2;
    if (allMsgs.length <= keepCount) return; // 太少不压缩

    final toSummarize = allMsgs.sublist(0, allMsgs.length - keepCount);
    if (toSummarize.isEmpty) return;

    state = state.copyWith(isCompacting: true);
    try {
      // 转换 ConvMessage 为元组列表传给 engine
      final tuples = toSummarize
          .map((m) => (role: m.role, content: m.content))
          .toList();
      final summaryText = await _engine!.summarize(tuples);
      if (summaryText != null && summaryText.isNotEmpty) {
        await _convService.applySummary(convId, summaryText);
        // 同步到 UI 状态
        final restored = HiveInit.conversationsBox.get(convId);
        if (restored != null) {
          final items = restored.messages
              .where((m) => m.role != 'system')
              .map((m) => ChatItem.fromConvMessage(m))
              .toList();
          state = state.copyWith(
            chatItems: items,
            summary: restored.summary,
            isCompacting: false,
          );
        } else {
          state = state.copyWith(isCompacting: false);
        }
      } else {
        state = state.copyWith(isCompacting: false);
      }
    } catch (_) {
      state = state.copyWith(isCompacting: false);
    }
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _logUnsubscribe?.call();
    super.dispose();
  }
}

/// Provider
final agentProvider = StateNotifierProvider<AgentNotifier, AgentState>((ref) {
  return AgentNotifier();
});
