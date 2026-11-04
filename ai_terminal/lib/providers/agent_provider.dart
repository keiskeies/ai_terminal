import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/agent_model.dart';
import '../models/agent_event.dart';
import '../models/agent_memory.dart';
import '../models/agent_goal.dart';
import '../models/ai_model_config.dart';
import '../models/chat_session.dart';
import '../models/conversation.dart';
import '../services/agent_engine.dart';
import '../services/agent_host_registry.dart';
import '../services/agent_stream_reducer.dart';
import '../services/ai_service.dart';
import '../services/ai_model_selection_service.dart';
import '../services/command_executor.dart';
import '../services/conversation_service.dart';
import '../services/knowledge_service.dart';
import '../core/credentials_store.dart';
import '../services/daos.dart';
import '../utils/goal_continuation.dart';
import '../core/l10n_holder.dart';
import '../models/agent_state.dart';
import '../models/chat_item.dart';
export '../models/agent_state.dart';
export '../models/chat_item.dart';

/// 流式更新节流间隔（毫秒）
const int _agentStreamThrottleMs = 80;

/// 自动压缩阈值：超过 20 轮（40 条 user+assistant）或 30k 字符触发压缩
const int _compactThresholdRounds = 20;
const int _compactThresholdChars = 30000;

/// 压缩后保留的最近原文轮数
const int _compactKeepRounds = 6;

/// Agent Provider — 每个 hostId 独立 Agent 状态和记忆（持久化）
class AgentNotifier extends StateNotifier<AgentState> {
  AgentEngine? _engine;
  CommandExecutor? _executor;
  AIModelConfig? _modelConfig;

  /// 多 host 状态注册表：管理每个 host 的状态、引擎、执行器、记忆等
  final AgentHostRegistry _registry = AgentHostRegistry();

  /// 流式内容 reducer：管理每个 host 的流式累积和节流
  final AgentStreamReducer _reducer = AgentStreamReducer();

  /// 每个 host 上次持久化的 assistant 内容长度，用于控制流式过程定期刷盘频率
  final Map<String, int> _lastPersistedLen = {};

  /// 每个 host 的持久化写入链：串行化 save 操作，防止并发写入导致事件丢失
  /// 解决 onEvent 中 fire-and-forget 持久化的竞态问题
  final Map<String, Future<void>> _persistChain = {};

  /// 正在启动任务的 tab：防止同一 tab 在异步落盘窗口内重复发任务
  final Set<String> _startingScopes = {};

  /// 正在被某个 tab 启动任务的会话：两个 tab 共享同一会话查看时，必须串行使用
  final Map<String, String> _startingConversations = {};

  /// 启动窗口内用户已点过停止的 tab。
  /// 此时 state 已显示"运行中"、但 engine.startTask 还没真正执行，
  /// engine.cancelTask() 会因 _currentTask==null 变成 no-op；必须记住意图，
  /// 让 startTask 在每个 await 之后放弃启动。
  final Set<String> _cancelRequestedScopes = {};

  /// 当前引擎所属的 scopeId（终端 tab id，用于回调路由）
  String? _engineScopeId;

  /// 由 UI（terminal_page）注入：弹出掩码输入框向用户索取一个秘密（如 sudo 密码）。
  /// 返回 null 表示取消。
  ///
  /// 明文只经由引擎写进安全存储，不经过 Notifier、state、对话历史与审计日志
  /// （AGENTS.md R7）—— 所以这里只透传回调，Notifier 自己也不留副本。
  Future<String?> Function(String title, String message)? secretRequestHandler;

  final ConversationService _convService = ConversationService();

  /// 日志订阅取消函数
  void Function()? _logUnsubscribe;

  AgentNotifier() : super(AgentState()) {
    _loadStoredGoals();
    // 订阅 AgentLogger，将日志写入产生日志时的 hostId 会话（避免多 host 串台）
    _logUnsubscribe = agentLogger.subscribe(
        (level, tag, message, timestamp, hostId, conversationId) {
      // 任务日志优先按任务开始时的会话路由：同 host 多 tab 并行时
      // hostId 相同，只有 conversationId 能区分各自该写哪个会话。
      final effectiveHostId =
          hostId ?? _registry.getHostId(_registry.activeScopeId ?? '');
      if (conversationId == null && effectiveHostId == null) return;
      _convService
          .appendAgentLog(
            effectiveHostId ?? 'local',
            level: level,
            tag: tag,
            message: message,
            conversationId: conversationId,
          )
          .catchError((e) {
        debugPrint('[AgentNotifier] 日志写入失败: $e');
      });
    });
  }

  /// 获取当前 tab（scope）的记忆实例（不存在则创建）
  AgentMemory _getMemory(String scopeId) {
    var memory = _registry.getMemory(scopeId);
    if (memory == null) {
      memory = AgentMemory();
      _registry.setMemory(scopeId, memory);
    }
    return memory;
  }

  /// 从安全存储加载 sudo 密码并注入到指定 engine
  /// R3: 传入 engine 实例避免 tab 切换后写到错误的 engine
  void _loadSudoPasswordForHost(String hostId, AgentEngine engine) {
    Future.microtask(() async {
      try {
        final sudoPassword = await CredentialsStore.get(
          hostId: hostId,
          type: 'sudoPassword',
        );
        engine.setSudoPassword(sudoPassword);
      } catch (e) {
        debugPrint('[AgentNotifier] 加载 sudo 密码失败 (hostId=$hostId): $e');
      }
    });
  }

  /// 切换到指定 tab。
  ///
  /// 状态按 **tabId（scope）** 隔离，而不是 hostId。这样同一服务器打开两个
  /// tab 时，第二个 tab 不会加载第一个 tab 正在执行的 Agent，也不会被共享
  /// 引擎的 isRunning 拦住。
  ///
  /// 保留原有安全边界：切换到**另一台服务器**时取消当前任务，避免用户在
  /// 没看的机器上继续自动执行；同一服务器的另一个 tab 则允许并行运行。
  void switchTab(String tabId, {String? hostId}) {
    final scopeId = tabId.isNotEmpty ? tabId : (hostId ?? 'local');
    final targetHost = hostId ?? 'local';
    final oldScopeId = _registry.activeScopeId;

    // R3: 离开当前 tab 时，只有切换到不同服务器才取消任务。
    // 同 host 多 tab 是本次要支持的核心场景：旧 tab 的 Agent 继续跑，
    // 它的回调仍绑定在旧 scope 上，写 registry 缓存而不是新 tab 的 state。
    if (oldScopeId != null && oldScopeId != scopeId) {
      final oldHost =
          _registry.getHostId(oldScopeId) ?? state.hostId ?? targetHost;
      if (oldHost != targetHost) {
        // 离开一台服务器时，取消该服务器上**所有** tab 的任务，而不是只取消
        // 当前 tab。同 host 多 tab 允许并行，但用户已经切到另一台机器后，
        // 继续在旧机器上自动执行会变成“背着他动手”（AGENTS.md R3）。
        final scopesToCancel =
            _registry.scopesForHost(oldHost).toSet()
              ..add(oldScopeId);
        for (final scope in scopesToCancel) {
          final oldEngine =
              _registry.getEngine(scope) ?? (scope == oldScopeId ? _engine : null);
          if (oldEngine != null && oldEngine.isRunning) {
            // R2: 先 flush 流式内容到 content，再清空回调
            // 否则清空回调后 cancelTask 中的 onCompleted 是 null，不会触发 _flushStreamingToContent，
            // _reducer.reset 会直接丢弃 streamingContent，导致切走 tab 时正在流式输出的内容丢失
            _flushStreamingToContent(scope);
            // R2: 先清空回调再 cancel，避免 cancelTask 触发的 onTaskUpdated/onEvent 写到新 tab state
            _clearEngineCallbacks(oldEngine);
            oldEngine.cancelTask();
            // 回调已清空，cancelTask 不会再通知 UI；这里主动把该 tab 状态收尾
            _applyCancelledState(scope, oldEngine);
          }
          _reducer.cancelTimer(scope);
          _reducer.reset(scope);
        }
      }
    }

    // 保存当前 tab 状态
    _registry.saveActiveState(state);

    _registry.setScopeHost(scopeId, targetHost);
    _registry.setActive(scopeId);
    _engineScopeId = scopeId;
    // 同步日志路由的 hostId，避免多 host 串台
    agentLogger.currentHostId = targetHost;

    // 加载目标 tab 状态：先从内存缓存读，再从持久化恢复
    if (_registry.hasState(scopeId)) {
      state = _registry.getState(scopeId)!;
      _engine = _registry.getEngine(scopeId);
      _executor = _registry.getScopeExecutor(scopeId);
      _modelConfig = _registry.getModelConfig(scopeId) ?? _modelConfig;
      // R2: 切走时清空了旧 engine 的回调，切回来必须重新绑定
      // 否则 engine 收到事件后无法通知 UI，导致任务运行但 UI 不更新
      if (_engine != null) {
        _setupEngineCallbacks(scopeId, _engine!);
      } else if (_modelConfig != null) {
        _reinitEngineForScope(scopeId);
      }
    } else {
      // 新 tab：若同 host 已有 Agent 正在执行，必须开新会话，不能把
      // 运行中的任务和会话加载进来（否则第二个 tab 无法发新任务）。
      final startFresh = _hasRunningAgentForHost(targetHost);
      _restoreFromPersistence(scopeId, targetHost, startFresh: startFresh);
      _engine = null;
      _executor = null;
      // 恢复该 host 的模型配置，或保留当前全局配置
      _modelConfig =
          _registry.getModelConfigForHost(targetHost) ?? _modelConfig;
      _reinitEngineForScope(scopeId);
    }

    // R3: 编排模式状态同步 — 确保 engine 的编排开关与 state.isOrchestratorMode 一致
    // 防止 engine 被重新初始化后编排标志丢失，但 state 仍为 true 的不一致情况
    _syncOrchestratorMode();
  }

