import 'dart:async';
import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../services/server_monitor_service.dart';

// ==================== 格式化（监控浮层与详情窗共用） ====================

String fmtRate(double kb) {
  if (kb < 1) return '${(kb * 1024).toStringAsFixed(0)} B/s';
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
  return '${(kb / 1024).toStringAsFixed(2)} MB/s';
}

String fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024)
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String fmtMB(double mb) {
  if (mb < 1024) return '${mb.toStringAsFixed(0)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// mb 是 MB 单位的值，用于把内存/磁盘字节数写成 "13.5GB/32GB"
String fmtFromMB(double mb) {
  if (mb < 1024) return '${mb.toStringAsFixed(0)}MB';
  return '${(mb / 1024).toStringAsFixed(1)}GB';
}

/// < 80%: 正常色, 80~95%: 警告橙, >= 95%: 危险红
Color monitorColorByPercent(double percent, ThemeColors tc, {Color? normal}) {
  if (percent >= 95) return tc.error;
  if (percent >= 80) return tc.warn;
  return normal ?? tc.ok;
}

/// 虚拟/容器网卡判定：Docker/K8s/网桥/veth/tap 这类接口在一台跑容器的机器上
/// 能占 30+ 行且绝大多数零流量，把真实网卡挤出可视区。
/// 大小写不敏感是为了 Windows 连接名（"vEthernet (NAT)"）；loopback 例外，
/// 只精确匹配 Linux 的 "lo" —— 否则大小写不敏感的 ^lo 会吃掉 Windows 的
/// "Local Area Connection"（真实网卡）。
final RegExp _virtualIfacePattern = RegExp(
  r'^(docker|br-|veth|virbr|virnet|tap|tunl|kube|flannel|cali|cni|cilium|lxc|lxdbr|dummy|ifb)',
  caseSensitive: false,
);

bool isVirtualNetInterface(String name) =>
    name == 'lo' || _virtualIfacePattern.hasMatch(name);

/// 按总流量降序
List<NetInterface> sortInterfacesByTraffic(List<NetInterface> list) {
  final sorted = List<NetInterface>.from(list)
    ..sort((a, b) => (b.rxBytes + b.txBytes).compareTo(a.rxBytes + a.txBytes));
  return sorted;
}

// ==================== 表格行 ====================

/// 网络接口表格行（4 列），浮层与详情窗共用同一份列结构
Widget netTableRow(
  ThemeColors tc, {
  required String name,
  required String traffic,
  required String rate,
  required String issues,
  bool isHeader = false,
  Color? issuesColor,
}) {
  final style = TextStyle(
    fontSize: fMicro,
    color: isHeader ? tc.textMuted : tc.textSub,
    fontWeight: isHeader ? FontWeight.w500 : FontWeight.normal,
    fontFamily: isHeader ? null : 'JetBrainsMono',
    fontFamilyFallback: isHeader ? null : kMonoFontFallback,
  );
  final issuesStyle = style.copyWith(
    color: issuesColor ?? style.color,
    fontWeight: issuesColor != null ? FontWeight.w600 : style.fontWeight,
  );
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 1.5),
    child: Row(
      children: [
        SizedBox(
          width: 70,
          child: Text(name, style: style, overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          flex: 3,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(traffic, style: style, overflow: TextOverflow.ellipsis),
          ),
        ),
        Expanded(
          flex: 3,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(rate, style: style, overflow: TextOverflow.ellipsis),
          ),
        ),
        SizedBox(
          width: 36,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(issues, style: issuesStyle),
          ),
        ),
      ],
    ),
  );
}

