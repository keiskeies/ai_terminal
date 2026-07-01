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
import '../core/hive_init.dart';
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

  /// 切换到指定 host（保存当前状态，加载目标 host 状态）
  /// [tabId] 保留兼容旧调用，实际用 hostId 隔离
  void switchTab(String tabId, {String? hostId}) {
    final effectiveHostId = hostId ?? 'local';

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
  /// 只恢复 summarizedUpToIndex 之后的消息（已摘要的不再恢复）
  void _restoreEngineHistory() {
    if (_engine == null) return;
    final convId = state.conversationId;
    if (convId == null) {
      _engine!.clearHistory();
      return;
    }
    final conv = HiveInit.conversationsBox.get(convId);
    if (conv == null) {
      _engine!.clearHistory();
      return;
    }
    // 提取 summarizedUpToIndex 之后的非 system 消息
    final startIdx = conv.summarizedUpToIndex > 0
        ? conv.summarizedUpToIndex
        : 0;
    final msgs = <ChatMessage>[];
    for (int i = startIdx; i < conv.messages.length; i++) {
      final m = conv.messages[i];
      if (m.role == 'system') continue;
      msgs.add(ChatMessage.create(role: m.role, content: m.content));
    }
    _engine!.restoreHistory(msgs, summary: conv.summary);
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
      }
      _registry.removeHost(hostId);
      _reducer.cancelTimer(hostId);
      _reducer.reset(hostId);
      if (_engineHostId == hostId) _engineHostId = null;
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
      );
      _setupEngineCallbacks(hostId);
      _registry.setEngine(hostId, _engine!);
      _registry.setModelConfig(hostId, _modelConfig);
      // 从持久化恢复引擎对话历史和摘要
      _restoreEngineHistory();
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

    _engine = AgentEngine(
      aiProvider: aiProvider,
      modelConfig: modelConfig,
      memory: memory,
      maxSteps: state.maxSteps,
    );

    _setupEngineCallbacks(hostId);

    // 保存到当前 host
    if (_registry.activeHostId != null) {
      _registry.setEngine(_registry.activeHostId!, _engine!);
      _registry.setModelConfig(_registry.activeHostId!, _modelConfig);
    }
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
              items[items.length - 1] = items.last.copyWith(
                streamingContent: content,
                isStreaming: true,
              );
            }
            return s.copyWith(lastMessage: content, chatItems: items);
          });
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
      // 命令执行完，结果已通过 onEvent(AgentEvent.result) 发出
      // 此时结果已发给 AI，AI 开始思考下一步，状态改为 thinking
      _updateHostState(hostId, (s) => s.copyWith(status: AgentStatus.thinking));
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
      // 持久化保存（含 events）
      _persistAssistantCompletion(hostId, newContent, events: lastItem.events);
      return s.copyWith(chatItems: items);
    });

    _reducer.cancelTimer(hostId);
    _reducer.reset(hostId);
  }

  /// 持久化 assistant 完整响应（流式结束后回写）
  Future<void> _persistAssistantCompletion(
    String hostId,
    String content, {
    List<AgentEvent>? events,
  }) async {
    try {
      await _convService.updateLastAssistantContent(hostId, content, events: events);
    } catch (e) { debugPrint('[AgentNotifier] 持久化 assistant 内容失败: $e'); }
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
    }
  }

  /// 设置最大步骤数
  void setMaxSteps(int steps) {
    state = state.copyWith(maxSteps: steps);
    _engine?.maxSteps = steps;
    try {
      HiveInit.settingsBox.put('agentMaxSteps', steps);
    } catch (e) { debugPrint('[AgentNotifier] 保存 maxSteps 失败: $e'); }
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
    } catch (e) { debugPrint('[AgentNotifier] 加载设置失败: $e'); }
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

    final hostId = _registry.activeHostId ?? 'local';
    _reducer.cancelTimer(hostId);
    _reducer.reset(hostId);
    // 确保日志路由到正确的 host（startTask 可能从非 UI 线程触发）
    agentLogger.currentHostId = hostId;

    // 持久化用户消息
    try {
      final conv = await _convService.appendMessage(hostId, role: 'user', content: goal);
      // 同步会话 id 到 state（首次创建时）
      if (state.conversationId != conv.id) {
        state = state.copyWith(conversationId: conv.id, hostId: hostId);
      }
    } catch (e) { debugPrint('[AgentNotifier] 持久化用户消息失败: $e'); }

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
    } catch (e) { debugPrint('[AgentNotifier] 持久化 assistant 占位失败: $e'); }

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
        state = state.copyWith(error: '清空消息失败: $e');
      }
    }
  }

  /// 清空当前 host 的记忆
  void clearMemory() {
    if (_registry.activeHostId != null) {
      _getMemory(_registry.activeHostId!).clear();
    }
    state = state.copyWith(error: null);
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

    final conv = HiveInit.conversationsBox.get(convId);
    if (conv == null) return;

    final rounds = conv.messages.where((m) => m.role != 'system').length ~/ 2;
    final needsCompact = rounds >= _compactThresholdRounds || conv.totalChars >= _compactThresholdChars;
    final isCompacting = _registry.getState(taskHostId)?.isCompacting ?? false;
    if (needsCompact && !isCompacting) {
      compact(taskHostId).catchError((e) { debugPrint('[AgentNotifier] 自动压缩失败: $e'); });
    }
  }

  /// 手动/自动压缩：用 AI 总结早期对话为摘要，保留最近 N 轮原文
  /// [taskHostId] 指定要压缩的 host，避免操作错误的活跃 host
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

    final conv = HiveInit.conversationsBox.get(convId);
    if (conv == null) return;

    // 待压缩 = 已摘要索引之后的所有非系统消息 - 保留的最近 N 轮
    final allMsgs = conv.messages.where((m) => m.role != 'system').toList();
    final keepCount = _compactKeepRounds * 2;
    if (allMsgs.length <= keepCount) return; // 太少不压缩

    // 从 summarizedUpToIndex 之后开始压缩（避免重复压缩已摘要的消息）
    final nonSysStart = conv.messages.indexWhere((m) => m.role != 'system');
    final startIdx = conv.summarizedUpToIndex > nonSysStart
        ? conv.summarizedUpToIndex - nonSysStart
        : 0;

    // 没有新的未摘要消息可压缩（startIdx 已追上保留边界）
    if (startIdx >= allMsgs.length - keepCount) return;

    final toSummarize = allMsgs.sublist(startIdx, allMsgs.length - keepCount);
    if (toSummarize.isEmpty) return;

    // L8 修复：用 _updateHostState 更新指定 host，避免覆盖活跃 host
    _updateHostState(hostId, (s) => s.copyWith(isCompacting: true));
    try {
      final tuples = toSummarize
          .map((m) => (role: m.role, content: m.content))
          .toList();
      final summaryText = await engine.summarize(tuples);
      if (summaryText != null && summaryText.isNotEmpty) {
        await _convService.applySummary(convId, summaryText);
        // 同步引擎内存：注入摘要到系统提示 + 裁剪已摘要的旧消息
        engine.setConversationSummary(summaryText);
        engine.syncAfterCompact(_compactKeepRounds);
        // 同步到 UI 状态
        final restored = HiveInit.conversationsBox.get(convId);
        if (restored != null) {
          final items = restored.messages
              .where((m) => m.role != 'system')
              .map((m) => ChatItem.fromConvMessage(m))
              .toList();
          _updateHostState(hostId, (s) => s.copyWith(
            chatItems: items,
            summary: restored.summary,
            isCompacting: false,
          ));
        } else {
          _updateHostState(hostId, (s) => s.copyWith(isCompacting: false));
        }
      } else {
        // 压缩返回空（AI 无响应或消息太少）
        agentLogger.warn('AgentNotifier', '对话压缩未产生摘要（AI 返回空或消息不足）');
        _updateHostState(hostId, (s) => s.copyWith(isCompacting: false));
      }
    } catch (e) {
      agentLogger.error('AgentNotifier', '对话压缩失败: $e');
      _updateHostState(hostId, (s) => s.copyWith(isCompacting: false, error: '对话压缩失败: $e'));
    }
  }

  @override
  void dispose() {
    // 停止所有引擎任务并清空回调，防止 dispose 后回调仍写 state
    for (final engine in _registry.engines) {
      engine.cancelTask();
      engine.onMessage = null;
      engine.onEvent = null;
      engine.onThinking = null;
      engine.onCommandGenerated = null;
      engine.onCommandExecuted = null;
      engine.onError = null;
      engine.onTaskUpdated = null;
      engine.onCompleted = null;
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
