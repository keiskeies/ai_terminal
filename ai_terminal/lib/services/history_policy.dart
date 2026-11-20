import '../models/chat_session.dart';
import '../utils/token_estimator.dart';
import 'agent_logger.dart';

/// 对话历史裁剪策略（R4：纯函数，不持有引擎实例状态）。
///
/// 三层策略依次执行：
/// 1. 单条消息截断：超长内容保留尾部，并保证代码块闭合
/// 2. 轮数兜底：保留最近 [maxConversationRounds] 轮，防止 token 估算偏低
/// 3. token-aware：非系统消息 token 超出有效上下文窗口的 70% 时，
///    从最早的消息开始丢弃，直到降至预算内
///
/// 有效上下文窗口由调用方通过 [contextWindow] 显式传入。
class HistoryPolicy {
  /// 对话历史最大轮数（每轮 = assistant + user）
  static const int maxConversationRounds = 40;

  /// 单条消息最大字符数，超出截断
  static const int maxMessageChars = 4000;

  /// 观测消息专用上限：失败观测头 2000+尾 6000 必须完整进模型，
  /// 通用 4000 上限会把分级截断保留的报错头部再次砍掉（O2）
  static const int maxObservationMessageChars = 12000;

  /// 原地裁剪 [messages]：先截断长消息，再轮数兜底，最后 token-aware 裁剪。
  /// 阈值 0.7 留出 30% 给 system prompt + 当前 user prompt + completion。
  static void trimMessages(
    List<ChatMessage> messages, {
    required int contextWindow,
  }) {
    // 保留 system 消息
    final systemMsgs = messages.where((m) => m.role == 'system').toList();
    final nonSystemMsgs = messages.where((m) => m.role != 'system').toList();

    // 第 1 层：单条消息截断（先截断再做 token 估算，避免单条消息撑爆预算）
    final truncated = <ChatMessage>[];
    for (final msg in nonSystemMsgs) {
      final cap = msg.content.startsWith('观测:')
          ? maxObservationMessageChars
          : maxMessageChars;
      if (msg.content.length > cap) {
        var t = msg.content.substring(msg.content.length - cap);
        // 确保代码块完整闭合：统计 ``` 数量，奇数则补一个 ```
        final openCount = '```'.allMatches(t).length;
        if (openCount % 2 != 0) {
          t = '$t\n```';
        }
        truncated.add(ChatMessage.create(
          role: msg.role,
          content: '...(已截断前 ${msg.content.length - cap} 字符)\n$t',
        ));
      } else {
        truncated.add(msg);
      }
    }

    // 第 2 层：轮数兜底裁剪
    const maxNonSystem = maxConversationRounds * 2;
    var kept = truncated.length > maxNonSystem
        ? truncated.skip(truncated.length - maxNonSystem).toList()
        : truncated;
    if (kept.length != truncated.length) {
      agentLogger.info(
          'TrimMsgs', '轮数裁剪: ${truncated.length} → ${kept.length} 条');
    }

    // 第 3 层：token-aware 裁剪（保留最近消息，丢弃最早的）
    final tokenBudget = (contextWindow * 0.7).round();
    var totalTokens = TokenEstimator.estimateHistory(kept);
    if (totalTokens > tokenBudget) {
      final originalCount = kept.length;
      // 从最早开始丢弃，直到总 token 数降至预算以下或仅剩 2 条。
      // 先算删除下标再 sublist，避免循环 removeAt(0) 的 O(n²) 移动。
      var drop = 0;
      while (drop < kept.length - 2 && totalTokens > tokenBudget) {
        totalTokens -= TokenEstimator.estimateMessage(kept[drop]);
        drop++;
      }
      if (drop > 0) kept = kept.sublist(drop);
      agentLogger.info(
        'TrimMsgs',
        'token-aware 裁剪: $originalCount → ${kept.length} 条, '
            'tokens=$totalTokens/$tokenBudget (ctx=$contextWindow)',
      );
    }

    messages
      ..clear()
      ..addAll(systemMsgs)
      ..addAll(kept);
  }
}
