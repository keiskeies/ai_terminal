import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_session.dart';
import '../models/ai_model_config.dart';
import '../services/ai_service.dart';
import '../core/hive_init.dart';
import '../utils/ansi_stripper.dart';

const _uuid = Uuid();

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

  ChatState({
    this.messages = const [],
    this.isLoading = false,
    this.error,
    this.currentHostId,
    this.currentAssistantMessage,
    this.lastCommandOutput = '',
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isLoading,
    String? error,
    String? currentHostId,
    String? currentAssistantMessage,
    String? lastCommandOutput,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      currentHostId: currentHostId ?? this.currentHostId,
      currentAssistantMessage: currentAssistantMessage,
      lastCommandOutput: lastCommandOutput ?? this.lastCommandOutput,
    );
  }
}

/// 尾截断：保留输出尾部（长输出有价值的信息通常在末尾）
String _tailTruncate(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  return '...(已截断前 ${text.length - maxChars} 字符)\n${text.substring(text.length - maxChars)}';
}

/// 聊天 Provider — 每个 tab 独立聊天状态
final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier();
});

class ChatNotifier extends StateNotifier<ChatState> {
  StreamSubscription<String>? _streamSubscription;

  /// 每个 tab 的聊天状态缓存
  final Map<String, ChatState> _tabStates = {};

  /// 当前活跃的 tabId
  String? _activeTabId;

  /// 流式输出节流：累积文本但限制 UI 更新频率
  String _streamingBuffer = '';
  Timer? _throttleTimer;

  ChatNotifier() : super(ChatState());

  /// 切换到指定 tab（保存当前状态，加载目标 tab 状态）
  void switchTab(String tabId, {String? hostId}) {
    // 保存当前 tab 状态
    if (_activeTabId != null) {
      _tabStates[_activeTabId!] = state;
    }

    _activeTabId = tabId;

    // 加载目标 tab 状态（若无则创建新的）
    if (_tabStates.containsKey(tabId)) {
      state = _tabStates[tabId]!;
    } else {
      // 新 tab：全新空聊天状态
      state = ChatState(currentHostId: hostId);
    }
  }

  /// 关闭 tab 时清除其聊天记录
  void removeTab(String tabId) {
    _tabStates.remove(tabId);
    // 如果关闭的是当前活跃 tab，重置状态
    if (_activeTabId == tabId) {
      _activeTabId = null;
      state = ChatState();
    }
  }

  /// 发送消息
  Future<void> sendMessage(String content, {String? hostId, AIModelConfig? config}) async {
    if (content.trim().isEmpty) return;

    // 获取默认模型
    final model = config ?? _getDefaultModel();
    if (model == null) {
      state = state.copyWith(error: '请先配置 AI 模型');
      return;
    }

    // 添加用户消息
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
      currentHostId: hostId,
    );

    // 构建上下文
    final context = _buildContext(hostId);

    // 获取历史消息（最近 10 条）
    final history = updatedMessages.length > 10
        ? updatedMessages.sublist(updatedMessages.length - 10)
        : updatedMessages;

    // 获取主机信息用于系统提示词
    final host = hostId != null ? HiveInit.hostsBox.get(hostId) : null;

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
          // 节流：限制 UI 更新频率，减少 rebuild 次数
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
          // 添加 AI 消息
          final aiMessage = ChatMessage.create(
            role: 'assistant',
            content: fullResponse,
          );
          state = state.copyWith(
            messages: [...state.messages, aiMessage],
            isLoading: false,
            currentAssistantMessage: null,
          );
        },
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// 构建上下文 - 只传上一条命令执行结果
  String? _buildContext(String? hostId) {
    var parts = <String>[];

    // 添加主机上下文
    if (hostId != null) {
      final hostContext = _getHostContext(hostId);
      if (hostContext != null) {
        parts.add('【当前环境】\n$hostContext');
      }
    }

    // 只添加上一条命令执行结果（取尾部，避免浪费 token）
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

  /// 清空当前 tab 的会话
  void clearSession() {
    state = ChatState(
      currentHostId: state.currentHostId,
    );
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

  AIModelConfig? _getDefaultModel() {
    try {
      return HiveInit.aiModelsBox.values.firstWhere((m) => m.isDefault);
    } catch (_) {
      try {
        return HiveInit.aiModelsBox.values.isNotEmpty
            ? HiveInit.aiModelsBox.values.first
            : null;
      } catch (_) {
        return null;
      }
    }
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
