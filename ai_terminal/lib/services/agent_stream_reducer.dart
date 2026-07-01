import 'dart:async';

/// Agent 流式内容 reducer：管理每个 host 的流式内容累积和节流
class AgentStreamReducer {
  final Map<String, String> _streamingContent = {};
  final Map<String, Timer> _throttleTimers = {};

  /// 获取指定 host 的当前流式内容
  String? getContent(String hostId) => _streamingContent[hostId];

  /// 设置/追加流式内容
  void append(String hostId, String chunk) {
    _streamingContent[hostId] = (_streamingContent[hostId] ?? '') + chunk;
  }

  /// 重置指定 host 的流式内容
  void reset(String hostId) {
    _streamingContent[hostId] = '';
  }

  /// 启动节流 Timer，到期后调用 onFlush 回调
  void scheduleFlush(String hostId, Duration delay, void Function(String content) onFlush) {
    _throttleTimers[hostId] ??= Timer(delay, () {
      _throttleTimers.remove(hostId);
      final content = _streamingContent[hostId];
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
