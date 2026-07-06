import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_session.dart';
import '../models/ai_model_config.dart';
import '../services/ai_service.dart';
import '../services/conversation_service.dart';
import '../core/hive_init.dart';
import '../core/credentials_store.dart';
import '../utils/ansi_stripper.dart';

/// 流式更新节流间隔（毫秒）
const int _streamThrottleMs = 80;

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
      currentHostId: clearCurrentHostId ? null : (currentHostId ?? this.currentHostId),
      currentAssistantMessage: currentAssistantMessage,
      lastCommandOutput: lastCommandOutput ?? this.lastCommandOutput,
      conversationId: clearConversationId ? null : (conversationId ?? this.conversationId),
      summary: clearSummary ? null : (summary ?? this.summary),
    );
  }
}

/// 尾截断：保留输出尾部（长输出有价值的信息通常在末尾）
String _tailTruncate(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  return '...(已截断前 ${text.length - maxChars} 字符)\n${text.substring(text.length - maxChars)}';
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

  /// 流式输出节流：累积文本但限制 UI 更新频率
  String _streamingBuffer = '';
  Timer? _throttleTimer;

  final ConversationService _convService = ConversationService();

  ChatNotifier() : super(ChatState());

  /// 切换到指定 host（保存当前状态，加载目标 host 状态）
  void switchTab(String tabId, {String? hostId}) {
    final effectiveHostId = hostId ?? 'local';

    if (_activeHostId != null) {
      _hostStates[_activeHostId!] = state;
    }

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
    // 持久化的 ConvMessage 转为 ChatMessage（旧模型）
    final messages = conv.messages
        .where((m) => m.role != 'system')
        .map((m) => ChatMessage.create(role: m.role, content: m.content))
        .toList();
    state = ChatState(
      currentHostId: hostId,
      conversationId: conv.id,
      messages: messages,
      summary: conv.summary,
    );
  }

  /// 关闭 tab 时清除其聊天记录
  void removeTab(String tabId, {String? hostId}) {
    if (hostId != null) {
      _hostStates.remove(hostId);
    }
    if (_activeHostId == hostId) {
      _activeHostId = null;
      state = ChatState();
    }
  }

  /// 发送消息
  Future<void> sendMessage(String content, {String? hostId, AIModelConfig? config}) async {
    if (content.trim().isEmpty) return;

    final effectiveHostId = hostId ?? _activeHostId ?? 'local';

    final model = config ?? await _getDefaultModel();
    if (model == null) {
      state = state.copyWith(error: '请先配置 AI 模型');
      return;
    }

    final userMessage = ChatMessage.create(
      role: 'user',
      content: content,
    );
    final updatedMessages = [...state.messages, userMessage];

    state = state.copyWith(
      messages: updatedMessages,
      isLoading: true,
      error: null,
      currentAssistantMessage: '',
      currentHostId: effectiveHostId,
    );

    // 持久化用户消息
    try {
      final conv = await _convService.appendMessage(effectiveHostId, role: 'user', content: content);
      if (state.conversationId != conv.id) {
        state = state.copyWith(conversationId: conv.id);
      }
    } catch (_) {}

    final context = _buildContext(effectiveHostId);

    final history = updatedMessages.length > 10
        ? updatedMessages.sublist(updatedMessages.length - 10)
        : updatedMessages;

    final host = effectiveHostId != 'local' ? HiveInit.hostsBox.get(effectiveHostId) : null;

    try {
      final stream = await AIService.sendMessage(
        config: model,
        history: history.take(history.length - 1).toList(),
        prompt: content,
        context: context,
        hostName: host?.name,
        hostAddress: host != null ? '${host.username}@${host.host}:${host.port}' : null,
      );

      String fullResponse = '';

      _streamSubscription = stream.listen(
        (chunk) {
          fullResponse += chunk;
          _streamingBuffer = fullResponse;
          _throttleTimer ??= Timer(
            const Duration(milliseconds: _streamThrottleMs),
            () {
              _throttleTimer = null;
              if (_streamingBuffer.isNotEmpty) {
                state = state.copyWith(currentAssistantMessage: _streamingBuffer);
              }
            },
          );
        },
        onError: (error) {
          _throttleTimer?.cancel();
          _throttleTimer = null;
          _streamingBuffer = '';
          state = state.copyWith(
            isLoading: false,
            error: error.toString(),
          );
        },
        onDone: () {
          _throttleTimer?.cancel();
          _throttleTimer = null;
          _streamingBuffer = '';
          final aiMessage = ChatMessage.create(
            role: 'assistant',
            content: fullResponse,
          );
          state = state.copyWith(
            messages: [...state.messages, aiMessage],
            isLoading: false,
            currentAssistantMessage: null,
          );
          // 持久化 assistant 响应
          _persistAssistant(effectiveHostId, fullResponse);
        },
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// 异步持久化 assistant 响应，忽略错误
  void _persistAssistant(String hostId, String content) {
    _convService.appendMessage(hostId, role: 'assistant', content: content).then((_) {}).catchError((_) {});
  }

  /// 构建上下文 - 只传上一条命令执行结果
  String? _buildContext(String? hostId) {
    var parts = <String>[];

    if (hostId != null && hostId != 'local') {
      final hostContext = _getHostContext(hostId);
      if (hostContext != null) {
        parts.add('【当前环境】\n$hostContext');
      }
    }

    if (state.lastCommandOutput.isNotEmpty) {
      final truncatedOutput = _tailTruncate(state.lastCommandOutput, 500);
      parts.add('【上一条命令执行结果】\n$truncatedOutput');
    }

    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// 更新上一条命令输出（执行完命令后调用）
  void updateLastOutput(String output) {
    state = state.copyWith(lastCommandOutput: AnsiStripper.strip(output));
  }

  /// 清空当前 host 的会话（同时清除持久化）
  Future<void> clearSession() async {
    final convId = state.conversationId;
    state = ChatState(
      currentHostId: state.currentHostId,
    );
    if (convId != null) {
      try {
        await _convService.clearMessages(convId);
      } catch (_) {}
    }
  }

  /// 取消加载
  void cancelLoading() {
    _streamSubscription?.cancel();
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _streamingBuffer = '';
    state = state.copyWith(
      isLoading: false,
      currentAssistantMessage: null,
    );
  }

  /// 获取默认模型，并从 CredentialsStore 注入 apiKey
  /// （Hive 中 apiKey 为空占位，真实 key 存于安全存储）
  Future<AIModelConfig?> _getDefaultModel() async {
    AIModelConfig? model;
    try {
      model = HiveInit.aiModelsBox.values.firstWhere((m) => m.isDefault);
    } catch (_) {
      try {
        model = HiveInit.aiModelsBox.values.isNotEmpty
            ? HiveInit.aiModelsBox.values.first
            : null;
      } catch (_) {
        model = null;
      }
    }
    if (model != null && model.apiKey.isEmpty) {
      final storedKey = await CredentialsStore.get(hostId: model.id, type: 'apiKey');
      if (storedKey != null) {
        model.apiKey = storedKey;
      }
    }
    return model;
  }

  String? _getHostContext(String hostId) {
    final host = HiveInit.hostsBox.get(hostId);
    if (host == null) return null;
    return '${host.host} (${host.username})';
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _throttleTimer?.cancel();
    super.dispose();
  }
}
