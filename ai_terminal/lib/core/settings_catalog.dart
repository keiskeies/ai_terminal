import 'terminal_themes.dart';
import 'ui_text.dart';
import '../services/daos.dart';
import '../services/mcp_manager.dart';
import '../services/notification_service.dart';
import '../services/web_search_config.dart';

/// 设置分组的单一数据源。
///
/// 此前抽屉和整页各维护一份分组：抽屉 8 项、整页 17 项，同一个开关在两处
/// 措辞不同（「外观」vs「外观与体验」，「AI 模型」vs「AI 与智能」）。分组
/// 顺序与标题以设计稿第 07 节的 7 组为准；联网搜索是设计稿未列出、但功能
/// 独立存在的一项，排在 Agent 之后，让三组 AI 能力连续。
///
/// 副标题一律是「当前真实状态读数」，不是说明文案 —— 用户要能一眼看出自己
/// 现在到底是什么配置，而不是读一句「管理你的主机」。
class SettingsEntry {
  const SettingsEntry({
    required this.id,
    required this.title,
    required this.route,
  });

  /// 与 [SettingsInlinePanel] 的 settingsId、`/settings/<id>` 路由保持一致
  final String id;

  final String title;

  /// 定位用的路由（`/settings/<id>`）。这条路由现在渲染的还是同一次 [SettingsPage]，
  /// 只是进来时把对应的组滚到视野里 —— 不再有独立的二级设置页面。
  final String route;

  /// 当前状态读数。数据源都在缓存里，读不到时给「还没有…」而不是空白。
  String get subtitle {
    switch (id) {
      case 'appearance':
        return _appearanceSubtitle();
      case 'ai':
        return _aiSubtitle();
      case 'agent':
        return _agentSubtitle();
      case 'web_search':
        return _webSearchSubtitle();
      case 'security':
        return _securitySubtitle();
      case 'mcp':
        return _mcpSubtitle();
      case 'knowledge_rules':
        return _rulesSubtitle();
      case 'notification':
        return _notificationSubtitle();
      default:
        return '';
    }
  }

  static String _appearanceSubtitle() {
    final mode = SettingsDao.getCached('themeMode') as String? ?? 'dark';
    final modeLabel = switch (mode) {
      'light' => UiText.t('浅色', 'Light'),
      'system' => UiText.t('跟随系统', 'System'),
      _ => UiText.t('深色', 'Dark'),
    };
    // 没存过就用默认配色：副标题漏掉配色会让人以为「没设置过配色」。
    final stored = SettingsDao.getCached('terminalPalette') as String?;
    final paletteId = (stored == null || stored.isEmpty)
        ? kDefaultTerminalPalette
        : stored;
    String? paletteName;
    for (final p in kTerminalPalettes) {
      if (p.id == paletteId) paletteName = p.label(isZh: UiText.zh);
    }
    final fontSize =
        (SettingsDao.getCached('terminalFontSize') as num?)?.toInt() ?? 13;
    return [
      modeLabel,
      if (paletteName != null) paletteName,
      '${fontSize}px',
    ].join(' · ');
  }

  static String _aiSubtitle() {
    final count =
        AIEndpointsDao.cached.fold<int>(0, (sum, e) => sum + e.models.length);
    if (count == 0) return UiText.t('还没有配置模型', 'No model configured');
    final selectedId =
        SettingsDao.getCached('aiSelectedModelId') as String?;
    String selectedName = '';
    for (final e in AIEndpointsDao.cached) {
      for (final m in e.models) {
        if (m.id == selectedId) selectedName = m.name;
      }
    }
    return selectedName.isNotEmpty
        ? UiText.t('$count 个 · 当前 $selectedName', '$count · using $selectedName')
        : UiText.t('$count 个已配置', '$count configured');
  }

  static String _agentSubtitle() {
    final stepsRaw = SettingsDao.getCached('agentMaxSteps');
    final steps = stepsRaw is num ? stepsRaw.toInt() : 0;
    final timeoutRaw = SettingsDao.getCached('agentAiTimeoutSeconds');
    final timeout = timeoutRaw is num ? timeoutRaw.toInt() : 120;
    // maxSteps = 0 在引擎里的含义是「不限」，写成「最大 0 步」像没初始化。
    return steps == 0
        ? UiText.t('步数不限 · 超时 ${timeout}s', 'Unlimited steps · ${timeout}s timeout')
        : UiText.t('最大 $steps 步 · 超时 ${timeout}s', '$steps steps · ${timeout}s timeout');
  }

  static String _webSearchSubtitle() {
    final web = WebSearchConfig.load();
    return web.enabled
        ? UiText.t('已开启 · ${web.enabledCount} 个后端可用',
            'On · ${web.enabledCount} backends')
        : UiText.t('已关闭 · AI 只靠本地上下文', 'Off · AI uses local context only');
  }

