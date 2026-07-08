import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
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

  // 浮层控制
  OverlayEntry? _overlayEntry;
  String? _activeMetric; // 当前展示浮层的指标名

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
    setState(() => _isCollecting = true);
    try {
      final snap = await widget.service.collect();
      if (!mounted) return;
      setState(() {
        _last = snap;
        _isCollecting = false;
      });
      // 如果浮层正在显示，刷新浮层数据
      if (_overlayEntry != null && _activeMetric != null) {
        _updateOverlayContent();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCollecting = false);
    }
  }

  // ==================== 浮层管理 ====================

  void _showOverlay(String metric) {
    if (_activeMetric == metric && _overlayEntry != null) return;
    _hideOverlay();
    _activeMetric = metric;
    _overlayEntry = OverlayEntry(
      builder: (ctx) => _buildOverlay(metric),
    );
    Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
  }

  void _hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _activeMetric = null;
  }

  void _updateOverlayContent() {
    if (_overlayEntry == null) return;
    _overlayEntry!.markNeedsBuild();
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final snap = _last;
    final history = widget.service.history;

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
              _buildMetricChip(
                metric: 'user',
                icon: Icons.person_outline,
                label: '用户',
                value: (snap?.hostname.isNotEmpty ?? false) ? snap!.hostname : '-',
                color: cKleinBlue,
                valueMaxWidth: 120,
              ),
              _divider(tc),
              _buildMetricChip(
                metric: 'uptime',
                icon: Icons.access_time,
                label: '开机',
                value: snap?.uptime ?? '-',
                color: cKleinBlue,
                valueMaxWidth: 100,
              ),
              _divider(tc),
              _buildMetricChip(
                metric: 'disk',
                icon: Icons.storage,
                label: '磁盘',
                value: '${(snap?.diskPercent ?? 0).toStringAsFixed(1)}%',
                color: cKleinBlue,
              ),
              _divider(tc),
              _buildMetricChipWithChart(
                metric: 'mem',
                icon: Icons.memory,
                label: '内存',
                value: snap != null && snap.memTotalMB > 0
                    ? '${_formatGB(snap.memUsedMB)}/${_formatGB(snap.memTotalMB)}'
                    : '-',
                color: cViolet,
                chartData: history.map((s) => s.memPercent).toList(),
                chartMax: 100,
              ),
              _divider(tc),
              _buildMetricChipWithChart(
                metric: 'cpu',
                icon: Icons.bolt,
                label: 'CPU',
                value: '${(snap?.cpuPercent ?? 0).toStringAsFixed(1)}%',
                color: cKleinBlue,
                chartData: history.map((s) => s.cpuPercent).toList(),
                chartMax: 100,
              ),
              _divider(tc),
              _buildMetricChipWithChart(
                metric: 'netUp',
                icon: Icons.arrow_upward,
                label: '上传',
                value: _formatRate(snap?.netUpKBps ?? 0),
                color: cLimeGreen,
                chartData: history.map((s) => s.netUpKBps).toList(),
                chartMax: null, // 自适应
              ),
              _divider(tc),
              _buildMetricChipWithChart(
                metric: 'netDown',
                icon: Icons.arrow_downward,
                label: '下载',
                value: _formatRate(snap?.netDownKBps ?? 0),
                color: cHermesOrange,
                chartData: history.map((s) => s.netDownKBps).toList(),
                chartMax: null,
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
      onShow: _showOverlay,
      onHide: _hideOverlay,
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
    return _MetricHoverWrapper(
      metric: metric,
      activeMetric: _activeMetric,
      onShow: _showOverlay,
      onHide: _hideOverlay,
      child: Padding(
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
            SizedBox(
              width: 60,
              height: widget.height - 4,
              child: _buildMiniChart(chartData, color, chartMax),
            ),
          ],
        ),
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
    final spots = <FlSpot>[];
    for (int i = 0; i < data.length; i++) {
      spots.add(FlSpot(i.toDouble(), data[i].clamp(0, max ?? double.infinity)));
    }
    final actualMax = max ?? data.fold<double>(0, (a, b) => a > b ? a : b) * 1.2;

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: actualMax <= 0 ? 1 : actualMax,
        minX: 0,
        maxX: (data.length - 1).toDouble(),
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

  // ==================== 浮层内容 ====================

  Widget _buildOverlay(String metric) {
    final snap = _last;
    final tc = ThemeColors.of(context);
    if (snap == null) return const SizedBox.shrink();

    final (title, rows) = _getOverlayData(metric, snap);
    return Positioned(
      // 浮层位置：全屏水平居中，固定在面板上方
      bottom: widget.height + 4,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 360,
            decoration: BoxDecoration(
              color: cCardElevated,
              borderRadius: BorderRadius.circular(rMedium),
              border: Border.all(color: cBorder, width: 1),
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
                // 网络/磁盘浮层使用专用表格布局，其他使用左右两栏
                if (metric == 'netUp' || metric == 'netDown')
                  _buildNetOverlayContent(tc, snap)
                else if (metric == 'disk')
                  _buildDiskOverlayContent(tc, snap)
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
    // 汇总信息
    final summary = [
      ('总下行速率', _formatRate(s.netDownKBps)),
      ('总上行速率', _formatRate(s.netUpKBps)),
      ('累计下载', _formatBytes(s.netTotalDownBytes)),
      ('累计上传', _formatBytes(s.netTotalUpBytes)),
      ('接口数', '${s.interfaces.length}'),
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
          '接口明细',
          style: TextStyle(fontSize: fMicro, color: tc.textSub, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        // 表头
        _buildNetTableRow(
          tc,
          name: '接口',
          traffic: '总流量 ↓/↑',
          rate: '速率 ↓/↑',
          issues: '错/丢',
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
                return _buildNetTableRow(
                  tc,
                  name: iface.name,
                  traffic: '${_formatBytes(iface.rxBytes)} / ${_formatBytes(iface.txBytes)}',
                  rate: '${_formatRate(iface.downKBps)} / ${_formatRate(iface.upKBps)}',
                  issues: totalErr > 0 || totalDrop > 0 ? '$totalErr/$totalDrop' : '-',
                );
              }).toList(),
            ),
          ),
        ),
        if (sorted.length > 8)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '还有 ${sorted.length - 8} 个接口未显示',
              style: TextStyle(fontSize: fMicro, color: tc.textMuted),
            ),
          ),
      ],
    );
  }

  /// 磁盘浮层专用内容：根分区汇总 + 分区明细表格
  Widget _buildDiskOverlayContent(ThemeColors tc, ServerSnapshot s) {
    final partitions = s.diskPartitions;
    final totalDisk = partitions.fold<double>(0, (sum, p) => sum + p.totalGB);
    final usedDisk = partitions.fold<double>(0, (sum, p) => sum + p.usedGB);
    final overallPercent = totalDisk > 0 ? (usedDisk / totalDisk * 100) : 0.0;

    final summary = [
      ('总容量', '${totalDisk.toStringAsFixed(1)} GB'),
      ('已用', '${usedDisk.toStringAsFixed(1)} GB'),
      ('可用', '${(totalDisk - usedDisk).toStringAsFixed(1)} GB'),
      ('总使用率', '${overallPercent.toStringAsFixed(1)}%'),
      ('分区数', '${partitions.length}'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTwoColumnRows(tc, summary),
        const SizedBox(height: 8),
        Text(
          '分区明细',
          style: TextStyle(fontSize: fMicro, color: tc.textSub, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        _buildDiskTableRow(
          tc,
          mount: '挂载点',
          used: '已用/总量',
          percent: '使用率',
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
    final percentColor = isHeader
        ? tc.textMuted
        : usePercent >= 90
            ? cDanger
            : usePercent >= 75
                ? cHermesOrange
                : cLimeGreen;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        border: isHeader
            ? Border(bottom: BorderSide(color: tc.border.withValues(alpha: 0.3), width: 0.5))
            : null,
      ),
      child: Row(
        children: [
          // 挂载点（左对齐）
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
          // 已用/总量（flex 填满）
          Expanded(
            child: Text(
              used,
              style: TextStyle(fontSize: fMicro, color: textColor, fontWeight: fontWeight, fontFamily: 'JetBrainsMono'),
              textAlign: TextAlign.left,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          // 使用率（右对齐，带颜色）
          SizedBox(
            width: 50,
            child: Text(
              percent,
              style: TextStyle(fontSize: fMicro, color: percentColor, fontWeight: FontWeight.w600, fontFamily: 'JetBrainsMono'),
              textAlign: TextAlign.right,
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
  }) {
    final style = TextStyle(
      fontSize: fMicro,
      color: isHeader ? tc.textMuted : tc.textSub,
      fontWeight: isHeader ? FontWeight.w500 : FontWeight.normal,
      fontFamily: isHeader ? null : 'JetBrainsMono',
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
              child: Text(issues, style: style),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建左右两栏的数据行
  Widget _buildTwoColumnRows(ThemeColors tc, List<(String, String)> rows) {
    // 将 rows 分成左右两组
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

  Widget _buildColumn(ThemeColors tc, List<(String, String)> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows.map((r) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            children: [
              Text(
                r.$1,
                style: TextStyle(fontSize: fMicro, color: tc.textMuted),
              ),
              const Spacer(),
              Text(
                r.$2,
                style: TextStyle(
                  fontSize: fMicro,
                  color: tc.textSub,
                  fontFamily: 'JetBrainsMono',
                  fontWeight: FontWeight.w500,
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
    switch (metric) {
      case 'cpu':
        return (
          'CPU 详情',
          [
            ('总使用率', '${s.cpuPercent.toStringAsFixed(1)}%'),
            ('用户态', '${s.cpuUser.toStringAsFixed(1)}%'),
            ('内核态', '${s.cpuSystem.toStringAsFixed(1)}%'),
            ('空闲', '${s.cpuIdle.toStringAsFixed(1)}%'),
            ('1分钟负载', s.loadAvg1.toStringAsFixed(2)),
            ('5分钟负载', s.loadAvg5.toStringAsFixed(2)),
            ('15分钟负载', s.loadAvg15.toStringAsFixed(2)),
            ('进程数', '${s.processCount}'),
          ],
        );
      case 'mem':
        return (
          '内存详情',
          [
            ('总内存', '${_formatMB(s.memTotalMB)}'),
            ('已用', '${_formatMB(s.memUsedMB)}'),
            ('可用', '${_formatMB(s.memAvailableMB)}'),
            ('空闲', '${_formatMB(s.memFreeMB)}'),
            ('缓存', '${_formatMB(s.memCachedMB)}'),
            ('缓冲', '${_formatMB(s.memBuffersMB)}'),
            ('使用率', '${s.memPercent.toStringAsFixed(1)}%'),
            ('Swap 总量', '${_formatMB(s.swapTotalMB)}'),
            ('Swap 已用', '${_formatMB(s.swapUsedMB)}'),
          ],
        );
      case 'disk':
        return (
          '磁盘详情',
          [
            ('总量', '${s.diskTotalGB.toStringAsFixed(1)} GB'),
            ('已用', '${s.diskUsedGB.toStringAsFixed(1)} GB'),
            ('可用', '${s.diskFreeGB.toStringAsFixed(1)} GB'),
            ('使用率', '${s.diskPercent.toStringAsFixed(1)}%'),
          ],
        );
      case 'netUp':
      case 'netDown':
        return (
          '网络详情',
          const [],
        );
      case 'user':
        return (
          '用户与会话',
          [
            ('登录用户数', '${s.userCount}'),
            ('进程数', '${s.processCount}'),
            ('1分钟负载', s.loadAvg1.toStringAsFixed(2)),
            ('5分钟负载', s.loadAvg5.toStringAsFixed(2)),
          ],
        );
      case 'uptime':
        return (
          '系统信息',
          [
            ('开机时长', s.uptime),
            ('内核版本', s.kernelVersion.isEmpty ? '-' : s.kernelVersion),
            ('1分钟负载', s.loadAvg1.toStringAsFixed(2)),
            ('5分钟负载', s.loadAvg5.toStringAsFixed(2)),
            ('15分钟负载', s.loadAvg15.toStringAsFixed(2)),
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
  final void Function(String metric) onShow;
  final VoidCallback onHide;
  final Widget child;

  const _MetricHoverWrapper({
    required this.metric,
    required this.activeMetric,
    required this.onShow,
    required this.onHide,
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
    final tc = ThemeColors.of(context);

    return MouseRegion(
      onEnter: (_) {
        if (!_isHovered) {
          _isHovered = true;
          widget.onShow(widget.metric);
        }
      },
      onExit: (_) {
        _isHovered = false;
        // 延迟隐藏，让鼠标能移到浮层上
        Future.delayed(const Duration(milliseconds: 200), () {
          if (!_isHovered && mounted) {
            widget.onHide();
          }
        });
      },
      child: GestureDetector(
        onTap: () {
          if (isActive) {
            widget.onHide();
          } else {
            widget.onShow(widget.metric);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          decoration: BoxDecoration(
            color: isActive ? cPrimary.withValues(alpha: 0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(rXSmall),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
