import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/host_config.dart';
import '../services/ssh_service.dart';
import '../services/local_terminal_service.dart';
import '../services/ssh_connection_pool.dart';
import '../core/credentials_store.dart';
import '../core/l10n_holder.dart';

const _uuid = Uuid();

/// 标签连接阶段
///
/// 分成"首连"和"曾连接"两组，是为了让 UI 有别：首连阶段终端还不存在，
/// 用整块过渡/错误视图；曾连接的标签要保留回滚内容，只用角标提示，
/// 否则重连时用户刚刚读到的输出会凭空消失。
enum TabStatus {
  /// 首次建连中
  connecting,

  /// 曾连接成功，正在重连
  reconnecting,

  /// 已连接
  connected,

  /// 首次建连失败（终端从未建立）
  failed,

  /// 曾连接成功，当前断开
  lost,
}

/// 终端标签
class TerminalTab {
  final String id;
  final String hostId; // 本地终端为 'local'
  String title;
  TabStatus status;

  /// 连接失败原因（已带分类提示），仅在 [TabStatus.failed] / [TabStatus.lost] 时有值
  String? connectionError;

  SSHService? service; // SSH 连接
  LocalTerminalService? localService; // 本地终端
  final StreamController<String> outputController;

  /// 保存输出流订阅，以便关闭时取消
  StreamSubscription<String>? _outputSubscription;

  TerminalTab({
    required this.id,
    required this.hostId,
    required this.title,
    this.status = TabStatus.connecting,
    this.service,
    this.localService,
  }) : outputController = StreamController<String>.broadcast();

  bool get isLocal => hostId == 'local';

  bool get isConnected => status == TabStatus.connected;

  bool get isConnecting =>
      status == TabStatus.connecting || status == TabStatus.reconnecting;

  /// 是否曾经建立过连接（决定失败后是"错误整屏"还是"角标可重连"）
  bool get everConnected => service != null || localService != null;

  /// 标记一次建连失败
  void markFailed(String error, {required bool hadConnectedBefore}) {
    status = hadConnectedBefore ? TabStatus.lost : TabStatus.failed;
    connectionError = error;
  }

  /// 设置输出流转发订阅（保存引用以便关闭时取消）
  void setOutputSubscription(StreamSubscription<String> sub) {
    _outputSubscription = sub;
  }

  /// 仅取消输出订阅（不关闭 outputController、不 dispose service）
  /// 用于重连场景：旧 service 已断开，需要换新 service 但保留 outputController
  /// 让 UI 侧监听保持有效，避免创建新 TerminalTab 导致订阅失效
  void cancelOutputSubscription() {
    _outputSubscription?.cancel();
    _outputSubscription = null;
  }

  void dispose() {
    _outputSubscription?.cancel();
    _outputSubscription = null;
    outputController.close();
    localService?.dispose();
  }
}

/// 终端状态
class TerminalState {
  final List<TerminalTab> tabs;
  final String? activeTabId;

  TerminalState({
    this.tabs = const [],
    this.activeTabId,
  });

  TerminalTab? get activeTab {
    if (activeTabId == null) return null;
    try {
      return tabs.firstWhere((t) => t.id == activeTabId);
    } catch (_) {
      return null;
    }
  }

  TerminalState copyWith({
    List<TerminalTab>? tabs,
    String? activeTabId,
  }) {
    return TerminalState(
      tabs: tabs ?? this.tabs,
      activeTabId: activeTabId ?? this.activeTabId,
    );
  }
}

/// 终端 Provider
final terminalProvider = StateNotifierProvider<TerminalNotifier, TerminalState>((ref) {
  return TerminalNotifier();
});

class TerminalNotifier extends StateNotifier<TerminalState> {
  TerminalNotifier() : super(TerminalState());

  /// 注册本地终端标签（不建连）。
  /// 拆成"注册 + 建连"两步，是为了让页面能立刻切过去显示过渡态，
  /// 而不是等 PTY 起好才换屏——期间用户看到的还是上一个标签。
  TerminalTab registerLocalTab() {
    final tab = TerminalTab(
      id: _uuid.v4(),
      hostId: 'local',
      title: L10n.str.terminalLocalTab,
    );
    state = state.copyWith(
      tabs: [...state.tabs, tab],
      activeTabId: tab.id,
    );
    return tab;
  }

