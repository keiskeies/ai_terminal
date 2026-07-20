import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:go_router/go_router.dart';
import 'package:xterm/xterm.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/credentials_store.dart';
import '../core/l10n_holder.dart';
import '../l10n/app_localizations.dart';
import '../widgets/sftp_panel.dart';
import '../widgets/logo_widget.dart';
import '../widgets/ai_prompt_input.dart';
import '../widgets/session_history_dialog.dart';
import '../widgets/agent_log_dialog.dart';
import '../widgets/agent_command_block.dart';
import '../widgets/agent_event_cards.dart';
import '../widgets/tab_item_widget.dart';
import '../services/daos.dart';
import '../core/prompts.dart' as prompts;
import '../models/runbook.dart';
import '../providers/app_providers.dart';
import '../providers/runbook_provider.dart';
import '../providers/terminal_provider.dart' as tp;
import '../providers/chat_provider.dart';
import '../providers/agent_provider.dart';
import '../models/ai_model_config.dart';
import '../models/host_config.dart';
import '../models/agent_event.dart';
import '../models/command_snippet.dart';
import '../services/ai_service.dart';
import '../services/command_executor.dart';
import '../services/server_monitor_service.dart';
import '../widgets/server_monitor_panel.dart';
import '../widgets/terminal_view.dart' as term_widget;


enum _AiPanelPosition { bottom, right }

class TerminalPage extends ConsumerStatefulWidget {
  final String? hostId; // null = 本地终端

  const TerminalPage({super.key, this.hostId});

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  Terminal? _terminal;
  bool _isConnecting = false;
  String? _connectionError;
  // ====== Per-tab 本地状态 ======
  String? _currentTabId;
  final Map<String, String?> _tabExecutingCommand = {};
  final Map<String, Set<String>> _tabExecutedCommands = {};
  final Map<String, String?> _tabPendingConfirm = {}; // 等待内联确认的危险命令
  final Map<String, Terminal> _tabTerminals = {}; // 每个 tab 独立的 Terminal 实例
  final Map<String, String> _tabAiInputText = {}; // 每个 tab 独立的 AI 输入框文字

  // AI 面板位置和大小
  _AiPanelPosition _aiPanelPosition = _AiPanelPosition.bottom;
  double _aiPanelRatio = 0.4;
  static const double _minPanelRatio = 0.15;
  static const double _maxPanelRatio = 0.7;

  // AI 面板是否可见（P0-1：支持完全收起）
  bool _isAIPanelVisible = false;

  // 服务器监控面板可见的 hostId 集合（每个 host 开关独立）
  final Set<String> _monitorVisibleHosts = {};

  // Per-host 监控服务缓存（key = hostId 或 "local"）
  final Map<String, ServerMonitorService> _monitorServices = {};

  // AI 输入框焦点状态（移动端键盘避让）
  bool _aiInputFocused = false;

  // SFTP 侧面板（桌面端）- Per-tab 独立状态
  final Map<String, bool> _tabSftpVisible = {}; // 每个 tab 的 SFTP 面板是否可见
  double _sftpPanelWidth = 320;
  static const double _minSftpWidth = 220;

  // 延迟 resize：记录最后需要同步尺寸的 tab
  tp.TerminalTab? _lastResizeTab;
  // R2: 保留 _switchToTab 的 150ms resize Timer 引用，便于切换 tab / dispose 时取消
  // 旧实现 inline 创建 Timer 不保留引用，导致 widget_test 中 dispose 后 Timer 仍 pending
  Timer? _resizeTimer;
  static const double _maxSftpWidth = 600;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  // Per-tab 状态便捷访问器（自动根据 _currentTabId 读写对应 tab 的状态）
  String? get _executingCommand => _currentTabId != null ? _tabExecutingCommand[_currentTabId!] : null;
  set _executingCommand(String? v) { if (_currentTabId != null) _tabExecutingCommand[_currentTabId!] = v; }
  Set<String> get _executedCommands => _currentTabId != null ? (_tabExecutedCommands[_currentTabId!] ??= {}) : {};
  String? get _pendingConfirmCommand => _currentTabId != null ? _tabPendingConfirm[_currentTabId!] : null;
  set _pendingConfirmCommand(String? v) { if (_currentTabId != null) _tabPendingConfirm[_currentTabId!] = v; }

  final _scrollController = ScrollController();
  final _chatScrollController = ScrollController();
  bool _showScrollToBottom = false;
  bool _autoScrollChat = true; // 用户手动上滚时禁用自动滚动
  StreamSubscription<String>? _terminalOutputSubscription;
  StreamSubscription<String>? _tabOutputSubscription; // 终端输出订阅（需随 tab 切换而取消/重建）
  AIModelConfig? _currentModelConfig;

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

