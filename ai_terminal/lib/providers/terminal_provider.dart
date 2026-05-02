import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/host_config.dart';
import '../services/ssh_service.dart';
import '../services/local_terminal_service.dart';
import '../services/ssh_connection_pool.dart';
import '../core/credentials_store.dart';

const _uuid = Uuid();

/// 终端标签
class TerminalTab {
  final String id;
  final String hostId; // 本地终端为 'local'
  final String title;
  bool isConnected;
  SSHService? service; // SSH 连接
  LocalTerminalService? localService; // 本地终端
  final StreamController<String> outputController;

  TerminalTab({
    required this.id,
    required this.hostId,
    required this.title,
    this.isConnected = false,
    this.service,
    this.localService,
  }) : outputController = StreamController<String>.broadcast();

  bool get isLocal => hostId == 'local';

  void dispose() {
    outputController.close();
    localService?.dispose();
  }

  /// 创建副本（用于触发 Riverpod 状态更新）
  TerminalTab copyWith({
    bool? isConnected,
    SSHService? service,
    LocalTerminalService? localService,
  }) {
    return TerminalTab(
      id: id,
      hostId: hostId,
      title: title,
      isConnected: isConnected ?? this.isConnected,
      service: service ?? this.service,
      localService: localService ?? this.localService,
    );
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

  /// 打开本地终端标签
  Future<void> openLocalTab() async {
    if (!LocalTerminalService.isSupported) return;

    final tabId = _uuid.v4();
    final newTab = TerminalTab(
      id: tabId,
      hostId: 'local',
      title: '本地',
    );

    state = state.copyWith(
      tabs: [...state.tabs, newTab],
      activeTabId: tabId,
    );

    final localService = LocalTerminalService();
    newTab.localService = localService;

    await localService.start();
    newTab.isConnected = localService.isConnected;

    // 触发状态更新，让 UI 感知 isConnected 变化
    state = state.copyWith(
      tabs: state.tabs.map((t) => t.id == tabId ? newTab : t).toList(),
    );

    // 监听输出
    localService.output.listen((data) {
      if (!newTab.outputController.isClosed) {
        newTab.outputController.add(data);
      }
    });
  }

  /// 打开新 SSH 标签（允许重复连接同一服务器）
  Future<void> openTab(HostConfig config, {String? password, String? privateKeyContent}) async {
    // 创建新标签（每次都新建，允许重复连接）
    final tabId = _uuid.v4();
    final newTab = TerminalTab(
      id: tabId,
      hostId: config.id,
      title: config.name,
    );

    state = state.copyWith(
      tabs: [...state.tabs, newTab],
      activeTabId: tabId,
    );

    // 处理跳板机（内联配置，和主服务器在一条连接信息里）
    HostConfig? jumpHostConfig;
    String? jumpPassword;
    String? jumpPrivateKeyContent;

    if (config.hasJumpHost) {
      // 从内联字段构建跳板机 HostConfig
      jumpHostConfig = HostConfig.create(
        id: '${config.id}_jump',
        name: '跳板机 ${config.jumpHost}',
        host: config.jumpHost!,
        port: config.jumpPort,
        username: config.jumpUsername ?? 'root',
        authType: config.jumpAuthType ?? 'password',
      );
      // 跳板机凭据从 CredentialsStore 获取（key 用主服务器 id + '_jump'）
      jumpPassword = await CredentialsStore.get(hostId: '${config.id}_jump', type: 'password');
      jumpPrivateKeyContent = await CredentialsStore.get(hostId: '${config.id}_jump', type: 'privateKey');
    }

    // 连接（每次新建，用 tabId 做 key 支持重复连接同一服务器）
    try {
      final service = await SSHConnectionPool.acquire(
        tabId, // 用 tabId 而非 hostId，允许同一服务器多个连接
        config,
        password: password,
        privateKeyContent: privateKeyContent,
        jumpHostConfig: jumpHostConfig,
        jumpPassword: jumpPassword,
        jumpPrivateKeyContent: jumpPrivateKeyContent,
      );

      newTab.service = service;
      newTab.isConnected = service.isConnected;

      // 触发状态更新，让 UI 感知 isConnected 变化
      state = state.copyWith(
        tabs: state.tabs.map((t) => t.id == tabId ? newTab : t).toList(),
      );

      // 监听输出
      service.output.listen((data) {
        if (!newTab.outputController.isClosed) {
          newTab.outputController.add(data);
        }
      });
    } catch (e) {
      newTab.outputController.add('\r\n❌ 连接失败: $e\r\n');
    }
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

  /// 重连
  Future<void> reconnect(String tabId, HostConfig config) async {
    // 断开旧连接
    await SSHConnectionPool.forceDisconnect(tabId);

    // 重新连接
    final password = await CredentialsStore.get(hostId: config.id, type: 'password');
    final privateKey = await CredentialsStore.get(hostId: config.id, type: 'privateKey');

    await openTab(config, password: password, privateKeyContent: privateKey);
  }

  @override
  void dispose() {
    for (final tab in state.tabs) {
      tab.dispose();
    }
    super.dispose();
  }
}
