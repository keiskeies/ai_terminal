import 'dart:math' as math;

/// 根据采样文件大小选择目录上传的初始并发。
///
/// 小文件是“每文件多次往返”延迟受限，并发越高重叠越多；大文件受
/// SSH/SFTP 通道窗口（2MB）限制，多开只会排队并增加句柄/内存，因此
/// 大文件主动降到 2–4。
int chooseInitialUploadConcurrency({
  required int fileCount,
  required double averageBytes,
}) {
  if (fileCount <= 1) return 1;
  if (averageBytes < 256 * 1024) return 16;
  if (averageBytes < 2 * 1024 * 1024) return 8;
  if (averageBytes < 8 * 1024 * 1024) return 4;
  return 2;
}

/// 自适应并发控制器：初始值由 [chooseInitialUploadConcurrency] 决定，
/// 连续失败时减半，持续成功后逐步恢复到初始值。
///
/// 使用 AIMD（加性增、乘性减）而不是直接线性调整：失败时快速退让，
/// 恢复时缓慢试探，避免在弱网/弱服务端上反复抖动。
class AdaptiveConcurrency {
  final int initial;
  final bool adaptive;
  int _current;
  int _successStreak = 0;
  int _failureStreak = 0;
  bool _degraded = false;

  AdaptiveConcurrency({required int initial, this.adaptive = true})
      : initial = math.max(1, initial),
        _current = math.max(1, initial);

  int get current => _current;
  int get finalConcurrency => _current;
  bool get degraded => _degraded;

  void onSuccess() {
    if (!adaptive) return;
    _failureStreak = 0;
    _successStreak++;
    if (_successStreak >= 20 && _current < initial) {
      _current++;
      _successStreak = 0;
    }
  }

  void onFailure() {
    if (!adaptive) return;
    _successStreak = 0;
    _failureStreak++;
    if (_failureStreak >= 3 && _current > 1) {
      _current = math.max(1, _current ~/ 2);
      _failureStreak = 0;
      _degraded = true;
    }
  }
}
