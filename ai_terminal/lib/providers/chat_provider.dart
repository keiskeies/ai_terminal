import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_session.dart';
import '../models/ai_model_config.dart';
import '../models/conversation.dart';
import '../services/ai_service.dart';
import '../services/ai_model_selection_service.dart';
import '../services/conversation_service.dart';
import '../services/conversation_title_service.dart';
import '../services/daos.dart';
import '../services/agent_logger.dart';
import '../utils/ansi_stripper.dart';
import '../utils/tail_text_buffer.dart';
import '../core/l10n_holder.dart';

/// 流式更新节流间隔（毫秒）
const int _streamThrottleMs = 120;

/// 聊天状态
class ChatState {
  final List<ChatMessage> messages;
  final bool isLoading;
  final String? error;
  final String? currentHostId;
  final String? currentAssistantMessage;

  // 只保存上一条命令的执行结果
  final String lastCommandOutput;

  /// 当前会话 id（持久化用）
  final String? conversationId;

  /// 早期对话摘要（压缩后产生）
  final String? summary;

  ChatState({
    this.messages = const [],
    this.isLoading = false,
    this.error,
    this.currentHostId,
    this.currentAssistantMessage,
    this.lastCommandOutput = '',
    this.conversationId,
    this.summary,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isLoading,
    String? error,
    String? currentHostId,
    String? currentAssistantMessage,
    String? lastCommandOutput,
    String? conversationId,
    String? summary,
    bool clearCurrentHostId = false,
    bool clearConversationId = false,
    bool clearSummary = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      currentHostId:
          clearCurrentHostId ? null : (currentHostId ?? this.currentHostId),
      currentAssistantMessage: currentAssistantMessage,
      lastCommandOutput: lastCommandOutput ?? this.lastCommandOutput,
      conversationId:
          clearConversationId ? null : (conversationId ?? this.conversationId),
      summary: clearSummary ? null : (summary ?? this.summary),
    );
  }
}

/// 尾截断：保留输出尾部（长输出有价值的信息通常在末尾）
String _tailTruncate(String text, int maxChars) {
  final tail = ConversationService.tailCap(text, maxChars);
  if (tail.length == text.length) return text;
  return '...(已截断前 ${text.length - tail.length} 字符)\n$tail';
}

/// 聊天 Provider — 每个 hostId 独立聊天状态（持久化）
final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier();
});

class ChatNotifier extends StateNotifier<ChatState> {
  StreamSubscription<String>? _streamSubscription;

  /// 每个 hostId 的聊天状态缓存
  final Map<String, ChatState> _hostStates = {};

  /// 当前活跃的 hostId
  String? _activeHostId;
  String? _activeTabId;
  final Map<String, String> _tabHosts = {};
  final Map<String, Set<String>> _hostTabs = {};

  /// 流式输出节流：累积文本但限制 UI 更新频率
  Timer? _throttleTimer;
  Object? _activeRequest;
  CancelToken? _activeCancelToken;
  String? _requestHostId;
  final Map<String, int> _hostMutationEpochs = {};
  final Map<String, int> _conversationMutationEpochs = {};

  int _hostEpoch(String hostId) => _hostMutationEpochs[hostId] ?? 0;

  int _conversationEpoch(String conversationId) =>
      _conversationMutationEpochs[conversationId] ?? 0;

  bool _canPersistCancellation(
    String hostId,
    String conversationId,
    int hostEpoch,
    int conversationEpoch,
  ) =>
      _hostEpoch(hostId) == hostEpoch &&
      _conversationEpoch(conversationId) == conversationEpoch;

  ChatState _stateForHost(String hostId) => _activeHostId == hostId
      ? state
      : (_hostStates[hostId] ?? ChatState(currentHostId: hostId));

  void _updateHostState(String hostId, ChatState Function(ChatState) update) {
    final next = update(_stateForHost(hostId));
    if (_activeHostId == hostId) {
      state = next;
    } else {
      _hostStates[hostId] = next;
    }
  }