  /// 同 host 是否已有 Agent 在另一 tab 中执行。
  /// 活跃 tab 的状态已由 [switchTab] 在调用前保存进 registry，因此这里能
  /// 同时覆盖活跃与非活跃 tab。
  bool _hasRunningAgentForHost(String hostId) {
    for (final scopeId in _registry.scopesForHost(hostId)) {
      if (_isEngineBusy(_registry.getEngine(scopeId))) return true;
      if (_isStateBusy(_registry.getState(scopeId))) return true;
    }
    return false;
  }

  /// 暂停中的任务也算“占着会话”：恢复后会继续写同一个会话，不能让
  /// 另一个 tab 在这期间拿同一会话跑新任务。
  bool _isEngineBusy(AgentEngine? engine) =>
      engine != null && (engine.isRunning || engine.isPaused);

  bool _isStateBusy(AgentState? state) =>
      state != null &&
      (state.isRunning ||
          state.status == AgentStatus.waitingConfirm ||
          state.status == AgentStatus.paused);

  /// R2/R3: 统一清空引擎回调，供切 tab / 移除 tab / dispose 使用
  void _clearEngineCallbacks(AgentEngine engine) {
    engine.onMessage = null;
    engine.onThinking = null;
    engine.onEvent = null;
    engine.onCommandGenerated = null;
    engine.onCommandExecuted = null;
    engine.onError = null;
    engine.onTaskUpdated = null;
    engine.onCompleted = null;
  }

  /// 回调已清空后再 cancel 的兜底收尾：不依赖 engine 回调，直接把该 tab
  /// 的状态置为 cancelled 并结束流式光标，避免切回来看到“仍在运行”。
  void _applyCancelledState(String scopeId, AgentEngine engine) {
    _updateScopeState(scopeId, (s) {
      final items = [...s.chatItems];
      if (items.isNotEmpty && items.last.role == 'assistant') {
        final lastItem = items.last;
        final newContent = lastItem.content.isEmpty
            ? L10n.str.taskCancelled
            : lastItem.content;
        items[items.length - 1] = lastItem.copyWith(
          content: newContent,
          streamingContent: '',
          isStreaming: false,
        );
        if (lastItem.content != newContent) {
          _persistAssistantCompletion(scopeId, newContent,
              events: lastItem.events);
        }
      }
      return s.copyWith(
        status: AgentStatus.cancelled,
        currentTask: engine.currentTask,
        chatItems: items,
        clearPendingConfirm: true,
        clearPendingOptions: true,
        clearError: true,
      );
    });
  }

  /// 同步编排模式：让 engine 的 _orchestratorMode 与 state.isOrchestratorMode 保持一致
  void _syncOrchestratorMode() {
    if (_engine == null) return;
    if (state.isOrchestratorMode && !_engine!.isOrchestratorMode) {
      _engine!.enableOrchestrator(_registry);
    } else if (!state.isOrchestratorMode && _engine!.isOrchestratorMode) {
      _engine!.disableOrchestrator();
    }
    // 同步只读模式
    _engine!.setReadOnlyMode(state.isReadOnlyMode);
    // 同步联网搜索会话级开关
    _engine!.setWebSearchEnabled(state.isWebSearchEnabled);
  }

  /// 从持久化恢复会话到内存状态。
  ///
  /// [startFresh] 为 true 时不加载 host 的 active 会话，直接得到一个空白
  /// 会话（conversationId 为 null，首次发任务时才创建），用于同 host 已有
  /// Agent 正在执行的场景。
  void _restoreFromPersistence(
    String scopeId,
    String hostId, {
    required bool startFresh,
  }) {
    if (startFresh) {
      state = AgentState(
        hostId: hostId,
        maxSteps: state.maxSteps,
        aiTimeoutSeconds: state.aiTimeoutSeconds,
      );
      return;
    }

    final conv = _convService.getActiveSession(hostId);
    if (conv == null) {
      state = AgentState(
        hostId: hostId,
        maxSteps: state.maxSteps,
        aiTimeoutSeconds: state.aiTimeoutSeconds,
      );
      return;
    }
    debugPrint(
        '[AgentNotifier] _restoreFromPersistence: scope=$scopeId hostId=$hostId messages=${conv.messages.length}');
    for (final m in conv.messages) {
      debugPrint(
          '[AgentNotifier]   msg: role=${m.role} contentLength=${m.content.length} events=${m.events?.length}');
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
      aiTimeoutSeconds: state.aiTimeoutSeconds,
    );
  }

  /// 从持久化恢复引擎对话历史（切换会话 / 新建引擎时调用）
  /// 传 AI 时优先用 effectiveContent (summary ?? content)
  void _restoreEngineHistory() {
    if (_engine == null) return;
    final convId = state.conversationId;
    _engine!.conversationId = convId;
    if (convId == null) {
      _engine!.clearHistory();
      return;
    }
    final conv = ConversationsDao.getCachedById(convId);
    if (conv == null) {
      _engine!.clearHistory();
      return;
    }
    // 提取所有非 system 消息，传 AI 时用 effectiveContent
    final msgs = <ChatMessage>[];
    for (final m in conv.messages) {
      if (m.role == 'system') continue;
      msgs.add(ChatMessage.create(role: m.role, content: m.effectiveContent));
    }
    _engine!.restoreHistory(msgs);
  }

  /// 关闭 tab 时清除该 tab 自己的状态和记忆。
  ///
  /// [hostId] 仅为兼容旧调用保留；状态隔离键是 tabId。关闭同一服务器的
  /// 一个 tab 不能清掉另一个 tab 的 Agent 状态或执行器。
  void removeTab(String tabId, {String? hostId}) {
    final scopeId = tabId.isNotEmpty ? tabId : hostId;
    if (scopeId == null) return;
    final engine = _registry.getEngine(scopeId);
    if (engine != null) {
      // L16 修复：先清空回调再 cancel，避免 cancelTask 触发的 onTaskUpdated 污染状态
      _clearEngineCallbacks(engine);
      engine.cancelTask();
      // R2: 清理工具资源（file_sync 的 watcher/timer/SFTP 等）
      engine.disposeTools();
    }
    _registry.removeScope(scopeId);
    _reducer.cancelTimer(scopeId);
    _reducer.reset(scopeId);
    _lastPersistedLen.remove(scopeId);
    _startingScopes.remove(scopeId);
    _startingConversations.removeWhere((_, owner) => owner == scopeId);
    // 如果移除的是当前活跃 tab，清空引用防止后续操作命中已 disposed 的引擎
    if (_engineScopeId == scopeId) {
      _engineScopeId = null;
      _engine = null;
      _executor = null;
    }
  }

  /// 为指定 tab（scope）重新初始化引擎（如果有模型配置）
  void _reinitEngineForScope(String scopeId) {
    final hostId = _registry.getHostId(scopeId) ?? state.hostId ?? 'local';
    if (_modelConfig == null) {
      _engine = null;
      return;
    }
    final memory = _getMemory(scopeId);
    final aiProvider = AIService.create(_modelConfig!);
    // P1-4: 加载 fallback 模型（如有配置）
    final fallback = _loadFallbackFor(_modelConfig!);
    _engine = AgentEngine(
      aiProvider: aiProvider,
      modelConfig: _modelConfig!,
      memory: memory,
      maxSteps: state.maxSteps,
      aiResponseTimeout: Duration(seconds: state.aiTimeoutSeconds),
      hostId: hostId,
      fallbackProvider: fallback?.$1,
      fallbackConfig: fallback?.$2,
    );
    _engineScopeId = scopeId;
    _setupEngineCallbacks(scopeId, _engine!);
    _registry.setEngine(scopeId, _engine!);
    _registry.setModelConfig(scopeId, _modelConfig);
    // 从持久化恢复引擎对话历史和摘要
    _restoreEngineHistory();
    // 从安全存储加载 sudo 密码注入到 engine
    _loadSudoPasswordForHost(hostId, _engine!);
  }

  /// 加载 fallback AIProvider 和 AIModelConfig
  /// 根据 modelConfig.fallbackModelId 在新端点/模型目录中查找并创建 provider
  /// 返回 null 表示无 fallback 或 fallback 模型不存在
  (AIProvider, AIModelConfig)? _loadFallbackFor(AIModelConfig config) {
    final fallbackId = config.fallbackModelId;
    if (fallbackId == null || fallbackId.isEmpty) return null;
    try {
      final fallbackConfig = AIModelSelectionService.buildConfig(
          AIEndpointsDao.cached, fallbackId);
      if (fallbackConfig == null) {
        debugPrint('[AgentNotifier] fallback 模型不存在: $fallbackId');
        return null;
      }
      final provider = AIService.create(fallbackConfig);
      return (provider, fallbackConfig);
    } catch (e) {
      debugPrint('[AgentNotifier] 加载 fallback 模型失败: $e');
      return null;
    }
  }

  /// 当前活跃 host 实际使用的模型配置（选择器显示用，避免切 tab 后显示全局值）
  AIModelConfig? get modelConfig => _modelConfig;

  @visibleForTesting
  AgentHostRegistry get registryForTesting => _registry;

  @visibleForTesting
  bool hasRunningAgentForHostForTesting(String hostId) =>
      _hasRunningAgentForHost(hostId);

  @visibleForTesting
  void beginStartupForTesting(String scopeId) => _startingScopes.add(scopeId);

  @visibleForTesting
  void endStartupForTesting(String scopeId) {
    _startingScopes.remove(scopeId);
    _cancelRequestedScopes.remove(scopeId);
  }

  @visibleForTesting
  bool isStartupCancelRequestedForTesting(String scopeId) =>
      _cancelRequestedScopes.contains(scopeId);

