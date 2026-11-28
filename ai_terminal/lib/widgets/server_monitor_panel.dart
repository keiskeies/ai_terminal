import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../providers/agent_provider.dart';
import '../services/server_monitor_service.dart';
import 'monitor_detail_view.dart';

/// 服务器监控面板 — 单行紧凑布局（30px 高）
///
/// 左到右依次：[CPU图标] 38% [图表] | [内存条图标] 13.5GB/32GB |
/// [上传图标] 0.01 Mb/s | [下载图标] 0.01 Mb/s | [磁盘图标] 12% |
/// [icon] up 32 days | [icon] hostname
///
/// 所有指标只留图标+数值，省掉文字标签（hover/tap 浮层里有完整名称）。
/// 只有 CPU 带 mini 折线图，其余指标只展示当前值（趋势看浮层/历史即可）。
///
/// 鼠标 hover 或触屏 tap 弹出详细数据浮层，浮层左右两栏布局。
class ServerMonitorPanel extends ConsumerStatefulWidget {
  final ServerMonitorService service;
  final Duration interval;
  final double height;

  /// 顶栏开关撤下后（手机端），横幅自己是收起监控的唯一入口。
  /// 不传就是桌面端：那里顶栏常驻按钮还在，横幅里不该多一个 ×。
  final VoidCallback? onHide;

  /// [interval] 默认 10s：一次本地采集是同步起子进程跑完全部指标，实测
  /// macOS 单轮 real 2.2s（其中 top 占 sys 1.34s ≈ 一个核的 27%@5s），
  /// Windows 还要冷启 powershell + 8 次 Get-CimInstance。监控条不是仪表盘，
  /// 10s 足够，直接把采集进程开销砍半。
  const ServerMonitorPanel({
    super.key,
    required this.service,
    this.interval = const Duration(seconds: 10),
    this.height = 30,
    this.onHide,
  });

  @override
  ConsumerState<ServerMonitorPanel> createState() => _ServerMonitorPanelState();
}

class _ServerMonitorPanelState extends ConsumerState<ServerMonitorPanel> {
  Timer? _timer;
  ServerSnapshot? _last;
  bool _isCollecting = false;
  int _consecutiveFailures = 0; // 连续失败次数，>=2 时显示失败状态
  int _tick = 0;
  DateTime _lastCollectAt = DateTime.fromMillisecondsSinceEpoch(0);

  // 浮层控制
  OverlayEntry? _overlayEntry;
  String? _activeMetric; // 当前展示浮层的指标名
  Offset? _mousePosition; // 鼠标全局位置，用于浮层定位

  static const double _overlayMouseGap = 6;

  /// 详情窗是否打开：打开期间面板不轮询，采集交给详情窗（见 _onTick）
  bool _detailDialogOpen = false;

