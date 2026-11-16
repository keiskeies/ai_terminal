import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:go_router/go_router.dart';
import 'package:xterm/xterm.dart';
import '../core/builtin_runbook_i18n.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/settings_catalog.dart';
import '../core/terminal_keybindings.dart';
import '../core/terminal_themes.dart';
import '../core/ui_text.dart';
import '../widgets/smart_table.dart';
import '../core/l10n_holder.dart';
import '../core/route_observer.dart';
import '../l10n/app_localizations.dart';
import '../widgets/sftp_panel.dart';
import '../widgets/command_palette.dart';
import '../widgets/nav_drawer.dart';
import '../widgets/ai_prompt_input.dart';
import '../widgets/model_picker_panel.dart';
import '../widgets/agent_goal_banner.dart';
import '../models/agent_goal.dart';
import '../models/agent_permission_mode.dart';
import '../widgets/session_history_dialog.dart';
import '../widgets/command_history_panel.dart';
import '../widgets/agent_log_dialog.dart';
import '../widgets/agent_command_block.dart';
import '../widgets/agent_event_cards.dart';
import '../widgets/collapsible_message_text.dart';
import '../widgets/operation_sheet.dart';
import '../widgets/plan_panel.dart';
import '../widgets/interrupted_turn_banner.dart';
import '../widgets/reconnecting_banner.dart';
import '../widgets/local_dir_auth_dialog.dart';
import '../widgets/tab_item_widget.dart';
import '../utils/interrupted_turn_detector.dart';
import '../utils/command_tracker.dart';
import '../utils/reconnect_policy.dart';
import '../utils/terminal_blocks.dart';
import '../utils/terminal_input_line.dart';
import '../utils/streaming_markdown.dart';
import '../utils/slash_command.dart';
import '../utils/agent_ui_text.dart';
import '../utils/conversation_export.dart';
import '../utils/goal_continuation.dart';
import '../services/agent_tracer.dart';
import '../services/agent_logger.dart';
import 'package:flutter/services.dart';
import '../services/daos.dart';
import '../models/runbook.dart';
import '../providers/app_providers.dart';
import '../providers/runbook_provider.dart';
import '../providers/terminal_provider.dart' as tp;
import '../providers/chat_provider.dart';
import '../providers/agent_provider.dart';
import '../models/ai_model_config.dart';
import '../models/ai_endpoint.dart';
import '../services/ai_model_selection_service.dart';
import '../models/host_config.dart';
import '../models/agent_event.dart';
import '../models/agent_model.dart';
import '../models/operation_report.dart';
import '../models/plan_step.dart';
import '../models/command_snippet.dart';
import '../services/ai_service.dart';
import '../services/command_executor.dart';
import '../services/server_monitor_service.dart';
import '../services/change_record_service.dart';
import '../services/local_file_policy.dart';
import '../services/session_log_service.dart';
import '../services/port_forward_service.dart';
import '../widgets/port_forward_dialog.dart';
import '../models/change_record.dart';
import '../widgets/server_monitor_panel.dart';
import '../widgets/terminal_view.dart' as term_widget;
import '../widgets/terminal_context_menu.dart';
import '../widgets/terminal_appearance_panel.dart';
import '../utils/terminal_text_actions.dart';
import '../utils/terminal_panes.dart';
import '../services/pane_session_service.dart';
import '../core/app_toast.dart';


enum _AiPanelPosition { bottom, right, overlay }

/// 面板方向与比例的存盘约定。此前两者都不落盘（每次启动都回到默认值），这里补齐。
///
/// 方向只在桌面显式切换时写：移动端每帧按屏幕方向覆盖，存了也会在竖屏被改回
/// bottom，写它只会让存盘值和实际显示不一致。
void saveAiPanelLayout({
  required bool isMobile,
  required bool savePosition,
  required String position,
  required double ratio,
}) {
  if (savePosition && !isMobile) {
    SettingsDao.set('aiPanelPosition', position);
  }
  SettingsDao.set('aiPanelRatio', ratio);
}

/// 面板方向与比例的读盘解析，与 [saveAiPanelLayout] 成对。
///
/// 规则：只有显式存过且合法的才覆盖默认值；比例一律夹回合法区间。
/// 抽成纯函数是因为"存进去"和"读出来"是两条独立的路径，只测前者会漏掉
/// 老用户被新默认值翻转、以及脏数据把面板拉成 0 宽这两种失效。
({String position, double ratio}) resolveAiPanelLayout({
  required Object? storedPosition,
  required Object? storedRatio,
  required String defaultPosition,
  required double defaultRatio,
  required double minRatio,
  required double maxRatio,
}) {
  final position = (storedPosition == 'bottom' ||
          storedPosition == 'right' ||
          storedPosition == 'overlay')
      ? storedPosition as String
      : defaultPosition;
  var ratio = defaultRatio;
  if (storedRatio is num) {
    ratio = storedRatio.toDouble();
    if (ratio < minRatio) ratio = minRatio;
    if (ratio > maxRatio) ratio = maxRatio;
  }
  return (position: position, ratio: ratio);
}

/// 80 列最小终端宽度估算：字号 × 经验字宽比 × 80，再加终端内边距与滚动条。
///
/// 拿不到运行时字号度量，用保守上界的字宽比 —— 宁可让面板宽一点，
/// 也不能让 vim/htop 之类的满屏程序被挤到 80 列以下。
double minTerminalWidthForFontSize(double fontSize) =>
    (fontSize * 0.62 * 80 + 24).toDouble();

/// 计算 AI 面板尺寸：先按 [ratio] 取值，再执行 80 列保护 ——
/// 终端一侧剩余宽度不足 80 列时，面板必须缩到 `totalW - 80列宽`。
/// 纯函数，便于单测覆盖「窗口太窄时面板封顶」这条不变量。
double aiPanelSizeFor({
  required double totalExtent,
  required double ratio,
  required bool enforce80Cols,
  required double fontSize,
  required double minRatio,
  required double maxRatio,
}) {
  var size = (totalExtent * ratio).clamp(0.0, totalExtent * maxRatio).toDouble();
  if (enforce80Cols && totalExtent > 0) {
    final maxPanel = totalExtent - minTerminalWidthForFontSize(fontSize);
    if (maxPanel <= 0) {
      // 窗口本身放不下「80 列 + 最小面板」：宽度优先给终端，面板留最小可用值。
      size = (totalExtent * minRatio).toDouble();
    } else {
      final minPanel = totalExtent * minRatio;
      size = size
          .clamp(minPanel < maxPanel ? minPanel : maxPanel, maxPanel)
          .toDouble();
    }
  }
  return size;
}

class TerminalPage extends ConsumerStatefulWidget {
  final String? hostId; // null = 本地终端

