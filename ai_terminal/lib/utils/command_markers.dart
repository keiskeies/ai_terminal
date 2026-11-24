import 'dart:math';

/// 命令退出码 marker 生成器。
///
/// 格式为 `EXITCODE_{seq}_{nonce}:`。nonce 是每次生成时随机取的 6 位 hex，
/// 目的是让 marker 不可预测：命令输出里若恰好出现 `EXITCODE_1:0` 这类文本
/// （AI cat/grep 到含旧格式 marker 的日志），固定 marker 会被误判为命令完成、
/// 提前截断真实输出。随机 nonce 让这种碰撞概率可忽略。
///
/// seq 仍保留，便于日志里按执行顺序追踪；`ExitMarkerScanner` 用
/// `RegExp.escape(marker)` 动态构造正则，marker 格式变化对它透明。
class CommandMarkers {
  CommandMarkers._();

  static final Random _random = Random.secure();

  /// 测试缝隙：设为非 null 时用固定 nonce（通常 '' 回复旧的确定性格式），
  /// 让模拟输出型测试能硬编码 marker 文本。生产环境恒为 null。
  static String? nonceForTesting;

  static String next(int seq) {
    if (nonceForTesting case final fixed?) {
      return fixed.isEmpty ? 'EXITCODE_$seq:' : 'EXITCODE_${seq}_$fixed:';
    }
    final nonce = _random.nextInt(0x1000000).toRadixString(16).padLeft(6, '0');
    return 'EXITCODE_${seq}_$nonce:';
  }
}