/// 磁盘分区表格行：数字行 + 使用率进度条
Widget diskTableRow(
  ThemeColors tc, {
  required String mount,
  required String used,
  required String percent,
  bool isHeader = false,
  double usePercent = 0,
}) {
  final textColor = isHeader ? tc.textMuted : tc.textSub;
  final barColor =
      isHeader ? tc.textMuted : monitorColorByPercent(usePercent, tc);
  final rowStyle = TextStyle(
    fontSize: fMicro,
    color: textColor,
    fontWeight: FontWeight.w500,
    fontFamily: 'JetBrainsMono',
    fontFamilyFallback: kMonoFontFallback,
  );

  final headerRow = Row(
    children: [
      SizedBox(width: 70, child: Text(mount, style: rowStyle)),
      const SizedBox(width: 6),
      Expanded(child: Text(used, style: rowStyle)),
      const SizedBox(width: 6),
      SizedBox(
        width: 50,
        child: Text(
          percent,
          style: rowStyle.copyWith(
            color: isHeader ? tc.textMuted : barColor,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.right,
        ),
      ),
    ],
  );

  if (isHeader) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tc.hairline)),
      ),
      child: headerRow,
    );
  }

  return Container(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        headerRow,
        const SizedBox(height: 4),
        Container(
          height: 4,
          decoration: BoxDecoration(
            color: tc.border.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(2),
          ),
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final w =
                  constraints.maxWidth * (usePercent / 100).clamp(0.0, 1.0);
              return Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: w,
                  decoration: BoxDecoration(
                    color: barColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

/// 左右两栏 label/value（浮层汇总区与详情窗共用）
Widget twoColumnRows(ThemeColors tc, List<(String, String)> rows) {
  Widget column(List<(String, String)> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items.map((r) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.$1,
                style: TextStyle(fontSize: fMicro, color: tc.textMuted),
              ),
              const Spacer(),
              Expanded(
                flex: 2,
                child: Text(
                  r.$2,
                  style: TextStyle(
                    fontSize: fMicro,
                    color: tc.textSub,
                    fontFamily: 'JetBrainsMono',
                    fontFamilyFallback: kMonoFontFallback,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  final mid = (rows.length / 2).ceil();
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: column(rows.sublist(0, mid))),
      const SizedBox(width: 12),
      Expanded(child: column(rows.sublist(mid))),
    ],
  );
}

/// 细进度条（详情窗磁盘总使用率）
Widget usageBar(ThemeColors tc, double percent, Color color,
    {double height = 6}) {
  return Container(
    height: height,
    decoration: BoxDecoration(
      color: tc.border.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(height / 2),
    ),
    child: LayoutBuilder(
      builder: (ctx, constraints) {
        final w = constraints.maxWidth * (percent / 100).clamp(0.0, 1.0);
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: w,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(height / 2),
            ),
          ),
        );
      },
    ),
  );
}

// ==================== 详情对话框 ====================

/// 把指标映射到详情类型；只有带明细表的指标才有详情窗
String? monitorDetailKind(String metric) {
  switch (metric) {
    case 'netUp':
    case 'netDown':
      return 'net';
    case 'disk':
      return 'disk';
    default:
      return null;
  }
}

/// 点击网络/磁盘指标弹出的详情窗：整表可滚、无行数上限，按 interval 跟随刷新
Future<void> showMonitorDetailDialog(
  BuildContext context, {
  required ServerMonitorService service,
  required String metric,
  required Duration interval,
}) {
  final kind = monitorDetailKind(metric);
  if (kind == null) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (ctx) => _MonitorDetailDialog(
      service: service,
      kind: kind,
      interval: interval,
    ),
  );
}

class _MonitorDetailDialog extends StatefulWidget {
  final ServerMonitorService service;
  final String kind;
  final Duration interval;

  const _MonitorDetailDialog({
    required this.service,
    required this.kind,
    required this.interval,
  });

  @override
  State<_MonitorDetailDialog> createState() => _MonitorDetailDialogState();
}

class _MonitorDetailDialogState extends State<_MonitorDetailDialog> {
  ServerSnapshot? _snap;
  Timer? _timer;

