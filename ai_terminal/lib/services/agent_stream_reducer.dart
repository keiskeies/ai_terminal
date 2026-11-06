import 'dart:async';

/// Agent 流式内容 reducer：管理每个 host 的流式内容累积和节流
class AgentStreamReducer {
  /// 单轮流式内容上限：只保留尾部，防止异常长响应无限占内存
  static const int _maxChars = 200000;

  final Map<String, StringBuffer> _streamingContent = {};
  final Map<String, Timer> _throttleTimers = {};

  /// 获取指定 host 的当前流式内容
  String? getContent(String hostId) => _streamingContent[hostId]?.toString();

  /// 设置/追加流式内容（StringBuffer 追加为摊还 O(1)，避免逐 chunk 复制整串）
  void append(String hostId, String chunk) {
    final buffer = _streamingContent.putIfAbsent(hostId, StringBuffer.new)
      ..write(chunk);
    if (buffer.length > _maxChars) {
      final tail = buffer.toString();
      buffer
        ..clear()
        ..write(tail.substring(tail.length - _maxChars));
    }
  }

  /// 重置指定 host 的流式内容
  void reset(String hostId) {
    final buffer = _streamingContent[hostId];
    buffer?.clear();
  }

  /// 启动节流 Timer，到期后调用 onFlush 回调
  void scheduleFlush(String hostId, Duration delay, void Function(String content) onFlush) {
    _throttleTimers[hostId] ??= Timer(delay, () {
      _throttleTimers.remove(hostId);
      final content = getContent(hostId);
      if (content != null && content.isNotEmpty) {
        onFlush(content);
      }
    });
  }

  /// 清除指定 host 的节流 Timer
  void cancelTimer(String hostId) {
    _throttleTimers[hostId]?.cancel();
    _throttleTimers.remove(hostId);
  }

  /// 释放所有资源
  void dispose() {
    for (final timer in _throttleTimers.values) {
      timer.cancel();
    }
    _throttleTimers.clear();
    _streamingContent.clear();
  }
}
