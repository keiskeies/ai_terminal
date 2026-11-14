/// 空闲断线自动重连的退避策略（docs/terminal-capability-gap-design.md §5）。
/// 任务运行中不允许自动重连——该判定在调用侧（isRunningFor），这里只管节奏。
class ReconnectPolicy {
  /// 最多自动尝试次数，超过后留给用户手动重连
  static const int maxAttempts = 3;

  /// 第 attempt 次尝试前的等待（从 0 计）：1s → 2s → 4s
  static Duration delayForAttempt(int attempt) {
    if (attempt < 0) attempt = 0;
    return Duration(seconds: 1 << attempt);
  }

  static bool shouldRetry(int attemptsSoFar) => attemptsSoFar < maxAttempts;
}