  /// tab-aware 状态更新：如果回调所属 tab 是当前活跃 tab，更新 state；
  /// 否则只更新注册表中的缓存，避免跨 tab 污染
  void _updateScopeState(
      String scopeId, AgentState Function(AgentState) updater) {
    if (_registry.isActive(scopeId)) {
      state = updater(state);
    } else {
      _registry.updateState(scopeId, updater);
    }
  }

  /// 初始化 Agent。
  ///
  /// 页面首次初始化时可能还没有活跃 tab；此时只保存模型配置，等
  /// [switchTab] 建立 scope 后再创建该 tab 自己的引擎。
  void init({
    required AIModelConfig modelConfig,
    required AIProvider aiProvider,
  }) {
    final scopeId = _registry.activeScopeId;
    // 模型/思考档位切换最终都会走 init（重建引擎）。运行中重建等于取消任务，
    // 这里做最后一道防线：UI 守卫漏掉时也绝不打断正在执行/暂停/等待确认的任务。
    if (scopeId != null && isRunningFor(scopeId)) {
      agentLogger.warn('AgentNotifier', 'Agent 任务进行中，拒绝重建引擎');
      return;
    }
    _modelConfig = modelConfig;
    if (scopeId == null) return;
    final hostId = _registry.getHostId(scopeId) ?? state.hostId ?? 'local';
    final memory = _getMemory(scopeId);

    // 若旧引擎存在（如切换 AI 模型时），先安全清理：flush 流式 → 清空回调 → cancelTask → disposeTools
    // 防止旧引擎的回调继续写当前 tab 的 state，造成双引擎并发污染
    if (_engine != null) {
      // R2: 先 flush 流式内容到 content，再清空回调
      // 否则清空回调后 cancelTask 中的 onCompleted 是 null，不会触发 _flushStreamingToContent，
      // 新引擎的 onThinking 会 reset reducer，导致切换模型时正在流式输出的内容丢失
      _flushStreamingToContent(scopeId);
      _clearEngineCallbacks(_engine!);
      _engine!.cancelTask();
      _engine!.disposeTools();
    }

    _engine = AgentEngine(
      aiProvider: aiProvider,
      modelConfig: modelConfig,
      memory: memory,
      maxSteps: state.maxSteps,
      aiResponseTimeout: Duration(seconds: state.aiTimeoutSeconds),
      hostId: hostId,
      fallbackProvider: _loadFallbackFor(modelConfig)?.$1,
      fallbackConfig: _loadFallbackFor(modelConfig)?.$2,
    );

    _engineScopeId = scopeId;
    _setupEngineCallbacks(scopeId, _engine!);

    // 保存到当前 tab
    _registry.setEngine(scopeId, _engine!);
    _registry.setModelConfig(scopeId, _modelConfig);

    // 恢复引擎对话历史（切换模型后 AI 仍能看到之前的对话上下文）
    _restoreEngineHistory();

    // 从安全存储加载 sudo 密码注入到 engine
    _loadSudoPasswordForHost(hostId, _engine!);

    // 重建引擎后同步编排/只读/联网搜索开关，避免状态与引擎不一致
    _syncOrchestratorMode();
  }