  static String _securitySubtitle() {
    final appLock =
        SettingsDao.getCached('appLockEnabled', defaultValue: false) == true;
    return appLock
        ? UiText.t('应用锁已开启 · 高危命令二次确认',
            'App lock on · dangerous commands confirmed')
        : UiText.t('应用锁未开启 · 高危命令二次确认',
            'App lock off · dangerous commands confirmed');
  }

  static String _mcpSubtitle() {
    final mcp = McpManager.instance;
    if (mcp.configs.isEmpty) return UiText.t('还没有服务器', 'No server yet');
    return UiText.t(
      '${mcp.connectedCount}/${mcp.configs.length} 已连接 · ${mcp.exposedToolCount} 个工具',
      '${mcp.connectedCount}/${mcp.configs.length} connected · ${mcp.exposedToolCount} tools',
    );
  }

  static String _rulesSubtitle() {
    final count = KnowledgeRulesDao.cached.length;
    return count == 0
        ? UiText.t('还没有规则', 'No rule yet')
        : UiText.count(
            count, '条 · 注入 AI 上下文', 'rules · injected into the AI context');
  }

  static String _notificationSubtitle() {
    final notify = NotificationService.config;
    if (!notify.enabled) return UiText.t('未开启', 'Off');
    if (notify.webhookUrl.trim().isEmpty) {
      return UiText.t('已开启 · 缺 Webhook 地址，发不出去',
          'On · no webhook URL, nothing is sent');
    }
    return notify.trigger == 'always'
        ? UiText.t('已开启 · 每次任务都提醒', 'On · every run')
        : UiText.t('已开启 · 仅失败时提醒', 'On · failures only');
  }
}

/// 抽屉与整页共用的分组顺序。
///
/// 顺序是「上手顺序」而不是「功能分类」：安全（应用锁、高危确认）是运维用户
/// 第一周就会碰的，所以排在 Agent 之后；联网搜索和内部规范属于「让 AI 更懂我」
/// 的调优项，是第二阶段的事；通知多数人永不触碰，压到最后。
const List<SettingsEntry> kSettingsEntries = [
  SettingsEntry(id: 'appearance', title: '外观', route: '/settings/appearance'),
  SettingsEntry(id: 'ai', title: 'AI 模型', route: '/settings/ai'),
  SettingsEntry(id: 'agent', title: 'Agent', route: '/settings/agent'),
  SettingsEntry(id: 'security', title: '安全', route: '/settings/security'),
  SettingsEntry(id: 'mcp', title: 'MCP 服务器', route: '/settings/mcp'),
  SettingsEntry(
      id: 'web_search', title: '联网搜索', route: '/settings/web_search'),
  SettingsEntry(
      id: 'knowledge_rules',
      title: '内部规范',
      route: '/settings/knowledge_rules'),
  SettingsEntry(
      id: 'notification', title: '通知', route: '/settings/notification'),
];

/// 设置页里的「管理类」入口：不是开关，点进去是独立的 CRUD 页面。
///
/// 和 [kSettingsEntries] 分开是因为交互不同 —— 上面那组点开是就地控件
/// （向下箭头），这组点进去是另一个页面（向右箭头）。混在一起用户没法
/// 预判点下去会发生什么。
class SettingsShortcut {
  const SettingsShortcut({
    required this.id,
    required this.title,
    required this.route,
    required this.subtitle,
  });

  final String id;
  final String title;
  final String route;
  final String subtitle;
}

List<SettingsShortcut> settingsShortcuts() {
  return [
    SettingsShortcut(
      id: 'hosts',
      title: UiText.t('主机', 'Hosts'),
      route: '/hosts',
      subtitle: UiText.count(HostsDao.cached.length, '台已保存', 'saved'),
    ),
    SettingsShortcut(
      id: 'snippets',
      title: UiText.t('快捷命令', 'Snippets'),
      route: '/snippets',
      subtitle: UiText.t('带变量的命令模板', 'Command templates with variables'),
    ),
    SettingsShortcut(
      id: 'runbooks',
      title: UiText.t('运维工作流', 'Runbooks'),
      route: '/runbooks',
      subtitle: UiText.t('多步骤操作清单', 'Multi-step procedures'),
    ),
    SettingsShortcut(
      id: 'audit-log',
      title: UiText.t('审计日志', 'Audit log'),
      route: '/audit-log',
      subtitle: UiText.t('每条命令的来源与结果', 'Origin and result of every command'),
    ),
    SettingsShortcut(
      id: 'change-records',
      title: UiText.t('变更台账', 'Change records'),
      route: '/change-records',
      subtitle: UiText.t('谁在什么时候改了什么', 'Who changed what, when'),
    ),
    SettingsShortcut(
      id: 'change-window',
      title: UiText.t('变更窗口', 'Change window'),
      route: '/change-window',
      subtitle: UiText.t('限制允许执行改动的时间段', 'Restrict when changes may run'),
    ),
  ];
}
