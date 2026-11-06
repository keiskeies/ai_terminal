import 'package:flutter/material.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/services/local_terminal_service.dart';
import 'package:ai_terminal/services/server_monitor_service.dart';
import 'package:ai_terminal/widgets/server_monitor_panel.dart';

/// 端到端：真实执行 Windows 本地采集命令（cmd → powershell -EncodedCommand），
/// 再走一遍解析，确认监控栏拿到的不是全零快照。
///
/// 只在 Windows 上跑；其它平台自动跳过。
class _RealLocalShell extends LocalTerminalService {
  @override
  bool get isConnected => true;

  @override
  Future<String> runOnce(String command, {Duration timeout = const Duration(seconds: 5)}) async {
    // 全量测试并行跑时 PowerShell 冷启动可能超过服务的 12s，这里统一放宽
    final r = await Process.run('cmd', ['/c', command])
        .timeout(timeout + const Duration(seconds: 45));
    return (r.stdout as String?) ?? '';
  }
}

void main() {
  test('Windows 本地采集链路返回真实数据', () async {
    final service = ServerMonitorService(executor: _RealLocalShell(), isLocal: true);
    final snap = await service.collect();

    expect(snap.error, isNull, reason: '采集失败: ${snap.error}');
    expect(snap.memTotalMB, greaterThan(1024), reason: '内存总量应为真实值而非 0');
    expect(snap.memPercent, inInclusiveRange(0, 100));
    expect(snap.diskPartitions, isNotEmpty, reason: '至少应解析出系统盘');
    expect(snap.diskTotalGB, greaterThan(1));
    expect(snap.hostname, isNotEmpty);
    expect(snap.kernelVersion, isNotEmpty);
    expect(snap.processCount, greaterThan(0));
  }, skip: !Platform.isWindows);

  testWidgets('监控栏用真实快照渲染，不再显示「-」与 0', (tester) async {
    final snap = ServerSnapshot(
      timestamp: DateTime.now(),
      cpuPercent: 34,
      memUsedMB: 17000,
      memTotalMB: 95800,
      memPercent: 18,
      diskPercent: 52,
      uptime: '1 days, 03:20',
      hostname: 'CJMD',
      processCount: 348,
      netUpKBps: 12,
      netDownKBps: 34,
    );
    final service = _FakeMonitorService(snap);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => ServerMonitorPanel(
            service: service,
            interval: const Duration(hours: 1),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(find.textContaining('CPU'), findsOneWidget);
    expect(find.textContaining('34.0%'), findsOneWidget);
    // 内存显示「已用/总量」，不再是「-」
    expect(find.textContaining('/'), findsWidgets);
    expect(find.textContaining('CJMD'), findsWidgets);
  });
}

class _FakeMonitorService extends ServerMonitorService {
  _FakeMonitorService(this.snap) : super(executor: null, isLocal: true);

  final ServerSnapshot snap;

  @override
  List<ServerSnapshot> get history => [snap];

  @override
  Future<ServerSnapshot> collect() async => snap;
}