  /// hover 位移阈值（px）：小于该位移不重建浮层
  static const double _overlayMoveEpsilon = 4;

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
    // 首帧后再采集：initState 里不能读 TickerMode；恢复多 tab 时避免
    // 后台 tab 的面板同时触发一轮 PowerShell/WMI 采集
    WidgetsBinding.instance.addPostFrameCallback((_) => _collectNow());
    _timer = Timer.periodic(widget.interval, (_) => _onTick());
  }

  void _onTick() {
    _tick++;
    // agent 运行期间降频到 1/3（默认 30s 一次）：本地 Windows 采集要起
    // PowerShell + 十几个 Get-CimInstance（WMI 很重），不该和正在执行的
    // 任务抢 CPU
    if (ref.read(agentProvider).isRunning && _tick % 3 != 0) return;
    _collectNow();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 切回本 tab（TickerMode 重新启用）时若数据已过期，立即补采一次
    if (TickerMode.valuesOf(context).enabled &&
        DateTime.now().difference(_lastCollectAt) > widget.interval) {
      _collectNow();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _hideOverlay();
    // 只停止采集，不清历史：历史归 ServerMonitorService 所有，面板在切 tab
    // 时会被重建，但服务是 per-tab 常驻的；在这里 reset 会把用户刚看到的数据
    // 清空，切回来从 0 开始。清空只发生在关闭 tab 或重连更换 executor 时。
    super.dispose();
  }

  Future<void> _collectNow() async {
    if (!mounted) return;
    // 详情窗打开期间由详情窗自己按 interval 轮询，面板再采等于把本地采集
    // （PowerShell + 一堆 Get-CimInstance/WMI）频率翻倍。闸门放这里而不是
    // _onTick：didChangeDependencies 的补采路径同样要挡
    if (_detailDialogOpen) return;
    // 后台 tab（Offstage + TickerMode disabled）不采集：Timer.periodic 不受
    // TickerMode 影响，必须显式跳过，否则多 tab 会叠加采集进程
    if (!TickerMode.valuesOf(context).enabled) return;
    if (_isCollecting) return;
    _isCollecting = true;
    _lastCollectAt = DateTime.now();
    try {
      final snap = await widget.service.collect();
      if (!mounted) return;
      // collect() 采集失败时不抛异常，而是返回带 error 的快照（见
      // ServerMonitorService.parseLinuxOutput 一路的返回）。只数 catch 里的
      // 分支等于永远绿点——曾经就是这样把「折线图永远是 …」瞒过去的。
      final failed = snap.error != null;
      setState(() {
        _last = snap;
        _consecutiveFailures = failed ? _consecutiveFailures + 1 : 0;
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

  // ==================== 浮层控制 ====================

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

  /// 点击指标 = 打开详情窗（网络/磁盘），其余指标沿用浮层
  ///
  /// 浮层是纯 hover 产物：鼠标一离开芯片 onExit 就销毁它，浮层里的按钮根本
  /// 点不到。所以「看全部」必须挂在芯片的 tap 上，而不是浮层内部。
  void _onMetricTap(String metric, Offset position) async {
    final snap = _last;
    final detailKind = monitorDetailKind(metric);
    if (snap != null && snap.error == null && detailKind != null) {
      _hideOverlay();
      _detailDialogOpen = true;
      await showMonitorDetailDialog(
        context,
        service: widget.service,
        metric: metric,
        interval: widget.interval,
      );
      if (!mounted) return;
      _detailDialogOpen = false;
      // 面板停轮询期间数据可能已过期，开窗期间看到的最新值先同步回快照
      _collectNow();
      return;
    }
    _showOverlay(metric, position);
  }

  /// 轻量级位置更新：只更新鼠标位置并重建浮层
  /// 不经过条件检查，不受 widget tree 重建影响
  ///
  /// 位移不足 [_overlayMoveEpsilon] 直接吞掉：onHover 是每个鼠标位移事件
  /// 都触发，磁盘浮层带 N 行分区 + 进度条 LayoutBuilder，鼠标快速划过时
  /// 按事件频率整层重建不值。
  void _updateOverlayPosition(Offset mousePosition) {
    final last = _mousePosition;
    if (last != null &&
        (mousePosition - last).distanceSquared <
            _overlayMoveEpsilon * _overlayMoveEpsilon) {
      return;
    }
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
        ? tc.error
        : hasData
            ? tc.ok
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
        border: Border(top: BorderSide(color: tc.hairline)),
      ),
      child: Row(
        children: [
          Expanded(
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
                      // 芯片=CPU；旧的 bolt 是闪电，表达的是电源而非处理器
                      icon: Icons.memory,
                      label: 'CPU',
                      showLabel: false,
                      // 无读数时显示 - 而不是 0.0%：手机上取不到 CPU 是常态
                      // （见 ServerMonitorService._collectAndroidLocal），
                      // 0% 会被读成「很空闲」。
                      value: snap == null || !snap.cpuAvailable
                          ? '-'
                          : '${snap.cpuPercent.toStringAsFixed(1)}%',
                      color: staleColor(monitorColorByPercent(
                          snap?.cpuPercent ?? 0, tc,
                          normal: tc.brand)),
                      // 无读数的帧不进折线：补一个 0 会在趋势上画出一道假谷底
                      chartData: history
                          .where((s) => s.cpuAvailable)
                          .map((s) => s.cpuPercent)
                          .toList(),
                      chartMax: 100,
                    ),
                    _divider(tc),
                    // 内存/上传/下载只展示当前值：mini 图各自要建 LineChart + 起
                    // 150ms 补间，整页重建时四个图一起重放动画，但 60px 宽的趋势
                    // 条实际没人读，只留 CPU 一个
                    _buildMetricChip(
                      metric: 'mem',
                      icon: Icons.memory,
                      // 内存条画成条形+金手指（梳齿），不是方块芯片
                      memoryStick: true,
                      label: l10n.monitorMemory,
                      showLabel: false,
                      value: snap != null && snap.memTotalMB > 0
                          ? '${fmtFromMB(snap.memUsedMB)}/${fmtFromMB(snap.memTotalMB)}'
                          : '-',
                      color: staleColor(
                          monitorColorByPercent(snap?.memPercent ?? 0, tc)),
                      valueColor: staleColor(
                          monitorColorByPercent(snap?.memPercent ?? 0, tc)),
                      valueMaxWidth: 110,
                    ),
                    _divider(tc),
                    _buildMetricChip(
                      metric: 'netUp',
                      icon: Icons.arrow_upward,
                      label: l10n.monitorUpload,
                      showLabel: false,
                      value: fmtRate(snap?.netUpKBps ?? 0),
                      color: staleColor(tc.brand),
                      valueColor: staleColor(tc.brand),
                      valueMaxWidth: 90,
                    ),
                    _divider(tc),
                    _buildMetricChip(
                      metric: 'netDown',
                      icon: Icons.arrow_downward,
                      label: l10n.monitorDownload,
                      showLabel: false,
                      value: fmtRate(snap?.netDownKBps ?? 0),
                      color: staleColor(tc.ok),
                      valueColor: staleColor(tc.ok),
                      valueMaxWidth: 90,
                    ),
                    _divider(tc),
                    _buildMetricChip(
                      metric: 'disk',
                      icon: Icons.storage,
                      label: l10n.monitorDisk,
                      showLabel: false,
                      value: '${(snap?.diskPercent ?? 0).toStringAsFixed(1)}%',
                      color: staleColor(monitorColorByPercent(
                          snap?.diskPercent ?? 0, tc,
                          normal: tc.warn)),
                    ),
                    _divider(tc),
                    _buildMetricChip(
                      metric: 'uptime',
                      icon: Icons.access_time,
                      label: l10n.monitorUptime,
                      showLabel: false,
                      value: snap?.uptime ?? '-',
                      color: isStale ? tc.textMuted : tc.textSub,
                      valueMaxWidth: 100,
                    ),
                    _divider(tc),
                    _buildMetricChip(
                      metric: 'user',
                      icon: Icons.person_outline,
                      label: l10n.monitorUser,
                      showLabel: false,
                      value:
                          (snap?.hostname.isNotEmpty ?? false) ? snap!.hostname : '-',
                      color: isStale ? tc.textMuted : tc.textSub,
                      valueMaxWidth: 120,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 收起：顶栏开关撤下后（手机端），这是关掉横幅的唯一入口。
          // 桌面端不传 onHide，横幅里不会出现这个 ×。
          if (widget.onHide != null)
            Semantics(
              button: true,
              label: l10n.ut_c56382e3ee,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onHide,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child:
                      Icon(Icons.close_rounded, size: 14, color: tc.textMuted),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _divider(ThemeColors tc) {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: tc.hairline,
    );
  }

  /// 不带图表的指标项（内存/上下行/用户/开机/磁盘）
  ///
  /// [color] 是图标色；[valueColor] 单独控制数值颜色（默认跟随 label 的
  /// textSub，用于磁盘/开机这类"数值本身不需要告警色"的项）。
  /// [showLabel] 为 false 时只留图标+数值；[memoryStick] 用自绘内存条图标。
  Widget _buildMetricChip({
    required String metric,
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    bool showLabel = true,
    bool memoryStick = false,
    Color? valueColor,
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
      onTap: _onMetricTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (memoryStick)
              _RamStickIcon(color: color)
            else
              Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
            if (showLabel)
              Text('$label ',
                  style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: valueMaxWidth ?? 80),
              child: Text(
                value,
                style: TextStyle(
                  fontSize: fMicro,
                  color: valueColor ?? tc.textSub,
                  fontWeight:
                      valueColor != null ? FontWeight.w600 : FontWeight.w500,
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: kMonoFontFallback,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 带图表的指标项（当前只有 CPU）
  /// hover 只在图表区域触发，避免在图标/数值区域频繁切换
  Widget _buildMetricChipWithChart({
    required String metric,
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required List<double> chartData,
    bool showLabel = true,
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
          if (showLabel)
            Text('$label ',
                style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
          Text(
            value,
            style: TextStyle(
              fontSize: fMicro,
              color: color,
              fontWeight: FontWeight.w600,
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: kMonoFontFallback,
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
            onTap: _onMetricTap,
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
        child: Text('…',
            style: TextStyle(
                fontSize: fMini, color: color.withValues(alpha: 0.5))),
      );
    }
    // 降采样：60px 宽最多 60 个点，数据多时按桶取最大最小值保留趋势
    const targetPoints = 60;
    final sampled =
        data.length <= targetPoints ? data : _downsample(data, targetPoints);

    final spots = <FlSpot>[];
    for (int i = 0; i < sampled.length; i++) {
      spots.add(
          FlSpot(i.toDouble(), sampled[i].clamp(0, max ?? double.infinity)));
    }
    final actualMax =
        max ?? sampled.fold<double>(0, (a, b) => a > b ? a : b) * 1.2;

    // duration: Duration.zero —— fl_chart 是 ImplicitlyAnimatedWidget，默认
    // 150ms 补间，而 LineChartData 的相等性比较落在 FlSpot 列表上，每次
    // build 都是全新实例 → 判定"变了" → 每来一条聊天消息（整页重建）就给
    // 这根 60px 折线重放一轮动画。
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
      // fl_chart 是 ImplicitlyAnimatedWidget，默认 150ms 补间；而 LineChartData
      // 的相等性比较落在 FlSpot 列表上，每次 build 都是全新实例 → 判定"变了"
      // → 每来一条聊天消息（整页重建）就给这根 60px 折线重放一轮动画。
      duration: Duration.zero,
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
                Divider(height: 6, color: tc.hairline),
                // 明细区用 Flexible 吃剩余高度：固定块（标题/汇总/表头）先占位，
                // 若不收缩明细，弹层高度不足时表格会被 RenderFlex 裁掉
                // （磁盘分区"挤到下面"就是这么来的）
                Flexible(
                  child: SingleChildScrollView(
                    child: _buildOverlayBody(metric, tc, snap, rows),
                  ),
                ),
                // 提示固定在滚动区之外：浮层是纯 hover 产物（鼠标离开芯片即销毁，
                // onExit 抢在任何点击进入之前），滚出可视区的东西等于不存在，
                // 入口提示绝不能放进可滚内容里。且只给真有详情窗的指标（网络/磁盘），
                // CPU/内存等点击不会开窗，挂提示就是死指引
                if (monitorDetailKind(metric) != null) _overlayDetailHint(tc),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlayBody(
    String metric,
    ThemeColors tc,
    ServerSnapshot snap,
    List<(String, String)> rows,
  ) {
    // 网络/磁盘 → 表格布局；系统信息 → 单栏（长文本）；其他 → 两栏
    if (metric == 'netUp' || metric == 'netDown')
      return _buildNetOverlayContent(tc, snap);
    if (metric == 'disk') return _buildDiskOverlayContent(tc, snap);
    if (metric == 'uptime') return _buildSingleColumnRows(tc, rows);
    return twoColumnRows(tc, rows);
  }

  /// 浮层是纯 hover 产物（鼠标离开芯片即销毁），里面的滚动和按钮都点不到，
  /// 所以浮层只做速览：真实设备优先、虚拟设备折叠成一行，完整列表走详情窗。
  Widget _buildNetOverlayContent(ThemeColors tc, ServerSnapshot s) {
    final l10n = AppLocalizations.of(context)!;
    final summary = [
      (l10n.monitorNetTotalDown, fmtRate(s.netDownKBps)),
      (l10n.monitorNetTotalUp, fmtRate(s.netUpKBps)),
      (l10n.monitorNetTotalDownloaded, fmtBytes(s.netTotalDownBytes)),
      (l10n.monitorNetTotalUploaded, fmtBytes(s.netTotalUpBytes)),
      (l10n.monitorNetInterfaceCount, '${s.interfaces.length}'),
    ];

    final sorted = sortInterfacesByTraffic(s.interfaces);
    final real = sorted.where((i) => !isVirtualNetInterface(i.name)).toList();
    final virtualCount = sorted.length - real.length;

    Widget row(NetInterface iface) {
      final errs = iface.rxErrors + iface.txErrors;
      final drops = iface.rxDropped + iface.txDropped;
      final hasIssue = errs > 0 || drops > 0;
      return netTableRow(
        tc,
        name: iface.name,
        traffic: '${fmtBytes(iface.rxBytes)} / ${fmtBytes(iface.txBytes)}',
        rate: '${fmtRate(iface.downKBps)} / ${fmtRate(iface.upKBps)}',
        issues: hasIssue ? '$errs/$drops' : '-',
        issuesColor: hasIssue ? (errs > 0 ? tc.error : tc.warn) : tc.textMuted,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        twoColumnRows(tc, summary),
        const SizedBox(height: 8),
        Text(
          l10n.monitorNetInterfaceDetail,
          style: TextStyle(
              fontSize: fMicro, color: tc.textSub, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        netTableRow(
          tc,
          name: l10n.monitorNetColInterface,
          traffic: l10n.monitorNetColTraffic,
          rate: l10n.monitorNetColRate,
          issues: l10n.monitorNetColIssues,
          isHeader: true,
        ),
        ...real.take(_overlayMaxRows).map(row),
        if (real.length > _overlayMaxRows || virtualCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              [
                if (virtualCount > 0) l10n.monitorNetVirtualGroup(virtualCount),
                if (real.length > _overlayMaxRows)
                  '+${real.length - _overlayMaxRows}',
              ].join(' · '),
              style: TextStyle(fontSize: fMicro, color: tc.textMuted),
            ),
          ),
      ],
    );
  }

  /// 浮层底部提示：浮层本身 hover 即散，鼠标进不去，所以「看全部」的入口是
  /// 芯片的点击 —— 这里只做指路，不能画成按钮（画成按钮就等于画了个点不到的东西）
  Widget _overlayDetailHint(ThemeColors tc) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(Icons.touch_app_outlined, size: 11, color: tc.textMuted),
          const SizedBox(width: 4),
          Text(l10n.monitorOpenDetail,
              style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
        ],
      ),
    );
  }

  Widget _buildDiskOverlayContent(ThemeColors tc, ServerSnapshot s) {
    final l10n = AppLocalizations.of(context)!;
    final partitions = s.diskPartitions;
    final totalDisk = partitions.fold<double>(0, (sum, p) => sum + p.totalGB);
    final usedDisk = partitions.fold<double>(0, (sum, p) => sum + p.usedGB);
    final overallPercent = totalDisk > 0 ? (usedDisk / totalDisk * 100) : 0.0;

    final summary = [
      (l10n.monitorDiskTotal, '${totalDisk.toStringAsFixed(1)} GB'),
      (l10n.monitorDiskUsed, '${usedDisk.toStringAsFixed(1)} GB'),
      (
        l10n.monitorDiskAvailable,
        '${(totalDisk - usedDisk).toStringAsFixed(1)} GB'
      ),
      (l10n.monitorDiskOverallUsage, '${overallPercent.toStringAsFixed(1)}%'),
      (l10n.monitorDiskPartitionCount, '${partitions.length}'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        twoColumnRows(tc, summary),
        const SizedBox(height: 8),
        usageBar(tc, overallPercent, monitorColorByPercent(overallPercent, tc)),
        const SizedBox(height: 10),
        Text(
          l10n.monitorDiskPartitionDetail,
          style: TextStyle(
              fontSize: fMicro, color: tc.textSub, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        diskTableRow(
          tc,
          mount: l10n.monitorDiskColMount,
          used: l10n.monitorDiskColUsage,
          percent: l10n.monitorDiskColPercent,
          isHeader: true,
        ),
        ...partitions.take(_overlayMaxRows).map(
              (p) => diskTableRow(
                tc,
                mount: p.mountPoint,
                used:
                    '${fmtFromMB(p.usedGB * 1024)} / ${fmtFromMB(p.totalGB * 1024)}',
                percent: '${p.usePercent.toStringAsFixed(1)}%',
                usePercent: p.usePercent,
              ),
            ),
        if (partitions.length > _overlayMaxRows)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+${partitions.length - _overlayMaxRows}',
              style: TextStyle(fontSize: fMicro, color: tc.textMuted),
            ),
          ),
      ],
    );
  }

  /// 浮层速览的最大行数
  static const int _overlayMaxRows = 6;

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

  /// 返回浮层标题 + 数据行（label, value）
  (String, List<(String, String)>) _getOverlayData(
      String metric, ServerSnapshot s) {
    final l10n = AppLocalizations.of(context)!;
    switch (metric) {
      case 'cpu':
        // 手机上只有本应用进程的 CPU，整机的读不到（SELinux 拒 /proc/stat）。
        // 口径不同的两个数不能共用一个不带限定的标签，否则进程占用会被读成
        // 整机占用。取不到的行一律 -。
        String pct(double v) => s.cpuAvailable ? '${v.toStringAsFixed(1)}%' : '-';
        final scope = s.cpuIsProcessScoped ? ' · ${l10n.monitorCpuScopeProcess}' : '';
        return (
          '${l10n.monitorCpuDetail}$scope',
          [
            (l10n.monitorCpuTotalUsage, pct(s.cpuPercent)),
            (l10n.monitorCpuUser, pct(s.cpuUser)),
            (l10n.monitorCpuSystem, pct(s.cpuSystem)),
            (l10n.monitorCpuIdle, pct(s.cpuIdle)),
            (l10n.monitorLoad1, s.cpuAvailable ? s.loadAvg1.toStringAsFixed(2) : '-'),
            (l10n.monitorLoad5, s.cpuAvailable ? s.loadAvg5.toStringAsFixed(2) : '-'),
            (l10n.monitorLoad15, s.cpuAvailable ? s.loadAvg15.toStringAsFixed(2) : '-'),
            (l10n.monitorProcessCount, s.processCount > 0 ? '${s.processCount}' : '-'),
          ],
        );
      case 'mem':
        // 采集失败时 memTotalMB 为 0，显示 "-" 而不是伪造的 0 MB
        final hasMem = s.memTotalMB > 0;
        String memValue(double mb) => hasMem ? fmtMB(mb) : '-';
        return (
          l10n.monitorMemoryDetail,
          [
            (l10n.monitorMemoryTotal, memValue(s.memTotalMB)),
            (l10n.monitorDiskUsed, memValue(s.memUsedMB)),
            (l10n.monitorDiskAvailable, memValue(s.memAvailableMB)),
            (l10n.monitorMemoryFree, memValue(s.memFreeMB)),
            (l10n.monitorMemoryCached, memValue(s.memCachedMB)),
            (l10n.monitorMemoryBuffers, memValue(s.memBuffersMB)),
            (
              l10n.monitorMemoryUsage,
              hasMem ? '${s.memPercent.toStringAsFixed(1)}%' : '-'
            ),
            (l10n.monitorSwapTotal, memValue(s.swapTotalMB)),
            (l10n.monitorSwapUsed, memValue(s.swapUsedMB)),
          ],
        );
      case 'disk':
        return (
          l10n.monitorDiskDetail,
          [
            (l10n.monitorDiskTotal2, '${s.diskTotalGB.toStringAsFixed(1)} GB'),
            (l10n.monitorDiskUsed, '${s.diskUsedGB.toStringAsFixed(1)} GB'),
            (
              l10n.monitorDiskAvailable,
              '${s.diskFreeGB.toStringAsFixed(1)} GB'
            ),
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
            (
              l10n.monitorKernelVersion,
              s.kernelVersion.isEmpty ? '-' : s.kernelVersion
            ),
            (l10n.monitorLoad1, s.loadAvg1.toStringAsFixed(2)),
            (l10n.monitorLoad5, s.loadAvg5.toStringAsFixed(2)),
            (l10n.monitorLoad15, s.loadAvg15.toStringAsFixed(2)),
          ],
        );
      default:
        return ('-', const []);
    }
  }
}

/// 内存条图标：横向长板 + 下方金手指（梳齿），与 Icon(size: 11) 同尺寸。
/// Material 的 Icons.memory 是方块芯片，用来表示内存会跟 CPU 混淆。
class _RamStickIcon extends StatelessWidget {
  final Color color;

  const _RamStickIcon({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 11,
      height: 11,
      child: CustomPaint(painter: _RamStickPainter(color: color)),
    );
  }
}

class _RamStickPainter extends CustomPainter {
  final Color color;

  _RamStickPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;

    // PCB 板体
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0.5, 1.0, size.width - 1, 4.0),
        const Radius.circular(1),
      ),
      paint,
    );
    // 金手指：等距竖线，形似梳齿
    const teeth = 5;
    for (var i = 0; i < teeth; i++) {
      final x = 1.5 + i * (size.width - 3) / (teeth - 1);
      // 金手指插进板体半截，外面只露一小截，别拖成流苏
      canvas.drawLine(Offset(x, 2.5), Offset(x, 8.0), paint);
    }
  }

  @override
  bool shouldRepaint(_RamStickPainter oldDelegate) =>
      oldDelegate.color != color;
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
  final void Function(String metric, Offset position) onTap;
  final Widget child;

  const _MetricHoverWrapper({
    required this.metric,
    required this.activeMetric,
    required this.color,
    required this.onShow,
    required this.onHide,
    required this.onHoverMove,
    required this.onTap,
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
        // onTapUp 而不是 onTapDown：按下后拖出再松手（按住拖动横向滚动监控栏）
        // 不应触发开窗/切浮层
        onTapUp: (details) =>
            widget.onTap(widget.metric, details.globalPosition),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          decoration: BoxDecoration(
            color: isActive
                ? widget.color.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(rXSmall),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