  /// 在已注册的标签上启动本地 PTY；成功返回该标签，失败返回 null（状态已写入标签）
  /// [hadConnectedBefore] 覆盖默认的"曾连接"判定，供重连路径保留终端回滚内容
  Future<TerminalTab?> connectLocalTab(TerminalTab tab,
      {bool? hadConnectedBefore}) async {
    final ever = hadConnectedBefore ?? tab.everConnected;

    if (!LocalTerminalService.isSupported) {
      tab.markFailed(L10n.str.terminalLocalStartFailed, hadConnectedBefore: ever);
      _publish();
      return null;
    }

    final localService = LocalTerminalService();
    try {
      await localService.start();
    } catch (e) {
      localService.dispose();
      tab.markFailed(_describeConnectionError(e), hadConnectedBefore: ever);
      _publish();
      return null;
    }

    if (!localService.isConnected) {
      localService.dispose();
      tab.markFailed(L10n.str.terminalLocalStartFailed, hadConnectedBefore: ever);
      _publish();
      return null;
    }

    // 建连期间标签可能已被关闭：谁创建谁释放
    if (!_isOpen(tab.id)) {
      localService.dispose();
      return null;
    }

    tab.localService = localService;
    tab.connectionError = null;
    tab.status = TabStatus.connected;
    _publish();

    final sub = localService.output.listen((data) {
      if (!tab.outputController.isClosed) {
        tab.outputController.add(data);
      }
    });
    tab.setOutputSubscription(sub);
    return tab;
  }

  /// 注册 SSH 标签（不建连），见 [registerLocalTab] 的拆分为何存在
  TerminalTab registerTab(HostConfig config) {
    final tab = TerminalTab(
      id: _uuid.v4(),
      hostId: config.id,
      title: config.name,
    );
    state = state.copyWith(
      tabs: [...state.tabs, tab],
      activeTabId: tab.id,
    );
    return tab;
  }

  /// 本地标签的标题在创建时取自当前语言；切换语言后由页面同步为新标题。
  void syncLocalTabTitle(String title) {
    var changed = false;
    for (final tab in state.tabs) {
      if (tab.isLocal && tab.title != title) {
        tab.title = title;
        changed = true;
      }
    }
    if (changed) _publish();
  }

  /// 在已注册的标签上建立 SSH 连接；成功返回该标签，失败返回 null（状态已写入标签）
  Future<TerminalTab?> connectTab(TerminalTab tab, HostConfig config) =>
      _openSsh(tab, config, hadConnectedBefore: tab.everConnected);

  /// 触发一次状态变更，让监听 terminalProvider 的 UI 重绘
  void _publish() => state = state.copyWith(tabs: [...state.tabs]);

  bool _isOpen(String tabId) => state.tabs.any((t) => t.id == tabId);

  /// 建连主流程：取凭据 → 组跳板机 → acquire → 绑定输出
  /// [hadConnectedBefore] 决定失败后是整屏错误（failed）还是角标重连（lost）
  Future<TerminalTab?> _openSsh(
    TerminalTab tab,
    HostConfig config, {
    required bool hadConnectedBefore,
  }) async {
    final password = await CredentialsStore.get(hostId: config.id, type: 'password');
    final privateKeyContent =
        await CredentialsStore.get(hostId: config.id, type: 'privateKey');

    if (password == null && privateKeyContent == null) {
      tab.markFailed(L10n.str.noCredentials,
          hadConnectedBefore: hadConnectedBefore);
      _publish();
      return null;
    }

    // 跳板机（内联配置，和主服务器在一条连接信息里）
    HostConfig? jumpHostConfig;
    String? jumpPassword;
    String? jumpPrivateKeyContent;
    if (config.hasJumpHost) {
      jumpHostConfig = HostConfig.create(
        id: '${config.id}_jump',
        name: '跳板机 ${config.jumpHost}',
        host: config.jumpHost!,
        port: config.jumpPort,
        username: config.jumpUsername ?? 'root',
        authType: config.jumpAuthType ?? 'password',
      );
      // 跳板机凭据从 CredentialsStore 获取（key 用主服务器 id + '_jump'）
      jumpPassword =
          await CredentialsStore.get(hostId: '${config.id}_jump', type: 'password');
      jumpPrivateKeyContent = await CredentialsStore.get(
          hostId: '${config.id}_jump', type: 'privateKey');
    }

    try {
      final service = await SSHConnectionPool.acquire(
        tab.id, // 用 tabId 而非 hostId，允许同一服务器多个连接
        config,
        password: password,
        privateKeyContent: privateKeyContent,
        jumpHostConfig: jumpHostConfig,
        jumpPassword: jumpPassword,
        jumpPrivateKeyContent: jumpPrivateKeyContent,
      );

      // 建连期间用户可能已关掉标签：连接已进池，必须还回去
      if (!_isOpen(tab.id)) {
        SSHConnectionPool.release(tab.id);
        return null;
      }

      tab.service = service;
      tab.connectionError = null;
      tab.status = TabStatus.connected;
      _publish();

      final sub = service.output.listen((data) {
        if (!tab.outputController.isClosed) {
          tab.outputController.add(data);
        }
      });
      tab.setOutputSubscription(sub);
      return tab;
    } catch (e) {
      tab.markFailed(_describeConnectionError(e),
          hadConnectedBefore: hadConnectedBefore);
      _publish();
      return null;
    }
  }