  const TerminalPage({super.key, this.hostId});

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> with RouteAware {
  Terminal? _terminal;

  /// 顶栏「外观」浮层：主题模式 + 配色 + 字号。都要边切边看，所以是浮层不是页面。
  final _appearanceMenu = MenuController();

  /// initState 时捕获的 Agent notifier。dispose 里不能再读 ref：
  /// 那时 element 已 disposed，ref.read 会抛 StateError 并中断后续资源回收。
  AgentNotifier? _agentNotifier;

  /// 尚无任何标签可承载时的提示（例如路由里的 hostId 已不存在）。
  /// 连接阶段本身记在 TerminalTab.status 上，页面不再持有副本。
  String? _placeholderError;
  // ====== Per-tab 本地状态 ======
  String? _currentTabId;
  final Map<String, String?> _tabExecutingCommand = {};
  final Map<String, Set<String>> _tabExecutedCommands = {};
  final Map<String, String?> _tabPendingConfirm = {}; // 等待内联确认的危险命令
  final Map<String, Terminal> _tabTerminals = {}; // 每个 tab 独立的 Terminal 实例
  final Map<String, String> _tabAiInputText = {}; // 每个 tab 独立的 AI 输入框文字

  /// 已成功回滚的变更 id（用于操作单即时反馈）
  final Set<String> _rolledBackChangeIds = {};
  bool _rollbackBusy = false;

  /// 正在重连的主机名称（非 null 时显示"连接恢复中"横幅）
  String? _reconnectingHostLabel;

  /// 空闲断线自动重连（docs §5）：每个 tab 的已尝试次数与待执行定时器。
  /// 任务运行中的 tab 不自动重连（isRunningFor 判定），断线即任务 failed。
  final Map<String, int> _autoReconnectAttempts = {};
  final Map<String, Timer> _autoReconnectTimers = {};
  // tab 对象在 provider 里原地复用，prev/next state 拿到的是同一实例，
  // 状态迁移必须自己记上一帧的值
  final Map<String, tp.TabStatus> _lastTabStatus = {};

  /// 会话日志（设置开启时对新开标签生效）：每 tab 一个录制器
  bool _sessionLogEnabled = false;
  final Map<String, SessionRecorder> _sessionRecorders = {};

  /// 端口转发：每 tab 一个管理器，关标签时 dispose
  final Map<String, PortForwardService> _portForwardServices = {};

  // AI 面板默认布局（从设置加载，新 tab 继承；每个 tab 可在会话内独立覆盖）
  _AiPanelPosition _defaultAiPanelPosition = _AiPanelPosition.right;
  // 设计稿 `.shell-body{grid-template-columns:minmax(0,1fr) 320px}` 的 AI 列宽
  // 是 **固定 320 逻辑 px**，不随窗口缩放。之前存的是比例：1280 窗口下 0.25
  // 正好 320，但窗口一放大（或老库里存着 0.4）面板就跟着涨到 500 多，终端被
  // 挤成一条，画面和 mockup 完全两回事。
  // 所以默认值改成 null = 未自定义 → 按 320px 渲染；只有用户真的拖过分隔条
  // 才写入比例（键 aiPanelRatioV2），此后按比例跟随窗口。
  static const double _kAiPanelDefaultWidth = 320;
  // 真正参与布局的是像素宽度（null = 用 320）。比例只在渲染时按容器换算，
  // 不再持久化 —— 旧键 aiPanelRatioV2 里 0.4 这类历史值正是把面板撑大的原因。
  double? _defaultAiPanelWidth;
  bool _defaultAiPanelVisible = false;
  // 设计稿「宽度与下限」：辅助面板不低于 240px。1280px 窗口下 0.19 ≈ 243px，
  // 比原来的 0.15（≈192px，胶囊和命令行都会换行）更贴近设计下限。
  static const double _minPanelRatio = 0.19;
  static const double _maxPanelRatio = 0.7;

  // 每个 tab 独立的 AI 面板可见性 / 方位 / 宽度比例
  final Map<String, bool> _tabAiPanelVisible = {};
  final Map<String, _AiPanelPosition> _tabAiPanelPosition = {};
  final Map<String, double?> _tabAiPanelWidth = {};

  bool _aiPanelVisibleFor(String? tabId) => tabId == null
      ? _defaultAiPanelVisible
      : (_tabAiPanelVisible[tabId] ?? _defaultAiPanelVisible);
  _AiPanelPosition _aiPanelPositionFor(String? tabId) => tabId == null
      ? _defaultAiPanelPosition
      : (_tabAiPanelPosition[tabId] ?? _defaultAiPanelPosition);
  double? _aiPanelWidthFor(String? tabId) => tabId == null
      ? _defaultAiPanelWidth
      : (_tabAiPanelWidth[tabId] ?? _defaultAiPanelWidth);

  void _setAiPanelVisible(String? tabId, bool visible) {
    if (tabId != null) _tabAiPanelVisible[tabId] = visible;
    _defaultAiPanelVisible = visible;
    SettingsDao.set('aiPanelVisible', visible);
  }

  void _setAiPanelPosition(String? tabId, _AiPanelPosition position) {
    if (tabId != null) _tabAiPanelPosition[tabId] = position;
    _defaultAiPanelPosition = position;
    SettingsDao.set('aiPanelPosition', position.name);
  }

  // 专注模式（per-tab）：终端独占。只压制可见性，不销毁 AI/SFTP/监控的
  // 各自状态 —— 退出专注模式后一切按原样回来。
  final Map<String, bool> _tabFocusMode = {};
  bool _isFocusModeFor(String? tabId) =>
      tabId != null && (_tabFocusMode[tabId] ?? false);

  void _toggleFocusMode() {
    final tabId = _currentTabId;
    if (tabId == null) return;
    setState(() => _tabFocusMode[tabId] = !_isFocusModeFor(tabId));
  }

  /// AI 面板的实际可见性：专注模式压制一切浮层。
  bool _effectiveAiVisible(String? tabId) =>
      !_isFocusModeFor(tabId) && _aiPanelVisibleFor(tabId);

  /// 新 tab 创建时把当前默认布局快照到自己的 map。
  /// 必须快照而不是一直读默认值：否则另一个 tab 改布局时，已有的 tab 会跟着变。
  void _initTabPanelState(tp.TerminalTab tab) {
    _tabAiPanelVisible.putIfAbsent(tab.id, () => _defaultAiPanelVisible);
    _tabAiPanelPosition.putIfAbsent(tab.id, () => _defaultAiPanelPosition);
    _tabAiPanelWidth.putIfAbsent(tab.id, () => _defaultAiPanelWidth);
    final hostKey = tab.isLocal ? 'local' : tab.hostId;
    _tabMonitorVisible.putIfAbsent(
        tab.id, () => _monitorDefaultVisibleHosts.contains(hostKey));
  }

  // 监控可见性的默认值仍按 host 持久化；每个 tab 在会话内有独立覆盖
  final Set<String> _monitorDefaultVisibleHosts = {};
  final Map<String, bool> _tabMonitorVisible = {};

  bool _monitorVisibleFor(tp.TerminalTab? tab) {
    if (tab == null) return false;
    final hostKey = tab.isLocal ? 'local' : tab.hostId;
    return _tabMonitorVisible[tab.id] ??
        _monitorDefaultVisibleHosts.contains(hostKey);
  }

  /// 移动端方向变化只调整当前 tab 的方位，不覆盖其它 tab
  void _updateMobilePositionForActive() {
    if (!_isMobile) return;
    final tabId = _currentTabId;
    if (tabId == null) return;
    final orientation = MediaQuery.of(context).orientation;
    final target = orientation == Orientation.landscape
        ? _AiPanelPosition.right
        : _AiPanelPosition.bottom;
    if (_aiPanelPositionFor(tabId) != target) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _tabAiPanelPosition[tabId] = target;
        });
      });
    }
  }

  // Per-tab 监控服务缓存（key = tab.id；同服务器多 tab 各自独立历史）
  final Map<String, ServerMonitorService> _monitorServices = {};

  // AI 输入框焦点状态（移动端键盘避让）
  bool _aiInputFocused = false;

  // SFTP 侧面板（桌面端）- Per-tab 独立状态
  final Map<String, bool> _tabSftpVisible = {}; // 每个 tab 的 SFTP 面板是否可见
  // 终端右键「在 SFTP 中定位」传入的初始目录（进面板后消费一次）
  final Map<String, String> _tabSftpInitialPath = {};
  double _sftpPanelWidth = 320;
  // 设计稿「宽度与下限」：辅助面板不低于 240px，终端不低于 80 列。
  static const double _minSftpWidth = 240;
  /// 顶栏高度：设计稿 .topbar 42px（32px 控件 + 上下各 5px）。
  static const double _kTopBarHeight = 42;

  // SFTP 与 AI 正交摆放：AI 在右 → SFTP 落到底部条；底部条高度独立可调
  double _sftpPanelHeight = 240;
  static const double _minSftpHeight = 150;
  static const double _maxSftpHeight = 420;

  // 延迟 resize：记录最后需要同步尺寸的 tab
  tp.TerminalTab? _lastResizeTab;
  // R2: 保留 _switchToTab 的 150ms resize Timer 引用，便于切换 tab / dispose 时取消
  // 旧实现 inline 创建 Timer 不保留引用，导致 widget_test 中 dispose 后 Timer 仍 pending
  Timer? _resizeTimer;
  Timer? _chatScrollThrottle;
  static const double _maxSftpWidth = 600;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  // Per-tab 状态便捷访问器（自动根据 _currentTabId 读写对应 tab 的状态）
  String? get _executingCommand => _currentTabId != null ? _tabExecutingCommand[_currentTabId!] : null;
  set _executingCommand(String? v) { if (_currentTabId != null) _tabExecutingCommand[_currentTabId!] = v; }
  Set<String> get _executedCommands => _currentTabId != null ? (_tabExecutedCommands[_currentTabId!] ??= {}) : {};
  String? get _pendingConfirmCommand => _currentTabId != null ? _tabPendingConfirm[_currentTabId!] : null;
  set _pendingConfirmCommand(String? v) { if (_currentTabId != null) _tabPendingConfirm[_currentTabId!] = v; }

  final _scrollController = ScrollController();
  /// 每个 tab 独立的聊天滚动控制器/滚动状态；切 tab 不再共用一个 offset。
  final Map<String, ScrollController> _chatScrollControllers = {};
  final Map<String, bool> _tabShowScrollToBottom = {};
  final Map<String, bool> _tabAutoScroll = {};

  bool get _autoScrollChat => _tabAutoScroll[_currentTabId] ?? true;
  set _autoScrollChat(bool value) {
    if (_currentTabId != null) _tabAutoScroll[_currentTabId!] = value;
  }
  /// 每个 tab 的终端输出订阅：常驻，不随 tab 切换取消。
  /// 这样后台 tab 的 PTY 输出会继续写进它自己的 Terminal 缓冲。
  final Map<String, StreamSubscription<String>> _tabOutputSubscriptions = {};
  final Map<String, StreamSubscription<String>> _tabChatOutputSubscriptions = {};

  /// 终端输出到聊天上下文的批量缓冲：
  /// 高频输出（构建日志、tail -f）下不再每个 chunk 做 ANSI 清洗 + provider 通知。
  final Map<String, StringBuffer> _tabChatOutputBuffers = {};
  final Map<String, Timer> _tabChatOutputTimers = {};
  final Map<String, StringBuffer> _tabTermWriteBuffers = {};
  final Map<String, Timer> _tabTermWriteTimers = {};

  /// 每 tab 的命令捕获器：从屏幕输入行抓回车执行的命令（见 utils/command_tracker.dart）
  final Map<String, CommandTracker> _tabCommandTrackers = {};

  /// 每 tab 的 OSC 133 命令块（shell 装了集成才有；没有则恒空，菜单不出该项）
  final Map<String, TerminalBlockTracker> _tabBlockTrackers = {};

  // —— 分屏（文档 §4 方案 B）——
  //
  // 三个表都以 **paneId** 为键，且只装额外 pane：首屏的 id 就是 tabId，
  // 它的 Terminal / 订阅 / 会话早就挂在 tabId 上了（`_tabTerminals` 等），
  // 再登记一份就会有第二份真相。首屏因此天然就是 AI 绑定的那一屏。
  final Map<String, PaneLayout> _tabPaneLayout = {};
  final Map<String, Terminal> _paneTerminals = {};
  final Map<String, StreamSubscription<String>> _paneOutputSubscriptions = {};
  final Map<String, StringBuffer> _paneTermWriteBuffers = {};
  final Map<String, Timer> _paneTermWriteTimers = {};
  final Map<String, PaneSession> _paneSessions = {};
  final Set<String> _paneOpening = {};

  /// 焦点在哪一屏（新 pane 插在哪、焦点往哪移）。AI 绑定永远是首屏，
  /// 不跟着这里漂移（AGENTS.md R3）。
  String _activePaneForTab(String tabId) =>
      _tabPaneLayout[tabId]?.activeOrPrimary ?? tabId;

  PaneLayout _layoutForTab(String tabId) =>
      _tabPaneLayout.putIfAbsent(tabId, () => PaneLayout.single(tabId));

  PaneSession? _paneSessionFor(String paneId) => _paneSessions[paneId];
  DateTime _lastTermRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _termWriteFlushMs = 16;
  static const int _termWriteMaxChars = 64 * 1024;
  static const int _chatOutputFlushMs = 200;
  static const int _chatOutputMaxChars = 8192;
  AIModelConfig? _currentModelConfig;
  final MenuController _modelMenuController = MenuController();
  bool _agentInitInFlight = true;
  bool _pendingModelSync = false;
  PageRoute<dynamic>? _subscribedRoute;

  // 终端设置
  double _terminalFontSize = 14; // P0-3: 默认终端字号从 13 改为 14
  int _terminalScrollback = 10000;

  // Markdown 预处理 & 内容分割缓存（避免每次 build 重复解析）
  final Map<String, String> _markdownCache = {};
  final Map<String, List<_ContentSegment>> _splitCache = {};

  @override
  void initState() {
    super.initState();
    _loadSettings(); // 先加载设置（含 maxSteps），确保 _initAgent 使用正确的 maxSteps
    _initAgent();
    // 页面持有 notifier 引用而非在 dispose 里读 ref：TerminalPage 按路由存在，
    // 同一时刻只有一个实例，直接占位注册，dispose 里按身份判断后释放，
    // 避免误清掉下一个页面的注册。在 dispose 中用 ref 会抛
    // "Cannot use ref after the widget was disposed"，中断后续资源回收。
    _agentNotifier = ref.read(agentProvider.notifier);
    _agentNotifier!.secretRequestHandler = _requestSecret;
    _agentNotifier!.localDirRequestHandler = _requestLocalDir;
    // 延迟到帧构建完成后执行连接，避免在 build 阶段修改 provider 状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (widget.hostId != null) {
          _connectToHost();
        } else {
          _connectLocalTerminal();
        }
      }
    });
  }

    /// 存盘面板布局。方向只在桌面显式切换时写：移动端 `_updateMobilePositionForActive`
  /// 每帧按屏幕方向覆盖，存了也会在竖屏被改回 bottom。
  void _savePanelLayout({required bool savePosition}) {
    final tabId = _currentTabId;
    final width = _aiPanelWidthFor(tabId);
    // 没拖过就保持 null，下次启动仍然按设计稿的 320px 渲染。
    if (width != null) {
      _defaultAiPanelWidth = width;
      SettingsDao.set('aiPanelWidthV2', width);
    }
    if (!savePosition || _isMobile) return;
    final position = _aiPanelPositionFor(tabId);
    _defaultAiPanelPosition = position;
    SettingsDao.set('aiPanelPosition', position.name);
  }

  void _loadSettings() {
    try {
      final fontSize = SettingsDao.getCached('terminalFontSize');
      if (fontSize != null) {
        _terminalFontSize = (fontSize as num).toDouble();
      } else {
        // P0-3: 如果没有设置过，使用新的默认值 14
        _terminalFontSize = 14;
        SettingsDao.set('terminalFontSize', 14.0);
      }
    } catch (_) {
      _terminalFontSize = 14;
    }
    try {
      final scrollback = SettingsDao.getCached('terminalScrollback');
      if (scrollback is num && scrollback >= 1000) {
        _terminalScrollback = scrollback.toInt();
      }
    } catch (_) {}
    try {
      final sessionLog = SettingsDao.getCached('sessionLogEnabled');
      if (sessionLog is bool) _sessionLogEnabled = sessionLog;
    } catch (_) {}
    // P0-1: 加载 AI 面板可见性设置，默认收起
    try {
      final aiPanelVisible = SettingsDao.getCached('aiPanelVisible');
      if (aiPanelVisible != null) {
        _defaultAiPanelVisible = aiPanelVisible as bool;
      }
    } catch (_) {}
    // 方向：只有显式存过才覆盖默认值。
    // 存过 bottom 的老用户不能被新默认 right 翻回去，所以两边都要认。
    try {
      final resolved = resolveAiPanelLayout(
        storedPosition: SettingsDao.getCached('aiPanelPosition'),
        // 宽度已改为像素键 aiPanelWidth（见下），比例只用于方位解析，
        // 这里传默认值占位，结果丢弃。
        storedRatio: null,
        defaultPosition: _defaultAiPanelPosition.name,
        defaultRatio: 0.25,
        minRatio: _minPanelRatio,
        maxRatio: _maxPanelRatio,
      );
      _defaultAiPanelPosition = switch (resolved.position) {
        'bottom' => _AiPanelPosition.bottom,
        'overlay' => _AiPanelPosition.overlay,
        _ => _AiPanelPosition.right,
      };
    } catch (_) {}
    // 宽度：只认新键 aiPanelWidth（像素）。旧键 aiPanelRatioV2 里的 0.4
    // 是老实现的默认值，读到就会把面板撑到终端的一半，必须彻底忽略。
    try {
      final storedWidth = SettingsDao.getCached('aiPanelWidthV2');
      if (storedWidth is num) _defaultAiPanelWidth = storedWidth.toDouble();
    } catch (_) {}
    // 加载监控面板可见的 host 默认列表（每个 tab 可在会话内独立覆盖）
    try {
      final raw = SettingsDao.getCached('monitorVisibleHosts');
      if (raw is List) {
        _monitorDefaultVisibleHosts.addAll(raw.cast<String>());
      }
    } catch (_) {}
    // 加载 Agent 最大步骤数（需在 initAgent 之前加载）
    // 延迟到下一帧，避免在 widget tree build 期间修改 provider state
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(agentProvider.notifier).loadSettings();
    });
    // 监听当前 tab 的聊天滚动，控制"回到底部"按钮显示 & 自动滚动锁定。
    // 每个 tab 一个 controller，在 _chatControllerFor 创建时挂 listener。
  }

  /// 取某个 tab 的聊天滚动控制器；首次创建时挂上滚动监听。
  ScrollController _chatControllerFor(String tabId) {
    return _chatScrollControllers.putIfAbsent(tabId, () {
      final controller = ScrollController();
      controller.addListener(() => _onChatScroll(tabId, controller));
      return controller;
    });
  }

  void _onChatScroll(String tabId, ScrollController controller) {
    if (!controller.hasClients) return;
    final distanceFromBottom =
        controller.position.maxScrollExtent - controller.offset;
    final show = distanceFromBottom > 80;
    var auto = _tabAutoScroll[tabId] ?? true;
    // 用户往上拖（finger 向下、看更早内容）立即关自动滚动：
    // 流式期间每 150ms 就 jumpTo 回底部，若等"离底超过 120px"才关，
    // 用户的拖动会不断被拽回去，表现为"一直自动滑到底部"。
    // 程序化 jumpTo/animateTo 不会更新 userScrollDirection，不会误触发。
    if (distanceFromBottom > 8 &&
        controller.position.userScrollDirection == ScrollDirection.forward) {
      auto = false;
    }
    if (distanceFromBottom > 120) auto = false;
    if (distanceFromBottom <= 40) auto = true;
    _tabShowScrollToBottom[tabId] = show;
    _tabAutoScroll[tabId] = auto;
    if (tabId == _currentTabId && mounted) {
      setState(() {});
    }
  }

  Future<void> _initAgent() async {
    try {
      // 确保 provider 完成从 CredentialsStore 注入 apiKey（重启后 apiKey 来自安全存储）
      await ref.read(aiEndpointsProvider.notifier).loadEndpoints();
      final config = await AIModelSelectionService.resolveCurrent(
        endpoints: ref.read(aiEndpointsProvider),
      );
      if (config == null) return;
      _currentModelConfig = config;
      final aiProvider = AIService.create(config);
      ref.read(agentProvider.notifier).init(
        modelConfig: config,
        aiProvider: aiProvider,
      );
      if (mounted) setState(() {});
    } finally {
      _agentInitInFlight = false;
    }
  }

  /// 活跃 tab 的 Agent 是否忙碌（执行/启动/暂停/等待确认）。
  /// 只用 `AgentState.isRunning` 会漏掉 paused / waitingConfirm / 启动窗口，
  /// 此时切模型会重建引擎并取消任务。
  bool get _activeAgentBusy {
    final tab = ref.read(tp.terminalProvider).activeTab;
    if (tab != null) {
      return ref.read(agentProvider.notifier).isRunningFor(tab.id);
    }
    return ref.read(agentProvider).isRunning;
  }

  /// 仅看 state 的忙碌判断，供 listener 用（不能在里面 ref.read notifier）
  bool _agentStateBusy(AgentState? s) =>
      s != null &&
      (s.isRunning ||
          s.status == AgentStatus.paused ||
          s.status == AgentStatus.waitingConfirm);

  /// 切换大模型。选择会持久化，但配置里没有「默认模型」这个概念。
  void _switchModel(AIModelConfig model) {
    _currentModelConfig = model;
    AIModelSelectionService.saveSelectedModel(model.id);
    final aiProvider = AIService.create(model);
    ref.read(agentProvider.notifier).init(
      modelConfig: model,
      aiProvider: aiProvider,
    );
    setState(() {});
  }

  /// 应用「端点 + 模型」选择：解析该模型上次的档位（或默认 medium）后重建引擎。
  void _applyModelChoice(AIModelChoice choice, {AIReasoningTier? tier}) {
    if (_activeAgentBusy) {
      _showGoalHint(AppLocalizations.of(context)!.terminalModelLockedRunning);
      return;
    }
    final resolvedTier =
        tier ?? choice.model.resolveReasoningTier(AIModelSelectionService.tierFor(choice.modelId));
    final config = AIModelConfig.fromEndpoint(
      endpoint: choice.endpoint,
      model: choice.model,
      tier: resolvedTier,
    );
    if (resolvedTier != null) {
      AIModelSelectionService.saveReasoningTier(
          choice.modelId, resolvedTier.level);
    }
    _switchModel(config);
  }

  /// 只切思考档位，模型不变。
  void _applyReasoningTier(AIReasoningTier tier) {
    if (_activeAgentBusy) {
      _showGoalHint(AppLocalizations.of(context)!.terminalModelLockedRunning);
      return;
    }
    final current =
        ref.read(agentProvider.notifier).modelConfig ?? _currentModelConfig;
    if (current == null) return;
    final choice = AIModelSelectionService.findChoice(
        ref.read(aiEndpointsProvider), current.id);
    if (choice == null) return;
    final config = AIModelConfig.fromEndpoint(
      endpoint: choice.endpoint,
      model: choice.model,
      tier: tier,
    );
    AIModelSelectionService.saveReasoningTier(choice.modelId, tier.level);
    _switchModel(config);
  }

  /// 设置页保存端点后同步当前 host：非运行态立即重建，运行态延后到任务结束。
  void _scheduleModelSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncModelWithEndpoints(ref.read(aiEndpointsProvider));
    });
  }

  void _syncModelWithEndpoints(List<AIEndpoint> endpoints) {
    if (_agentInitInFlight || endpoints.isEmpty) return;
    if (_activeAgentBusy) {
      _pendingModelSync = true;
      return;
    }
    _pendingModelSync = false;

    final current =
        ref.read(agentProvider.notifier).modelConfig ?? _currentModelConfig;
    var choice = current == null
        ? null
        : AIModelSelectionService.findChoice(endpoints, current.id);
    var tierLevel =
        choice == null ? null : AIModelSelectionService.tierFor(choice.modelId);

    if (choice == null) {
      final selectedId = AIModelSelectionService.selectedModelId;
      choice = selectedId == null
          ? null
          : AIModelSelectionService.findChoice(endpoints, selectedId);
      final all = AIModelSelectionService.allChoices(endpoints);
      if (choice == null && all.isNotEmpty) {
        choice = all.first;
        AIModelSelectionService.saveSelectedModel(choice.modelId);
      }
      if (choice == null) return;
      tierLevel = AIModelSelectionService.tierFor(choice.modelId);
    }

    final tier = choice.model.resolveReasoningTier(tierLevel);
    final endpoint = choice.endpoint;
    final maxTokens =
        choice.model.maxTokens <= 0 ? 4096 : choice.model.maxTokens;
    final effort = tier != null && tier.sendsParameter ? tier.apiValue.trim() : null;
    final unchanged = current != null &&
        current.id == choice.model.id &&
        current.endpointId == endpoint.id &&
        current.baseUrl == endpoint.baseUrl &&
        current.apiKey == endpoint.apiKey &&
        current.modelName == choice.model.modelName &&
        current.temperature == choice.model.temperature &&
        current.maxTokens == maxTokens &&
        current.contextWindow == choice.model.contextWindow &&
        current.supportsFunctionCalling ==
            choice.model.supportsFunctionCalling &&
        current.fallbackModelId == choice.model.fallbackModelId &&
        current.reasoningEffort == effort &&
        current.reasoningLabel == tier?.label;
    if (unchanged) return;

    final config = AIModelConfig.fromEndpoint(
      endpoint: endpoint,
      model: choice.model,
      tier: tier,
    );
    if (tier != null) {
      AIModelSelectionService.saveReasoningTier(choice.modelId, tier.level);
    }
    _switchModel(config);
  }

  Future<void> _connectToHost() async {
    final host = ref.read(hostsProvider.notifier).getHostById(widget.hostId!);
    if (host == null) {
      setState(() => _placeholderError = L10n.str.terminalHostNotFound);
      return;
    }
    await _openHostTab(host);
  }

  /// 在新标签里连接服务器：先把界面切到新标签，再建连。
  ///
  /// 顺序是关键。以前等 connect 返回才切标签，期间画面还停在旧服务器上，
  /// 顶栏和输入框却已经指向新标签——两边对不上，看起来像卡住了。
  Future<void> _openHostTab(HostConfig host) async {
    final notifier = ref.read(tp.terminalProvider.notifier);
    final tab = notifier.registerTab(host);
    _switchToTab(tab);

    final connected = await notifier.connectTab(tab, host);
    if (connected == null || !mounted) return;

    // SSH 连接成功后设置 executor（R3：显式传 tab.hostId，避免用 activeHostId 顶替）
    ref.read(agentProvider.notifier).setExecutor(connected.service,
        hostId: connected.hostId, tabId: connected.id);
    // 过渡视图期间终端还没参与布局，尺寸要等真正渲染后再同步一次
    if (connected.id == _currentTabId) _scheduleSizeSync(connected);
  }

  /// 连接本地终端
  Future<void> _connectLocalTerminal() async {
    final notifier = ref.read(tp.terminalProvider.notifier);
    final tab = notifier.registerLocalTab();
    _switchToTab(tab);

    final connected = await notifier.connectLocalTab(tab);
    if (connected == null || !mounted) return;

    // 本地终端连接成功后立即设置 executor，使 Agent 模式可用
    ref.read(agentProvider.notifier).setExecutor(connected.localService,
        hostId: connected.hostId, tabId: connected.id);
    if (connected.id == _currentTabId) _scheduleSizeSync(connected);
  }

  /// 绑定某个 tab 自己的 Terminal：输入/尺寸写回该 tab 的 service，输出写入它的缓冲。
  StreamSubscription<String> _setupTerminalListener(
      tp.TerminalTab tab, Terminal term) {
    term.onOutput = (data) {
      // 建连仍在飞行中时不要另起一次重连：连接池按 tabId 去重，
      // 但两次 status 写入会互相覆盖，界面可能永远停在过渡态
      if (!tab.isConnected) {
        if (tab.isConnecting) return;
        if (tab.id == _currentTabId) _reconnect();
        return;
      }
      _tabCommandTrackers[tab.id]?.onInput(data, currentInputLine: () {
        // 刚敲的字符其回显可能还躺在批处理缓冲里（最多 16ms），不先落进
        // buffer 就会读到半条命令。闭包只在回车时执行，不影响按键热路径。
        _flushTermWrite(tab.id);
        return currentInputLineOf(term);
      });
      if (tab.isLocal) {
        tab.localService?.writeToTerminal(data);
      } else {
        tab.service?.writeToTerminal(data);
      }
    };
    term.onResize = (width, height, pixelWidth, pixelHeight) {
      if (tab.isLocal) {
        tab.localService?.resize(width, height);
      } else {
        tab.service?.resize(width, height);
      }
    };
    // xterm 4.0.0 的循环缓冲在滚动回卷时可能越界（见 agent.log 里的 RangeError）。
    // 一次写坏后 Buffer 的行数和循环缓冲会失配，之后每帧 paint 都会再崩一次，
    // 所以这里就地恢复：清掉滚动历史让索引重新对齐，并做 5s 冷却避免刷屏。
    // 输出先入帧级批处理缓冲：逐 chunk 直写会让每个 PTY/SSH 包都触发一次
    // VT 解析 + markNeedsLayout + 全视口重绘，大输出时 CPU/GPU 直接打满。
    return tab.outputController.stream.listen((data) {
      _bufferTermWrite(tab.id, data);
      _sessionRecorders[tab.id]?.write(data);
      _tabCommandTrackers[tab.id]?.onOutput(data);
    });
  }

  /// 终端显示路径批处理：最多每 16ms（约一帧）或 64KB 合并写入一次。
  ///
  /// 键既可以是 tabId（首屏）也可以是 paneId（额外屏，形如 `tab#p1`）：
  /// 首屏 id 不含 `#p`，据此分流到两套缓冲，避免分屏输出跟主屏互相挤批。
  void _bufferTermWrite(String id, String data) {
    final buffers = _isPaneId(id) ? _paneTermWriteBuffers : _tabTermWriteBuffers;
    final buffer = buffers.putIfAbsent(id, StringBuffer.new)..write(data);
    if (buffer.length >= _termWriteMaxChars) {
      _flushTermWrite(id);
      return;
    }
    final timers = _isPaneId(id) ? _paneTermWriteTimers : _tabTermWriteTimers;
    timers[id] ??= Timer(
      const Duration(milliseconds: _termWriteFlushMs),
      () => _flushTermWrite(id),
    );
  }

  static bool _isPaneId(String id) => id.contains('#p');

  void _flushTermWrite(String id) {
    (_isPaneId(id) ? _paneTermWriteTimers : _tabTermWriteTimers)
        .remove(id)
        ?.cancel();
    final buffer =
        (_isPaneId(id) ? _paneTermWriteBuffers : _tabTermWriteBuffers)
            .remove(id);
    if (buffer == null || buffer.isEmpty) return;
    final term =
        _isPaneId(id) ? _paneTerminals[id] : _tabTerminals[id];
    if (term == null) return;
    try {
      term.write(buffer.toString());
    } catch (e) {
      final now = DateTime.now();
      if (now.difference(_lastTermRecoveryAt).inSeconds >= 5) {
        _lastTermRecoveryAt = now;
        agentLogger.warn('Terminal', '写入异常，清空滚动历史以恢复: $e');
        try {
          term.buffer.clearScrollback();
        } catch (_) {}
      }
    }
  }

  void _discardTermWrite(String id) {
    final isPane = _isPaneId(id);
    (isPane ? _paneTermWriteTimers : _tabTermWriteTimers).remove(id)?.cancel();
    (isPane ? _paneTermWriteBuffers : _tabTermWriteBuffers).remove(id);
  }

  // ==================== 分屏（文档 §4 方案 B）====================
  //
  // 路由规则：第一个 pane 就是标签本身 —— 它的 service、executor 绑定、AI 面板
  // 全挂在 tabId 上，一律不动，所以 AI 的命令天然只落在这屏。额外 pane 各开自己
  // 的会话（本地 PTY / 同一条 SSH 连接上的第二条 shell），是纯用户终端：永不注册
  // executor，AI 绝不写入它。绑定也不随焦点漂移（AGENTS.md R3）。

  tp.TerminalTab? _tabById(String tabId) => ref
      .read(tp.terminalProvider)
      .tabs
      .cast<tp.TerminalTab?>()
      .firstWhere((t) => t?.id == tabId, orElse: () => null);

  /// pane id 形如 `<tabId>#p1`；首屏 id 就是 tabId（无后缀）
  static String _tabIdOfPaneId(String paneId) {
    final i = paneId.lastIndexOf('#p');
    return i < 0 ? paneId : paneId.substring(0, i);
  }

  /// pane 是否还在该标签的布局里（建会话是异步的，回来时可能已被关掉）
  bool _paneExists(String tabId, String paneId) {
    final layout = _tabPaneLayout[tabId];
    return layout != null && layout.indexOf(paneId) >= 0;
  }

  /// 额外 pane 自己的 Terminal（含 OSC 133 块跟踪与命令捕获）。
  /// build 期间调用，只写页面私有的 map，不 setState。
  Terminal _ensurePaneTerminal(String tabId, String paneId) {
    final existing = _paneTerminals[paneId];
    if (existing != null) return existing;
    final term = Terminal(maxLines: _terminalScrollback);
    _paneTerminals[paneId] = term;
    final blockTracker = TerminalBlockTracker(terminal: term);
    _tabBlockTrackers[paneId] = blockTracker;
    term.onPrivateOSC = blockTracker.onPrivateOsc;
    final hostId = _tabById(tabId)?.hostId ?? 'local';
    _tabCommandTrackers[paneId] = CommandTracker(
      onCommand: (command) =>
          CommandHistoryDao.record(command, hostId: hostId),
    );
    return term;
  }

  /// 为额外 pane 打开（或补开）会话通道并双向绑定。
  ///
  /// 三条收尾路径都必须释放：建会话失败、期间 pane 被关、期间页面被销毁 ——
  /// 谁创建谁释放（R2），否则本地会留下孤儿 PTY 进程。
  Future<void> _ensurePaneSession(String tabId, String paneId) async {
    final existing = _paneSessions[paneId];
    if (existing != null) {
      if (existing.isConnected) return;
      // 主连接重连过：旧 shell 随 client 一起废了，补开一条，
      // 否则这一屏看着还在、敲键却毫无反应。
      _paneOutputSubscriptions.remove(paneId)?.cancel();
      existing.close();
      _paneSessions.remove(paneId);
      _discardTermWrite(paneId);
    }
    if (_paneOpening.contains(paneId)) return;
    final tab = _tabById(tabId);
    if (tab == null) return;
    final isLocal = tab.isLocal;
    final client = tab.service?.client;
    final encoding = tab.service?.config.encoding ?? 'utf-8';
    if (!isLocal && client == null) {
      _paneHint(paneId, 'SSH 连接未就绪，重连后点这一屏重试');
      return;
    }
    _paneOpening.add(paneId);
    PaneSession? session;
    try {
      session = isLocal
          ? await LocalPaneSession.start()
          : await SshPaneSession.open(client!, encoding: encoding);
    } catch (e) {
      session?.close();
      session = null;
      agentLogger.warn('Pane', '打开分屏会话失败: $e');
    } finally {
      _paneOpening.remove(paneId);
    }
    // await 之后重新确认：pane 可能已被关、页面可能已销毁（R1）
    if (!mounted || !_paneExists(tabId, paneId)) {
      session?.close();
      return;
    }
    // SSH 的 client 可能在这一次 await 期间被换掉（掉线→重连）。此时拿到的
    // shell 挂在已关闭的旧连接上：注册进去就是一屏「看着在、敲键没反应」。
    // 掉线时 `_invalidatePaneSessions` 还看不到这条尚未登记的会话，所以只能
    // 在这里按身份比一次。
    if (!isLocal && !identical(client, _tabById(tabId)?.service?.client)) {
      session?.close();
      // 换掉 client 的那次重连可能正好也在这次 await 期间完成，于是重连回调里
      // 的补开被 `_paneOpening` 挡掉了。这里用新 client 再跑一次，否则这一屏
      // 只能等用户手点重开 —— 与「重连后自动补开」的约定不符。
      unawaited(_ensurePaneSession(tabId, paneId));
      return;
    }
    if (session == null) {
      _paneHint(paneId, isLocal ? '本地终端启动失败' : '这一屏的会话打开失败');
      return;
    }
    _paneSessions[paneId] = session;
    final term = _ensurePaneTerminal(tabId, paneId);
    term.write('\x1b[2J\x1b[H');
    _bindPaneChannel(tabId, paneId, term, session);
    setState(() {});
  }

  void _bindPaneChannel(
      String tabId, String paneId, Terminal term, PaneSession session) {
    _paneOutputSubscriptions.remove(paneId)?.cancel();
    term.onOutput = (data) {
      _tabCommandTrackers[paneId]?.onInput(data, currentInputLine: () {
        _flushTermWrite(paneId);
        return currentInputLineOf(term);
      });
      session.writeToTerminal(data);
    };
    term.onResize = (width, height, _, __) => session.resize(width, height);
    _paneOutputSubscriptions[paneId] = session.output.listen(
      (data) => _bufferTermWrite(paneId, data),
      // 通道自己关了（shell 退出 / 主机侧断链 / 主连接作废）：留一行提示，
      // 并把会话从表里摘掉 —— 底部重开条只在「表里没有会话」时出现，留着这条
      // 死对象等于把这一屏永久锁死（点不动也重不开）。
      onDone: () {
        if (!_paneExists(tabId, paneId)) return;
        if (_paneSessions[paneId] != session) return;
        _paneSessions.remove(paneId);
        _discardTermWrite(paneId);
        term.write('\r\n\x1b[90m[会话已结束]\x1b[0m\r\n');
        setState(() {});
      },
    );
  }

  void _paneHint(String paneId, String message) {
    final tabId = _tabIdOfPaneId(paneId);
    if (!_paneExists(tabId, paneId)) return;
    _ensurePaneTerminal(tabId, paneId).write('\r\n\x1b[31m$message\x1b[0m\r\n');
    setState(() {});
  }

  void _splitPane(String tabId, SplitDirection direction) {
    final current = _layoutForTab(tabId);
    final result = splitAfter(current, afterPaneId: _activePaneForTab(tabId));
    if (result == null) {
      _showOperationMessage(
        '一个标签最多 ${PaneLayout.maxPanes} 屏（每屏一个真实会话）',
        isError: true,
      );
      return;
    }
    // 同一方向连续切是 iTerm2 的习惯；换方向时整体重排，不做嵌套树
    var layout = result.layout;
    if (layout.isSplit && layout.direction != direction) {
      layout = setDirection(layout, direction);
    }
    _tabPaneLayout[tabId] = layout;
    _ensurePaneTerminal(tabId, result.newPaneId);
    setState(() {});
    unawaited(_ensurePaneSession(tabId, result.newPaneId));
  }

  /// 关掉一屏。
  ///
  /// 首屏在有其它屏时不许单独关：AI 绑的就是首屏那条会话，关掉它会让 AI 的
  /// 输出「没有画面」——比取消任务更糟（文档 §4：宁可取消也不能悄悄迁移）。
  /// 要收掉这一屏请关标签，那条路径已有 removeTab → 取消运行中任务。
  void _closePane(String tabId, String paneId) {
    final layout = _layoutForTab(tabId);
    if (!layout.isSplit) return;
    if (paneId == layout.primaryPaneId) {
      _showOperationMessage('这一屏绑定了 AI，不能单独关掉；请直接关闭标签',
          isError: true);
      return;
    }
    _tabPaneLayout[tabId] = closePane(layout, paneId);
    _disposePane(paneId);
    setState(() {});
  }

  void _focusPaneNeighbor(String tabId, bool forward) {
    final layout = _layoutForTab(tabId);
    final next =
        neighborPane(layout, _activePaneForTab(tabId), forward: forward);
    if (next == null) return; // 到边界不动：绕圈会让用户以为终端吞了键
    _tabPaneLayout[tabId] = setActive(layout, next);
    setState(() {});
  }

  /// 键盘焦点落到某一屏。setState 是必须的：`active` 决定 Windows 原生 IME
  /// 的唯一投递目标，不跟着真实焦点走会把中文送进另一屏。
  void _setPaneFocus(String tabId, String paneId) {
    final layout = _tabPaneLayout[tabId];
    if (layout == null || !layout.isSplit) return;
    if (layout.activeOrPrimary == paneId) return; // 未变则不重建（避免回环）
    _tabPaneLayout[tabId] = setActive(layout, paneId);
    setState(() {});
  }

  void _dragPaneDivider(
      tp.TerminalTab tab, int index, double delta, double extent) {
    if (extent <= 0) return;
    final layout = _layoutForTab(tab.id);
    _tabPaneLayout[tab.id] = dragDivider(layout, index, delta / extent);
    setState(() {});
  }

  void _disposePane(String paneId) {
    _paneOutputSubscriptions.remove(paneId)?.cancel();
    _discardTermWrite(paneId);
    _paneSessions.remove(paneId)?.close();
    _paneOpening.remove(paneId);
    _tabBlockTrackers.remove(paneId)?.dispose();
    _tabCommandTrackers.remove(paneId);
    _paneTerminals.remove(paneId);
  }

  /// 关掉标签：清掉它的所有额外 pane（首屏由 tab 自己的清理路径负责）
  void _disposeTabPanes(String tabId) {
    final layout = _tabPaneLayout.remove(tabId);
    if (layout == null) return;
    for (final paneId in layout.paneIds) {
      if (paneId != tabId) _disposePane(paneId);
    }
  }

  /// 主连接掉线：额外 pane 的 shell 挂在同一个 client 上，一起作废。
  /// 布局保留 —— 用户重连后点那一屏会自动补开，滚动内容也不丢。
  void _invalidatePaneSessions(String tabId) {
    if (!mounted) return;
    final layout = _tabPaneLayout[tabId];
    if (layout == null || !layout.isSplit) return;
    var changed = false;
    for (final paneId in layout.paneIds) {
      final session = _paneSessions.remove(paneId);
      if (session == null) continue;
      _paneOutputSubscriptions.remove(paneId)?.cancel();
      session.close();
      _discardTermWrite(paneId);
      changed = true;
    }
    if (changed) setState(() {});
  }

  /// 重连成功后把额外 pane 的会话补开回来。
  ///
  /// 覆盖两种空洞：掉线时作废的、以及首连还没就绪所以压根没开成的。
  /// `_ensurePaneSession` 自己会跳过「已有活会话」和「正在开」，重复调用安全。
  void _reopenPaneSessions(tp.TerminalTab tab) {
    final layout = _tabPaneLayout[tab.id];
    if (layout == null || !layout.isSplit) return;
    for (final paneId in layout.paneIds) {
      if (paneId == tab.id) continue;
      unawaited(_ensurePaneSession(tab.id, paneId));
    }
  }

  /// 一屏 = 一个 TerminalView + 归属徽标 +（额外屏）会话不可用时的重开入口。
  ///
  /// 徽标是分屏的核心交代：用户必须一眼看出「AI 在那一屏干活」「这一屏只是我
  /// 自己的 shell」，否则共享会话的 AI 输出会像是凭空出现在别的屏。
  Widget _buildPaneView(tp.TerminalTab tab, String paneId,
      {required bool isActive}) {
    final isPrimary = paneId == tab.id;
    final layout = _layoutForTab(tab.id);
    final term = isPrimary
        ? (_tabTerminals[tab.id] ?? _terminal)
        : _ensurePaneTerminal(tab.id, paneId);
    final session = isPrimary ? null : _paneSessions[paneId];
    final tc = ThemeColors.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        term_widget.TerminalView(
          terminal: term,
          blockTracker: _tabBlockTrackers[paneId],
          fontSize: _terminalFontSize,
          paletteId: ref.watch(
              settingsProvider.select((s) => s['terminalPalette'] as String?)),
          keymap: TerminalKeymap.fromSettings(
              ref.watch(settingsProvider.select((s) => s['terminalKeybindings']))),
          active: isActive,
          isLocal: tab.isLocal,
          onCommandPalette: _showCommandPalette,
          onFontSizeChanged: (size) {
            final clamped = size.clamp(10.0, 24.0);
            setState(() => _terminalFontSize = clamped);
            // 同步给 settingsProvider：顶栏外观浮层的字号读数才不会停在旧值
            ref
                .read(settingsProvider.notifier)
                .setSetting('terminalFontSize', clamped);
          },
          onMenuIntent: (intent, text) =>
              _handleTerminalMenuIntent(tab, intent, text, paneId: paneId),
          onSend: (command) {
            if (isPrimary) {
              if (tab.isLocal) {
                tab.localService?.execute(command);
              } else {
                tab.service?.execute(command);
              }
            } else {
              _paneSessionFor(paneId)?.writeToTerminal('$command\r');
            }
          },
          panes: TerminalPaneActions(
            paneId: paneId,
            isPrimary: isPrimary,
            isSplit: layout.isSplit,
            canSplit: layout.canSplit,
            onSplit: (direction) => _splitPane(tab.id, direction),
            onClose: () => _closePane(tab.id, paneId),
            onFocusNeighbor: (forward) => _focusPaneNeighbor(tab.id, forward),
            onFocus: () => _setPaneFocus(tab.id, paneId),
          ),
        ),
        if (layout.isSplit)
          Positioned(
            top: 6,
            right: 10,
            child: _buildPaneBadge(
              label: isPrimary
                  ? UiText.t('AI 会话', 'AI session')
                  : UiText.t('本地 shell', 'Local shell'),
              color: isPrimary ? tc.agentGreen : tc.textMuted,
            ),
          ),
        if (!isPrimary && session == null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildPaneRetryBar(tab.id, paneId),
          ),
      ],
    );
  }

  Widget _buildPaneBadge({required String label, required Color color}) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: fMicro, color: color, height: 1.2)),
      ),
    );
  }

  Widget _buildPaneRetryBar(String tabId, String paneId) {
    final tc = ThemeColors.of(context);
    return Container(
      color: tc.cardElevated.withValues(alpha: 0.92),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 14, color: tc.warn),
          const SizedBox(width: 6),
          Expanded(
            child: Text(UiText.t('这一屏的会话已断开', 'This pane\'s session ended'),
                style: TextStyle(fontSize: fMicro, color: tc.textSub)),
          ),
          TextButton(
            onPressed: () => _ensurePaneSession(tabId, paneId),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 22),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(UiText.t('重开这一屏', 'Reopen pane'),
                style: const TextStyle(fontSize: fMicro)),
          ),
        ],
      ),
    );
  }

  /// 终端区：未分屏就是一屏；分屏按方向平铺 + 可拖分隔条。
  ///
  /// 用 Expanded(flex:) 而非按占比算宽度：flex 由布局引擎保证「分完且不重叠」，
  /// 浮点比例直接换宽度会留 0.5px 缝，且 flex 最小为 1 = 任何 pane 都不会被压没。
  Widget _buildTerminalArea(tp.TerminalTab tab, {required bool isActive}) {
    final layout = _layoutForTab(tab.id);
    if (!layout.isSplit) {
      return _buildPaneView(tab, tab.id, isActive: isActive);
    }
    final flex = ratiosToFlex(layout.ratios);
    return LayoutBuilder(builder: (context, constraints) {
      final isRow = layout.direction.isSideBySide;
      final extent = isRow ? constraints.maxWidth : constraints.maxHeight;
      final children = <Widget>[];
      for (var i = 0; i < layout.paneIds.length; i++) {
        if (i > 0) {
          children.add(_buildPaneDivider(tab, i, isRow, extent));
        }
        final paneId = layout.paneIds[i];
        children.add(Expanded(
          key: ValueKey('pane-$paneId'),
          flex: flex[i],
          child: _buildPaneView(
            tab,
            paneId,
            isActive: isActive && layout.activeOrPrimary == paneId,
          ),
        ));
      }
      return Flex(
        direction: isRow ? Axis.horizontal : Axis.vertical,
        children: children,
      );
    });
  }

  Widget _buildPaneDivider(
      tp.TerminalTab tab, int index, bool isRow, double extent) {
    final tc = ThemeColors.of(context);
    return MouseRegion(
      cursor: isRow
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _dragPaneDivider(
            tab, index, isRow ? d.delta.dx : d.delta.dy, extent),
        child: Container(
          width: isRow ? 6 : double.infinity,
          height: isRow ? double.infinity : 6,
          color: tc.border.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  /// 确保某个 tab 有独立的 Terminal 和常驻输出订阅。切换 tab 不再取消/重建。
  void _ensureTabTerminal(tp.TerminalTab tab) {
    final isCurrent = tab.id == _currentTabId;
    final existing = _tabTerminals[tab.id];
    if (existing != null) {
      if (isCurrent) _terminal = existing;
      return;
    }
    final term = Terminal(maxLines: _terminalScrollback);
    _tabTerminals[tab.id] = term;
    if (isCurrent) _terminal = term;
    if (_sessionLogEnabled) {
      final recorder = SessionRecorder(label: tab.title);
      _sessionRecorders[tab.id] = recorder;
      recorder.start();
    }
    _tabCommandTrackers[tab.id] = CommandTracker(
      onCommand: (command) =>
          CommandHistoryDao.record(command, hostId: tab.hostId),
    );
    // xterm 不认识 OSC 133，但会把不认识的 OSC 转交给 onPrivateOSC：
    // 装了 shell 集成的会话据此把「命令 + 它的输出」切成块。
    final blockTracker = TerminalBlockTracker(terminal: term);
    _tabBlockTrackers[tab.id] = blockTracker;
    term.onPrivateOSC = blockTracker.onPrivateOsc;
    _tabOutputSubscriptions[tab.id] = _setupTerminalListener(tab, term);
    _tabChatOutputSubscriptions[tab.id] =
        tab.outputController.stream.listen((data) {
      if (tab.id == _currentTabId && mounted) {
        _bufferChatOutput(tab.id, data);
      }
    });
  }

  /// 累积该 tab 的终端输出，最多每 200ms 或 8KB 触发一次上下文更新
  void _bufferChatOutput(String tabId, String data) {
    final buffer =
        _tabChatOutputBuffers.putIfAbsent(tabId, StringBuffer.new)..write(data);
    if (buffer.length >= _chatOutputMaxChars) {
      _flushChatOutput(tabId);
      return;
    }
    _tabChatOutputTimers[tabId] ??= Timer(
      const Duration(milliseconds: _chatOutputFlushMs),
      () => _flushChatOutput(tabId),
    );
  }

  void _flushChatOutput(String tabId) {
    _tabChatOutputTimers.remove(tabId)?.cancel();
    final buffer = _tabChatOutputBuffers.remove(tabId);
    if (buffer == null || buffer.isEmpty) return;
    var text = buffer.toString();
    if (text.length > _chatOutputMaxChars) {
      text = text.substring(text.length - _chatOutputMaxChars);
    }
    if (!mounted) return;
    ref.read(chatProvider.notifier).updateLastOutput(text);
  }

  void _discardChatOutput(String tabId) {
    _tabChatOutputTimers.remove(tabId)?.cancel();
    _tabChatOutputBuffers.remove(tabId);
  }

  /// 统一切换到指定 tab：每 tab 的 Terminal/输出订阅已常驻，这里只切状态。
  void _switchToTab(tp.TerminalTab tab) {
    _currentTabId = tab.id;
    _initTabPanelState(tab);
    _ensureTabTerminal(tab);
    _chatControllerFor(tab.id);

    // 更新各 provider 的当前 tab（switchTab 已恢复该 tab 的 engine/ssh/model）
    _placeholderError = null; // 已有标签可承载提示，不再需要整屏占位
    ref.read(chatProvider.notifier).switchTab(tab.id, hostId: tab.hostId);
    ref.read(agentProvider.notifier).switchTab(tab.id, hostId: tab.hostId);
    // 不再调用 setSSHService — switchTab 已恢复该 tab 的 SSH 服务，
    // 避免每次切换都重新 collectSystemInfo

    setState(() {});

    // 首帧渲染后确保 PTY 尺寸与终端视图同步，修复 Tab 补全时 prompt 被覆盖的问题
    _scheduleSizeSync(tab);
  }

  /// 延迟到 xterm 完成自身布局后，把终端视图尺寸推给 PTY/SSH 通道
  /// R2: 保留 Timer 引用，切换 tab / dispose 时取消，避免 Timer 在 widget 销毁后仍 pending
  void _scheduleSizeSync(tp.TerminalTab tab) {
    _lastResizeTab = tab;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      final currentTab = _lastResizeTab;
      if (currentTab == null) return;
      final term = _tabTerminals[currentTab.id];
      if (term == null) return;
      final termW = term.viewWidth;
      final termH = term.viewHeight;
      if (currentTab.isLocal) {
        currentTab.localService?.resize(termW, termH);
      } else {
        currentTab.service?.resize(termW, termH);
      }
    });
  }

  /// 在当前 tab 上重连（SSH 或本地终端）
  /// 保留 tabId、终端历史内容、订阅，仅替换底层 service
  Future<void> _reconnect() async {
    final tab = ref.read(tp.terminalProvider).activeTab;
    if (tab == null) {
      // 没有活跃 tab，回退到首次连接流程
      if (widget.hostId == null) {
        _connectLocalTerminal();
      } else {
        _connectToHost();
      }
      return;
    }
    await _reconnectTab(tab);
  }

  /// 重连指定 tab（手动与空闲自动重连共用）。成功后重绑 AI executor。
  Future<void> _reconnectTab(tp.TerminalTab tab) async {
    if (tab.isConnecting) return;
    _autoReconnectTimers.remove(tab.id)?.cancel();

    tp.TerminalTab? newTab;
    if (tab.isLocal) {
      newTab = await ref.read(tp.terminalProvider.notifier).reconnectLocal(tab.id);
      if (!mounted) return;
      if (newTab?.localService != null) {
        // 重新绑定 executor（service 已更新）
        ref.read(agentProvider.notifier).setExecutor(newTab!.localService,
            hostId: newTab.hostId, tabId: newTab.id);
        // 终端的 onOutput 闭包读的是 tab 上的实时 service，重连不需要重绑订阅
        _ensureTabTerminal(newTab);
        // 新会话的提示符与旧连接无关，清掉残留的提示语判定
        _tabCommandTrackers[newTab.id]?.reset();
        // 旧连接的块与新 shell 无关（新 shell 甚至可能没装集成）
        _tabBlockTrackers[newTab.id]?.reset();
        if (newTab.id == _currentTabId) _scheduleSizeSync(newTab);
      }
    } else {
      final host = ref.read(hostsProvider.notifier).getHostById(tab.hostId);
      if (host == null) {
        _showOperationMessage(L10n.str.terminalHostNotFound, isError: true);
        return;
      }
      newTab = await ref.read(tp.terminalProvider.notifier).reconnect(tab.id, host);
      if (!mounted) return;
      if (newTab?.service != null) {
        ref.read(agentProvider.notifier).setExecutor(newTab!.service,
            hostId: newTab.hostId, tabId: newTab.id);
        // 终端的 onOutput 闭包读的是 tab 上的实时 service，重连不需要重绑订阅
        _ensureTabTerminal(newTab);
        _tabCommandTrackers[newTab.id]?.reset();
        _tabBlockTrackers[newTab.id]?.reset();
        if (newTab.id == _currentTabId) _scheduleSizeSync(newTab);
      }
    }

    if (newTab == null) {
      // 失败原因存在 tab.connectionError 上，主区按状态渲染；这里补一条即时反馈
      _showOperationMessage(tab.connectionError ?? L10n.str.connectionFailedHint, isError: true);
    } else {
      // 重连成功：清零自动重连计数，下次掉线重新获得完整退避预算
      _autoReconnectAttempts.remove(tab.id);
    }
  }

  /// 空闲断线自动重连（docs §5）：connected→lost 且该 tab 无运行中任务时，
  /// 按 1s/2s/4s 退避最多自动重连 3 次；任务运行中不重连（断线即任务 failed，
  /// 留给用户/引擎显式重试）。本地 PTY 退出是正常结束，不自动重启。
  void _maybeAutoReconnect(tp.TerminalTab tab) {
    if (tab.isLocal || tab.status != tp.TabStatus.lost) return;
    if (ref.read(agentProvider.notifier).isRunningFor(tab.id)) return;
    final attempts = _autoReconnectAttempts[tab.id] ?? 0;
    if (!ReconnectPolicy.shouldRetry(attempts)) return;
    _autoReconnectTimers.remove(tab.id)?.cancel();
    _autoReconnectTimers[tab.id] =
        Timer(ReconnectPolicy.delayForAttempt(attempts), () {
      _autoReconnectTimers.remove(tab.id);
      if (!mounted) return;
      final current = ref
          .read(tp.terminalProvider)
          .tabs
          .cast<tp.TerminalTab?>()
          .firstWhere((t) => t?.id == tab.id, orElse: () => null);
      // 等待期间用户可能已手动重连/关闭 tab，或任务已启动
      if (current == null || current.status != tp.TabStatus.lost) return;
      if (ref.read(agentProvider.notifier).isRunningFor(tab.id)) return;
      _autoReconnectAttempts[tab.id] = attempts + 1;
      _reconnectTab(current);
    });
  }

  void _showAddHostDialog() {
    // 弹出已保存服务器列表供选择（允许重复连接）
    final hosts = HostsDao.cached.toList();
    if (hosts.isEmpty) {
      context.push('/host/edit');
      return;
    }

    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      backgroundColor: tc.cardElevated,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(rLarge))),
      builder: (context) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.add_circle_outline, size: 16, color: tc.brand),
                  const SizedBox(width: 8),
                  Text(l10n.terminalSelectServerForNewTab, style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      this.context.push('/host/edit');
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: tc.brand.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(rSmall),
                        border: Border.all(color: tc.brand.withValues(alpha: 0.25)),
                      ),
                      child: Text(l10n.terminalCreateNew, style: TextStyle(fontSize: fMicro, color: tc.brand, fontWeight: FontWeight.w500)),
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: tc.border, height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: hosts.length,
                itemBuilder: (context, index) {
                  final host = hosts[index];
                  return ListTile(
                    dense: true,
                    leading: Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        color: host.tagColor != null
                            ? tagColors.firstWhere((c) => c.toARGB32().toString() == host.tagColor, orElse: () => cPrimary)
                            : cPrimary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    title: Text(host.name, style: TextStyle(fontSize: fBody, color: tc.textMain)),
                    subtitle: Text('${host.username}@${host.host}', style: TextStyle(fontSize: fMicro, color: tc.textSub, fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback)),
                    trailing: Icon(Icons.open_in_new, size: 14, color: tc.textMuted),
                    onTap: () {
                      Navigator.pop(context);
                      _openHostTab(host);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final localTitle = AppLocalizations.of(context)?.terminalLocalTab;
    if (localTitle != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(tp.terminalProvider.notifier).syncLocalTabTitle(localTitle);
        }
      });
    }
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _subscribedRoute) {
      if (_subscribedRoute != null) appRouteObserver.unsubscribe(this);
      _subscribedRoute = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  /// 从设置页等子路由返回：设置页里的端点/模型改动不会自动进入已存在的
  /// Agent 引擎，这里强制重读端点并同步当前 host 的模型配置。
  @override
  void didPopNext() {
    _refreshModelsAfterSettings();
  }

  Future<void> _refreshModelsAfterSettings() async {
    if (!mounted) return;
    await ref.read(aiEndpointsProvider.notifier).loadEndpoints();
    if (!mounted) return;
    _syncModelWithEndpoints(ref.read(aiEndpointsProvider));
    setState(() {});
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _resizeTimer?.cancel();
    _resizeTimer = null;
    _chatScrollThrottle?.cancel();
    _chatScrollThrottle = null;
    for (final sub in _tabOutputSubscriptions.values) {
      sub.cancel();
    }
    _tabOutputSubscriptions.clear();
    for (final sub in _tabChatOutputSubscriptions.values) {
      sub.cancel();
    }
    _tabChatOutputSubscriptions.clear();
    for (final timer in _tabChatOutputTimers.values) {
      timer.cancel();
    }
    _tabChatOutputTimers.clear();
    _tabChatOutputBuffers.clear();
    for (final timer in _tabTermWriteTimers.values) {
      timer.cancel();
    }
    _tabTermWriteTimers.clear();
    _tabTermWriteBuffers.clear();
    for (final sub in _paneOutputSubscriptions.values) {
      sub.cancel();
    }
    _paneOutputSubscriptions.clear();
    for (final timer in _paneTermWriteTimers.values) {
      timer.cancel();
    }
    _paneTermWriteTimers.clear();
    _paneTermWriteBuffers.clear();
    // 额外 pane 是真实 PTY / SSH shell：页面销毁必须收干净，否则留下孤儿进程
    for (final session in _paneSessions.values) {
      session.close();
    }
    _paneSessions.clear();
    _paneOpening.clear();
    _tabPaneLayout.clear();
    _paneTerminals.clear();
    for (final timer in _autoReconnectTimers.values) {
      timer.cancel();
    }
    _autoReconnectTimers.clear();
    _autoReconnectAttempts.clear();
    _lastTabStatus.clear();
    for (final recorder in _sessionRecorders.values) {
      recorder.close();
    }
    _sessionRecorders.clear();
    for (final service in _portForwardServices.values) {
      service.dispose();
    }
    _portForwardServices.clear();
    _scrollController.dispose();
    for (final controller in _chatScrollControllers.values) {
      controller.dispose();
    }
    _chatScrollControllers.clear();
    final notifier = _agentNotifier;
    if (notifier != null && notifier.secretRequestHandler == _requestSecret) {
      notifier.secretRequestHandler = null;
    }
    if (notifier != null &&
        notifier.localDirRequestHandler == _requestLocalDir) {
      notifier.localDirRequestHandler = null;
    }
    _agentNotifier = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 终端字号是终端自己的状态（Ctrl +/- 改它），但顶栏外观浮层的字号控件走
    // settingsProvider：只写库不通知这边，滑块拖完终端不动，看着就像「设置没生效」。
    // 这里把外部改动收回本地状态，两处入口操作的是同一份显示。
    ref.listen(settingsProvider.select((s) => s['terminalFontSize']), (_, next) {
      if (next is num && next.toDouble() != _terminalFontSize) {
        setState(() => _terminalFontSize = next.toDouble().clamp(8.0, 24.0));
      }
    });
    final host = widget.hostId != null ? ref.watch(hostsProvider.notifier).getHostById(widget.hostId!) : null;
    final terminalState = ref.watch(tp.terminalProvider);
    // chatProvider 只在这里贡献 error；不要 watch 整个状态，否则每个终端
    // 输出 chunk 都会让整页（终端 + 所有 tab + AI 面板）重建。
    final chatError = ref.watch(chatProvider.select((s) => s.error));
    // 只订阅低频字段：流式 chatItems/liveReasoning/lastMessage 每个 chunk 都在变，
    // 若全量 watch，整页（含所有 Offstage tab 工作区）每秒重建 10~15 次。
    // 高频部分由活动 tab 的 AI 面板 Consumer 局部订阅（见 _buildMainBody）。
    ref.watch(agentProvider.select((s) => (
          s.status,
          s.error,
          s.isCompacting,
          s.goal,
          s.permissionMode,
          s.isWebSearchEnabled,
          s.isOrchestratorMode,
          s.pendingConfirmCommand,
          s.pendingOptions,
          s.hostId,
          s.conversationId,
          s.summary,
          s.chatItems.length,
        )));
    final agentState = ref.read(agentProvider);
    final activeTab = terminalState.activeTab;

    final tc = ThemeColors.of(context);

    // 手机端：根据屏幕方向自动设置 AI 面板位置
    _updateMobilePositionForActive();

    // ref.listen 必须在 build 中无条件调用，否则面板收起时 listener 消失会触发 assertion
    // 只跟随聊天内容长度/流式文本变化滚动；终端输出更新 lastCommandOutput 时不再打断滚动
    ref.listen<(String?, int)>(
      chatProvider.select(
          (s) => (s.currentAssistantMessage, s.messages.length)),
      (_, __) => _scrollChatToBottom(),
    );
    ref.listen(agentProvider, (_, state) {
      if (state.chatItems.isNotEmpty) {
        _scrollChatToBottom();
      }
    });
    // 设置页改了端点/模型后同步当前 host；运行中延后到任务结束，
    // 避免保存配置顺手把正在跑的任务取消掉。
    ref.listen<List<AIEndpoint>>(aiEndpointsProvider, (_, __) {
      _scheduleModelSync();
    });
    ref.listen<AgentState>(agentProvider, (prev, next) {
      // paused / waitingConfirm 也算“任务未结束”。只比较 isRunning 会把
      // 暂停当成结束，在任务仍持有引擎时同步模型并把它取消。
      if (_pendingModelSync &&
          _agentStateBusy(prev) &&
          !_agentStateBusy(next)) {
        _scheduleModelSync();
      }
    });
    // tab 对象在 provider 里原地复用，prev/next state 拿到的是同一实例，
    // 无法靠比较 prev/next 得到状态迁移，用 _lastTabStatus 自己记上一帧的值。
    ref.listen<tp.TerminalState>(tp.terminalProvider, (prev, next) {
      for (final tab in next.tabs) {
        final oldStatus = _lastTabStatus[tab.id];
        _lastTabStatus[tab.id] = tab.status;
        if (!tab.isLocal &&
            oldStatus != tp.TabStatus.connected &&
            tab.status == tp.TabStatus.connected) {
          // 重连成功：掉线时作废的额外 pane 补开回来（用户重连的意图就是
          // 「继续用这一套终端」，不该还要他逐屏点一次）
          _reopenPaneSessions(tab);
        }
        if (!tab.isLocal &&
            oldStatus == tp.TabStatus.connected &&
            tab.status == tp.TabStatus.lost) {
          // 额外 pane 的 shell 挂在同一个 client 上，掉线即作废（先清后重连，
          // 否则重连补开了新 client，旧 pane 还握着已关闭的会话）
          _invalidatePaneSessions(tab.id);
          _maybeAutoReconnect(tab);
        }
      }
      _lastTabStatus.removeWhere((id, _) => !next.tabs.any((t) => t.id == id));
      // 兜底：标签在别处被关掉时，额外 pane 的会话也要跟着收
      _tabPaneLayout.removeWhere((id, layout) {
        if (next.tabs.any((t) => t.id == id)) return false;
        for (final paneId in layout.paneIds) {
          if (paneId != id) _disposePane(paneId);
        }
        return true;
      });
    });

    return Scaffold(
      backgroundColor: tc.bg,
      resizeToAvoidBottomInset: true,
      // Ctrl+K / ⌘K 命令面板：挂在页面级 Shortcuts 上，终端焦点节点未消费的
      // 按键会冒泡到这里（keymap 默认可重绑表里没有 K，不抢 shell 的键）。
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _showCommandPalette,
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              _showCommandPalette,
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          child: Column(
            children: [
              // 顶部栏（标签 + 工具）
              _buildTopBar(host, terminalState, activeTab),

              // 每个 tab 一棵常驻工作区；切换只改 Offstage，不销毁/重建
              Expanded(
                child: _buildTabWorkspaces(
                    chatError, agentState, terminalState, activeTab),
              ),

              // 快捷按键行（仅 Android / iOS 显示，桌面端不需要）
              // 当 AI 输入框获焦（键盘弹出）时隐藏快捷按键栏，节省空间
              if (Platform.isAndroid || Platform.isIOS && !_aiInputFocused)
                _buildQuickKeysBar(activeTab),
            ],
          ),
        ),
      ),
    );
  }

  /// 每个 tab 一棵常驻工作区。
  ///
  /// 用 Offstage 而不是只渲染 active tab：终端滚动、Agent 消息的展开状态、
  /// 监控历史都由各自的 widget/服务持有，切 tab 不能被重建。非活跃 tab
  /// 停止动画并排除焦点，但输出/采样继续写自己的缓冲。
  Widget _buildTabWorkspaces(
    String? chatError,
    AgentState activeAgentState,
    tp.TerminalState terminalState,
    tp.TerminalTab? activeTab,
  ) {
    final tabs = terminalState.tabs;
    if (tabs.isEmpty) {
      return _buildMainBody(
          chatError, activeAgentState, null, isActive: true);
    }
    final notifier = ref.read(agentProvider.notifier);
    final activeId = activeTab?.id;
    for (final tab in tabs) {
      // 兜底：从 provider 恢复出来的历史 tab 可能还没在页面里建过 Terminal/布局快照
      _initTabPanelState(tab);
      _ensureTabTerminal(tab);
    }
    if (activeTab != null) {
      _terminal = _tabTerminals[activeTab.id] ?? _terminal;
    }
    _clearSftpOnLocalTab();
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final tab in tabs)
          Offstage(
            offstage: tab.id != activeId,
            child: ExcludeFocus(
              excluding: tab.id != activeId,
              child: TickerMode(
                enabled: tab.id == activeId,
                child: KeyedSubtree(
                  key: ValueKey('tab-workspace-${tab.id}'),
                  child: _buildMainBody(
                    chatError,
                    tab.id == activeId
                        ? activeAgentState
                        : notifier.stateForScope(tab.id, hostId: tab.hostId),
                    tab,
                    isActive: tab.id == activeId,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 主体区域：终端 + AI 面板 + SFTP 侧面板，根据面板位置切换布局
  Widget _buildMainBody(String? chatError, AgentState agentState,
      tp.TerminalTab? tab, {required bool isActive}) {

    // 终端视图。主区渲染只看活动标签自己的连接阶段：页面级不再留一份
    // "连接中"副本，否则顶栏指向新标签、画面还停在旧标签。
    final placeholder = _buildConnectionPlaceholder(tab);

    final terminalView = Stack(
      children: [
        // 分屏时这里是一整块平铺区（每屏一条会话）；未分屏就是单屏。
        // tab == null（还没有任何标签）时保留一份裸终端，只为让过渡态有底色。
        tab == null
            ? term_widget.TerminalView(
                terminal: _terminal,
                fontSize: _terminalFontSize,
                paletteId: ref.watch(
                    settingsProvider.select((s) => s['terminalPalette'] as String?)),
                keymap: TerminalKeymap.fromSettings(ref.watch(
                    settingsProvider.select((s) => s['terminalKeybindings']))),
                active: isActive,
                isLocal: true,
                onCommandPalette: _showCommandPalette,
              )
            : _buildTerminalArea(tab, isActive: isActive),
        // AnimatedSwitcher 常驻：让它从"过渡/错误视图"切回空占位，
        // 连接成功时才有淡出动画（整个开关被移除的话是直接消失）
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: placeholder ?? const SizedBox.shrink(),
          ),
        ),
        if (tab != null &&
            (tab.status == tp.TabStatus.reconnecting || tab.status == tp.TabStatus.lost))
          Positioned(
            top: 8,
            right: 8,
            child: _buildDisconnectedChip(tab),
          ),
      ],
    );

    // 监控面板包装：在终端下方插入监控横幅（仅在已连接且该 host 开关开启时）
    final monitorService = _getOrCreateMonitorService(tab);
    final showMonitor = tab != null &&
        !_isFocusModeFor(tab.id) &&
        _monitorVisibleFor(tab) &&
        monitorService != null;
    final terminalArea = showMonitor
        ? Column(
            children: [
              Expanded(child: terminalView),
              ServerMonitorPanel(service: monitorService),
            ],
          )
        : terminalView;

    // SFTP 与 AI 正交：AI 占右列 → SFTP 挂终端列下方；AI 在底/悬浮/收起 →
    // SFTP 挂右侧列。挂载点必须在选择 AI 方位的分支**内侧**，否则底部态的
    // SFTP 会横铺整屏、把 AI 一起顶上去。
    final showSftp = _sftpVisibleFor(tab);

    // P0-1: AI 面板支持完全收起 + 移动端上滑手势展开
    Widget mainContent;
    if (!_effectiveAiVisible(tab?.id)) {
      // AI 面板收起状态：终端占满全屏，移动端支持上滑展开 AI 面板
      final bareTerminal = _isMobile
          ? GestureDetector(
              onVerticalDragEnd: (details) {
                // 上滑速度超过阈值时展开 AI 面板
                if (details.primaryVelocity != null && details.primaryVelocity! < -300) {
                  setState(() => _setAiPanelVisible(tab?.id, true));
                }
              },
              child: terminalArea,
            )
          : terminalArea;
      mainContent = showSftp && tab != null
          ? _withSftpRight(bareTerminal, tab, active: isActive)
          : bareTerminal;
    } else {
      // AI 面板展开状态：保持现有分栏布局
      mainContent = LayoutBuilder(builder: (context, constraints) {
        final totalW = constraints.maxWidth;
        final totalH = constraints.maxHeight;
        final position = _aiPanelPositionFor(tab?.id);
        // 设计稿「窄窗口自动上下堆叠」：窗口放不下「80 列终端 + 240px 面板」时，
        // 右侧分栏自动退回底部，否则终端会被硬挤到 80 列以下（vim/htop 先坏）。
        // 只影响本次渲染，不改用户存下来的方位偏好。
        final tooNarrowForRight = totalW <
            minTerminalWidthForFontSize(_terminalFontSize) + 240 + 20;
        final isRight =
            position == _AiPanelPosition.right && !tooNarrowForRight;
        // 非底部态的 SFTP（右列）挂在分栏结果外侧。
        Widget sftpCol(Widget content) => showSftp && tab != null
            ? _withSftpRight(content, tab, active: isActive)
            : content;

        void onDrag(DragUpdateDetails details) {
          final box = context.findRenderObject() as RenderBox;
          final origin = box.localToGlobal(Offset.zero);
          // 直接记像素宽度：拖到哪就是哪，不再折成比例 —— 比例会随窗口大小
          // 漂移，而设计稿这一列是固定宽度。
          final extent = isRight ? totalW : totalH;
          final raw = isRight
              ? totalW - (details.globalPosition.dx - origin.dx)
              : totalH - (details.globalPosition.dy - origin.dy);
          final px = raw
              .clamp(240.0, extent * _maxPanelRatio)
              .toDouble();
          setState(() {
            if (tab != null) _tabAiPanelWidth[tab.id] = px;
            _defaultAiPanelWidth = px;
          });
        }

        final tc = ThemeColors.of(context);
        // 手机端不显示拖拽手柄
        final dragHandle = _isMobile
            ? (isRight ? const SizedBox.shrink() : GestureDetector(
                // 移动端底部布局：可拖拽调整高度的手柄
                onPanUpdate: onDrag,
                onPanEnd: (_) => _savePanelLayout(savePosition: false),
                child: Container(
                  height: 20,
                  width: double.infinity,
                  color: Colors.transparent,
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: tc.textMuted.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ))
            : GestureDetector(
              onPanUpdate: onDrag,
              onPanEnd: (_) => _savePanelLayout(savePosition: false),
              child: MouseRegion(
                cursor: isRight ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
                // 设计稿在终端与面板之间只有一条 1px 发丝线（rgba(255,255,255,.12)）。
                // 这里把「能拖动的热区」与「看得见的线」分开：热区仍是 5px
                // （太窄就拖不住），可见部分收成居中 1px —— 之前整块 5px 都填
                // 了 60% 白，在两张深色面板之间像一条亮缝，是画面最脏的地方。
                child: SizedBox(
                  width: isRight ? 5 : double.infinity,
                  height: isRight ? double.infinity : 5,
                  child: Center(
                    child: Container(
                      width: isRight ? 1 : double.infinity,
                      height: isRight ? double.infinity : 1,
                      color: tc.border,
                    ),
                  ),
                ),
              ),
            );

        // 80 列保护：横向分栏时终端一侧不得被面板挤到 80 列以下。
        // 悬浮态（仅桌面）不占布局宽度，终端永远全宽，但面板取宽度比例。
        final overlayActive =
            position == _AiPanelPosition.overlay && !_isMobile;
        // 像素宽度 → 本次容器的比例。默认 320（设计稿固定列宽），
        // 拖过分隔条就用手动值；240px 下限同样换算成比例交给同一条 clamp。
        final panelExtent = isRight || overlayActive ? totalW : totalH;
        final wantWidth = _aiPanelWidthFor(tab?.id) ?? _kAiPanelDefaultWidth;
        final ratio =
            panelExtent > 0 ? (wantWidth / panelExtent).clamp(0.0, 1.0) : 0.25;
        final minRatio = panelExtent > 0
            ? (240.0 / panelExtent).clamp(0.0, 1.0)
            : _minPanelRatio;
        final aiPanelSize = aiPanelSizeFor(
          totalExtent: panelExtent,
          ratio: ratio,
          enforce80Cols: isRight,
          fontSize: _terminalFontSize,
          minRatio: minRatio,
          maxRatio: _maxPanelRatio,
        );
        // 活动 tab 的 AI 面板局部订阅完整 agent 状态：流式高频更新只重建
        // 这棵子树，不再带动整页和其他 tab 工作区。非活动 tab 用页面传入的
        // 快照（Offstage 不可见，切回时页面重建会刷新）。
        final aiContent = isActive
            ? Consumer(builder: (_, ref, __) {
                final liveState = ref.watch(agentProvider);
                return Column(
                  children: [
                    Expanded(child: _buildAIPanel(chatError, liveState, tab)),
                    _buildBottomBar(liveState, tab),
                  ],
                );
              })
            : Column(
                children: [
                  Expanded(child: _buildAIPanel(chatError, agentState, tab)),
                  _buildBottomBar(agentState, tab),
                ],
              );

        if (position == _AiPanelPosition.overlay && !_isMobile) {
          // 悬浮态：终端全宽，AI 浮在右上不占布局。SFTP 判定也按
          // 「AI 没占宽度」走右侧列（见 _withSftpRight）。
          // 设计稿 .shell.m-overlay .ai-panel：absolute top52 / right10、
          // 宽 min(320, 88%)、12 圆角 + 四向扩散投影 —— 是一张浮起的卡片，
          // 不是通高贴边的抽屉。之前 top/bottom/right 全 0 拉满高度，视觉上
          // 仍像分栏，只是把分隔线盖住了而已。
          return sftpCol(Stack(
            fit: StackFit.expand,
            children: [
              terminalArea,
              Positioned(
                right: 10,
                top: 4,
                bottom: 10,
                child: SizedBox(
                  width: math.min(aiPanelSize, constraints.maxWidth * 0.88),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: tc.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 32,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: aiContent,
                    ),
                  ),
                ),
              ),
            ],
          ));
        }

        if (isRight) {
          // AI 占右列 → SFTP 只能在终端列的下方（设计稿 "center ai"/"sftp ai"）。
          final terminalColumn = showSftp && tab != null
              ? _withSftpBottom(terminalArea, tab, active: isActive)
              : terminalArea;
          return Row(
            children: [
              Expanded(child: terminalColumn),
              dragHandle,
              SizedBox(width: aiPanelSize, child: aiContent),
            ],
          );
        } else {
          // 底部布局：移动端 AI 面板顶部添加下滑收起手势
          Widget aiPanelWithSwipe = _isMobile
              ? GestureDetector(
                  onVerticalDragEnd: (details) {
                    // 下滑速度超过阈值时收起 AI 面板
                    if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
                      setState(() => _setAiPanelVisible(tab?.id, false));
                    }
                  },
                  child: SizedBox(height: aiPanelSize, child: aiContent),
                )
              : SizedBox(height: aiPanelSize, child: aiContent);

          return sftpCol(Column(
            children: [
              Expanded(child: terminalArea),
              dragHandle,
              aiPanelWithSwipe,
            ],
          ));
        }
      });
    }

    return mainContent;
  }

  /// 某个 tab 的内嵌 SFTP 面板。
  ///
  /// 保活由各 tab 工作区外层的 Offstage 负责（切 tab 只隐藏不销毁），
  /// 所以这里不再需要多 tab 共享一个 Stack。key 带上初始目录，
  /// 「在 SFTP 中定位」换目录时让面板按新目录重新加载。
  Widget _buildTabSftpPanel(tp.TerminalTab tab, {required bool active}) {
    return SftpPanel(
      key: ValueKey(
          'sftp-${tab.id}-${tab.hostId}-${_tabSftpInitialPath[tab.id] ?? ''}'),
      hostId: tab.hostId,
      embedded: true,
      dropEnabled: active,
      initialPath: _tabSftpInitialPath[tab.id],
      onClose: () => setState(() {
        _tabSftpVisible[tab.id] = false;
        // 关闭后清掉定位目标，下次从默认目录打开
        _tabSftpInitialPath.remove(tab.id);
      }),
    );
  }

  /// SFTP 是否应该显示在该 tab 上（专注模式只压制显示，状态与高度保留）。
  bool _sftpVisibleFor(tp.TerminalTab? tab) =>
      tab != null &&
      !_isMobile &&
      !tab.isLocal &&
      (_tabSftpVisible[tab.id] ?? false) &&
      !_isFocusModeFor(tab.id);

  /// 「终端列 + 底部 SFTP」—— 设计稿 `.shell.sftp-on.sftp-bottom` 的
  /// `"center ai" / "sftp ai"`：SFTP 只吃终端列的下方，AI 保持通高右列。
  /// 包在「终端+AI」外层会横铺整屏把 AI 顶上去，那是错的挂载点。
  Widget _withSftpBottom(Widget terminalColumn, tp.TerminalTab tab,
      {required bool active}) {
    final tc = ThemeColors.of(context);
    return Column(
      children: [
        Expanded(child: terminalColumn),
        // SFTP 拖拽调整高度手柄
        GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              _sftpPanelHeight -= details.delta.dy;
              _sftpPanelHeight = _sftpPanelHeight
                  .clamp(_minSftpHeight, _maxSftpHeight)
                  .toDouble();
            });
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeRow,
            child: Container(
              height: 4,
              color: tc.border.withValues(alpha: 0.6),
            ),
          ),
        ),
        SizedBox(
            height: _sftpPanelHeight,
            child: _buildTabSftpPanel(tab, active: active)),
      ],
    );
  }

  /// 「内容 + 右列 SFTP」—— AI 在底/悬浮/收起时 SFTP 走右侧列，
  /// 与 AI 永远不在同一根轴上抢空间。
  Widget _withSftpRight(Widget content, tp.TerminalTab tab,
      {required bool active}) {
    final tc = ThemeColors.of(context);
    return Row(
      children: [
        Expanded(child: content),
        // SFTP 拖拽调整宽度手柄
        GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              _sftpPanelWidth -= details.delta.dx;
              _sftpPanelWidth =
                  _sftpPanelWidth.clamp(_minSftpWidth, _maxSftpWidth);
            });
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: Container(
              width: 4,
              color: tc.border.withValues(alpha: 0.6),
            ),
          ),
        ),
        SizedBox(
            width: _sftpPanelWidth, child: _buildTabSftpPanel(tab, active: active)),
      ],
    );
  }

  /// 切到本地终端时清掉该 tab 的 SFTP 面板（本地没有远端文件系统可看）。
  void _clearSftpOnLocalTab() {
    if (_isMobile) return;
    final currentTabId = ref.read(tp.terminalProvider).activeTabId;
    if (currentTabId == null) return;
    final activeTab = ref.read(tp.terminalProvider).activeTab;
    if (activeTab == null ||
        !activeTab.isLocal ||
        !(_tabSftpVisible[currentTabId] ?? false)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _tabSftpVisible[currentTabId] = false);
    });
  }

  // ==================== 顶部栏 ====================
  /// 三段式结构：标签区（+ 号紧贴标签）/ 弹性空白 / 右侧操作区
  Widget _buildTopBar(dynamic host, tp.TerminalState terminalState, tp.TerminalTab? activeTab) {
    final tc = ThemeColors.of(context);
    return Container(
      // 设计稿 .topbar：42px 高、左右 8px 内边距，控件统一 32px 见方。
      // 比原来的 48px 更贴终端类应用的密度，也让 32px 的标签/按钮上下各留 5px。
      height: _kTopBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: tc.bg,
        border: Border(bottom: BorderSide(color: tc.border, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左侧不再放 LOGO + 应用名：终端窗口标题栏已经写着应用名，
          // 这里再占一块只会挤走标签区。需要回主页用左侧标签或快捷键。
          // 标签区 + 末尾 "+"，整段 Expanded 吃掉左侧全部剩余宽度。
          //
          // 之前是 Flexible(ListView) 与 Spacer 两个弹性兄弟：RenderFlex 把
          // 剩余宽度对半分，标签条实际只画 70px 却占掉一半且不回收，右侧动作
          // 组因此停在窗口 70% 处（1267 宽的窗口实测停在 x=898）。窗口越宽，
          // 动作组离右边缘越远。改成单个 Expanded 后空白全部落在标签右侧，
          // "+" 仍是列表最后一项（紧贴最后一个标签），动作组贴住右边缘。
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              // 42 高顶栏里给 32px 的标签/加号留 5px 上下留白（设计稿同值）
              padding: const EdgeInsets.symmetric(vertical: 5),
              itemCount: terminalState.tabs.length + 1,
              itemBuilder: (context, index) {
                if (index == terminalState.tabs.length) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    heightFactor: 1.0,
                    child: _buildAddTabButton(),
                  );
                }
                final tab = terminalState.tabs[index];
                final isActive = tab.id == terminalState.activeTabId;
                return Align(
                  alignment: Alignment.centerLeft,
                  heightFactor: 1.0,
                  child: _buildTabItem(tab, isActive, terminalState),
                );
              },
            ),
          ),
          // 命令面板入口（零占位导航的常驻把手）
          _buildCommandPaletteButton(),
          const SizedBox(width: 4),
          // 右侧操作区：设计稿这里只有 5 个 32px 图标（菜单 / AI / SFTP / 监控），
          // 之前还塞了专注模式与字号，8 个图标连成一排占掉顶栏 37% 的宽度，
          // 视觉上比标签区还抢眼。专注模式在网格菜单里已有入口，字号归到
          // 顶栏外观浮层，这里只留全局开关。
          _buildTopBarActions(),
        ],
      ),
    );
  }

  /// 命令面板按钮（Ctrl+K 的可视化入口）
  Widget _buildCommandPaletteButton() {
    final tc = ThemeColors.of(context);
    return Tooltip(
      message: UiText.t('命令面板 (Ctrl+K)', 'Command palette (Ctrl+K)'),
      waitDuration: const Duration(milliseconds: 500),
      child: GestureDetector(
        onTap: _showCommandPalette,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          // 设计稿 .pal-btn：透底 + 12% 描边（不填 surface，顶栏上更轻），
          // 键帽单独成盒：muted 字、surface 底、下沿加粗。
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: tc.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_rounded, size: 13, color: tc.textSub),
              if (MediaQuery.of(context).size.width > 720) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.fromLTRB(5, 1, 5, 0),
                  decoration: BoxDecoration(
                    color: tc.surface,
                    borderRadius: BorderRadius.circular(5),
                    border: Border(
                      top: BorderSide(color: tc.border),
                      left: BorderSide(color: tc.border),
                      right: BorderSide(color: tc.border),
                      bottom: BorderSide(color: tc.border, width: 2),
                    ),
                  ),
                  child: Text('Ctrl K',
                      style: TextStyle(
                          fontSize: fMicro,
                          color: tc.textMuted,
                          fontFamily: 'JetBrainsMono',
                          fontFamilyFallback: kMonoFontFallback)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 右侧常驻动作区。
  ///
  /// 分成三层，顺序就是「碰到的频率」：
  /// 1. **外观**（主题 / 配色 / 字号）—— 用户要挨个切过去看效果的，必须一次点击到，
  ///    并且浮层里带一块按当前配色渲染的终端预览。以前它埋在「更多 → 终端字号
  ///    ／配色 → 另一个页面」三层里，只给八个配色名字，没人能靠想象选色。
  /// 2. **AI / SFTP / 监控** —— 面板开关，点一下布局就变。
  /// 3. **菜单** —— 去处置信和会话级操作，贴最右（平台惯例：溢出项在最外侧）。
  ///
  /// 以前这里是两个平级菜单（四宫格「功能菜单」+ ⋯「更多」），SFTP 和监控在两个
  /// 菜单里各有一份，设置也有两个入口 —— 用户不知道点哪个、也不知道点了会有什么
  /// 区别。现在只剩一个菜单，而且菜单里**不再出现顶栏已有的开关**。
  Widget _buildTopBarActions() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildAppearanceButton(),
        const SizedBox(width: 4),
        _buildAIPanelToggleButton(),
        const SizedBox(width: 4),
        // SFTP 常驻开关（设计稿右侧动作组：菜单 / AI / SFTP / 监控）
        _buildSftpToggleButton(),
        const SizedBox(width: 4),
        _buildMonitorToggleButton(),
        const SizedBox(width: 4),
        _buildGridMenuButton(),
      ],
    );
  }

  /// 顶栏「外观」：主题 + 配色 + 字号就地改，浮层里带实时预览。
  Widget _buildAppearanceButton() {
    final tc = ThemeColors.of(context);
    return MenuAnchor(
      controller: _appearanceMenu,
      // 按钮贴着右边缘，菜单要往左展开，否则会顶出窗口
      style: MenuStyle(
        alignment: AlignmentDirectional.bottomEnd,
        backgroundColor: WidgetStatePropertyAll(tc.cardElevated),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        elevation: const WidgetStatePropertyAll(12),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rMedium),
            side: BorderSide(color: tc.border),
          ),
        ),
      ),
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        TerminalAppearancePanel(
          onMore: () {
            _appearanceMenu.close();
            // 进设置抽屉的「终端」组（回滚缓冲 / 会话日志 / 快捷键），
            // 就地改 —— 不跳整页。
            _showNavDrawer(NavDrawer.sectionSettings, group: 'terminal');
          },
        ),
      ],
      builder: (context, controller, child) => _buildTopAct(
        icon: Icons.palette_outlined,
        tooltip: UiText.t('终端配色与字号', 'Terminal colors & font size'),
        active: controller.isOpen,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  /// 抽屉入口：功能板块全部覆盖在终端之上，终端尺寸一寸不让。
  ///
  /// [group] 是设置分区里要直接摊开的那一组 —— 配色浮层的「更多」用它，
  /// 不再 push 一个整页设置出来。
  void _showNavDrawer(String section, {String? group}) {
    NavDrawer.show(
      context,
      section: section,
      initialGroup: group,
      onOpenHost: _openHostTab,
      onRunSnippet: _executeSnippet,
      onRunRunbook: _runRunbook,
    );
  }

  /// 唯一的溢出菜单：**去处置信** + **本终端能做的事**。
  ///
  /// 顶栏已有的开关（AI / SFTP / 监控 / 配色 / 字号）绝不在这里出现第二遍 ——
  /// 同一件事两个入口，用户只能靠记；记不住的就会点错，点错了就烦。
  /// 这里的项都是「点一次跳走或做完」，不存在需要先展开再选的两级结构。
  Widget _buildGridMenuButton() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final activeTab = ref.read(tp.terminalProvider).activeTab;
    final snippets = SnippetsDao.cached.toList();
    final auditToday = AuditLogsDao.getCachedRecentLogs(limit: 200)
        .where((l) => _isToday(l['timestamp'] as String?))
        .length;
    // 只给「菜单里会显示计数」的三项备读数。快捷命令 / 工作流已从菜单移出
    // （抽屉标签一键可达，且它们各自的内容已经在菜单下方有更直接的入口），
    // 留着 key 只会变成没人读的死数据。
    final counts = <String, String>{
      'drawer:${NavDrawer.sectionHosts}': '${HostsDao.cached.length} 台',
      'drawer:${NavDrawer.sectionAudit}': '今日 $auditToday 条',
      // 组数跟着 kSettingsEntries 走：写死「8 组」的话，以后加一组就悄悄错了。
      'drawer:${NavDrawer.sectionSettings}': '${kSettingsEntries.length} 组',
    };
    return PopupMenuButton<String>(
      tooltip: UiText.t('菜单', 'Menu'),
      color: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      offset: const Offset(0, 36),
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 320),
      // 设计稿 .top-act 是 32px 见方；PopupMenuButton 走 IconButton，默认 48
      // 的点击区会把 42px 顶栏撑开，这里压回 32。
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(Icons.more_horiz, color: tc.textSub, size: 20),
      onSelected: (value) async {
        if (value.startsWith('drawer:')) {
          _showNavDrawer(value.substring(7));
          return;
        }
        if (value.startsWith('page:')) {
          // 台账 / 变更窗口是独立工作区（整页表格与规则编辑），不是抽屉分区。
          context.push(value.substring(5));
          return;
        }
        if (value.startsWith('snippet:')) {
          final snippet = SnippetsDao.getCachedById(value.substring(8));
          if (snippet != null) _executeSnippet(snippet);
          return;
        }
        switch (value) {
          case 'act:focus':
            _toggleFocusMode();
            break;
          case 'act:cycle':
            _cycleAiPanelPosition();
            break;
          case 'act:reconnect':
            await _reconnect();
            break;
          case 'act:clear':
            _terminal?.write('\x1b[2J\x1b[H');
            break;
          case 'act:history':
            _showCommandHistory();
            break;
          case 'act:portforward':
            _showPortForwardDialog();
            break;
        }
      },
      itemBuilder: (context) => [
        // 前往组只留「菜单是唯一入口」或「带状态读数」的项。
        // 快捷命令 / 运维工作流不在这里：抽屉顶部标签一键可达，工作流底部面板
        // 也有自己的「管理」按钮指向同一个分区 —— 同一目的地三条路径，用户
        // 只能靠记。菜单省下来的两条高度让「本终端」组进得了首屏。
        _menuGroupLabel(tc, UiText.t('前往', 'Go to')),
        _gridMenuItem('drawer:${NavDrawer.sectionHosts}', Icons.dns_outlined,
            UiText.t('主机管理', 'Hosts'), trailing: counts['drawer:${NavDrawer.sectionHosts}']),
        _gridMenuItem('drawer:${NavDrawer.sectionAudit}', Icons.history_rounded,
            UiText.t('审计日志', 'Audit log'), trailing: counts['drawer:${NavDrawer.sectionAudit}']),
        _gridMenuItem('drawer:${NavDrawer.sectionSettings}',
            Icons.tune_rounded, UiText.t('设置', 'Settings'),
            trailing: counts['drawer:${NavDrawer.sectionSettings}']),
        _gridMenuItem('page:/change-records', Icons.fact_check_outlined,
            UiText.t('变更台账', 'Change records')),
        _gridMenuItem('page:/change-window', Icons.schedule_outlined,
            UiText.t('变更窗口', 'Change window')),

        const PopupMenuDivider(height: 8),
        _menuGroupLabel(tc, UiText.t('本终端', 'This terminal')),
        _gridMenuItem('act:reconnect', Icons.refresh_rounded, l10n.terminalReconnect),
        // 本地终端既没有可转发的 SSH 通道，点了必然失败，不如不出现
        if (activeTab != null && !activeTab.isLocal)
          _gridMenuItem('act:portforward', Icons.swap_horiz_rounded,
              UiText.t('端口转发', 'Port forwarding')),
        _gridMenuItem('act:history', Icons.history_rounded,
            '${UiText.t('命令历史', 'Command history')}  (Ctrl+Shift+H)'),
        // 移动端没有右键菜单，清屏只能留在这里
        if (_isMobile)
          _gridMenuItem('act:clear', Icons.cleaning_services_rounded,
              l10n.terminalClearScreen),
        if (snippets.isNotEmpty) ...[
          const PopupMenuDivider(height: 8),
          _menuGroupLabel(tc, l10n.quickCommands),
          ...snippets.take(5).map(
              (s) => _gridMenuItem('snippet:${s.id}', Icons.terminal, s.name)),
        ],

        const PopupMenuDivider(height: 8),
        _menuGroupLabel(tc, UiText.t('视图', 'View')),
        _gridMenuItem('act:focus', Icons.fullscreen_rounded,
            UiText.t('专注模式', 'Focus mode'),
            trailing: UiText.t('终端全宽', 'Terminal only')),
        if (activeTab != null)
          _gridMenuItem('act:cycle', Icons.view_sidebar_outlined,
              UiText.t('切换 AI 面板位置', 'Cycle AI panel position'),
              trailing: UiText.t('右 / 底 / 悬浮', 'right / bottom / float')),
      ],
    );
  }

  PopupMenuItem<String> _menuGroupLabel(ThemeColors tc, String label) {
    return PopupMenuItem<String>(
      enabled: false,
      height: 26,
      child: Text(label,
          style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
    );
  }

  PopupMenuItem<String> _gridMenuItem(String value, IconData icon, String label,
      {String? trailing}) {
    final tc = ThemeColors.of(context);
    return PopupMenuItem<String>(
      value: value,
      height: 38,
      child: Row(
        children: [
          Icon(icon, size: 14, color: tc.textSub),
          const SizedBox(width: 9),
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: fSmall, color: tc.textMain)),
          ),
          if (trailing != null)
            Text(trailing,
                style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
        ],
      ),
    );
  }

  static bool _isToday(String? rawIso) {
    final t = rawIso == null ? null : DateTime.tryParse(rawIso);
    if (t == null) return false;
    final local = t.toLocal();
    final now = DateTime.now();
    return local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
  }

  /// 右栏 → 底部 → 悬浮 循环（移动端没有悬浮，跳过）
  void _cycleAiPanelPosition() {
    final tab = ref.read(tp.terminalProvider).activeTab;
    final tabId = tab?.id;
    final next = switch (_aiPanelPositionFor(tabId)) {
      _AiPanelPosition.right => _AiPanelPosition.bottom,
      _AiPanelPosition.bottom =>
        _isMobile ? _AiPanelPosition.right : _AiPanelPosition.overlay,
      _AiPanelPosition.overlay => _AiPanelPosition.right,
    };
    setState(() {
      _setAiPanelPosition(tabId, next);
      // 切到某个方位即视为想用它：悬浮/分栏都直接展开，避免「点了没反应」。
      if (!_isFocusModeFor(tabId)) _setAiPanelVisible(tabId, true);
    });
  }

  /// 顶栏 SFTP 开关：移动端没有桌面分栏，跳整页。
  void _toggleSftpPanel() {
    final tab = ref.read(tp.terminalProvider).activeTab;
    if (tab == null || tab.isLocal) return;
    if (_isMobile) {
      context.push('/sftp/${tab.hostId}');
      return;
    }
    setState(
        () => _tabSftpVisible[tab.id] = !(_tabSftpVisible[tab.id] ?? false));
  }

  /// 单个 Tab 项（连接名称 + 关闭x）— 使用独立 widget 避免 hover 触发整页 rebuild
  Widget _buildTabItem(tp.TerminalTab tab, bool isActive, tp.TerminalState terminalState) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return TabItemWidget(
      tab: tab,
      isActive: isActive,
      tc: tc,
      onTap: () {
        ref.read(tp.terminalProvider.notifier).setActiveTab(tab.id);
        _switchToTab(tab);
      },
      onClose: () async {
        // 小白用户误触关闭按钮时提示：如果正在运行任务，先确认
        final agentState = ref.read(agentProvider);
        // 编排模式运行中：编排可能涉及任意已连接 host，关闭任一 tab 都会
        // 让该 host 的 executor 变成陈旧引用，导致编排误报"未连接"。
        // 直接拦截，要求用户先等编排完成或取消编排。
        if (agentState.isOrchestratorMode && agentState.isRunning) {
          showTopSnackBar(context, 
            SnackBar(
              content: Text(l10n.orchAgentRunning),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        // 每个 tab 的 Agent 独立运行；关闭后台 tab 也可能取消它自己的任务
        final tabAgentRunning =
            ref.read(agentProvider.notifier).isRunningFor(tab.id);
        if (tabAgentRunning) {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(l10n.terminalTaskRunning),
              content: Text(l10n.terminalCloseTabConfirm),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.commonCancel)),
                TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.close)),
              ],
            ),
          );
          if (confirmed != true) return;
        }
        await _removeTab(tab);
      },
    );
  }

  /// 关闭标签并清理页面侧的 per-tab 状态（tab 项的 x 与连接失败视图共用）
  Future<void> _removeTab(tp.TerminalTab tab) async {
    ref.read(chatProvider.notifier).removeTab(tab.id);
    ref.read(agentProvider.notifier).removeTab(tab.id, hostId: tab.hostId);
    _tabAiInputText.remove(tab.id);
    _tabExecutingCommand.remove(tab.id);
    _tabExecutedCommands.remove(tab.id);
    _tabPendingConfirm.remove(tab.id);
    _tabTerminals.remove(tab.id);
    _tabCommandTrackers.remove(tab.id);
    _tabBlockTrackers.remove(tab.id)?.dispose();
    _disposeTabPanes(tab.id);
    _sessionRecorders.remove(tab.id)?.close();
    _portForwardServices.remove(tab.id)?.dispose();
    _tabOutputSubscriptions.remove(tab.id)?.cancel();
    _tabChatOutputSubscriptions.remove(tab.id)?.cancel();
    _discardChatOutput(tab.id);
    _discardTermWrite(tab.id);
    _chatScrollControllers.remove(tab.id)?.dispose();
    _tabShowScrollToBottom.remove(tab.id);
    _tabAutoScroll.remove(tab.id);
    _monitorServices.remove(tab.id)?.reset();
    _tabMonitorVisible.remove(tab.id);
    _tabAiPanelVisible.remove(tab.id);
    _tabAiPanelPosition.remove(tab.id);
    _tabAiPanelWidth.remove(tab.id);
    _tabSftpVisible.remove(tab.id);
    await ref.read(tp.terminalProvider.notifier).closeTab(tab.id);
    if (!mounted) return;
    final newActiveTab = ref.read(tp.terminalProvider).activeTab;
    if (newActiveTab != null) {
      _switchToTab(newActiveTab);
    }
    if (ref.read(tp.terminalProvider).tabs.isEmpty) {
      _connectLocalTerminal();
    }
  }

  /// "+" 新标签按钮
  Widget _buildAddTabButton() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: l10n.terminalNewConnection,
      child: GestureDetector(
        onTap: _showAddHostDialog,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: CustomPaint(
            // 设计稿 .tab-add：透底 + 虚线描边。虚线在视觉上天然读作
            // 「这里还缺一块」，比实线底更贴合“新建”语义。
            foregroundPainter:
                _DashedRoundedRectPainter(color: tc.border, radius: rSmall),
            child: SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: Icon(Icons.add, size: 14, color: tc.textSub),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// P0-1: AI 面板展开/收起按钮（只影响当前 tab）
  /// 顶栏动作按钮（设计稿 .top-act）：32px 见方、8px 圆角、纯图标。
  ///
  /// 为什么去掉文字标签：设计稿右侧动作组是「菜单 / AI / SFTP / 监控」四个
  /// 同尺寸图标，标签文字会把按钮撑成 60~70px 的胶囊，一排下来比标签区还宽。
  /// 语义交给图标 + 悬浮提示，激活态统一为「品牌青字 + 10% 青底 + 发丝边」。
  Widget _buildTopAct({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool active = false,
  }) {
    final tc = ThemeColors.of(context);
    final color = active
        ? tc.brand
        : (onTap == null ? tc.textMuted : tc.textSub);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: animFast,
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: active ? tc.brandBg : Colors.transparent,
            borderRadius: BorderRadius.circular(rSmall),
            // 开启态原来用 tc.border 描边，和 brandBg 底几乎同色，等于没有边界。
            // 换成 brand 色能让「已开」在 42px 深色顶栏上一眼可辨；但直接用
            // 实色 brand 会变成「亮底 + 亮边 + 亮图标」三重强调，廉价且抢标签区。
            // 取 45% 透明度：够勾勒形状，不至于发光。
            border: Border.all(
              color: active
                  ? tc.brand.withValues(alpha: 0.45)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Icon(icon, size: 15, color: color),
        ),
      ),
    );
  }

  Widget _buildAIPanelToggleButton() {
    final l10n = AppLocalizations.of(context)!;
    final tabId = ref.read(tp.terminalProvider).activeTab?.id;
    final visible = _effectiveAiVisible(tabId);

    return _buildTopAct(
      icon: visible ? Icons.auto_awesome : Icons.auto_awesome_outlined,
      tooltip: visible ? l10n.terminalCollapseAIPanel : l10n.terminalExpandAIPanel,
      active: visible,
      onTap: () => setState(() => _setAiPanelVisible(tabId, !visible)),
    );
  }


  /// SFTP 面板开关按钮。
  ///
  /// 设计稿把 SFTP 与 AI 并列成两个常驻开关：两者永远正交（AI 在右→SFTP 在下，
  /// AI 在下/悬浮/收起→SFTP 在右），所以入口必须一眼可见，不能只藏在网格菜单里。
  /// 本地终端没有远端文件系统，按钮置灰。
  Widget _buildSftpToggleButton() {
    final tab = ref.read(tp.terminalProvider).activeTab;
    final canShow = tab != null && !tab.isLocal;
    final on = tab != null && (_tabSftpVisible[tab.id] ?? false);
    return _buildTopAct(
      icon: on ? Icons.folder_rounded : Icons.folder_outlined,
      // 置灰了就得说清为什么 —— 一个点不动又不解释的按钮，用户只会反复点。
      // 也不在这里写「与 AI 正交」这类布局算法说明，用户不需要知道。
      tooltip: !canShow
          ? UiText.t('SFTP 仅远程会话可用', 'SFTP available on remote sessions only')
          : on
              ? UiText.t('关闭 SFTP 面板', 'Close SFTP panel')
              : UiText.t('SFTP 文件面板', 'SFTP file panel'),
      onTap: canShow ? _toggleSftpPanel : null,
      active: on,
    );
  }

  /// 服务器监控面板开关按钮（终端下方横幅，只影响当前 tab）
  Widget _buildMonitorToggleButton() {
    final activeTab = ref.read(tp.terminalProvider).activeTab;
    final canShow = activeTab != null && activeTab.isConnected;
    final isOn = activeTab != null && _monitorVisibleFor(activeTab);
    final l10n = AppLocalizations.of(context)!;

    return _buildTopAct(
      // 设计稿这一格是纯波形（activity），monitor_heart 带一个外框，
      // 缩到 15px 后和「面板」类图标糊在一起，认不出是监控。
      icon: Icons.show_chart_rounded,
      tooltip:
          isOn ? l10n.terminalCollapseMonitorPanel : l10n.terminalExpandMonitorPanel,
      active: isOn,
      onTap: canShow ? () {
          final tab = ref.read(tp.terminalProvider).activeTab;
          if (tab == null) return;
          final next = !_monitorVisibleFor(tab);
          final hostKey = tab.isLocal ? 'local' : tab.hostId;
          setState(() {
            _tabMonitorVisible[tab.id] = next;
            // 同步 host 默认值，供之后新开的 tab 继承；已有 tab 不受影响
            if (next) {
              _monitorDefaultVisibleHosts.add(hostKey);
            } else {
              _monitorDefaultVisibleHosts.remove(hostKey);
            }
          });
          SettingsDao.set(
              'monitorVisibleHosts', _monitorDefaultVisibleHosts.toList());
        } : null,
    );
  }

  /// 获取或创建当前 tab 对应的监控服务
  ServerMonitorService? _getOrCreateMonitorService(tp.TerminalTab? tab) {
    if (tab == null || !tab.isConnected) return null;
    final key = tab.id;
    var svc = _monitorServices[key];
    final executor = tab.isLocal ? tab.localService : tab.service;
    if (svc == null) {
      svc = ServerMonitorService(executor: executor, isLocal: tab.isLocal);
      _monitorServices[key] = svc;
    } else if (svc.executor != executor) {
      // 服务实例变了（重连），重置历史
      svc.reset();
      _monitorServices[key] =
          ServerMonitorService(executor: executor, isLocal: tab.isLocal);
      svc = _monitorServices[key]!;
    }
    return svc;
  }

  // ==================== 连接阶段视图 ====================

  /// 活动标签处于"终端还不存在"的阶段时返回覆盖层，其余阶段返回 null
  /// 重连中的标签走 null 分支，刚读到的输出不会因为重连而凭空消失
  Widget? _buildConnectionPlaceholder(tp.TerminalTab? tab) {
    if (tab == null) {
      final notice = _placeholderError;
      return notice != null ? _buildNoticeView(notice) : _buildConnectingView(null);
    }
    switch (tab.status) {
      case tp.TabStatus.connecting:
        return _buildConnectingView(tab);
      case tp.TabStatus.failed:
        return _buildTabErrorView(tab);
      case tp.TabStatus.connected:
      case tp.TabStatus.reconnecting:
      case tp.TabStatus.lost:
        return null;
    }
  }

  /// 过渡视图：标签注册后、底层建连返回前占住主区
  Widget _buildConnectingView(tp.TerminalTab? tab) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final hostId = tab?.hostId ?? widget.hostId;
    final host = (hostId == null || hostId == 'local')
        ? null
        : HostsDao.getCachedById(hostId);
    final name = tab?.title ?? host?.name ?? '';
    return Container(
      key: const ValueKey('tab-connecting'),
      // 与终端本体同一套配色，避免「切到 Dracula 后连接中闪一下内置底色」
      color: resolveTerminalTheme(
        paletteId: ref.watch(
            settingsProvider.select((s) => s['terminalPalette'] as String?)),
        isLight: tc.isLight,
      ).background,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24, height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: tc.brand),
          ),
          const SizedBox(height: 12),
          Text(l10n.terminalConnecting(name), style: TextStyle(color: tc.textSub, fontSize: fBody)),
          if (host != null) ...[
            const SizedBox(height: 4),
            Text(
              '${host.username}@${host.host}:${host.port}',
              style: TextStyle(color: tc.textMuted, fontSize: fMicro, fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback),
            ),
          ],
        ],
      ),
    );
  }

  /// 首连失败视图：整块占据主区，说明原因并给出重试/编辑/关闭出路
  Widget _buildTabErrorView(tp.TerminalTab tab) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: const ValueKey('tab-connect-failed'),
      color: tc.bg,
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_tethering_error_rounded, size: 40, color: tc.error),
              const SizedBox(height: 12),
              Text(
                '${l10n.connectionFailed} · ${tab.title}',
                style: TextStyle(color: tc.textSub, fontSize: fBody),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Flexible(
                // 底层异常可能很长，允许滚动和复制，别把它截成看不懂的半句
                child: SingleChildScrollView(
                  child: SelectableText(
                    tab.connectionError ?? l10n.connectionFailedHint,
                    style: TextStyle(color: tc.error, fontSize: fSmall),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: _reconnect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: tc.brand,
                      foregroundColor: tc.isLight ? Colors.white : cBg,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
                    ),
                    child: Text(l10n.retry, style: const TextStyle(fontSize: fBody)),
                  ),
                  OutlinedButton(
                    onPressed: () => context.push('/host/edit/${tab.hostId}'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: tc.textSub,
                      side: BorderSide(color: tc.border),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
                    ),
                    child: Text(l10n.edit, style: const TextStyle(fontSize: fBody)),
                  ),
                  OutlinedButton(
                    onPressed: () => _removeTab(tab),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: tc.textSub,
                      side: BorderSide(color: tc.border),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
                    ),
                    child: Text(l10n.close, style: const TextStyle(fontSize: fBody)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 无法归属到任何标签的提示（例如路由里的 hostId 已被删除）
  Widget _buildNoticeView(String message) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: const ValueKey('tab-notice'),
      color: tc.bg,
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: tc.error),
            const SizedBox(height: 12),
            Text(message, style: TextStyle(color: tc.error, fontSize: fSmall), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () {
                setState(() => _placeholderError = null);
                _connectLocalTerminal();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: tc.textSub,
                side: BorderSide(color: tc.border),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
              ),
              child: Text(l10n.commonBack, style: const TextStyle(fontSize: fBody)),
            ),
          ],
        ),
      ),
    );
  }

  /// 曾连接的标签处于断开/重连阶段时的角标（保留终端内容，只叠加提示）
  Widget _buildDisconnectedChip(tp.TerminalTab tab) {
    final l10n = AppLocalizations.of(context)!;
    final retrying = tab.status == tp.TabStatus.reconnecting;
    final color = retrying ? cWarning : cDanger;
    return GestureDetector(
      onTap: retrying ? null : _reconnect,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(rFull),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (retrying)
              SizedBox(
                width: 11, height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
              )
            else
              const Icon(Icons.warning_amber_rounded, color: cDanger, size: 12),
            const SizedBox(width: 4),
            Text(
              retrying ? l10n.connecting : l10n.connectionInterrupted,
              style: TextStyle(color: color, fontSize: fMicro, fontWeight: FontWeight.w500),
            ),
            if (!retrying) ...[
              const SizedBox(width: 4),
              Text(
                l10n.terminalReconnect,
                style: const TextStyle(
                  color: cDanger, fontSize: fMicro, fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Agent 面板的等待态：首连进行中或已失败时给出一句实话。
  /// 曾连接过的标签正在重连时返回 null —— 那会儿会话内容还在，值得留着看。
  Widget? _buildAgentWaitingView(tp.TerminalTab? tab) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    final isConnecting = tab == null || tab.status == tp.TabStatus.connecting;
    final isFailed = tab?.status == tp.TabStatus.failed;
    if (!isConnecting && !isFailed) return null;

    final label = isFailed
        ? '${l10n.connectionFailed} · ${tab!.title}'
        : (tab == null ? l10n.connecting : l10n.terminalConnecting(tab.title));
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isConnecting)
              SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: tc.brand),
              )
            else
              Icon(Icons.wifi_tethering_error_rounded, size: 20, color: tc.error),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(
                color: isFailed ? tc.error : tc.textSub,
                fontSize: fSmall,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              isFailed ? l10n.connectionFailedHint : l10n.terminalInputHintDisconnected,
              style: TextStyle(color: tc.textMuted, fontSize: fMicro),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ==================== AI 面板 ====================
  Widget _buildAIPanel(String? chatError, AgentState agentState, tp.TerminalTab? tab) {
    final tc = ThemeColors.of(context);

    return Container(
      // 设计稿 .ai-panel 只有 border-left（右侧态）/ 分割条（底部态）。
      // 面板自己再画一条上边线会和顶栏的下边线叠成双线，这里只保留底色。
      color: tc.cardElevated,
      child: Column(
        children: [
          // 会话压缩中横幅
          if (agentState.isCompacting)
            _buildCompactingBanner(tc),
          // 面板头（设计稿 .ai-head）：星形 + 标题 + 模型胶囊。
          // 位置切换钮仍留在分隔条上，这里只做身份标识。
          _buildAiPanelHead(),
          // 目标横幅已下移到输入框之上（见 _buildBottomBar），与参考图顺序一致：
          // 清单 → 目标 → 输入 → 底边指标。这里不再渲染，避免同屏两条目标行。
          // 消息列表 + 回到底部按钮
          Expanded(
            child: Stack(
              children: [
                _buildAgentChatList(agentState, tab),
                // 回到底部按钮
                if (_tabShowScrollToBottom[tab?.id] ?? false)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: GestureDetector(
                      onTap: _scrollChatToBottomManual,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: tc.cardElevated,
                          borderRadius: BorderRadius.circular(rFull),
                          border: Border.all(color: tc.border),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6),
                          ],
                        ),
                        child: Icon(Icons.keyboard_arrow_down, size: 18, color: tc.textSub),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 错误
          if (chatError != null || agentState.error != null)
            _buildErrorBanner(chatError ?? agentState.error),
        ],
      ),
    );
  }

  /// 面板头（设计稿 .ai-head）：品牌星 + 「AI 助手」+ 当前模型胶囊。
  Widget _buildAiPanelHead() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final modelName = _currentModelConfig?.name;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tc.hairline)),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 14, color: tc.brand),
          const SizedBox(width: 7),
          Text(
            l10n.commonAIAssistant,
            style: TextStyle(
                fontSize: fSmall, color: tc.textMain, fontWeight: FontWeight.w500),
          ),
          if (modelName != null && MediaQuery.of(context).size.width > 560) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              constraints: const BoxConstraints(maxWidth: 180),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(rFull),
                border: Border.all(color: tc.border),
              ),
              child: Text(
                modelName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: fMicro, color: tc.textSub),
              ),
            ),
          ],
          if (!_isMobile) ...[
            const Spacer(),
            _buildAiHeadControls(
                ref.read(tp.terminalProvider).activeTab?.id),
          ],
        ],
      ),
    );
  }

  /// AI 面板头右侧的微型控件：切换方位（右 → 下 → 悬浮）+ 收起。
  ///
  /// 设计稿的面板头只有「星 + 标题 + 模型胶囊」，没有一条常驻竖条放这些
  /// 操作；把两个入口收进头部后，终端与面板之间就只剩 1px 发丝线。
  Widget _buildAiHeadControls(String? tabId) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final position = _aiPanelPositionFor(tabId);
    final icon = switch (position) {
      _AiPanelPosition.bottom => Icons.horizontal_split_rounded,
      _AiPanelPosition.overlay => Icons.layers_outlined,
      _ => Icons.vertical_split_outlined,
    };

    Widget act(IconData ic, String tip, VoidCallback onTap) {
      return Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 24,
            height: 24,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(rXSmall),
            ),
            child: Icon(ic, size: 14, color: tc.textSub),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        act(icon, UiText.t('切换面板位置（右 / 下 / 悬浮）',
            'Switch panel position (right / bottom / overlay)'),
            _cycleAiPanelPosition),
        act(Icons.close_rounded, l10n.terminalCollapseAIPanel,
            () => setState(() => _setAiPanelVisible(tabId, false))),
      ],
    );
  }

  /// 会话压缩中横幅
  Widget _buildCompactingBanner(ThemeColors tc) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: tc.brandBg,
        border: Border(
          bottom: BorderSide(color: tc.brand.withValues(alpha: 0.3)),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: tc.brand),
          ),
          const SizedBox(width: 8),
          Text(
            L10n.str.compacting,
            style: TextStyle(
              color: tc.brand,
              fontSize: fSmall,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          Text(
            l10n.terminalCompactingHistory,
            style: TextStyle(color: tc.textSub, fontSize: fMicro),
          ),
        ],
      ),
    );
  }

  void _scrollChatToBottom() {
    if (!_autoScrollChat) return;
    // 流式期间 agent 状态每 120~150ms 变一次；若每次都 animateTo(200ms)，
    // 动画不断重启、永远跑不完，聊天列表会以满帧率持续 layout/paint。
    // 改为 150ms 尾随节流 + jumpTo：最多 ~6 次/秒瞬时滚动，无动画帧开销。
    if (_chatScrollThrottle != null) return;
    _chatScrollThrottle = Timer(const Duration(milliseconds: 150), () {
      _chatScrollThrottle = null;
      if (!mounted || !_autoScrollChat) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 延迟回调里重新查表：节流窗口内 tab 可能已关闭、controller 已
        // dispose，捕获旧引用再访问 hasClients 会抛"use after dispose"
        if (!mounted || !_autoScrollChat || _currentTabId == null) return;
        final controller = _chatScrollControllers[_currentTabId!];
        if (controller == null || !controller.hasClients) return;
        controller.jumpTo(controller.position.maxScrollExtent);
      });
    });
  }

  /// 用户点击"回到底部"按钮：恢复自动滚动并滚到底部
  void _scrollChatToBottomManual() {
    _autoScrollChat = true;
    final controller =
        _currentTabId == null ? null : _chatScrollControllers[_currentTabId];
    if (controller == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) {
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ==================== 轮次骨架 ====================

  /// 一轮的分隔线：`● 第 3 轮  24 条命令 · 1 失败 ─────────`
  ///
  /// 12 轮堆叠时，用户要能一眼看出"这一段是哪一轮、有多大"，否则滚动全靠
  /// 用户消息卡片当路标；命令数/失败数也给历史轮一个成本感。
  Widget _buildTurnAnchor(int number, String? stats, ThemeColors tc) {
    final ui = AgentUiText.of(context);
    return Padding(
      // 锚点是"下一轮的开头"，不是上一轮的结尾：上面只留一档分隔，
      // 下面给足呼吸，避免它贴住紧随其后的用户消息。
      padding: const EdgeInsets.only(top: 6, bottom: 16),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 4,
            margin: const EdgeInsets.only(right: 7),
            decoration: BoxDecoration(
              color: tc.textMuted.withValues(alpha: 0.8),
              shape: BoxShape.circle,
            ),
          ),
          Text(
            ui.turnLabel(number),
            style: TextStyle(
              color: tc.textSub,
              fontSize: fMicro,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          if (stats != null) ...[
            const SizedBox(width: 8),
            Text(
              stats,
              style: TextStyle(color: tc.textMuted, fontSize: fMicro),
            ),
          ],
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 1,
              color: tc.border.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  /// 本轮回答的命令数与失败数；下一项不是 assistant（还在等模型）时返回 null
  String? _turnStats(List<ChatItem> items, int userIndex) {
    if (userIndex + 1 >= items.length) return null;
    final answer = items[userIndex + 1];
    if (answer.role != 'assistant') return null;
    final commands = answer.events.where((e) => e.isCommand).length;
    final failures =
        answer.events.where((e) => e.isResult && e.success == false).length;
    if (commands == 0 && failures == 0) return null;
    final ui = AgentUiText.of(context);
    return [
      if (commands > 0) ui.commandCallsCount(commands),
      if (failures > 0) ui.failureCount(failures),
    ].join(' · ');
  }

  // ==================== Agent 模式统一消息列表 ====================
  /// 空会话的引导块。
  ///
  /// 之前这里只有一行居中的灰字（复用输入框 placeholder 那条文案），在一整块
  /// 320px 宽的空面板里既没有视觉锚点、也没说清楚"这个框能干什么"。
  /// 改成「图标 + 一句定位 + 一句边界说明」，全部克制在 11~12px，
  /// 和设计稿面板内的小字号层级一致。
  Widget _buildAiEmptyState() {
    final tc = ThemeColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: tc.brandBg,
                borderRadius: BorderRadius.circular(rMedium),
                border: Border.all(color: tc.border),
              ),
              child: Icon(Icons.auto_awesome, size: 19, color: tc.brand),
            ),
            const SizedBox(height: 12),
            Text(
              UiText.t('让 Agent 在这台主机上干活',
                  'Let the agent work on this host'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: fSmall,
                  color: tc.textBody,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 5),
            Text(
              UiText.t('描述需求，步骤自动执行；危险命令会先征求同意',
                  'Describe the task — steps run on their own, risky commands ask first'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: fMicro, color: tc.textMuted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgentChatList(AgentState agentState, tp.TerminalTab? tab) {
    final items = agentState.chatItems;
    // 终端还不存在的阶段（首连中/首连失败）不给上一标签的会话，也不提示"输入需求
    // 开始自动执行"——那时输入框是灰的，提示只会让人以为能直接问
    final waiting = _buildAgentWaitingView(tab);
    if (waiting != null) return waiting;
    if (items.isEmpty) {
      return _buildAiEmptyState();
    }
    // 轮次骨架：一条 user 开启一轮，其后 assistant 的产出都属于这一轮。
    // 12 轮的会话原来没有任何分隔，滚动时找不到"这段是哪一轮"。
    final turnNumbers = List<int?>.filled(items.length, null);
    var turnCount = 0;
    for (var i = 0; i < items.length; i++) {
      if (items[i].role == 'user') {
        turnCount++;
        turnNumbers[i] = turnCount;
      }
    }

    // 整块列表共用一个 SelectionArea：Markdown 的每段、命令卡、输出卡都是
    // 独立 Text 组件，若各自用 SelectableText 就只能一次选中一段。
    return SelectionArea(
      child: ListView.builder(
        controller: _chatControllerFor(tab?.id ?? _currentTabId ?? ''),
        // 两侧留白与下方底栏对齐：内容贴着面板边缘时，11px 小字 + 细边框
        // 会显得拥挤，留出一档呼吸空间也让卡片左边缘和输入框左边缘齐平。
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          final isLast = index == items.length - 1;
          final turnNo = turnNumbers[index];
          final turnGoal = item.role == 'assistant' &&
                  index > 0 &&
                  items[index - 1].role == 'user'
              ? items[index - 1].content
              : null;
          // RepaintBoundary：流式时只有最后一条消息在变，已定型消息不必跟着重绘
          return RepaintBoundary(
            key: ValueKey('agent_${item.role}_$index'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 单轮会话不加锚点：只有一个"第 1 轮"没有导航价值
                if (turnNo != null && turnCount > 1)
                  _buildTurnAnchor(
                    turnNo,
                    _turnStats(items, index),
                    ThemeColors.of(context),
                  ),
                _buildMessageBubble(
              role: item.role,
              content: item.content,
              events: item.events,
              streamingContent: item.streamingContent,
              turnGoal: turnGoal,
              isLoading: item.isStreaming && isLast && agentState.isRunning,
              // 原生推理只在跑动中展示；任务结束就收起，不占历史空间
              liveReasoning:
                  isLast && agentState.isRunning ? agentState.liveReasoning : '',
              tab: tab,
              showAutoExecute: true,
              isAgentRunning: agentState.isRunning,
              // 只有最后一条消息可能是"当前等待的询问"；历史消息里的旧询问不能
              // 跟着变成可点，否则用户会误答一个早已结束的问题。
              isWaitingChoice: agentState.isWaitingChoice && isLast,
              pendingOptions:
                  agentState.isWaitingChoice && isLast ? agentState.pendingOptions : const [],
              enginePendingConfirm: isLast ? agentState.pendingConfirmCommand : null,
                  // 历史回合只在"最近一轮"里保留展开态；旧回合收起过程与清单
                  isLastTurn: isLast,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ==================== Markdown 预处理 ====================
  /// 将单个换行转为 Markdown 硬换行（带缓存）
  /// 单段 Markdown 文本的缓存上限：流式中间态会远超这个长度，
  /// 缓存它们既不会再命中，也会让缓存常驻一堆大字符串。
  static const int _maxCachedMarkdownChars = 32768;

  String _preprocessMarkdown(String text) {
    if (text.length > _maxCachedMarkdownChars) {
      return _preprocessMarkdownInternal(text);
    }
    if (_markdownCache.containsKey(text)) {
      return _markdownCache[text]!;
    }
    final result = _preprocessMarkdownInternal(text);
    _markdownCache[text] = result;
    // 限制缓存大小
    if (_markdownCache.length > 100) {
      _markdownCache.remove(_markdownCache.keys.first);
    }
    return result;
  }

  /// 内部实现：将单个换行转为 Markdown 硬换行（两个空格+换行），
  /// 让 MarkdownBody 正确显示换行，而不把单换行当空格。
  /// 保持代码块内的换行不变。
  String _preprocessMarkdownInternal(String text) {
    final buffer = StringBuffer();
    var inCodeBlock = false;
    final lines = text.split('\n');

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      // 检测代码块边界
      if (line.trimLeft().startsWith('```')) {
        inCodeBlock = !inCodeBlock;
        buffer.write(line);
        if (i < lines.length - 1) buffer.write('\n');
        continue;
      }

      if (inCodeBlock) {
        // 代码块内保持原样
        buffer.write(line);
        if (i < lines.length - 1) buffer.write('\n');
      } else {
        // 代码块外：检查下一行
        final nextLine = i < lines.length - 1 ? lines[i + 1] : null;
        if (nextLine == null) {
          // 最后一行
          buffer.write(line);
        } else if (nextLine.trimLeft().startsWith('```')) {
          // 下一行是代码块开始，不加硬换行
          buffer.write(line);
          buffer.write('\n');
        } else if (nextLine.isEmpty) {
          // 下一个是空行 = 段落分隔，保持原样
          buffer.write(line);
          buffer.write('\n');
        } else if (line.isEmpty) {
          // 当前是空行，保持原样
          buffer.write('\n');
        } else if (line.trimLeft().startsWith('- ') ||
            line.trimLeft().startsWith('* ') ||
            line.trimLeft().startsWith('> ') ||
            line.trimLeft().startsWith('#') ||
            line.trimLeft().startsWith('1. ') ||
            line.trimLeft().startsWith('2. ') ||
            line.trimLeft().startsWith('3. ') ||
            line.trimLeft().startsWith('4. ') ||
            line.trimLeft().startsWith('5. ') ||
            line.trimLeft().startsWith('6. ') ||
            line.trimLeft().startsWith('7. ') ||
            line.trimLeft().startsWith('8. ') ||
            line.trimLeft().startsWith('9. ')) {
          // Markdown 列表/标题/引用项，保持原样
          buffer.write(line);
          buffer.write('\n');
        } else {
          // 普通文本行 → 加硬换行（两个空格+换行）
          buffer.write(line);
          buffer.write('  \n');
        }
      }
    }

    return buffer.toString();
  }

  // ==================== 消息气泡 ====================
  Widget _buildMessageBubble({
    Key? key,
    required String role,
    required String content,
    required bool isLoading,
    tp.TerminalTab? tab,
    bool showAutoExecute = false,
    bool isAgentRunning = false,
    bool isWaitingChoice = false,
    List<String> pendingOptions = const [],
    List<AgentEvent> events = const [],
    String streamingContent = '',
    String liveReasoning = '',
    String? turnGoal,
    String? enginePendingConfirm,
    bool isLastTurn = false,
  }) {
    final isUser = role == 'user';
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final ui = AgentUiText.of(context);
    // 流式没收尾时正文还会变，复制半截回答不如不复制
    final copyText = isUser || isLoading
        ? ''
        : formatAnswerForCopy(
            events: events,
            content: content,
            streamingContent: streamingContent,
          );

    return Align(
      key: key,
      alignment: Alignment.centerLeft,
      child: Container(
        // 用户提问和 AI 回答同一列宽（满宽）：原来用户消息缩在右侧 85% 宽的
        // 气泡里，一轮对话的左边缘跟着跳，滚动时像两套不同的版式。
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: isUser
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
            : EdgeInsets.zero,
        decoration: isUser
            ? BoxDecoration(
                gradient: tc.userBubbleGradient,
                borderRadius: const BorderRadius.all(Radius.circular(rMedium)),
                border: Border.all(color: tc.userBubbleBorder, width: 0.8),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 角色标签（设计稿 .role）：纯文字 11px 品牌色，不再套胶囊底——
            // 每条消息一个描边胶囊会把消息流切成一串标签串。
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  // 设计稿 .role：对话里的助手署名统一叫 Agent，面板头才叫「AI 助手」。
                  isUser ? l10n.terminalRoleYou : 'Agent',
                  style: TextStyle(
                    fontSize: fMicro,
                    color: tc.brand,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (isLoading) ...[
                  const SizedBox(width: 6),
                  SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.5, color: tc.brand)),
                ],
              ],
            ),
            SizedBox(height: isUser ? pXSmall : pSmall),
            // 内容
            // 选区由列表级 SelectionArea 统一管理，这里用普通 Text 才能跨段拖动
            if (isUser)
              CollapsibleMessageText(
                key: ValueKey('user_$content'),
                text: content,
                style: TextStyle(
                  color: tc.textMain,
                  fontSize: fBody,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              )
            else ...[
              _buildAIContent(content, tc, tab, showAutoExecute, isLoading, isAgentRunning, isWaitingChoice, pendingOptions: pendingOptions, events: events, streamingContent: streamingContent, liveReasoning: liveReasoning, turnGoal: turnGoal, enginePendingConfirm: enginePendingConfirm, isLastTurn: isLastTurn),
              // 整段复制固定在回答左下角：Markdown 段落、命令卡、输出卡都是独立
              // Text，拖选跨不过去，整段复制只能靠这一个按钮。放在左边缘是因为
              // 右对齐会飘到滚动条旁边，且和结论卡的右端对齐线打架。
              if (copyText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: pSmall),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _AnswerCopyButton(
                      text: copyText,
                      label: ui.copyAnswer,
                      doneLabel: ui.copied,
                      copiedLabel: ui.answerCopied,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 取本轮最后一个操作单报告（终态唯一）
  OperationReport? _findOperationReport(List<AgentEvent> events) {
    for (var i = events.length - 1; i >= 0; i--) {
      final event = events[i];
      if (event.isReport && event.operationReport != null) {
        return event.operationReport;
      }
    }
    return null;
  }

  /// 取当前尚未产出结果的命令（运行中用于计划步骤下的"当前命令"）
  String? _findRunningCommand(List<AgentEvent> events) {
    final completed = <String>{};
    for (final event in events) {
      if (event.isResult && event.commandId != null) {
        completed.add(event.commandId!);
      }
    }
    for (var i = events.length - 1; i >= 0; i--) {
      final event = events[i];
      if (event.isCommand && !completed.contains(event.id)) {
        final command = (event.command ?? '').trim();
        if (command.isNotEmpty) return command;
      }
    }
    return null;
  }

  /// 取本轮最新的执行计划（模型每次输出完整计划，最后一个为准）
  List<PlanStep> _findLatestPlan(List<AgentEvent> events) {
    for (var i = events.length - 1; i >= 0; i--) {
      final event = events[i];
      if (event.isPlan &&
          event.planSteps != null &&
          event.planSteps!.isNotEmpty) {
        return event.planSteps!;
      }
    }
    return const [];
  }

  /// 执行一条变更的回滚：远程变更需主机已连接，本机文件还原只需确认
  Future<void> _executeRollback(OperationChange change, String? hostId) async {
    if (_rollbackBusy) return;
    final cached = ChangeRecordsDao.getCachedById(change.id);
    final rollbackCommand = change.rollbackCommand?.trim().isNotEmpty == true
        ? change.rollbackCommand!.trim()
        : (cached?.rollbackCommand?.trim() ?? '');
    // 本机文件还原：把备份/回收区里的副本移回原路径，不经过 executor
    final isLocalRestore =
        change.localRestore || (cached?.isLocalFileRestore ?? false);
    if (!isLocalRestore && rollbackCommand.isEmpty) {
      _showOperationMessage('该变更没有可执行的回滚命令', isError: true);
      return;
    }

    final targetHost =
        (hostId != null && hostId.trim().isNotEmpty) ? hostId.trim() : 'local';
    tp.TerminalTab? targetTab;
    if (!isLocalRestore) {
      for (final tab in ref.read(tp.terminalProvider).tabs) {
        if (tab.hostId == targetHost && tab.isConnected) {
          targetTab = tab;
          break;
        }
      }
      if (targetTab == null) {
        _showOperationMessage(
          '主机 ${targetHost == 'local' ? '本地' : targetHost} 未连接，无法执行回滚',
          isError: true,
        );
        return;
      }
    }

    final tc = ThemeColors.of(context);
    final hostLabel = targetHost == 'local' ? '本地' : targetHost;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: tc.cardElevated,
        title: const Text('确认回滚'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('主机：$hostLabel',
                  style: TextStyle(color: tc.textMain, fontSize: fSmall)),
              const SizedBox(height: 8),
              Text(
                isLocalRestore ? '将把本机文件还原到：' : '将执行回滚命令：',
                style: TextStyle(color: tc.textSub, fontSize: fMicro),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: tc.terminalBg,
                  borderRadius: BorderRadius.circular(rXSmall),
                  border: Border.all(color: tc.border),
                ),
                child: SelectableText(
                  isLocalRestore ? change.command : rollbackCommand,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                    fontSize: fMono,
                    color: tc.warn,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isLocalRestore
                    ? '还原会把备份/回收区中的副本放回本机原路径，并写入审计记录。'
                    : '回滚会修改服务器状态，并写入审计记录。',
                style: TextStyle(color: tc.textMuted, fontSize: fMicro),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('确认回滚', style: TextStyle(color: tc.ok)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _rollbackBusy = true);
    try {
      CommandExecutor? executor;
      if (!isLocalRestore) {
        executor = targetTab!.isLocal
            ? targetTab.localService
            : targetTab.service;
        if (executor == null || !executor.isConnected) {
          _showOperationMessage('主机连接已断开，回滚未执行', isError: true);
          return;
        }
      }

      final type =
          ChangeType.values.asNameMap()[change.type] ?? ChangeType.other;
      // 优先用台账里的原始记录：本机还原对（localRestoreFrom/To）只存在于此
      final record = cached ??
          ChangeRecord(
            id: change.id,
            hostId: targetHost,
            command: change.command,
            type: type,
            rollbackCommand: rollbackCommand,
            timestamp: DateTime.now(),
            success: true,
          );
      final result =
          await ChangeRecordService.executeRollback(record, executor);
      if (!mounted) return;
      if (result == null) {
        _showOperationMessage('回滚未执行：主机未连接或没有回滚命令', isError: true);
      } else if (result.success) {
        setState(() => _rolledBackChangeIds.add(change.id));
        _showOperationMessage(
            '回滚成功：${isLocalRestore ? result.stdout : rollbackCommand}');
      } else {
        final reason = result.stderr.trim().isNotEmpty
            ? result.stderr.trim()
            : '退出码 ${result.exitCode}';
        _showOperationMessage('回滚失败：$reason', isError: true);
      }
    } catch (e) {
      if (mounted) _showOperationMessage('回滚异常：$e', isError: true);
    } finally {
      if (mounted) setState(() => _rollbackBusy = false);
    }
  }

  /// 断线失败一键重连当前主机
  Future<void> _reconnectHost(AgentEvent event) async {
    final targetHost =
        (event.hostId != null && event.hostId!.trim().isNotEmpty)
            ? event.hostId!.trim()
            : 'local';
    final activeTab = ref.read(tp.terminalProvider).activeTab;
    if (activeTab == null || activeTab.hostId != targetHost) {
      _showOperationMessage('请先切换到该主机再重连', isError: true);
      return;
    }
    if (activeTab.isLocal) {
      _showOperationMessage('本地终端不需要重连，请检查终端进程', isError: true);
      return;
    }
    final config = HostsDao.getCachedById(targetHost);
    if (config == null) {
      _showOperationMessage('找不到主机配置，无法重连', isError: true);
      return;
    }

    _showOperationMessage('正在重连 ${activeTab.title} ...');
    if (mounted) {
      setState(() => _reconnectingHostLabel = activeTab.title);
    }
    try {
      final tab = await ref
          .read(tp.terminalProvider.notifier)
          .reconnect(activeTab.id, config);
      if (!mounted) return;
      if (tab == null || !tab.isConnected) {
        _showOperationMessage('重连失败，请检查网络或密码', isError: true);
        return;
      }
      final executor = tab.isLocal ? tab.localService : tab.service;
      ref
          .read(agentProvider.notifier)
          .setExecutor(executor, hostId: tab.hostId, tabId: tab.id);
      _showOperationMessage('重连成功');
    } catch (e) {
      if (mounted) _showOperationMessage('重连异常：$e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _reconnectingHostLabel = null);
      }
    }
  }

  /// 中断/失败后继续：带上次目标和执行清单开启新一轮，要求先核对状态
  Future<void> _continueOperation(OperationReport report) {
    final reason = report.isCancelled
        ? '用户取消'
        : report.isInterrupted
            ? '达到步数上限'
            : '执行失败';
    return _startContinuation(
      goal: report.goal,
      plan: report.plan,
      reason: reason,
      hostId: report.hostId,
    );
  }

  Future<void> _continueInterruptedTurn({
    String? goal,
    required List<PlanStep> plan,
    String? hostId,
  }) {
    return _startContinuation(
      goal: goal ?? '',
      plan: plan,
      reason: '应用退出或连接中断',
      hostId: hostId,
    );
  }

  Future<void> _startContinuation({
    required String goal,
    required List<PlanStep> plan,
    required String reason,
    String? hostId,
  }) async {
    if (ref.read(agentProvider).isRunning) {
      _showOperationMessage('Agent 正在执行，请稍后再试', isError: true);
      return;
    }
    if (!_checkAIModelConfigured()) {
      _showAIModelNotConfiguredHint();
      return;
    }
    final activeTab = ref.read(tp.terminalProvider).activeTab;
    if (activeTab == null) {
      _showOperationMessage('请先连接主机再继续任务', isError: true);
      return;
    }
    final targetHost =
        (hostId != null && hostId.trim().isNotEmpty) ? hostId.trim() : activeTab.hostId;
    if (activeTab.hostId != targetHost) {
      _showOperationMessage('请先切换到该主机再继续任务', isError: true);
      return;
    }
    final executor =
        activeTab.isLocal ? activeTab.localService : activeTab.service;
    if (!activeTab.isConnected || executor == null || !executor.isConnected) {
      _showOperationMessage('请先连接主机再继续任务', isError: true);
      return;
    }

    final planBlock = plan.isEmpty
        ? ''
        : '\n上次执行清单：\n'
            '${plan.map((s) => '- [${_planStatusMarker(s.status)}] ${s.title}').join('\n')}\n';
    final goalText = goal.trim().isEmpty ? '上一步任务' : goal.trim();
    final prompt = '继续完成之前的目标：$goalText\n$planBlock'
        '上次任务因$reason中断。请先检查当前服务器状态，避免重复已完成或已生效的操作，然后从中断处继续。';
    _autoScrollChat = true;
    ref
        .read(agentProvider.notifier)
        .setExecutor(executor, hostId: activeTab.hostId, tabId: activeTab.id);
    await ref.read(agentProvider.notifier).startTask(prompt);
  }

  String _planStatusMarker(PlanStepStatus status) {
    switch (status) {
      case PlanStepStatus.completed:
        return 'x';
      case PlanStepStatus.inProgress:
        return '>';
      case PlanStepStatus.failed:
        return '!';
      case PlanStepStatus.skipped:
        return '-';
      case PlanStepStatus.pending:
        return ' ';
    }
  }

  /// 多主机矩阵：只重试失败主机
  Future<void> _retryFailedHosts(List<String> failedHostIds) async {
    final hosts = failedHostIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (hosts.isEmpty) return;
    if (ref.read(agentProvider).isRunning) {
      _showOperationMessage('Agent 正在执行，请稍后再试', isError: true);
      return;
    }
    if (!_checkAIModelConfigured()) {
      _showAIModelNotConfiguredHint();
      return;
    }

    final activeTab = ref.read(tp.terminalProvider).activeTab;
    final executor =
        activeTab?.isLocal == true ? activeTab?.localService : activeTab?.service;
    if (activeTab == null ||
        !activeTab.isConnected ||
        executor == null ||
        !executor.isConnected) {
      _showOperationMessage('请先连接一台主机再重试', isError: true);
      return;
    }

    final prompt = '上一步批量执行在以下主机失败：${hosts.join(', ')}。'
        '请先分析各主机的失败原因，修复后只重试这些主机；'
        '如果某台主机已断开，请先提示我重连；如果需要多机编排，请提示我开启编排模式。';
    _autoScrollChat = true;
    ref
        .read(agentProvider.notifier)
        .setExecutor(executor, hostId: activeTab.hostId, tabId: activeTab.id);
    await ref.read(agentProvider.notifier).startTask(prompt);
  }

  /// 失败命令重试：把失败上下文带回新一轮 Agent 任务
  Future<void> _retryFailedCommand(AgentEvent event) async {
    final command = (event.command ?? '').trim();
    if (command.isEmpty) return;
    if (ref.read(agentProvider).isRunning) {
      _showOperationMessage('Agent 正在执行，请稍后再试', isError: true);
      return;
    }
    if (!_checkAIModelConfigured()) {
      _showAIModelNotConfiguredHint();
      return;
    }

    final targetHost =
        (event.hostId != null && event.hostId!.trim().isNotEmpty)
            ? event.hostId!.trim()
            : 'local';
    final activeTab = ref.read(tp.terminalProvider).activeTab;
    if (activeTab == null ||
        activeTab.hostId != targetHost ||
        !activeTab.isConnected) {
      _showOperationMessage('请先切换/重连到该主机再重试', isError: true);
      return;
    }
    final executor = activeTab.isLocal
        ? activeTab.localService
        : activeTab.service;
    if (executor == null || !executor.isConnected) {
      _showOperationMessage('主机连接已断开，请先重连', isError: true);
      return;
    }

    final errorLine = (event.error ?? '').trim().split('\n').first.trim();
    final reason = errorLine.isNotEmpty ? '：$errorLine' : '';
    final prompt = '上一步命令 `$command` 执行失败$reason。'
        '请先分析失败原因，修复后重试；如果需要我确认或重连，请明确告诉我。';
    _autoScrollChat = true;
    ref
        .read(agentProvider.notifier)
        .setExecutor(executor, hostId: activeTab.hostId, tabId: activeTab.id);
    await ref.read(agentProvider.notifier).startTask(prompt);
  }

  void _showOperationMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    clearTopToast();
    showTopSnackBar(context, SnackBar(
      content: Text(message, style: const TextStyle(fontSize: fSmall)),
      duration: Duration(seconds: isError ? 4 : 2),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      backgroundColor: isError ? cDanger.withValues(alpha: 0.95) : null,
    ));
  }

  /// AI 回复内容渲染：优先用结构化事件列表渲染卡片，fallback 到旧的纯文本/ReAct 解析
  /// 目标是否就是上一条用户消息本身。
  ///
  /// 会话里 report.goal 通常直接取自用户输入，结果层再复述一遍，屏幕上就是
  /// 两段一模一样的大字。只在两者确实重合时省略，独立场景仍保留目标。
  bool _goalEchoesPrompt(String goal, String? prompt) {
    if (prompt == null) return false;
    String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
    final g = norm(goal);
    final p = norm(prompt);
    if (g.length < 12 || p.length < 12) return false;
    return g == p || p.contains(g) || g.contains(p);
  }

  /// 去掉"其实是正文草稿"的思考行。
  ///
  /// 模型有时把最终回答整段写进推理里，于是同一段 Markdown 先以三行原始
  /// 文本出现在思考行，再被正文渲染一遍——两边都是几百字，屏幕上就是重复。
  /// 只在思考**包含**完整一段正文时丢弃，正常推理不受影响。
  List<AgentEvent> _dedupeProcessEvents(List<AgentEvent> events) {
    String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
    final texts = events
        .where((e) => e.isText)
        .map((e) => norm(e.text ?? ''))
        .where((t) => t.length >= 120)
        .toList(growable: false);
    if (texts.isEmpty) return events;
    bool isDraft(AgentEvent e) {
      if (!e.isThought) return false;
      final t = norm(e.text ?? '');
      if (t.length < 120) return false;
      return texts.any(t.contains);
    }

    return events.where((e) => !isDraft(e)).toList(growable: false);
  }

  /// 两段文字是否只是标题符号/空白差异（正文与结论重复时只留一份）
  bool _sameAnswerText(String a, String b) {
    String n(String s) => s
        .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return n(a) == n(b);
  }

  Widget _buildAIContent(
    String content,
    ThemeColors tc,
    tp.TerminalTab? tab,
    bool showAutoExecute,
    bool isLoading,
    bool isAgentRunning,
    bool isWaitingChoice, {
    List<String> pendingOptions = const [],
    List<AgentEvent> events = const [],
    String streamingContent = '',
    String liveReasoning = '',
    String? turnGoal,
    String? enginePendingConfirm,
    bool isLastTurn = false,
  }) {
    // 合并两种待确认来源：引擎自动流程（enginePendingConfirm）和手动播放（_pendingConfirmCommand）
    final effectivePendingConfirm = enginePendingConfirm ??
        (tab == null ? _pendingConfirmCommand : _tabPendingConfirm[tab.id]);

    // 判断某命令是否是引擎等待确认的命令（走 confirmCommand/rejectCommand 路径）
    bool isEngineConfirm(String command) =>
        enginePendingConfirm != null && enginePendingConfirm == command.trim();

    // 优先使用结构化事件渲染（ReAct 格式已由 ReActStreamParser 正确解析）
    if (events.isNotEmpty) {
      Widget buildEventContent(List<AgentEvent> source) =>
          AgentEventContent(
            events: source,
            tc: tc,
            tab: tab,
            showAutoExecute: showAutoExecute,
            isLoading: isLoading,
            isWaitingChoice: isWaitingChoice,
            pendingOptions: pendingOptions,
            // 实时推理接到时间线末尾：思考发生在它真实的位置上，
            // 而不是浮在整条回答顶部、结束后又凭空消失
            liveReasoning: liveReasoning,
            executingCommand:
                tab == null ? _executingCommand : _tabExecutingCommand[tab.id],
            pendingConfirmCommand: effectivePendingConfirm,
            markdownBuilder: _buildMarkdownText,
            onExecuteCommand: _executeLineDirectly,
            onConfirmCommand: (command) {
              if (isEngineConfirm(command)) {
                // 引擎自动流程：走 confirmCommand 解析 completer
                ref.read(agentProvider.notifier).confirmCommand();
              } else {
                // 手动播放流程：直接在终端执行
                final activeTab = ref.read(tp.terminalProvider).activeTab;
                if (activeTab != null) _executeLineDirectly(command, true, activeTab);
              }
            },
            onRejectCommand: () {
              if (enginePendingConfirm != null) {
                ref.read(agentProvider.notifier).rejectCommand();
              } else {
                setState(() => _pendingConfirmCommand = null);
              }
            },
            onSelectChoice: _onOptionSelected,
            onRetryFailedCommand: _retryFailedCommand,
            onReconnectHost: _reconnectHost,
            onRetryFailedHosts: _retryFailedHosts,
          );

      // 有操作单报告：按发生顺序铺开过程，再收结论、复制、执行清单。
      //
      // 之前是「结论 → 计划 → 正文 → 过程折叠」：用户先看到结论，真正的
      // 思考 / 命令 / 输出被压到最后一次点击里，顺序和实际发生顺序相反。
      final report = _findOperationReport(events);
      if (report != null) {
        final processEvents = _dedupeProcessEvents(events
            .where((e) => !e.isReport && !e.isFinish && !e.isPlan)
            .toList(growable: false));
        final planSteps =
            report.plan.isNotEmpty ? report.plan : _findLatestPlan(events);
        // 回答正文只留一份：正文缺失时用"结论"兜底，正文与结论同义时也只渲染
        // 一次。结论卡里的那一段不再单独展示——同一句话在大字标题下再讲一遍，
        // 是整条回答最明显的重复。
        final body = (report.answerBody ?? '').trim();
        final conclusion = report.conclusion.trim();
        final answerText =
            body.isNotEmpty && !_sameAnswerText(body, conclusion)
                ? body
                : conclusion;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. 过程：思考 / 命令 / 输出按原始顺序交错
            if (processEvents.isNotEmpty) buildEventContent(processEvents),
            // 2. 回答正文：和过程里的命令行同一套框（透明填充 + 1px 边框 +
            //    10px 圆角），左右不再内缩——原来无边框的正文比上下卡片更宽，
            //    读起来像另一套版式。
            if (answerText.isNotEmpty) _answerCard(answerText, tc),
            // 3. 结果层：状态 / 主机 / 耗时 / 变更数 / 下一步
            Padding(
              padding: const EdgeInsets.only(top: pModule),
              child: OperationSheet(
                report: report,
                tc: tc,
                markdownBuilder: _buildMarkdownText,
                // 目标就是上一条用户消息时不再复述
                showGoal: !_goalEchoesPrompt(report.goal, turnGoal),
                // 过程已经在上面按顺序铺开，这里不留「过程与证据」折叠
                hasEvidence: false,
                showEvidence: false,
                evidenceBuilder: () => const SizedBox.shrink(),
                // 正文与结论合并到上面那块，结果卡只留结果
                showAnswerBody: false,
                showConclusion: false,
                // 执行清单移到整条回答的最底部
                showPlan: false,
                plan: const [],
                rolledBackChangeIds: _rolledBackChangeIds,
                onRollbackChange: _executeRollback,
                rollbackBusy: _rollbackBusy,
                onOpenAudit: () {
                  final host = report.hostId;
                  final query = (host != null && host.isNotEmpty)
                      ? '?hostId=${Uri.encodeComponent(host)}'
                      : '';
                  context.push('/audit-log$query');
                },
                onContinueOperation: () => _continueOperation(report),
              ),
            ),
            // 4. 执行清单：整条回答的最后一块（运行中由贴底清单承担）
            if (planSteps.isNotEmpty && !_planPinnedActive) ...[
              const SizedBox(height: pModule),
              PlanPanel(
                steps: planSteps,
                tc: tc,
                initiallyExpanded: isLastTurn ? null : false,
                margin: EdgeInsets.zero,
              ),
            ],
          ],
        );
      }

      // 旧会话/进行中：保持原有事件流渲染
      // 判断 events 中是否有 AI 输出的内容事件（thought/command/text/ask/finish）
      // 如果只有 result/info，说明还在流式过程中，需要同时显示 streamingContent
      final hasAIContentEvents = events.any((e) =>
          e.isThought || e.isCommand || e.isText || e.isAsk || e.isFinish);
      final plan = _findLatestPlan(events);
      final interrupted = !isAgentRunning &&
          !isLoading &&
          !isWaitingChoice &&
          isInterruptedTurn(events);
      final runningCommand =
          isAgentRunning ? _findRunningCommand(events) : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 历史中断回合：明确标记并允许继续
          if (interrupted)
            InterruptedTurnBanner(
              tc: tc,
              goal: turnGoal,
              onContinue: () => _continueInterruptedTurn(
                goal: turnGoal,
                plan: plan,
                hostId: lastEventHostId(events),
              ),
            ),
          // 过程一条不折：用户要的是"AI 输出什么就看到什么"
          // 实时推理（reasoning_content）已经作为时间线末尾的思考行渲染，
          // 不再单独浮一个「模型思考」块——它停在回答顶部、每步结束又被清空，
          // 看上去就像"思考凭空消失"。也不再有「思考中」块：它装的是流式正文
          // （模型写的说明/答案），不是思考。
          buildEventContent(_dedupeProcessEvents(events)),
          // 没有 AI 内容事件时（流式早期或纯文本兜底）仍然按原逻辑显示
          if (!hasAIContentEvents && !isLoading)
            _answerCard(
              streamingContent.trim().isNotEmpty
                  ? streamingContent
                  : content,
              tc,
            ),
          // 执行清单固定在这条回答的最底部；运行中则由贴底清单承担，
          // 这里抑制，避免同一份计划同屏出现两次。
          if (plan.isNotEmpty && !_planPinnedActive) ...[
            const SizedBox(height: pModule),
            PlanPanel(
              steps: plan,
              tc: tc,
              currentCommand: runningCommand,
              // 历史回合默认收起，只留"进度 + 当前步"一行
              initiallyExpanded: isLastTurn ? null : false,
              margin: EdgeInsets.zero,
            ),
          ],
        ],
      );
    }

    // 非 Agent 模式：纯 Markdown + 代码块渲染
    final segments = _splitContentByCodeBlocks(content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...segments.map((seg) {
          if (seg.isCodeBlock) {
            final lang = seg.language;
            final isShell = lang == 'bash' || lang == 'sh' || lang == 'shell' || lang == 'zsh';
            if (isShell) {
              return buildCodeBlockWithExecuteButton(
                seg.content, tc, tab, showAutoExecute, isLoading,
                executingCommand:
                tab == null ? _executingCommand : _tabExecutingCommand[tab.id],
                pendingConfirmCommand: effectivePendingConfirm,
                onExecute: _executeLineDirectly,
                onConfirm: (command) {
                  if (isEngineConfirm(command)) {
                    ref.read(agentProvider.notifier).confirmCommand();
                  } else {
                    final activeTab = ref.read(tp.terminalProvider).activeTab;
                    if (activeTab != null) _executeLineDirectly(command, true, activeTab);
                  }
                },
                onReject: () {
                  if (enginePendingConfirm != null) {
                    ref.read(agentProvider.notifier).rejectCommand();
                  } else {
                    setState(() => _pendingConfirmCommand = null);
                  }
                },
              );
            } else {
              return buildPlainCodeBlock(seg.content, tc);
            }
          } else {
            if (seg.content.trim().isEmpty) return const SizedBox.shrink();
            return _buildMarkdownText(seg.content, tc);
          }
        }),
        if (isWaitingChoice && pendingOptions.isNotEmpty)
          buildOptionButtons(pendingOptions, tc, false, onSelectChoice: _onOptionSelected),
      ],
    );
  }


  /// 回答正文的容器：与命令行 / 结果卡同一套（见 [agentAnswerCard]）
  Widget _answerCard(String text, ThemeColors tc) =>
      agentAnswerCard(_buildMarkdownText(text, tc), tc);

  /// 渲染一段 Markdown 文本（用于 thought/text/info 的自动追加显示）。
  ///
  /// 围栏代码块先拆出来单独渲染：flutter_markdown 的 `code` 样式同时作用于行内
  /// 代码和整块代码的正文，想给行内代码上字色就会把整块也染上；块走独立容器，
  /// 行内代码才敢直接用字色区分，而不是在字后面垫一块深色补丁。
  Widget _buildMarkdownText(String text, ThemeColors tc,
      {bool streaming = false}) {
    // 流式增量渲染：稳定前缀走缓存块，只有正在增长的尾部重新解析
    if (streaming && text.length > 1024) {
      final incremental = _buildStreamingMarkdown(text, tc);
      if (incremental != null) return incremental;
    }
    final bodies = <Widget>[];
    for (final seg in _splitContentByCodeBlocks(text)) {
      if (seg.isCodeBlock) {
        bodies.add(buildPlainCodeBlock(seg.content, tc));
        continue;
      }
      if (seg.content.trim().isEmpty) continue;
      // 表格先切出来单独渲染：flutter_markdown 0.6.x 的 builders 对块级元素
      // 不生效，表格始终均分列宽；这里按内容自适应宽度渲染。
      for (final chunk in splitMarkdownTables(seg.content)) {
        final table = chunk.table;
        if (table != null) {
          bodies.add(SmartMarkdownTable(data: table, tc: tc));
        } else if (chunk.text.trim().isNotEmpty) {
          bodies.add(_CachedMarkdownText(
            text: chunk.text,
            isLight: tc.isLight,
            tc: tc,
            builder: (text, theme) => MarkdownBody(
              data: _preprocessMarkdown(text),
              // 交给外层 SelectionArea 统一选择：selectable=true 会让 flutter_markdown
              // 为每个段落生成独立 SelectableText，选区被限制在单段内。
              selectable: false,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(
                  color: theme.textMain,
                  height: 1.5,
                  // Agent 正文比过程证据再小一档，避免大段正文喧宾夺主
                  fontSize: fAgentBody,
                  fontWeight: FontWeight.w500,
                ),
                h1: TextStyle(color: theme.textMain, fontSize: 16, fontWeight: FontWeight.bold),
                h2: TextStyle(color: theme.textMain, fontSize: 14, fontWeight: FontWeight.bold),
                h3: TextStyle(color: theme.textMain, fontSize: fBody, fontWeight: FontWeight.w600),
                code: TextStyle(
                  fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                  fontSize: fMono,
                  fontWeight: FontWeight.w500,
                  color: theme.brand,
                ),
                listBullet: TextStyle(color: theme.brand, fontSize: fAgentBody),
                blockquote: TextStyle(
                  color: theme.textSub,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w500,
                ),
                blockquoteDecoration: BoxDecoration(
                  border: Border(left: BorderSide(color: theme.brand, width: 2)),
                ),
                blockquotePadding: const EdgeInsets.only(left: 8),
                // AI 常用 `---` 分隔章节，默认是 5px 粗灰线，过于抢眼；改成细线
                horizontalRuleDecoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: theme.border, width: 1),
                  ),
                ),
              ),
              onTapLink: (text, href, title) {},
            ),
          ));
        }
      }
    }
    if (bodies.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: bodies.length == 1
          ? bodies.single
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: bodies,
            ),
    );
  }

  /// 流式 Markdown 增量分割缓存：稳定前缀只增不改，记录前缀及其分割结果，
  /// 每次 flush 只分割新完成的段落，避免对全文反复全量分割+解析（O(n²)）。
  String _streamMdBase = '';
  List<_ContentSegment> _streamMdSegs = const [];

  /// 流式增量渲染：在代码块外的最后一个段落边界（空行）切成
  ///「稳定前缀 + 活跃尾部」。前缀按代码块/文本段拆成独立缓存块，文本不再
  /// 变化、缓存必命中；只有尾部（正在增长的段落）每次 flush 重解析。
  Widget? _buildStreamingMarkdown(String text, ThemeColors tc) {
    final cut = stableParagraphCut(text);
    if (cut <= 0) return null;
    final head = text.substring(0, cut);
    final tail = text.substring(cut);
    List<_ContentSegment> segs;
    if (head == _streamMdBase) {
      segs = _streamMdSegs;
    } else if (_streamMdBase.isNotEmpty && head.startsWith(_streamMdBase)) {
      // 新旧前缀都结束于代码块外的段落边界，增量可以独立分割后追加
      final delta = head.substring(_streamMdBase.length);
      segs = [..._streamMdSegs, ..._splitContentByCodeBlocksInternal(delta)];
      _streamMdBase = head;
      _streamMdSegs = segs;
    } else {
      segs = _splitContentByCodeBlocksInternal(head);
      _streamMdBase = head;
      _streamMdSegs = segs;
    }
    final children = <Widget>[];
    for (final seg in segs) {
      if (seg.isCodeBlock) {
        children.add(buildPlainCodeBlock(seg.content, tc));
      } else if (seg.content.trim().isNotEmpty) {
        children.add(_buildMarkdownText(seg.content, tc));
      }
    }
    if (tail.trim().isNotEmpty) {
      // 尾部含未闭合代码围栏时：围栏内容直接按纯代码块渲染，
      // 避免增长中的代码块被当 Markdown 全文重解析
      final fence = unclosedFenceSplit(tail);
      if (fence != null) {
        if (fence.$1.trim().isNotEmpty) {
          children.add(_buildMarkdownText(fence.$1, tc));
        }
        children.add(buildPlainCodeBlock(fence.$2, tc));
      } else {
        children.add(_buildMarkdownText(tail, tc));
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// 将内容按代码块分割（带缓存）
  List<_ContentSegment> _splitContentByCodeBlocks(String content) {
    if (content.length > _maxCachedMarkdownChars) {
      return _splitContentByCodeBlocksInternal(content);
    }
    if (_splitCache.containsKey(content)) {
      return _splitCache[content]!;
    }
    final result = _splitContentByCodeBlocksInternal(content);
    _splitCache[content] = result;
    // 限制缓存大小
    if (_splitCache.length > 100) {
      _splitCache.remove(_splitCache.keys.first);
    }
    return result;
  }

  /// 内部实现：将内容按代码块分割
  List<_ContentSegment> _splitContentByCodeBlocksInternal(String content) {
    final segments = <_ContentSegment>[];
    final regex = RegExp(r'```(\w*)\s*\n([\s\S]*?)```', multiLine: true);
    int lastEnd = 0;
    for (final match in regex.allMatches(content)) {
      // 代码块前的文本
      if (match.start > lastEnd) {
        final before = content.substring(lastEnd, match.start);
        if (before.trim().isNotEmpty) {
          segments.add(_ContentSegment(before, false));
        }
      }
      // 代码块内容和语言标识
      final lang = match.group(1) ?? '';
      final code = match.group(2) ?? '';
      segments.add(_ContentSegment(code, true, language: lang.isEmpty ? null : lang.toLowerCase()));
      lastEnd = match.end;
    }
    // 剩余文本
    if (lastEnd < content.length) {
      final remaining = content.substring(lastEnd);
      if (remaining.trim().isNotEmpty) {
        segments.add(_ContentSegment(remaining, false));
      }
    }
    if (segments.isEmpty) {
      segments.add(_ContentSegment(content, false));
    }
    return segments;
  }

  /// 选项按钮点击处理：如果 agent 正在等待选择则回复选择，否则作为新任务发送
  void _onOptionSelected(String option) {
    final agentState = ref.read(agentProvider);
    if (agentState.isWaitingChoice) {
      ref.read(agentProvider.notifier).selectChoice(option);
    } else {
      ref.read(agentProvider.notifier).startTask(option);
    }
  }

  /// 掩码密码输入弹窗 —— Agent 的 provide_password 工具走这里收集特权密码。
  ///
  /// 返回值只在调用栈里流转到 CredentialsStore：不写 provider state、
  /// 不进对话历史、也不落日志（AGENTS.md R7）。
  Future<String?> _requestSecret(String title, String message) {
    if (!mounted) return Future.value(null);
    final tc = ThemeColors.of(context);
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        bool obscure = true;
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            backgroundColor: tc.cardElevated,
            title: Text(title,
                style: TextStyle(color: tc.textMain, fontSize: fBody)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message,
                    style:
                        TextStyle(color: tc.textSub, fontSize: fSmall, height: 1.5)),
                const SizedBox(height: pCompact),
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: obscure,
                  style: TextStyle(color: tc.textMain, fontSize: fBody),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: '密码',
                    labelStyle: TextStyle(color: tc.textSub, fontSize: fSmall),
                    filled: true,
                    fillColor: tc.card,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: pCompact, vertical: pSmall),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(rInput),
                      borderSide: BorderSide(color: tc.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(rInput),
                      borderSide: BorderSide(color: tc.brand),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                          obscure ? Icons.visibility_off : Icons.visibility,
                          size: 16,
                          color: tc.textSub),
                      tooltip: obscure ? '显示' : '隐藏',
                      onPressed: () => setDialogState(() => obscure = !obscure),
                    ),
                  ),
                  onSubmitted: (value) => Navigator.of(ctx).pop(value),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('取消',
                    style: TextStyle(color: tc.textSub, fontSize: fSmall)),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text),
                child: const Text('确定', style: TextStyle(fontSize: fSmall)),
              ),
            ],
          ),
        );
      },
    ).whenComplete(controller.dispose);
  }

  /// 本机目录授权弹窗 —— local_exec 的 cwd 不在白名单时走这里。
  ///
  /// 弹窗必须列出具体路径、原因和“会开启本地文件访问并授权该目录”，
  /// 不能静默扩权；敏感路径在工具层就被拒绝，不会走到这里。
  Future<bool> _requestLocalDir(String path, String reason) async {
    if (!mounted) return false;
    final ui = AgentUiText.of(context);
    final approved = await showLocalDirAuthDialog(
      context,
      path: path,
      reason: reason,
    );
    if (!approved || !mounted) return false;
    // 弹窗期间任务可能已被取消：不再保存授权，也不让工具继续执行
    if (!ref.read(agentProvider).isRunning) return false;

    final policy = LocalFilePolicy.load();
    final dirs = [...policy.allowedDirs];
    if (!dirs.contains(path)) dirs.add(path);
    await policy.copyWith(enabled: true, allowedDirs: dirs).save();
    if (!mounted) return true;
    showTopSnackBar(
      context,
      SnackBar(
        content:
            Text(ui.localExecAuthorized(path), style: const TextStyle(fontSize: fSmall)),
        duration: const Duration(seconds: 2),
      ),
    );
    return true;
  }

  /// 直接执行命令行
  Future<void> _executeLineDirectly(String command, bool dangerous, tp.TerminalTab tab) async {
    // 危险命令：首次点击展开内联确认按钮，第二次点击确认才执行
    if (dangerous && _pendingConfirmCommand != command) {
      setState(() => _pendingConfirmCommand = command);
      return;
    }
    // 确认执行或安全命令直接执行
    setState(() => _pendingConfirmCommand = null);

    setState(() => _executingCommand = command);

    // 发送命令到终端
    if (tab.isLocal) {
      tab.localService?.writeToTerminal('$command\n');
    } else {
      tab.service?.writeToTerminal('$command\n');
    }

    await Future.delayed(const Duration(milliseconds: 800));

    if (mounted) {
      setState(() {
        _executedCommands.add(command);
        _executingCommand = null;
      });
    }
  }

  /// 把文本交给 agent。`onSend` 与 `/goal` 首轮共用这段执行器绑定，避免两份实现漂移。
  Future<void> _sendToAgent(String text, {required bool isConnected}) async {
    if (!_checkAIModelConfigured()) {
      _showAIModelNotConfiguredHint();
      return;
    }
    _autoScrollChat = true; // 用户发送新消息时恢复自动滚动
    if (!isConnected) return;
    final tab = ref.read(tp.terminalProvider).activeTab;
    // 本地终端用 localService，SSH 用 service
    final CommandExecutor? executor =
        tab?.isLocal == true ? tab?.localService : tab?.service;
    final notifier = ref.read(agentProvider.notifier);
    notifier.setExecutor(executor,
        hostId: tab?.hostId ?? 'local', tabId: tab?.id);
    await notifier.startTask(text);
  }

  void _showGoalHint(String message) {
    showTopSnackBar(context, SnackBar(
      content: Text(message, style: const TextStyle(fontSize: 13)),
      duration: const Duration(seconds: 3),
    ));
  }

  /// 切换执行权限档位；全自动先弹一次范围警告。
  Future<void> _applyPermissionMode(AgentPermissionMode mode) async {
    if (mode == ref.read(agentProvider).permissionMode) return;
    final ui = AgentUiText.of(context);
    if (mode == AgentPermissionMode.fullAuto) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final tc = ThemeColors.of(ctx);
          return AlertDialog(
            backgroundColor: tc.cardElevated,
            title: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: tc.error, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ui.permissionModeFullAutoWarningTitle,
                    style: TextStyle(color: tc.textMain, fontSize: fBody),
                  ),
                ),
              ],
            ),
            content: Text(
              ui.permissionModeFullAutoWarningBody,
              style: TextStyle(
                color: tc.textSub,
                fontSize: fSmall,
                height: 1.5,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(ui.cancel,
                    style: TextStyle(color: tc.textSub, fontSize: fSmall)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: tc.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(ui.permissionModeEnable,
                    style: const TextStyle(fontSize: fSmall)),
              ),
            ],
          );
        },
      );
      if (ok != true || !mounted) return;
    }
    ref.read(agentProvider.notifier).setPermissionMode(mode);
    if (!mounted) return;
    _showGoalHint(ui.permissionModeSwitched(
      ui.permissionModeLabel(mode),
      ui.permissionModeDescription(mode),
    ));
  }

  /// `/plan`：只要计划、不执行。临时置只读，结束后**恢复原档位而不是恢复询问**——
  /// 本来就在自动/全自动的用户不该被这次操作顺手改档。
  Future<void> _runPlanOnly(String objective,
      {required bool isConnected}) async {
    final notifier = ref.read(agentProvider.notifier);
    // 权限档位必须按 host 读写：计划任务可能跑几百秒，期间用户完全可能切 tab，
    // 那时用"活跃 host"的 toggle 就会改到另一台机器上（AGENTS.md R3）
    final planHostId = ref.read(agentProvider).hostId ?? 'local';
    final wasMode = notifier.permissionModeFor(planHostId);
    final enteredReadOnly = wasMode != AgentPermissionMode.readOnly;
    if (enteredReadOnly) {
      notifier.setPermissionModeForHost(
          planHostId, AgentPermissionMode.readOnly);
    }
    try {
      await _sendToAgent(
        '【只要计划，不要执行】\n目标：$objective\n\n'
        '请只输出执行计划（用 计划: 列出步骤与每步要跑的命令），不要执行任何命令；'
        '本次已临时开启只读模式，任务结束后会恢复你原来的设置。',
        isConnected: isConnected,
      );
    } finally {
      // 重读一次：任务期间用户可能自己动过这个档位，只在他没动时还原。
      // 页面已销毁时不还原——那种情况下留在只读是安全方向。
      if (mounted) {
        final nowMode = notifier.permissionModeFor(planHostId);
        if (shouldRestorePermissionMode(before: wasMode, now: nowMode)) {
          notifier.setPermissionModeForHost(planHostId, wasMode);
        }
      }
    }
  }

  /// `/model`：切模型。歧义时列候选让用户选，不猜——猜错等于换了一个计费不同的后端。
  bool _handleModelCommand(String? rest) {
    if (_activeAgentBusy) {
      _showGoalHint(AppLocalizations.of(context)!.terminalModelLockedRunning);
      return true;
    }
    final choices =
        AIModelSelectionService.allChoices(ref.read(aiEndpointsProvider));
    if (choices.isEmpty) {
      _showGoalHint('还没有配置模型，请到 设置 → AI 模型 添加');
      return true;
    }
    String labelOf(AIModelChoice c) {
      final duplicated = choices
              .where((x) =>
                  x.displayName.toLowerCase() == c.displayName.toLowerCase())
              .length >
          1;
      return duplicated ? '${c.displayName}（${c.endpointName}）' : c.displayName;
    }

    final labels = {for (final c in choices) c.modelId: labelOf(c)};
    final wanted = (rest ?? '').trim().toLowerCase();
    if (wanted.isEmpty) {
      final currentLabel =
          labels[_currentModelConfig?.id] ?? _currentModelConfig?.name ?? '未选择';
      final tier = _currentModelConfig?.reasoningLabel;
      _showGoalHint('当前：$currentLabel${tier == null ? '' : ' $tier'}\n'
          '可选：${labels.values.join('、')}\n用法：/model <名称>');
      return true;
    }
    final candidates = matchModelNames(labels.values, wanted);
    if (candidates.isEmpty) {
      _showGoalHint('没有叫「$rest」的模型\n可选：${labels.values.join('、')}');
      return true;
    }
    if (candidates.length > 1) {
      _showGoalHint('「$rest」匹配到多个模型：${candidates.join('、')}\n请用完整名称');
      return true;
    }
    final target = choices.firstWhere((c) => labels[c.modelId] == candidates.first);
    _applyModelChoice(target);
    _showGoalHint('已切换到模型：${labels[target.modelId]}');
    return true;
  }

  /// `/export`：把当前会话复制到剪贴板，并指出执行日志文件的位置。
  /// 不弹保存框、不新造格式——剪贴板是终端用户最容易接住的落点，
  /// 日志则已经由 tracer 落成 NDJSON，指路比再造一份导出器更准。
  bool _exportConversation() {
    final text = formatConversationForExport(ref.read(agentProvider).chatItems);
    if (text.isEmpty) {
      _showGoalHint('当前会话还没有可导出的内容');
      return true;
    }
    Clipboard.setData(ClipboardData(text: text));
    final chars = text.characters.length;
    AgentTracer.instance.tracePath().then((path) {
      if (!mounted) return;
      _showGoalHint(path == null
          ? '会话已复制到剪贴板（$chars 字）'
          : '会话已复制到剪贴板（$chars 字）\n执行日志：$path');
    }).catchError((Object e) {
      if (!mounted) return;
      _showGoalHint('会话已复制到剪贴板（$chars 字）\n日志路径读取失败：$e');
    });
    return true;
  }

  // ==================== 终端右键菜单动作 ====================

  /// 终端右键里需要页面能力的动作：Agent / 片段 / SFTP / 审计。
  /// 纯本地动作（复制、清屏、字号、保存）在 TerminalView 内部完成。
  Future<void> _handleTerminalMenuIntent(
    tp.TerminalTab? tab,
    TerminalMenuIntent intent,
    String text, {
    String? paneId,
  }) async {
    switch (intent) {
      case TerminalMenuIntent.sendToAgent:
        _putIntoAgentInput(tab, agentExplainPrompt(text));
        break;
      case TerminalMenuIntent.askError:
        _putIntoAgentInput(tab, agentErrorPrompt(text));
        break;
      case TerminalMenuIntent.askBlock:
        _putIntoAgentInput(tab, agentBlockPrompt(text));
        break;
      case TerminalMenuIntent.saveSnippet:
        await _saveSelectionAsSnippet(text);
        break;
      case TerminalMenuIntent.openSftp:
        if (tab == null || tab.isLocal) return;
        setState(() {
          _tabSftpInitialPath[tab.id] = text; // 空串表示回到默认目录
          _tabSftpVisible[tab.id] = true;
        });
        break;
      case TerminalMenuIntent.openAudit:
        final hostId = tab?.hostId;
        if (hostId == null || hostId.isEmpty) return;
        context.push('/audit-log?hostId=${Uri.encodeComponent(hostId)}');
        break;
      case TerminalMenuIntent.viewChanges:
        final hostId = tab?.hostId;
        if (hostId == null || hostId.isEmpty) return;
        context.push('/change-records?hostId=${Uri.encodeComponent(hostId)}');
        break;
      case TerminalMenuIntent.showHistory:
        _showCommandHistory(paneId: paneId);
        break;
    }
  }

  /// 只把内容放进 Agent 输入框，不自动发送：右键是"帮我看看"，不是"替我执行"
  void _putIntoAgentInput(tp.TerminalTab? tab, String prompt) {
    final tabId = tab?.id ?? _currentTabId ?? '';
    setState(() {
      _tabAiInputText[tabId] = prompt;
      _setAiPanelVisible(tabId, true);
    });
    clearTopToast();
    showTopSnackBar(context,
      const SnackBar(
        content: Text('已放入 Agent 输入框', style: TextStyle(fontSize: fSmall)),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.all(16),
      ),
    );
  }

  Future<void> _saveSelectionAsSnippet(String command) async {
    if (command.trim().isEmpty) return;
    final tc = ThemeColors.of(context);
    final controller = TextEditingController(text: '终端命令');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: tc.cardElevated,
        title: Text('存为命令片段',
            style: TextStyle(color: tc.textMain, fontSize: fBody)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              style: TextStyle(color: tc.textMain, fontSize: fBody),
              decoration: InputDecoration(
                isDense: true,
                labelText: '片段名称',
                labelStyle: TextStyle(color: tc.textSub, fontSize: fSmall),
              ),
              onSubmitted: (value) => Navigator.of(ctx).pop(value),
            ),
            const SizedBox(height: 10),
            Text(
              command,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontFamilyFallback: kMonoFontFallback,
                fontSize: fMono,
                color: tc.textSub,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    await SnippetsDao.upsert(CommandSnippet.create(
      id: 'snippet_${DateTime.now().microsecondsSinceEpoch}',
      name: trimmed,
      command: command,
      description: '来自终端右键',
    ));
    await SnippetsDao.loadCache();
    if (!mounted) return;
    clearTopToast();
    showTopSnackBar(context,
      SnackBar(
        content: Text('已保存到命令片段：$trimmed',
            style: const TextStyle(fontSize: fSmall)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  void _showCommandHelp() {
    final tc = ThemeColors.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Agent 命令'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final c in kSlashCommands)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 92,
                        child: Text(
                          c.command,
                          style: TextStyle(
                            color: tc.brand,
                            fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                            fontSize: fSmall,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          c.description,
                          style: TextStyle(
                            color: tc.textSub,
                            fontSize: fMicro,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                '输入 / 可搜索全部命令与运维模板；↑↓ 切换、Tab 选择、Enter 执行。',
                style: TextStyle(color: tc.textSub, fontSize: fMicro),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// `/goal` 命令。子命令与目标文本的消歧见 [parseGoalCommand]。
  bool _handleGoalCommand(String? rest, {required bool isConnected}) {
    final notifier = ref.read(agentProvider.notifier);
    final hostId = ref.read(agentProvider).hostId ?? 'local';
    final cmd = parseGoalCommand(rest);
    final existing = notifier.goalFor(hostId);

    switch (cmd.sub) {
      case null:
        if (cmd.objective.isEmpty) {
          _showGoalHint(existing == null
              ? '用法：/goal <目标> 开始；/goal pause | resume | edit <新目标> | done | clear'
              : '${existing.objective}\n状态 ${existing.status.name} · '
                  '轮次 ${existing.roundsUsed}/${existing.maxRounds}'
                  '${(existing.note ?? '').isEmpty ? '' : ' · ${existing.note}'}');
          return true;
        }
        if (existing?.isActive == true) {
          _showGoalHint('已有进行中的目标：${existing!.objective}\n'
              '先 /goal done 结束，或 /goal edit <新目标> 改写');
          return true;
        }
        final created = notifier.createGoal(hostId, cmd.objective);
        if (created == null) {
          _showGoalHint('目标文本不能为空');
          return true;
        }
        // 立刻跑第一轮：`/goal xxx` 的语义是"开始"，不是"先记下来"
        _sendToAgent(buildGoalContinuationPrompt(created),
            isConnected: isConnected);
        return true;
      case 'pause':
        _showGoalHint(notifier.pauseGoal(hostId)
            ? '目标已暂停，不再自动续跑'
            : '没有进行中的目标');
        return true;
      case 'resume':
        // 失败原因（预算用尽 / 未连接 / 不在本会话）由 resumeGoal 写进 error
        _showGoalHint(notifier.resumeGoal(hostId)
            ? '目标已恢复，接着跑下一轮'
            : '目标未能恢复，原因见上方提示');
        return true;
      case 'edit':
        if (cmd.objective.isEmpty) {
          _showGoalHint('用法：/goal edit <新目标>');
          return true;
        }
        _showGoalHint(notifier.editGoal(hostId, cmd.objective)
            ? '目标已改写（已用轮次继续累计，编辑不能重置预算）'
            : '当前没有目标可改写；用 /goal <目标> 新建');
        return true;
      case 'done':
        _showGoalHint(notifier.finishGoal(hostId) ? '目标已结束' : '没有进行中的目标');
        return true;
      case 'clear':
        notifier.clearGoal(hostId);
        _showGoalHint('目标记录已清除');
        return true;
      default:
        return false;
    }
  }

  // ==================== 斜杠命令 ====================
  /// 处理斜杠命令，返回 true 表示已处理（不再发送）
  bool _handleSlashCommand(String command, {required bool isConnected}) {
    final l10n = AppLocalizations.of(context)!;
    // 命令名与参数分开取：整串 lowercase 会毁掉用户的目标原文，
    // 而"首个 / 就当命令"会让 /etc/nginx 这类路径没法发给模型
    final parsed = parseSlashCommand(
      command,
      knownNames: kSlashCommands.map((c) => c.command),
    );
    if (parsed == null) return false;
    switch (parsed.name) {
      case '/new':
        _autoScrollChat = true;
        ref.read(agentProvider.notifier).newSession();
        showTopSnackBar(context, 
          SnackBar(
            content: Text(l10n.terminalSessionCreated, style: const TextStyle(fontSize: 13)),
            duration: const Duration(seconds: 1),
          ),
        );
        return true;
      case '/goal':
        return _handleGoalCommand(parsed.rest, isConnected: isConnected);
      case '/plan':
        final objective = (parsed.rest ?? '').trim();
        if (objective.isEmpty) {
          _showGoalHint('用法：/plan <要计划的目标>');
          return true;
        }
        _runPlanOnly(objective, isConnected: isConnected);
        return true;
      case '/model':
        return _handleModelCommand(parsed.rest);
      case '/permission':
        final ui = AgentUiText.of(context);
        final current = ref.read(agentProvider).permissionMode;
        final wanted = parsePermissionMode(parsed.rest);
        if ((parsed.rest ?? '').trim().isEmpty) {
          _showGoalHint(
              '${ui.permissionModeCurrent(ui.permissionModeLabel(current))}\n'
              '${ui.permissionModeUsage}');
          return true;
        }
        if (wanted == null) {
          _showGoalHint(ui.permissionModeUsage);
          return true;
        }
        _applyPermissionMode(wanted);
        return true;
      case '/help':
        _showCommandHelp();
        return true;
      case '/export':
        return _exportConversation();
      case '/compact':
        // §5-V8：压缩会并发起第二条流并重写引擎的对话历史，任务运行中做这件事
        // 会让正在跑的 ReAct 循环看到被改写过的历史。输入框运行中本就禁用，
        // 但目标模式会自动续跑，这个窗口被打开了，所以显式挡住。
        if (ref.read(agentProvider).isRunning) {
          _showGoalHint('任务进行中不能压缩记忆，请先停止任务');
          return true;
        }
        if (!isConnected) {
          showTopSnackBar(context, 
            SnackBar(
              content: Text(l10n.terminalConnectTerminalFirst, style: const TextStyle(fontSize: 13)),
              duration: const Duration(seconds: 1),
            ),
          );
          return true;
        }
        if (!_checkAIModelConfigured()) {
          _showAIModelNotConfiguredHint();
          return true;
        }
        ref.read(agentProvider.notifier).compact().then((_) {
          if (!mounted) return;
          showTopSnackBar(context, 
            SnackBar(
              content: Text(l10n.terminalCompactionDone, style: const TextStyle(fontSize: 13)),
              duration: const Duration(seconds: 1),
            ),
          );
        }).catchError((e) {
          if (!mounted) return;
          showTopSnackBar(context, 
            SnackBar(
              content: Text(l10n.terminalCompactionFailed('$e'), style: const TextStyle(fontSize: 13)),
              duration: const Duration(seconds: 2),
            ),
          );
        });
        return true;
      default:
        // 未知斜杠命令：当作普通文本发送
        return false;
    }
  }

  // ==================== 底部栏 ====================
  /// 清单是否正贴底常驻（运行 / 暂停 / 待确认）。
  ///
  /// 会话流里那份 `PlanPanel` 据此抑制，避免同一份计划同屏出现两次。
  /// 条件必须是任务状态而不是"是否存在贴底卡"这个布尔值：终态后贴底卡消失，
  /// 会话流那份要恢复显示，否则历史回看时清单两处都看不见。
  bool get _planPinnedActive {
    final s = ref.read(agentProvider);
    return s.currentTask != null &&
        (s.isRunning ||
            s.status == AgentStatus.paused ||
            s.status == AgentStatus.waitingConfirm);
  }

  Widget _buildBottomBar(AgentState agentState, tp.TerminalTab? tab) {
    final isConnected = tab?.isConnected == true;
    // 端点状态已注入 API Key；当前模型优先取活跃 host 实际使用的配置
    final endpoints = ref.watch(aiEndpointsProvider);
    final currentModel =
        ref.read(agentProvider.notifier).modelConfig ?? _currentModelConfig;
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    // 斜杠建议里同时列出运维模板：内置模板在读取时才本地化，避免把首次
    // 启动语言固化到持久化数据里。
    final runbooks =
        BuiltinRunbookI18n.localizeAll(ref.watch(runbooksProvider));
    final slashExtras = <SlashCommand>[
      for (final rb in runbooks)
        SlashCommand(
          '/${rb.name}',
          rb.description ?? '',
          isTemplate: true,
          leading: rb.icon.isEmpty ? '📋' : rb.icon,
          badge: rb.type == RunbookType.agent
              ? 'AI'
              : l10n.terminalRunbookTypeCommand,
          searchText: '${rb.name} ${rb.description ?? ''}',
          onSelect: () => _runRunbook(rb),
        ),
    ];
    final List<PlanStep> pinnedPlan = agentState.chatItems.isNotEmpty &&
            agentState.chatItems.last.role == 'assistant'
        ? _findLatestPlan(agentState.chatItems.last.events)
        : const [];

    return Container(
      // 设计稿 .ai-footer：上下 8/10、左右 10。左右从 14 收到 12，和消息列表
      // 的 12 对齐；上边线用发丝线（hairline），面板内部的横向分隔比外框
      // 12% 更轻，否则底栏像被焊死在面板上。
      padding: EdgeInsets.only(
        left: 12, right: 12, top: 8,
        bottom: 10 + (_isMobile ? MediaQuery.of(context).padding.bottom : 0),
      ),
      decoration: BoxDecoration(
        color: tc.card,
        border: Border(top: BorderSide(color: tc.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 重连状态
          if (_reconnectingHostLabel != null)
            ReconnectingBanner(
              tc: tc,
              hostLabel: _reconnectingHostLabel!,
            ),
          // 常驻运行条：目标 / 阶段 / 步数 / 计时 / 计划进度 / 暂停停止
          if (agentState.currentTask != null &&
              (agentState.isRunning ||
                  agentState.status == AgentStatus.paused ||
                  agentState.status == AgentStatus.waitingConfirm))
            LiveOperationBar(
              task: agentState.currentTask,
              status: agentState.status,
              tc: tc,
              plan: pinnedPlan,
              onPause: () => ref.read(agentProvider.notifier).pause(),
              onResume: () => ref.read(agentProvider.notifier).resume(),
              onStop: () => ref.read(agentProvider.notifier).cancel(),
              onOpenTerminal: () {
                setState(() => _setAiPanelVisible(_currentTabId, false));
                SettingsDao.set('aiPanelVisible', false);
              },
            ),
          // 执行清单贴底常驻：运行中"我现在在哪"的锚点，跟着消息流滚走等于没有。
          // 限高 168 卡内滚动，长计划不会把输入框顶出屏幕。
          if (_planPinnedActive && pinnedPlan.isNotEmpty)
            PlanPanel(
              steps: pinnedPlan,
              tc: tc,
              maxHeight: 168,
            ),
          // 目标行：清单之下、输入框之上（参考图顺序）。运行中输入框禁用，
          // 暂停/编辑/结束必须在这里可点，只给 /goal 命令等于没法中途停下。
          if (agentState.goal != null)
            AgentGoalBanner(
              goal: agentState.goal!,
              tc: tc,
              onPause: () => ref
                  .read(agentProvider.notifier)
                  .pauseGoal(agentState.goal!.hostId),
              onResume: () => ref
                  .read(agentProvider.notifier)
                  .resumeGoal(agentState.goal!.hostId),
              onFinish: () {
                final g = agentState.goal!;
                final notifier = ref.read(agentProvider.notifier);
                if (g.status == AgentGoalStatus.finished) {
                  notifier.clearGoal(g.hostId);
                } else {
                  notifier.finishGoal(g.hostId);
                }
              },
              onEdit: (text) => ref
                  .read(agentProvider.notifier)
                  .editGoal(agentState.goal!.hostId, text),
            ),
          // 工具栏
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Agent / 编排模式胶囊
              _ModeCapsule(
                isOrchestratorMode: agentState.isOrchestratorMode,
                connectedCount: ref.read(tp.terminalProvider).tabs.where((t) => t.isConnected && !t.isLocal).length,
                totalHosts: HostsDao.cached.length,
                onTap: agentState.isOrchestratorMode ? () => _showOrchestratorHosts(tc) : null,
              ),
              const SizedBox(width: 6),
              // 日志按钮
              _buildToolbarIconButton(
                icon: Icons.terminal_outlined,
                tooltip: l10n.terminalAgentLog,
                onTap: () => _showAgentLogDialog(context),
                tc: tc,
              ),
              const SizedBox(width: 4),
              // 历史按钮
              _buildToolbarIconButton(
                icon: Icons.history_outlined,
                tooltip: l10n.terminalSessionHistory,
                onTap: () => _showSessionHistoryPanel(context),
                tc: tc,
              ),
              const SizedBox(width: 4),
              // 新建会话：不用先打开历史面板
              _buildToolbarIconButton(
                icon: Icons.add_comment_outlined,
                tooltip: l10n.sessionNew,
                onTap: _startNewSession,
                tc: tc,
              ),
              const SizedBox(width: 4),
              // 联网搜索切换（会话级，覆盖全局开关；下次任务生效）
              _buildToolbarIconButton(
                icon: Icons.travel_explore_rounded,
                tooltip: agentState.isWebSearchEnabled
                    ? '联网搜索：已启用（下次任务生效）'
                    : '联网搜索：未启用（点击启用，下次任务生效）',
                onTap: () {
                  ref.read(agentProvider.notifier).toggleWebSearch();
                },
                tc: tc,
                active: agentState.isWebSearchEnabled,
              ),
              const SizedBox(width: 4),
              // 运维模板（Runbook）
              _buildToolbarIconButton(
                icon: Icons.bolt_outlined,
                tooltip: l10n.terminalRunbookTemplates,
                onTap: () => _showRunbookTemplates(tc),
                tc: tc,
              ),
              const SizedBox(width: 4),
              // 多机编排开关：原来挤在输入框里和发送按钮并排，挪到这一排工具按钮之后
              _buildToolbarIconButton(
                icon: Icons.hub_outlined,
                tooltip: agentState.isOrchestratorMode
                    ? l10n.orchExitMode
                    : l10n.orchEnterMode,
                onTap: () {
                  ref.read(agentProvider.notifier).toggleOrchestratorMode();
                },
                tc: tc,
                active: agentState.isOrchestratorMode,
              ),
              const Spacer(),
              // 运行状态指示
              if (agentState.isRunning)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: tc.brand.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rFull),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 10, height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: tc.brand),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        agentState.status == AgentStatus.executing
                            ? UiText.t('执行中', 'Executing')
                            : UiText.t('思考中', 'Thinking'),
                        style: TextStyle(fontSize: fMicro, color: tc.brand, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              if (agentState.isRunning)
                const SizedBox(width: 6),
            ],
          ),
          const SizedBox(height: 8),
          // 输入框
          AIPromptInput(
            enabled: isConnected,
            isRunning: agentState.isRunning,
            hintText: _getInputHint(isConnected, agentState.isRunning, agentState.isOrchestratorMode,
                connecting: tab?.isConnecting == true),
            initialText: _tabAiInputText[tab?.id ?? _currentTabId ?? ''] ?? '',
            accentColor: tc.brand,
            isOrchestratorMode: agentState.isOrchestratorMode,
            permissionMode: agentState.permissionMode,
            onPermissionModeChanged: _applyPermissionMode,
            onFocusChanged: (focused) {
              setState(() => _aiInputFocused = focused);
            },
            onChanged: (text) { _tabAiInputText[tab?.id ?? _currentTabId ?? ''] = text; },
            onSlashCommand: (command) {
              return _handleSlashCommand(command, isConnected: isConnected);
            },
            slashExtras: slashExtras,
            onStop: () => ref.read(agentProvider.notifier).cancel(),
            onSend: (text) => _sendToAgent(text, isConnected: isConnected),
            footer: _buildModelCapsule(currentModel, endpoints, tc),
          ),
          // 底边状态条：参考界面把数字放在输入框之下、贴着窗口底边，运行中与终态
          // 共用同一条。位置不随任务结束而改变，用户不用来回找数字。
          if (agentState.currentTask != null)
            AgentMetricsBar(
              task: agentState.currentTask!,
              tc: tc,
              contextWindow: currentModel?.effectiveContextWindow,
              running: agentState.isRunning,
            ),
        ],
      ),
    );
  }

  /// 工具栏图标按钮
  Widget _buildToolbarIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    required ThemeColors tc,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        // 只有图标本体可命中的话，28×28 按钮的边框与间隙点了没反应
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: active ? cWarning.withValues(alpha: 0.10) : tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
            border: active ? Border.all(color: cWarning) : null,
          ),
          child: Icon(icon, size: 14, color: active ? cWarning : tc.textSub),
        ),
      ),
    );
  }

  /// 输入框底部的模型 + 思考档位胶囊。点开是按端点分组的模型选择面板。
  Widget _buildModelCapsule(
      AIModelConfig? currentModel, List<AIEndpoint> endpoints, ThemeColors tc) {
    final l10n = AppLocalizations.of(context)!;
    final choices = AIModelSelectionService.allChoices(endpoints);

    if (choices.isEmpty) {
      return Tooltip(
        message: l10n.aiModelEmptyTitle,
        child: InkWell(
          // 模型管理就在抽屉设置里，不再跳整页。
          onTap: () =>
              _showNavDrawer(NavDrawer.sectionSettings, group: 'ai'),
          borderRadius: BorderRadius.circular(rFull),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: cWarning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(rFull),
              border: Border.all(color: cWarning.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 12, color: cWarning),
                const SizedBox(width: 4),
                Text(
                  l10n.terminalConfigureModel,
                  style: const TextStyle(fontSize: fMicro, color: cWarning),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final currentChoice = currentModel == null
        ? null
        : AIModelSelectionService.findChoice(endpoints, currentModel.id);
    final labelBase =
        currentChoice?.displayName ?? currentModel?.name ?? l10n.terminalModel;
    final effort = currentModel?.reasoningLabel;
    final label =
        effort == null || effort.isEmpty ? labelBase : '$labelBase $effort';

    String? currentTierLevel;
    if (currentChoice != null) {
      currentTierLevel = currentChoice.model
          .resolveReasoningTier(
              AIModelSelectionService.tierFor(currentChoice.modelId))
          ?.level;
    }

    return MenuAnchor(
      controller: _modelMenuController,
      alignmentOffset: const Offset(0, -8),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(tc.cardElevated),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        elevation: const WidgetStatePropertyAll(10),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rMedium),
            side: BorderSide(color: tc.border),
          ),
        ),
      ),
      menuChildren: [
        ModelPickerPanel(
          endpoints: endpoints,
          currentModelId: currentModel?.id,
          currentTierLevel: currentTierLevel,
          tc: tc,
          onModelSelected: (choice, tier) =>
              _applyModelChoice(choice, tier: tier),
          onTierSelected: _applyReasoningTier,
          onManage: () {
            _modelMenuController.close();
            _showNavDrawer(NavDrawer.sectionSettings, group: 'ai');
          },
          onDone: () => _modelMenuController.close(),
        ),
      ],
      builder: (context, controller, child) {
        return Tooltip(
          message: l10n.terminalModelAndReasoning,
          child: InkWell(
            borderRadius: BorderRadius.circular(rFull),
            onTap: () {
              if (_activeAgentBusy) {
                _showGoalHint(l10n.terminalModelLockedRunning);
                return;
              }
              controller.isOpen ? controller.close() : controller.open();
            },
            child: Container(
              // 与左侧权限胶囊同高（设计稿两个 cap-wrap 都是 30）、透明底 + 细描边，
              // 一排控件的高度基线才统一。
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(rFull),
                border: Border.all(color: tc.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.psychology_outlined,
                      size: 12, color: tc.textMuted),
                  const SizedBox(width: 4),
                  // AI 面板按设计稿收到 320px 后，输入框里的胶囊只剩 ~130px：
                  // 模型名必须可压缩，否则 Row 直接溢出（原来靠面板够宽蒙混过去）。
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 190),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: fMicro,
                          color: tc.textSub,
                          height: 1.0,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  // 这里原本还有一个 11px 的 unfold_more：320px 面板下它和
                  // 权限胶囊一起把模型名挤成 "...flash-n..."。胶囊整体可点，
                  // 箭头不是必须的，省下的 14px 正好让 "…-next High" 完整露出来。
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ==================== 快捷按键行 ====================
  Widget _buildQuickKeysBar(tp.TerminalTab? activeTab) {
    final tc = ThemeColors.of(context);
    final isConnected = activeTab?.isConnected == true;

    // 高频组合键（始终显示）
    final coreKeys = [
      const _QuickKey('ESC', '\x1b'),
      const _QuickKey('Tab', '\t'),
      const _QuickKey('⌃C', '\x03'),
      const _QuickKey('⌃D', '\x04'),
      const _QuickKey('⌃Z', '\x1a'),
      const _QuickKey('⌃L', '\x0c'),
    ];
    // readline 快捷键
    final readlineKeys = [
      const _QuickKey('⌃A', '\x01'),
      const _QuickKey('⌃E', '\x05'),
      const _QuickKey('⌃U', '\x15'),  // 删除行首到光标
      const _QuickKey('⌃K', '\x0b'),  // 删除光标到行尾
      const _QuickKey('⌃W', '\x17'),  // 删除前一个单词
      const _QuickKey('⌃R', '\x12'),  // 搜索历史命令
    ];
    // 方向 + 导航键
    final navKeys = [
      const _QuickKey('↑', '\x1b[A'),
      const _QuickKey('↓', '\x1b[B'),
      const _QuickKey('←', '\x1b[D'),
      const _QuickKey('→', '\x1b[C'),
      const _QuickKey('Home', '\x1b[H'),
      const _QuickKey('End', '\x1b[F'),
      const _QuickKey('PgUp', '\x1b[5~'),
      const _QuickKey('PgDn', '\x1b[6~'),
    ];
    final keys = [...coreKeys, ...readlineKeys, ...navKeys];
    // 分组索引：高频键用主色高亮
    final coreCount = coreKeys.length;

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: tc.card,
        border: Border(top: BorderSide(color: tc.border.withValues(alpha: 0.3))),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        itemCount: keys.length,
        separatorBuilder: (_, index) {
          // 在高频键和其他键之间加分隔线
          if (index == coreCount - 1 || index == coreCount + readlineKeys.length - 1) {
            return Container(
              width: 1,
              margin: const EdgeInsets.symmetric(vertical: 4),
              color: tc.border.withValues(alpha: 0.4),
            );
          }
          return const SizedBox(width: 3);
        },
        itemBuilder: (context, index) {
          final key = keys[index];
          final isCore = index < coreCount;
          final isNav = index >= coreCount + readlineKeys.length;
          return GestureDetector(
            onTap: isConnected ? () => _sendKey(key.sequence, activeTab) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isCore
                    ? tc.brand.withValues(alpha: isConnected ? 0.12 : 0.05)
                    : isNav
                        ? tc.ok.withValues(alpha: isConnected ? 0.08 : 0.03)
                        : tc.surface,
                borderRadius: BorderRadius.circular(rXSmall),
                border: Border.all(
                  color: isCore
                      ? tc.brand.withValues(alpha: isConnected ? 0.3 : 0.1)
                      : isNav
                          ? tc.ok.withValues(alpha: isConnected ? 0.2 : 0.05)
                          : tc.border.withValues(alpha: 0.3),
                ),
              ),
              child: Center(
                child: Text(
                  key.label,
                  style: TextStyle(
                    fontSize: fMicro,
                    color: isCore
                        ? (isConnected ? tc.brand : tc.textMuted)
                        : isNav
                            ? (isConnected ? tc.ok : tc.textMuted)
                            : (isConnected ? tc.textSub : tc.textMuted),
                    fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                    fontWeight: isCore ? FontWeight.w600 : FontWeight.w500,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _sendKey(String sequence, tp.TerminalTab? tab) {
    if (tab == null) return;
    if (tab.isLocal) {
      tab.localService?.writeToTerminal(sequence);
    } else {
      tab.service?.writeToTerminal(sequence);
    }
  }

  // ==================== 工具方法 ====================

  /// 编排模式主机清单浮层（底部弹出）
  void _showOrchestratorHosts(ThemeColors tc) {
    final tabs = ref.read(tp.terminalProvider).tabs;
    final connectedHostIds = <String>{};
    for (final t in tabs) {
      if (t.isConnected && !t.isLocal) {
        connectedHostIds.add(t.hostId);
      }
    }
    final allHosts = HostsDao.cached.toList();
    // 按分组聚合
    final grouped = <String, List<HostConfig>>{};
    for (final h in allHosts) {
      grouped.putIfAbsent(h.group, () => []).add(h);
    }
    final groupNames = grouped.keys.toList()..sort();

    showModalBottomSheet(
      context: context,
      backgroundColor: tc.cardElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rMedium)),
      ),
      builder: (ctx) {
        return _OrchestratorHostsSheet(
          tc: tc,
          allHosts: allHosts,
          grouped: grouped,
          groupNames: groupNames,
          connectedHostIds: connectedHostIds,
          onExit: () {
            Navigator.of(ctx).pop();
            ref.read(agentProvider.notifier).disableOrchestratorMode();
          },
        );
      },
    );
  }

  /// 运维工作流选择浮层（从持久化的 Runbook 加载）
  void _showRunbookTemplates(ThemeColors tc) {
    final l10n = AppLocalizations.of(context)!;
    final runbooks =
        BuiltinRunbookI18n.localizeAll(ref.read(runbooksProvider));
    final grouped = <RunbookCategory, List<Runbook>>{};
    for (final rb in runbooks) {
      grouped.putIfAbsent(rb.category, () => []).add(rb);
    }
    const order = [
      RunbookCategory.inspection,
      RunbookCategory.security,
      RunbookCategory.deployment,
      RunbookCategory.troubleshooting,
      RunbookCategory.maintenance,
      RunbookCategory.custom,
    ];
    final categoryLabels = {
      RunbookCategory.inspection: l10n.runbookCategoryInspection,
      RunbookCategory.security: l10n.runbookCategorySecurity,
      RunbookCategory.deployment: l10n.runbookCategoryDeployment,
      RunbookCategory.troubleshooting: l10n.runbookCategoryTroubleshooting,
      RunbookCategory.maintenance: l10n.runbookCategoryMaintenance,
      RunbookCategory.custom: l10n.runbookCategoryCustom,
    };

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: tc.cardElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rMedium)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.bolt, size: 16, color: tc.brand),
                    const SizedBox(width: 8),
                    Text(
                      l10n.runbooks,
                      style: TextStyle(
                        fontSize: fBody,
                        color: tc.textMain,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () {
                        // 「管理」和抽屉里是同一份工作流列表：先收面板，再开
                        // 抽屉的工作流分区。跳整页 /runbooks 等于同一个功能
                        // 有两个长相不同的页面。
                        Navigator.of(ctx).pop();
                        _showNavDrawer(NavDrawer.sectionRunbooks);
                      },
                      icon: const Icon(Icons.settings_outlined, size: 14),
                      label: Text(l10n.terminalManage),
                      style: TextButton.styleFrom(
                        foregroundColor: tc.brand,
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: const TextStyle(fontSize: fSmall),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: tc.border.withValues(alpha: 0.5)),
              if (runbooks.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
                  child: Column(
                    children: [
                      Icon(Icons.auto_awesome_motion, size: 40, color: tc.textSub),
                      const SizedBox(height: 8),
                      Text(l10n.terminalNoRunbooks, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                      const SizedBox(height: 4),
                      Text(l10n.terminalNoRunbooksHint, style: TextStyle(color: tc.textSub, fontSize: fMicro)),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final cat in order)
                        if (grouped[cat] != null && grouped[cat]!.isNotEmpty) ...[
                          _buildRunbookSectionHeader(tc, categoryLabels[cat]!, grouped[cat]!.length),
                          for (final rb in grouped[cat]!)
                            _buildRunbookTile(tc, ctx, rb),
                        ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRunbookSectionHeader(ThemeColors tc, String label, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: fMicro,
              color: tc.textSub,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(fontSize: fMicro, color: tc.textSub),
          ),
        ],
      ),
    );
  }

  Widget _buildRunbookTile(ThemeColors tc, BuildContext sheetCtx, Runbook rb) {
    final l10n = AppLocalizations.of(context)!;
    final isAgent = rb.type == RunbookType.agent;
    final typeColor = isAgent ? tc.brand : tc.ok;
    return ListTile(
      leading: Text(
        rb.icon.isEmpty ? '📋' : rb.icon,
        style: const TextStyle(fontSize: 22),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              rb.name,
              style: TextStyle(
                fontSize: fBody,
                color: tc.textMain,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: typeColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(rXSmall),
              border: Border.all(color: typeColor.withValues(alpha: 0.5)),
            ),
            child: Text(
              isAgent ? 'AI' : l10n.terminalRunbookTypeCommand,
              style: TextStyle(color: typeColor, fontSize: fMicro),
            ),
          ),
        ],
      ),
      subtitle: Text(
        rb.description ?? '',
        style: TextStyle(fontSize: fSmall, color: tc.textSub),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        Navigator.of(sheetCtx).pop();
        _runRunbook(rb);
      },
    );
  }

  /// 运维模板的统一执行入口：斜杠建议浮层与工具栏弹层共用，
  /// 避免两条入口在 agent / command 分流上产生行为差异。
  void _runRunbook(Runbook rb) {
    if (rb.type == RunbookType.agent) {
      _sendRunbookPrompt(rb);
    } else {
      _sendRunbookCommand(rb);
    }
  }

  // ==================== 命令面板（Ctrl+K）====================
  /// 零占位导航的统一入口：主机 / 快捷命令 / 工作流 / 页面 / 操作。
  /// 数据全部来自同步缓存（Dao.cached），面板即时可用，不等异步。
  void _showCommandPalette() {
    CommandPalette.show(context, entries: _buildPaletteEntries());
  }

  List<CommandPaletteEntry> _buildPaletteEntries() {
    final entries = <CommandPaletteEntry>[];
    final activeTab = ref.read(tp.terminalProvider).activeTab;

    // —— 操作 ——
    void op(String label, IconData icon, VoidCallback run,
            {List<String> keywords = const []}) =>
        entries.add(CommandPaletteEntry(
          label: label,
          icon: icon,
          group: UiText.t('操作', 'Actions'),
          onRun: run,
          keywords: keywords,
        ));

    op(UiText.t('新建连接', 'New connection'), Icons.add_circle_outline,
        _showAddHostDialog,
        keywords: const ['new', 'tab', 'host', '新建', '标签']);
    if (activeTab != null) {
      op(UiText.t('重连当前标签', 'Reconnect tab'), Icons.refresh_rounded,
          () => _reconnectTab(activeTab),
          keywords: const ['reconnect']);
      op(
        _effectiveAiVisible(activeTab.id)
            ? UiText.t('收起 AI 面板', 'Collapse AI panel')
            : UiText.t('展开 AI 面板', 'Expand AI panel'),
        Icons.auto_fix_high,
        () => setState(() =>
            _setAiPanelVisible(activeTab.id, !_effectiveAiVisible(activeTab.id))),
        keywords: const ['ai', 'panel'],
      );
      op(
        _isFocusModeFor(activeTab.id)
            ? UiText.t('退出专注模式', 'Exit focus mode')
            : UiText.t('专注模式', 'Focus mode'),
        Icons.fullscreen_rounded,
        _toggleFocusMode,
        keywords: const ['focus'],
      );
      op(
        _monitorVisibleFor(activeTab)
            ? UiText.t('隐藏服务器监控', 'Hide monitor')
            : UiText.t('显示服务器监控', 'Show monitor'),
        Icons.monitor_heart_outlined,
        () => setState(() => _tabMonitorVisible[activeTab.id] =
            !_monitorVisibleFor(activeTab)),
        keywords: const ['monitor'],
      );
      if (!activeTab.isLocal) {
        op(
          (_tabSftpVisible[activeTab.id] ?? false)
              ? UiText.t('关闭 SFTP 面板', 'Close SFTP')
              : UiText.t('打开 SFTP 面板', 'Open SFTP'),
          Icons.folder_outlined,
          () {
            if (_isMobile) {
              context.push('/sftp/${activeTab.hostId}');
            } else {
              setState(() => _tabSftpVisible[activeTab.id] =
                  !(_tabSftpVisible[activeTab.id] ?? false));
            }
          },
          keywords: const ['files', '文件'],
        );
        op(UiText.t('端口转发', 'Port forwarding'), Icons.swap_horiz_rounded,
            _showPortForwardDialog,
            keywords: const ['port', 'forward', 'tunnel']);
      }
    }
    op(UiText.t('命令历史', 'Command history'), Icons.history_rounded,
        _showCommandHistory,
        keywords: const ['history']);
    op(UiText.t('会话历史', 'Session history'), Icons.chat_bubble_outline,
        () => _showSessionHistoryPanel(context),
        keywords: const ['session']);
    op(UiText.t('新建 AI 会话', 'New AI session'), Icons.add_comment_outlined,
        _startNewSession,
        keywords: const ['session', 'new']);

    // —— 整页 ——
    // 只有台账留在这里：它是多列的规则编辑，塞进 600 宽的抽屉会被挤成一团。
    // 五个功能板块一律指到抽屉，不给同一个功能第二个目的地。
    void page(String label, String route, IconData icon,
            {List<String> keywords = const []}) =>
        entries.add(CommandPaletteEntry(
          label: label,
          icon: icon,
          group: UiText.t('整页', 'Full page'),
          onRun: () => context.push(route),
          keywords: keywords,
        ));

    // 五个功能板块都在抽屉里，命令面板也把路指到同一个地方 —— 不给同一件事
    // 第二个目的地（整页 /hosts /snippets /settings…）。
    void section(String label, String id, IconData icon,
            {String? group, List<String> keywords = const []}) =>
        entries.add(CommandPaletteEntry(
          label: label,
          icon: icon,
          group: UiText.t('抽屉', 'Drawer'),
          onRun: () => _showNavDrawer(id, group: group),
          keywords: keywords,
        ));

    section(UiText.t('主机管理', 'Hosts'), NavDrawer.sectionHosts,
        Icons.dns_outlined,
        keywords: const ['server', 'hosts', '服务器']);
    section(UiText.t('快捷命令', 'Snippets'), NavDrawer.sectionSnippets,
        Icons.bolt_outlined,
        keywords: const ['snippet', 'commands']);
    section(UiText.t('运维工作流', 'Runbooks'), NavDrawer.sectionRunbooks,
        Icons.checklist_outlined,
        keywords: const ['runbook', 'workflow']);
    section(UiText.t('操作审计', 'Audit log'), NavDrawer.sectionAudit,
        Icons.fact_check_outlined,
        keywords: const ['audit']);
    section(UiText.t('设置', 'Settings'), NavDrawer.sectionSettings,
        Icons.settings_outlined,
        keywords: const ['settings']);
    section(UiText.t('AI 模型设置', 'AI model settings'),
        NavDrawer.sectionSettings, Icons.psychology_outlined,
        group: 'ai', keywords: const ['agent', 'model']);
    page(UiText.t('变更记录', 'Change records'), '/change-records',
        Icons.receipt_long_outlined,
        keywords: const ['changes']);

    // —— 主机 ——
    const groupHosts = '主机';
    for (final host in HostsDao.cached) {
      entries.add(CommandPaletteEntry(
        label: host.name,
        subtitle: '${host.username}@${host.host}',
        icon: Icons.dns,
        group: groupHosts,
        keywords: [host.host, host.username],
        onRun: () => _openHostTab(host),
      ));
    }

    // —— 快捷命令 ——
    for (final s in SnippetsDao.cached) {
      entries.add(CommandPaletteEntry(
        label: s.name,
        subtitle: s.command,
        icon: Icons.bolt,
        group: UiText.t('快捷命令', 'Snippets'),
        keywords: [s.command],
        onRun: () => _executeSnippet(s),
      ));
    }

    // —— 工作流 ——
    for (final rb in BuiltinRunbookI18n.localizeAll(RunbooksDao.cached)) {
      entries.add(CommandPaletteEntry(
        label: '${rb.icon} ${rb.name}',
        subtitle: rb.description,
        icon: rb.type == RunbookType.agent
            ? Icons.psychology_outlined
            : Icons.terminal,
        group: UiText.t('工作流', 'Runbooks'),
        keywords: [rb.content],
        onRun: () => _runRunbook(rb),
      ));
    }

    return entries;
  }

  /// 发送 Runbook（agent 类型）prompt 到 Agent 执行
  void _sendRunbookPrompt(Runbook rb) async {
    // 校验模型配置、连接状态，并显式 setExecutor
    if (!_checkAIModelConfigured()) {
      _showAIModelNotConfiguredHint();
      return;
    }
    final tab = ref.read(tp.terminalProvider).activeTab;
    if (tab == null || !tab.isConnected) {
      final l10n = AppLocalizations.of(context)!;
      showTopSnackBar(context, 
        SnackBar(
          content: Text(l10n.terminalConnectTerminalForRunbook),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    _autoScrollChat = true;
    // 本地终端用 localService，SSH 用 service
    final CommandExecutor? executor = tab.isLocal == true ? tab.localService : tab.service;
    ref.read(agentProvider.notifier).setExecutor(executor,
        hostId: tab.hostId, tabId: tab.id);
    await ref.read(runbooksProvider.notifier).incrementRunCount(rb.id);
    await ref.read(agentProvider.notifier).startTask(rb.content);
  }

  /// 执行 Runbook（command 类型）：变量替换后直接在终端执行命令
  void _sendRunbookCommand(Runbook rb) async {
    final tab = ref.read(tp.terminalProvider).activeTab;
    if (tab == null || !tab.isConnected) {
      final l10n = AppLocalizations.of(context)!;
      showTopSnackBar(context, 
        SnackBar(
          content: Text(l10n.terminalConnectTerminalForCommand),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    // 处理变量替换
    final variables = rb.getAllVariables();
    final values = <String, String>{};
    if (variables.isNotEmpty) {
      final filled = await _showRunbookVariablesDialog(rb, variables);
      if (filled == null) return; // 用户取消
      values.addAll(filled);
      if (rb.hasUnfilledVariables(values)) {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;
        showTopSnackBar(context, 
          SnackBar(
            content: Text(l10n.terminalUnfilledVariables),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    }
    final resolved = rb.resolveContent(values);
    // 直接写入终端执行
    if (tab.isLocal) {
      tab.localService?.writeToTerminal('$resolved\n');
    } else {
      tab.service?.writeToTerminal('$resolved\n');
    }
    await ref.read(runbooksProvider.notifier).incrementRunCount(rb.id);
  }

  /// Runbook 变量填写对话框，返回 null 表示用户取消
  Future<Map<String, String>?> _showRunbookVariablesDialog(
    Runbook rb,
    List<String> variables,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final controllers = {
      for (final v in variables) v: TextEditingController(),
    };
    final tc = ThemeColors.of(context);
    return showDialog<Map<String, String>>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: tc.cardElevated,
        title: Text(l10n.terminalFillVariables(rb.name), style: TextStyle(color: tc.textMain, fontSize: fBody)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (rb.description != null && rb.description!.isNotEmpty) ...[
                Text(
                  rb.description!,
                  style: TextStyle(color: tc.textSub, fontSize: fSmall),
                ),
                const SizedBox(height: pCompact),
              ],
              Text(l10n.terminalCommandTemplate, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(pSmall),
                decoration: BoxDecoration(
                  color: tc.terminalBg,
                  borderRadius: BorderRadius.circular(rSmall),
                  border: Border.all(color: tc.border),
                ),
                child: SelectableText(
                  rb.content,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                    fontSize: fMono,
                    color: tc.terminalGreen,
                  ),
                ),
              ),
              const SizedBox(height: pCompact),
              ...variables.map(
                (v) => Padding(
                  padding: const EdgeInsets.only(bottom: pSmall),
                  child: TextField(
                    controller: controllers[v],
                    style: TextStyle(color: tc.textMain, fontSize: fBody),
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: '{{$v}}',
                      labelStyle: TextStyle(
                        color: tc.textSub,
                        fontSize: fSmall,
                        fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                      ),
                      filled: true,
                      fillColor: tc.card,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: pCompact,
                        vertical: pSmall,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(rInput),
                        borderSide: BorderSide(color: tc.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(rInput),
                        borderSide: BorderSide(color: tc.brand),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(
                dialogCtx,
                {for (final v in variables) v: controllers[v]!.text.trim()},
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: tc.brand,
              foregroundColor: tc.isLight ? Colors.white : cBg,
            ),
            child: Text(l10n.commonExecute),
          ),
        ],
      ),
    );
  }

  String _getInputHint(bool isConnected, bool isRunning, bool isOrchestrator,
      {bool connecting = false}) {
    final l10n = AppLocalizations.of(context)!;
    if (isRunning) return l10n.terminalInputHintRunning;
    if (connecting) return l10n.connecting;
    if (!isConnected) return l10n.terminalInputHintDisconnected;
    if (isOrchestrator) return l10n.terminalInputHintOrchestrator;
    return l10n.terminalInputHintDefault;
  }

  bool _checkAIModelConfigured() {
    try {
      return AIEndpointsDao.cached.any((e) => e.models.isNotEmpty);
    } catch (_) {
      return false;
    }
  }

  void _showAIModelNotConfiguredHint() {
    final l10n = AppLocalizations.of(context)!;
    showTopSnackBar(context, 
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(l10n.pleaseConfigAIModel, style: const TextStyle(fontSize: fBody)),
          ],
        ),
        backgroundColor: cWarning,
        action: SnackBarAction(
          label: l10n.terminalConfigure,
          textColor: Colors.white,
          onPressed: () =>
              _showNavDrawer(NavDrawer.sectionSettings, group: 'ai'),
        ),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
      ),
    );
  }

  Widget _buildErrorBanner(String? error) {
    if (error == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(6),
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: cDanger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: cDanger.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: cDanger, size: 14),
          const SizedBox(width: 6),
          Expanded(child: Text(error, style: const TextStyle(color: cDanger, fontSize: fSmall), maxLines: 2, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  void _showAgentLogDialog(BuildContext context) {
    showDialog(context: context, builder: (context) => const AgentLogDialog());
  }

  /// 显示会话历史面板（侧边抽屉式）
  void _showSessionHistoryPanel(BuildContext context) {
    showDialog(context: context, builder: (context) => const SessionHistoryDialog());
  }

  /// 新建会话（不经过历史面板）
  Future<void> _startNewSession() async {
    await ref.read(agentProvider.notifier).newSession();
    if (!mounted) return;
    _showOperationMessage(AppLocalizations.of(context)!.terminalSessionCreated);
  }

  /// 执行快捷命令片段
  void _executeSnippet(CommandSnippet snippet) {
    final variables = snippet.getAllVariables();
    if (variables.isEmpty) {
      // 无变量，直接执行
      final tab = ref.read(tp.terminalProvider).activeTab;
      if (tab?.service != null) {
        tab!.service!.execute(snippet.command);
      }
      return;
    }
    // 有变量，弹出填写框
    final controllers = <String, TextEditingController>{};
    for (final v in variables) {
      controllers[v] = TextEditingController();
    }
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: tc.cardElevated,
        title: Text(snippet.name, style: TextStyle(color: tc.textMain)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.snippetResolvedCommand(snippet.command), style: TextStyle(color: tc.textSub, fontSize: fSmall, fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback)),
            const SizedBox(height: 12),
            ...variables.map((v) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: controllers[v],
                style: TextStyle(color: tc.textMain, fontSize: fBody),
                decoration: InputDecoration(
                  labelText: '{{$v}}',
                  labelStyle: TextStyle(color: tc.textSub),
                  filled: true,
                  fillColor: tc.surface,
                ),
              ),
            )),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.commonCancel, style: TextStyle(color: tc.textSub))),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              final resolved = snippet.resolveCommand(controllers.map((k, c) => MapEntry(k, c.text)));
              final tab = ref.read(tp.terminalProvider).activeTab;
              if (tab?.service != null) {
                tab!.service!.execute(resolved);
              }
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: tc.brand,
                foregroundColor: tc.isLight ? Colors.white : cBg,
              ),
            child: Text(l10n.commonExecute),
          ),
        ],
      ),
    );
  }

  /// 端口转发管理（仅 SSH 标签；本地终端无 SSH 连接可复用）
  void _showPortForwardDialog() {
    final tab = ref.read(tp.terminalProvider).activeTab;
    if (tab == null) return;
    if (tab.isLocal) {
      _showOperationMessage(
          UiText.t('本地终端不支持端口转发', 'Port forwarding requires an SSH tab'),
          isError: true);
      return;
    }
    final service =
        _portForwardServices.putIfAbsent(tab.id, PortForwardService.new);
    showDialog<void>(
      context: context,
      builder: (_) => PortForwardDialog(
        service: service,
        client: () => tab.service?.client,
      ),
    );
  }

  /// 命令历史面板：搜历史、填进命令行或直接执行。
  /// 写入走 `writeToTerminal`（与用户按键同一条编码队列），不是 execute，
  /// 这样填入后仍停在命令行等用户确认，非 UTF-8 主机也不会错位。
  /// [paneId] 非空且不是首屏时写入那一屏自己的会话。
  void _showCommandHistory({String? paneId}) {
    final tab = ref.read(tp.terminalProvider).activeTab;
    if (tab == null) return;
    final targetPane = paneId ?? tab.id;
    showDialog<void>(
      context: context,
      builder: (_) => CommandHistoryPanel(
        onInsert: (command, {required bool run}) {
          final text = run ? '$command\r' : command;
          if (targetPane != tab.id) {
            _paneSessionFor(targetPane)?.writeToTerminal(text);
          } else if (tab.isLocal) {
            tab.localService?.writeToTerminal(text);
          } else {
            tab.service?.writeToTerminal(text);
          }
        },
      ),
    );
  }
}

/// 内容分段：文本 or 代码块
class _ContentSegment {
  final String content;
  final bool isCodeBlock;
  /// 代码块语言标识（如 bash、text、python 等），非代码块时为 null
  final String? language;
  _ContentSegment(this.content, this.isCodeBlock, {this.language});
}

/// 快捷按键定义
class _QuickKey {
  final String label;
  final String sequence;
  const _QuickKey(this.label, this.sequence);
}

/// Agent / 编排模式胶囊
/// 非编排模式：绿色 "Agent" 胶囊（不可点击）
/// 编排模式：橙色 "编排 · X/Y" 胶囊，hub 图标向外发射雷达波纹（象征中枢向多机广播指令）
class _ModeCapsule extends StatefulWidget {
  final bool isOrchestratorMode;
  final int connectedCount;
  final int totalHosts;
  final VoidCallback? onTap;

  const _ModeCapsule({
    required this.isOrchestratorMode,
    required this.connectedCount,
    required this.totalHosts,
    this.onTap,
  });

  @override
  State<_ModeCapsule> createState() => _ModeCapsuleState();
}

class _ModeCapsuleState extends State<_ModeCapsule> with SingleTickerProviderStateMixin {
  late AnimationController _radarController;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    if (widget.isOrchestratorMode) {
      _radarController.repeat();
    }
  }

  @override
  void didUpdateWidget(_ModeCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOrchestratorMode != oldWidget.isOrchestratorMode) {
      if (widget.isOrchestratorMode) {
        _radarController.repeat();
      } else {
        _radarController.stop();
        _radarController.reset();
      }
    }
  }

  @override
  void dispose() {
    _radarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final isOrch = widget.isOrchestratorMode;
    // 描边/底色在 build 里按 .mode-capsule 配方走品牌青；图标与文字同色，
    // 编排态继续用橙色保持模式可辨。
    final accent = isOrch ? cWarning : tc.brand;

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        // 设计稿 .mode-capsule：Agent 态用品牌青 10% 底 + 中性发丝边；
        // 编排态保留橙色以示模式差异。
        decoration: BoxDecoration(
          color: (isOrch ? cWarning : tc.brand).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(rFull),
          border: Border.all(color: isOrch ? cWarning.withValues(alpha: 0.4) : tc.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // hub 图标 + 雷达波纹
            SizedBox(
              width: 14,
              height: 14,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  // 雷达波纹（仅编排模式显示）
                  if (isOrch)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _RadarRipplePainter(
                          progress: _radarController,
                          color: accent,
                          rings: 2,
                        ),
                      ),
                    ),
                  // 图标本体
                  Icon(Icons.hub, size: 12, color: accent),
                ],
              ),
            ),
            const SizedBox(width: 5),
            Text(
              isOrch ? l10n.terminalOrchestratorMode(widget.connectedCount, widget.totalHosts) : 'Agent',
              style: TextStyle(
                fontSize: fSmall,
                color: accent,
                fontWeight: FontWeight.w600,
                height: 1.0,
              ),
            ),
            if (isOrch) ...[
              const SizedBox(width: 3),
              Icon(Icons.arrow_drop_down, size: 14, color: accent.withValues(alpha: 0.7)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 雷达波纹画笔：从图标中心向外扩散多个环形波纹，象征中枢向多机广播指令
class _RadarRipplePainter extends CustomPainter {
  final Animation<double> progress;
  final Color color;
  final int rings;

  _RadarRipplePainter({
    required this.progress,
    required this.color,
    this.rings = 2,
  }) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 起始半径 = 图标边缘；最大半径 = 容器对角线（波纹会超出 SizedBox 边界，由 Clip.none 允许）
    final startRadius = size.width / 2;
    final maxRadius = size.width * 1.8;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final baseProgress = progress.value;
    for (int i = 0; i < rings; i++) {
      // 每个环错开相位（i / rings）
      final phase = (baseProgress + i / rings) % 1.0;
      final radius = startRadius + (maxRadius - startRadius) * phase;
      // 淡出曲线：前 20% 淡入，后 80% 淡出
      final alpha = phase < 0.2
          ? (phase / 0.2) * 0.5
          : (1 - (phase - 0.2) / 0.8) * 0.5;
      paint.color = color.withValues(alpha: alpha.clamp(0.0, 0.5));
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_RadarRipplePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.rings != rings;
}

/// 编排模式主机清单浮层（带分组筛选）
class _OrchestratorHostsSheet extends StatefulWidget {
  final ThemeColors tc;
  final List<HostConfig> allHosts;
  final Map<String, List<HostConfig>> grouped;
  final List<String> groupNames;
  final Set<String> connectedHostIds;
  final VoidCallback onExit;

  const _OrchestratorHostsSheet({
    required this.tc,
    required this.allHosts,
    required this.grouped,
    required this.groupNames,
    required this.connectedHostIds,
    required this.onExit,
  });

  @override
  State<_OrchestratorHostsSheet> createState() => _OrchestratorHostsSheetState();
}

class _OrchestratorHostsSheetState extends State<_OrchestratorHostsSheet> {
  String? _selectedGroup; // null = 全部

  List<HostConfig> get _filteredHosts {
    if (_selectedGroup == null) return widget.allHosts;
    return widget.grouped[_selectedGroup] ?? [];
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.hub, size: 16, color: cWarning),
                const SizedBox(width: 8),
                Text(
                  l10n.terminalOrchestratorHostList,
                  style: TextStyle(
                    fontSize: fBody,
                    color: tc.textMain,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  l10n.terminalOrchestratorConnected(widget.connectedHostIds.length, widget.allHosts.length),
                  style: TextStyle(fontSize: fSmall, color: tc.textSub),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: tc.border.withValues(alpha: 0.5)),
          // 分组筛选 chip 行
          if (widget.groupNames.length > 1)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  _buildGroupChip(tc, l10n.commonAll, _selectedGroup == null),
                  for (final g in widget.groupNames)
                    _buildGroupChip(tc, g, _selectedGroup == g),
                ],
              ),
            ),
          // 主机列表
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.4,
            ),
            child: widget.allHosts.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.terminalNoHostsSaved,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: tc.textMuted, fontSize: fBody),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _filteredHosts.length,
                    itemBuilder: (_, i) {
                      final host = _filteredHosts[i];
                      final isConn = widget.connectedHostIds.contains(host.id);
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                        child: Row(
                          children: [
                            Container(
                              width: 8, height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isConn ? tc.agentGreen : tc.textMuted.withValues(alpha: 0.4),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        host.name,
                                        style: TextStyle(
                                          fontSize: fBody,
                                          color: tc.textMain,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: tc.textMuted.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(rSmall),
                                        ),
                                        child: Text(
                                          host.group,
                                          style: TextStyle(fontSize: fMicro, color: tc.textSub),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    '${host.host}:${host.port} · ${host.username}',
                                    style: TextStyle(fontSize: fMicro, color: tc.textSub),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              isConn ? l10n.terminalConnected : l10n.terminalStatusNotConnected,
                              style: TextStyle(
                                fontSize: fSmall,
                                color: isConn ? tc.agentGreen : tc.textMuted,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Divider(height: 1, color: tc.border.withValues(alpha: 0.5)),
          // 底部操作栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: widget.onExit,
                    child: Container(
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: cWarning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(rSmall),
                        border: Border.all(color: cWarning.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        l10n.terminalExitOrchestrator,
                        style: const TextStyle(
                          fontSize: fBody,
                          color: cWarning,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupChip(ThemeColors tc, String label, bool selected) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () => setState(() => _selectedGroup = selected ? null : label),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? cWarning.withValues(alpha: 0.15) : tc.textMuted.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(
              color: selected ? cWarning.withValues(alpha: 0.4) : tc.border.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: fSmall,
              color: selected ? cWarning : tc.textSub,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

class _AnswerCopyButton extends StatefulWidget {
  const _AnswerCopyButton({
    required this.text,
    required this.label,
    required this.doneLabel,
    required this.copiedLabel,
  });

  final String text;
  final String label;

  /// 复制成功后按钮自己显示的状态文案
  final String doneLabel;
  final String copiedLabel;

  @override
  State<_AnswerCopyButton> createState() => _AnswerCopyButtonState();
}

class _AnswerCopyButtonState extends State<_AnswerCopyButton> {
  bool _hover = false;
  bool _pressed = false;
  bool _copied = false;
  Timer? _doneTimer;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.text));
    clearTopToast();
    showTopSnackBar(
      context,
      SnackBar(
        content: Text(
          widget.copiedLabel,
          style: const TextStyle(fontSize: fSmall),
        ),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
    // 按下态在手势竞争下不一定出现，按钮自己变成「已复制」才是确定的回执
    setState(() => _copied = true);
    _doneTimer?.cancel();
    _doneTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _doneTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final accent = _copied
        ? tc.ok
        : _pressed
            ? tc.brand
            : _hover
                ? tc.brand.withValues(alpha: 0.6)
                : tc.border;
    final foreground =
        _copied ? tc.ok : (_hover || _pressed) ? tc.brand : tc.textSub;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _copy,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _copied
                ? tc.ok.withValues(alpha: 0.12)
                : _pressed
                    ? tc.brand.withValues(alpha: 0.18)
                    : _hover
                        ? tc.brand.withValues(alpha: 0.07)
                        : Colors.transparent,
            borderRadius: BorderRadius.circular(rXSmall),
            // 静止时不画边框：它是回答末尾的一个动作入口，不该再起一个方块
            border: _copied || _hover || _pressed
                ? Border.all(color: accent, width: 0.5)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _copied ? Icons.check_rounded : Icons.copy_all_outlined,
                size: _copied ? 13 : 12,
                color: foreground,
              ),
              const SizedBox(width: 5),
              Text(
                _copied ? widget.doneLabel : widget.label,
                style: TextStyle(fontSize: fMicro, color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 以 (text, isLight) 为 key 缓存 Markdown 子树的构建结果。
///
/// 流式刷新时，同一条消息里未变化的段落会反复经过父级 build；返回同一个
/// widget 实例可让 Element.updateChild 直接跳过整棵子树，避免重复 Markdown 解析。
class _CachedMarkdownText extends StatefulWidget {
  final String text;
  final bool isLight;
  final ThemeColors tc;
  final Widget Function(String text, ThemeColors tc) builder;

  const _CachedMarkdownText({
    required this.text,
    required this.isLight,
    required this.tc,
    required this.builder,
  });

  @override
  State<_CachedMarkdownText> createState() => _CachedMarkdownTextState();
}

class _CachedMarkdownTextState extends State<_CachedMarkdownText> {
  String? _cachedText;
  bool? _cachedIsLight;
  Widget? _cached;

  @override
  Widget build(BuildContext context) {
    if (_cached != null &&
        _cachedText == widget.text &&
        _cachedIsLight == widget.isLight) {
      return _cached!;
    }
    _cachedText = widget.text;
    _cachedIsLight = widget.isLight;
    _cached = widget.builder(widget.text, widget.tc);
    return _cached!;
  }
}

/// 虚线圆角描边（设计稿 .tab-add 的 CSS dashed border 等价实现）。
class _DashedRoundedRectPainter extends CustomPainter {
  const _DashedRoundedRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const double _dash = 4.0;
  static const double _gap = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rect = Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final next = math.min(distance + _dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRoundedRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
