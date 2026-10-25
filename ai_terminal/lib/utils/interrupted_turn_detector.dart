import '../models/agent_event.dart';

/// 判断一轮历史事件是否是"新格式但未完成"的中断回合
///
/// 旧版本会话没有 report/finish，也没有新格式元数据，不能误标记为中断。
/// 新格式回合至少会带 hostId/toolName/duration/plan 等字段。
bool isInterruptedTurn(List<AgentEvent> events) {
  if (events.isEmpty) return false;
  if (events.any((e) => e.isFinish || e.isReport)) return false;

  final hasNewMetadata = events.any((e) =>
      e.hostId != null ||
      e.toolName != null ||
      e.planSteps != null ||
      e.durationMs != null ||
      e.outputTotalChars != null ||
      e.outputTruncated != null ||
      e.outputTail != null ||
      e.hostResults != null ||
      e.failureKind != null);
  if (!hasNewMetadata) return false;

  return events.any((e) => e.isCommand || e.isPlan || e.isResult);
}

/// 取该回合最后一次已知主机，用于继续任务时的主机校验
String? lastEventHostId(List<AgentEvent> events) {
  for (var i = events.length - 1; i >= 0; i--) {
    final host = events[i].hostId;
    if (host != null && host.trim().isNotEmpty) return host.trim();
  }
  return null;
}
