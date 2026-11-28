import 'dart:async';
import 'package:dartssh2/dartssh2.dart' show SSHHostkeyError;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/host_config.dart';
import '../services/ssh_service.dart';
import '../services/local_terminal_service.dart';
import '../services/ssh_connection_pool.dart';
import '../core/credentials_store.dart';
import '../core/l10n_holder.dart';
import '../core/security/ssh_client_security.dart';
import '../core/security/ssh_host_key_verifier.dart';
import '../services/daos.dart';
import '../utils/reconnect_policy.dart';
import 'agent_provider.dart';
import 'app_providers.dart';

const _uuid = Uuid();

/// 打开的 SSH 标签持久化键（冷启动恢复用）
const kOpenTabsKey = 'openTabsV1';

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

  /// 失败原因的本地化消息键。失败瞬间存下的文本会把当时的语言冻结进 tab，
  /// 切换语言后仍显示旧语言；带键的已知消息会在渲染时按当前语言重新取词。
  String? errorL10nKey;

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
  void markFailed(String error,
      {required bool hadConnectedBefore, String? l10nKey}) {
    status = hadConnectedBefore ? TabStatus.lost : TabStatus.failed;
    connectionError = error;
    errorL10nKey = l10nKey;
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
final terminalProvider =
    StateNotifierProvider<TerminalNotifier, TerminalState>((ref) {
  // 自动重连的定时器归 notifier 所有。若允许 Riverpod 在页面销毁后回收
  // provider，后台自愈会随之失效（A2 根因），因此这里必须保活。
  ref.keepAlive();
  return TerminalNotifier(ref);
});

class TerminalNotifier extends StateNotifier<TerminalState> {
  TerminalNotifier(this._ref) : super(TerminalState());
  final Ref _ref;

  /// 断线自动重连的退避计数与定时器（按 tabId 隔离）
  final Map<String, int> _reconnectAttempts = {};
  final Map<String, Timer> _reconnectTimers = {};

  /// 重连成功后广播 tabId，UI 侧据此重绑 terminal / tracker / 尺寸同步。
  /// 业务层（executor 重绑）在 notifier 内完成，不依赖页面是否存活。
  final StreamController<String> _reconnectedTabIds =
      StreamController<String>.broadcast();

  Stream<String> get reconnectedTabIds => _reconnectedTabIds.stream;

  TerminalTab? _findTab(String tabId) {
    final tabs = state.tabs;
    for (final tab in tabs) {
      if (tab.id == tabId) return tab;
    }
    return null;
  }

  /// 注册本地终端标签（不建连），平台不支持本地 PTY 时返回 null。
  /// 拆成"注册 + 建连"两步，是为了让页面能立刻切过去显示过渡态，
  /// 而不是等 PTY 起好才换屏——期间用户看到的还是上一个标签。
  ///
  /// 守卫必须在这一层：注册出标签就等于在 tab 条上落了席位，
  /// Android/iOS 上必然连不起来，只会留一个死的「本地终端」空标签。
  /// 只把守卫放在页面层的话，任何绕过页面直接调 provider 的路径都会漏。
  TerminalTab? registerLocalTab() {
    if (!LocalTerminalService.isSupported) return null;
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

  /// 仅供测试：替换本地 PTY 服务的构造，免得测试里真的起一个 shell。
  @visibleForTesting
  LocalTerminalService Function()? localServiceFactoryForTesting;

  /// 在已注册的标签上启动本地 PTY；成功返回该标签，失败返回 null（状态已写入标签）
  /// [hadConnectedBefore] 覆盖默认的"曾连接"判定，供重连路径保留终端回滚内容
  /// [columns]/[rows] 是终端视图当前实测的可视区尺寸，用于让 shell 第一条提示符
  /// 就打在正确的宽度上；不传则退回 Pty.start 的 80×24。
  Future<TerminalTab?> connectLocalTab(TerminalTab tab,
      {bool? hadConnectedBefore, int? columns, int? rows}) async {
    final ever = hadConnectedBefore ?? tab.everConnected;

    if (!LocalTerminalService.isSupported) {
      tab.markFailed(L10n.str.terminalLocalStartFailed,
          hadConnectedBefore: ever, l10nKey: 'terminalLocalStartFailed');
      _publish();
      return null;
    }

    final localService = localServiceFactoryForTesting?.call() ??
        LocalTerminalService();
    try {
      // 尺寸能传就必须传：xterm 新建的 Terminal 固定从 80×24 起算，onResize 只在
      // 「变化」时才回调，而此刻 tab.localService 还是 null —— 视图实测到的真实
      // 宽度就在这一帧里丢了。shell 于是按 80 列打第一条提示符，150ms 后才被
      // 改成实测列数：readline 的换行/光标推算停在旧宽度上，回显会盖到相邻行、
      // 长命令看着像重复了一屏。
      await localService.start(
        columns: columns ?? 80,
        rows: rows ?? 24,
      );
    } catch (e) {
      localService.dispose();
      tab.markFailed(_describeConnectionError(e), hadConnectedBefore: ever);
      _publish();
      return null;
    }

    if (!localService.isConnected) {
      localService.dispose();
      tab.markFailed(L10n.str.terminalLocalStartFailed,
          hadConnectedBefore: ever, l10nKey: 'terminalLocalStartFailed');
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
    persistOpenTabs();
    return tab;
  }

  /// 记录当前打开的 SSH 标签，供冷启动后恢复。
  ///
  /// 只记 SSH 标签：本地标签绑的是当次进程的 PTY，跨启动既没有回滚内容也没有
  /// 恢复价值（Android/iOS 上根本起不来）。tab id 是随机 UUID，重启后无意义，
  /// 所以持久化 hostId 顺序 + 「哪个位置是活动标签」。
  void persistOpenTabs() {
    final hostIds = state.tabs.where((t) => !t.isLocal).map((t) => t.hostId).toList();
    final active = _findTab(state.activeTabId ?? '');
    final activeIndex =
        active == null || active.isLocal ? 0 : hostIds.indexOf(active.hostId);
    SettingsDao.set(kOpenTabsKey, {
      'hostIds': hostIds,
      'activeIndex': activeIndex >= 0 ? activeIndex : 0,
    });
  }

  /// 冷启动要恢复的标签（hostId 按打开顺序）；无记录时返回空列表
  static ({List<String> hostIds, int activeIndex}) readOpenTabsToRestore() {
    final raw = SettingsDao.getCached(kOpenTabsKey);
    if (raw is! Map) return (hostIds: const [], activeIndex: 0);
    final hostIds = (raw['hostIds'] as List?)
            ?.map((e) => e.toString())
            .where((e) => e.isNotEmpty && e != 'local')
            .toList() ??
        const <String>[];
    final activeIndex = raw['activeIndex'] is int ? raw['activeIndex'] as int : 0;
    return (
      hostIds: hostIds,
      activeIndex: activeIndex >= 0 && activeIndex < hostIds.length ? activeIndex : 0,
    );
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

  /// 断线后按退避自动重连（见 ReconnectPolicy）。
  /// 调度权归 notifier：页面销毁后仍要完成自愈（A2）。
  ///
  /// 任务运行中**同样要重连**：这里重连不会取消任务，只是把 executor 换成
  /// 新的连接，引擎下一步会自动取用（AgentEngine.setExecutor 自愈通道）。
  /// 早先的 `isRunningFor` 拦截会让自愈链彻底失效——掉线事件的首次触发只有
  /// onDisconnected 一个入口，拒掉就没有下一次，半开连接上任务只能干等到超时。
  void scheduleAutoReconnect(String tabId) {
    final tab = _findTab(tabId);
    if (tab == null || tab.isLocal || tab.status != TabStatus.lost) return;
    if (_reconnectTimers.containsKey(tabId)) return; // 已有调度，避免重复
    final attempts = _reconnectAttempts[tabId] ?? 0;
    if (!ReconnectPolicy.shouldRetry(attempts)) return;

    _reconnectTimers[tabId] =
        Timer(ReconnectPolicy.delayForAttempt(attempts), () async {
      _reconnectTimers.remove(tabId);
      // 等待期间用户可能已手动重连或关 tab
      final current = _findTab(tabId);
      if (current == null || current.status != TabStatus.lost) return;
      // 定时器已到点即消耗一次尝试预算，后续即使找不到主机配置也不再
      // 无限重试（配置缺失属于用户侧问题，交给手动重连处理）。
      _reconnectAttempts[tabId] = attempts + 1;
      final host =
          _ref.read(hostsProvider.notifier).getHostById(current.hostId);
      if (host == null) return;
      try {
        await reconnect(tabId, host, autoRetryOnFailure: true);
      } catch (e) {
        // 后台定时器里不能让异常逸出，否则变成 uncaught zone error
        debugPrint('[TerminalNotifier] 自动重连失败 (tabId=$tabId): $e');
      }
    });
  }

  /// 手动重连 / 关 tab 时取消后台调度，避免与用户操作竞争。
  /// [keepAttempts] 供自动重连路径使用：重连失败后还要按下一档退避，
  /// 不能把已用掉的尝试次数清掉。
  void cancelAutoReconnect(String tabId, {bool keepAttempts = false}) {
    _reconnectTimers.remove(tabId)?.cancel();
    if (!keepAttempts) _reconnectAttempts.remove(tabId);
  }

  /// 仅供测试观察调度状态
  @visibleForTesting
  int get pendingReconnectCount => _reconnectTimers.length;

  @visibleForTesting
  int reconnectAttemptsFor(String tabId) => _reconnectAttempts[tabId] ?? 0;

  /// 重连成功后的统一收尾：清退避、重绑 executor、通知 UI 与引擎。
  /// 业务绑定放在 notifier 内，页面不在时 AI 也不会拿着旧 executor。
  void _finishReconnect(TerminalTab tab) {
    cancelAutoReconnect(tab.id);
    final service = tab.service ?? tab.localService;
    if (service != null) {
      final agent = _ref.read(agentProvider.notifier);
      agent.setExecutor(service, hostId: tab.hostId, tabId: tab.id);
      // 引擎侧：放宽连续失败预算 + 登记"新会话状态已丢"提示。
      // 必须在 setExecutor 之后——它会把新 executor 的存活状态告知引擎。
      agent.noteConnectionRestored(tab.id);
    }
    if (!_reconnectedTabIds.isClosed) _reconnectedTabIds.add(tab.id);
  }

  /// 建连主流程：取凭据 → 组跳板机 → acquire → 绑定输出
  /// [hadConnectedBefore] 决定失败后是整屏错误（failed）还是角标重连（lost）
  Future<TerminalTab?> _openSsh(
    TerminalTab tab,
    HostConfig config, {
    required bool hadConnectedBefore,
  }) async {
    final password =
        await CredentialsStore.get(hostId: config.id, type: 'password');
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
      jumpPassword = await CredentialsStore.get(
          hostId: '${config.id}_jump', type: 'password');
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
      // 掉线（非主动断开）→ 标记 lost，UI 出重连角标；页面侧决定是否自动重连。
      // 一个 tab 一个池条目（acquire 以 tabId 为键），回调不会被别的 tab 覆盖。
      service.onDisconnected = () {
        if (!_isOpen(tab.id) || tab.status != TabStatus.connected) return;
        tab.markFailed(L10n.str.orchHostDisconnected, hadConnectedBefore: true);
        _publish();
        // 自动重连由 notifier 调度，不依赖 TerminalPage 是否存活
        scheduleAutoReconnect(tab.id);
      };
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
    // 主机密钥被拒绝时 dartssh2 只会报 SSHAuthAbortError(…before authentication)，
    // 不还原原因就会被下面的认证分支接管，把用户送去查密码。
    final cause = SshClientSecurity.unwrapConnectionFailure(error);
    final message = cause.toString();
    final hint = L10n.str;
    if (cause is SshHostKeyVerificationException || cause is SSHHostkeyError)
      return '$message\n\n💡 ${hint.connErrHostKey}';
    if (message.contains('Connection refused'))
      return '$message\n\n💡 ${hint.connErrRefused}';
    if (message.contains('timeout') || message.contains('Timeout'))
      return '$message\n\n💡 ${hint.connErrTimeout}';
    if (message.contains('authentication') || message.contains('Auth'))
      return '$message\n\n💡 ${hint.connErrAuth}';
    if (message.contains('No route to host'))
      return '$message\n\n💡 ${hint.connErrNoRoute}';
    return '$message\n\n💡 ${hint.connErrGeneric}';
  }

  /// 关闭标签
  Future<void> closeTab(String tabId) async {
    final tab = state.tabs.cast<TerminalTab?>().firstWhere(
          (t) => t?.id == tabId,
          orElse: () => null,
        );

    if (tab != null) {
      cancelAutoReconnect(tabId); // 关掉 tab 后不再有重连目标
      if (tab.isLocal) {
        tab.localService?.disconnect();
      } else {
        tab.service?.onDisconnected = null; // 关 tab 是主动断开，不触发 lost
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
    persistOpenTabs();
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
      // 切到本地标签时不落盘：本地标签不参与恢复，覆盖后会把「上次活跃的
      // SSH 标签」位置擦成 0，重启后焦点跑到最先打开的那个。
      final tab = _findTab(tabId);
      if (tab != null && !tab.isLocal) persistOpenTabs();
    }
  }

  /// 恢复流程专用：把 activeTabId 指向已注册的标签并落盘。
  ///
  /// [setActiveTab] 是用户点击的入口；冷启动恢复时页面注册完一串标签后，
  /// 每个标签都会把 activeTabId 覆盖成最后一个，需要这一步把焦点放回
  /// 上次关闭时的活动标签。
  void activateTabForRestore(String tabId) {
    if (!state.tabs.any((t) => t.id == tabId)) return;
    state = state.copyWith(activeTabId: tabId);
    persistOpenTabs();
  }

  /// 重连：在原 tab 上重建 SSH 连接（保留 tabId、终端内容、outputController）
  /// 返回重连后的 tab；失败返回 null（原因写在 tab.connectionError）。
  /// 取消当前调度：用户开始手动重连，后台退避必须让位。
  Future<TerminalTab?> reconnect(String tabId, HostConfig config,
      {bool autoRetryOnFailure = false}) async {
    // 取消待执行的定时器，但保留已用次数：失败后还要按下一档退避
    cancelAutoReconnect(tabId, keepAttempts: true);
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
    // 2. 强制断开旧 SSH 连接（清理连接池）。先清掉线回调：主动断开不该触发 lost
    existingTab.service?.onDisconnected = null;
    await SSHConnectionPool.forceDisconnect(tabId);

    // 3. 标记为连接中
    existingTab.service = null;
    existingTab.connectionError = null;
    existingTab.status =
        hadConnectedBefore ? TabStatus.reconnecting : TabStatus.connecting;
    _publish();

    final result = await _openSsh(existingTab, config,
        hadConnectedBefore: hadConnectedBefore);
    if (result != null) {
      _finishReconnect(result);
    } else if (autoRetryOnFailure) {
      // 自动重连失败：tab 仍是 lost，继续下一档退避
      scheduleAutoReconnect(tabId);
    }
    return result;
  }

  /// 本地终端重连：在原 tab 上重启 PTY（保留 tabId、终端内容）
  /// 返回重连后的 tab；失败返回 null（原因写在 tab.connectionError）。
  Future<TerminalTab?> reconnectLocal(String tabId,
      {int? columns, int? rows}) async {
    if (!LocalTerminalService.isSupported) return null;
    cancelAutoReconnect(tabId, keepAttempts: true);
    final existingTab = state.tabs.cast<TerminalTab?>().firstWhere(
          (t) => t?.id == tabId,
          orElse: () => null,
        );
    if (existingTab == null) {
      // 原 tab 已不在列表中，新建一个
      final tab = registerLocalTab();
      return tab == null
          ? null
          : connectLocalTab(tab, columns: columns, rows: rows);
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
        hadConnectedBefore: hadConnectedBefore, columns: columns, rows: rows);
    if (result != null) _finishReconnect(result);
    return result;
  }

  @override
  void dispose() {
    for (final timer in _reconnectTimers.values) {
      timer.cancel();
    }
    _reconnectTimers.clear();
    _reconnectAttempts.clear();
    _reconnectedTabIds.close();
    for (final tab in state.tabs) {
      tab.dispose();
    }
    super.dispose();
  }
}
