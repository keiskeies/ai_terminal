import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/agent_model.dart';
import '../models/agent_event.dart';
import '../models/agent_memory.dart';
import '../models/ai_model_config.dart';
import '../models/chat_session.dart';
import '../models/conversation.dart';
import '../services/agent_engine.dart';
import '../services/agent_host_registry.dart';
import '../services/agent_stream_reducer.dart';
import '../services/ai_service.dart';
import '../services/command_executor.dart';
import '../services/conversation_service.dart';
import '../services/knowledge_service.dart';
import '../core/credentials_store.dart';
import '../services/daos.dart';
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

  /// 当前引擎所属的 hostId（用于回调路由）
  String? _engineHostId;

  final ConversationService _convService = ConversationService();

  /// 日志订阅取消函数
  void Function()? _logUnsubscribe;

  AgentNotifier() : super(AgentState()) {
    // 订阅 AgentLogger，将日志写入产生日志时的 hostId 会话（避免多 host 串台）
    _logUnsubscribe = agentLogger.subscribe((level, tag, message, timestamp, hostId) {
      // 优先用日志产生时的 hostId（currentHostId），回退到当前活跃 host
      final effectiveHostId = hostId ?? _registry.activeHostId;
      if (effectiveHostId == null) return;
      _convService.appendAgentLog(effectiveHostId, level: level, tag: tag, message: message)
          .catchError((e) { debugPrint('[AgentNotifier] 日志写入失败: $e'); });
    });
  }

  /// 获取当前 host 的记忆实例（不存在则创建）
  AgentMemory _getMemory(String hostId) {
    var memory = _registry.getMemory(hostId);
    if (memory == null) {
      memory = AgentMemory();
      _registry.setMemory(hostId, memory);
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

  /// 切换到指定 host（保存当前状态，加载目标 host 状态）
  /// [tabId] 保留兼容旧调用，实际用 hostId 隔离
  void switchTab(String tabId, {String? hostId}) {
    final effectiveHostId = hostId ?? 'local';

    // R3: 切换前取消当前 host 的运行任务并重置 reducer，避免旧 tab 的流式 chunk 串台到新会话
    final oldHostId = _registry.activeHostId;
    if (oldHostId != null && oldHostId != effectiveHostId) {
      if (_engine != null && _engine!.isRunning) {
        _engine!.cancelTask();
      }
      _reducer.cancelTimer(oldHostId);
      _reducer.reset(oldHostId);
    }

    // 保存当前 host 状态
    _registry.saveActiveState(state);

    _registry.setActive(effectiveHostId);
    // 同步日志路由的 hostId，避免多 host 串台
    agentLogger.currentHostId = effectiveHostId;

    // 加载目标 host 状态：先从内存缓存读，再从持久化恢复
    if (_registry.hasState(effectiveHostId)) {
      state = _registry.getState(effectiveHostId)!;
      _engine = _registry.getEngine(effectiveHostId);
      _executor = _registry.getExecutor(effectiveHostId);
      _modelConfig = _registry.getModelConfig(effectiveHostId);
      _engineHostId = effectiveHostId;
    } else {
      // 新 host：从持久化恢复，或创建新会话
      _restoreFromPersistence(effectiveHostId);
      _engine = null;
      _executor = null;
      // 恢复该 host 的模型配置，或保留当前全局配置
      _modelConfig = _registry.getModelConfig(effectiveHostId) ?? _modelConfig;
      _reinitEngineForCurrentHost();
    }

    // R3: 编排模式状态同步 — 确保 engine 的编排开关与 state.isOrchestratorMode 一致
    // 防止 engine 被重新初始化后编排标志丢失，但 state 仍为 true 的不一致情况
    _syncOrchestratorMode();
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
  }

  /// 从持久化恢复会话到内存状态
  void _restoreFromPersistence(String hostId) {
    final conv = _convService.getActiveSession(hostId);
    if (conv == null) {
      state = AgentState(hostId: hostId, maxSteps: state.maxSteps);
      return;
    }
    debugPrint('[AgentNotifier] _restoreFromPersistence: hostId=$hostId messages=${conv.messages.length}');
    for (final m in conv.messages) {
      debugPrint('[AgentNotifier]   msg: role=${m.role} contentLength=${m.content.length} events=${m.events?.length}');
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

  /// 从持久化恢复引擎对话历史（切换会话 / 新建引擎时调用）
  /// 传 AI 时优先用 effectiveContent (summary ?? content)
  void _restoreEngineHistory() {
    if (_engine == null) return;
    final convId = state.conversationId;
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

  /// 关闭 tab/host 时清除其状态和记忆
  void removeTab(String tabId, {String? hostId}) {
    // 旧接口兼容：tabId 不再用于状态隔离，仅清理可能的引用
    if (hostId != null) {
      final engine = _registry.getEngine(hostId);
      if (engine != null) {
        // L16 修复：先清空回调再 cancel，避免 cancelTask 触发的 onTaskUpdated 污染状态
        engine.onMessage = null;
        engine.onThinking = null;
        engine.onEvent = null;
        engine.onCommandGenerated = null;
        engine.onCommandExecuted = null;
        engine.onError = null;
        engine.onTaskUpdated = null;
        engine.onCompleted = null;
        engine.cancelTask();
        // R2: 清理工具资源（file_sync 的 watcher/timer/SFTP 等）
        engine.disposeTools();
      }
      _registry.removeHost(hostId);
      _reducer.cancelTimer(hostId);
      _reducer.reset(hostId);
      _lastPersistedLen.remove(hostId);
      _persistChain.remove(hostId);
      // 如果移除的是当前活跃 host，清空引用防止后续操作命中已 disposed 的引擎
      if (_engineHostId == hostId) {
        _engineHostId = null;
        _engine = null;
        _executor = null;
      }
    }
  }

  /// 为当前 host 重新初始化引擎（如果有模型配置）
  void _reinitEngineForCurrentHost() {
    final hostId = _registry.activeHostId;
    if (_modelConfig != null && hostId != null) {
      final memory = _getMemory(hostId);
      final aiProvider = AIService.create(_modelConfig!);
      _engine = AgentEngine(
        aiProvider: aiProvider,
        modelConfig: _modelConfig!,
        memory: memory,
        maxSteps: state.maxSteps,
        hostId: hostId,
      );
      _setupEngineCallbacks(hostId);
      _registry.setEngine(hostId, _engine!);
      _registry.setModelConfig(hostId, _modelConfig);
      // 从持久化恢复引擎对话历史和摘要
      _restoreEngineHistory();
      // 从安全存储加载 sudo 密码注入到 engine
      _loadSudoPasswordForHost(hostId, _engine!);
    }
  }

  /// tab-aware 状态更新：如果回调所属 host 是当前活跃 host，更新 state；
  /// 否则只更新注册表中的缓存，避免跨 host 污染
  void _updateHostState(String hostId, AgentState Function(AgentState) updater) {
    if (_registry.isActive(hostId)) {
      state = updater(state);
    } else {
      _registry.updateState(hostId, updater);
    }
  }

  /// 初始化 Agent
  void init({
    required AIModelConfig modelConfig,
    required AIProvider aiProvider,
  }) {
    _modelConfig = modelConfig;

    final hostId = _registry.activeHostId ?? 'local';
    final memory = _getMemory(hostId);

    // 若旧引擎存在（如切换 AI 模型时），先安全清理：清空回调 → cancelTask → disposeTools
    // 防止旧引擎的回调继续写当前 host 的 state，造成双引擎并发污染
    if (_engine != null) {
      _engine!.onMessage = null;
      _engine!.onThinking = null;
      _engine!.onEvent = null;
      _engine!.onCommandGenerated = null;
      _engine!.onCommandExecuted = null;
      _engine!.onError = null;
      _engine!.onTaskUpdated = null;
      _engine!.onCompleted = null;
      _engine!.cancelTask();
      _engine!.disposeTools();
    }

    _engine = AgentEngine(
      aiProvider: aiProvider,
      modelConfig: modelConfig,
      memory: memory,
      maxSteps: state.maxSteps,
      hostId: hostId,
    );

    _setupEngineCallbacks(hostId);

    // 保存到当前 host
    if (_registry.activeHostId != null) {
      _registry.setEngine(_registry.activeHostId!, _engine!);
      _registry.setModelConfig(_registry.activeHostId!, _modelConfig);
    }

    // 恢复引擎对话历史（切换模型后 AI 仍能看到之前的对话上下文）
    _restoreEngineHistory();

    // 从安全存储加载 sudo 密码注入到 engine
    _loadSudoPasswordForHost(hostId, _engine!);
  }

  void _setupEngineCallbacks(String hostId) {
    _engineHostId = hostId;
    _engine!.onThinking = (msg) {
      // 新一轮 AI 流式开始：先把上一轮的 streamingContent 累积到 content 并保存
      _flushStreamingToContent(hostId);
      _reducer.reset(hostId);
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
      _reducer.append(hostId, msg);
      // 每 hostId 独立节流 Timer，避免多 host 互相阻塞
      _reducer.scheduleFlush(
        hostId,
        const Duration(milliseconds: _agentStreamThrottleMs),
        (content) {
          _updateHostState(hostId, (s) {
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
              final lastLen = _lastPersistedLen[hostId] ?? 0;
              if (fullContent.length - lastLen > 500) {
                _lastPersistedLen[hostId] = fullContent.length;
                _persistAssistantCompletion(hostId, fullContent, events: lastItem.events);
              }
            }
            return s.copyWith(lastMessage: content, chatItems: items);
          });
        },
      );
    };

    /// 结构化事件回调：追加事件（不清空 streamingContent，避免流式过程中闪烁）
    _engine!.onEvent = (event) {
      // R3: 必须从正确的 host 状态读取数据，不能直接用 state（活跃 host）
      // 否则非活跃 host 的事件会被持久化到错误的会话
      AgentState? hostState;
      _updateHostState(hostId, (s) {
        hostState = s; // 捕获更新前的 host 状态引用
        final items = [...s.chatItems];
        if (items.isEmpty || items.last.role != 'assistant') return s;
        final lastItem = items.last;
        final events = [...lastItem.events, event];
        items[items.length - 1] = lastItem.copyWith(
          events: events,
          isStreaming: s.isRunning,
        );
        hostState = s.copyWith(chatItems: items); // 捕获更新后的状态
        return hostState!;
      });
      // 命令/结果事件即时持久化：使用 hostState（正确 host 的状态）而非 state（活跃 host）
      if (event.type == AgentEventType.command || event.type == AgentEventType.result) {
        final items = hostState?.chatItems ?? state.chatItems;
        if (items.isNotEmpty && items.last.role == 'assistant') {
          _persistAssistantCompletion(hostId, items.last.content, events: items.last.events);
        }
      }
    };

    _engine!.onCommandGenerated = (cmd) {
      _updateHostState(hostId, (s) => s.copyWith(status: AgentStatus.executing));
    };

    _engine!.onCommandExecuted = (result) {
      // 命令执行完，结果已通过 onEvent(AgentEvent.result) 发出
      // 此时结果已发给 AI，AI 开始思考下一步，状态改为 thinking
      _updateHostState(hostId, (s) => s.copyWith(status: AgentStatus.thinking));
    };

    _engine!.onError = (error) {
      // 出错时也保存当前内容
      _flushStreamingToContent(hostId);
      _updateHostState(hostId, (s) {
        // AI 调用失败时 assistant 消息可能为空（无流式内容）
        // 用错误信息填充并持久化，确保引擎重建恢复时 AI 能看到上下文
        final items = [...s.chatItems];
        if (items.isNotEmpty && items.last.role == 'assistant' && items.last.content.isEmpty) {
          final errorMsg = '⚠️ $error';
          items[items.length - 1] = ChatItem(
            role: 'assistant',
            content: errorMsg,
            isStreaming: false,
          );
          _persistAssistantCompletion(hostId, errorMsg);
          return s.copyWith(chatItems: items, error: error);
        }
        return s.copyWith(error: error);
      });
    };

    _engine!.onTaskUpdated = (task) {
      // 任务进入终态时清除 error：让之前因 isRunning 拒绝等设置的 error 不残留
      final isTerminal = task.status == AgentStatus.completed ||
          task.status == AgentStatus.failed ||
          task.status == AgentStatus.cancelled;
      _updateHostState(hostId, (s) => s.copyWith(
        currentTask: task,
        status: task.status,
        pendingConfirmCommand: _engine!.pendingConfirmCommand,
        pendingOptions: _engine!.pendingOptions.isNotEmpty ? _engine!.pendingOptions : null,
        clearPendingOptions: _engine!.pendingOptions.isEmpty,
        clearError: isTerminal,
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
          // 记录成功经验到用户经验库（异步，不阻塞 UI）
          _recordLearningFromTask(hostId, items, fullMessage);
        }
        return s.copyWith(chatItems: items);
      });
    };
  }

  /// 将当前流式内容累积到 content 中，并持久化保存
  void _flushStreamingToContent(String hostId) {
    final streamingContent = _reducer.getContent(hostId);
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
      // 持久化保存（含 events），并更新已持久化长度
      _lastPersistedLen[hostId] = newContent.length;
      _persistAssistantCompletion(hostId, newContent, events: lastItem.events);
      return s.copyWith(chatItems: items);
    });

    _reducer.cancelTimer(hostId);
    _reducer.reset(hostId);
  }

  /// 任务成功完成后，将经验记录到用户经验库（异步，不阻塞 UI）
  /// 使用捕获的 hostId（R3：不使用 activeHostId，避免切换 host 后写错库）
  void _recordLearningFromTask(String hostId, List<ChatItem> items, String aiSummary) {
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
          if (event.isCommand && event.command != null && event.command!.isNotEmpty) {
            commands.add(event.command!);
          }
        }
        if (commands.isEmpty) return;

        // R8：截断过长内容，防止无界增长
        final truncatedRequest = userRequest.length > 500
            ? userRequest.substring(0, 500)
            : userRequest;
        final truncatedSummary = aiSummary.length > 1000
            ? aiSummary.substring(0, 1000)
            : aiSummary;
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
  Future<void> _persistAssistantCompletion(
    String hostId,
    String content, {
    List<AgentEvent>? events,
  }) async {
    // 串行化：接在上一次持久化之后执行，防止并发 save 覆盖
    final prev = _persistChain[hostId] ?? Future.value();
    final next = prev.then((_) async {
      try {
        await _convService.updateLastAssistantContent(hostId, content, events: events);
      } catch (e) {
        debugPrint('[AgentNotifier] 持久化 assistant 内容失败 (hostId=$hostId): $e');
      }
    });
    _persistChain[hostId] = next;
    return next;
  }

  /// 设置命令执行器（SSH 或本地 PTY，仅首次连接时收集系统信息）
  void setExecutor(CommandExecutor? executor) {
    _executor = executor;
    if (_registry.activeHostId != null) {
      _registry.setExecutor(_registry.activeHostId!, executor);
    }
    if (executor != null && _engine != null) {
      final hostId = _registry.activeHostId;
      if (hostId != null && !_registry.hasSysInfoFuture(hostId)) {
        _registry.setSysInfoFuture(hostId, _engine!.collectSystemInfo(executor));
      }
      // 连接建立后（重新）加载 sudo 密码，覆盖 host 配置变更后的场景
      if (hostId != null) {
        _loadSudoPasswordForHost(hostId, _engine!);
      }
    }
  }

  /// 设置最大步骤数
  void setMaxSteps(int steps) {
    state = state.copyWith(maxSteps: steps);
    _engine?.maxSteps = steps;
    SettingsDao.set('agentMaxSteps', steps)
        .catchError((e) { debugPrint('[AgentNotifier] 保存 maxSteps 失败: $e'); });
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
    } catch (e) { debugPrint('[AgentNotifier] 加载设置失败: $e'); }
  }

  /// 开始任务
  Future<void> startTask(String goal) async {
    // 防重复发送：小白用户可能快速点击多次发送按钮
    // 必须在持久化之前同步检查，否则会产生孤儿消息（用户消息重复但无 AI 回复）
    if (_engine != null && _engine!.isRunning) {
      state = state.copyWith(error: 'Agent 正在执行任务，请等待完成');
      return;
    }

    if (_engine == null) {
      if (_modelConfig != null) {
        _reinitEngineForCurrentHost();
      }
      if (_engine == null) {
        state = state.copyWith(error: L10n.str.pleaseConfigAIModel);
        return;
      }
    }

    // 检查终端连接：小白可能不知道 SSH 已断开，继续发任务会失败
    if (_executor != null && !_executor!.isConnected) {
      state = state.copyWith(error: '终端未连接，请先连接终端');
      return;
    }

    // 输入校验：超长消息截断，防止小白粘贴 MB 级文本撑爆 AI 上下文
    if (goal.length > 10000) {
      goal = '${goal.substring(0, 10000)}\n\n${L10n.str.orchInputTruncated}';
    }

    final hostId = _registry.activeHostId ?? 'local';
    _reducer.cancelTimer(hostId);
    _reducer.reset(hostId);
    // 确保日志路由到正确的 host（startTask 可能从非 UI 线程触发）
    agentLogger.currentHostId = hostId;

    // 持久化用户消息 + assistant 占位（原子写入，消除两次 save 之间的崩溃窗口）
    String? convId;
    try {
      final conv = await _convService.appendMessagePair(
        hostId,
        userContent: goal,
        assistantContent: '',
      );
      convId = conv.id;
    } catch (e) {
      // R8: 持久化失败必须告知用户，不能静默吞掉后继续启动引擎制造假象
      agentLogger.error('AgentNotifier', '持久化消息失败: $e');
      state = state.copyWith(error: '${L10n.str.messageSaveFailed}: $e');
      return;
    }

    // 同步会话 id 到 state（首次创建时）
    if (state.conversationId != convId) {
      state = state.copyWith(conversationId: convId, hostId: hostId);
    }

    // 添加用户消息 + AI 占位到 chatItems
    final items = [...state.chatItems,
      ChatItem(role: 'user', content: goal),
      ChatItem(role: 'assistant', content: '', isStreaming: true),
    ];

    state = state.copyWith(
      status: AgentStatus.thinking,
      chatItems: items,
      lastMessage: '',
      currentTask: null,
      clearError: true,
    );
    // 重置该 host 的持久化长度计数器（新 assistant 消息从 0 开始累积）
    _lastPersistedLen[hostId] = 0;

    // 如果系统信息还没收集，先收集再开始任务，避免命令混在一起
    if (_executor != null && !_registry.hasSysInfoFuture(hostId)) {
      _registry.setSysInfoFuture(hostId, _engine!.collectSystemInfo(_executor!));
    }
    final sysInfoFuture = _registry.getSysInfoFuture(hostId);
    if (sysInfoFuture != null) {
      await sysInfoFuture;
    }

    await _engine!.startTask(goal, _executor);

    // 任务结束后检查是否需要自动压缩
    _maybeAutoCompact(hostId);
  }

  /// 取消任务
  void cancel() {
    // 取消前先保存当前内容
    final hostId = _engineHostId;
    if (hostId != null) {
      _flushStreamingToContent(hostId);
      // 如果流式内容为空（thinking 阶段取消），assistant 占位仍为空
      // 填充取消提示并持久化，避免恢复后出现空 assistant 消息
      _updateHostState(hostId, (s) {
        final items = [...s.chatItems];
        if (items.isNotEmpty && items.last.role == 'assistant' &&
            items.last.content.isEmpty && items.last.streamingContent.isEmpty) {
          items[items.length - 1] = items.last.copyWith(
            content: L10n.str.taskCancelled,
            isStreaming: false,
          );
          _persistAssistantCompletion(hostId, L10n.str.taskCancelled, events: items.last.events);
        }
        return s.copyWith(chatItems: items);
      });
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
    final hostId = _registry.activeHostId;
    final convId = state.conversationId;
    state = state.copyWith(chatItems: [], lastMessage: '', clearSummary: true);
    if (hostId != null && convId != null) {
      try {
        await _convService.clearMessages(convId);
      } catch (e) {
        agentLogger.error('AgentNotifier', '清空持久化消息失败: $e');
        state = state.copyWith(error: '${L10n.str.clearMessagesFailed}: $e');
      }
    }
  }

  /// 清空当前 host 的记忆
  void clearMemory() {
    if (_registry.activeHostId != null) {
      _getMemory(_registry.activeHostId!).clear();
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

  // ═══════════════════════════════════════════
  // 会话管理（侧边栏调用）
  // ═══════════════════════════════════════════

  /// 新建会话（结束当前会话，创建空白会话）
  Future<void> newSession() async {
    final hostId = _registry.activeHostId;
    if (hostId == null) return;
    _engine?.clearHistory();
    final conv = _convService.createSession(hostId: hostId);
    _reducer.cancelTimer(hostId);
    _reducer.reset(hostId);
    state = AgentState(
      hostId: hostId,
      conversationId: conv.id,
      maxSteps: state.maxSteps,
    );
  }

  /// 切换到指定会话（侧边栏点击）
  Future<void> switchSession(String conversationId) async {
    final hostId = _registry.activeHostId;
    if (hostId == null) return;
    // 先保存当前流式内容到旧会话（cancelTask 后引擎退出，不再有 onCompleted 触发保存）
    _flushStreamingToContent(hostId);
    // L7 修复：取消当前任务 + 重置 reducer，避免旧任务的事件/流式内容串台到新会话
    _engine?.cancelTask();
    _reducer.cancelTimer(hostId);
    _reducer.reset(hostId);
    _convService.setActive(hostId, conversationId);
    _restoreFromPersistence(hostId);
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
      final hostId = _registry.activeHostId;
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
    final hostId = _registry.activeHostId;
    if (hostId == null) return [];
    return _convService.listSessions(hostId);
  }

  // ═══════════════════════════════════════════
  // 记忆压缩
  // ═══════════════════════════════════════════

  /// 判断是否需要自动压缩（任务结束后调用）
  /// [taskHostId] 发起任务的 host，避免切换 host 后压缩错误的会话
  void _maybeAutoCompact(String taskHostId) {
    final convId = _registry.getState(taskHostId)?.conversationId;
    if (convId == null) return;

    final conv = ConversationsDao.getCachedById(convId);
    if (conv == null) return;

    // 统计未压缩的消息（summary 为空的非系统消息）
    final unsummarized = conv.messages.where((m) =>
        m.role != 'system' && (m.summary == null || m.summary!.isEmpty));
    final rounds = unsummarized.length ~/ 2;
    // 基于有效内容计算字符数（已压缩的用 summary 长度）
    final needsCompact = rounds >= _compactThresholdRounds || conv.totalChars >= _compactThresholdChars;
    final isCompacting = _registry.getState(taskHostId)?.isCompacting ?? false;
    if (needsCompact && !isCompacting) {
      compact(taskHostId).catchError((e) { debugPrint('[AgentNotifier] 自动压缩失败: $e'); });
    }
  }

  /// 压缩对话：一次性调用 AI 将早期消息逐条压缩，写入 ConvMessage.summary
  /// 保留最近 N 轮原文不压缩，确保 AI 有足够近期上下文
  /// 压缩期间加锁（isCompacting），UI 显示"会话压缩中"横幅
  Future<void> compact([String? taskHostId]) async {
    final hostId = taskHostId ?? _registry.activeHostId;
    if (hostId == null) return;
    final convId = _registry.getState(hostId)?.conversationId;
    if (convId == null) return;
    final engine = _registry.getEngine(hostId);
    if (engine == null) return;
    final hostState = _registry.getState(hostId);
    if (hostState == null) return;
    if (hostState.isCompacting) return; // 防止并发压缩

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
    _updateHostState(hostId, (s) => s.copyWith(isCompacting: true));

    try {
      // 构造压缩输入
      final tuples = <({int index, String role, String content, String? command, bool? commandSuccess})>[];
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
        _updateHostState(hostId, (s) => s.copyWith(isCompacting: false));
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
      _syncEngineHistoryAfterCompact(hostId, convId);

      // 更新 UI 状态
      final restored = ConversationsDao.getCachedById(convId);
      if (restored != null) {
        final items = restored.messages
            .where((m) => m.role != 'system')
            .map((m) => ChatItem.fromConvMessage(m))
            .toList();
        _updateHostState(hostId, (s) => s.copyWith(
          chatItems: items,
          isCompacting: false,
        ));
      } else {
        _updateHostState(hostId, (s) => s.copyWith(isCompacting: false));
      }
    } catch (e) {
      agentLogger.error('AgentNotifier', '对话压缩失败: $e');
      _updateHostState(hostId, (s) => s.copyWith(isCompacting: false, error: '${L10n.str.compactFailed}: $e'));
    }
  }

  /// 压缩后同步引擎内存历史：用 effectiveContent 重建 _conversationHistory
  void _syncEngineHistoryAfterCompact(String hostId, String convId) {
    final engine = _registry.getEngine(hostId);
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
      engine.onMessage = null;
      engine.onEvent = null;
      engine.onThinking = null;
      engine.onCommandGenerated = null;
      engine.onCommandExecuted = null;
      engine.onError = null;
      engine.onTaskUpdated = null;
      engine.onCompleted = null;
      engine.cancelTask();
      // R2: 清理工具资源（如文件同步的 watcher 和 timer）
      engine.disposeTools();
    }
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
