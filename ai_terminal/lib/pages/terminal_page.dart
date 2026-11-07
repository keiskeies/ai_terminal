import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:go_router/go_router.dart';
import 'package:xterm/xterm.dart';
import '../core/builtin_runbook_i18n.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../core/l10n_holder.dart';
import '../core/route_observer.dart';
import '../l10n/app_localizations.dart';
import '../widgets/sftp_panel.dart';
import '../widgets/logo_widget.dart';
import '../widgets/ai_prompt_input.dart';
import '../widgets/model_picker_panel.dart';
import '../widgets/agent_goal_banner.dart';
import '../models/agent_goal.dart';
import '../models/agent_permission_mode.dart';
import '../widgets/session_history_dialog.dart';
import '../widgets/agent_log_dialog.dart';
import '../widgets/agent_command_block.dart';
import '../widgets/agent_event_cards.dart';
import '../widgets/agent_thinking_blocks.dart';
import '../widgets/collapsible_message_text.dart';
import '../widgets/operation_sheet.dart';
import '../widgets/plan_panel.dart';
import '../widgets/interrupted_turn_banner.dart';
import '../widgets/reconnecting_banner.dart';
import '../widgets/local_dir_auth_dialog.dart';
import '../widgets/tab_item_widget.dart';
import '../utils/interrupted_turn_detector.dart';
import '../utils/streaming_markdown.dart';
import '../utils/slash_command.dart';
import '../utils/agent_ui_text.dart';
import '../utils/conversation_export.dart';
import '../utils/goal_continuation.dart';
import '../services/agent_tracer.dart';
import '../services/agent_logger.dart';
import 'package:flutter/services.dart';
import '../services/daos.dart';
import '../core/prompts.dart' as prompts;
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
import '../models/change_record.dart';
import '../widgets/server_monitor_panel.dart';
import '../widgets/terminal_view.dart' as term_widget;
import '../widgets/terminal_context_menu.dart';
import '../utils/terminal_text_actions.dart';
import '../core/app_toast.dart';


enum _AiPanelPosition { bottom, right }

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
  final position = (storedPosition == 'bottom' || storedPosition == 'right')
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

class TerminalPage extends ConsumerStatefulWidget {
  final String? hostId; // null = 本地终端

  const TerminalPage({super.key, this.hostId});

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> with RouteAware {
  Terminal? _terminal;

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

  // AI 面板默认布局（从设置加载，新 tab 继承；每个 tab 可在会话内独立覆盖）
  _AiPanelPosition _defaultAiPanelPosition = _AiPanelPosition.right;
  double _defaultAiPanelRatio = 0.4;
  bool _defaultAiPanelVisible = false;
  static const double _minPanelRatio = 0.15;
  static const double _maxPanelRatio = 0.7;

  // 每个 tab 独立的 AI 面板可见性 / 方位 / 宽度比例
  final Map<String, bool> _tabAiPanelVisible = {};
  final Map<String, _AiPanelPosition> _tabAiPanelPosition = {};
  final Map<String, double> _tabAiPanelRatio = {};

  bool _aiPanelVisibleFor(String? tabId) => tabId == null
      ? _defaultAiPanelVisible
      : (_tabAiPanelVisible[tabId] ?? _defaultAiPanelVisible);
  _AiPanelPosition _aiPanelPositionFor(String? tabId) => tabId == null
      ? _defaultAiPanelPosition
      : (_tabAiPanelPosition[tabId] ?? _defaultAiPanelPosition);
  double _aiPanelRatioFor(String? tabId) => tabId == null
      ? _defaultAiPanelRatio
      : (_tabAiPanelRatio[tabId] ?? _defaultAiPanelRatio);

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

  /// 新 tab 创建时把当前默认布局快照到自己的 map。
  /// 必须快照而不是一直读默认值：否则另一个 tab 改布局时，已有的 tab 会跟着变。
  void _initTabPanelState(tp.TerminalTab tab) {
    _tabAiPanelVisible.putIfAbsent(tab.id, () => _defaultAiPanelVisible);
    _tabAiPanelPosition.putIfAbsent(tab.id, () => _defaultAiPanelPosition);
    _tabAiPanelRatio.putIfAbsent(tab.id, () => _defaultAiPanelRatio);
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
  static const double _minSftpWidth = 220;

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
    final ratio = _aiPanelRatioFor(tabId);
    _defaultAiPanelRatio = ratio;
    SettingsDao.set('aiPanelRatio', ratio);
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
    // P0-1: 加载 AI 面板可见性设置，默认收起
    try {
      final aiPanelVisible = SettingsDao.getCached('aiPanelVisible');
      if (aiPanelVisible != null) {
        _defaultAiPanelVisible = aiPanelVisible as bool;
      }
    } catch (_) {}
    // 方向与比例：只有显式存过才覆盖默认值。
    // 存过 bottom 的老用户不能被新默认 right 翻回去，所以两边都要认。
    try {
      final resolved = resolveAiPanelLayout(
        storedPosition: SettingsDao.getCached('aiPanelPosition'),
        storedRatio: SettingsDao.getCached('aiPanelRatio'),
        defaultPosition: _defaultAiPanelPosition.name,
        defaultRatio: _defaultAiPanelRatio,
        minRatio: _minPanelRatio,
        maxRatio: _maxPanelRatio,
      );
      _defaultAiPanelPosition = resolved.position == 'bottom'
          ? _AiPanelPosition.bottom
          : _AiPanelPosition.right;
      _defaultAiPanelRatio = resolved.ratio;
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
    });
  }