  void _invalidateRequest() {
    final requestHostId = _requestHostId;
    _activeRequest = Object();
    _activeCancelToken?.cancel('聊天请求已失效');
    _activeCancelToken = null;
    _requestHostId = null;
    _streamSubscription?.cancel();
    _streamSubscription = null;
    _throttleTimer?.cancel();
    _throttleTimer = null;
    if (requestHostId != null) {
      _updateHostState(
          requestHostId,
          (s) => s.copyWith(
                isLoading: false,
                currentAssistantMessage: null,
              ));
    }
  }

  final ConversationService _convService = ConversationService();
  final ConversationTitleService _titleService = ConversationTitleService();

  ChatNotifier() : super(ChatState());

  /// 切换到指定 host（保存当前状态，加载目标 host 状态）
  void switchTab(String tabId, {String? hostId}) {
    final effectiveHostId = hostId ?? 'local';
    if (_activeHostId != null && _activeHostId != effectiveHostId) {
      _invalidateRequest();
    }

    if (_activeHostId != null) {
      _hostStates[_activeHostId!] = state;
    }
    final previousTabHost = _tabHosts.remove(_activeTabId);
    if (previousTabHost != null) {
      _hostTabs[previousTabHost]?.remove(_activeTabId);
    }
    _activeTabId = tabId;
    _tabHosts[tabId] = effectiveHostId;
    _hostTabs.putIfAbsent(effectiveHostId, () => {}).add(tabId);
    _activeHostId = effectiveHostId;

    if (_hostStates.containsKey(effectiveHostId)) {
      state = _hostStates[effectiveHostId]!;
    } else {
      _restoreFromPersistence(effectiveHostId);
    }
  }

  /// 从持久化恢复
  void _restoreFromPersistence(String hostId) {
    final conv = _convService.getActiveSession(hostId);
    if (conv == null) {
      state = ChatState(currentHostId: hostId);
      return;
    }
    state = ChatState(
      currentHostId: hostId,
      conversationId: conv.id,
      messages: _messagesFromConversation(conv),
      summary: conv.summary,
    );
  }

  /// 持久化的 ConvMessage 转为 ChatMessage（旧模型）
  List<ChatMessage> _messagesFromConversation(Conversation conv) =>
      conv.messages
          .where((m) => m.role != 'system')
          .map((m) => ChatMessage.create(
                role: m.role,
                content: m.isAssistant
                    ? ConversationService.capAssistantContent(m.content)
                    : m.content,
              ))
          .toList();

  /// 关闭 tab 时清除其聊天记录
  void removeTab(String tabId, {String? hostId}) {
    final effectiveHostId = hostId ?? _tabHosts[tabId];
    if (effectiveHostId == null) return;
    _tabHosts.remove(tabId);
    final tabs = _hostTabs[effectiveHostId];
    tabs?.remove(tabId);
    final isLastHostTab = tabs?.isEmpty ?? true;
    if (isLastHostTab) {
      _hostTabs.remove(effectiveHostId);
      if (_requestHostId == effectiveHostId) _invalidateRequest();
      _hostMutationEpochs[effectiveHostId] = _hostEpoch(effectiveHostId) + 1;
    }
    final cached = isLastHostTab ? _hostStates.remove(effectiveHostId) : null;
    final conversationId = _activeHostId == effectiveHostId
        ? state.conversationId
        : cached?.conversationId;
    if (conversationId != null && isLastHostTab) {
      _conversationMutationEpochs[conversationId] =
          _conversationEpoch(conversationId) + 1;
    }
    if (isLastHostTab && _activeHostId == effectiveHostId) {
      _activeHostId = null;
      _activeTabId = null;
      state = ChatState();
    } else if (_activeTabId == tabId) {
      _activeTabId = null;
    }
  }

