import 'dart:convert';

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

  group('Windows 本地采集', () {
    // 真机（Win11 22000）上 -EncodedCommand 采集到的实际输出，仅截掉多余网卡
    const windowsRaw = '''
@@CPU@@
LoadPercentage=34
@@MEM@@
FreePhysicalMemory=80304424
TotalVisibleMemorySize=98178380
FreeVirtualMemory=177660308
TotalVirtualMemorySize=198841676
@@DISK@@
DeviceID=C:
DriveType=3
FileSystem=NTFS
FreeSpace=960695062528
Size=1997684166656

DeviceID=I:
DriveType=2
FileSystem=exFAT
FreeSpace=62910627840
Size=62911414272

@@NET@@
Name=Realtek PCIe 2.5GbE Family Controller
BytesReceivedPersec=137711252228
BytesSentPersec=4581280000
PacketsReceivedErrors=2
PacketsOutboundErrors=1

Name=MediaTek Wi-Fi 7 MT7925 Wireless LAN Card
BytesReceivedPersec=0
BytesSentPersec=0
PacketsReceivedErrors=0
PacketsOutboundErrors=0

@@USER@@
8
@@UPTIME@@
LastBootUpTime=20261105235812
@@LOAD@@
N/A
@@PROC@@
348
@@KERNEL@@
Microsoft Windows 11 专业版 10.0.22000
@@HOSTNAME@@
CJMD
@@END@@
''';

    test('CIM 输出解析出全部指标，不再只剩 0 和短横线', () {
      // 空输出分支会读 L10n（需 setup），这里只锁真实采集结果的解析
      final snap = service.parseWindowsOutput(windowsRaw);
      expect(snap.error, isNull);
      expect(snap.cpuPercent, 34);
      expect(snap.memTotalMB, closeTo(98178380 / 1024, 0.001));
      expect(snap.memPercent, greaterThan(15));
      expect(snap.diskTotalGB, closeTo(1997684166656 / (1024 * 1024 * 1024), 0.01));
      expect(snap.diskPercent, greaterThan(40));
      expect(snap.diskPartitions.length, 2);
      expect(snap.diskPartitions.first.mountPoint, 'C:');
      expect(snap.interfaces.length, 2);
      expect(snap.netTotalDownBytes, 137711252228);
      expect(snap.netTotalUpBytes, 4581280000);
      expect(snap.userCount, 8);
      expect(snap.processCount, 348);
      expect(snap.uptime, isNot('-'));
      expect(snap.kernelVersion, contains('Windows 11'));
      expect(snap.hostname, 'CJMD');
    });

    test('-EncodedCommand 的 Base64 是 UTF-16LE 且不含引号', () {
      const script = r"Write-Output '@@CPU@@'; $x = 'a b'";
      final encoded = ServerMonitorService.encodePowershellCommand(script);

      // 不含引号：整条命令经 cmd /c 传递也不会被二次解析
      expect(encoded.contains('"'), isFalse);
      expect(encoded.contains("'"), isFalse);

      final bytes = base64Decode(encoded);
      expect(bytes.length, script.length * 2);
      final decoded = String.fromCharCodes([
        for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
      ]);
      expect(decoded, script);
    });
  });
}
