import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/services/server_monitor_service.dart';
import 'package:ai_terminal/utils/android_userland.dart';
import 'package:ai_terminal/widgets/server_monitor_panel.dart';

/// 手机端本地监控采集的回归。
///
/// 起点是「本地 tab 的 CPU mini 折线图永远停在 …」。链路是：`runOnce` 写死
/// `/bin/sh`，Android 上不存在该路径 → spawn 抛异常被翻译成空字符串 →
/// `parseLinuxOutput('')` 得到 error 快照 → error 不进 history → 折线图永远
/// 只有 0/1 个点。而状态点只数抛出的异常，于是界面一路显示「一切正常」。
/// 这一组把当时只能在桌面上判对错的决定都钉住。
void main() {
  group('runOnce 用的 shell', () {
    test('Android 用 /system/bin/sh，不是 /bin/sh', () {
      expect(posixShForRunOnce(isAndroid: true), '/system/bin/sh');
    });

    test('桌面分支只在 /bin/sh 与 sh 之间选', () {
      expect(posixShForRunOnce(isAndroid: false), anyOf('/bin/sh', 'sh'));
    });

    test('系统命令目录补进 PATH 时保留原有条目、顺序与去重', () {
      final parts =
          androidSystemBinPath('/data/user/0/x/app.bin:/system/bin').split(':');
      expect(parts.first, '/data/user/0/x/app.bin');
      expect(parts.toSet().length, parts.length);
      expect(parts, containsAll(['/system/bin', '/system/xbin', '/vendor/bin']));
    });
  });

  group('/proc/self/stat 解析', () {
    // 字段顺序照 stat(2)：pid (comm) state ppid …，第 14/15 是 utime/stime。
    // head 占字段 1..4，filler 补到第 13，随后就是传入的那两个时间字段。
    String stat(List<String> tail, {String comm = 'droid.terminal'}) {
      final head = ['1234', '($comm)', 'S', '1'];
      final filler = List.generate(9, (i) => '${100 + i}');
      return [...head, ...filler, ...tail].join(' ');
    }

    test('普通进程名', () {
      expect(ServerMonitorService.parseSelfCpuTicks(stat(['300', '100'])), 400);
    });

    test('进程名含空格与括号时仍按下标解析', () {
      // 直接 split 整行会在这里整体错位，把 filler 当成 utime 读出荒谬值
      expect(
          ServerMonitorService.parseSelfCpuTicks(
              stat(['300', '100'], comm: 'a b) (c')),
          400);
    });

    test('缺字段 / 没有右括号 / 非数字都返回 null', () {
      expect(ServerMonitorService.parseSelfCpuTicks('1234 (x) S'), isNull);
      expect(ServerMonitorService.parseSelfCpuTicks('no parens here'), isNull);
      expect(ServerMonitorService.parseSelfCpuTicks(stat(['x', '100'])), isNull);
    });
  });

  group('原生 collectStats 映射', () {
    ServerMonitorService svc() =>
        ServerMonitorService(executor: Object(), isLocal: true);

    final t0 = DateTime(2026, 11, 28, 12);
    const mb = 1024 * 1024;
    const gb = 1024 * mb;

    test('内存/磁盘按字节换算，取不到的键不造假', () {
      final s = svc().mapAndroidStats({
        'memTotalBytes': 8 * gb,
        'memAvailBytes': 3 * gb,
        'diskTotalBytes': (111.0 * gb).round(),
        'diskFreeBytes': (40.0 * gb).round(),
        'uptimeMs': 3 * 24 * 3600 * 1000 + 2 * 3600 * 1000 + 15 * 60 * 1000,
        'model': 'Mi 10 Pro',
      }, t0);
      expect(s.error, isNull);
      expect(s.memTotalMB, closeTo(8192, 0.001));
      expect(s.memUsedMB, closeTo(5120, 0.001));
      expect(s.memPercent, closeTo(62.5, 0.001));
      expect(s.diskTotalGB, closeTo(111, 0.001));
      expect(s.uptime, '3 days, 02:15');
      expect(s.hostname, 'Mi 10 Pro');
      // 没有 CPU 读数 → cpuAvailable=false，面板据此显示 - 而不是 0.0%
      expect(s.cpuAvailable, isFalse);
      expect(s.cpuIsProcessScoped, isTrue);
    });

    test('空 map 不抛异常，也不会伪造出可用容量', () {
      final s = svc().mapAndroidStats(const {}, t0);
      expect(s.error, isNull);
      expect(s.memTotalMB, 0);
      expect(s.diskTotalGB, 0);
      expect(s.diskPartitions, isEmpty);
      expect(s.uptime, '-');
      expect(s.interfaces, isEmpty);
    });

    test('TrafficStats 的 -1 当未知，不参与差分', () {
      final s = svc()
          .mapAndroidStats({'rxBytes': -1, 'txBytes': -1}, t0);
      expect(s.interfaces, isEmpty);
      expect(s.netUpKBps, 0);
      expect(s.netDownKBps, 0);
      expect(s.netTotalDownBytes, 0);
    });

    test('第一帧只有累计值没有速率，第二帧才算出 KB/s', () {
      final s = svc();
      final first = s.mapAndroidStats(
          {'rxBytes': 1024 * 1024, 'txBytes': 512 * 1024}, t0);
      expect(first.interfaces, hasLength(1));
      expect(first.netDownKBps, 0); // 没有基准点，不能凭空造一个速率
      final second = s.mapAndroidStats(
          {'rxBytes': 1024 * 1024 + 512 * 1024, 'txBytes': 512 * 1024},
          t0.add(const Duration(seconds: 5)));
      expect(second.netDownKBps, closeTo(102.4, 1));
      expect(second.netUpKBps, 0);
    });

    test('进程 CPU 有读数时才标 cpuAvailable', () {
      final s = svc().mapAndroidStats(const {}, t0, selfCpuPct: 12.5);
      expect(s.cpuAvailable, isTrue);
      expect(s.cpuPercent, 12.5);
      expect(s.cpuIsProcessScoped, isTrue);
    });

    test('availMem 大于 totalMem 时占用率不溢出为负', () {
      final s = svc().mapAndroidStats(
          {'memTotalBytes': 4 * mb, 'memAvailBytes': 9 * mb}, t0);
      expect(s.memUsedMB, 0);
      expect(s.memPercent, 0);
    });
  });

  group('面板对「取不到」的表达', () {
    testWidgets('连续返回 error 快照时状态点算失败，而不是永远绿', (tester) async {
      final svc = _StubService(() => ServerSnapshot(
            timestamp: DateTime.now(),
            error: '采集输出为空',
          ));
      await _pumpPanel(tester, svc, interval: const Duration(milliseconds: 100));
      await tester.pump(); // initState 的 postFrame 采集
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(svc.calls, greaterThanOrEqualTo(3));
      final tip = tester.widget<Tooltip>(find.byType(Tooltip).first);
      expect(tip.message, contains('采集失败'));
    });

    testWidgets('没有 CPU 读数时芯片显示 -，不拿 0.0% 冒充空闲', (tester) async {
      final svc = _StubService(() => ServerSnapshot(
            timestamp: DateTime.now(),
            cpuAvailable: false,
            cpuIsProcessScoped: true,
            memTotalMB: 8192,
            memUsedMB: 5120,
            diskPercent: 60,
            uptime: '02:15',
          ));
      await _pumpPanel(tester, svc);
      await tester.pump();
      expect(find.text('0.0%'), findsNothing);
      expect(find.text('-'), findsWidgets);
    });

    testWidgets('有 CPU 读数时芯片显示百分比', (tester) async {
      final svc = _StubService(() => ServerSnapshot(
            timestamp: DateTime.now(),
            cpuAvailable: true,
            cpuIsProcessScoped: true,
            cpuPercent: 12.5,
          ));
      await _pumpPanel(tester, svc);
      await tester.pump();
      expect(find.text('12.5%'), findsOneWidget);
    });
  });
}

/// 只回固定快照的假服务：真实 executor 要起子进程，测试里换掉。
class _StubService extends ServerMonitorService {
  _StubService(this._next) : super(executor: null, isLocal: true);

  final ServerSnapshot Function() _next;
  int calls = 0;

  @override
  bool get canCollect => true;

  @override
  Future<ServerSnapshot> collect() async {
    calls++;
    return _next();
  }
}

Future<void> _pumpPanel(WidgetTester tester, ServerMonitorService svc,
    {Duration interval = const Duration(hours: 1)}) async {
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: AppTheme.darkTheme,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ServerMonitorPanel(service: svc, interval: interval),
      ),
    ),
  ));
}