  /// 发送消息
  Future<void> sendMessage(String content,
      {String? hostId, AIModelConfig? config}) async {
    if (content.trim().isEmpty) return;

    final effectiveHostId = hostId ?? _activeHostId ?? 'local';
    final hostEpoch = _hostEpoch(effectiveHostId);
    final persistedConversationId =
        _stateForHost(effectiveHostId).conversationId;
    // R1: epoch 必须在 await 之前捕获。await 之后现取当前值是恒真判断，
    // 删除/清空会话时无法拦住旧任务的回写。
    final persistedConversationEpoch = persistedConversationId == null
        ? 0
        : _conversationEpoch(persistedConversationId);
    _invalidateRequest();
    final request = Object();
    final cancelToken = CancelToken();
    _activeRequest = request;
    _activeCancelToken = cancelToken;
    _requestHostId = effectiveHostId;

    final model = config ?? await _getDefaultModel();
    if (!identical(_activeRequest, request)) return;
    if (model == null) {
      _updateHostState(effectiveHostId, (s) => s.copyWith(error: '请先配置 AI 模型'));
      return;
    }

    final hostState = _stateForHost(effectiveHostId);
    final userMessage = ChatMessage.create(role: 'user', content: content);
    final updatedMessages = [...hostState.messages, userMessage];

    _updateHostState(
        effectiveHostId,
        (s) => s.copyWith(
              messages: updatedMessages,
              isLoading: true,
              error: null,
              currentAssistantMessage: '',
              currentHostId: effectiveHostId,
            ));

    String? conversationId;
    var isFirstUserMessage = false;
    var conversationEpoch = persistedConversationEpoch;
    try {
      final appended = await _appendUserMessage(effectiveHostId, content,
          persistedConversationId: persistedConversationId, request: request);
      final conv = appended.conversation;
      conversationId = conv.id;
      // 沿用原会话用 await 前捕获的值；回落到其它会话时以它当前的
      // epoch 为基线（后续删除会把它 +1，取消回写就能被拦住）。
      conversationEpoch = conv.id == persistedConversationId
          ? persistedConversationEpoch
          : _conversationEpoch(conv.id);
      isFirstUserMessage = conv.messages.where((m) => m.isUser).length == 1;
      if (!identical(_activeRequest, request)) {
        if (_canPersistCancellation(
            effectiveHostId, conv.id, hostEpoch, conversationEpoch)) {
          await _persistAssistant(
              effectiveHostId, L10n.str.taskCancelled, conv.id);
        }
        return;
      }
      // 回落到新会话时必须同步重建消息列表与摘要，否则界面仍显示已删除
      // 会话的旧历史，而磁盘写入落到了另一个会话。
      _updateHostState(
          effectiveHostId,
          (s) => appended.fellBack
              ? s.copyWith(
                  conversationId: conv.id,
                  messages: _messagesFromConversation(conv),
                  summary: conv.summary,
                  clearSummary: conv.summary == null,
                )
              : s.copyWith(conversationId: conv.id));
    } catch (e) {
      agentLogger.error(
          'ChatNotifier', '持久化用户消息失败 (hostId=$effectiveHostId): $e');
      if (identical(_activeRequest, request)) {
        _updateHostState(effectiveHostId, (s) {
          final messages = s.messages
              .where((message) => !identical(message, userMessage))
              .toList();
          return s.copyWith(
            messages: messages,
            isLoading: false,
            currentAssistantMessage: null,
            error: '消息保存失败: $e',
          );
        });
      }
      return;
    }

    final context = _buildContext(effectiveHostId);
    // 上面的 try 正常退出时一定已写入 conversationId；取局部变量供后续闭包使用。
    final convId = conversationId;
    final history = updatedMessages.length > 10
        ? updatedMessages.sublist(updatedMessages.length - 10)
        : updatedMessages;
    final host = effectiveHostId != 'local'
        ? HostsDao.getCachedById(effectiveHostId)
        : null;

    try {
      final stream = await AIService.sendMessage(
        config: model,
        history: history.take(history.length - 1).toList(),
        prompt: content,
        context: context,
        hostName: host?.name,
        hostAddress:
            host != null ? '${host.username}@${host.host}:${host.port}' : null,
        hostId: host?.id,
        cancelToken: cancelToken,
      );
      if (!identical(_activeRequest, request)) {
        cancelToken.cancel('聊天请求已失效');
        await stream.listen(null).cancel();
        if (_canPersistCancellation(
            effectiveHostId, convId, hostEpoch, conversationEpoch)) {
          await _persistAssistant(
              effectiveHostId, L10n.str.taskCancelled, convId);
        }
        return;
      }

      final responseBuffer =
          TailTextBuffer(ConversationService.maxAssistantContentChars ~/ 2);
      _streamSubscription = stream.listen(
        (chunk) {
          if (!identical(_activeRequest, request)) return;
          responseBuffer.write(chunk);
          _throttleTimer ??= Timer(
            const Duration(milliseconds: _streamThrottleMs),
            () {
              _throttleTimer = null;
              if (!identical(_activeRequest, request)) return;
              final text = ConversationService.capAssistantContent(
                  responseBuffer.toString());
              if (text.isNotEmpty) {
                _updateHostState(effectiveHostId,
                    (s) => s.copyWith(currentAssistantMessage: text));
              }
            },
          );
        },
        onError: (error) {
          _throttleTimer?.cancel();
          _throttleTimer = null;
          if (identical(_activeCancelToken, cancelToken)) {
            _activeCancelToken = null;
          }
          if (!identical(_activeRequest, request)) return;
          _updateHostState(
              effectiveHostId,
              (s) => s.copyWith(
                    isLoading: false,
                    currentAssistantMessage: null,
                    error: error.toString(),
                  ));
        },
        onDone: () {
          _throttleTimer?.cancel();
          _throttleTimer = null;
          if (identical(_activeCancelToken, cancelToken)) {
            _activeCancelToken = null;
          }
          if (!identical(_activeRequest, request)) return;
          final fullResponse = ConversationService.capAssistantContent(
              responseBuffer.toString());
          final aiMessage =
              ChatMessage.create(role: 'assistant', content: fullResponse);
          _updateHostState(effectiveHostId, (s) {
            return s.copyWith(
              messages: [...s.messages, aiMessage],
              isLoading: false,
              currentAssistantMessage: null,
            );
          });
          _persistAssistant(effectiveHostId, fullResponse, conversationId,
              request: request);
          if (isFirstUserMessage && conversationId != null) {
            _titleService
                .generateAndApplyTexts(
              conversationId,
              model,
              userText: content,
              assistantText: fullResponse,
            )
                .catchError((Object e) {
              agentLogger.warn('ChatNotifier', 'AI 生成会话标题失败: $e');
              return false;
            });
          }
        },
      );
    } catch (e) {
      if (!identical(_activeRequest, request)) return;
      _updateHostState(
          effectiveHostId,
          (s) => s.copyWith(
                isLoading: false,
                currentAssistantMessage: null,
                error: e.toString(),
              ));
    }
  }

