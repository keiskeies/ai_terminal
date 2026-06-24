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
import '../widgets/sftp_panel.dart';
import '../core/hive_init.dart';
import '../core/prompts.dart' as prompts;
import '../providers/app_providers.dart';
import '../providers/terminal_provider.dart' as tp;
import '../providers/chat_provider.dart';
import '../providers/agent_provider.dart';
import '../models/ai_model_config.dart';
import '../models/agent_event.dart';
import '../models/command_snippet.dart';
import 'package:flutter/services.dart';
import '../services/ai_service.dart';
import '../services/command_executor.dart';
import '../services/agent_engine.dart';
import '../services/conversation_service.dart';
import '../models/conversation.dart';
import '../core/safety_guard.dart';
import '../utils/ai_parser.dart';
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
  final Map<String, Terminal> _tabTerminals = {}; // 每个 tab 独立的 Terminal 实例
  final Map<String, String> _tabAiInputText = {}; // 每个 tab 独立的 AI 输入框文字

  // AI 面板位置和大小
  _AiPanelPosition _aiPanelPosition = _AiPanelPosition.bottom;
  double _aiPanelRatio = 0.4;
  static const double _minPanelRatio = 0.15;
  static const double _maxPanelRatio = 0.7;

  // AI 面板是否可见（P0-1：支持完全收起）
  bool _isAIPanelVisible = false;

  // AI 输入框焦点状态（移动端键盘避让）
  bool _aiInputFocused = false;

  // SFTP 侧面板（桌面端）- Per-tab 独立状态
  final Map<String, bool> _tabSftpVisible = {}; // 每个 tab 的 SFTP 面板是否可见
  double _sftpPanelWidth = 320;
  static const double _minSftpWidth = 220;

  // 延迟 resize：记录最后需要同步尺寸的 tab
  tp.TerminalTab? _lastResizeTab;
  static const double _maxSftpWidth = 600;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  // Per-tab 状态便捷访问器（自动根据 _currentTabId 读写对应 tab 的状态）
  String? get _executingCommand => _currentTabId != null ? _tabExecutingCommand[_currentTabId!] : null;
  set _executingCommand(String? v) { if (_currentTabId != null) _tabExecutingCommand[_currentTabId!] = v; }
  Set<String> get _executedCommands => _currentTabId != null ? (_tabExecutedCommands[_currentTabId!] ??= {}) : {};

  final _scrollController = ScrollController();
  final _chatScrollController = ScrollController();
  bool _showScrollToBottom = false;
  bool _autoScrollChat = true; // 用户手动上滚时禁用自动滚动
  StreamSubscription<String>? _terminalOutputSubscription;
  StreamSubscription<String>? _tabOutputSubscription; // 终端输出订阅（需随 tab 切换而取消/重建）
  bool _agentInitialized = false;
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
      final fontSize = HiveInit.settingsBox.get('terminalFontSize');
      if (fontSize != null) {
        _terminalFontSize = (fontSize as num).toDouble();
      } else {
        // P0-3: 如果没有设置过，使用新的默认值 14
        _terminalFontSize = 14;
        HiveInit.settingsBox.put('terminalFontSize', 14.0);
      }
    } catch (_) {
      _terminalFontSize = 14;
    }
    // P0-1: 加载 AI 面板可见性设置，默认收起
    try {
      final aiPanelVisible = HiveInit.settingsBox.get('aiPanelVisible');
      if (aiPanelVisible != null) {
        _isAIPanelVisible = aiPanelVisible as bool;
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
    final models = HiveInit.aiModelsBox.values.toList();
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
      _agentInitialized = true;
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
    final host = ref.read(hostsProvider.notifier).getHostById(widget.hostId!);
    if (host == null) {
      setState(() => _connectionError = '主机不存在');
      return;
    }

    setState(() => _isConnecting = true);

    try {
      final password = await CredentialsStore.get(hostId: host.id, type: 'password');
      final privateKey = await CredentialsStore.get(hostId: host.id, type: 'privateKey');

      if (password == null && privateKey == null) {
        setState(() {
          _isConnecting = false;
          _connectionError = '❌ 未找到登录凭据\n\n请重新编辑服务器，填写密码或私钥后保存。';
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
        throw Exception('连接失败，请检查网络和凭据');
      }

      // SSH 连接成功后设置 executor
      ref.read(agentProvider.notifier).setExecutor(tab.service);

      _switchToTab(tab);
      setState(() => _isConnecting = false);
    } catch (e) {
      setState(() {
        _isConnecting = false;
        final errorMsg = e.toString();
        String hint;
        if (errorMsg.contains('Connection refused')) {
          hint = '服务器拒绝连接，请检查 SSH 端口是否正确';
        } else if (errorMsg.contains('timeout') || errorMsg.contains('Timeout')) {
          hint = '连接超时，请检查网络或服务器是否可达';
        } else if (errorMsg.contains('authentication') || errorMsg.contains('Auth')) {
          hint = '认证失败，请检查用户名和密码/私钥是否正确';
        } else if (errorMsg.contains('No route to host')) {
          hint = '无法到达主机，请检查服务器地址是否正确';
        } else {
          hint = '请检查网络连接和服务器状态';
        }
        _connectionError = '$errorMsg\n\n💡 $hint';
      });
    }
  }

  /// 连接本地终端
  Future<void> _connectLocalTerminal() async {
    try {
      await ref.read(tp.terminalProvider.notifier).openLocalTab();

      final tab = ref.read(tp.terminalProvider).activeTab;
      if (tab == null) {
        setState(() => _connectionError = '本地终端启动失败');
        return;
      }

      // 本地终端连接成功后立即设置 executor，使 Agent 模式可用
      ref.read(agentProvider.notifier).setExecutor(tab.localService);

      _switchToTab(tab);
    } catch (e) {
      setState(() => _connectionError = '本地终端启动失败: $e');
    }
  }

  StreamSubscription<String> _setupTerminalListener(tp.TerminalTab tab) {
    final sub = tab.outputController.stream.listen((data) {
      if (_terminal != null) _terminal!.write(data);
    });
    _terminal?.onOutput = (data) {
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
    _lastResizeTab = tab;
    Timer(const Duration(milliseconds: 150), () {
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

  void _reconnect() {
    final tab = ref.read(tp.terminalProvider).activeTab;
    if (tab != null && tab.isLocal) {
      _connectLocalTerminal();
    } else {
      _connectToHost();
    }
  }

  void _showAddHostDialog() {
    // 弹出已保存服务器列表供选择（允许重复连接）
    final hosts = HiveInit.hostsBox.values.toList();
    if (hosts.isEmpty) {
      context.push('/host/edit');
      return;
    }

    final tc = ThemeColors.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(rLarge))),
      builder: (context) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.add_circle_outline, size: 16, color: cPrimary),
                  const SizedBox(width: 8),
                  Text('选择服务器新标签连接', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      this.context.push('/host/edit');
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: cPrimary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(rSmall),
                        border: Border.all(color: cPrimary.withOpacity(0.2)),
                      ),
                      child: Text('+ 新建', style: TextStyle(fontSize: fMicro, color: cPrimary, fontWeight: FontWeight.w500)),
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
                            ? tagColors.firstWhere((c) => c.value.toString() == host.tagColor, orElse: () => cPrimary)
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
    final password = await CredentialsStore.get(hostId: host.id, type: 'password');
    final privateKey = await CredentialsStore.get(hostId: host.id, type: 'privateKey');

    if (password == null && privateKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${host.name} 未配置凭据，请先编辑服务器'),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('连接 ${host.name} 失败: $e'),
          backgroundColor: cDanger,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
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
                  HiveInit.settingsBox.put('aiPanelVisible', true);
                }
              },
              child: terminalView,
            )
          : terminalView;
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
                        color: tc.textMuted.withOpacity(0.6),
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
                  color: tc.border.withOpacity(0.6),
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
              Expanded(child: terminalView),
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
                      HiveInit.settingsBox.put('aiPanelVisible', false);
                    }
                  },
                  child: SizedBox(height: aiPanelSize, child: aiContent),
                )
              : SizedBox(height: aiPanelSize, child: aiContent);

          return Column(
            children: [
              Expanded(child: terminalView),
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
                color: tc.border.withOpacity(0.6),
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
  Widget _buildTopBar(dynamic host, tp.TerminalState terminalState, tp.TerminalTab? activeTab) {
    final tc = ThemeColors.of(context);
    return Container(
      height: hAppBar,
      decoration: BoxDecoration(
        color: tc.card,
        border: Border(bottom: BorderSide(color: tc.border.withOpacity(0.6), width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 设置按钮（替代返回按钮）
          GestureDetector(
            onTap: () => context.push('/settings'),
            child: Container(
              margin: const EdgeInsets.only(left: 8),
              height: 32,
              width: 32,
              decoration: BoxDecoration(
                color: tc.surface,
                borderRadius: BorderRadius.circular(rSmall),
              ),
              child: Icon(Icons.settings, size: 14, color: tc.textSub),
            ),
          ),
          const SizedBox(width: 6),
          // Tab 列表（可横向滚动，含连接名称和关闭x）
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 2),
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
          const SizedBox(width: 6),
          // 连接状态
          _buildConnectionBadge(activeTab),
          const SizedBox(width: 6),
          // P0-1: AI 面板展开/收起按钮
          _buildAIPanelToggleButton(),
          const SizedBox(width: 6),
          // 终端设置按钮
          _buildTerminalSettingsButton(),
          const SizedBox(width: 4),
          // 菜单
          _buildToolbarMenu(),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// 单个 Tab 项（连接名称 + 关闭x）— 使用独立 widget 避免 hover 触发整页 rebuild
  Widget _buildTabItem(tp.TerminalTab tab, bool isActive, tp.TerminalState terminalState) {
    final tc = ThemeColors.of(context);
    return _TabItem(
      tab: tab,
      isActive: isActive,
      tc: tc,
      onTap: () {
        ref.read(tp.terminalProvider.notifier).setActiveTab(tab.id);
        _switchToTab(tab);
      },
      onClose: () async {
        ref.read(chatProvider.notifier).removeTab(tab.id);
        ref.read(agentProvider.notifier).removeTab(tab.id, hostId: tab.hostId);
        _tabAiInputText.remove(tab.id);
        _tabExecutingCommand.remove(tab.id);
        _tabExecutedCommands.remove(tab.id);
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
    return Tooltip(
      message: '新连接',
      child: GestureDetector(
        onTap: _showAddHostDialog,
        child: Container(
          width: 32,
          height: 32,
          margin: const EdgeInsets.only(left: 2, right: 2),
          decoration: BoxDecoration(
            color: tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: tc.border.withOpacity(0.3)),
          ),
          child: Icon(Icons.add, size: 14, color: tc.textSub),
        ),
      ),
    );
  }

  /// 终端设置按钮（字号、配色）
  Widget _buildTerminalSettingsButton() {
    final tc = ThemeColors.of(context);
    return PopupMenuButton<String>(
      icon: Icon(Icons.text_fields, color: tc.textSub, size: 18),
      color: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
      offset: const Offset(0, 40),
      onSelected: (value) {
        if (value.startsWith('font_')) {
          final size = double.parse(value.substring(5));
          setState(() => _terminalFontSize = size);
          HiveInit.settingsBox.put('terminalFontSize', size);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: Text('字号', style: TextStyle(fontSize: fMicro, color: cPrimary, fontWeight: FontWeight.w600)),
        ),
        ...[8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 18.0, 20.0, 22.0, 24.0].map((size) => PopupMenuItem<String>(
          value: 'font_$size',
          height: 28,
          child: Row(
            children: [
              if (_terminalFontSize == size)
                Icon(Icons.check, size: 12, color: cPrimary)
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (connected ? cSuccess : cDanger).withOpacity(0.1),
        borderRadius: BorderRadius.circular(rFull),
        border: Border.all(color: (connected ? cSuccess : cDanger).withOpacity(0.2)),
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
                BoxShadow(color: (connected ? cSuccess : cDanger).withOpacity(0.5), blurRadius: 4),
              ],
            ),
          ),
          const SizedBox(width: 5),
          Text(
            connected ? '已连接' : '离线',
            style: TextStyle(fontSize: fMicro, color: connected ? cSuccess : cDanger, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  /// P0-1: AI 面板展开/收起按钮
  Widget _buildAIPanelToggleButton() {
    final tc = ThemeColors.of(context);
    final accentColor = cAgentGreen;

    return Tooltip(
      message: _isAIPanelVisible ? '收起 AI 面板' : '展开 AI 面板',
      child: GestureDetector(
        onTap: () {
          setState(() {
            _isAIPanelVisible = !_isAIPanelVisible;
          });
          // 持久化状态
          HiveInit.settingsBox.put('aiPanelVisible', _isAIPanelVisible);
        },
        child: AnimatedContainer(
          duration: animFast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _isAIPanelVisible ? accentColor.withOpacity(0.15) : tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(
              color: _isAIPanelVisible ? accentColor.withOpacity(0.4) : tc.border.withOpacity(0.3),
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

  Widget _buildToolbarMenu() {
    final tc = ThemeColors.of(context);
    final snippets = HiveInit.snippetsBox.values.toList();
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_horiz, color: tc.textSub, size: 20),
      color: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rMedium)),
      offset: const Offset(0, 40),
      onSelected: (value) async {
        if (value.startsWith('snippet:')) {
          final snippetId = value.substring(8);
          final snippet = HiveInit.snippetsBox.get(snippetId);
          if (snippet != null) _executeSnippet(snippet);
          return;
        }
        switch (value) {
          case 'reconnect': await _connectToHost(); break;
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
        _menuItem('reconnect', Icons.refresh_rounded, '重连'),
        _menuItem('clear', Icons.cleaning_services_rounded, '清屏'),
        _menuItem('sftp', Icons.folder_outlined, 'SFTP'),
        // 快捷命令
        if (snippets.isNotEmpty) ...[
          const PopupMenuDivider(height: 8),
          PopupMenuItem<String>(
            enabled: false,
            height: 24,
            child: Text('快捷命令', style: TextStyle(fontSize: fMicro, color: cPrimary, fontWeight: FontWeight.w600)),
          ),
          ...snippets.take(5).map((s) => _menuItem('snippet:${s.id}', Icons.terminal, s.name)),
        ],
        const PopupMenuDivider(height: 8),
        _menuItem('prompt', Icons.edit_note_rounded, '自定义提示词'),
        _menuItem('builtInPrompt', Icons.description_outlined, '内置提示词'),
        _menuItem('maxsteps', Icons.auto_mode_rounded, '最大步骤数'),
        const PopupMenuDivider(height: 8),
        _menuItem('settings', Icons.settings_outlined, '设置'),
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 24, height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: cPrimary),
          ),
          const SizedBox(height: 12),
          Text('正在连接 ${host?.host}...', style: TextStyle(color: tc.textSub, fontSize: fBody)),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    final tc = ThemeColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 40, color: cDanger),
            const SizedBox(height: 12),
            Text('连接失败', style: TextStyle(color: tc.textSub, fontSize: fBody)),
            const SizedBox(height: 6),
            Text(_connectionError!, style: TextStyle(color: cDanger, fontSize: fSmall), textAlign: TextAlign.center),
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
                  child: Text('重试', style: TextStyle(fontSize: fBody)),
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
                  child: Text('返回', style: TextStyle(fontSize: fBody)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDisconnectedChip() {
    return GestureDetector(
      onTap: _reconnect,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: cDanger.withOpacity(0.15),
          borderRadius: BorderRadius.circular(rFull),
          border: Border.all(color: cDanger.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, color: cDanger, size: 12),
            const SizedBox(width: 4),
            Text('连接中断', style: TextStyle(color: cDanger, fontSize: fMicro, fontWeight: FontWeight.w500)),
            const SizedBox(width: 4),
            Text('重连', style: TextStyle(color: cDanger, fontSize: fMicro, fontWeight: FontWeight.w600, decoration: TextDecoration.underline)),
          ],
        ),
      ),
    );
  }

  // ==================== 区域分界线（分割条，位于终端和 AI 面板之间）====================
  Widget _buildAreaDivider(AgentState agentState) {
    final accentColor = cAgentGreen;
    final tc = ThemeColors.of(context);
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
              color: isActive ? accentColor.withOpacity(0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(3),
              border: isActive ? Border.all(color: accentColor.withOpacity(0.5), width: 1) : null,
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
            boxShadow: [BoxShadow(color: cWarning.withOpacity(0.5), blurRadius: 4)],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'AGENT',
          style: TextStyle(
            fontSize: fMicro,
            color: accentColor.withOpacity(0.8),
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );

    // P0-1: 收起按钮
    Widget closeButton() {
      return Tooltip(
        message: '收起 AI 面板',
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onTap: () {
            setState(() => _isAIPanelVisible = false);
            HiveInit.settingsBox.put('aiPanelVisible', false);
          },
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: accentColor.withOpacity(0.3), width: 1),
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
          border: Border(right: BorderSide(color: tc.border.withOpacity(0.4), width: 0.5)),
        ),
        child: Column(
          children: [
            if (showButtons) ...[
              const SizedBox(height: 4),
              closeButton(),
              const SizedBox(height: 4),
              RotatedBox(quarterTurns: 1, child: layoutButton(_AiPanelPosition.bottom, Icons.view_sidebar_outlined, '下')),
              const SizedBox(height: 2),
              layoutButton(_AiPanelPosition.right, Icons.view_sidebar_outlined, '右'),
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
                    colors: [accentColor.withOpacity(0.0), accentColor.withOpacity(0.7), accentColor.withOpacity(0.0)],
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
            bottom: BorderSide(color: tc.border.withOpacity(0.4), width: 0.5),
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
                    colors: [accentColor.withOpacity(0.6), accentColor.withOpacity(0.0)],
                  ),
                ),
              ),
            ),
            if (showButtons) ...[
              const SizedBox(width: 8),
              RotatedBox(quarterTurns: 1, child: layoutButton(_AiPanelPosition.bottom, Icons.view_sidebar_outlined, '下')),
              const SizedBox(width: 2),
              layoutButton(_AiPanelPosition.right, Icons.view_sidebar_outlined, '右'),
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
      ),
      child: Column(
        children: [
          // 状态条
          if (agentState.isRunning || agentState.isWaitingConfirm || agentState.isWaitingChoice) _buildAgentStatusBar(agentState),
          // 等待确认横幅（仅危险命令确认时显示）
          if (agentState.isWaitingConfirm) _buildConfirmBanner(agentState),
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
                            BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6),
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

  Widget _buildAgentStatusBar(AgentState agentState) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cAgentGreen.withOpacity(0.06),
        border: Border(bottom: BorderSide(color: cAgentGreen.withOpacity(0.1))),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 12, height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: cAgentGreen,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            agentState.statusText,
            style: TextStyle(fontSize: fSmall, color: cAgentGreen, fontWeight: FontWeight.w500),
          ),
          if (agentState.currentTask?.currentStep != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: cSurface,
                borderRadius: BorderRadius.circular(rXSmall),
              ),
              child: Text(
                _truncateCommand(agentState.currentTask!.currentStep!),
                style: TextStyle(fontSize: fMicro, color: ThemeColors.of(context).textSub, fontFamily: 'JetBrainsMono'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const Spacer(),
          GestureDetector(
            onTap: () => ref.read(agentProvider.notifier).cancel(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: cDanger.withOpacity(0.1),
                borderRadius: BorderRadius.circular(rSmall),
                border: Border.all(color: cDanger.withOpacity(0.2)),
              ),
              child: Text('停止', style: TextStyle(fontSize: fMicro, color: cDanger, fontWeight: FontWeight.w500)),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => _showAgentLogDialog(context),
            child: Icon(Icons.terminal, size: 14, color: ThemeColors.of(context).textSub),
          ),
        ],
      ),
    );
  }

  // ==================== 高风险命令确认横幅 ====================
  Widget _buildConfirmBanner(AgentState agentState) {
    final tc = ThemeColors.of(context);
    final command = agentState.pendingConfirmCommand ?? '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cWarning.withOpacity(0.08),
        border: Border(bottom: BorderSide(color: cWarning.withOpacity(0.3))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: cWarning, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '高风险命令待确认',
                  style: TextStyle(fontSize: fSmall, color: cWarning, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: tc.terminalBg,
              borderRadius: BorderRadius.circular(rSmall),
            ),
            child: SelectableText(
              command,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: fMono,
                color: cWarning,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // 拒绝按钮
              GestureDetector(
                onTap: () => ref.read(agentProvider.notifier).rejectCommand(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: tc.surface,
                    borderRadius: BorderRadius.circular(rSmall),
                    border: Border.all(color: tc.border),
                  ),
                  child: Text('拒绝', style: TextStyle(fontSize: fSmall, color: tc.textSub, fontWeight: FontWeight.w500)),
                ),
              ),
              const SizedBox(width: 8),
              // 确认执行按钮
              GestureDetector(
                onTap: () => ref.read(agentProvider.notifier).confirmCommand(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: cWarning.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(rSmall),
                    border: Border.all(color: cWarning.withOpacity(0.4)),
                  ),
                  child: Text('确认执行', style: TextStyle(fontSize: fSmall, color: cWarning, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==================== Agent 模式统一消息列表 ====================
  Widget _buildAgentChatList(AgentState agentState, tp.TerminalTab? tab) {
    final items = agentState.chatItems;
    if (items.isEmpty) {
      return Center(child: Text('输入需求开始自动执行...', style: TextStyle(color: ThemeColors.of(context).textMuted, fontSize: fBody)));
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
        );
      },
    );
  }

  Widget _buildChatMessageList(ChatState chatState, tp.TerminalTab? tab) {
    return ListView.builder(
      controller: _chatScrollController,
      padding: const EdgeInsets.all(8),
      itemCount: chatState.messages.length + (chatState.currentAssistantMessage != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (chatState.currentAssistantMessage != null && index == chatState.messages.length) {
          return _buildMessageBubble(
            key: const ValueKey('chat_current_assistant'),
            role: 'assistant',
            content: chatState.currentAssistantMessage!,
            isLoading: true,
          );
        }
        final message = chatState.messages[index];
        return _buildMessageBubble(
          key: ValueKey('chat_${message.role}_$index'),
          role: message.role,
          content: message.content,
          isLoading: false,
          tab: tab,
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
  }) {
    final isUser = role == 'user';
    final tc = ThemeColors.of(context);

    return Align(
      key: key,
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isUser
              ? cPrimary.withOpacity(0.2)
              : tc.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(rMedium),
            topRight: const Radius.circular(rMedium),
            bottomLeft: Radius.circular(isUser ? rMedium : rXSmall),
            bottomRight: Radius.circular(isUser ? rXSmall : rMedium),
          ),
          border: Border.all(
            color: isUser
                ? cPrimary.withOpacity(0.3)
                : tc.border.withOpacity(0.3),
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
                          ? [cPrimary.withOpacity(0.18), cPrimary.withOpacity(0.08)]
                          : [cAgentGreen.withOpacity(0.18), cAgentGreen.withOpacity(0.06)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(rXSmall),
                    border: Border.all(
                      color: (isUser ? cPrimary : cAgentGreen).withOpacity(0.2),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isUser ? Icons.person_outline : Icons.auto_awesome,
                        size: 11,
                        color: isUser ? cPrimary : cAgentGreen,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isUser ? '你' : 'AI 助手',
                        style: TextStyle(
                          fontSize: fMicro,
                          color: isUser ? cPrimary : cAgentGreen,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      if (isLoading) ...[
                        const SizedBox(width: 6),
                        SizedBox(width: 9, height: 9, child: CircularProgressIndicator(strokeWidth: 1.5, color: isUser ? cPrimary : cAgentGreen)),
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
              _buildAIContent(content, tc, tab, showAutoExecute, isLoading, isAgentRunning, isWaitingChoice, pendingOptions: pendingOptions, events: events, streamingContent: streamingContent),
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
  }) {
    // 优先使用结构化事件渲染（ReAct 格式已由 ReActStreamParser 正确解析）
    if (events.isNotEmpty) {
      // 判断 events 中是否有 AI 输出的内容事件（thought/command/text/ask/finish）
      // 如果只有 result/info，说明还在流式过程中，需要同时显示 streamingContent
      final hasAIContentEvents = events.any((e) =>
          e.isThought || e.isCommand || e.isText || e.isAsk || e.isFinish);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildEventsContent(events, tc, tab, showAutoExecute, isLoading, isWaitingChoice, pendingOptions),
          // 只有在还没有 AI 内容事件时（流式过程中，只有 result/info），才显示流式纯文本
          if (!hasAIContentEvents && streamingContent.trim().isNotEmpty)
            _buildMarkdownText(streamingContent, tc),
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
              return _buildCodeBlockWithExecuteButton(seg.content, tc, tab, showAutoExecute, isLoading);
            } else {
              return _buildPlainCodeBlock(seg.content, tc);
            }
          } else {
            if (seg.content.trim().isEmpty) return const SizedBox.shrink();
            return _buildMarkdownText(seg.content, tc);
          }
        }),
        if (isWaitingChoice && pendingOptions.isNotEmpty)
          _buildOptionButtons(pendingOptions, tc, false),
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
          listBullet: TextStyle(color: cPrimary, fontSize: fBody),
          blockquote: TextStyle(color: tc.textSub, fontStyle: FontStyle.italic),
          blockquoteDecoration: BoxDecoration(
            border: Border(left: BorderSide(color: cPrimary, width: 2)),
          ),
          blockquotePadding: const EdgeInsets.only(left: 8),
        ),
        onTapLink: (text, href, title) {},
      ),
    );
  }

  /// 统一命令块：左侧三角形执行按钮 + 命令文本 + 右侧复制按钮
  Widget _buildCommandBlock(
    String command,
    ThemeColors tc,
    tp.TerminalTab? tab,
    bool showAutoExecute,
    bool isLoading, {
    bool indent = false,
  }) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    final canExecute = tab != null && tab.isConnected && showAutoExecute;
    final safetyLevel = SafetyGuard.check(trimmed);
    final hasChain = hasChainOperator(trimmed);
    final dangerous = hasChain || safetyLevel != SafetyLevel.safe;
    final isBlocked = safetyLevel == SafetyLevel.blocked;

    final cmdColor = isBlocked
        ? cDanger
        : dangerous
            ? cWarning
            : tc.terminalGreen;

    final accentColor = isBlocked ? cDanger : dangerous ? cWarning : tc.terminalGreen;

    final block = Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: tc.terminalBg,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // 顶部栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: tc.surface,
              border: Border(bottom: BorderSide(color: tc.border, width: 0.5)),
            ),
            child: Row(
              children: [
                // 红黄绿三个小圆点
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF5F56),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 5),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFBD2E),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 5),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: const Color(0xFF27C93F),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  isBlocked ? '已拦截' : dangerous ? '需确认' : '可执行',
                  style: TextStyle(
                    fontSize: fMicro,
                    color: accentColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                // 复制按钮
                _buildCopyButton(trimmed, tc),
                const SizedBox(width: 4),
                // 执行按钮
                if (canExecute && !isLoading && !isBlocked)
                  _buildExecuteButton(trimmed, dangerous, isBlocked, tc, tab)
                else if (isBlocked)
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    child: Icon(Icons.block, size: 13, color: cDanger),
                  ),
              ],
            ),
          ),
          // 命令内容
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // $ 提示符
                Text(
                  '\$ ',
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: fMono,
                    color: accentColor,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                // 命令文本
                Expanded(
                  child: SelectableText(
                    trimmed,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: fMono,
                      color: cmdColor,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (!indent) return block;

    // 缩进 + 左侧连接线表示从属
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.5),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(2),
                    bottomRight: Radius.circular(2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(child: block),
        ],
      ),
    );
  }

  /// 复制按钮
  Widget _buildCopyButton(String text, ThemeColors tc) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('已复制', style: TextStyle(fontSize: fSmall)),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
          ),
        );
      },
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        child: Icon(Icons.copy, size: 13, color: tc.textMuted),
      ),
    );
  }

  /// 结构化事件列表渲染：内容自动追加，只有命令单独包装成块
  ///
  /// 渲染规则：
  /// - thought/text/info：合并为连续 Markdown 文本自动追加显示
  /// - command：单独命令块（执行按钮 + 复制按钮）
  /// - result：紧跟对应 command 后，用缩进+连接线表示从属
  /// - ask：问题文本 + 横向选项按钮组
  /// - finish：完成横幅
  Widget _buildEventsContent(
    List<AgentEvent> events,
    ThemeColors tc,
    tp.TerminalTab? tab,
    bool showAutoExecute,
    bool isLoading,
    bool isWaitingChoice,
    List<String> pendingOptions,
  ) {
    // 构建事件→结果配对映射：commandId → result
    final resultMap = <String, AgentEvent>{};
    for (final e in events) {
      if (e.isResult && e.commandId != null) {
        resultMap[e.commandId!] = e;
      }
    }

    final widgets = <Widget>[];
    final textBuffer = StringBuffer();

    void flushText() {
      final text = textBuffer.toString().trim();
      if (text.isNotEmpty) {
        widgets.add(_buildMarkdownText(text, tc));
        textBuffer.clear();
      }
    }

    for (final event in events) {
      switch (event.type) {
        case AgentEventType.thought:
        case AgentEventType.text:
        case AgentEventType.info:
          if (event.text != null && event.text!.trim().isNotEmpty) {
            textBuffer.writeln(event.text);
          }
          break;
        case AgentEventType.command:
          flushText();
          widgets.add(_buildCommandBlock(
            event.command ?? '',
            tc,
            tab,
            showAutoExecute,
            isLoading,
          ));
          // 若有对应 result，紧跟在 command 后渲染
          final result = resultMap[event.id];
          if (result != null) {
            widgets.add(_buildResultCard(result, tc, indent: true));
          }
          break;
        case AgentEventType.result:
          if (event.commandId == null || !events.any((e) => e.id == event.commandId)) {
            flushText();
            widgets.add(_buildResultCard(event, tc, indent: false));
          }
          break;
        case AgentEventType.ask:
          flushText();
          widgets.add(_buildAskCard(event, tc, isWaitingChoice));
          break;
        case AgentEventType.finish:
          flushText();
          widgets.add(_buildFinishCard(event, tc));
          break;
      }
    }
    flushText();

    // 兜底：若有 pendingOptions 但没有 ask 事件（旧格式），显示选项按钮
    if (isWaitingChoice && pendingOptions.isNotEmpty && !events.any((e) => e.isAsk)) {
      widgets.add(_buildOptionButtons(pendingOptions, tc, false));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  /// 结果卡片：成功/失败状态 + 输出（全部展开显示）
  /// [indent] 为 true 时用左侧缩进+连接线表示从属于上方命令
  Widget _buildResultCard(AgentEvent event, ThemeColors tc, {required bool indent}) {
    final success = event.success ?? false;
    final output = event.output ?? event.error ?? '(无输出)';
    final lines = output.split('\n');

    final statusColor = success ? cSuccess : cDanger;
    final statusBg = success ? cSuccess.withOpacity(0.08) : cDanger.withOpacity(0.08);
    final statusIcon = success ? Icons.check_circle : Icons.error_rounded;
    final statusText = success ? '执行成功' : '执行失败';

    final card = Container(
      margin: const EdgeInsets.only(bottom: 8, top: 2),
      decoration: BoxDecoration(
        color: tc.surface,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 状态条
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: statusBg,
              border: Border(bottom: BorderSide(color: tc.border, width: 0.5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(statusIcon, size: 10, color: statusColor),
                ),
                const SizedBox(width: 6),
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: fMicro,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: tc.textMuted.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${lines.length} 行',
                    style: TextStyle(color: tc.textMuted, fontSize: fMicro, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
          // 输出区 - 全部展开显示
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: SelectableText(
              output.trimRight(),
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: fMono,
                color: tc.textSub,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );

    if (!indent) return card;

    // 缩进 + 左侧连接线表示从属
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 3,
                height: 12,
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.4),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(2),
                    bottomRight: Radius.circular(2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(child: card),
        ],
      ),
    );
  }

  /// 询问卡片：问题 + 选项按钮
  Widget _buildAskCard(AgentEvent event, ThemeColors tc, bool isWaitingChoice) {
    final options = event.options ?? [];
    final question = event.question ?? '请选择';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cWarning.withOpacity(0.05),
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: cWarning.withOpacity(0.15)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: cWarning.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.help_outline, size: 13, color: cWarning),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  question,
                  style: TextStyle(color: tc.textMain, fontSize: fBody, height: 1.5, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          if (options.isNotEmpty && isWaitingChoice) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: options.map((opt) {
                return _buildOptionChip(opt, tc);
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionChip(String label, ThemeColors tc) {
    return GestureDetector(
      onTap: () {
        final notifier = ref.read(agentProvider.notifier);
        notifier.selectChoice(label);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: tc.surface,
          borderRadius: BorderRadius.circular(rMedium),
          border: Border.all(color: cWarning.withOpacity(0.3)),
          boxShadow: [
            BoxShadow(
              color: cWarning.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app, size: 12, color: cWarning),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: fSmall,
                color: cWarning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 任务完成卡片
  Widget _buildFinishCard(AgentEvent event, ThemeColors tc) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            cSuccess.withOpacity(0.12),
            cSuccess.withOpacity(0.04),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: cSuccess.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: cSuccess.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: cSuccess.withOpacity(0.2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.celebration, size: 15, color: cSuccess),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '任务完成',
                  style: TextStyle(
                    color: cSuccess,
                    fontSize: fSmall,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  event.summary ?? '已完成所有步骤',
                  style: TextStyle(color: cSuccess.withOpacity(0.85), fontSize: fBody, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
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

  /// 纯文本代码块（无执行/复制按钮），用于命令输出等非可执行内容
  Widget _buildPlainCodeBlock(String codeBlock, ThemeColors tc) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tc.terminalBg,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border),
      ),
      child: SelectableText(
        codeBlock.trimRight(),
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: fMono,
          color: tc.textSub,
          height: 1.4,
        ),
      ),
    );
  }

  /// 选项按钮组 — AI 输出 :::choose A|B|C::: 后渲染为可点击选项
  Widget _buildOptionButtons(List<String> options, ThemeColors tc, bool disabled) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: options.asMap().entries.map((entry) {
          final index = entry.key;
          final option = entry.value;
          final isPrimary = index == 0; // 第一个选项用主色高亮
          final color = isPrimary ? cPrimary : tc.textMain;
          final bgColor = isPrimary
              ? cPrimary.withOpacity(disabled ? 0.1 : 0.15)
              : tc.border.withOpacity(disabled ? 0.3 : 0.6);

          return GestureDetector(
            onTap: disabled ? null : () => _onOptionSelected(option),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(rSmall),
                border: Border.all(
                  color: color.withOpacity(disabled ? 0.2 : 0.4),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isPrimary) ...[
                    Icon(Icons.check_circle_outline, size: 14, color: color.withOpacity(disabled ? 0.4 : 1)),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    option,
                    style: TextStyle(
                      fontSize: fSmall,
                      color: color.withOpacity(disabled ? 0.4 : 1),
                      fontWeight: isPrimary ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
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

  /// 带执行按钮的代码块 — 每条命令独立成块，复用统一命令块样式
  Widget _buildCodeBlockWithExecuteButton(String codeBlock, ThemeColors tc, tp.TerminalTab? tab, bool showAutoExecute, bool isLoading) {
    final lines = codeBlock.trimRight().split('\n');
    final children = <Widget>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      children.add(_buildCommandBlock(trimmed, tc, tab, showAutoExecute, isLoading));
    }

    if (children.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  /// 命令执行按钮（带背景色的三角形按钮）
  Widget _buildExecuteButton(String command, bool dangerous, bool isBlocked, ThemeColors tc, tp.TerminalTab tab) {
    final isExecuting = _executingCommand == command;
    final hasAnyExecuting = _executingCommand != null;
    final isDisabled = isBlocked || (hasAnyExecuting && !isExecuting);

    final color = isBlocked
        ? cDanger
        : dangerous
            ? cWarning
            : cPrimary;

    return GestureDetector(
      onTap: isDisabled ? null : () => _executeLineDirectly(command, dangerous, tab),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isDisabled ? Colors.transparent : color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(rSmall),
          border: isDisabled ? null : Border.all(color: color.withOpacity(0.35)),
        ),
        child: isExecuting
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
              )
            : isBlocked
                ? Icon(Icons.block, size: 14, color: cDanger)
                : Icon(Icons.play_arrow, size: 18, color: color),
      ),
    );
  }

  /// 直接执行命令行
  Future<void> _executeLineDirectly(String command, bool dangerous, tp.TerminalTab tab) async {
    // 危险/复杂命令需确认
    if (dangerous) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: ThemeColors.of(context).cardElevated,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
          title: Text('确认执行', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('⚠️ 此命令较为复杂，建议确认后执行：', style: TextStyle(color: cWarning, fontSize: fSmall)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: ThemeColors.of(context).terminalBg,
                  borderRadius: BorderRadius.circular(rSmall),
                ),
                child: SelectableText(
                  command,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: fMono, color: cTerminalGreen),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('取消', style: TextStyle(color: cTextSub, fontSize: fBody)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
              child: Text('执行', style: TextStyle(fontSize: fBody)),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

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
    final cmd = command.trim().toLowerCase();
    switch (cmd) {
      case '/new':
        _autoScrollChat = true;
        ref.read(agentProvider.notifier).newSession();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('已新建会话', style: TextStyle(fontSize: 13)),
            duration: const Duration(seconds: 1),
          ),
        );
        return true;
      case '/compact':
        if (!isConnected) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('请先连接终端', style: TextStyle(fontSize: 13)),
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
              content: const Text('记忆压缩完成', style: TextStyle(fontSize: 13)),
              duration: const Duration(seconds: 1),
            ),
          );
        }).catchError((e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('压缩失败: $e', style: const TextStyle(fontSize: 13)),
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
    final models = HiveInit.aiModelsBox.values.toList();
    final tc = ThemeColors.of(context);

    return Container(
      padding: EdgeInsets.only(
        left: 8, right: 8, top: 4,
        bottom: 4 + (_isMobile ? MediaQuery.of(context).padding.bottom : 0),
      ),
      decoration: BoxDecoration(
        color: tc.card,
        border: Border(top: BorderSide(color: tc.border.withOpacity(0.5))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 上方一行：功能按钮
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Agent 模式指示
              Container(
                height: 26,
                width: 26,
                decoration: BoxDecoration(
                  color: cAgentGreen.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(rSmall),
                ),
                child: Icon(
                  Icons.smart_toy,
                  color: cAgentGreen,
                  size: 12,
                ),
              ),
              const SizedBox(width: 4),
              // Agent 标签
              Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: cAgentGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(rXSmall),
                  border: Border.all(color: cAgentGreen.withOpacity(0.3)),
                ),
                child: Center(
                  child: Text(
                    'Agent',
                    style: TextStyle(
                      fontSize: fSmall,
                      color: cAgentGreen,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Agent 日志按钮
              GestureDetector(
                onTap: () => _showAgentLogDialog(context),
                child: Container(
                  height: 26,
                  width: 26,
                  decoration: BoxDecoration(
                    color: tc.surface,
                    borderRadius: BorderRadius.circular(rSmall),
                  ),
                  child: Icon(Icons.terminal, size: 12, color: tc.textSub),
                ),
              ),
              const SizedBox(width: 4),
              // 会话历史按钮
              GestureDetector(
                onTap: () => _showSessionHistoryPanel(context),
                child: Container(
                  height: 26,
                  width: 26,
                  decoration: BoxDecoration(
                    color: tc.surface,
                    borderRadius: BorderRadius.circular(rSmall),
                  ),
                  child: Icon(Icons.history, size: 12, color: tc.textSub),
                ),
              ),
              const Spacer(),
              // 运行状态指示
              if (agentState.isRunning)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: cAgentGreen.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(rXSmall),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 10, height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: cAgentGreen),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        agentState.statusText,
                        style: TextStyle(fontSize: fMicro, color: cAgentGreen, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              if (agentState.isRunning)
                const SizedBox(width: 4),
              // 模型选择（贴右）
              if (models.isNotEmpty)
                _buildModelSelector(models, tc),
            ],
          ),
          const SizedBox(height: 4),
          // 下方一行：输入框
          _AIPromptInput(
              enabled: isConnected && !agentState.isRunning,
              hintText: _getInputHint(isConnected, agentState.isRunning),
              initialText: _tabAiInputText[_currentTabId ?? ''] ?? '',
              accentColor: cAgentGreen,
              onFocusChanged: (focused) {
                setState(() => _aiInputFocused = focused);
              },
              onChanged: (text) { _tabAiInputText[_currentTabId ?? ''] = text; },
              onSlashCommand: (command) {
                return _handleSlashCommand(command, isConnected: isConnected);
              },
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
                  ref.read(agentProvider.notifier).setExecutor(executor);
                  await ref.read(agentProvider.notifier).startTask(text);
                }
              },
            ),
        ],
      ),
    );
  }

  /// 模型选择器 - 紧凑按钮
  Widget _buildModelSelector(List<AIModelConfig> models, ThemeColors tc) {
    return PopupMenuButton<String>(
      onSelected: (modelId) {
        final model = models.firstWhere((m) => m.id == modelId);
        _switchModel(model);
      },
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: tc.surface,
          borderRadius: BorderRadius.circular(rSmall),
          border: Border.all(color: tc.border.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined, size: 12, color: tc.textMuted),
            const SizedBox(width: 3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 80),
              child: Text(
                _currentModelConfig?.name ?? '模型',
                style: TextStyle(fontSize: fSmall, color: tc.textSub, height: 1.0),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.unfold_more, size: 10, color: tc.textMuted),
          ],
        ),
      ),
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
    );
  }

  // ==================== 快捷按键行 ====================
  Widget _buildQuickKeysBar(tp.TerminalTab? activeTab) {
    final tc = ThemeColors.of(context);
    final isConnected = activeTab?.isConnected == true;

    // 高频组合键（始终显示）
    final coreKeys = [
      _QuickKey('ESC', '\x1b'),
      _QuickKey('Tab', '\t'),
      _QuickKey('⌃C', '\x03'),
      _QuickKey('⌃D', '\x04'),
      _QuickKey('⌃Z', '\x1a'),
      _QuickKey('⌃L', '\x0c'),
    ];
    // readline 快捷键
    final readlineKeys = [
      _QuickKey('⌃A', '\x01'),
      _QuickKey('⌃E', '\x05'),
      _QuickKey('⌃U', '\x15'),  // 删除行首到光标
      _QuickKey('⌃K', '\x0b'),  // 删除光标到行尾
      _QuickKey('⌃W', '\x17'),  // 删除前一个单词
      _QuickKey('⌃R', '\x12'),  // 搜索历史命令
    ];
    // 方向 + 导航键
    final navKeys = [
      _QuickKey('↑', '\x1b[A'),
      _QuickKey('↓', '\x1b[B'),
      _QuickKey('←', '\x1b[D'),
      _QuickKey('→', '\x1b[C'),
      _QuickKey('Home', '\x1b[H'),
      _QuickKey('End', '\x1b[F'),
      _QuickKey('PgUp', '\x1b[5~'),
      _QuickKey('PgDn', '\x1b[6~'),
    ];
    final keys = [...coreKeys, ...readlineKeys, ...navKeys];
    // 分组索引：高频键用主色高亮
    final coreCount = coreKeys.length;

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: tc.card,
        border: Border(top: BorderSide(color: tc.border.withOpacity(0.3))),
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
              color: tc.border.withOpacity(0.4),
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
                    ? cPrimary.withOpacity(isConnected ? 0.12 : 0.05)
                    : isNav
                        ? cSuccess.withOpacity(isConnected ? 0.08 : 0.03)
                        : tc.surface,
                borderRadius: BorderRadius.circular(rXSmall),
                border: Border.all(
                  color: isCore
                      ? cPrimary.withOpacity(isConnected ? 0.3 : 0.1)
                      : isNav
                          ? cSuccess.withOpacity(isConnected ? 0.2 : 0.05)
                          : tc.border.withOpacity(0.3),
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
  String _getInputHint(bool isConnected, bool isRunning) {
    if (isRunning) return 'Agent 执行中...';
    if (!isConnected) return '连接终端后可用';
    return '描述需求，Agent 自动执行...';
  }

  bool _checkAIModelConfigured() {
    try {
      return HiveInit.aiModelsBox.values.isNotEmpty;
    } catch (_) { return false; }
  }

  void _showAIModelNotConfiguredHint() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text('请先配置 AI 模型', style: TextStyle(fontSize: fBody)),
          ],
        ),
        backgroundColor: cWarning,
        action: SnackBarAction(
          label: '配置',
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
        color: cDanger.withOpacity(0.08),
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: cDanger.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: cDanger, size: 14),
          const SizedBox(width: 6),
          Expanded(child: Text(error, style: TextStyle(color: cDanger, fontSize: fSmall), maxLines: 2, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  String _truncateCommand(String command) {
    if (command.length <= 40) return command;
    return '${command.substring(0, 40)}...';
  }

  void _showAgentLogDialog(BuildContext context) {
    showDialog(context: context, builder: (context) => _AgentLogDialog());
  }

  /// 显示会话历史面板（侧边抽屉式）
  void _showSessionHistoryPanel(BuildContext context) {
    showDialog(context: context, builder: (context) => const _SessionHistoryDialog());
  }

  /// 显示最大步骤数设置
  void _showMaxStepsDialog() {
    final controller = TextEditingController(text: ref.read(agentProvider).maxSteps.toString());
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('最大执行步骤数', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Agent 自动模式下的最大执行步骤数。设为 0 表示无限制，复杂任务不会被中断。', style: TextStyle(color: cTextSub, fontSize: fSmall)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: TextStyle(color: cTextMain, fontSize: fBody),
              decoration: InputDecoration(
                labelText: '步骤数 (0 = 无限制)',
                labelStyle: TextStyle(color: cTextSub),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: cBorder)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消', style: TextStyle(color: cTextSub)),
          ),
          ElevatedButton(
            onPressed: () {
              final steps = int.tryParse(controller.text) ?? 0;
              final clamped = steps.clamp(0, 999);
              ref.read(agentProvider.notifier).setMaxSteps(clamped);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('最大步骤数已设为 ${clamped == 0 ? "无限制" : clamped}'),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
            child: Text('确定'),
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
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        title: Text(snippet.name, style: TextStyle(color: ThemeColors.of(context).textMain)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('命令: ${snippet.command}', style: TextStyle(color: cTextSub, fontSize: fSmall, fontFamily: 'JetBrainsMono')),
            const SizedBox(height: 12),
            ...variables.map((v) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: controllers[v],
                style: TextStyle(color: cTextMain, fontSize: fBody),
                decoration: InputDecoration(
                  labelText: '{{$v}}',
                  labelStyle: TextStyle(color: cTextSub),
                  filled: true,
                  fillColor: cSurface,
                ),
              ),
            )),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: cTextSub))),
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
            child: Text('执行'),
          ),
        ],
      ),
    );
  }

  /// 显示自定义提示词设置
  void _showCustomPromptDialog() {
    String? savedPrompt;
    try {
      savedPrompt = HiveInit.settingsBox.get('customSystemPrompt') as String?;
    } catch (_) {}
    final controller = TextEditingController(text: savedPrompt ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('自定义 AI 提示词', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: SizedBox(
          width: MediaQuery.of(context).size.width * 0.75,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('追加到 AI 系统提示词末尾的自定义指令，可用于调整 AI 行为风格、输出偏好等。留空则不追加。', style: TextStyle(color: cTextSub, fontSize: fSmall)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 5,
                minLines: 2,
                style: TextStyle(color: cTextMain, fontSize: fBody),
                decoration: InputDecoration(
                  hintText: '例如：回答使用英文、输出简洁格式、优先使用 Docker...',
                  hintStyle: TextStyle(color: cTextMuted, fontSize: fSmall),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: cBorder)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消', style: TextStyle(color: cTextSub)),
          ),
          ElevatedButton(
            onPressed: () {
              try {
                HiveInit.settingsBox.put('customSystemPrompt', controller.text.trim());
              } catch (_) {}
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('自定义提示词已保存'),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
            child: Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 显示内置系统提示词编辑
  void _showBuiltInPromptDialog() {
    final currentPrompt = prompts.getSystemPrompt();
    final controller = TextEditingController(text: currentPrompt);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('内置系统提示词', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: SizedBox(
          width: MediaQuery.of(ctx).size.width * 0.85,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('AI 的核心系统提示词，修改后立即生效。包含 {context} 的位置会被替换为服务器信息。', style: TextStyle(color: cTextSub, fontSize: fSmall)),
              const SizedBox(height: 6),
              Text('⚠️ 修改需谨慎，可随时"重置默认"。', style: TextStyle(color: cWarning, fontSize: fMicro)),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                maxLines: 10,
                minLines: 5,
                style: TextStyle(color: cTextMain, fontSize: fSmall, fontFamily: 'JetBrainsMono'),
                decoration: InputDecoration(
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: cBorder)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => controller.text = prompts.defaultSystemPrompt,
            child: Text('重置默认', style: TextStyle(color: cWarning)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: cTextSub)),
          ),
          ElevatedButton(
            onPressed: () {
              prompts.saveSystemPrompt(controller.text.trim());
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('内置提示词已保存'),
                  duration: const Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
            child: Text('保存'),
          ),
        ],
      ),
    );
  }
}

// ==================== AI 输入框 ====================
class _AIPromptInput extends StatefulWidget {
  final bool enabled;
  final String hintText;
  final String initialText;
  final Function(String) onSend;
  final ValueChanged<String>? onChanged;
  final ValueChanged<bool>? onFocusChanged;
  final Color accentColor;
  /// 斜杠命令回调：返回 true 表示命令已被处理（不再走 onSend）
  final bool Function(String command)? onSlashCommand;

  const _AIPromptInput({
    super.key,
    required this.enabled,
    required this.hintText,
    this.initialText = '',
    required this.onSend,
    this.onChanged,
    this.onFocusChanged,
    required this.accentColor,
    this.onSlashCommand,
  });

  @override
  State<_AIPromptInput> createState() => _AIPromptInputState();
}

/// 斜杠命令定义
class _SlashCommand {
  final String command;
  final String description;
  const _SlashCommand(this.command, this.description);
}

const List<_SlashCommand> _kSlashCommands = [
  _SlashCommand('/new', '新建会话'),
  _SlashCommand('/compact', '压缩记忆（总结早期对话）'),
];

class _AIPromptInputState extends State<_AIPromptInput> {
  late TextEditingController _controller;
  final _focusNode = FocusNode();
  String _lastInitialText = '';
  bool _isFocused = false;
  OverlayEntry? _slashOverlay;
  List<_SlashCommand> _filteredCommands = [];
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _lastInitialText = widget.initialText;
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(() {
      final focused = _focusNode.hasFocus;
      if (focused != _isFocused) {
        setState(() => _isFocused = focused);
        widget.onFocusChanged?.call(focused);
      }
      if (!focused) {
        _hideSlashOverlay();
      }
    });
  }

  void _onTextChanged() {
    widget.onChanged?.call(_controller.text);
    _detectSlashCommand();
  }

  /// 检测输入框中的斜杠命令前缀，显示建议
  void _detectSlashCommand() {
    final text = _controller.text;
    // 仅当文本以 / 开头且不含空格时显示建议
    if (text.startsWith('/') && !text.contains(' ')) {
      final prefix = text.toLowerCase();
      final filtered = _kSlashCommands
          .where((c) => c.command.toLowerCase().startsWith(prefix))
          .toList();
      if (filtered.isNotEmpty) {
        _filteredCommands = filtered;
        _highlightedIndex = _highlightedIndex.clamp(0, filtered.length - 1);
        _showSlashOverlay();
        return;
      }
    }
    _hideSlashOverlay();
  }

  void _showSlashOverlay() {
    if (_slashOverlay == null) {
      _slashOverlay = OverlayEntry(builder: _buildSlashOverlay);
      Overlay.of(context).insert(_slashOverlay!);
    } else {
      _slashOverlay!.markNeedsBuild();
    }
  }

  void _hideSlashOverlay() {
    _slashOverlay?.remove();
    _slashOverlay = null;
  }

  Widget _buildSlashOverlay(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return const SizedBox.shrink();
    final size = renderBox.size;
    final tc = ThemeColors.of(context);
    return Positioned(
      bottom: size.height + 4,
      left: 0,
      width: size.width,
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: tc.cardElevated,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: tc.border.withOpacity(0.5)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < _filteredCommands.length; i++)
                InkWell(
                  onTap: () => _selectSlashCommand(_filteredCommands[i]),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    color: i == _highlightedIndex ? widget.accentColor.withOpacity(0.15) : Colors.transparent,
                    child: Row(
                      children: [
                        Text(
                          _filteredCommands[i].command,
                          style: TextStyle(
                            color: i == _highlightedIndex ? widget.accentColor : tc.textMain,
                            fontSize: fSmall,
                            fontFamily: 'JetBrainsMono',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _filteredCommands[i].description,
                            style: TextStyle(color: tc.textSub, fontSize: fMicro),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectSlashCommand(_SlashCommand cmd) {
    _controller.text = cmd.command;
    _controller.selection = TextSelection.collapsed(offset: cmd.command.length);
    _hideSlashOverlay();
  }

  /// 键盘导航：上/下选择，Enter 执行，Esc 关闭
  void _handleKeyEvent(KeyEvent event) {
    if (_slashOverlay == null || _filteredCommands.isEmpty) return;
    if (event is! KeyDownEvent) return;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _highlightedIndex = (_highlightedIndex + 1) % _filteredCommands.length;
      });
      _slashOverlay!.markNeedsBuild();
      return;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlightedIndex = (_highlightedIndex - 1 + _filteredCommands.length) % _filteredCommands.length;
      });
      _slashOverlay!.markNeedsBuild();
      return;
    }
    if (key == LogicalKeyboardKey.tab) {
      _selectSlashCommand(_filteredCommands[_highlightedIndex]);
      return;
    }
    if (key == LogicalKeyboardKey.escape) {
      _hideSlashOverlay();
      return;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      // 若有高亮的斜杠命令建议，则执行该命令
      final cmd = _filteredCommands[_highlightedIndex];
      _controller.clear();
      _hideSlashOverlay();
      _executeSlashCommand(cmd);
      return;
    }
  }

  void _executeSlashCommand(_SlashCommand cmd) {
    final handled = widget.onSlashCommand?.call(cmd.command) ?? false;
    if (handled) return;
    // 默认行为：作为普通文本发送
    widget.onSend(cmd.command);
  }

  @override
  void didUpdateWidget(covariant _AIPromptInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialText != _lastInitialText && widget.initialText != _controller.text) {
      _controller.text = widget.initialText;
      _lastInitialText = widget.initialText;
    }
  }

  @override
  void dispose() {
    _hideSlashOverlay();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled) return;
    // 若是斜杠命令，优先走 onSlashCommand
    if (text.startsWith('/') && widget.onSlashCommand != null) {
      final handled = widget.onSlashCommand!(text);
      if (handled) {
        _controller.clear();
        return;
      }
    }
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final borderColor = _isFocused
        ? widget.accentColor.withOpacity(0.7)
        : widget.accentColor.withOpacity(0.4);
    final disabledBorderColor = tc.border.withOpacity(0.3);
    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: TextField(
        controller: _controller,
        enabled: widget.enabled,
        maxLines: 1,
        style: TextStyle(color: tc.textMain, fontSize: fSmall),
        decoration: InputDecoration(
          hintText: widget.hintText,
          hintStyle: TextStyle(color: tc.textMuted, fontSize: fSmall),
          filled: true,
          fillColor: tc.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: borderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: borderColor, width: 1.5),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(rSmall),
            borderSide: BorderSide(color: disabledBorderColor),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          isDense: true,
          suffixIcon: IconButton(
            icon: Icon(Icons.send_rounded, color: widget.enabled ? widget.accentColor : cTextMuted, size: 14),
            onPressed: _send,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ),
        onSubmitted: (_) => _send(),
      ),
    );
  }
}

// ==================== 会话历史对话框 ====================
class _SessionHistoryDialog extends ConsumerStatefulWidget {
  const _SessionHistoryDialog();

  @override
  ConsumerState<_SessionHistoryDialog> createState() => _SessionHistoryDialogState();
}

class _SessionHistoryDialogState extends ConsumerState<_SessionHistoryDialog> {
  List<Conversation> _sessions = [];
  String? _activeId;
  final ConversationService _convService = ConversationService();

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  void _loadSessions() {
    final agentState = ref.read(agentProvider);
    final hostId = agentState.hostId ?? 'local';
    setState(() {
      _sessions = _convService.listSessions(hostId);
      _activeId = agentState.conversationId;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Dialog(
      backgroundColor: tc.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.55,
        height: MediaQuery.of(context).size.height * 0.7,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, color: cPrimary, size: 18),
                const SizedBox(width: 8),
                Text('会话历史', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                const Spacer(),
                // 新建会话按钮
                TextButton.icon(
                  onPressed: () async {
                    await ref.read(agentProvider.notifier).newSession();
                    _loadSessions();
                  },
                  icon: Icon(Icons.add, size: 14, color: cPrimary),
                  label: Text('新建', style: TextStyle(fontSize: fSmall, color: cPrimary)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: tc.textSub, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
            const Divider(color: cBorder, height: 16),
            Expanded(
              child: _sessions.isEmpty
                  ? Center(child: Text('暂无会话', style: TextStyle(color: tc.textMuted, fontSize: fBody)))
                  : ListView.builder(
                      itemCount: _sessions.length,
                      itemBuilder: (context, index) {
                        final conv = _sessions[index];
                        final isActive = conv.id == _activeId;
                        return _buildSessionTile(conv, isActive, tc);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionTile(Conversation conv, bool isActive, ThemeColors tc) {
    final msgCount = conv.messages.length;
    final hasSummary = conv.summary != null && conv.summary!.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: isActive ? cPrimary.withOpacity(0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(
          color: isActive ? cPrimary.withOpacity(0.3) : tc.border.withOpacity(0.3),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(rSmall),
        onTap: () async {
          await ref.read(agentProvider.notifier).switchSession(conv.id);
          _loadSessions();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (isActive)
                          Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: const BoxDecoration(
                              color: cPrimary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            conv.title,
                            style: TextStyle(
                              color: isActive ? cPrimary : tc.textMain,
                              fontSize: fBody,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          '${conv.updatedAt.month}/${conv.updatedAt.day} ${conv.updatedAt.hour.toString().padLeft(2, '0')}:${conv.updatedAt.minute.toString().padLeft(2, '0')}',
                          style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$msgCount 条消息',
                          style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                        ),
                        if (hasSummary) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: cAgentGreen.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(rXSmall),
                            ),
                            child: Text(
                              '已压缩',
                              style: TextStyle(color: cAgentGreen, fontSize: fMicro),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // 重命名按钮
              IconButton(
                icon: Icon(Icons.edit_outlined, size: 14, color: tc.textSub),
                onPressed: () => _showRenameDialog(conv),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                tooltip: '重命名',
              ),
              // 删除按钮
              IconButton(
                icon: Icon(Icons.delete_outline, size: 14, color: tc.textSub),
                onPressed: () => _confirmDelete(conv),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                tooltip: '删除',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRenameDialog(Conversation conv) {
    final controller = TextEditingController(text: conv.title);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('重命名会话', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody),
          decoration: InputDecoration(
            hintText: '输入会话名称',
            hintStyle: TextStyle(color: ThemeColors.of(context).textMuted),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: fBody)),
          ),
          ElevatedButton(
            onPressed: () async {
              final title = controller.text.trim();
              if (title.isNotEmpty) {
                await _convService.rename(conv.id, title);
                _loadSessions();
              }
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
            child: Text('保存', style: TextStyle(fontSize: fBody)),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(Conversation conv) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeColors.of(context).cardElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('删除会话？', style: TextStyle(color: ThemeColors.of(context).textMain, fontSize: fBody)),
        content: Text('会话「${conv.title}」的所有消息和日志将被永久删除，无法恢复。',
            style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: fSmall)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: fBody)),
          ),
          ElevatedButton(
            onPressed: () async {
              await ref.read(agentProvider.notifier).deleteSession(conv.id);
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              _loadSessions();
            },
            style: ElevatedButton.styleFrom(backgroundColor: cDanger, foregroundColor: Colors.white),
            child: Text('删除', style: TextStyle(fontSize: fBody)),
          ),
        ],
      ),
    );
  }
}

// ==================== Agent 日志对话框 ====================
class _AgentLogDialog extends StatefulWidget {
  @override
  State<_AgentLogDialog> createState() => _AgentLogDialogState();
}

class _AgentLogDialogState extends State<_AgentLogDialog> {
  List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadLogs();
    // 监听滚动：用户手动上滚时禁用自动滚动，滚到底部时恢复
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final distanceFromBottom = _scrollController.position.maxScrollExtent - _scrollController.offset;
      if (distanceFromBottom > 120 && _autoScroll) {
        _autoScroll = false;
        setState(() {});
      }
      if (distanceFromBottom <= 40 && !_autoScroll) {
        _autoScroll = true;
        setState(() {});
      }
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted) { timer.cancel(); return; }
      // 仅当日志数量变化时才 setState，避免无谓重建
      final newLogs = agentLogger.getLogs();
      if (newLogs.length != _logs.length) {
        setState(() {
          _logs = newLogs.isEmpty ? ['暂无日志...'] : newLogs;
        });
        // 下一帧再滚动，给 scrollController listener 时间检测用户是否手动上滚过
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_autoScroll && _scrollController.hasClients) {
            _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: animNormal, curve: Curves.easeOut);
          }
        });
      }
    });
  }

  void _loadLogs() {
    _logs = agentLogger.getLogs();
    if (_logs.isEmpty) _logs = ['暂无日志...'];
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Dialog(
      backgroundColor: tc.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.75,
        height: MediaQuery.of(context).size.height * 0.65,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.terminal, color: cPrimary, size: 18),
                const SizedBox(width: 8),
                Text('Agent 日志', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                const Spacer(),
                // 复制全部按钮
                IconButton(
                  tooltip: '复制全部日志',
                  icon: Icon(Icons.copy_all, color: tc.textSub, size: 16),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _logs.join('\n')));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('已复制 ${_logs.length} 条日志', style: const TextStyle(fontSize: 13)),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: tc.textSub, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
            const Divider(color: cBorder, height: 16),
            Expanded(
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: tc.bg,
                      borderRadius: BorderRadius.circular(rSmall),
                    ),
                    // SelectionArea 包裹整个 ListView，实现跨行自由选择复制
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(8),
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          final log = _logs[index];
                          Color color = cTextSub;
                          if (log.contains('[ERROR]')) color = cDanger;
                          else if (log.contains('[WARN]')) color = cWarning;
                          else if (log.contains('[DEBUG]')) color = cTextMuted;
                          else if (log.contains('[INFO]')) color = cSuccess;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 0.5),
                            child: Text(log, style: TextStyle(fontFamily: 'monospace', fontSize: fMicro, color: color)),
                          );
                        },
                      ),
                    ),
                  ),
                  // 回到底部按钮
                  if (!_autoScroll)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: GestureDetector(
                        onTap: () {
                          _autoScroll = true;
                          if (_scrollController.hasClients) {
                            _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: animNormal, curve: Curves.easeOut);
                          }
                        },
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: tc.cardElevated,
                            borderRadius: BorderRadius.circular(rFull),
                            border: Border.all(color: tc.border),
                            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 6)],
                          ),
                          child: Icon(Icons.keyboard_arrow_down, size: 18, color: tc.textSub),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text('共 ${_logs.length} 条', style: TextStyle(color: cTextMuted, fontSize: fMicro)),
          ],
        ),
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