  /// 终端显示路径批处理：最多每 16ms（约一帧）或 64KB 合并写入一次。
  void _bufferTermWrite(String tabId, String data) {
    final buffer =
        _tabTermWriteBuffers.putIfAbsent(tabId, StringBuffer.new)..write(data);
    if (buffer.length >= _termWriteMaxChars) {
      _flushTermWrite(tabId);
      return;
    }
    _tabTermWriteTimers[tabId] ??= Timer(
      const Duration(milliseconds: _termWriteFlushMs),
      () => _flushTermWrite(tabId),
    );
  }

  void _flushTermWrite(String tabId) {
    _tabTermWriteTimers.remove(tabId)?.cancel();
    final buffer = _tabTermWriteBuffers.remove(tabId);
    if (buffer == null || buffer.isEmpty) return;
    final term = _tabTerminals[tabId];
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

  void _discardTermWrite(String tabId) {
    _tabTermWriteTimers.remove(tabId)?.cancel();
    _tabTermWriteBuffers.remove(tabId);
  }

  /// 确保某个 tab 有独立的 Terminal 和常驻输出订阅。切换 tab 不再取消/重建。
  void _ensureTabTerminal(tp.TerminalTab tab) {
    final isCurrent = tab.id == _currentTabId;
    final existing = _tabTerminals[tab.id];
    if (existing != null) {
      if (isCurrent) _terminal = existing;
      return;
    }
    final term = Terminal(maxLines: 10000);
    _tabTerminals[tab.id] = term;
    if (isCurrent) _terminal = term;
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
    if (tab.isConnecting) return;

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
        if (newTab.id == _currentTabId) _scheduleSizeSync(newTab);
      }
    }

    if (newTab == null) {
      // 失败原因存在 tab.connectionError 上，主区按状态渲染；这里补一条即时反馈
      _showOperationMessage(tab.connectionError ?? L10n.str.connectionFailedHint, isError: true);
    }
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

