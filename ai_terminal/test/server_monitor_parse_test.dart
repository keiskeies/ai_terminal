import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/server_monitor_service.dart';

/// 模拟采集脚本的分段输出：@@NAME@@ 单独一行，后跟命令输出
String _raw(List<(String, String)> sections) {
  final buffer = StringBuffer();
  for (final (name, body) in sections) {
    buffer.writeln('@@$name@@');
    if (body.isNotEmpty) buffer.writeln(body);
  }
  buffer.writeln('@@END@@');
  return buffer.toString();
}

const _cpu = 'Cpu(s):  8.0 us,  3.0 sy,  0.0 ni, 88.0 id,  0.0 wa,  1.0 hi,  0.0 si,  0.0 st';

const _meminfo = '''
MemTotal:       16293652 kB
MemFree:         9456120 kB
MemAvailable:   13516800 kB
Buffers:          123456 kB
Cached:          4027000 kB
SReclaimable:     123000 kB
Shmem:             28000 kB
SwapTotal:       2097148 kB
SwapFree:        2097148 kB
''';

void main() {
  final service = ServerMonitorService(executor: null, isLocal: false);

  group('Linux 内存解析', () {
    test('/proc/meminfo 优先生效，中文 locale 的 free 输出不影响结果', () {
      final snap = service.parseLinuxOutput(_raw([
        ('CPU', _cpu),
        // 中文服务器上 free -m 的真实标签（procps-ng zh_CN 翻译）
        ('MEM', '               总计        已用        空闲      共享    缓冲/缓存    可用\n'
            '内存：        15911        2419        9234          27        4257       13202\n'
            '交换：         2047           0        2047'),
        ('MEMINFO', _meminfo),
      ]));

      expect(snap.error, isNull);
      expect(snap.memTotalMB, closeTo(15911.77, 0.01));
      expect(snap.memAvailableMB, closeTo(13200.0, 0.01));
      expect(snap.memUsedMB, closeTo(15911.77 - 13200.0, 0.01));
      expect(snap.memPercent, closeTo((15911.77 - 13200.0) / 15911.77 * 100, 0.01));
      expect(snap.memFreeMB, closeTo(9234.49, 0.01));
      expect(snap.memBuffersMB, closeTo(120.56, 0.01));
      expect(snap.memCachedMB, closeTo((4027000 + 123000 - 28000) / 1024, 0.01));
      expect(snap.swapTotalMB, closeTo(2048.0, 0.01));
      expect(snap.swapUsedMB, 0);
    });

    test('没有 /proc/meminfo 时回退到 free -m（LC_ALL=C 英文输出）', () {
      final snap = service.parseLinuxOutput(_raw([
        ('CPU', _cpu),
        ('MEM', '               total        used        free      shared  buff/cache   available\n'
            'Mem:           15911        2419        9234          27        4257       13202\n'
            'Swap:           2047         100        1947'),
      ]));

      expect(snap.memTotalMB, 15911);
      expect(snap.memUsedMB, 2419);
      expect(snap.memAvailableMB, 13202);
      expect(snap.memBuffersMB, 4257);
      expect(snap.swapTotalMB, 2047);
      expect(snap.swapUsedMB, 100);
      expect(snap.memPercent, closeTo(2419 / 15911 * 100, 0.01));
    });

    test('MEM/MEMINFO 都缺失时 memTotalMB 为 0，供 UI 显示为不可用', () {
      final snap = service.parseLinuxOutput(_raw([
        ('CPU', _cpu),
      ]));

      expect(snap.memTotalMB, 0);
      expect(snap.memPercent, 0);
    });
  });
}
