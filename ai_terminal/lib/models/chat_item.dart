import 'package:flutter/foundation.dart';
import 'agent_event.dart';
import 'conversation.dart';
import '../utils/react_stream_parser.dart';

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
        } catch (e) { debugPrint('[AgentNotifier] 事件解析失败: $e'); }
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