    return Scaffold(
      backgroundColor: tc.bg,
      resizeToAvoidBottomInset: true,
      body: Column(
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
      return _wrapWithSftp(
          _buildMainBody(chatError, activeAgentState, null, isActive: true));
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
    return _wrapWithSftp(Stack(
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
    ));
  }

  /// 主体区域：终端 + AI 面板 + SFTP 侧面板，根据面板位置切换布局
  Widget _buildMainBody(String? chatError, AgentState agentState,
      tp.TerminalTab? tab, {required bool isActive}) {

    // 终端视图。主区渲染只看活动标签自己的连接阶段：页面级不再留一份
    // "连接中"副本，否则顶栏指向新标签、画面还停在旧标签。
    final placeholder = _buildConnectionPlaceholder(tab);

    final terminalView = Stack(
      children: [
        term_widget.TerminalView(
          terminal: tab == null ? _terminal : (_tabTerminals[tab.id] ?? _terminal),
          fontSize: _terminalFontSize,
          active: isActive,
          isLocal: tab?.isLocal ?? true,
          onFontSizeChanged: (size) {
            final clamped = size.clamp(10.0, 24.0);
            setState(() => _terminalFontSize = clamped);
            SettingsDao.set('terminalFontSize', clamped);
          },
          onMenuIntent: (intent, text) =>
              _handleTerminalMenuIntent(tab, intent, text),
          onSend: (command) {
            if (tab == null) return;
            if (tab.isLocal) {
              tab.localService?.execute(command);
            } else {
              tab.service?.execute(command);
            }
          },
        ),
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

    // P0-1: AI 面板支持完全收起 + 移动端上滑手势展开
    Widget mainContent;
    if (!_aiPanelVisibleFor(tab?.id)) {
      // AI 面板收起状态：终端占满全屏，移动端支持上滑展开 AI 面板
      mainContent = _isMobile
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
    } else {
      // AI 面板展开状态：保持现有分栏布局
      mainContent = LayoutBuilder(builder: (context, constraints) {
        final totalW = constraints.maxWidth;
        final totalH = constraints.maxHeight;
        final isRight =
            _aiPanelPositionFor(tab?.id) == _AiPanelPosition.right;

        void onDrag(DragUpdateDetails details) {
          setState(() {
            final ratio = isRight
                ? (1 -
                        (details.globalPosition.dx -
                                (context.findRenderObject() as RenderBox)
                                    .localToGlobal(Offset.zero)
                                    .dx) /
                            totalW)
                    .clamp(_minPanelRatio, _maxPanelRatio)
                    .toDouble()
                : (1 -
                        (details.globalPosition.dy -
                                (context.findRenderObject() as RenderBox)
                                    .localToGlobal(Offset.zero)
                                    .dy) /
                            totalH)
                    .clamp(_minPanelRatio, _maxPanelRatio)
                    .toDouble();
            if (tab != null) _tabAiPanelRatio[tab.id] = ratio;
            _defaultAiPanelRatio = ratio;
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
                child: Container(
                  width: isRight ? 5 : double.infinity,
                  height: isRight ? double.infinity : 5,
                  color: tc.border.withValues(alpha: 0.6),
                ),
              ),
            );

        final divider = _buildAreaDivider(agentState, tab?.id);
        final aiPanelSize = isRight
            ? totalW * _aiPanelRatioFor(tab?.id)
            : totalH * _aiPanelRatioFor(tab?.id);
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

        if (isRight) {
          return Row(
            children: [
              Expanded(child: terminalArea),
              dragHandle,
              divider,
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

          return Column(
            children: [
              Expanded(child: terminalArea),
              dragHandle,
              divider,
              aiPanelWithSwipe,
            ],
          );
        }
      });
    }

    return mainContent;
  }

  /// 桌面端 SFTP 侧面板：每个 tab 独立、Offstage 保活，切换不重连。
  Widget _wrapWithSftp(Widget content) {
    final currentTabId = ref.read(tp.terminalProvider).activeTabId;
    final allTabs = ref.read(tp.terminalProvider).tabs;
    final visibleSftpTabs = allTabs
        .where((t) => !t.isLocal && (_tabSftpVisible[t.id] ?? false))
        .toList();
    final hasActiveSftp = currentTabId != null &&
        (_tabSftpVisible[currentTabId] ?? false) &&
        !_isMobile;

    if (hasActiveSftp && visibleSftpTabs.isNotEmpty) {
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
            width: _sftpPanelWidth,
            child: Stack(
              children: visibleSftpTabs.map((tab) {
                final isActive = tab.id == currentTabId;
                return Offstage(
                  offstage: !isActive,
                  child: ExcludeFocus(
                    excluding: !isActive,
                    child: SftpPanel(
                      // 初始目录变化时更换 key，让面板按新目录重新加载
                      key: ValueKey(
                          'sftp-${tab.id}-${tab.hostId}-${_tabSftpInitialPath[tab.id] ?? ''}'),
                      hostId: tab.hostId,
                      embedded: true,
                      initialPath: _tabSftpInitialPath[tab.id],
                      onClose: () => setState(() {
                        _tabSftpVisible[tab.id] = false;
                        // 关闭后清掉定位目标，下次从默认目录打开
                        _tabSftpInitialPath.remove(tab.id);
                      }),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      );
    }

    // 如果切换到本地终端但其他 tab 的 SFTP 面板还在，需要清理
    if (!_isMobile && currentTabId != null) {
      final activeTab = ref.read(tp.terminalProvider).activeTab;
      if (activeTab != null &&
          activeTab.isLocal &&
          (_tabSftpVisible[currentTabId] ?? false)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _tabSftpVisible[currentTabId] = false);
        });
      }
    }

    return content;
  }

  // ==================== 顶部栏 ====================
  /// 三段式结构：左侧品牌区 / 中间标签区 / 右侧操作区
  Widget _buildTopBar(dynamic host, tp.TerminalState terminalState, tp.TerminalTab? activeTab) {
    final tc = ThemeColors.of(context);
    return Container(
      height: hAppBar,
      decoration: BoxDecoration(
        color: tc.bg,
        border: Border(bottom: BorderSide(color: tc.border, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左侧品牌区：LOGO + 应用名，点击返回主页
          _buildBrandArea(tc),
          const SizedBox(width: 8),
          // 中间标签区
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
              itemCount: terminalState.tabs.length + 1, // +1 for add button
              itemBuilder: (context, index) {
                // 最后一项是"+"按钮
                if (index == terminalState.tabs.length) {
                  return Align(
                    alignment: Alignment.center,
                    heightFactor: 1.0,
                    child: _buildAddTabButton(),
                  );
                }
                final tab = terminalState.tabs[index];
                final isActive = tab.id == terminalState.activeTabId;
                return Align(
                  alignment: Alignment.center,
                  heightFactor: 1.0,
                  child: _buildTabItem(tab, isActive, terminalState),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          // 右侧操作区
          _buildTopBarActions(),
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  /// 左侧品牌区
  Widget _buildBrandArea(ThemeColors tc) {
    return GestureDetector(
      onTap: () => context.go('/'),
      child: Container(
        height: hAppBar,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: Colors.transparent,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LogoWidget(type: LogoType.mark, size: 20),
            const SizedBox(width: 8),
            Text(
              'AI Terminal',
              style: TextStyle(
                fontSize: fSmall,
                fontWeight: FontWeight.w500,
                color: tc.textMain,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 右侧操作区：AI 面板开关、监控、设置、更多。
  /// 连接状态不在这里重复：每个 tab 自己带一个同色系小圆点。
  Widget _buildTopBarActions() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildAIPanelToggleButton(),
        const SizedBox(width: 6),
        _buildMonitorToggleButton(),
        const SizedBox(width: 6),
        _buildTerminalSettingsButton(),
        const SizedBox(width: 6),
        _buildToolbarMenu(),
      ],
    );
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
    _tabAiPanelRatio.remove(tab.id);
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
        child: Container(
          width: 32,
          height: 32,
          margin: const EdgeInsets.only(left: 2, right: 2),
          decoration: BoxDecoration(
            color: tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: tc.border.withValues(alpha: 0.3)),
          ),
          child: Icon(Icons.add, size: 14, color: tc.textSub),
        ),
      ),
    );
  }

  /// 终端设置按钮（字号、配色）
  Widget _buildTerminalSettingsButton() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      icon: Icon(Icons.text_fields, color: tc.textSub, size: 18),
      color: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
      offset: const Offset(0, 40),
      onSelected: (value) {
        if (value.startsWith('font_')) {
          final size = double.parse(value.substring(5));
          setState(() => _terminalFontSize = size);
          SettingsDao.set('terminalFontSize', size);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: Text(l10n.terminalFontSize(_terminalFontSize.toInt()), style: TextStyle(fontSize: fMicro, color: tc.brand, fontWeight: FontWeight.w600)),
        ),
        ...[8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 18.0, 20.0, 22.0, 24.0].map((size) => PopupMenuItem<String>(
          value: 'font_$size',
          height: 28,
          child: Row(
            children: [
              if (_terminalFontSize == size)
                Icon(Icons.check, size: 12, color: tc.brand)
              else
                const SizedBox(width: 12),
              const SizedBox(width: 4),
              Text('${size.toInt()}px', style: TextStyle(fontSize: fSmall, color: _terminalFontSize == size ? tc.brand : tc.textMain)),
            ],
          ),
        )),
      ],
    );
  }

  /// P0-1: AI 面板展开/收起按钮（只影响当前 tab）
  Widget _buildAIPanelToggleButton() {
    final tc = ThemeColors.of(context);
    final accentColor = tc.agentGreen;
    final l10n = AppLocalizations.of(context)!;
    final tabId = ref.read(tp.terminalProvider).activeTab?.id;
    final visible = _aiPanelVisibleFor(tabId);

    return Tooltip(
      message: visible ? l10n.terminalCollapseAIPanel : l10n.terminalExpandAIPanel,
      child: GestureDetector(
        onTap: () {
          setState(() => _setAiPanelVisible(tabId, !visible));
        },
        child: AnimatedContainer(
          duration: animFast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: visible ? accentColor.withValues(alpha: 0.15) : tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(
              color: visible ? accentColor.withValues(alpha: 0.4) : tc.border.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                visible ? Icons.auto_fix_high : Icons.auto_fix_high_outlined,
                size: 14,
                color: visible ? accentColor : tc.textSub,
              ),
              const SizedBox(width: 4),
              Text(
                'AI',
                style: TextStyle(
                  fontSize: fMicro,
                  color: visible ? accentColor : tc.textSub,
                  fontWeight: visible ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  /// 服务器监控面板开关按钮（终端下方横幅，只影响当前 tab）
  Widget _buildMonitorToggleButton() {
    final tc = ThemeColors.of(context);
    const accentColor = cKleinBlue;
    final activeTab = ref.read(tp.terminalProvider).activeTab;
    final canShow = activeTab != null && activeTab.isConnected;
    final isOn = activeTab != null && _monitorVisibleFor(activeTab);
    final l10n = AppLocalizations.of(context)!;

    return Tooltip(
      message: isOn ? l10n.terminalCollapseMonitorPanel : l10n.terminalExpandMonitorPanel,
      child: GestureDetector(
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
        child: AnimatedContainer(
          duration: animFast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: isOn ? accentColor.withValues(alpha: 0.15) : tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(
              color: isOn ? accentColor.withValues(alpha: 0.4) : tc.border.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.monitor_heart_outlined,
                size: 14,
                color: isOn ? accentColor : (canShow ? tc.textSub : tc.textMuted),
              ),
              const SizedBox(width: 4),
              Text(
                l10n.terminalMonitor,
                style: TextStyle(
                  fontSize: fMicro,
                  color: isOn ? accentColor : (canShow ? tc.textSub : tc.textMuted),
                  fontWeight: isOn ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
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
  Widget _buildToolbarMenu() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final snippets = SnippetsDao.cached.toList();
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz, color: tc.textSub, size: 20),
      color: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
      offset: const Offset(0, 40),
      onSelected: (value) async {
        if (value.startsWith('snippet:')) {
          final snippetId = value.substring(8);
          final snippet = SnippetsDao.getCachedById(snippetId);
          if (snippet != null) _executeSnippet(snippet);
          return;
        }
        switch (value) {
          case 'reconnect': await _reconnect(); break;
          case 'clear': _terminal?.write('\x1b[2J\x1b[H'); break;
          case 'sftp':
            final sftpTab = ref.read(tp.terminalProvider).activeTab;
            if (sftpTab != null && !sftpTab.isLocal) {
              if (_isMobile) {
                context.push('/sftp/${sftpTab.hostId}');
              } else {
                setState(() {
                  _tabSftpVisible[sftpTab.id] = !(_tabSftpVisible[sftpTab.id] ?? false);
                });
              }
            }
            break;
          case 'prompt': _showCustomPromptDialog(); break;
          case 'builtInPrompt': _showBuiltInPromptDialog(); break;
          case 'maxsteps': _showMaxStepsDialog(); break;
          case 'settings': context.push('/settings'); break;
        }
      },
      itemBuilder: (context) => [
        _menuItem('reconnect', Icons.refresh_rounded, l10n.terminalReconnect),
        _menuItem('clear', Icons.cleaning_services_rounded, l10n.terminalClearScreen),
        _menuItem('sftp', Icons.folder_outlined, 'SFTP'),
        // 快捷命令
        if (snippets.isNotEmpty) ...[
          const PopupMenuDivider(height: 8),
          PopupMenuItem<String>(
            enabled: false,
            height: 24,
            child: Text(l10n.quickCommands, style: TextStyle(fontSize: fMicro, color: tc.brand, fontWeight: FontWeight.w600)),
          ),
          ...snippets.take(5).map((s) => _menuItem('snippet:${s.id}', Icons.terminal, s.name)),
        ],
        const PopupMenuDivider(height: 8),
        _menuItem('prompt', Icons.edit_note_rounded, L10n.str.menuItemCustomPrompt),
        _menuItem('builtInPrompt', Icons.description_outlined, L10n.str.menuItemBuiltinPrompt),
        _menuItem('maxsteps', Icons.auto_mode_rounded, l10n.terminalMaxSteps),
        const PopupMenuDivider(height: 8),
        _menuItem('settings', Icons.settings_outlined, l10n.settings),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) {
    final tc = ThemeColors.of(context);
    return PopupMenuItem(
      value: value,
      height: 36,
      child: Row(
        children: [
          Icon(icon, color: tc.textSub, size: 16),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: fBody, color: tc.textMain)),
        ],
      ),
    );
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
      color: tc.terminalBg,
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

  // ==================== 区域分界线（分割条，位于终端和 AI 面板之间）====================
  Widget _buildAreaDivider(AgentState agentState, String? tabId) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final accentColor = tc.agentGreen;
    final isRight = _aiPanelPositionFor(tabId) == _AiPanelPosition.right;
    // 手机端不显示位置切换按钮
    final showButtons = !_isMobile;

    // Chrome DevTools 风格的方形布局切换按钮
    Widget layoutButton(_AiPanelPosition pos, IconData icon, String tooltip) {
      final isActive = _aiPanelPositionFor(tabId) == pos;
      return Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onTap: () {
            setState(() => _setAiPanelPosition(tabId, pos));
            _savePanelLayout(savePosition: true);
          },
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: isActive ? accentColor.withValues(alpha: 0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(3),
              border: isActive ? Border.all(color: accentColor.withValues(alpha: 0.5), width: 1) : null,
            ),
            child: Icon(icon, size: 13, color: isActive ? accentColor : tc.textMuted),
          ),
        ),
      );
    }

    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6, height: 6,
          decoration: BoxDecoration(
            color: cWarning,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: cWarning.withValues(alpha: 0.5), blurRadius: 4)],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'AGENT',
          style: TextStyle(
            fontSize: fMicro,
            color: accentColor.withValues(alpha: 0.8),
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );

    // P0-1: 收起按钮
    Widget closeButton() {
      return Tooltip(
        message: l10n.terminalCollapseAIPanel,
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onTap: () {
            setState(() => _setAiPanelVisible(tabId, false));
          },
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: accentColor.withValues(alpha: 0.3), width: 1),
            ),
            child: Icon(
              isRight ? Icons.keyboard_arrow_right : Icons.keyboard_arrow_down,
              size: 16,
              color: accentColor,
            ),
          ),
        ),
      );
    }

    if (isRight) {
      // 竖向分割条（AI 在右侧时）
      return Container(
        width: showButtons ? 32 : 28,
        decoration: BoxDecoration(
          color: tc.card,
          border: Border(right: BorderSide(color: tc.border.withValues(alpha: 0.4), width: 0.5)),
        ),
        child: Column(
          children: [
            if (showButtons) ...[
              const SizedBox(height: 4),
              closeButton(),
              const SizedBox(height: 4),
              RotatedBox(quarterTurns: 1, child: layoutButton(_AiPanelPosition.bottom, Icons.view_sidebar_outlined, l10n.terminalLayoutBottom)),
              const SizedBox(height: 2),
              layoutButton(_AiPanelPosition.right, Icons.view_sidebar_outlined, l10n.terminalLayoutRight),
            ],
            const Spacer(),
            // 竖向彩色射线
            Expanded(
              child: Container(
                width: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [accentColor.withValues(alpha: 0.0), accentColor.withValues(alpha: 0.7), accentColor.withValues(alpha: 0.0)],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            RotatedBox(quarterTurns: 3, child: label),
            const SizedBox(height: 8),
          ],
        ),
      );
    } else {
      // 横向分割条（AI 在下方时）
      return Container(
        height: 28,
        decoration: BoxDecoration(
          color: tc.card,
          border: Border(
            bottom: BorderSide(color: tc.border.withValues(alpha: 0.4), width: 0.5),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            label,
            const SizedBox(width: 8),
            if (showButtons) closeButton(),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [accentColor.withValues(alpha: 0.6), accentColor.withValues(alpha: 0.0)],
                  ),
                ),
              ),
            ),
            if (showButtons) ...[
              const SizedBox(width: 8),
              RotatedBox(quarterTurns: 1, child: layoutButton(_AiPanelPosition.bottom, Icons.view_sidebar_outlined, l10n.terminalLayoutBottom)),
              const SizedBox(width: 2),
              layoutButton(_AiPanelPosition.right, Icons.view_sidebar_outlined, l10n.terminalLayoutRight),
            ],
            const SizedBox(width: 6),
          ],
        ),
      );
    }
  }

  // ==================== AI 面板 ====================
  Widget _buildAIPanel(String? chatError, AgentState agentState, tp.TerminalTab? tab) {
    final tc = ThemeColors.of(context);

    return Container(
      decoration: BoxDecoration(
        color: tc.cardElevated,
        border: Border(
          top: BorderSide(color: tc.border, width: 1),
        ),
      ),
      child: Column(
        children: [
          // 会话压缩中横幅
          if (agentState.isCompacting)
            _buildCompactingBanner(tc),
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

  // ==================== Agent 模式统一消息列表 ====================
  Widget _buildAgentChatList(AgentState agentState, tp.TerminalTab? tab) {
    final l10n = AppLocalizations.of(context)!;
    final items = agentState.chatItems;
    // 终端还不存在的阶段（首连中/首连失败）不给上一标签的会话，也不提示"输入需求
    // 开始自动执行"——那时输入框是灰的，提示只会让人以为能直接问
    final waiting = _buildAgentWaitingView(tab);
    if (waiting != null) return waiting;
    if (items.isEmpty) {
      return Center(child: Text(l10n.terminalInputHintEmpty, style: TextStyle(color: ThemeColors.of(context).textMuted, fontSize: fBody)));
    }
    // 整块列表共用一个 SelectionArea：Markdown 的每段、命令卡、输出卡都是
    // 独立 Text 组件，若各自用 SelectableText 就只能一次选中一段。
    return SelectionArea(
      child: ListView.builder(
        controller: _chatControllerFor(tab?.id ?? _currentTabId ?? ''),
        padding: const EdgeInsets.all(8),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          final isLast = index == items.length - 1;
          final turnGoal = item.role == 'assistant' &&
                  index > 0 &&
                  items[index - 1].role == 'user'
              ? items[index - 1].content
              : null;
          // RepaintBoundary：流式时只有最后一条消息在变，已定型消息不必跟着重绘
          return RepaintBoundary(
            key: ValueKey('agent_${item.role}_$index'),
            child: _buildMessageBubble(
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

    return Align(
      key: key,
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isUser ? tc.userBubble : tc.card,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(rMedium),
            topRight: const Radius.circular(rMedium),
            bottomLeft: Radius.circular(isUser ? rMedium : rXSmall),
            bottomRight: Radius.circular(isUser ? rXSmall : rMedium),
          ),
          border: Border.all(
            color: isUser ? tc.userBubbleBorder : tc.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 角色标签
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: tc.brand.withValues(
                        alpha: isUser ? 0.14 : 0.1),
                    borderRadius: BorderRadius.circular(rXSmall),
                    border: Border.all(
                      color: tc.brand.withValues(
                          alpha: isUser ? 0.32 : 0.25),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isUser ? Icons.person_outline : Icons.auto_awesome,
                        size: 11,
                        color: tc.brand,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isUser ? l10n.terminalRoleYou : l10n.commonAIAssistant,
                        style: TextStyle(
                          fontSize: fMicro,
                          color: tc.brand,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      if (isLoading) ...[
                        const SizedBox(width: 6),
                        SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.5, color: tc.brand)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
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
              _buildAnswerCopyRow(events, content, streamingContent, isLoading),
            ],
          ],
        ),
      ),
    );
  }

  /// 回答底部的整段复制。
  ///
  /// 拖拽选区跨不过 markdown 段落与命令卡，复制按钮是把一整轮回答捞走的出口。
  Widget _buildAnswerCopyRow(
    List<AgentEvent> events,
    String content,
    String streamingContent,
    bool isLoading,
  ) {
    // 流式没收尾时正文还会变，复制半截回答不如不复制
    if (isLoading) return const SizedBox.shrink();
    final text = formatAnswerForCopy(
      events: events,
      content: content,
      streamingContent: streamingContent,
    );
    if (text.isEmpty) return const SizedBox.shrink();
    final ui = AgentUiText.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: _AnswerCopyButton(
        text: text,
        label: ui.copyAnswer,
        doneLabel: ui.copied,
        copiedLabel: ui.answerCopied,
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
      Widget buildEventContent(List<AgentEvent> source) => AgentEventContent(
            events: source,
            tc: tc,
            tab: tab,
            showAutoExecute: showAutoExecute,
            isLoading: isLoading,
            isWaitingChoice: isWaitingChoice,
            pendingOptions: pendingOptions,
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

      // 有操作单报告：结论先行 + 证据折叠；finish 卡片不再重复展示
      final report = _findOperationReport(events);
      if (report != null) {
        final evidenceEvents = events
            .where((e) => !e.isReport && !e.isFinish)
            .toList(growable: false);
        final hasAIContentEvidence = evidenceEvents.any(
            (e) => e.isThought || e.isCommand || e.isText || e.isAsk);
        final hasFallbackText = streamingContent.trim().isNotEmpty ||
            content.trim().isNotEmpty;
        Widget buildEvidence() => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (evidenceEvents.isNotEmpty)
                  buildEventContent(evidenceEvents),
                // 流式结束后从历史恢复时 streamingContent 为空，使用持久化 content 兜底
                if (!hasAIContentEvidence) ...[
                  if (streamingContent.trim().isNotEmpty)
                    _buildMarkdownText(streamingContent, tc, streaming: true)
                  else if (content.trim().isNotEmpty)
                    _buildMarkdownText(content, tc),
                ],
              ],
            );
        return OperationSheet(
          report: report,
          tc: tc,
          markdownBuilder: _buildMarkdownText,
          hasEvidence: evidenceEvents.isNotEmpty || hasFallbackText,
          evidenceBuilder: buildEvidence,
          isLiveTurn: isLastTurn,
          plan: report.plan.isNotEmpty ? report.plan : _findLatestPlan(events),
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
          // 执行清单常驻在事件流上方，运行中也始终可见；
          // 但贴底卡正在显示同一份计划时这里要抑制，否则同屏两份。
          if (plan.isNotEmpty && !_planPinnedActive)
            PlanPanel(
              steps: plan,
              tc: tc,
              currentCommand: runningCommand,
              // 历史回合默认收起，只留"进度 + 当前步"一行
              initiallyExpanded: isLastTurn ? null : false,
            ),
          // 过程折叠由 AgentProcessTimeline 自己负责（一行一步 + 更早 N 步），
          // 模型原生推理（reasoning_content）：只有部分网关返回该字段，有就实时显示
          if (liveReasoning.trim().isNotEmpty)
            ModelReasoningBlock(text: liveReasoning, tc: tc),
          // 不再套一层 CollapsibleEventStream —— 两层折叠会互相打架。
          buildEventContent(events),
          // 流式过程中的当前步思考逐字显示。原来这段只在"还没有任何 AI 事件"时
          // 才渲染，第一步之后事件已存在，用户就再也看不到实时输出了。
          if (isLoading && streamingContent.trim().isNotEmpty)
            LiveThoughtBlock(rawText: streamingContent, tc: tc),
          // 没有 AI 内容事件时（流式早期或纯文本兜底）仍然按原逻辑显示
          if (!hasAIContentEvents && !isLoading) ...[
            if (streamingContent.trim().isNotEmpty)
              _buildMarkdownText(streamingContent, tc)
            else if (content.trim().isNotEmpty)
              _buildMarkdownText(content, tc),
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
      bodies.add(_CachedMarkdownText(
        text: seg.content,
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
              fontSize: fBody,
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
            listBullet: TextStyle(color: theme.brand, fontSize: fBody),
            blockquote: TextStyle(
              color: theme.textSub,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w500,
            ),
            blockquoteDecoration: BoxDecoration(
              border: Border(left: BorderSide(color: theme.brand, width: 2)),
            ),
            blockquotePadding: const EdgeInsets.only(left: 8),
          ),
          onTapLink: (text, href, title) {},
        ),
      ));
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
    String text,
  ) async {
    switch (intent) {
      case TerminalMenuIntent.sendToAgent:
        _putIntoAgentInput(tab, agentExplainPrompt(text));
        break;
      case TerminalMenuIntent.askError:
        _putIntoAgentInput(tab, agentErrorPrompt(text));
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
    final List<PlanStep> pinnedPlan = agentState.chatItems.isNotEmpty &&
            agentState.chatItems.last.role == 'assistant'
        ? _findLatestPlan(agentState.chatItems.last.events)
        : const [];

    return Container(
      padding: EdgeInsets.only(
        left: 12, right: 12, top: 8,
        bottom: 8 + (_isMobile ? MediaQuery.of(context).padding.bottom : 0),
      ),
      decoration: BoxDecoration(
        color: tc.card,
        border: Border(top: BorderSide(color: tc.border)),
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
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: active ? cWarning.withValues(alpha: 0.15) : tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
            border: active ? Border.all(color: cWarning.withValues(alpha: 0.4)) : null,
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
          onTap: () => context.push('/settings/ai'),
          borderRadius: BorderRadius.circular(rFull),
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
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
            context.push('/settings/ai');
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
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: tc.surface,
                borderRadius: BorderRadius.circular(rFull),
                border: Border.all(color: tc.border.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.psychology_outlined,
                      size: 12, color: tc.textMuted),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 170),
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
                  const SizedBox(width: 3),
                  Icon(Icons.unfold_more, size: 11, color: tc.textMuted),
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
                        Navigator.of(ctx).pop();
                        context.push('/runbooks');
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
        if (isAgent) {
          _sendRunbookPrompt(rb);
        } else {
          _sendRunbookCommand(rb);
        }
      },
    );
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
          onPressed: () => context.push('/settings/ai'),
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

  /// 显示最大步骤数设置
  void _showMaxStepsDialog() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: ref.read(agentProvider).maxSteps.toString());
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: tc.cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text(l10n.terminalMaxStepsTitle, style: TextStyle(color: tc.textMain, fontSize: fBody)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.terminalMaxStepsDesc, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: TextStyle(color: tc.textMain, fontSize: fBody),
              decoration: InputDecoration(
                labelText: l10n.terminalMaxStepsLabel,
                labelStyle: TextStyle(color: tc.textSub),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: tc.border)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: tc.brand)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel, style: TextStyle(color: tc.textSub)),
          ),
          ElevatedButton(
            onPressed: () {
              final steps = int.tryParse(controller.text) ?? 0;
              final clamped = steps.clamp(0, 100);
              ref.read(agentProvider.notifier).setMaxSteps(clamped);
              Navigator.pop(context);
              showTopSnackBar(context, 
                SnackBar(
                  content: Text(l10n.terminalMaxStepsSet(clamped)),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: tc.brand,
                foregroundColor: tc.isLight ? Colors.white : cBg,
              ),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
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

  /// 显示自定义提示词设置
  void _showCustomPromptDialog() {
    String? savedPrompt;
    try {
      savedPrompt = SettingsDao.getCached('customSystemPrompt') as String?;
    } catch (_) {}
    final controller = TextEditingController(text: savedPrompt ?? '');
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: tc.cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text(L10n.str.customPromptTitle, style: TextStyle(color: tc.textMain, fontSize: fBody)),
        content: SizedBox(
          width: MediaQuery.of(context).size.width * 0.75,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(L10n.str.customPromptDesc, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 5,
                minLines: 2,
                style: TextStyle(color: tc.textMain, fontSize: fBody),
                decoration: InputDecoration(
                  hintText: l10n.terminalCustomPromptHint,
                  hintStyle: TextStyle(color: tc.textMuted, fontSize: fSmall),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: tc.border)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: tc.brand)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel, style: TextStyle(color: tc.textSub)),
          ),
          ElevatedButton(
            onPressed: () {
              try {
                SettingsDao.set('customSystemPrompt', controller.text.trim());
              } catch (_) {}
              Navigator.pop(context);
              showTopSnackBar(context, 
                SnackBar(
                  content: Text(L10n.str.customPromptSaved),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: tc.brand,
                foregroundColor: tc.isLight ? Colors.white : cBg,
              ),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }

  /// 显示内置系统提示词编辑
  void _showBuiltInPromptDialog() {
    final currentPrompt = prompts.getSystemPrompt();
    final controller = TextEditingController(text: currentPrompt);
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: tc.cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text(L10n.str.builtinPromptTitle, style: TextStyle(color: tc.textMain, fontSize: fBody)),
        content: SizedBox(
          width: MediaQuery.of(ctx).size.width * 0.85,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(L10n.str.builtinPromptDesc, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
              const SizedBox(height: 6),
              Text(L10n.str.builtinPromptWarning, style: const TextStyle(color: cWarning, fontSize: fMicro)),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                maxLines: 10,
                minLines: 5,
                style: TextStyle(color: tc.textMain, fontSize: fSmall, fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback),
                decoration: InputDecoration(
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: tc.border)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: tc.brand)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => controller.text = prompts.defaultSystemPrompt,
            child: Text(l10n.commonResetDefault, style: const TextStyle(color: cWarning)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonCancel, style: TextStyle(color: tc.textSub)),
          ),
          ElevatedButton(
            onPressed: () {
              prompts.saveSystemPrompt(controller.text.trim());
              Navigator.pop(ctx);
              showTopSnackBar(context, 
                SnackBar(
                  content: Text(L10n.str.builtinPromptSaved),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: tc.brand,
                foregroundColor: tc.isLight ? Colors.white : cBg,
              ),
            child: Text(l10n.save),
          ),
        ],
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
    final accent = isOrch ? cWarning : tc.agentGreen;

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(rFull),
          border: Border.all(color: accent.withValues(alpha: 0.25)),
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

/// 回答底部的「复制回答」胶囊。
///
/// 外层列表是 SelectionArea：光标默认落在文本光标上，命中区也归选区，所以这里
/// 自己声明手型光标、整块可点与悬停/按下态——否则它看着就只是回答下面一行正文。
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: _copied
                ? tc.ok.withValues(alpha: 0.12)
                : _pressed
                    ? tc.brand.withValues(alpha: 0.18)
                    : _hover
                        ? tc.brand.withValues(alpha: 0.07)
                        : Colors.transparent,
            borderRadius: BorderRadius.circular(rXSmall),
            border: Border.all(color: accent, width: 0.5),
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
