/// 空闲断线自动重连的退避策略（docs/terminal-capability-gap-design.md §5）。
/// 任务运行中同样会重连：重连只换 executor，不碰任务状态。
class ReconnectPolicy {
  /// 最多自动尝试次数，超过后留给用户手动重连。
  ///
  /// 6 次 ≈ 1+2+4+8+16+32 = 63s，覆盖"NAT 映射回收 + 对端重启"这类需要
  /// 一分钟才恢复的链路；3 次（7s）在这类场景里必然提前放弃。
  static const int maxAttempts = 6;

  /// 第 attempt 次尝试前的等待（从 0 计）：1s → 2s → 4s → 8s → 16s → 32s
  static Duration delayForAttempt(int attempt) {
    if (attempt < 0) attempt = 0;
    return Duration(seconds: 1 << attempt);
  }

  static bool shouldRetry(int attemptsSoFar) => attemptsSoFar < maxAttempts;
}
