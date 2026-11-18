import 'ui_text.dart';
import '../services/change_window_service.dart';
import '../services/daos.dart';
import '../services/mcp_manager.dart';
import '../services/notification_service.dart';
import '../services/web_search_config.dart';
import '../core/l10n_holder.dart';

/// 设置分组的单一数据源。
///
/// 此前抽屉和整页各维护一份分组：抽屉 8 项、整页 17 项，同一个开关在两处
/// 措辞不同（「终端」vs「外观与体验」，「AI 模型」vs「AI 与智能」）。分组
/// 顺序与标题以设计稿第 07 节的 7 组为准；联网搜索是设计稿未列出、但功能
/// 独立存在的一项，排在 Agent 之后，让三组 AI 能力连续。
///
/// 副标题一律是「当前真实状态读数」，不是说明文案 —— 用户要能一眼看出自己
/// 现在到底是什么配置，而不是读一句「管理你的主机」。
///
/// 主题模式 / 终端配色 / 字号这三项外观设置放在顶栏外观浮层（边切边看的
/// 东西，一次点击到），不在这里出现。
class SettingsEntry {
  const SettingsEntry({
    required this.id,
    required this.title,
    required this.titleEn,
    required this.route,
  });

  /// 与 [SettingsInlinePanel] 的 settingsId、`/settings/<id>` 路由保持一致
  final String id;

  /// 中文标题；渲染请用 [label]。
  ///
  /// 这里保留字段而不是直接写 `UiText.t(...)`，是因为 `kSettingsEntries` 是
  /// `const` 列表 —— 构造期求值会把文案冻在编译时的语言上。
  final String title;

  /// 英文标题（其它语言回退英文）。
  final String titleEn;

  /// 跟随界面语言的标题。
  String get label => UiText.t(title, titleEn);

  /// 定位用的路由（`/settings/<id>`）。这条路由现在渲染的还是同一次 [SettingsPage]，
  /// 只是进来时把对应的组滚到视野里 —— 不再有独立的二级设置页面。
  final String route;

  /// 当前状态读数。数据源都在缓存里，读不到时给「还没有…」而不是空白。
  String get subtitle {
    switch (id) {
      case 'terminal':
        return _terminalSubtitle();
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

  /// 终端的「配一次不再动」项。主题/配色/字号已移到顶栏外观浮层，
  /// 不在设置里（也不在副标题里）。
  static String _terminalSubtitle() {
    final scrollback =
        (SettingsDao.getCached('terminalScrollback') as num?)?.toInt() ?? 10000;
    final log = SettingsDao.getCached('sessionLogEnabled') == true;
    final logLabel = log
        ? UiText.t('会话日志开', 'Log on')
        : UiText.t('会话日志关', 'Log off');
    final scrollLabel = switch (scrollback) {
      1000 => UiText.t('1 千行', '1k'),
      10000 => UiText.t('1 万行', '10k'),
      50000 => UiText.t('5 万行', '50k'),
      100000 => UiText.t('10 万行', '100k'),
      _ => '$scrollback',
    };
    return L10n.str.ut_7695e08c1e(scrollLabel, logLabel);
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
        ? L10n.str.ut_b003c911bd(count, selectedName)
        : L10n.str.ut_3f574ada1a(count);
  }

  static String _agentSubtitle() {
    final stepsRaw = SettingsDao.getCached('agentMaxSteps');
    final steps = stepsRaw is num ? stepsRaw.toInt() : 0;
    final timeoutRaw = SettingsDao.getCached('agentAiTimeoutSeconds');
    final timeout = timeoutRaw is num ? timeoutRaw.toInt() : 120;
    // maxSteps = 0 在引擎里的含义是「不限」，写成「最大 0 步」像没初始化。
    return steps == 0
        ? L10n.str.ut_664f79491a(timeout)
        : L10n.str.ut_a303a7b799(steps, timeout);
  }

  static String _webSearchSubtitle() {
    final web = WebSearchConfig.load();
    return web.enabled
        ? L10n.str.ut_9947165032(web.enabledCount)
        : UiText.t('已关闭 · AI 只靠本地上下文', 'Off · AI uses local context only');
  }

  static String _securitySubtitle() {
    final appLock =
        SettingsDao.getCached('appLockEnabled', defaultValue: false) == true;
    final lockLabel = appLock
        ? UiText.t('应用锁已开启', 'App lock on')
        : UiText.t('应用锁未开启', 'App lock off');
    final cw = ChangeWindowService.config;
    String pad(int h) => h.toString().padLeft(2, '0');
    final cwLabel = cw.enabled
        ? L10n.str.ut_94c3718c07(pad(cw.startHour), pad(cw.endHour))
        : UiText.t('安全时段未启用', 'Safe window off');
    return '$lockLabel · $cwLabel';
  }

  static String _mcpSubtitle() {
    final mcp = McpManager.instance;
    if (mcp.configs.isEmpty) return UiText.t('还没有服务器', 'No server yet');
    // 数字插值串必须用 ARB 模板键（L10n.str.*），不能走 UiText.t 的字面配对：
    // 「2/2 connected · 8 tools」这类带上数字的串在索引里没有对应条目，
    // ko/ja 等 12 种语言会回退英文。两块碎片（连接分数 + 工具数）分别
    // 用各自的 ARB 键组装。
    final connected = L10n.str.terminalOrchestratorConnected(
        mcp.connectedCount, mcp.configs.length);
    // 工具数用纯数量的模板键「{value} 个工具」；不能用 ut_8ecd2c14b5
    // （「已连接 · {value} 个工具」），否则和前面的分数拼接出
    // 「2/2 已连接 · 已连接 · 8 个工具」双份「已连接」。
    final tools = L10n.str.ut_7c5becde1e(mcp.exposedToolCount);
    return '$connected · $tools';
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
  SettingsEntry(
      id: 'terminal',
      title: '终端',
      titleEn: 'Terminal',
      route: '/settings/terminal'),
  SettingsEntry(
      id: 'ai',
      title: 'AI 模型',
      titleEn: 'AI model',
      route: '/settings/ai'),
  SettingsEntry(
      id: 'agent',
      title: 'Agent',
      titleEn: 'Agent',
      route: '/settings/agent'),
  SettingsEntry(
      id: 'security',
      title: '安全',
      titleEn: 'Security',
      route: '/settings/security'),
  SettingsEntry(
      id: 'mcp',
      title: 'MCP 服务器',
      titleEn: 'MCP servers',
      route: '/settings/mcp'),
  SettingsEntry(
      id: 'web_search',
      title: '联网搜索',
      titleEn: 'Web search',
      route: '/settings/web_search'),
  SettingsEntry(
      id: 'knowledge_rules',
      title: '内部规范',
      titleEn: 'House rules',
      route: '/settings/knowledge_rules'),
  SettingsEntry(
      id: 'notification',
      title: '通知',
      titleEn: 'Notifications',
      route: '/settings/notification'),
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
  ];
}