  /// 把底层异常翻译成人话 + 分类排查提示
  String _describeConnectionError(Object error) {
    final message = error.toString();
    final hint = L10n.str;
    if (message.contains('Connection refused')) return '$message\n\n💡 ${hint.connErrRefused}';
    if (message.contains('timeout') || message.contains('Timeout')) return '$message\n\n💡 ${hint.connErrTimeout}';
    if (message.contains('authentication') || message.contains('Auth')) return '$message\n\n💡 ${hint.connErrAuth}';
    if (message.contains('No route to host')) return '$message\n\n💡 ${hint.connErrNoRoute}';
    return '$message\n\n💡 ${hint.connErrGeneric}';
  }

  /// 关闭标签
  Future<void> closeTab(String tabId) async {
    final tab = state.tabs.cast<TerminalTab?>().firstWhere(
      (t) => t?.id == tabId,
      orElse: () => null,
    );

    if (tab != null) {
      if (tab.isLocal) {
        tab.localService?.disconnect();
      } else {
        SSHConnectionPool.release(tab.id); // 用 tabId 释放
      }
      tab.dispose();
    }

    final newTabs = state.tabs.where((t) => t.id != tabId).toList();
    String? newActiveTabId = state.activeTabId;

    if (state.activeTabId == tabId) {
      newActiveTabId = newTabs.isNotEmpty ? newTabs.last.id : null;
    }

    state = TerminalState(
      tabs: newTabs,
      activeTabId: newActiveTabId,
    );
  }

  /// 发送命令
  void sendCommand(String tabId, String command) {
    final tab = state.tabs.cast<TerminalTab?>().firstWhere(
      (t) => t?.id == tabId,
      orElse: () => null,
    );

    tab?.service?.execute(command);
    tab?.localService?.execute(command);
  }

  /// 调整终端大小
  void resizeTab(String tabId, int columns, int rows) {
    final tab = state.tabs.cast<TerminalTab?>().firstWhere(
      (t) => t?.id == tabId,
      orElse: () => null,
    );

    tab?.service?.resize(columns, rows);
    tab?.localService?.resize(columns, rows);
  }

  /// 切换激活标签
  void setActiveTab(String tabId) {
    if (state.tabs.any((t) => t.id == tabId)) {
      state = state.copyWith(activeTabId: tabId);
    }
  }

  /// 重连：在原 tab 上重建 SSH 连接（保留 tabId、终端内容、outputController）
  /// 返回重连后的 tab；失败返回 null（原因写在 tab.connectionError）。
  Future<TerminalTab?> reconnect(String tabId, HostConfig config) async {
    final existingTab = state.tabs.cast<TerminalTab?>().firstWhere(
      (t) => t?.id == tabId,
      orElse: () => null,
    );
    if (existingTab == null) {
      // 原 tab 已不在列表中（可能已被关闭），新建一个
      return _openSsh(registerTab(config), config, hadConnectedBefore: false);
    }

    // 曾连接过 → 保留回滚内容，状态用 reconnecting/lost；首连失败 → connecting/failed
    final hadConnectedBefore = existingTab.everConnected;

    // 1. 取消旧 tab 上的输出订阅（避免旧 service 流到新 service 之间产生串扰）
    existingTab.cancelOutputSubscription();
    // 2. 强制断开旧 SSH 连接（清理连接池）
    await SSHConnectionPool.forceDisconnect(tabId);

    // 3. 标记为连接中
    existingTab.service = null;
    existingTab.connectionError = null;
    existingTab.status =
        hadConnectedBefore ? TabStatus.reconnecting : TabStatus.connecting;
    _publish();

    return _openSsh(existingTab, config,
        hadConnectedBefore: hadConnectedBefore);
  }

  /// 本地终端重连：在原 tab 上重启 PTY（保留 tabId、终端内容）
  /// 返回重连后的 tab；失败返回 null（原因写在 tab.connectionError）。
  Future<TerminalTab?> reconnectLocal(String tabId) async {
    final existingTab = state.tabs.cast<TerminalTab?>().firstWhere(
      (t) => t?.id == tabId,
      orElse: () => null,
    );
    if (existingTab == null) {
      // 原 tab 已不在列表中，新建一个
      final tab = registerLocalTab();
      return connectLocalTab(tab);
    }
    if (!existingTab.isLocal) return null;

    final hadConnectedBefore = existingTab.everConnected;

    // 1. 取消旧输出订阅
    existingTab.cancelOutputSubscription();
    // 2. dispose 旧 localService（PTY 进程可能已退出，释放残留资源）
    existingTab.localService?.dispose();
    existingTab.localService = null;
    existingTab.connectionError = null;
    existingTab.status =
        hadConnectedBefore ? TabStatus.reconnecting : TabStatus.connecting;
    _publish();

    final result = await connectLocalTab(existingTab,
        hadConnectedBefore: hadConnectedBefore);
    return result;
  }

  @override
  void dispose() {
    for (final tab in state.tabs) {
      tab.dispose();
    }
    super.dispose();
  }
}
