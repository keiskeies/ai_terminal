import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../services/server_monitor_service.dart';

/// 服务器监控面板（MobaXterm 风格 + 动态折线图）
///
/// 在终端下方横幅区域展示 CPU/内存/带宽折线图 + 用户/开机时间/磁盘等关键指标。
/// 每 5 秒采集一次，保留最近 60 个数据点（5 分钟）。
class ServerMonitorPanel extends StatefulWidget {
  /// 监控服务（外部持有，跨 tab 切换保持存活）
  final ServerMonitorService service;

  /// 采集间隔
  final Duration interval;

  /// 高度
  final double height;

  const ServerMonitorPanel({
    super.key,
    required this.service,
    this.interval = const Duration(seconds: 5),
    this.height = 140,
  });

  @override
  State<ServerMonitorPanel> createState() => _ServerMonitorPanelState();
}

class _ServerMonitorPanelState extends State<ServerMonitorPanel> {
  Timer? _timer;
  ServerSnapshot? _last;
  bool _isCollecting = false;

  @override
  void initState() {
    super.initState();
    // 立即采集一次，然后周期采集
    _collectNow();
    _timer = Timer.periodic(widget.interval, (_) => _collectNow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  Future<void> _collectNow() async {
    if (!mounted) return;
    if (_isCollecting) return; // 重入保护
    setState(() => _isCollecting = true);
    try {
      final snap = await widget.service.collect();
      if (!mounted) return;
      setState(() {
        _last = snap;
        _isCollecting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isCollecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final snap = _last;
    final history = widget.service.history;

    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: tc.card,
        border: Border(top: BorderSide(color: tc.border, width: 0.5)),
      ),
      child: Column(
        children: [
          // 顶部指标条：用户 / 开机时长 / 磁盘 / 内存总量 / 状态
          _buildStatusBar(tc, snap),
          // 折线图区：CPU / 内存 / 网络
          Expanded(
            child: history.length < 2
                ? _buildEmptyChart(tc, snap?.error)
                : _buildChartsRow(tc, history),
          ),
        ],
      ),
    );
  }

  /// 顶部状态条
  Widget _buildStatusBar(ThemeColors tc, ServerSnapshot? snap) {
    final err = snap?.error;
    final statusColor = err != null
        ? cDanger
        : _isCollecting
            ? cWarning
            : cSuccess;
    final statusText = err != null
        ? '采集失败'
        : _isCollecting
            ? '采集中…'
            : '已连接';

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: tc.surface,
        border: Border(bottom: BorderSide(color: tc.border.withValues(alpha: 0.3), width: 0.5)),
      ),
      child: Row(
        children: [
          // 状态指示灯
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(statusText, style: TextStyle(fontSize: fMicro, color: tc.textSub)),
          const SizedBox(width: 12),
          _buildStatusItem(tc, Icons.person_outline, '用户', '${snap?.userCount ?? 0}'),
          const SizedBox(width: 12),
          _buildStatusItem(tc, Icons.access_time, '开机', snap?.uptime ?? '-'),
          const SizedBox(width: 12),
          _buildStatusItem(tc, Icons.storage, '磁盘', '${(snap?.diskPercent ?? 0).toStringAsFixed(1)}%'),
          if (snap != null && snap.memTotalMB > 0) ...[
            const SizedBox(width: 12),
            _buildStatusItem(tc, Icons.memory, '内存', '${snap.memTotalMB.toStringAsFixed(0)}MB'),
          ],
          const Spacer(),
          Text(
            '最近更新: ${_last != null ? _formatTime(_last!.timestamp) : "--:--:--"}',
            style: TextStyle(fontSize: fMicro, color: tc.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusItem(ThemeColors tc, IconData icon, String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: tc.textMuted),
        const SizedBox(width: 3),
        Text('$label ', style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
        Text(value, style: TextStyle(fontSize: fMicro, color: tc.textSub, fontWeight: FontWeight.w500)),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  Widget _buildEmptyChart(ThemeColors tc, String? error) {
    return Center(
      child: Text(
        error != null ? '$error，重试中…' : '采集中…',
        style: TextStyle(color: tc.textMuted, fontSize: fMicro),
      ),
    );
  }

  /// 三栏折线图：CPU / 内存 / 网络
  Widget _buildChartsRow(ThemeColors tc, List<ServerSnapshot> history) {
    return Row(
      children: [
        Expanded(child: _buildMiniChart(
          tc: tc,
          label: 'CPU',
          unit: '%',
          color: cKleinBlue,
          data: history.map((s) => s.cpuPercent).toList(),
          max: 100,
          current: history.last.cpuPercent,
        )),
        VerticalDivider(width: 0.5, color: tc.border.withValues(alpha: 0.3)),
        Expanded(child: _buildMiniChart(
          tc: tc,
          label: '内存',
          unit: '%',
          color: cViolet,
          data: history.map((s) => s.memPercent).toList(),
          max: 100,
          current: history.last.memPercent,
          extra: history.last.memTotalMB > 0
              ? '${history.last.memUsedMB.toStringAsFixed(0)}/${history.last.memTotalMB.toStringAsFixed(0)}MB'
              : null,
        )),
        VerticalDivider(width: 0.5, color: tc.border.withValues(alpha: 0.3)),
        Expanded(child: _buildNetChart(tc, history)),
      ],
    );
  }

  /// 单个 mini 折线图
  Widget _buildMiniChart({
    required ThemeColors tc,
    required String label,
    required String unit,
    required Color color,
    required List<double> data,
    required double max,
    required double current,
    String? extra,
  }) {
    final spots = <FlSpot>[];
    for (int i = 0; i < data.length; i++) {
      spots.add(FlSpot(i.toDouble(), data[i].clamp(0, max)));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部：标签 + 当前值
          Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: fMicro, color: tc.textSub, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                '${current.toStringAsFixed(1)}$unit',
                style: TextStyle(
                  fontSize: fSmall,
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
            ],
          ),
          if (extra != null)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(extra, style: TextStyle(fontSize: 10, color: tc.textMuted, fontFamily: 'JetBrainsMono')),
              ),
            ),
          const SizedBox(height: 2),
          // 折线图
          Expanded(
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: max,
                minX: 0,
                maxX: (data.length - 1).toDouble().clamp(1, double.infinity),
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: color,
                    barWidth: 1.5,
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
            ),
          ),
        ],
      ),
    );
  }

  /// 网络上下行折线图（双线）
  Widget _buildNetChart(ThemeColors tc, List<ServerSnapshot> history) {
    final upData = history.map((s) => s.netUpKBps).toList();
    final downData = history.map((s) => s.netDownKBps).toList();
    final maxVal = [upData.fold<double>(0, (a, b) => a > b ? a : b),
                    downData.fold<double>(0, (a, b) => a > b ? a : b)].fold<double>(0, (a, b) => a > b ? a : b);
    final chartMax = (maxVal * 1.2).clamp(1.0, double.infinity);

    final upSpots = <FlSpot>[];
    final downSpots = <FlSpot>[];
    for (int i = 0; i < history.length; i++) {
      upSpots.add(FlSpot(i.toDouble(), upData[i]));
      downSpots.add(FlSpot(i.toDouble(), downData[i]));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: cLimeGreen, shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
              Text('↑${_formatRate(history.last.netUpKBps)}',
                  style: TextStyle(fontSize: fMicro, color: cLimeGreen, fontWeight: FontWeight.w600, fontFamily: 'JetBrainsMono')),
              const SizedBox(width: 8),
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: cHermesOrange, shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
              Text('↓${_formatRate(history.last.netDownKBps)}',
                  style: TextStyle(fontSize: fMicro, color: cHermesOrange, fontWeight: FontWeight.w600, fontFamily: 'JetBrainsMono')),
            ],
          ),
          const SizedBox(height: 2),
          Expanded(
            child: LineChart(
              LineChartData(
                minY: 0,
                maxY: chartMax,
                minX: 0,
                maxX: (history.length - 1).toDouble().clamp(1, double.infinity),
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: upSpots,
                    isCurved: true,
                    color: cLimeGreen,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                    isStrokeCapRound: true,
                  ),
                  LineChartBarData(
                    spots: downSpots,
                    isCurved: true,
                    color: cHermesOrange,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                    isStrokeCapRound: true,
                  ),
                ],
                lineTouchData: const LineTouchData(enabled: false),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatRate(double kb) {
    if (kb < 1) return '${(kb * 1024).toStringAsFixed(0)}B/s';
    if (kb < 1024) return '${kb.toStringAsFixed(1)}K/s';
    return '${(kb / 1024).toStringAsFixed(2)}M/s';
  }
}