  void _setupEngineCallbacks(String scopeId, AgentEngine engine) {
    _engineScopeId = scopeId;
    _mirrorGoal(scopeId);
    // 透传而不是捕获：页面可能在引擎创建之后才注册处理器（切 tab、重建 engine）
    engine.onSecretRequest =
        (title, message) async => secretRequestHandler?.call(title, message);
    engine.onThinking = (msg) {
      // 新一轮 AI 流式开始：先把上一轮的 streamingContent 累积到 content 并保存
      _flushStreamingToContent(scopeId);
      _reducer.reset(scopeId);
      _updateScopeState(scopeId, (s) {
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

    engine.onMessage = (msg) {
      _reducer.append(scopeId, msg);
      // 每 scope 独立节流 Timer，避免多 tab 互相阻塞
      _reducer.scheduleFlush(
        scopeId,
        const Duration(milliseconds: _agentStreamThrottleMs),
        (content) {
          _updateScopeState(scopeId, (s) {
            final items = [...s.chatItems];
            if (items.isNotEmpty && items.last.role == 'assistant') {
              final lastItem = items.last;
              // 保持原有设计：streamingContent 存放当前轮增量，content 存放已固化的内容
              // UI 渲染时优先显示 streamingContent（流式效果），content 作为兜底
              items[items.length - 1] = lastItem.copyWith(
                streamingContent: content,
                isStreaming: true,
              );
              // 周期性持久化：将 content + streamingContent 合并写入磁盘
              // 防止 app 异常退出时丢失全部流式内容（events 由 onCompleted 时统一回写）
              final fullContent = lastItem.content + content;
              final lastLen = _lastPersistedLen[scopeId] ?? 0;
              if (fullContent.length - lastLen > 500) {
                _lastPersistedLen[scopeId] = fullContent.length;
                _persistAssistantCompletion(scopeId, fullContent,
                    events: lastItem.events);
              }
            }
            return s.copyWith(lastMessage: content, chatItems: items);
          });
        },
      );
    };

    /// 结构化事件回调：追加事件（不清空 streamingContent，避免流式过程中闪烁）
    engine.onEvent = (event) {
      // R3: 必须从正确的 tab 状态读取数据，不能直接用 state（活跃 tab）
      // 否则非活跃 tab 的事件会被持久化到错误的会话
      AgentState? scopeState;
      _updateScopeState(scopeId, (s) {
        scopeState = s; // 捕获更新前的 tab 状态引用
        final items = [...s.chatItems];
        if (items.isEmpty || items.last.role != 'assistant') return s;
        final lastItem = items.last;
        final events = [...lastItem.events, event];
        items[items.length - 1] = lastItem.copyWith(
          events: events,
          isStreaming: s.isRunning,
        );
        scopeState = s.copyWith(chatItems: items); // 捕获更新后的状态
        return scopeState!;
      });
      // 命令/结果/操作单报告即时持久化：使用 scopeState（正确 tab 的状态）而非 state（活跃 tab）
      // report 必须即时落盘：取消且无累积文本时不会触发 onCompleted，否则报告会丢
      if (event.type == AgentEventType.command ||
          event.type == AgentEventType.result ||
          event.type == AgentEventType.report ||
          event.type == AgentEventType.plan) {
        final items = scopeState?.chatItems ?? state.chatItems;
        if (items.isNotEmpty && items.last.role == 'assistant') {
          _persistAssistantCompletion(scopeId, items.last.content,
              events: items.last.events);
        }
      }
      // 目标模式：finish 事件是任务终局唯一可靠的信号（设计 §5-V1），
      // 放在状态更新之后，确保读到的 currentTask 就是刚结束的那个任务
      if (event.type == AgentEventType.finish) {
        _onGoalTaskFinished(scopeId, engine, event);
      }
    };

    engine.onCommandGenerated = (cmd) {
      _updateScopeState(
          scopeId, (s) => s.copyWith(status: AgentStatus.executing));
    };

    engine.onCommandExecuted = (result) {
      // 命令执行完，结果已通过 onEvent(AgentEvent.result) 发出
      // 此时结果已发给 AI，AI 开始思考下一步，状态改为 thinking
      _updateScopeState(
          scopeId, (s) => s.copyWith(status: AgentStatus.thinking));
    };

    engine.onError = (error) {
      // 出错时也保存当前内容
      _flushStreamingToContent(scopeId);
      _updateScopeState(scopeId, (s) {
        // AI 调用失败时 assistant 消息可能为空（无流式内容）
        // 用错误信息填充并持久化，确保引擎重建恢复时 AI 能看到上下文
        final items = [...s.chatItems];
        if (items.isNotEmpty &&
            items.last.role == 'assistant' &&
            items.last.content.isEmpty) {
          final errorMsg = '⚠️ $error';
          items[items.length - 1] = ChatItem(
            role: 'assistant',
            content: errorMsg,
            isStreaming: false,
          );
          _persistAssistantCompletion(scopeId, errorMsg);
          return s.copyWith(chatItems: items, error: error);
        }
        return s.copyWith(error: error);
      });
    };

    engine.onTaskUpdated = (task) {
      // 任务进入终态时清除 error：让之前因 isRunning 拒绝等设置的 error 不残留
      final isTerminal = task.status == AgentStatus.completed ||
          task.status == AgentStatus.failed ||
          task.status == AgentStatus.cancelled;
      _updateScopeState(
          scopeId,
          (s) => s.copyWith(
                currentTask: task,
                status: task.status,
                pendingConfirmCommand: engine.pendingConfirmCommand,
                pendingOptions: engine.pendingOptions.isNotEmpty
                    ? engine.pendingOptions
                    : null,
                clearPendingOptions: engine.pendingOptions.isEmpty,
                clearError: isTerminal,
              ));
    };

    engine.onCompleted = (fullMessage) {
      // 任务完成：累积最后一轮内容并保存
      _flushStreamingToContent(scopeId);
      // 仅成功完成的任务记录经验到用户经验库
      // cancelTask / _finishTask(success:false) / maxSteps 耗尽都会调 onCompleted 以 flush 流式内容，
      // 但这些路径的任务不完整（cancelled / failed），不应记录到知识库（避免污染学习经验）
      final taskStatus = engine.currentTask?.status;
      final shouldRecordLearning = taskStatus == AgentStatus.completed;
      _updateScopeState(scopeId, (s) {
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
          _persistAssistantCompletion(scopeId, lastItem.content,
              events: lastItem.events);
          // 仅成功完成的任务记录经验到用户经验库（cancelled/failed 不记录）
          if (shouldRecordLearning) {
            _recordLearningFromTask(scopeId, items, fullMessage);
          }
        }
        return s.copyWith(chatItems: items);
      });
    };
  }

  /// 将当前流式内容累积到 content 中，并持久化保存
  void _flushStreamingToContent(String scopeId) {
    final streamingContent = _reducer.getContent(scopeId);
    if (streamingContent == null || streamingContent.isEmpty) return;

    _updateScopeState(scopeId, (s) {
      final items = [...s.chatItems];
      if (items.isEmpty || items.last.role != 'assistant') return s;
      final lastItem = items.last;
      final newContent = lastItem.content + streamingContent;
      // isStreaming 必须置 false：流式已结束，UI 停止显示"运行中"光标和停止按钮
      // 之前遗漏此字段导致 cancel() 后 UI 仍显示 streaming 状态
      items[items.length - 1] = lastItem.copyWith(
        content: newContent,
        streamingContent: '',
        isStreaming: false,
      );
      // 持久化保存（含 events），并更新已持久化长度
      _lastPersistedLen[scopeId] = newContent.length;
      _persistAssistantCompletion(scopeId, newContent, events: lastItem.events);
      return s.copyWith(chatItems: items);
    });

    _reducer.cancelTimer(scopeId);
    _reducer.reset(scopeId);
  }

  /// 任务成功完成后，将经验记录到用户经验库（异步，不阻塞 UI）
  /// 使用捕获的 scopeId 解析真实 hostId（R3：不读当前活跃 tab，避免写错库）
  void _recordLearningFromTask(
      String scopeId, List<ChatItem> items, String aiSummary) {
    final hostId = _registry.getHostId(scopeId) ??
        _registry.getState(scopeId)?.hostId ??
        'local';
    Future.microtask(() async {
      try {
        // 取最后一条用户消息作为原始请求
        String? userRequest;
        for (var i = items.length - 1; i >= 0; i--) {
          if (items[i].role == 'user') {
            userRequest = items[i].content;
            break;
          }
        }
        if (userRequest == null || userRequest.trim().isEmpty) return;

        // 从最后一条 assistant 消息的 events 提取执行过的命令
        ChatItem? lastAssistant;
        for (var i = items.length - 1; i >= 0; i--) {
          if (items[i].role == 'assistant') {
            lastAssistant = items[i];
            break;
          }
        }
        if (lastAssistant == null) return;

        final commands = <String>[];
        for (final event in lastAssistant.events) {
          if (event.isCommand &&
              event.command != null &&
              event.command!.isNotEmpty) {
            commands.add(event.command!);
          }
        }
        if (commands.isEmpty) return;

        // R8：截断过长内容，防止无界增长
        final truncatedRequest = userRequest.length > 500
            ? userRequest.substring(0, 500)
            : userRequest;
        final truncatedSummary =
            aiSummary.length > 1000 ? aiSummary.substring(0, 1000) : aiSummary;
        final executedCommands = commands.join('\n');
        final truncatedCommands = executedCommands.length > 2000
            ? executedCommands.substring(0, 2000)
            : executedCommands;

        final knowledge = KnowledgeService();
        await knowledge.ensureInitialized();
        await knowledge.recordLearning(
          hostId: hostId,
          userRequest: truncatedRequest,
          executedCommands: truncatedCommands,
          aiSummary: truncatedSummary,
        );
      } catch (e) {
        debugPrint('[AgentNotifier] _recordLearningFromTask 失败: $e');
      }
    });
  }

  /// 持久化 assistant 完整响应（流式结束后回写）
  /// 使用串行化链防止并发写入竞态：多个事件快速到达时，按顺序执行 save
  ///
  /// 必须按任务所属会话 id 写入，而不是 host 的 active 会话：同一服务器
  /// 两个 tab 并行时，另一个 tab 新建会话会改变 active 会话。
  Future<void> _persistAssistantCompletion(
    String scopeId,
    String content, {
    List<AgentEvent>? events,
  }) async {
    final convId = _registry.isActive(scopeId)
        ? state.conversationId
        : _registry.getState(scopeId)?.conversationId;
    if (convId == null) {
      agentLogger.warn('Persist',
          '跳过 assistant 持久化：scope=$scopeId 尚无会话 id');
      return;
    }
    final hostId = _registry.getHostId(scopeId) ??
        _registry.getState(scopeId)?.hostId ??
        'local';

    // 串行化：按会话 id 串起来，防止并发 save 覆盖
    final chainKey = convId;
    final prev = _persistChain[chainKey] ?? Future.value();
    final next = prev.then((_) async {
      try {
        await _convService.updateLastAssistantContent(
          hostId,
          content,
          events: events,
          conversationId: convId,
        );
      } catch (e) {
        // R8: 持久化失败不可静默吞掉，需暴露到 UI 让用户感知数据丢失风险
        agentLogger.error('Persist',
            '持久化 assistant 内容失败 (scope=$scopeId, conv=$convId): $e');
        _updateScopeState(
            scopeId,
            (s) => s.copyWith(
                  error: '会话保存失败，重启后此条消息可能丢失: $e',
                ));
      }
    });
    _persistChain[chainKey] = next;
    // 链尾完成后移除，避免会话数量增长导致 map 无界增长
    next.whenComplete(() {
      if (identical(_persistChain[chainKey], next)) {
        _persistChain.remove(chainKey);
      }
    });
    return next;
  }

  /// 设置命令执行器（SSH 或本地 PTY，仅首次连接时收集系统信息）。
  ///
  /// [hostId] 是服务器 id；[tabId] 是该连接所属 tab 的 id。状态按 tab 隔离，
  /// 同一服务器的两个 tab 各自拥有自己的 executor，互不覆盖。
  ///
  /// 调用方必须显式传 `tab.id` 与 `tab.hostId`（AGENTS.md R3），不能拿
  /// 当前活跃 tab 顶替——后台重连时活跃 tab 可能是另一个连接。
  void setExecutor(
    CommandExecutor? executor, {
    required String hostId,
    String? tabId,
  }) {
    final scopeId = tabId ?? _registry.activeScopeId;
    if (scopeId != null) {
      _registry.setScopeExecutor(scopeId, executor);
      // 供多机编排按 host 解析 executor；活跃 tab 会优先命中
      _registry.setExecutor(hostId, executor);
    } else {
      // 还没有 tab（页面初始化阶段）时保留旧的 host 级注册
      _registry.setExecutor(hostId, executor);
    }

    final isActiveScope = scopeId != null && _registry.isActive(scopeId);
    final engine = scopeId == null ? null : _registry.getEngine(scopeId);
    if (isActiveScope) _executor = executor;

    if (executor != null && engine != null) {
      // 同步刷新 engine 的 executor 引用：解决 sudo reboot 后用户重连 SSH
      // 创建新 SSHService 实例，但 ReAct 循环仍持有旧引用导致连续失败的问题。
      engine.setExecutor(executor);
      if (scopeId == null || !_registry.hasSysInfoFuture(scopeId)) {
        final future = engine.collectSystemInfo(executor);
        if (scopeId != null) {
          _registry.setSysInfoFuture(scopeId, future);
        }
      }
      // 连接建立后（重新）加载 sudo 密码，覆盖 host 配置变更后的场景
      _loadSudoPasswordForHost(hostId, engine);
    }
  }

  /// 指定 tab 是否正在执行 Agent 任务。
  /// 关闭后台 tab 时不能只看活跃 tab 的 state，否则会静默取消另一个 tab 的任务。
  bool isRunningFor(String tabId) {
    if (_startingScopes.contains(tabId)) return true;
    if (_registry.activeScopeId == tabId) {
      return _isStateBusy(state) || _isEngineBusy(_engine);
    }
    return _isEngineBusy(_registry.getEngine(tabId)) ||
        _isStateBusy(_registry.getState(tabId));
  }

  /// 设置最大步骤数
  void setMaxSteps(int steps) {
    state = state.copyWith(maxSteps: steps);
    _engine?.maxSteps = steps;
    SettingsDao.set('agentMaxSteps', steps).catchError((e) {
      debugPrint('[AgentNotifier] 保存 maxSteps 失败: $e');
    });
  }

  /// 设置 AI 流式响应超时（秒），立即对所有 host 的引擎生效
  void setAiTimeoutSeconds(int seconds) {
    final clamped = seconds.clamp(
        kMinAiResponseTimeoutSeconds, kMaxAiResponseTimeoutSeconds);
    state = state.copyWith(aiTimeoutSeconds: clamped);
    final timeout = Duration(seconds: clamped);
    for (final engine in _registry.engines) {
      engine.aiResponseTimeout = timeout;
    }
    for (final scopeId in _registry.scopeIds) {
      _registry.updateState(
          scopeId, (s) => s.copyWith(aiTimeoutSeconds: clamped));
    }
    _engine?.aiResponseTimeout = timeout;
    SettingsDao.set('agentAiTimeoutSeconds', clamped).catchError((e) {
      debugPrint('[AgentNotifier] 保存 aiTimeoutSeconds 失败: $e');
    });
  }

  /// 加载设置
  void loadSettings() {
    try {
      final saved = SettingsDao.getCached('agentMaxSteps');
      if (saved != null) {
        final steps = (saved is int) ? saved : (saved as num).toInt();
        state = state.copyWith(maxSteps: steps);
        _engine?.maxSteps = steps;
      }
      final savedTimeout = SettingsDao.getCached('agentAiTimeoutSeconds');
      if (savedTimeout != null) {
        final seconds = ((savedTimeout is int)
                ? savedTimeout
                : (savedTimeout as num).toInt())
            .clamp(kMinAiResponseTimeoutSeconds, kMaxAiResponseTimeoutSeconds);
        state = state.copyWith(aiTimeoutSeconds: seconds);
        final timeout = Duration(seconds: seconds);
        for (final engine in _registry.engines) {
          engine.aiResponseTimeout = timeout;
        }
        _engine?.aiResponseTimeout = timeout;
      }
    } catch (e) {
      debugPrint('[AgentNotifier] 加载设置失败: $e');
    }
  }

  /// 开始任务
  Future<void> startTask(String goal) async {
    final scopeId = _registry.activeScopeId;
    if (scopeId == null) {
      state = state.copyWith(error: L10n.str.pleaseConfigAIModel);
      return;
    }

    // 防重复发送：小白用户可能快速点击多次发送按钮
    // 必须在持久化之前同步检查，否则会产生孤儿消息（用户消息重复但无 AI 回复）
    if (_engine != null && (_engine!.isRunning || _engine!.isPaused)) {
      state = state.copyWith(error: 'Agent 正在执行任务，请等待完成');
      return;
    }

    if (_engine == null) {
      if (_modelConfig != null) {
        _reinitEngineForScope(scopeId);
      }
      if (_engine == null) {
        state = state.copyWith(error: L10n.str.pleaseConfigAIModel);
        return;
      }
    }

    final engine = _engine!;
    final executor = _executor;
    // 检查终端连接：小白可能不知道 SSH 已断开，继续发任务会失败
    if (executor != null && !executor.isConnected) {
      state = state.copyWith(error: '终端未连接，请先连接终端');
      return;
    }

    // 输入校验：超长消息截断，防止小白粘贴 MB 级文本撑爆 AI 上下文
    if (goal.length > 10000) {
      goal = '${goal.substring(0, 10000)}\n\n${L10n.str.orchInputTruncated}';
    }

    final hostId =
        _registry.getHostId(scopeId) ?? state.hostId ?? 'local';
    _reducer.cancelTimer(scopeId);
    _reducer.reset(scopeId);
    // 确保日志路由到正确的 host（startTask 可能从非 UI 线程触发）
    agentLogger.currentHostId = hostId;

    // 防重复点击：engine.isRunning 要到下方才置位，这里先占住异步落盘窗口
    if (!_startingScopes.add(scopeId)) {
      state = state.copyWith(error: 'Agent 正在执行任务，请等待完成');
      return;
    }
    // 清掉上一次启动窗口遗留的取消请求
    _cancelRequestedScopes.remove(scopeId);
    String? claimedConversation;
    try {
      // 会话冲突处理：同一服务器的另一个 tab 若正**执行**在同一会话上，
      // 必须为该 tab 新建会话，不能两个引擎同时写同一个会话。
      // 如果只是空闲 tab 也在看这个会话，可以继续使用；启动前先按磁盘
      // 最新内容刷新状态和引擎历史，避免拿着旧上下文接话。
      var convId = state.conversationId;
      final needsNewConversation = convId == null ||
          _isConversationBusyInOtherScope(scopeId, convId);
      if (needsNewConversation) {
        try {
          final conv = _convService.createSession(hostId: hostId);
          convId = conv.id;
        } catch (e) {
          agentLogger.error('AgentNotifier', '创建会话失败: $e');
          _updateScopeState(
            scopeId,
            (s) => s.copyWith(error: '${L10n.str.messageSaveFailed}: $e'),
          );
          return;
        }
        engine.clearHistory();
        engine.conversationId = convId;
        _reducer.reset(scopeId);
        _lastPersistedLen[scopeId] = 0;
        // 新会话不复用旧会话的聊天记录；保留编排/只读/联网搜索等会话级开关
        final oldState = _registry.isActive(scopeId)
            ? state
            : _registry.getState(scopeId);
        _updateScopeState(
          scopeId,
          (s) => AgentState(
            hostId: hostId,
            conversationId: convId,
            maxSteps: (oldState ?? s).maxSteps,
            aiTimeoutSeconds: (oldState ?? s).aiTimeoutSeconds,
            isOrchestratorMode: s.isOrchestratorMode,
            isReadOnlyMode: s.isReadOnlyMode,
            isWebSearchEnabled: s.isWebSearchEnabled,
            goal: s.goal,
          ),
        );
        _syncOrchestratorMode();
      } else {
        engine.conversationId = convId;
        if (_isConversationUsedByOtherScope(scopeId, convId)) {
          _reloadScopeFromConversation(scopeId, convId);
          _syncEngineHistoryAfterCompact(scopeId, convId);
        }
      }

      // 同步占住会话：另一个 tab 在本次异步落盘窗口内不能抢同一个会话
      _startingConversations[convId] = scopeId;
      claimedConversation = convId;

      // 持久化用户消息 + assistant 占位（原子写入，消除两次 save 之间的崩溃窗口）
      try {
        await _convService.appendMessagePair(
          hostId,
          userContent: goal,
          assistantContent: '',
          conversationId: convId,
        );
      } catch (e) {
        // R8: 持久化失败必须告知用户，不能静默吞掉后继续启动引擎制造假象
        agentLogger.error('AgentNotifier', '持久化消息失败: $e');
        _updateScopeState(
          scopeId,
          (s) => s.copyWith(error: '${L10n.str.messageSaveFailed}: $e'),
        );
        return;
      }

      // 用户在落盘窗口内点过停止：engine 还没有 _currentTask，
      // cancelTask 无法生效，这里按取消收尾并放弃启动。
      if (_cancelRequestedScopes.remove(scopeId)) {
        _applyCancelledState(scopeId, engine);
        return;
      }

      // R1: await 期间用户可能切换 tab / 更换引擎。任务必须继续在发起它的
      // scope 上执行；但若已切到另一台服务器，switchTab 已经取消了这个引擎，
      // 不再启动一个后台任务。
      if (_registry.getEngine(scopeId) != engine) return;
      final activeScope = _registry.activeScopeId;
      final activeHost =
          activeScope == null ? null : _registry.getHostId(activeScope);
      if (activeHost != null && activeHost != hostId) {
        // 已离开这台机器：保留用户消息 + 取消占位，不启动后台任务
        _updateScopeState(
          scopeId,
          (s) => s.copyWith(
            hostId: hostId,
            conversationId: convId,
            chatItems: [
              ...s.chatItems,
              ChatItem(role: 'user', content: goal),
              ChatItem(
                  role: 'assistant',
                  content: L10n.str.taskCancelled,
                  isStreaming: false),
            ],
            clearError: true,
          ),
        );
        _persistAssistantCompletion(scopeId, L10n.str.taskCancelled);
        return;
      }

      // 添加用户消息 + AI 占位到该 tab 的 chatItems
      _updateScopeState(
        scopeId,
        (s) => s.copyWith(
          status: AgentStatus.thinking,
          hostId: hostId,
          conversationId: convId,
          chatItems: [
            ...s.chatItems,
            ChatItem(role: 'user', content: goal),
            ChatItem(role: 'assistant', content: '', isStreaming: true),
          ],
          lastMessage: '',
          currentTask: null,
          clearError: true,
        ),
      );
      // 重置该 tab 的持久化长度计数器（新 assistant 消息从 0 开始累积）
      _lastPersistedLen[scopeId] = 0;

      // 如果系统信息还没收集，先收集再开始任务，避免命令混在一起
      if (executor != null && !_registry.hasSysInfoFuture(scopeId)) {
        _registry.setSysInfoFuture(
            scopeId, engine.collectSystemInfo(executor));
      }
      final sysInfoFuture = _registry.getSysInfoFuture(scopeId);
      if (sysInfoFuture != null) {
        await sysInfoFuture;
      }

      // 系统信息收集期间用户点了停止
      if (_cancelRequestedScopes.remove(scopeId)) {
        _applyCancelledState(scopeId, engine);
        return;
      }

      // R1: 系统信息收集/切 tab 期间引擎可能已被替换或取消，不能再启动
      if (_registry.getEngine(scopeId) != engine) {
        _applyCancelledState(scopeId, engine);
        return;
      }
      final activeScopeNow = _registry.activeScopeId;
      final activeHostNow = activeScopeNow == null
          ? null
          : _registry.getHostId(activeScopeNow);
      if (activeHostNow != null && activeHostNow != hostId) {
        // 已切到另一台服务器：switchTab 已取消旧 host 的所有引擎
        _applyCancelledState(scopeId, engine);
        return;
      }

      final startFuture = engine.startTask(goal, executor);
      // engine.startTask 同步进入 thinking 状态，之后由 isRunning 接管防重
      _startingScopes.remove(scopeId);
      await startFuture;

      // 任务结束后检查是否需要自动压缩
      _maybeAutoCompact(scopeId);
    } finally {
      _startingScopes.remove(scopeId);
      _cancelRequestedScopes.remove(scopeId);
      if (claimedConversation != null &&
          _startingConversations[claimedConversation] == scopeId) {
        _startingConversations.remove(claimedConversation);
      }
    }
  }

  /// 指定会话是否正被其他 tab 使用（无论是否在运行）。
  bool _isConversationUsedByOtherScope(String scopeId, String conversationId) {
    final activeScope = _registry.activeScopeId;
    for (final otherScope in _registry.scopeIds) {
      if (otherScope == scopeId) continue;
      final otherConv = otherScope == activeScope
          ? state.conversationId
          : _registry.getState(otherScope)?.conversationId;
      if (otherConv == conversationId) return true;
    }
    return false;
  }

  /// 指定会话是否正被其他 tab **执行中**（含启动中的异步窗口）。
  bool _isConversationBusyInOtherScope(
      String scopeId, String conversationId) {
    final starter = _startingConversations[conversationId];
    if (starter != null && starter != scopeId) return true;
    final activeScope = _registry.activeScopeId;
    for (final otherScope in _registry.scopeIds) {
      if (otherScope == scopeId) continue;
      final otherConv = otherScope == activeScope
          ? state.conversationId
          : _registry.getState(otherScope)?.conversationId;
      if (otherConv != conversationId) continue;
      final otherEngine = _registry.getEngine(otherScope);
      if (_isEngineBusy(otherEngine)) return true;
      final otherState = otherScope == activeScope
          ? state
          : _registry.getState(otherScope);
      if (_isStateBusy(otherState)) return true;
    }
    return false;
  }

  /// 从磁盘刷新指定 tab 的会话内容与引擎历史。
  /// 两个空闲 tab 共享同一会话时，另一个 tab 可能刚写过新消息。
  void _reloadScopeFromConversation(String scopeId, String conversationId) {
    final conv = ConversationsDao.getCachedById(conversationId);
    if (conv == null) return;
    final items = conv.messages
        .where((m) => m.role != 'system')
        .map((m) => ChatItem.fromConvMessage(m))
        .toList();
    final hasSummary = conv.summary != null && conv.summary!.isNotEmpty;
    _updateScopeState(
        scopeId,
        (s) => s.copyWith(
              chatItems: items,
              summary: hasSummary ? conv.summary : null,
              clearSummary: !hasSummary,
            ));
  }

  /// 取消任务
  void cancel() {
    // 以活跃 tab 的当前引擎为准；_engine 只是缓存，切 tab/重建模型后可能滞后
    final scopeId = _registry.activeScopeId ?? _engineScopeId;
    final engine = scopeId == null
        ? _engine
        : (_registry.getEngine(scopeId) ?? _engine);

    if (scopeId != null) {
      // 任务已显示"运行中"、但 engine.startTask 尚未执行的窗口：
      // 此时 cancelTask 是 no-op，必须记下取消意图让 startTask 放弃启动
      if (_startingScopes.contains(scopeId)) {
        _cancelRequestedScopes.add(scopeId);
      }
      // 取消前先保存当前流式内容到 content（_flushStreamingToContent 会同时 isStreaming: false）
      _flushStreamingToContent(scopeId);
      // 兜底：所有终态路径都必须强制 isStreaming: false，避免 UI 卡在"运行中"
      // 覆盖两种场景：
      //   1. thinking 阶段取消（streamingContent 为空，_flushStreamingToContent 提前 return）
      //      → 填充"任务已取消"提示，避免空 assistant 消息
      //   2. streamingContent 非空但被 _flushStreamingToContent 合并后，仍需兜底确保 isStreaming: false
      _updateScopeState(scopeId, (s) {
        final items = [...s.chatItems];
        if (items.isNotEmpty && items.last.role == 'assistant') {
          final lastItem = items.last;
          final newContent = lastItem.content.isEmpty
              ? L10n.str.taskCancelled
              : lastItem.content;
          items[items.length - 1] = lastItem.copyWith(
            content: newContent,
            streamingContent: '',
            isStreaming: false,
          );
          // 仅当 content 有变化时持久化（避免无谓 IO）
          if (lastItem.content != newContent) {
            _persistAssistantCompletion(scopeId, newContent,
                events: lastItem.events);
          }
        }
        // 不依赖引擎回调：即使 engine 还没有 _currentTask，UI 也必须马上退出运行态
        return s.copyWith(
          status: AgentStatus.cancelled,
          currentTask: engine?.currentTask,
          chatItems: items,
          clearPendingConfirm: true,
          clearPendingOptions: true,
          clearError: true,
        );
      });
    }
    engine?.cancelTask();
  }

  /// P2-7: 暂停任务
  void pause() {
    if (_engine == null || !_engine!.isRunning) return;
    _engine!.pauseTask();
  }

  /// P2-7: 恢复任务
  Future<void> resume() async {
    final engine = _engine;
    final scopeId = _engineScopeId;
    if (engine == null || scopeId == null || engine.currentTask == null) {
      return;
    }
    final executor = _executor;
    await engine.resumeTask(executor);
    // 任务结束后检查是否需要自动压缩（引擎可能已被模型切换替换）
    if (_registry.getEngine(scopeId) == engine) {
      _maybeAutoCompact(scopeId);
    }
  }

  /// 确认执行危险命令（自动模式）
  void confirmCommand() {
    if (_engine != null && _engine!.hasPendingConfirm) {
      _engine!.confirmDangerousCommand();
      _updateScopeState(
          _engineScopeId ?? '',
          (s) => s.copyWith(
                status: AgentStatus.executing,
                clearPendingConfirm: true,
              ));
    }
  }

  /// 拒绝执行危险命令（自动模式）
  void rejectCommand() {
    if (_engine != null && _engine!.hasPendingConfirm) {
      _engine!.rejectDangerousCommand();
      _updateScopeState(
          _engineScopeId ?? '',
          (s) => s.copyWith(
                status: AgentStatus.thinking,
                clearPendingConfirm: true,
              ));
    }
  }

  /// 用户选择选项
  void selectChoice(String choice) {
    if (_engine != null && _engine!.hasPendingChoice) {
      _engine!.selectChoice(choice);
      _updateScopeState(
          _engineScopeId ?? '',
          (s) => s.copyWith(
                status: AgentStatus.thinking,
                clearPendingOptions: true,
              ));
    }
  }

  /// 清空消息（同时清除引擎对话历史 + 持久化）
  Future<void> clearMessages() async {
    final activeScope = _registry.activeScopeId;
    if (_engine?.isRunning == true ||
        (activeScope != null && _startingScopes.contains(activeScope))) {
      state = state.copyWith(error: 'Agent 正在执行任务，请先停止后再清空会话');
      return;
    }
    _engine?.clearHistory();
    final convId = state.conversationId;
    state = state.copyWith(chatItems: [], lastMessage: '', clearSummary: true);
    if (convId != null) {
      try {
        await _convService.clearMessages(convId);
      } catch (e) {
        agentLogger.error('AgentNotifier', '清空持久化消息失败: $e');
        state = state.copyWith(error: '${L10n.str.clearMessagesFailed}: $e');
      }
    }
  }

  /// 清空当前 tab 的记忆
  void clearMemory() {
    final scopeId = _registry.activeScopeId;
    if (scopeId != null) {
      _getMemory(scopeId).clear();
    }
    state = state.copyWith(clearError: true);
  }

  // ═══════════════════════════════════════════
  // 多机编排模式
  // ═══════════════════════════════════════════

  /// 启用多机编排模式
  /// 启用后，AI 可使用 exec_on/exec_batch/check_connectivity 工具跨主机调度
  void enableOrchestratorMode() {
    if (_engine == null) {
      state = state.copyWith(error: L10n.str.agentNotInitialized);
      return;
    }
    _engine!.enableOrchestrator(_registry);
    state = state.copyWith(isOrchestratorMode: true, clearError: true);
  }

  /// 禁用多机编排模式
  void disableOrchestratorMode() {
    _engine?.disableOrchestrator();
    state = state.copyWith(isOrchestratorMode: false);
  }

  /// 切换编排模式
  void toggleOrchestratorMode() {
    if (state.isOrchestratorMode) {
      disableOrchestratorMode();
    } else {
      enableOrchestratorMode();
    }
  }

  /// 开启/关闭只读模式（Dry-run）
  void toggleReadOnlyMode() {
    final newValue = !state.isReadOnlyMode;
    _engine?.setReadOnlyMode(newValue);
    state = state.copyWith(isReadOnlyMode: newValue);
  }

  /// 按 host 设置只读模式。
  ///
  /// 不能用 [toggleReadOnlyMode]：它读 `state`（活跃 host）也写 `state`，
  /// 调用方若跨 await 持有意图（如 `/plan` 结束时还原），期间用户切了 tab
  /// 就会把**另一个 host** 的模式改掉（AGENTS.md R3 的那类串台）。
  void setReadOnlyForHost(String hostId, {required bool enabled}) {
    final scopes = _registry.scopesForHost(hostId).toList();
    // 活跃 tab 的 state 可能还没写回 registry，先确保它被包含
    final activeScope = _registry.activeScopeId;
    if (activeScope != null &&
        state.hostId == hostId &&
        !scopes.contains(activeScope)) {
      scopes.add(activeScope);
    }
    for (final scopeId in scopes) {
      _registry.getEngine(scopeId)?.setReadOnlyMode(enabled);
      _updateScopeState(scopeId, (s) => s.copyWith(isReadOnlyMode: enabled));
    }
  }

  /// 该 host 当前是否只读。跨 await 的调用方必须按 host 读，不能读 `state`。
  bool isReadOnlyFor(String hostId) {
    if (state.hostId == hostId) return state.isReadOnlyMode;
    for (final scopeId in _registry.scopesForHost(hostId)) {
      final s = _registry.getState(scopeId);
      if (s != null) return s.isReadOnlyMode;
    }
    return false;
  }

  /// 开启/关闭联网搜索（会话级，覆盖全局开关）
  ///
  /// 运行中切换不影响当前任务（system prompt 已构建），
  /// 下次 startTask 时工具注册状态会按新值同步。
  void toggleWebSearch() {
    final newValue = !state.isWebSearchEnabled;
    _engine?.setWebSearchEnabled(newValue);
    state = state.copyWith(isWebSearchEnabled: newValue);
  }

  // ═══════════════════════════════════════════
  // 会话管理（侧边栏调用）
  // ═══════════════════════════════════════════

  /// 新建会话（结束当前会话，创建空白会话）
  Future<void> newSession() async {
    final scopeId = _registry.activeScopeId;
    if (scopeId == null) return;
    // 运行中/正在启动任务时新建会话会让任务失去落盘目标，直接拒绝比静默串台安全
    if (_engine?.isRunning == true || _startingScopes.contains(scopeId)) {
      state = state.copyWith(error: 'Agent 正在执行任务，请先停止后再新建会话');
      return;
    }
    final hostId =
        _registry.getHostId(scopeId) ?? state.hostId ?? 'local';
    _engine?.clearHistory();
    final conv = _convService.createSession(hostId: hostId);
    _engine?.conversationId = conv.id;
    _reducer.cancelTimer(scopeId);
    _reducer.reset(scopeId);
    _lastPersistedLen[scopeId] = 0;
    state = AgentState(
      hostId: hostId,
      conversationId: conv.id,
      maxSteps: state.maxSteps,
      aiTimeoutSeconds: state.aiTimeoutSeconds,
      isOrchestratorMode: state.isOrchestratorMode,
      isReadOnlyMode: state.isReadOnlyMode,
      isWebSearchEnabled: state.isWebSearchEnabled,
      goal: _goals[hostId],
    );
  }

  /// 切换到指定会话（侧边栏点击）
  Future<void> switchSession(String conversationId) async {
    final scopeId = _registry.activeScopeId;
    if (scopeId == null) return;
    final hostId =
        _registry.getHostId(scopeId) ?? state.hostId ?? 'local';
    // 本 tab 自己的启动窗口内不能切会话
    if (_startingScopes.contains(scopeId)) {
      state = state.copyWith(error: 'Agent 正在启动任务，请稍后再切换会话');
      return;
    }
    // 同一会话正被另一个 tab 执行时不能切过去：本 tab 一旦发任务就会
    // 和对方同时写一个会话，内存历史和磁盘必然互相覆盖。
    if (_isConversationBusyInOtherScope(scopeId, conversationId)) {
      state = state.copyWith(error: '该会话正在另一个标签中执行，请先切回那个标签');
      return;
    }
    // 先保存当前流式内容到旧会话（cancelTask 后引擎退出，不再有 onCompleted 触发保存）
    _flushStreamingToContent(scopeId);
    // L7 修复：取消当前任务 + 重置 reducer，避免旧任务的事件/流式内容串台到新会话
    _engine?.cancelTask();
    _reducer.cancelTimer(scopeId);
    _reducer.reset(scopeId);
    _convService.setActive(hostId, conversationId);
    _restoreFromPersistence(scopeId, hostId, startFresh: false);
    // 从持久化恢复引擎对话历史（不含已摘要的消息，那些已压缩为 summary）
    _restoreEngineHistory();
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
      final scopeId = _registry.activeScopeId;
      if (scopeId != null) {
        final hostId =
            _registry.getHostId(scopeId) ?? state.hostId ?? 'local';
        final sessions = _convService.listSessions(hostId);
        if (sessions.isEmpty) {
          await newSession();
        } else {
          await switchSession(sessions.first.id);
        }
      }
    }
  }

  /// 获取当前 tab 所属服务器的所有会话列表（侧边栏用）
  List<Conversation> listSessions() {
    final scopeId = _registry.activeScopeId;
    if (scopeId == null) return [];
    final hostId = _registry.getHostId(scopeId) ?? state.hostId;
    if (hostId == null) return [];
    return _convService.listSessions(hostId);
  }

  // ═══════════════════════════════════════════
  // 记忆压缩
  // ═══════════════════════════════════════════

  /// 判断是否需要自动压缩（任务结束后调用）
  /// [taskHostId] 发起任务的 host，避免切换 host 后压缩错误的会话
  // ==================== 目标模式（设计 §3.2）====================

  /// hostId → 目标。`AgentState.goal` 是它的 UI 镜像；所有变更都经 [_setGoal]
  /// 同时写存储与刷状态，避免两份真相各自漂移。
  final Map<String, AgentGoal> _goals = {};

  /// 已为哪个终局任务发起过续跑。取消与异常可能连着发出两个 finish 事件，
  /// 不去重就会在一次结束后起两个任务。
  String? _continuedFromTaskId;

  static const String _goalKeyPrefix = 'agentGoal:';

  static String _goalKey(String hostId) => '$_goalKeyPrefix$hostId';

  /// 启动时把所有 host 的目标读回内存。
  /// 只读 SettingsDao 的内存缓存（同步），不在 build 期间改 provider state。
  void _loadStoredGoals() {
    try {
      for (final entry in SettingsDao.cachedMap.entries) {
        if (!entry.key.startsWith(_goalKeyPrefix)) continue;
        final hostId = entry.key.substring(_goalKeyPrefix.length);
        final goal = AgentGoal.fromJson(entry.value);
        if (goal != null) _goals[hostId] = goal;
      }
    } catch (e) {
      // R8: 不能静默吞掉——目标读不回来就等于功能消失
      debugPrint('[AgentNotifier] 加载目标失败: $e');
    }
  }

  /// 引擎为某 tab 重建时把 host 目标镜像回该 tab 的状态（应用重启后的恢复路径）
  void _mirrorGoal(String scopeId) {
    final hostId = _registry.getHostId(scopeId) ?? state.hostId;
    if (hostId == null) return;
    final goal = _goals[hostId];
    _updateScopeState(scopeId, (s) {
      if (goal == null) return s.goal == null ? s : s.copyWith(clearGoal: true);
      return s.copyWith(goal: goal);
    });
  }

  /// 目标属于 host，但 UI 状态按 tab 存。更新该 host 下所有 tab 的状态，
  /// 避免一个 tab 改了目标、另一个 tab 的横幅还停在旧值。
  void _updateStatesForHost(
      String hostId, AgentState Function(AgentState) updater) {
    final activeScope = _registry.activeScopeId;
    if (state.hostId == hostId) {
      state = updater(state);
    }
    for (final scopeId in _registry.scopesForHost(hostId)) {
      if (scopeId == activeScope) continue;
      _registry.updateState(scopeId, updater);
    }
  }

  /// 只读取，不改状态——供命令回显与测试用
  AgentGoal? goalFor(String hostId) => _goals[hostId];

  void _setGoal(String hostId, AgentGoal? goal) {
    if (goal == null) {
      _goals.remove(hostId);
    } else {
      _goals[hostId] = goal;
    }
    try {
      // 空串代表"没有目标"：读侧 AgentGoal.fromJson 会把它当无效数据丢弃
      SettingsDao.set(_goalKey(hostId), goal?.toJson() ?? '');
    } catch (e) {
      debugPrint('[AgentNotifier] 目标存盘失败 (hostId=$hostId): $e');
    }
    _updateStatesForHost(
        hostId,
        (s) => goal == null
            ? s.copyWith(clearGoal: true)
            : s.copyWith(goal: goal));
  }

  /// 创建并激活目标。已有活跃目标时返回 null，由调用方提示，不静默覆盖。
  AgentGoal? createGoal(String hostId, String objective, {int? maxRounds}) {
    final text = objective.trim();
    if (text.isEmpty) return null;
    if (_goals[hostId]?.isActive == true) return null;
    final now = DateTime.now();
    final goal = AgentGoal(
      id: 'goal-${now.microsecondsSinceEpoch}-$hostId',
      hostId: hostId,
      objective: text,
      maxRounds: _clampMaxRounds(maxRounds),
      createdAt: now,
      updatedAt: now,
    );
    _continuedFromTaskId = null;
    _setGoal(hostId, goal);
    return goal;
  }

  bool pauseGoal(String hostId) {
    final goal = _goals[hostId];
    if (goal == null || !goal.isActive) return false;
    _setGoal(
      hostId,
      goal.copyWith(
        status: AgentGoalStatus.paused,
        note: '手动暂停',
        updatedAt: DateTime.now(),
      ),
    );
    return true;
  }

  /// 恢复。预算已用尽时拒绝——否则下一轮判定立刻以"预算耗尽"结束，
  /// 用户看到的是"点了恢复什么都没发生"。
  bool resumeGoal(String hostId) {
    final goal = _goals[hostId];
    if (goal == null || goal.status == AgentGoalStatus.active) return false;
    if (goal.budgetExhausted) {
      _updateStatesForHost(
          hostId,
          (s) => s.copyWith(
              error:
                  '目标轮次已用尽（${goal.roundsUsed}/${goal.maxRounds}），请用 /goal edit 调整目标或先结束'));
      return false;
    }
    final activeScope = _registry.activeScopeId;
    final isForegroundHost = activeScope != null &&
        _registry.getHostId(activeScope) == hostId &&
        _engine != null &&
        _engineScopeId == activeScope;
    final connectionAlive = _executor?.isConnected ?? false;
    if (!isForegroundHost || !connectionAlive) {
      // 与其翻成 active 然后什么都不发生，不如当场说清楚恢复不了的原因
      _updateStatesForHost(
          hostId,
          (s) => s.copyWith(
              error: isForegroundHost
                  ? '终端未连接，恢复后没有可执行的地方，请先重连'
                  : '该目标属于别的会话，先切回它的会话再恢复'));
      return false;
    }
    final resumed = goal.copyWith(
      status: AgentGoalStatus.active,
      clearNote: true,
      // 恢复后重新计无进展窗口，否则恢复即触发"连续两轮无进展"
      noProgressRounds: 0,
      updatedAt: DateTime.now(),
    );
    _setGoal(hostId, resumed);
    if (!shouldKickGoalRound(
      goalActive: true,
      isForegroundHost: isForegroundHost,
      engineRunning: _engine?.isRunning ?? false,
      connectionAlive: connectionAlive,
    )) {
      // 已经有任务在跑：它终局时会自己接上续跑，这里不抢
      return true;
    }
    final prompt = buildGoalContinuationPrompt(resumed);
    final resumeScope = activeScope;
    scheduleMicrotask(() {
      if (_goals[hostId]?.isActive != true) return;
      if (_registry.activeScopeId != resumeScope) return;
      if (_engine != null && _engine!.isRunning) return;
      startTask(prompt);
    });
    return true;
  }

  /// 改目标文本。**保留 roundsUsed 与 maxRounds**：编辑不能用来刷预算。
  bool editGoal(String hostId, String objective) {
    final goal = _goals[hostId];
    final text = objective.trim();
    if (goal == null || text.isEmpty) return false;
    _setGoal(
      hostId,
      goal.copyWith(objective: text, updatedAt: DateTime.now()),
    );
    return true;
  }

  bool finishGoal(String hostId, {String? note}) {
    final goal = _goals[hostId];
    if (goal == null) return false;
    _setGoal(
      hostId,
      goal.copyWith(
        status: AgentGoalStatus.finished,
        note: note ?? '手动结束',
        updatedAt: DateTime.now(),
      ),
    );
    return true;
  }

  void clearGoal(String hostId) => _setGoal(hostId, null);

  static int _clampMaxRounds(int? raw) {
    final v = raw ?? AgentGoal.defaultMaxRounds;
    if (v < 1) return 1;
    return v > AgentGoal.maxAllowedRounds ? AgentGoal.maxAllowedRounds : v;
  }

  /// 任务终局时的目标处理。
  ///
  /// 挂在 `AgentEvent.finish` 而不是 `onCompleted`（设计 §5-V1）：后者漏掉所有异常
  /// 失败路径与空输出路径，用它会出现"任务失败了但目标再也不动"。
  void _onGoalTaskFinished(
      String scopeId, AgentEngine engine, AgentEvent event) {
    final hostId =
        _registry.getHostId(scopeId) ?? engine.hostId ?? 'local';
    final goal = _goals[hostId];
    if (goal == null || !goal.isActive) return;

    // 任务对象必须按 tab 取对来源：活跃 tab 的 currentTask 写在 `state` 里
    // （startTask / onTaskUpdated 都是直接 `state =`），注册表里那份不随这些写更新。
    // 早先一律读 `_registry.getState(hostId)`，取到的 currentTask 是 null，
    // 于是 commandsRun 恒为 0，目标两轮就误判"无进展"——真机复拍暴露的就是这个。
    final activeScope = _registry.activeScopeId;
    final liveTask = scopeId == activeScope
        ? state.currentTask
        : _registry.getState(scopeId)?.currentTask;
    final taskId = liveTask?.id;
    if (taskId != null && taskId == _continuedFromTaskId) return;

    // 只在发起目标的那台机器的前台 tab 上续跑。后台 tab 上自动执行命令，
    // 等于在用户没看的机器上动手（AGENTS.md R3 的那类事故）；同一 host 的
    // 另一个 tab 也不接管，避免两个 tab 抢同一个目标。
    final isForegroundHost = activeScope == scopeId &&
        _engineScopeId == scopeId &&
        _engine == engine;

    final decision = decideGoalContinuation(
      goal: goal,
      finishState: event.finishState,
      // 本轮干了多少活：stepIndex 每个任务各自从 1 计，跨轮比大小会误判
      commandsRun:
          (liveTask?.successCount ?? 0) + (liveTask?.failureCount ?? 0),
      hadConfirmTimeout: engine.hadConfirmTimeout,
      connectionAlive:
          _registry.getScopeExecutor(scopeId)?.isConnected ?? false,
      isForegroundHost: isForegroundHost,
      finishSummary: event.text,
    );

    _setGoal(hostId, decision.goal);
    if (decision.action != GoalAction.continueRound) {
      agentLogger.info('Goal', '目标停止自动续跑：${decision.reason}');
      return;
    }

    if (!shouldScheduleGoalRound(
      goal: decision.goal,
      finishingTaskId: taskId,
      alreadyContinuedTaskId: _continuedFromTaskId,
      engineRunning: engine.isRunning,
    )) {
      return;
    }
    if (taskId != null) _continuedFromTaskId = taskId;
    final prompt = buildGoalContinuationPrompt(decision.goal);
    // 延后发起（设计 §5-V2 / D5）：finish 事件在 _finishTask 的资源清理之前发出，
    // 同步起新任务会让那段清理作用在新任务上——刚建的 streamSub 立刻被 cancel。
    scheduleMicrotask(() {
      // 排队期间用户可能按了暂停、切了 tab，也可能自己发了消息：都得重查
      if (_goals[hostId]?.isActive != true) return;
      if (_registry.activeScopeId != scopeId) return;
      if (_engine != engine || engine.isRunning) return;
      startTask(prompt);
    });
  }

  void _maybeAutoCompact(String scopeId) {
    final convId = _registry.isActive(scopeId)
        ? state.conversationId
        : _registry.getState(scopeId)?.conversationId;
    if (convId == null) return;

    final conv = ConversationsDao.getCachedById(convId);
    if (conv == null) return;

    // 统计未压缩的消息（summary 为空的非系统消息）
    final unsummarized = conv.messages.where(
        (m) => m.role != 'system' && (m.summary == null || m.summary!.isEmpty));
    final rounds = unsummarized.length ~/ 2;
    // 基于有效内容计算字符数（已压缩的用 summary 长度）
    final needsCompact = rounds >= _compactThresholdRounds ||
        conv.totalChars >= _compactThresholdChars;
    final isCompacting = _registry.isActive(scopeId)
        ? state.isCompacting
        : (_registry.getState(scopeId)?.isCompacting ?? false);
    if (needsCompact && !isCompacting) {
      compact(scopeId).catchError((e) {
        debugPrint('[AgentNotifier] 自动压缩失败: $e');
      });
    }
  }

  /// 压缩对话：一次性调用 AI 将早期消息逐条压缩，写入 ConvMessage.summary
  /// 保留最近 N 轮原文不压缩，确保 AI 有足够近期上下文
  /// 压缩期间加锁（isCompacting），UI 显示"会话压缩中"横幅
  Future<void> compact([String? scopeId]) async {
    final effectiveScope = scopeId ?? _registry.activeScopeId;
    if (effectiveScope == null) return;
    final isActiveScope = _registry.isActive(effectiveScope);
    final scopeState = isActiveScope
        ? state
        : _registry.getState(effectiveScope);
    if (scopeState == null) return;
    final convId = scopeState.conversationId;
    if (convId == null) return;
    final engine = _registry.getEngine(effectiveScope) ??
        (isActiveScope ? _engine : null);
    if (engine == null) return;
    if (scopeState.isCompacting) return; // 防止并发压缩

    final conv = ConversationsDao.getCachedById(convId);
    if (conv == null) return;

    // 待压缩 = 所有非系统消息中 summary 为空的，排除最近 N 轮（保留原文给 AI 近期上下文）
    final allMsgs = conv.messages.where((m) => m.role != 'system').toList();
    const keepCount = _compactKeepRounds * 2;
    if (allMsgs.length <= keepCount) return; // 太少不压缩

    // 待压缩范围：除最近 keepCount 条之外，且尚未有 summary 的消息
    final toSummarize = <ConvMessage>[];
    for (int i = 0; i < allMsgs.length - keepCount; i++) {
      final m = allMsgs[i];
      if (m.summary == null || m.summary!.isEmpty) {
        toSummarize.add(m);
      }
    }
    if (toSummarize.isEmpty) return;

    // 加锁 + UI 提示
    _updateScopeState(effectiveScope, (s) => s.copyWith(isCompacting: true));

    try {
      // 构造压缩输入
      final tuples = <({
        int index,
        String role,
        String content,
        String? command,
        bool? commandSuccess
      })>[];
      for (int i = 0; i < toSummarize.length; i++) {
        final m = toSummarize[i];
        tuples.add((
          index: i,
          role: m.role,
          content: m.content,
          command: m.command,
          commandSuccess: m.commandSuccess,
        ));
      }

      final summaries = await engine.summarizeMessages(tuples);
      if (summaries == null || summaries.isEmpty) {
        agentLogger.warn('AgentNotifier', '对话压缩未产生摘要（AI 返回空或解析失败）');
        _updateScopeState(
            effectiveScope, (s) => s.copyWith(isCompacting: false));
        return;
      }

      // 逐条写入 ConvMessage.summary
      for (final (idx, summary) in summaries) {
        if (idx >= 0 && idx < toSummarize.length) {
          toSummarize[idx].summary = summary;
        }
      }
      conv.updatedAt = DateTime.now();
      await ConversationsDao.upsert(conv);

      // 同步引擎内存历史：用 effectiveContent 重建，使后续 AI 调用使用压缩后的内容
      _syncEngineHistoryAfterCompact(effectiveScope, convId);

      // 更新 UI 状态
      final restored = ConversationsDao.getCachedById(convId);
      if (restored != null) {
        final items = restored.messages
            .where((m) => m.role != 'system')
            .map((m) => ChatItem.fromConvMessage(m))
            .toList();
        _updateScopeState(
            effectiveScope,
            (s) => s.copyWith(
                  chatItems: items,
                  isCompacting: false,
                ));
      } else {
        _updateScopeState(
            effectiveScope, (s) => s.copyWith(isCompacting: false));
      }
    } catch (e) {
      agentLogger.error('AgentNotifier', '对话压缩失败: $e');
      _updateScopeState(
          effectiveScope,
          (s) => s.copyWith(
              isCompacting: false, error: '${L10n.str.compactFailed}: $e'));
    }
  }

  /// 压缩后同步引擎内存历史：用 effectiveContent 重建 _conversationHistory
  void _syncEngineHistoryAfterCompact(String scopeId, String convId) {
    final engine = _registry.getEngine(scopeId);
    if (engine == null) return;
    final conv = ConversationsDao.getCachedById(convId);
    if (conv == null) return;

    final msgs = <ChatMessage>[];
    for (final m in conv.messages) {
      if (m.role == 'system') continue;
      msgs.add(ChatMessage.create(role: m.role, content: m.effectiveContent));
    }
    engine.restoreHistory(msgs);
  }

  @override
  void dispose() {
    // R2: 先清空所有回调，再 cancelTask，防止 cancelTask 触发的 onTaskUpdated 写已 disposed 的 state
    for (final engine in _registry.engines) {
      _clearEngineCallbacks(engine);
      engine.cancelTask();
      // R2: 清理工具资源（如文件同步的 watcher 和 timer）
      engine.disposeTools();
    }
    _startingScopes.clear();
    _startingConversations.clear();
    _registry.dispose();
    _reducer.dispose();
    _logUnsubscribe?.call();
    super.dispose();
  }
}

/// Provider
final agentProvider = StateNotifierProvider<AgentNotifier, AgentState>((ref) {
  return AgentNotifier();
});
