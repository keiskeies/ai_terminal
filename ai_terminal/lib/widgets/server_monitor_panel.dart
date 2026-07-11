import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../services/server_monitor_service.dart';

/// 服务器监控面板 — 单行紧凑布局（30px 高）
///
/// 左到右依次：[icon]用户 4 | [icon]开机 up 32 days | [icon]磁盘 12% |
/// [icon]内存 13.5GB/32GB [图表] | [icon]CPU 38% [图表] |
/// [icon]上传 0.01 Mb/s [图表] | [icon]下载 0.01 Mb/s [图表]
///
/// 鼠标 hover 或触屏 tap 弹出详细数据浮层，浮层左右两栏布局。
class ServerMonitorPanel extends StatefulWidget {
  final ServerMonitorService service;
  final Duration interval;
  final double height;

  const ServerMonitorPanel({
    super.key,
    required this.service,
    this.interval = const Duration(seconds: 5),
    this.height = 30,
  });

  @override
  State<ServerMonitorPanel> createState() => _ServerMonitorPanelState();
}

class _ServerMonitorPanelState extends State<ServerMonitorPanel> {
  Timer? _timer;
  ServerSnapshot? _last;
  bool _isCollecting = false;
  int _consecutiveFailures = 0; // 连续失败次数，>=2 时显示失败状态

  // 浮层控制
  OverlayEntry? _overlayEntry;
  String? _activeMetric; // 当前展示浮层的指标名
  Offset? _mousePosition; // 鼠标全局位置，用于浮层定位

  static const double _overlayMouseGap = 6;

  /// 按指标类型返回浮层宽度
  /// 网络/磁盘有表格 → 340；系统信息有长文本 → 320；其他两栏数字 → 280
  double _overlayWidthFor(String metric) {
    switch (metric) {
      case 'netUp':
      case 'netDown':
      case 'disk':
        return 340;
      case 'uptime':
        return 320;
      default:
        return 280;
    }
  }

  @override
  void initState() {
    super.initState();
    _collectNow();
    _timer = Timer.periodic(widget.interval, (_) => _collectNow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _hideOverlay();
    // 关闭面板时清除历史数据并停止后台采集
    // 下次打开时从 0 开始，避免显示陈旧数据；同时释放内存
    widget.service.reset();
    super.dispose();
  }

  Future<void> _collectNow() async {
    if (!mounted) return;
    if (_isCollecting) return;
    _isCollecting = true;
    try {
      final snap = await widget.service.collect();
      if (!mounted) return;
      setState(() {
        _last = snap;
        _consecutiveFailures = 0;
      });
      _isCollecting = false;
      // 如果浮层正在显示，刷新浮层数据
      if (_overlayEntry != null && _activeMetric != null) {
        _updateOverlayContent();
      }
    } catch (_) {
      if (!mounted) return;
      _isCollecting = false;
      setState(() => _consecutiveFailures++);
    }
  }

  // ==================== 工具函数 ====================

  /// 根据使用率百分比返回对应颜色
  /// < 80%: 正常色, 80~95%: 警告橙, >= 95%: 危险红
  Color _colorByPercent(double percent, Color normal) {
    if (percent >= 95) return cDanger;
    if (percent >= 80) return cWarning;
    return normal;
  }

  void _showOverlay(String metric, Offset mousePosition) {
    _mousePosition = mousePosition;
    if (_activeMetric == metric && _overlayEntry != null) {
      _overlayEntry!.markNeedsBuild();
      return;
    }
    _activeMetric = metric;
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
    }
    _overlayEntry = OverlayEntry(
      builder: (ctx) => _buildOverlay(metric),
    );
    Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
  }

  /// 轻量级位置更新：只更新鼠标位置并重建浮层
  /// 不经过条件检查，不受 widget tree 重建影响
  void _updateOverlayPosition(Offset mousePosition) {
    _mousePosition = mousePosition;
    _overlayEntry?.markNeedsBuild();
  }

  void _hideOverlay([String? metric]) {
    if (metric != null && _activeMetric != metric) return;
    _overlayEntry?.remove();
    _overlayEntry = null;
    _activeMetric = null;
    _mousePosition = null;
  }

  void _updateOverlayContent() {
    if (_overlayEntry == null) return;
    _overlayEntry!.markNeedsBuild();
  }