  /// 追加用户消息；钉住的会话已被删除时清除旧 id 并回落到 host 的活跃会话。
  /// 不回落的话，state.conversationId 会永久指向一个不存在的会话，
  /// 之后每次发送都报 "conversation not found"。
  Future<({Conversation conversation, bool fellBack})> _appendUserMessage(
    String hostId,
    String content, {
    String? persistedConversationId,
    Object? request,
  }) async {
    try {
      final conv = await _convService.appendMessage(
        hostId,
        role: 'user',
        content: content,
        conversationId: persistedConversationId,
      );
      return (conversation: conv, fellBack: false);
    } on StateError catch (e) {
      final message = e.toString();
      final missing = message.contains('conversation not found') ||
          message.contains('conversation deleted');
      if (persistedConversationId == null || !missing) rethrow;
      agentLogger.warn('ChatNotifier',
          '钉住的会话已不存在，回落到活跃会话 (hostId=$hostId, convId=$persistedConversationId)');
      final conv = await _convService.appendMessage(hostId,
          role: 'user', content: content);
      // 当前请求会由调用方重建状态；只有请求已失效时才需要这里清掉
      // 指向已删除会话的陈旧 id（且不能清掉更新的请求刚设置的 id）。
      if (request == null || !identical(_activeRequest, request)) {
        _updateHostState(
            hostId,
            (s) => s.conversationId == persistedConversationId
                ? s.copyWith(clearConversationId: true)
                : s);
      }
      return (conversation: conv, fellBack: true);
    }
  }