/// 可折叠卡片：点击头部展开/收起内容
class _FoldableCard extends StatefulWidget {
  final String summary;
  final IconData icon;
  final Color iconColor;
  final Color bgColor;
  final Color borderColor;
  final ThemeColors tc;
  final Widget child;
  final EdgeInsets padding;

  const _FoldableCard({
    required this.summary,
    required this.icon,
    required this.iconColor,
    required this.bgColor,
    required this.borderColor,
    required this.tc,
    required this.child,
    this.padding = const EdgeInsets.all(10),
  });

  @override
  State<_FoldableCard> createState() => _FoldableCardState();
}

class _FoldableCardState extends State<_FoldableCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: widget.bgColor,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: widget.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(rSmall),
              topRight: Radius.circular(rSmall),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(widget.icon, size: 12, color: widget.iconColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.summary,
                      style: TextStyle(
                        color: widget.tc.textSub,
                        fontSize: fMicro,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 14,
                    color: widget.tc.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: widget.padding,
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

/// 独立的 Tab 项 widget，hover 状态自管理，不触发父页面 rebuild
class _TabItem extends StatefulWidget {
  final tp.TerminalTab tab;
  final bool isActive;
  final ThemeColors tc;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _TabItem({
    required this.tab,
    required this.isActive,
    required this.tc,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<_TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<_TabItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final isActive = widget.isActive;
    final tc = widget.tc;

    Color bgColor;
    if (isActive) {
      bgColor = tc.surface;
    } else if (_isHovered) {
      bgColor = tc.surface.withOpacity(0.5);
    } else {
      bgColor = Colors.transparent;
    }

    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Container(
          height: 32,
          constraints: const BoxConstraints(maxWidth: 140, minWidth: 60),
          margin: const EdgeInsets.only(right: 2),
          padding: const EdgeInsets.only(left: 8, right: 4),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(rSmall),
            border: isActive
                ? Border.all(color: cPrimary.withOpacity(0.4), width: 1)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 5,
                height: 5,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: tab.isConnected ? cSuccess : cDanger,
                  shape: BoxShape.circle,
                  boxShadow: tab.isConnected
                      ? [BoxShadow(color: cSuccess.withOpacity(0.4), blurRadius: 3)]
                      : null,
                ),
              ),
              Flexible(
                child: Text(
                  tab.title,
                  style: TextStyle(
                    color: isActive ? tc.textMain : tc.textSub,
                    fontSize: fSmall,
                    fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              GestureDetector(
                onTap: widget.onClose,
                child: Container(
                  width: 16,
                  height: 16,
                  margin: const EdgeInsets.only(left: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(rXSmall),
                  ),
                  child: Icon(
                    Icons.close,
                    size: 10,
                    color: isActive ? tc.textSub : tc.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
