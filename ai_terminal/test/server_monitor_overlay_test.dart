import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/services/server_monitor_service.dart';
import 'package:ai_terminal/widgets/server_monitor_panel.dart';

/// 监控浮层/详情窗回归：装了 Docker/K8s 的机器有 30+ 网卡、十几块挂载点，
/// 旧实现把接口硬截断成 8 个（"还有 20+ 个未显示"），且明细表没有 Flexible，
/// 弹层高度不足时磁盘分区被 RenderFlex 裁掉（"挤到下面"）。
NetInterface _iface(String name, int rx, int tx) => NetInterface(
      name: name,
      rxBytes: rx,
      txBytes: tx,
      rxErrors: 0,
      txErrors: 0,
      rxDropped: 0,
      txDropped: 0,
      downKBps: 1,
      upKBps: 1,
    );

ServerSnapshot _snapshot({
  required List<NetInterface> interfaces,
  required List<DiskPartition> partitions,
}) =>
    ServerSnapshot(
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
      interfaces: interfaces,
      diskPartitions: partitions,
    );

class _FakeMonitorService extends ServerMonitorService {
  _FakeMonitorService(this.snap) : super(executor: null, isLocal: true);

  final ServerSnapshot snap;

  @override
  List<ServerSnapshot> get history => [snap];

  @override
  Future<ServerSnapshot> collect() async => snap;
}

/// 计数版：用于断言"谁在轮询"。pump 会冲掉 async collect 的微任务，
/// 计数在每次 pump 后即时可读。
class _CountingMonitorService extends _FakeMonitorService {
  _CountingMonitorService(super.snap);

  int collectCount = 0;

  @override
  Future<ServerSnapshot> collect() async {
    collectCount++;
    return snap;
  }
}

Future<void> _pump(WidgetTester tester, ServerSnapshot snap) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.darkTheme,
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ServerMonitorPanel(
        service: _FakeMonitorService(snap),
        interval: const Duration(hours: 1),
      ),
    ),
  ));
  await tester.pump();
}

/// 用鼠标 hover 触发浮层（浮层是 MouseRegion.onEnter 的产物，无法直接 pump）
Future<void> _hover(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: const Offset(1, 1));
  addTearDown(gesture.removePointer);
  await tester.pumpAndSettle();
  await gesture.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
}

void main() {
  // 3 个真实网卡 + 24 个容器虚拟网卡，按流量排序后虚拟网卡排在前面
  final interfaces = <NetInterface>[
    _iface('eth0', 900000000, 800000000),
    _iface('eth1', 700000000, 600000000),
    _iface('lo', 500000000, 500000000),
    ...List.generate(
      24,
      (i) => _iface(i.isEven ? 'veth${i}a1' : 'br-${i}x', 1000 * i, 1000 * i),
    ),
  ];
  final partitions = List.generate(
    14,
    (i) => DiskPartition(
      filesystem: '/dev/sd${String.fromCharCode(98 + i)}1',
      mountPoint: '/mnt/data$i',
      totalGB: 200 - i.toDouble(),
      usedGB: 80 + i.toDouble(),
      freeGB: 120 - 2 * i.toDouble(),
      usePercent: 40 + i.toDouble(),
    ),
  );

  testWidgets('网络浮层不再硬截断：真实网卡直接列出，虚拟网卡折叠成一行', (tester) async {
    await _pump(tester, _snapshot(interfaces: interfaces, partitions: partitions));

    await _hover(tester, find.text('34.0 KB/s'));

    // 虚拟网卡折叠：只出现汇总行，不逐个列出
    expect(find.textContaining('虚拟接口'), findsOneWidget);
    expect(find.text('veth0a1'), findsNothing);

    // 真实网卡（非虚拟）直接可见
    expect(find.text('eth0'), findsOneWidget);
    expect(find.text('eth1'), findsOneWidget);

    // 旧的"还有 N 个接口未显示"式死胡同提示必须消失
    expect(find.textContaining('未显示'), findsNothing);
  });

  testWidgets('磁盘浮层多分区不溢出：速览限行 + 剩余数提示', (tester) async {
    await _pump(tester, _snapshot(interfaces: interfaces, partitions: partitions));

    await _hover(tester, find.text('52.0%'));

    // 浮层是速览：最多 6 行，剩下的用 +N 指路到详情窗（widget test 会因
    // RenderFlex overflow 直接失败，这里能过就说明"挤到下面"没复发）
    expect(find.textContaining('/mnt/data'), findsNWidgets(6));
    expect(find.text('+8'), findsOneWidget);
  });

  testWidgets('点击磁盘芯片打开详情窗并列出全部分区', (tester) async {
    await _pump(tester, _snapshot(interfaces: interfaces, partitions: partitions));

    await tester.tap(find.text('52.0%'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    // 14 块分区全部渲染，一条不丢
    for (var i = 0; i < 14; i++) {
      expect(find.text('/mnt/data$i'), findsOneWidget, reason: '第 $i 块分区缺失');
    }

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('详情窗打开期间面板不重复轮询，关闭后恢复', (tester) async {
    final service = _CountingMonitorService(
      _snapshot(interfaces: interfaces, partitions: partitions),
    );
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ServerMonitorPanel(
            service: service,
            interval: const Duration(seconds: 10),
          ),
        ),
      ),
    ));
    await tester.pump();
    final baseline = service.collectCount;

    // 打开详情窗前，面板轮询推进
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(service.collectCount, greaterThan(baseline));
    final opened = service.collectCount;

    await tester.tap(find.text('52.0%'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    // 详情窗自己刷新一次；此后窗口打开期间面板不得再叠加采集：
    // 每 10s 全局增量必须恰为 1（详情窗自己的那一次），双轮询会变成 2
    final withDialog = service.collectCount;
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(service.collectCount, withDialog + 1,
        reason: '详情窗打开期间面板仍在轮询（双采集者）');

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(service.collectCount, greaterThan(withDialog), reason: '关窗后面板未恢复轮询');
    expect(opened, lessThan(withDialog));
  });

  testWidgets('网络详情窗展开虚拟网卡分组后 27 个接口全部可见', (tester) async {
    await _pump(tester, _snapshot(interfaces: interfaces, partitions: partitions));

    await tester.tap(find.text('34.0 KB/s'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('veth0a1'), findsNothing);

    await tester.tap(find.textContaining('虚拟接口'));
    await tester.pumpAndSettle();

    for (var i = 0; i < 24; i++) {
      final name = i.isEven ? 'veth${i}a1' : 'br-${i}x';
      expect(find.text(name), findsOneWidget, reason: '$name 缺失');
    }

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
  });
}