  /// 异步持久化 assistant 响应
  Future<void> _persistAssistant(
    String hostId,
    String content,
    String? conversationId, {
    Object? request,
  }) async {
    final boundedContent = ConversationService.capAssistantContent(content);
    try {
      await _convService.appendMessage(
        hostId,
        role: 'assistant',
        content: boundedContent,
        conversationId: conversationId,
      );
    } catch (e) {
      agentLogger.error(
          'ChatNotifier', '持久化 assistant 响应失败 (hostId=$hostId): $e');
      if (mounted && (request == null || identical(_activeRequest, request))) {
        _updateHostState(
            hostId, (s) => s.copyWith(error: L10n.str.ut_61476f7ee8(e)));
      }
    }
  }

  /// 构建上下文 - 只传上一条命令执行结果
  String? _buildContext(String? hostId) {
    var parts = <String>[];
    final hostState = hostId == null ? state : _stateForHost(hostId);

    if (hostId != null && hostId != 'local') {
      final hostContext = _getHostContext(hostId);
      if (hostContext != null) {
        parts.add('【当前环境】\n$hostContext');
      }
    }

    if (hostState.lastCommandOutput.isNotEmpty) {
      final truncatedOutput = _tailTruncate(hostState.lastCommandOutput, 500);
      parts.add('【上一条命令执行结果】\n$truncatedOutput');
    }

    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// lastCommandOutput 只用于拼上下文（取尾部 500 字符），保留过长输出没有意义
  static const int _maxLastOutputChars = 4096;

  /// 更新上一条命令输出（调用方按批节流，避免每个终端 chunk 都清洗+通知）
  void updateLastOutput(String output, {required String hostId}) {
    var stripped = AnsiStripper.strip(output);
    stripped = ConversationService.tailCap(stripped, _maxLastOutputChars);
    if (stripped == _stateForHost(hostId).lastCommandOutput) return;
    _updateHostState(hostId, (s) => s.copyWith(lastCommandOutput: stripped));
  }

  /// 清空当前 host 的会话（同时清除持久化）
  Future<void> clearSession() async {
    final hostId = state.currentHostId ?? _activeHostId ?? 'local';
    final convId = state.conversationId;
    _invalidateRequest();
    _activeCancelToken = null;
    final request = Object();
    _activeRequest = request;
    _hostMutationEpochs[hostId] = _hostEpoch(hostId) + 1;
    if (convId != null) {
      _conversationMutationEpochs[convId] = _conversationEpoch(convId) + 1;
    }
    _updateHostState(hostId, (_) => ChatState(currentHostId: hostId));
    if (convId != null) {
      try {
        await _convService.clearMessages(convId);
      } catch (e) {
        agentLogger.error('ChatNotifier', '清空会话失败 (convId=$convId): $e');
        if (mounted && identical(_activeRequest, request)) {
          _updateHostState(hostId, (s) => s.copyWith(error: '清空会话失败: $e'));
        }
      }
    }
  }

  /// 取消加载
  void cancelLoading() {
    _invalidateRequest();
    _activeCancelToken = null;
    state = state.copyWith(
      isLoading: false,
      currentAssistantMessage: null,
    );
  }

  /// 获取当前选择的模型（无选择时取第一个可用模型），并注入 API Key。
  Future<AIModelConfig?> _getDefaultModel() async {
    try {
      return await AIModelSelectionService.resolveCurrent();
    } catch (e) {
      agentLogger.error('ChatNotifier', '解析当前模型失败: $e');
      return null;
    }
  }

  String? _getHostContext(String hostId) {
    final host = HostsDao.getCachedById(hostId);
    if (host == null) return null;
    return '${host.host} (${host.username})';
  }

  @override
  void dispose() {
    _invalidateRequest();
    super.dispose();
  }
}