  /// 手机端根据屏幕方向自动设置 AI 面板位置
  /// 切换方向时保持 AI 面板可见状态和面板比例
  void _updateMobilePosition(BuildContext context) {
    if (!_isMobile) return;
    final orientation = MediaQuery.of(context).orientation;
    final target = orientation == Orientation.landscape
        ? _AiPanelPosition.right
        : _AiPanelPosition.bottom;
    if (_aiPanelPosition != target) {
      // 保存当前面板比例，避免切换时重置
      final savedRatio = _aiPanelRatio;
      final savedVisibility = _isAIPanelVisible;
      setState(() {
        _aiPanelPosition = target;
        _aiPanelRatio = savedRatio;
        _isAIPanelVisible = savedVisibility;
      });
    }
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
        _isAIPanelVisible = aiPanelVisible as bool;
      }
    } catch (_) {}
    // 加载监控面板可见的 host 列表（per-host 独立开关）
    try {
      final raw = SettingsDao.getCached('monitorVisibleHosts');
      if (raw is List) {
        _monitorVisibleHosts.addAll(raw.cast<String>());
      }
    } catch (_) {}
    // 加载 Agent 最大步骤数（需在 initAgent 之前加载）
    // 延迟到下一帧，避免在 widget tree build 期间修改 provider state
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(agentProvider.notifier).loadSettings();
    });
    // 监听聊天滚动，控制"回到底部"按钮显示 & 自动滚动锁定
    _chatScrollController.addListener(() {
      if (!_chatScrollController.hasClients) return;
      final maxScroll = _chatScrollController.position.maxScrollExtent;
      final offset = _chatScrollController.offset;
      final distanceFromBottom = maxScroll - offset;
      final show = distanceFromBottom > 80;
      if (show != _showScrollToBottom) {
        setState(() => _showScrollToBottom = show);
      }
      // 用户手动上滚（距底部超过 120px）时禁用自动滚动
      if (distanceFromBottom > 120 && _autoScrollChat) {
        _autoScrollChat = false;
      }
      // 用户滚到底部时恢复自动滚动
      if (distanceFromBottom <= 40 && !_autoScrollChat) {
        _autoScrollChat = true;
      }
    });
  }

  Future<void> _initAgent() async {
    // 确保 provider 完成从 CredentialsStore 注入 apiKey（重启后 apiKey 来自安全存储）
    await ref.read(aiModelsProvider.notifier).loadModels();
    final models = ref.read(aiModelsProvider);
    if (models.isNotEmpty) {
      final defaultModel = models.firstWhere(
        (m) => m.isDefault,
        orElse: () => models.first,
      );
      _currentModelConfig = defaultModel;
      final aiProvider = AIService.create(defaultModel);
      ref.read(agentProvider.notifier).init(
        modelConfig: defaultModel,
        aiProvider: aiProvider,
      );
    }
  }

  /// 切换大模型
  void _switchModel(AIModelConfig model) {
    _currentModelConfig = model;
    final aiProvider = AIService.create(model);
    ref.read(agentProvider.notifier).init(
      modelConfig: model,
      aiProvider: aiProvider,
    );
    setState(() {});
  }

  Future<void> _connectToHost() async {
    final l10n = AppLocalizations.of(context)!;
    final host = ref.read(hostsProvider.notifier).getHostById(widget.hostId!);
    if (host == null) {
      setState(() => _connectionError = l10n.terminalHostNotFound);
      return;
    }

    setState(() => _isConnecting = true);

    try {
      final password = await CredentialsStore.get(hostId: host.id, type: 'password');
      final privateKey = await CredentialsStore.get(hostId: host.id, type: 'privateKey');

      if (password == null && privateKey == null) {
        setState(() {
          _isConnecting = false;
          _connectionError = l10n.noCredentials;
        });
        return;
      }

      await ref.read(tp.terminalProvider.notifier).openTab(
        host,
        password: password,
        privateKeyContent: privateKey,
      );

      final tab = ref.read(tp.terminalProvider).activeTab;
      if (tab == null || !tab.isConnected) {
        throw Exception(L10n.str.connectionFailedHint);
      }

      // SSH 连接成功后设置 executor（R3：显式传 tab.hostId，避免用 activeHostId 顶替）
      ref.read(agentProvider.notifier).setExecutor(tab.service, hostId: tab.hostId);

      _switchToTab(tab);
      setState(() => _isConnecting = false);
    } catch (e) {
      setState(() {
        _isConnecting = false;
        final errorMsg = e.toString();
        String hint;
        if (errorMsg.contains('Connection refused')) {
          hint = L10n.str.connErrRefused;
        } else if (errorMsg.contains('timeout') || errorMsg.contains('Timeout')) {
          hint = L10n.str.connErrTimeout;
        } else if (errorMsg.contains('authentication') || errorMsg.contains('Auth')) {
          hint = L10n.str.connErrAuth;
        } else if (errorMsg.contains('No route to host')) {
          hint = L10n.str.connErrNoRoute;
        } else {
          hint = L10n.str.connErrGeneric;
        }
        _connectionError = '$errorMsg\n\n💡 $hint';
      });
    }
  }

  /// 连接本地终端
  Future<void> _connectLocalTerminal() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref.read(tp.terminalProvider.notifier).openLocalTab();

      final tab = ref.read(tp.terminalProvider).activeTab;
      if (tab == null) {
        setState(() => _connectionError = l10n.terminalLocalStartFailed);
        return;
      }

      // 本地终端连接成功后立即设置 executor，使 Agent 模式可用
      ref.read(agentProvider.notifier).setExecutor(tab.localService, hostId: tab.hostId);

      _switchToTab(tab);
    } catch (e) {
      setState(() => _connectionError = l10n.terminalLocalStartFailedWithError('$e'));
    }
  }

  StreamSubscription<String> _setupTerminalListener(tp.TerminalTab tab) {
    final sub = tab.outputController.stream.listen((data) {
      if (_terminal != null) _terminal!.write(data);
    });
    _terminal?.onOutput = (data) {
      if (!tab.isConnected) {
        _reconnect();
        return;
      }
      if (tab.isLocal) {
        tab.localService?.writeToTerminal(data);
      } else {
        tab.service?.writeToTerminal(data);
      }
    };
    _terminal?.onResize = (width, height, pixelWidth, pixelHeight) {
      if (tab.isLocal) {
        tab.localService?.resize(width, height);
      } else {
        tab.service?.resize(width, height);
      }
    };
    return sub;
  }

  /// 统一切换到指定 tab：取消旧订阅 → 复用/创建 Terminal → 绑定新监听 → 切换 provider 状态
  void _switchToTab(tp.TerminalTab tab) {
    // 取消旧的订阅，避免多个 tab 的输出交叉
    _tabOutputSubscription?.cancel();
    _tabOutputSubscription = null;
    _terminalOutputSubscription?.cancel();
    _terminalOutputSubscription = null;

    // 复用已有的 Terminal 实例（保留终端内容），或为新 tab 创建
    if (_tabTerminals.containsKey(tab.id)) {
      _terminal = _tabTerminals[tab.id];
    } else {
      final term = Terminal(maxLines: 10000);
      _tabTerminals[tab.id] = term;
      _terminal = term;
    }

    // 绑定新 tab 的输出/输入监听
    _tabOutputSubscription = _setupTerminalListener(tab);
    _terminalOutputSubscription = tab.outputController.stream.listen((data) {
      ref.read(chatProvider.notifier).updateLastOutput(data);
    });

    // 更新各 provider 的当前 tab（switchTab 已恢复该 tab 的 engine/ssh/model）
    _currentTabId = tab.id;
    _autoScrollChat = true; // 切换 tab 时重置自动滚动
    _showScrollToBottom = false;
    ref.read(chatProvider.notifier).switchTab(tab.id, hostId: tab.hostId);
    ref.read(agentProvider.notifier).switchTab(tab.id, hostId: tab.hostId);
    // 不再调用 setSSHService — switchTab 已恢复该 tab 的 SSH 服务，
    // 避免每次切换都重新 collectSystemInfo

    setState(() {});

    // 首帧渲染后确保 PTY 尺寸与终端视图同步，修复 Tab 补全时 prompt 被覆盖的问题
    // 使用 Timer 延迟确保 xterm 内置的 resize 已完成，避免双重 SIGWINCH
    // R2: 保留 Timer 引用，切换 tab / dispose 时取消，避免 Timer 在 widget 销毁后仍 pending
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

    setState(() => _isConnecting = true);
    try {
      if (tab.isLocal) {
        final newTab = await ref.read(tp.terminalProvider.notifier).reconnectLocal(tab.id);
        if (newTab != null && newTab.localService != null) {
          // 重新绑定 executor（service 已更新）
          ref.read(agentProvider.notifier).setExecutor(newTab.localService, hostId: newTab.hostId);
          // 重新绑定终端输入监听（旧闭包持有的是旧 localService 引用）
          _tabOutputSubscription?.cancel();
          _tabOutputSubscription = _setupTerminalListener(newTab);
        }
      } else {
        final host = ref.read(hostsProvider.notifier).getHostById(tab.hostId);
        if (host == null) {
          setState(() => _connectionError = L10n.str.terminalHostNotFound);
          return;
        }
        final newTab = await ref.read(tp.terminalProvider.notifier).reconnect(tab.id, host);
        if (newTab != null && newTab.service != null) {
          ref.read(agentProvider.notifier).setExecutor(newTab.service, hostId: newTab.hostId);
          // 重新绑定终端输入监听（旧闭包持有的是旧 service 引用）
          _tabOutputSubscription?.cancel();
          _tabOutputSubscription = _setupTerminalListener(newTab);
        }
      }
    } finally {
      setState(() => _isConnecting = false);
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
                  const Icon(Icons.add_circle_outline, size: 16, color: cPrimary),
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
                        color: cPrimary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(rSmall),
                        border: Border.all(color: cPrimary.withValues(alpha: 0.2)),
                      ),
                      child: Text(l10n.terminalCreateNew, style: const TextStyle(fontSize: fMicro, color: cPrimary, fontWeight: FontWeight.w500)),
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
                    subtitle: Text('${host.username}@${host.host}', style: TextStyle(fontSize: fMicro, color: tc.textSub, fontFamily: 'JetBrainsMono')),
                    trailing: Icon(Icons.open_in_new, size: 14, color: tc.textMuted),
                    onTap: () async {
                      Navigator.pop(context);
                      await _connectToNewTab(host);
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

  /// 在新标签中连接服务器
  Future<void> _connectToNewTab(dynamic host) async {
    final l10n = AppLocalizations.of(context)!;
    final password = await CredentialsStore.get(hostId: host.id, type: 'password');
    final privateKey = await CredentialsStore.get(hostId: host.id, type: 'privateKey');

    if (password == null && privateKey == null) {
      final ctx = context;
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(l10n.terminalHostNoCredentials(host.name)),
          backgroundColor: cWarning,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      await ref.read(tp.terminalProvider.notifier).openTab(
        host,
        password: password,
        privateKeyContent: privateKey,
      );
      // 更新终端显示到新标签
      final tab = ref.read(tp.terminalProvider).activeTab;
      if (tab != null && tab.isConnected) {
        _switchToTab(tab);
      }
    } catch (e) {
      final ctx = context;
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(l10n.terminalConnectHostFailed(host.name, '$e')),
          backgroundColor: cDanger,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    _resizeTimer?.cancel();
    _resizeTimer = null;
    _tabOutputSubscription?.cancel();
    _terminalOutputSubscription?.cancel();
    _scrollController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.hostId != null ? ref.watch(hostsProvider.notifier).getHostById(widget.hostId!) : null;
    final terminalState = ref.watch(tp.terminalProvider);
    final chatState = ref.watch(chatProvider);
    final agentState = ref.watch(agentProvider);
    final activeTab = terminalState.activeTab;

    final tc = ThemeColors.of(context);

    // 手机端：根据屏幕方向自动设置 AI 面板位置
    _updateMobilePosition(context);

    // ref.listen 必须在 build 中无条件调用，否则面板收起时 listener 消失会触发 assertion
    ref.listen(chatProvider, (_, state) {
      if (state.currentAssistantMessage != null || state.messages.isNotEmpty) {
        _scrollChatToBottom();
      }
    });
    ref.listen(agentProvider, (_, state) {
      if (state.chatItems.isNotEmpty) {
        _scrollChatToBottom();
      }
    });

    return Scaffold(
      backgroundColor: tc.bg,
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          // 顶部栏（标签 + 工具）
          _buildTopBar(host, terminalState, activeTab),

          // 终端 + AI 面板主体
          Expanded(
            child: _buildMainBody(host, chatState, agentState, activeTab),
          ),

          // 快捷按键行（仅 Android / iOS 显示，桌面端不需要）
          // 当 AI 输入框获焦（键盘弹出）时隐藏快捷按键栏，节省空间
          if (Platform.isAndroid || Platform.isIOS && !_aiInputFocused)
            _buildQuickKeysBar(activeTab),
        ],
      ),
    );
  }

  /// 主体区域：终端 + AI 面板 + SFTP 侧面板，根据面板位置切换布局
  Widget _buildMainBody(dynamic host, ChatState chatState, AgentState agentState, tp.TerminalTab? tab) {

    // 终端视图
    final terminalView = Stack(
      children: [
        _isConnecting
            ? _buildConnectingView(host)
            : _connectionError != null
                ? _buildErrorView()
                : term_widget.TerminalView(
                    terminal: _terminal,
                    fontSize: _terminalFontSize,
                    onSend: (command) {
                      final t = ref.read(tp.terminalProvider).activeTab;
                      if (t == null) return;
                      if (t.isLocal) {
                        t.localService?.execute(command);
                      } else {
                        t.service?.execute(command);
                      }
                    },
                  ),
        if (tab != null && !tab.isConnected)
          Positioned(
            top: 8,
            right: 8,
            child: _buildDisconnectedChip(),
          ),
      ],
    );

    // 监控面板包装：在终端下方插入监控横幅（仅在已连接且该 host 开关开启时）
    final monitorService = _getOrCreateMonitorService(tab);
    final currentHostId = tab != null && tab.isConnected
        ? (tab.isLocal ? 'local' : tab.hostId)
        : null;
    final showMonitor = currentHostId != null &&
        _monitorVisibleHosts.contains(currentHostId) &&
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
    if (!_isAIPanelVisible) {
      // AI 面板收起状态：终端占满全屏，移动端支持上滑展开 AI 面板
      mainContent = _isMobile
          ? GestureDetector(
              onVerticalDragEnd: (details) {
                // 上滑速度超过阈值时展开 AI 面板
                if (details.primaryVelocity != null && details.primaryVelocity! < -300) {
                  setState(() => _isAIPanelVisible = true);
                  SettingsDao.set('aiPanelVisible', true);
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
        final isRight = _aiPanelPosition == _AiPanelPosition.right;

        void onDrag(DragUpdateDetails details) {
          setState(() {
            if (isRight) {
              final pos = details.globalPosition.dx - (context.findRenderObject() as RenderBox).localToGlobal(Offset.zero).dx;
              _aiPanelRatio = (1 - pos / totalW).clamp(_minPanelRatio, _maxPanelRatio).toDouble();
            } else {
              final pos = details.globalPosition.dy - (context.findRenderObject() as RenderBox).localToGlobal(Offset.zero).dy;
              _aiPanelRatio = (1 - pos / totalH).clamp(_minPanelRatio, _maxPanelRatio).toDouble();
            }
          });
        }

        final tc = ThemeColors.of(context);
        // 手机端不显示拖拽手柄
        final dragHandle = _isMobile
            ? (isRight ? const SizedBox.shrink() : GestureDetector(
                // 移动端底部布局：可拖拽调整高度的手柄
                onPanUpdate: onDrag,
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
              child: MouseRegion(
                cursor: isRight ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
                child: Container(
                  width: isRight ? 5 : double.infinity,
                  height: isRight ? double.infinity : 5,
                  color: tc.border.withValues(alpha: 0.6),
                ),
              ),
            );

        final divider = _buildAreaDivider(agentState);
        final aiPanelSize = isRight ? totalW * _aiPanelRatio : totalH * _aiPanelRatio;
        final aiContent = Column(
          children: [
            Expanded(child: _buildAIPanel(chatState, agentState, tab)),
            _buildBottomBar(chatState, agentState, tab),
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
                      setState(() => _isAIPanelVisible = false);
                      SettingsDao.set('aiPanelVisible', false);
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

    // 桌面端：SFTP 侧面板（per-tab 独立，用 Offstage 保持存活避免重连）
    final currentTabId = ref.read(tp.terminalProvider).activeTabId;
    final allTabs = ref.read(tp.terminalProvider).tabs;
    final visibleSftpTabs = allTabs.where((t) => !t.isLocal && (_tabSftpVisible[t.id] ?? false)).toList();
    final hasActiveSftp = currentTabId != null && (_tabSftpVisible[currentTabId] ?? false) && !_isMobile;

    if (hasActiveSftp && visibleSftpTabs.isNotEmpty) {
      final tc = ThemeColors.of(context);
      return Row(
        children: [
          Expanded(child: mainContent),
          // SFTP 拖拽调整宽度手柄
          GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                _sftpPanelWidth -= details.delta.dx;
                _sftpPanelWidth = _sftpPanelWidth.clamp(_minSftpWidth, _maxSftpWidth);
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
                      key: ValueKey('sftp-${tab.id}-${tab.hostId}'),
                      hostId: tab.hostId,
                      embedded: true,
                      onClose: () => setState(() => _tabSftpVisible[tab.id] = false),
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
      if (activeTab != null && activeTab.isLocal && (_tabSftpVisible[currentTabId] ?? false)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _tabSftpVisible[currentTabId] = false);
        });
      }
    }

    return mainContent;
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
          _buildTopBarActions(activeTab, tc),
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

  /// 右侧操作区：连接状态、AI 面板开关、设置、更多
  Widget _buildTopBarActions(tp.TerminalTab? activeTab, ThemeColors tc) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildConnectionBadge(activeTab),
        const SizedBox(width: 6),
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.orchAgentRunning),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        if (agentState.isRunning && tab.id == ref.read(tp.terminalProvider).activeTab?.id) {
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
        ref.read(chatProvider.notifier).removeTab(tab.id);
        ref.read(agentProvider.notifier).removeTab(tab.id, hostId: tab.hostId);
        _tabAiInputText.remove(tab.id);
        _tabExecutingCommand.remove(tab.id);
        _tabExecutedCommands.remove(tab.id);
        _tabPendingConfirm.remove(tab.id);
        _tabTerminals.remove(tab.id);
        _tabSftpVisible.remove(tab.id);
        await ref.read(tp.terminalProvider.notifier).closeTab(tab.id);
        final newActiveTab = ref.read(tp.terminalProvider).activeTab;
        if (newActiveTab != null) {
          _switchToTab(newActiveTab);
        }
        if (ref.read(tp.terminalProvider).tabs.isEmpty && mounted) {
          _connectLocalTerminal();
        }
      },
    );
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
          child: Text(l10n.terminalFontSize(_terminalFontSize.toInt()), style: const TextStyle(fontSize: fMicro, color: cPrimary, fontWeight: FontWeight.w600)),
        ),
        ...[8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 18.0, 20.0, 22.0, 24.0].map((size) => PopupMenuItem<String>(
          value: 'font_$size',
          height: 28,
          child: Row(
            children: [
              if (_terminalFontSize == size)
                const Icon(Icons.check, size: 12, color: cPrimary)
              else
                const SizedBox(width: 12),
              const SizedBox(width: 4),
              Text('${size.toInt()}px', style: TextStyle(fontSize: fSmall, color: _terminalFontSize == size ? cPrimary : tc.textMain)),
            ],
          ),
        )),
      ],
    );
  }

  Widget _buildConnectionBadge(tp.TerminalTab? tab) {
    final connected = tab?.isConnected == true;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (connected ? cSuccess : cDanger).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(rFull),
        border: Border.all(color: (connected ? cSuccess : cDanger).withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: connected ? cSuccess : cDanger,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: (connected ? cSuccess : cDanger).withValues(alpha: 0.5), blurRadius: 4),
              ],
            ),
          ),
          const SizedBox(width: 5),
          Text(
            connected ? l10n.terminalConnected : l10n.terminalOffline,
            style: TextStyle(fontSize: fMicro, color: connected ? cSuccess : cDanger, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  /// P0-1: AI 面板展开/收起按钮
  Widget _buildAIPanelToggleButton() {
    final tc = ThemeColors.of(context);
    final accentColor = tc.agentGreen;
    final l10n = AppLocalizations.of(context)!;

    return Tooltip(
      message: _isAIPanelVisible ? l10n.terminalCollapseAIPanel : l10n.terminalExpandAIPanel,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _isAIPanelVisible = !_isAIPanelVisible;
          });
          // 持久化状态
          SettingsDao.set('aiPanelVisible', _isAIPanelVisible);
        },
        child: AnimatedContainer(
          duration: animFast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _isAIPanelVisible ? accentColor.withValues(alpha: 0.15) : tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(
              color: _isAIPanelVisible ? accentColor.withValues(alpha: 0.4) : tc.border.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isAIPanelVisible ? Icons.auto_fix_high : Icons.auto_fix_high_outlined,
                size: 14,
                color: _isAIPanelVisible ? accentColor : tc.textSub,
              ),
              const SizedBox(width: 4),
              Text(
                _isAIPanelVisible ? 'AI' : 'AI',
                style: TextStyle(
                  fontSize: fMicro,
                  color: _isAIPanelVisible ? accentColor : tc.textSub,
                  fontWeight: _isAIPanelVisible ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  /// 服务器监控面板开关按钮（终端下方横幅）
  Widget _buildMonitorToggleButton() {
    final tc = ThemeColors.of(context);
    const accentColor = cKleinBlue;
    final activeTab = ref.read(tp.terminalProvider).activeTab;
    final canShow = activeTab != null && activeTab.isConnected;
    // per-host 开关状态
    final hostId = activeTab != null && activeTab.isConnected
        ? (activeTab.isLocal ? 'local' : activeTab.hostId)
        : null;
    final isOn = hostId != null && _monitorVisibleHosts.contains(hostId);
    final l10n = AppLocalizations.of(context)!;

    return Tooltip(
      message: isOn ? l10n.terminalCollapseMonitorPanel : l10n.terminalExpandMonitorPanel,
      child: GestureDetector(
        onTap: canShow ? () {
          setState(() {
            if (isOn) {
              _monitorVisibleHosts.remove(hostId);
            } else {
              _monitorVisibleHosts.add(hostId!);
            }
          });
          // 持久化为 List
          SettingsDao.set('monitorVisibleHosts', _monitorVisibleHosts.toList());
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
    final hostId = tab.isLocal ? 'local' : tab.hostId;
    var svc = _monitorServices[hostId];
    if (svc == null) {
      final executor = tab.isLocal ? tab.localService : tab.service;
      svc = ServerMonitorService(executor: executor, isLocal: tab.isLocal);
      _monitorServices[hostId] = svc;
    } else if (svc.executor != (tab.isLocal ? tab.localService : tab.service)) {
      // 服务实例变了（重连），重置历史
      svc.reset();
      _monitorServices[hostId] = ServerMonitorService(executor: tab.isLocal ? tab.localService : tab.service, isLocal: tab.isLocal);
      svc = _monitorServices[hostId]!;
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
            child: Text(l10n.quickCommands, style: const TextStyle(fontSize: fMicro, color: cPrimary, fontWeight: FontWeight.w600)),
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

  // ==================== 连接中/错误 ====================
  Widget _buildConnectingView(dynamic host) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 24, height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: cPrimary),
          ),
          const SizedBox(height: 12),
          Text(l10n.terminalConnecting(host?.host ?? ''), style: TextStyle(color: tc.textSub, fontSize: fBody)),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 40, color: cDanger),
            const SizedBox(height: 12),
            Text(L10n.str.connectionFailed, style: TextStyle(color: tc.textSub, fontSize: fBody)),
            const SizedBox(height: 6),
            Text(_connectionError!, style: const TextStyle(color: cDanger, fontSize: fSmall), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: _connectToHost,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cPrimary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
                  ),
                  child: Text(l10n.retry, style: const TextStyle(fontSize: fBody)),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () => _connectLocalTerminal(),
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
          ],
        ),
      ),
    );
  }

  Widget _buildDisconnectedChip() {
    final l10n = AppLocalizations.of(context)!;
    return GestureDetector(
      onTap: _reconnect,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: cDanger.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(rFull),
          border: Border.all(color: cDanger.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_amber_rounded, color: cDanger, size: 12),
            const SizedBox(width: 4),
            Text(l10n.connectionInterrupted, style: const TextStyle(color: cDanger, fontSize: fMicro, fontWeight: FontWeight.w500)),
            const SizedBox(width: 4),
            Text(l10n.terminalReconnect, style: const TextStyle(color: cDanger, fontSize: fMicro, fontWeight: FontWeight.w600, decoration: TextDecoration.underline)),
          ],
        ),
      ),
    );
  }

  // ==================== 区域分界线（分割条，位于终端和 AI 面板之间）====================
  Widget _buildAreaDivider(AgentState agentState) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final accentColor = tc.agentGreen;
    final isRight = _aiPanelPosition == _AiPanelPosition.right;
    // 手机端不显示位置切换按钮
    final showButtons = !_isMobile;

    // Chrome DevTools 风格的方形布局切换按钮
    Widget layoutButton(_AiPanelPosition pos, IconData icon, String tooltip) {
      final isActive = _aiPanelPosition == pos;
      return Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onTap: () => setState(() => _aiPanelPosition = pos),
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
            setState(() => _isAIPanelVisible = false);
            SettingsDao.set('aiPanelVisible', false);
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
  Widget _buildAIPanel(ChatState chatState, AgentState agentState, tp.TerminalTab? tab) {
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
          // 消息列表 + 回到底部按钮
          Expanded(
            child: Stack(
              children: [
                _buildAgentChatList(agentState, tab),
                // 回到底部按钮
                if (_showScrollToBottom)
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
          if (chatState.error != null || agentState.error != null)
            _buildErrorBanner(chatState.error ?? agentState.error),
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
        color: cPrimaryBg,
        border: Border(
          bottom: BorderSide(color: cPrimary.withValues(alpha: 0.3)),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: cPrimary),
          ),
          const SizedBox(width: 8),
          Text(
            L10n.str.compacting,
            style: const TextStyle(
              color: cPrimary,
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 用户点击"回到底部"按钮：恢复自动滚动并滚到底部
  void _scrollChatToBottomManual() {
    _autoScrollChat = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
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
    if (items.isEmpty) {
      return Center(child: Text(l10n.terminalInputHintEmpty, style: TextStyle(color: ThemeColors.of(context).textMuted, fontSize: fBody)));
    }
    return ListView.builder(
      controller: _chatScrollController,
      padding: const EdgeInsets.all(8),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final isLast = index == items.length - 1;
        return _buildMessageBubble(
          key: ValueKey('agent_${item.role}_$index'),
          role: item.role,
          content: item.content,
          events: item.events,
          streamingContent: item.streamingContent,
          isLoading: item.isStreaming && isLast && agentState.isRunning,
          tab: tab,
          showAutoExecute: true,
          isAgentRunning: agentState.isRunning,
          isWaitingChoice: agentState.isWaitingChoice,
          pendingOptions: agentState.isWaitingChoice && isLast ? agentState.pendingOptions : const [],
          enginePendingConfirm: isLast ? agentState.pendingConfirmCommand : null,
        );
      },
    );
  }

  // ==================== Markdown 预处理 ====================
  /// 将单个换行转为 Markdown 硬换行（带缓存）
  String _preprocessMarkdown(String text) {
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
    String? enginePendingConfirm,
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
          color: isUser
              ? cPrimary.withValues(alpha: 0.2)
              : tc.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(rMedium),
            topRight: const Radius.circular(rMedium),
            bottomLeft: Radius.circular(isUser ? rMedium : rXSmall),
            bottomRight: Radius.circular(isUser ? rXSmall : rMedium),
          ),
          border: Border.all(
            color: isUser
                ? cPrimary.withValues(alpha: 0.3)
                : tc.border.withValues(alpha: 0.3),
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
                    gradient: LinearGradient(
                      colors: isUser
                          ? [cPrimary.withValues(alpha: 0.18), cPrimary.withValues(alpha: 0.08)]
                          : [tc.agentGreen.withValues(alpha: 0.18), tc.agentGreen.withValues(alpha: 0.06)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(rXSmall),
                    border: Border.all(
                      color: (isUser ? cPrimary : tc.agentGreen).withValues(alpha: 0.2),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isUser ? Icons.person_outline : Icons.auto_awesome,
                        size: 11,
                        color: isUser ? cPrimary : tc.agentGreen,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isUser ? l10n.terminalRoleYou : l10n.commonAIAssistant,
                        style: TextStyle(
                          fontSize: fMicro,
                          color: isUser ? cPrimary : tc.agentGreen,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      if (isLoading) ...[
                        const SizedBox(width: 6),
                        SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.5, color: isUser ? cPrimary : tc.agentGreen)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 内容
            if (isUser)
              SelectableText(content, style: TextStyle(color: tc.textMain, fontSize: fBody, height: 1.5))
            else
              _buildAIContent(content, tc, tab, showAutoExecute, isLoading, isAgentRunning, isWaitingChoice, pendingOptions: pendingOptions, events: events, streamingContent: streamingContent, enginePendingConfirm: enginePendingConfirm),
          ],
        ),
      ),
    );
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
    String? enginePendingConfirm,
  }) {
    // 合并两种待确认来源：引擎自动流程（enginePendingConfirm）和手动播放（_pendingConfirmCommand）
    final effectivePendingConfirm = enginePendingConfirm ?? _pendingConfirmCommand;

    // 判断某命令是否是引擎等待确认的命令（走 confirmCommand/rejectCommand 路径）
    bool isEngineConfirm(String command) =>
        enginePendingConfirm != null && enginePendingConfirm == command.trim();

    // 优先使用结构化事件渲染（ReAct 格式已由 ReActStreamParser 正确解析）
    if (events.isNotEmpty) {
      // 判断 events 中是否有 AI 输出的内容事件（thought/command/text/ask/finish）
      // 如果只有 result/info，说明还在流式过程中，需要同时显示 streamingContent
      final hasAIContentEvents = events.any((e) =>
          e.isThought || e.isCommand || e.isText || e.isAsk || e.isFinish);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AgentEventContent(
            events: events,
            tc: tc,
            tab: tab,
            showAutoExecute: showAutoExecute,
            isLoading: isLoading,
            isWaitingChoice: isWaitingChoice,
            pendingOptions: pendingOptions,
            executingCommand: _executingCommand,
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
          ),
          // 只有在还没有 AI 内容事件时（流式过程中，只有 result/info），才显示流式纯文本
          // 流式结束后从历史恢复时 streamingContent 为空，使用持久化的 content 兜底
          if (!hasAIContentEvents) ...[
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
                executingCommand: _executingCommand,
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


  /// 渲染一段 Markdown 文本（用于 thought/text/info 的自动追加显示）
  Widget _buildMarkdownText(String text, ThemeColors tc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MarkdownBody(
        data: _preprocessMarkdown(text),
        selectable: true,
        // 规避 flutter_markdown 0.6.23 在 selectable=true 时无条件调用 onSelectionChanged!() 的 bug
        onSelectionChanged: (_, __, ___) {},
        styleSheet: MarkdownStyleSheet(
          p: TextStyle(color: tc.textMain, height: 1.5, fontSize: fBody),
          h1: TextStyle(color: tc.textMain, fontSize: 16, fontWeight: FontWeight.bold),
          h2: TextStyle(color: tc.textMain, fontSize: 14, fontWeight: FontWeight.bold),
          h3: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600),
          code: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: fMono,
            color: tc.terminalGreen,
            backgroundColor: tc.terminalBg,
          ),
          listBullet: const TextStyle(color: cPrimary, fontSize: fBody),
          blockquote: TextStyle(color: tc.textSub, fontStyle: FontStyle.italic),
          blockquoteDecoration: const BoxDecoration(
            border: Border(left: BorderSide(color: cPrimary, width: 2)),
          ),
          blockquotePadding: const EdgeInsets.only(left: 8),
        ),
        onTapLink: (text, href, title) {},
      ),
    );
  }

  /// 将内容按代码块分割（带缓存）
  List<_ContentSegment> _splitContentByCodeBlocks(String content) {
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

  // ==================== 斜杠命令 ====================
  /// 处理斜杠命令，返回 true 表示已处理（不再发送）
  bool _handleSlashCommand(String command, {required bool isConnected}) {
    final l10n = AppLocalizations.of(context)!;
    final cmd = command.trim().toLowerCase();
    switch (cmd) {
      case '/new':
        _autoScrollChat = true;
        ref.read(agentProvider.notifier).newSession();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.terminalSessionCreated, style: const TextStyle(fontSize: 13)),
            duration: const Duration(seconds: 1),
          ),
        );
        return true;
      case '/compact':
        if (!isConnected) {
          ScaffoldMessenger.of(context).showSnackBar(
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.terminalCompactionDone, style: const TextStyle(fontSize: 13)),
              duration: const Duration(seconds: 1),
            ),
          );
        }).catchError((e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
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
  Widget _buildBottomBar(ChatState chatState, AgentState agentState, tp.TerminalTab? tab) {
    final isConnected = tab?.isConnected == true;
    // 从 provider 读取（已注入 apiKey），而非直接读 Hive
    final models = ref.read(aiModelsProvider);
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;

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
              // 只读模式（Dry-run）切换
              _buildToolbarIconButton(
                icon: agentState.isReadOnlyMode ? Icons.lock : Icons.lock_open_outlined,
                tooltip: agentState.isReadOnlyMode ? l10n.terminalReadOnlyOn : l10n.terminalReadOnlyOff,
                onTap: () {
                  ref.read(agentProvider.notifier).toggleReadOnlyMode();
                },
                tc: tc,
                active: agentState.isReadOnlyMode,
              ),
              const SizedBox(width: 4),
              // 运维模板（Runbook）
              _buildToolbarIconButton(
                icon: Icons.bolt_outlined,
                tooltip: l10n.terminalRunbookTemplates,
                onTap: () => _showRunbookTemplates(tc),
                tc: tc,
              ),
              const Spacer(),
              // 运行状态指示
              if (agentState.isRunning)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: tc.agentGreen.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rFull),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 10, height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: tc.agentGreen),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        agentState.statusText,
                        style: TextStyle(fontSize: fMicro, color: tc.agentGreen, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              if (agentState.isRunning)
                const SizedBox(width: 6),
              // 模型选择
              if (models.isNotEmpty)
                _buildModelSelector(models, tc),
            ],
          ),
          const SizedBox(height: 8),
          // 输入框
          AIPromptInput(
            enabled: isConnected,
            isRunning: agentState.isRunning,
            hintText: _getInputHint(isConnected, agentState.isRunning, agentState.isOrchestratorMode),
            initialText: _tabAiInputText[_currentTabId ?? ''] ?? '',
            accentColor: tc.agentGreen,
            isOrchestratorMode: agentState.isOrchestratorMode,
            onToggleOrchestrator: () {
              ref.read(agentProvider.notifier).toggleOrchestratorMode();
            },
            onFocusChanged: (focused) {
              setState(() => _aiInputFocused = focused);
            },
            onChanged: (text) { _tabAiInputText[_currentTabId ?? ''] = text; },
            onSlashCommand: (command) {
              return _handleSlashCommand(command, isConnected: isConnected);
            },
            onStop: () => ref.read(agentProvider.notifier).cancel(),
            onSend: (text) async {
              if (!_checkAIModelConfigured()) {
                _showAIModelNotConfiguredHint();
                return;
              }
              _autoScrollChat = true; // 用户发送新消息时恢复自动滚动
              if (isConnected) {
                final tab = ref.read(tp.terminalProvider).activeTab;
                // 本地终端用 localService，SSH 用 service
                final CommandExecutor? executor = tab?.isLocal == true ? tab?.localService : tab?.service;
                ref.read(agentProvider.notifier).setExecutor(executor, hostId: tab?.hostId ?? 'local');
                await ref.read(agentProvider.notifier).startTask(text);
              }
            },
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

  /// 模型选择器 - 紧凑按钮
  Widget _buildModelSelector(List<AIModelConfig> models, ThemeColors tc) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      onSelected: (modelId) {
        final model = models.firstWhere((m) => m.id == modelId);
        _switchModel(model);
      },
      offset: const Offset(0, -70),
      color: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
      itemBuilder: (context) => models.map((m) {
        final isActive = m.id == _currentModelConfig?.id;
        return PopupMenuItem<String>(
          value: m.id,
          height: 32,
          child: Row(
            children: [
              Container(
                width: 6, height: 6,
                decoration: BoxDecoration(
                  color: isActive ? cPrimary : Colors.transparent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                m.name,
                style: TextStyle(
                  fontSize: fSmall,
                  color: isActive ? cPrimary : ThemeColors.of(context).textMain,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                m.modelName,
                style: TextStyle(fontSize: fMicro, color: ThemeColors.of(context).textMuted),
              ),
            ],
          ),
        );
      }).toList(),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: tc.surface,
          borderRadius: BorderRadius.circular(rSmall),
          border: Border.all(color: tc.border.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined, size: 12, color: tc.textMuted),
            const SizedBox(width: 3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 80),
              child: Text(
                _currentModelConfig?.name ?? l10n.terminalModel,
                style: TextStyle(fontSize: fSmall, color: tc.textSub, height: 1.0),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.unfold_more, size: 10, color: tc.textMuted),
          ],
        ),
      ),
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
                    ? cPrimary.withValues(alpha: isConnected ? 0.12 : 0.05)
                    : isNav
                        ? cSuccess.withValues(alpha: isConnected ? 0.08 : 0.03)
                        : tc.surface,
                borderRadius: BorderRadius.circular(rXSmall),
                border: Border.all(
                  color: isCore
                      ? cPrimary.withValues(alpha: isConnected ? 0.3 : 0.1)
                      : isNav
                          ? cSuccess.withValues(alpha: isConnected ? 0.2 : 0.05)
                          : tc.border.withValues(alpha: 0.3),
                ),
              ),
              child: Center(
                child: Text(
                  key.label,
                  style: TextStyle(
                    fontSize: fMicro,
                    color: isCore
                        ? (isConnected ? cPrimary : tc.textMuted)
                        : isNav
                            ? (isConnected ? cSuccess : tc.textMuted)
                            : (isConnected ? tc.textSub : tc.textMuted),
                    fontFamily: 'JetBrainsMono',
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
    final runbooks = ref.read(runbooksProvider);
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
                    const Icon(Icons.bolt, size: 16, color: cPrimary),
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
                        foregroundColor: cPrimary,
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
    final typeColor = isAgent ? cPrimary : cSuccess;
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
      ScaffoldMessenger.of(context).showSnackBar(
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
    ref.read(agentProvider.notifier).setExecutor(executor, hostId: tab.hostId);
    await ref.read(runbooksProvider.notifier).incrementRunCount(rb.id);
    await ref.read(agentProvider.notifier).startTask(rb.content);
  }

  /// 执行 Runbook（command 类型）：变量替换后直接在终端执行命令
  void _sendRunbookCommand(Runbook rb) async {
    final tab = ref.read(tp.terminalProvider).activeTab;
    if (tab == null || !tab.isConnected) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
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
        ScaffoldMessenger.of(context).showSnackBar(
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
                    fontFamily: 'JetBrainsMono',
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
                        fontFamily: 'JetBrainsMono',
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
                        borderSide: const BorderSide(color: cPrimary),
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
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary),
            child: Text(l10n.commonExecute),
          ),
        ],
      ),
    );
  }

  String _getInputHint(bool isConnected, bool isRunning, bool isOrchestrator) {
    final l10n = AppLocalizations.of(context)!;
    if (isRunning) return l10n.terminalInputHintRunning;
    if (!isConnected) return l10n.terminalInputHintDisconnected;
    if (isOrchestrator) return l10n.terminalInputHintOrchestrator;
    return l10n.terminalInputHintDefault;
  }

  bool _checkAIModelConfigured() {
    try {
      return AIModelsDao.cached.isNotEmpty;
    } catch (_) { return false; }
  }

  void _showAIModelNotConfiguredHint() {
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
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
                focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
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
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n.terminalMaxStepsSet(clamped)),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
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
            Text(l10n.snippetResolvedCommand(snippet.command), style: TextStyle(color: tc.textSub, fontSize: fSmall, fontFamily: 'JetBrainsMono')),
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
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
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
                  focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
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
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(L10n.str.customPromptSaved),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
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
                style: TextStyle(color: tc.textMain, fontSize: fSmall, fontFamily: 'JetBrainsMono'),
                decoration: InputDecoration(
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: tc.border)),
                  focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
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
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(L10n.str.builtinPromptSaved),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
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