  // ==================== 构建 ====================

  /// 采集状态指示器
  /// 绿点=正常, 红点=连续失败, 灰点=未采集
  Widget _buildStatusIndicator(ThemeColors tc) {
    final isFailed = _consecutiveFailures >= 2;
    final hasData = _last != null;
    final l10n = AppLocalizations.of(context)!;
    final dotColor = isFailed
        ? cDanger
        : hasData
            ? cSuccess
            : tc.textMuted.withValues(alpha: 0.5);
    final tooltip = isFailed
        ? l10n.monitorCollectingFailed(_consecutiveFailures)
        : hasData
            ? l10n.monitorCollecting
            : l10n.monitorWaitingData;

    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Container(
        width: 16,
        height: widget.height,
        alignment: Alignment.center,
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final snap = _last;
    final history = widget.service.history;
    final isStale = _consecutiveFailures >= 2; // 数据是否过期（采集失败）

    // 数据过期时所有指标变灰
    Color staleColor(Color c) => isStale ? tc.textMuted : c;

    return Container(
      width: double.infinity,
      height: widget.height,
      decoration: BoxDecoration(
        color: tc.card,
        border: Border(top: BorderSide(color: tc.border, width: 0.5)),
      ),
      child: Listener(
        // 点击面板外部时隐藏浮层
        onPointerDown: (_) {
          if (_overlayEntry != null) {
            // 延迟隐藏，让指标项的 tap 先处理
            Future.microtask(() {
              if (_activeMetric != null) _hideOverlay();
            });
          }
        },
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            // 显式 min + start：内容从左对齐，不因全屏宽而被居中或拉伸
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              // 采集状态指示器
              _buildStatusIndicator(tc),
              const SizedBox(width: 4),
              _buildMetricChipWithChart(
                metric: 'cpu',
                icon: Icons.bolt,
                label: 'CPU',
                value: '${(snap?.cpuPercent ?? 0).toStringAsFixed(1)}%',
                color: staleColor(_colorByPercent(snap?.cpuPercent ?? 0, cPrimary)),
                chartData: history.map((s) => s.cpuPercent).toList(),
                chartMax: 100,
              ),
              _divider(tc),
              _buildMetricChipWithChart(
                metric: 'mem',
                icon: Icons.memory,
                label: l10n.monitorMemory,
                value: snap != null && snap.memTotalMB > 0
                    ? '${_formatGB(snap.memUsedMB)}/${_formatGB(snap.memTotalMB)}'
                    : '-',
                color: staleColor(_colorByPercent(snap?.memPercent ?? 0, cSuccess)),
                chartData: history.map((s) => s.memPercent).toList(),
                chartMax: 100,
              ),
              _divider(tc),
              _buildMetricChipWithChart(
                metric: 'netUp',
                icon: Icons.arrow_upward,
                label: '上传',
                value: _formatRate(snap?.netUpKBps ?? 0),
                color: staleColor(cPrimary),
                chartData: history.map((s) => s.netUpKBps).toList(),
                chartMax: null, // 自适应
              ),
              _divider(tc),
              _buildMetricChipWithChart(
                metric: 'netDown',
                icon: Icons.arrow_downward,
                label: '下载',
                value: _formatRate(snap?.netDownKBps ?? 0),
                color: staleColor(cSuccess),
                chartData: history.map((s) => s.netDownKBps).toList(),
                chartMax: null,
              ),
              _divider(tc),
              _buildMetricChip(
                metric: 'disk',
                icon: Icons.storage,
                label: '磁盘',
                value: '${(snap?.diskPercent ?? 0).toStringAsFixed(1)}%',
                color: staleColor(_colorByPercent(snap?.diskPercent ?? 0, cWarning)),
              ),
              _divider(tc),
              _buildMetricChip(
                metric: 'uptime',
                icon: Icons.access_time,
                label: l10n.monitorUptime,
                value: snap?.uptime ?? '-',
                color: isStale ? tc.textMuted : tc.textSub,
                valueMaxWidth: 100,
              ),
              _divider(tc),
              _buildMetricChip(
                metric: 'user',
                icon: Icons.person_outline,
                label: l10n.monitorUser,
                value: (snap?.hostname.isNotEmpty ?? false) ? snap!.hostname : '-',
                color: isStale ? tc.textMuted : tc.textSub,
                valueMaxWidth: 120,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _divider(ThemeColors tc) {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: tc.border.withValues(alpha: 0.3),
    );
  }

  /// 不带图表的指标项（用户/开机/磁盘）
  Widget _buildMetricChip({
    required String metric,
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    double? valueMaxWidth,
  }) {
    final tc = ThemeColors.of(context);
    return _MetricHoverWrapper(
      metric: metric,
      activeMetric: _activeMetric,
      color: color,
      onShow: _showOverlay,
      onHide: _hideOverlay,
      onHoverMove: _updateOverlayPosition,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
            Text('$label ', style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: valueMaxWidth ?? 80),
              child: Text(
                value,
                style: TextStyle(
                  fontSize: fMicro,
                  color: tc.textSub,
                  fontWeight: FontWeight.w500,
                  fontFamily: 'JetBrainsMono',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 带图表的指标项（内存/CPU/上传/下载）
  /// hover 只在图表区域触发，避免在图标/文字区域频繁切换
  Widget _buildMetricChipWithChart({
    required String metric,
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required List<double> chartData,
    double? chartMax,
  }) {
    final tc = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text('$label ', style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
          Text(
            value,
            style: TextStyle(
              fontSize: fMicro,
              color: color,
              fontWeight: FontWeight.w600,
              fontFamily: 'JetBrainsMono',
            ),
          ),
          const SizedBox(width: 4),
          _MetricHoverWrapper(
            metric: metric,
            activeMetric: _activeMetric,
            color: color,
            onShow: _showOverlay,
            onHide: _hideOverlay,
            onHoverMove: _updateOverlayPosition,
            child: SizedBox(
              width: 60,
              height: widget.height - 4,
              child: _buildMiniChart(chartData, color, chartMax),
            ),
          ),
        ],
      ),
    );
  }

  /// mini 折线图（无坐标轴，只显示趋势）
  Widget _buildMiniChart(List<double> data, Color color, double? max) {
    if (data.length < 2) {
      return Center(
        child: Text('…', style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.5))),
      );
    }
    // 降采样：60px 宽最多 60 个点，数据多时按桶取最大最小值保留趋势
    const targetPoints = 60;
    final sampled = data.length <= targetPoints
        ? data
        : _downsample(data, targetPoints);

    final spots = <FlSpot>[];
    for (int i = 0; i < sampled.length; i++) {
      spots.add(FlSpot(i.toDouble(), sampled[i].clamp(0, max ?? double.infinity)));
    }
    final actualMax = max ?? sampled.fold<double>(0, (a, b) => a > b ? a : b) * 1.2;

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: actualMax <= 0 ? 1 : actualMax,
        minX: 0,
        maxX: (sampled.length - 1).toDouble(),
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: color,
            barWidth: 1.2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.15),
            ),
            isStrokeCapRound: true,
          ),
        ],
        lineTouchData: const LineTouchData(enabled: false),
      ),
    );
  }

  /// 降采样：将数据按桶取最大最小值，保留峰值趋势
  List<double> _downsample(List<double> data, int targetCount) {
    if (data.length <= targetCount) return data;
    // 目标点数的一半作为桶数（每个桶取 2 个点：最小+最大）
    final bucketSize = data.length / (targetCount / 2).floor();
    final result = <double>[];
    for (int i = 0; i < data.length; i += bucketSize.toInt()) {
      final end = (i + bucketSize.toInt()).clamp(0, data.length);
      final bucket = data.sublist(i, end);
      if (bucket.isEmpty) continue;
      double mn = bucket.first;
      double mx = bucket.first;
      for (final v in bucket) {
        if (v < mn) mn = v;
        if (v > mx) mx = v;
      }
      // 先放最小，再放最大，保持顺序
      if (mn == mx) {
        result.add(mn);
      } else {
        // 按在桶中的顺序添加，保证折线走势正确
        final minIdx = bucket.indexOf(mn);
        final maxIdx = bucket.indexOf(mx);
        if (minIdx < maxIdx) {
          result.add(mn);
          result.add(mx);
        } else {
          result.add(mx);
          result.add(mn);
        }
      }
    }
    return result;
  }

  // ==================== 浮层内容 ====================

  Widget _buildOverlay(String metric) {
    final snap = _last;
    final tc = ThemeColors.of(context);
    if (snap == null) return const SizedBox.shrink();

    final (title, rows) = _getOverlayData(metric, snap);
    final screenSize = MediaQuery.of(context).size;
    final mouse = _mousePosition ?? Offset.zero;
    const margin = 8.0;

    // 浮层宽度：按内容需求 + 屏幕宽度上限
    final overlayWidth = _overlayWidthFor(metric).clamp(
      0.0,
      screenSize.width - margin * 2,
    );

    // 计算鼠标上下方的可用空间
    final spaceBelow = screenSize.height - mouse.dy - _overlayMouseGap - margin;
    final spaceAbove = mouse.dy - _overlayMouseGap - margin;

    // 默认放下方（top 定位），下方空间不够且上方更宽裕时放上方（bottom 定位）
    final placeBelow = spaceBelow >= 200 || spaceBelow >= spaceAbove;

    // 水平定位
    var left = mouse.dx + _overlayMouseGap;
    if (left + overlayWidth > screenSize.width - margin) {
      left = mouse.dx - overlayWidth - _overlayMouseGap;
    }
    if (left < margin) left = margin;
    if (left + overlayWidth > screenSize.width - margin) {
      left = screenSize.width - overlayWidth - margin;
    }

    // 垂直定位
    final double? positionedTop;
    final double? positionedBottom;
    final double maxContentHeight;

    if (placeBelow) {
      // 放下方：浮层顶部紧贴鼠标下方
      positionedTop = mouse.dy + _overlayMouseGap;
      positionedBottom = null;
      maxContentHeight = spaceBelow;
    } else {
      // 放上方：浮层底部紧贴鼠标上方
      positionedTop = null;
      positionedBottom = screenSize.height - mouse.dy + _overlayMouseGap;
      maxContentHeight = spaceAbove;
    }

    return Positioned(
      left: left,
      top: positionedTop,
      bottom: positionedBottom,
      width: overlayWidth,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxContentHeight),
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: tc.cardElevated,
              borderRadius: BorderRadius.circular(rMedium),
              border: Border.all(color: tc.border, width: 1),
              boxShadow: shadowXl,
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: fSmall,
                        color: tc.textMain,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _hideOverlay,
                      child: Icon(Icons.close, size: 12, color: tc.textMuted),
                    ),
                  ],
                ),
                Divider(height: 6, color: tc.border.withValues(alpha: 0.3)),
                // 网络/磁盘 → 表格布局；系统信息 → 单栏（长文本）；其他 → 两栏
                if (metric == 'netUp' || metric == 'netDown')
                  _buildNetOverlayContent(tc, snap)
                else if (metric == 'disk')
                  _buildDiskOverlayContent(tc, snap)
                else if (metric == 'uptime')
                  _buildSingleColumnRows(tc, rows)
                else
                  _buildTwoColumnRows(tc, rows),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 网络浮层专用内容：汇总 + 接口明细表格
  Widget _buildNetOverlayContent(ThemeColors tc, ServerSnapshot s) {
    final l10n = AppLocalizations.of(context)!;
    // 汇总信息
    final summary = [
      (l10n.monitorNetTotalDown, _formatRate(s.netDownKBps)),
      (l10n.monitorNetTotalUp, _formatRate(s.netUpKBps)),
      (l10n.monitorNetTotalDownloaded, _formatBytes(s.netTotalDownBytes)),
      (l10n.monitorNetTotalUploaded, _formatBytes(s.netTotalUpBytes)),
      (l10n.monitorNetInterfaceCount, '${s.interfaces.length}'),
    ];

    // 接口按总流量排序，活跃接口在前
    final sorted = List<NetInterface>.from(s.interfaces)
      ..sort((a, b) => (b.rxBytes + b.txBytes).compareTo(a.rxBytes + a.txBytes));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 汇总行（左右两栏）
        _buildTwoColumnRows(tc, summary),
        const SizedBox(height: 8),
        // 接口明细表
        Text(
          l10n.monitorNetInterfaceDetail,
          style: TextStyle(fontSize: fMicro, color: tc.textSub, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        // 表头
        _buildNetTableRow(
          tc,
          name: l10n.monitorNetColInterface,
          traffic: l10n.monitorNetColTraffic,
          rate: l10n.monitorNetColRate,
          issues: l10n.monitorNetColIssues,
          isHeader: true,
        ),
        // 表体（最多展示 8 个接口，避免浮层过高）
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 170),
          child: SingleChildScrollView(
            child: Column(
              children: sorted.take(8).map((iface) {
                final totalErr = iface.rxErrors + iface.txErrors;
                final totalDrop = iface.rxDropped + iface.txDropped;
                final hasIssue = totalErr > 0 || totalDrop > 0;
                final issueColor = hasIssue
                    ? (totalErr > 0 ? cDanger : cWarning)
                    : tc.textMuted;
                return _buildNetTableRow(
                  tc,
                  name: iface.name,
                  traffic: '${_formatBytes(iface.rxBytes)} / ${_formatBytes(iface.txBytes)}',
                  rate: '${_formatRate(iface.downKBps)} / ${_formatRate(iface.upKBps)}',
                  issues: hasIssue ? '$totalErr/$totalDrop' : '-',
                  issuesColor: issueColor,
                );
              }).toList(),
            ),
          ),
        ),
        if (sorted.length > 8)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.monitorNetMoreInterfaces(sorted.length - 8),
              style: TextStyle(fontSize: fMicro, color: tc.textMuted),
            ),
          ),
      ],
    );
  }

  /// 磁盘浮层专用内容：根分区汇总 + 分区明细表格
  Widget _buildDiskOverlayContent(ThemeColors tc, ServerSnapshot s) {
    final l10n = AppLocalizations.of(context)!;
    final partitions = s.diskPartitions;
    final totalDisk = partitions.fold<double>(0, (sum, p) => sum + p.totalGB);
    final usedDisk = partitions.fold<double>(0, (sum, p) => sum + p.usedGB);
    final overallPercent = totalDisk > 0 ? (usedDisk / totalDisk * 100) : 0.0;

    final summary = [
      (l10n.monitorDiskTotal, '${totalDisk.toStringAsFixed(1)} GB'),
      (l10n.monitorDiskUsed, '${usedDisk.toStringAsFixed(1)} GB'),
      (l10n.monitorDiskAvailable, '${(totalDisk - usedDisk).toStringAsFixed(1)} GB'),
      (l10n.monitorDiskOverallUsage, '${overallPercent.toStringAsFixed(1)}%'),
      (l10n.monitorDiskPartitionCount, '${partitions.length}'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTwoColumnRows(tc, summary),
        const SizedBox(height: 8),
        // 总使用率进度条
        Container(
          height: 6,
          decoration: BoxDecoration(
            color: tc.border.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(3),
          ),
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final w = constraints.maxWidth * (overallPercent / 100).clamp(0.0, 1.0);
              return Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: w,
                  decoration: BoxDecoration(
                    color: _colorByPercent(overallPercent, cSuccess),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        Text(
          l10n.monitorDiskPartitionDetail,
          style: TextStyle(fontSize: fMicro, color: tc.textSub, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        _buildDiskTableRow(
          tc,
          mount: l10n.monitorDiskColMount,
          used: l10n.monitorDiskColUsage,
          percent: l10n.monitorDiskColPercent,
          isHeader: true,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: SingleChildScrollView(
            child: Column(
              children: partitions.map((p) {
                return _buildDiskTableRow(
                  tc,
                  mount: p.mountPoint,
                  used: '${_formatGB(p.usedGB * 1024)} / ${_formatGB(p.totalGB * 1024)}',
                  percent: '${p.usePercent.toStringAsFixed(1)}%',
                  usePercent: p.usePercent,
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  /// 磁盘分区表格行
  Widget _buildDiskTableRow(
    ThemeColors tc, {
    required String mount,
    required String used,
    required String percent,
    bool isHeader = false,
    double usePercent = 0,
  }) {
    final textColor = isHeader ? tc.textMuted : tc.textSub;
    final fontWeight = isHeader ? FontWeight.w500 : FontWeight.w500;
    final barColor = isHeader
        ? tc.textMuted
        : _colorByPercent(usePercent, cSuccess);

    if (isHeader) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tc.border.withValues(alpha: 0.3), width: 0.5)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 70,
              child: Text(
                mount,
                style: TextStyle(fontSize: fMicro, color: textColor, fontWeight: fontWeight, fontFamily: 'JetBrainsMono'),
                textAlign: TextAlign.left,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                used,
                style: TextStyle(fontSize: fMicro, color: textColor, fontWeight: fontWeight, fontFamily: 'JetBrainsMono'),
                textAlign: TextAlign.left,
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 50,
              child: Text(
                percent,
                style: TextStyle(fontSize: fMicro, color: textColor, fontWeight: fontWeight, fontFamily: 'JetBrainsMono'),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 70,
                child: Text(
                  mount,
                  style: TextStyle(fontSize: fMicro, color: textColor, fontWeight: fontWeight, fontFamily: 'JetBrainsMono'),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  used,
                  style: TextStyle(fontSize: fMicro, color: tc.textMuted, fontFamily: 'JetBrainsMono'),
                  textAlign: TextAlign.left,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 50,
                child: Text(
                  percent,
                  style: TextStyle(fontSize: fMicro, color: barColor, fontWeight: FontWeight.w600, fontFamily: 'JetBrainsMono'),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 进度条
          Container(
            height: 4,
            decoration: BoxDecoration(
              color: tc.border.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                final w = constraints.maxWidth * (usePercent / 100).clamp(0.0, 1.0);
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

  /// 网络接口表格行（4 列布局，适配 340px 宽度）
  Widget _buildNetTableRow(
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
    );
    final issuesStyle = style.copyWith(
      color: issuesColor ?? style.color,
      fontWeight: issuesColor != null ? FontWeight.w600 : style.fontWeight,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          // 接口名 70px
          SizedBox(
            width: 70,
            child: Text(name, style: style, overflow: TextOverflow.ellipsis),
          ),
          // 总流量
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(traffic, style: style, overflow: TextOverflow.ellipsis),
            ),
          ),
          // 速率
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(rate, style: style, overflow: TextOverflow.ellipsis),
            ),
          ),
          // 错/丢 36px
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

  /// 构建左右两栏的数据行（适用于短数字/短文本 value）
  Widget _buildTwoColumnRows(ThemeColors tc, List<(String, String)> rows) {
    final mid = (rows.length / 2).ceil();
    final left = rows.sublist(0, mid);
    final right = rows.sublist(mid);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildColumn(tc, left)),
        const SizedBox(width: 12),
        Expanded(child: _buildColumn(tc, right)),
      ],
    );
  }

  /// 构建单栏数据行（适用于可能有长文本 value 的场景，如系统信息）
  Widget _buildSingleColumnRows(ThemeColors tc, List<(String, String)> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows.map((r) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 70,
                child: Text(
                  r.$1,
                  style: TextStyle(fontSize: fMicro, color: tc.textMuted),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.$2,
                  style: TextStyle(
                    fontSize: fMicro,
                    color: tc.textSub,
                    fontFamily: 'JetBrainsMono',
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

  Widget _buildColumn(ThemeColors tc, List<(String, String)> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows.map((r) {
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

  /// 返回浮层标题 + 数据行（label, value）
  (String, List<(String, String)>) _getOverlayData(String metric, ServerSnapshot s) {
    final l10n = AppLocalizations.of(context)!;
    switch (metric) {
      case 'cpu':
        return (
          l10n.monitorCpuDetail,
          [
            (l10n.monitorCpuTotalUsage, '${s.cpuPercent.toStringAsFixed(1)}%'),
            (l10n.monitorCpuUser, '${s.cpuUser.toStringAsFixed(1)}%'),
            (l10n.monitorCpuSystem, '${s.cpuSystem.toStringAsFixed(1)}%'),
            (l10n.monitorCpuIdle, '${s.cpuIdle.toStringAsFixed(1)}%'),
            (l10n.monitorLoad1, s.loadAvg1.toStringAsFixed(2)),
            (l10n.monitorLoad5, s.loadAvg5.toStringAsFixed(2)),
            (l10n.monitorLoad15, s.loadAvg15.toStringAsFixed(2)),
            (l10n.monitorProcessCount, '${s.processCount}'),
          ],
        );
      case 'mem':
        return (
          l10n.monitorMemoryDetail,
          [
            (l10n.monitorMemoryTotal, _formatMB(s.memTotalMB)),
            (l10n.monitorDiskUsed, _formatMB(s.memUsedMB)),
            (l10n.monitorDiskAvailable, _formatMB(s.memAvailableMB)),
            (l10n.monitorMemoryFree, _formatMB(s.memFreeMB)),
            (l10n.monitorMemoryCached, _formatMB(s.memCachedMB)),
            (l10n.monitorMemoryBuffers, _formatMB(s.memBuffersMB)),
            (l10n.monitorMemoryUsage, '${s.memPercent.toStringAsFixed(1)}%'),
            (l10n.monitorSwapTotal, _formatMB(s.swapTotalMB)),
            (l10n.monitorSwapUsed, _formatMB(s.swapUsedMB)),
          ],
        );
      case 'disk':
        return (
          l10n.monitorDiskDetail,
          [
            (l10n.monitorDiskTotal2, '${s.diskTotalGB.toStringAsFixed(1)} GB'),
            (l10n.monitorDiskUsed, '${s.diskUsedGB.toStringAsFixed(1)} GB'),
            (l10n.monitorDiskAvailable, '${s.diskFreeGB.toStringAsFixed(1)} GB'),
            (l10n.monitorDiskUsage, '${s.diskPercent.toStringAsFixed(1)}%'),
          ],
        );
      case 'netUp':
      case 'netDown':
        return (
          l10n.monitorNetDetail,
          const [],
        );
      case 'user':
        return (
          l10n.monitorUserSession,
          [
            (l10n.monitorLoginUsers, '${s.userCount}'),
            (l10n.monitorProcessCount, '${s.processCount}'),
            (l10n.monitorLoad1, s.loadAvg1.toStringAsFixed(2)),
            (l10n.monitorLoad5, s.loadAvg5.toStringAsFixed(2)),
          ],
        );
      case 'uptime':
        return (
          l10n.monitorSystemInfo,
          [
            (l10n.monitorUptimeLabel, s.uptime),
            (l10n.monitorKernelVersion, s.kernelVersion.isEmpty ? '-' : s.kernelVersion),
            (l10n.monitorLoad1, s.loadAvg1.toStringAsFixed(2)),
            (l10n.monitorLoad5, s.loadAvg5.toStringAsFixed(2)),
            (l10n.monitorLoad15, s.loadAvg15.toStringAsFixed(2)),
          ],
        );
      default:
        return ('-', const []);
    }
  }

  // ==================== 格式化工具 ====================

  String _formatRate(double kb) {
    if (kb < 1) return '${(kb * 1024).toStringAsFixed(0)} B/s';
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
    return '${(kb / 1024).toStringAsFixed(2)} MB/s';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatMB(double mb) {
    if (mb < 1024) return '${mb.toStringAsFixed(0)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  String _formatGB(double mb) {
    if (mb < 1024) return '${mb.toStringAsFixed(0)}MB';
    return '${(mb / 1024).toStringAsFixed(1)}GB';
  }
}

/// 指标项的 hover/tap 包装器
///
/// 桌面端：鼠标进入显示浮层，鼠标移出隐藏
/// 移动端：tap 切换浮层
class _MetricHoverWrapper extends StatefulWidget {
  final String metric;
  final String? activeMetric;
  final Color color;
  final void Function(String metric, Offset mousePosition) onShow;
  final void Function(String metric) onHide;
  final void Function(Offset mousePosition) onHoverMove;
  final Widget child;

  const _MetricHoverWrapper({
    required this.metric,
    required this.activeMetric,
    required this.color,
    required this.onShow,
    required this.onHide,
    required this.onHoverMove,
    required this.child,
  });

  @override
  State<_MetricHoverWrapper> createState() => _MetricHoverWrapperState();
}

class _MetricHoverWrapperState extends State<_MetricHoverWrapper> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.activeMetric == widget.metric;

    return MouseRegion(
      onEnter: (event) {
        if (!_isHovered) {
          _isHovered = true;
          widget.onShow(widget.metric, event.position);
        }
      },
      onHover: (event) {
        if (_isHovered) {
          widget.onHoverMove(event.position);
        }
      },
      onExit: (_) {
        _isHovered = false;
        widget.onHide(widget.metric);
      },
      child: GestureDetector(
        onTapDown: (details) {
          if (isActive) {
            widget.onHide(widget.metric);
          } else {
            widget.onShow(widget.metric, details.globalPosition);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          decoration: BoxDecoration(
            color: isActive ? widget.color.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(rXSmall),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