  /// 虚拟网卡/零流量接口默认折叠 —— 一屏先看真实设备
  bool _showVirtual = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(widget.interval, (_) => _refresh());
  }

  @override
  void dispose() {
    // 只停自己的定时器；历史数据归 service 所有，面板还要用
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final snap = await widget.service.collect();
      if (!mounted) return;
      setState(() => _snap = snap);
    } catch (_) {
      // 采集失败保留上一次快照：详情窗是只读视图，清空反而丢信息
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    final size = MediaQuery.of(context).size;
    final snap = _snap;
    final isNet = widget.kind == 'net';

    return Dialog(
      backgroundColor: tc.card,
      insetPadding: const EdgeInsets.all(24),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: Container(
        // 上下限都要贴屏幕：clamp 下限 520/360 在小窗口里会把 dialog 撑出
        // 视口（insetPadding 也救不回来），先按可用尺寸取 min
        width:
            (size.width * 0.6).clamp(520.0, 820.0).clamp(0.0, size.width - 48),
        height: (size.height * 0.72)
            .clamp(360.0, 760.0)
            .clamp(0.0, size.height - 48),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isNet ? Icons.lan_outlined : Icons.storage_outlined,
                    size: 16, color: tc.brand),
                const SizedBox(width: 8),
                Text(
                  isNet ? l10n.monitorNetDetail : l10n.monitorDiskDetail,
                  style: TextStyle(
                    color: tc.textMain,
                    fontSize: fBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  l10n.monitorLiveUpdating(widget.interval.inSeconds),
                  style: TextStyle(fontSize: fMicro, color: tc.textMuted),
                ),
                const Spacer(),
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(rXSmall),
                  onTap: () => Navigator.of(context).pop(),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 16, color: tc.textMuted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: tc.hairline),
            const SizedBox(height: 10),
            if (snap == null || snap.error != null)
              Expanded(
                child: Center(
                  child: Text(
                    snap?.error ?? l10n.monitorWaitingData,
                    style: TextStyle(fontSize: fMicro, color: tc.textMuted),
                  ),
                ),
              )
            else
              Expanded(
                child: SingleChildScrollView(
                  child: isNet
                      ? _netBody(tc, l10n, snap)
                      : _diskBody(tc, l10n, snap),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toggleChip(ThemeColors tc,
      {required String label, required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(rXSmall),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: tc.border, width: 1),
          borderRadius: BorderRadius.circular(rXSmall),
        ),
        child:
            Text(label, style: TextStyle(fontSize: fMicro, color: tc.textSub)),
      ),
    );
  }

  Widget _sectionTitle(ThemeColors tc, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: fMicro,
          color: tc.textSub,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _netBody(ThemeColors tc, AppLocalizations l10n, ServerSnapshot s) {
    final sorted = sortInterfacesByTraffic(s.interfaces);
    final real = sorted.where((i) => !isVirtualNetInterface(i.name)).toList();
    final virtual = sorted.where((i) => isVirtualNetInterface(i.name)).toList();

    Widget ifaceRow(NetInterface iface) {
      final issues =
          iface.rxErrors + iface.txErrors + iface.rxDropped + iface.txDropped;
      return netTableRow(
        tc,
        name: iface.name,
        traffic: '${fmtBytes(iface.rxBytes)} / ${fmtBytes(iface.txBytes)}',
        rate: '${fmtRate(iface.downKBps)} / ${fmtRate(iface.upKBps)}',
        issues: issues > 0
            ? '${iface.rxErrors + iface.txErrors}/${iface.rxDropped + iface.txDropped}'
            : '-',
        issuesColor: issues > 0
            ? (iface.rxErrors + iface.txErrors > 0 ? tc.error : tc.warn)
            : tc.textMuted,
      );
    }

    Widget header() => netTableRow(
          tc,
          name: l10n.monitorNetColInterface,
          traffic: l10n.monitorNetColTraffic,
          rate: l10n.monitorNetColRate,
          issues: l10n.monitorNetColIssues,
          isHeader: true,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        twoColumnRows(tc, [
          (l10n.monitorNetTotalDown, fmtRate(s.netDownKBps)),
          (l10n.monitorNetTotalUp, fmtRate(s.netUpKBps)),
          (l10n.monitorNetTotalDownloaded, fmtBytes(s.netTotalDownBytes)),
          (l10n.monitorNetTotalUploaded, fmtBytes(s.netTotalUpBytes)),
          (l10n.monitorNetInterfaceCount, '${s.interfaces.length}'),
        ]),
        _sectionTitle(tc, '${l10n.monitorNetInterfaceDetail} · ${real.length}'),
        header(),
        ...real.map(ifaceRow),
        if (virtual.isNotEmpty)
          _toggleChip(
            tc,
            label: '${l10n.monitorNetVirtualGroup(virtual.length)}'
                '${_showVirtual ? ' · ${l10n.monitorHideVirtual}' : ' · ${l10n.monitorShowVirtual}'}',
            onTap: () => setState(() => _showVirtual = !_showVirtual),
          ),
        if (_showVirtual) ...[
          const SizedBox(height: 4),
          ...virtual.map(ifaceRow),
        ],
      ],
    );
  }

  Widget _diskBody(ThemeColors tc, AppLocalizations l10n, ServerSnapshot s) {
    final partitions = s.diskPartitions;
    final total = partitions.fold<double>(0, (sum, p) => sum + p.totalGB);
    final used = partitions.fold<double>(0, (sum, p) => sum + p.usedGB);
    final overall = total > 0 ? (used / total * 100) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        twoColumnRows(tc, [
          (l10n.monitorDiskTotal, '${total.toStringAsFixed(1)} GB'),
          (l10n.monitorDiskUsed, '${used.toStringAsFixed(1)} GB'),
          (
            l10n.monitorDiskAvailable,
            '${(total - used).toStringAsFixed(1)} GB'
          ),
          (l10n.monitorDiskOverallUsage, '${overall.toStringAsFixed(1)}%'),
          (l10n.monitorDiskPartitionCount, '${partitions.length}'),
        ]),
        const SizedBox(height: 10),
        usageBar(tc, overall, monitorColorByPercent(overall, tc)),
        _sectionTitle(tc, l10n.monitorDiskPartitionDetail),
        diskTableRow(
          tc,
          mount: l10n.monitorDiskColMount,
          used: l10n.monitorDiskColUsage,
          percent: l10n.monitorDiskColPercent,
          isHeader: true,
        ),
        ...partitions.map(
          (p) => diskTableRow(
            tc,
            mount: p.mountPoint,
            used:
                '${fmtFromMB(p.usedGB * 1024)} / ${fmtFromMB(p.totalGB * 1024)}',
            percent: '${p.usePercent.toStringAsFixed(1)}%',
            usePercent: p.usePercent,
          ),
        ),
      ],
    );
  }
}
