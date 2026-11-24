import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_toast.dart';
import '../core/builtin_runbook_i18n.dart';
import '../core/constants.dart';
import '../core/settings_catalog.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/command_snippet.dart';
import '../models/host_config.dart';
import '../models/runbook.dart';
import '../pages/host_edit_page.dart';
import '../services/daos.dart';
import 'drawer_editors.dart';
import 'settings_extras.dart';
import 'settings_inline_panel.dart';
import 'settings_row_card.dart';
import '../core/l10n_holder.dart';

/// 应用唯一的功能抽屉。
///
/// **一个抽屉，内部分层。** 五个分区（主机 / 快捷命令 / 工作流 / 审计 / 设置）
/// 共用这一个浮层：顶部一排分区标签随时切换，不再需要「关掉 → 开菜单 → 再开
/// 另一个抽屉」。进入编辑（新增主机、写快捷命令、改工作流）是在抽屉里再下钻
/// 一层，顶栏出现 **← 返回**，退回列表；✕ 才是关掉整个抽屉。
///
/// 抽屉里**不 push 任何页面、不弹任何对话框**：编辑表单就长在这里。这样终端
/// 视口尺寸一寸不变，手机端也不会出现「抽屉上又压一个全屏页」。
///
/// 宽度：窗口 < 640 视为手机，直接占满屏宽；桌面端 min(600, 92%)。所有分区
/// 同一个宽度 —— 之前设置 480、其它 360，切分区时抽屉会跟着变宽窄，很跳。
class NavDrawer extends StatefulWidget {
  const NavDrawer({
    super.key,
    required this.section,
    this.initialGroup,
    this.onOpenHost,
    this.onRunSnippet,
    this.onRunRunbook,
  });

  /// 打开时展示的分区，见 [kDrawerSections]。
  final String section;

  /// 打开时就展开的设置组（例如从配色浮层的「更多」进设置，直接摊开外观组）。
  final String? initialGroup;

  /// 这三个动作是**终端侧**的能力：点主机要在终端里开标签，执行命令要有当前
  /// 会话。聊天页这类没有终端上下文的地方不传它们 —— 抽屉就只剩查看和编辑，
  /// 而不是给一个点了没反应（或要你再去别处）的按钮。
  ///
  /// 点主机卡片：开标签并关闭抽屉。
  final void Function(HostConfig host)? onOpenHost;
  final void Function(CommandSnippet)? onRunSnippet;
  final void Function(Runbook runbook)? onRunRunbook;

  static const sectionHosts = 'hosts';
  static const sectionSnippets = 'snippets';
  static const sectionRunbooks = 'runbooks';
  static const sectionAudit = 'audit';
  static const sectionSettings = 'settings';

  static const kDrawerSections = [
    sectionHosts,
    sectionSnippets,
    sectionRunbooks,
    sectionAudit,
    sectionSettings,
  ];

  static const titles = <String, String>{
    sectionHosts: '主机管理',
    sectionSnippets: '快捷命令',
    sectionRunbooks: '运维工作流',
    sectionAudit: '审计日志',
    sectionSettings: '设置',
  };

  /// [titles] 的英文对照；其它语言回退英文。
  static const titlesEn = <String, String>{
    // en 必须与 ARB 中 (zh,en) 对的 en 完全一致，否则 UiText.t 查不到索引、
    // 非中文界面回退成英文（历史 bug：'Server inventory' 应写 'Hosts'）。
    sectionHosts: 'Hosts',
    sectionSnippets: 'Snippets',
    sectionRunbooks: 'Runbooks',
    sectionAudit: 'Audit log',
    sectionSettings: 'Settings',
  };

  /// 顶部分区标签的文字（比标题短，五个标签要挤在一行）。
  static const shortTitles = <String, String>{
    sectionHosts: '主机',
    sectionSnippets: '命令',
    sectionRunbooks: '工作流',
    sectionAudit: '审计',
    sectionSettings: '设置',
  };

  /// [shortTitles] 的英文对照。
  static const shortTitlesEn = <String, String>{
    sectionHosts: 'Hosts',
    sectionSnippets: 'Commands',
    sectionRunbooks: 'Runbooks',
    sectionAudit: 'Audit',
    sectionSettings: 'Settings',
  };

  /// 跟随界面语言的分区标题。
  ///
  /// 用访问器而不是直接读 [titles]：两个表都是 `const`，在表里写
  /// `UiText.t(...)` 会把文案冻在编译时语言上（切语言不刷新）。
  static String titleOf(String section) =>
      UiText.t(titles[section] ?? '功能', titlesEn[section] ?? 'Features');

  /// 跟随界面语言的分区短标签。
  static String shortTitleOf(String section) => UiText.t(
      shortTitles[section] ?? section, shortTitlesEn[section] ?? section);

  /// 设置搜索索引：组 id → 该组可被搜到的词。
  ///
  /// 搜索框必须能搜到**组里的选项**，而不是只搜组名 —— 用户想改超时时间，
  /// 心里想的是「超时」，不知道它在「Agent」组里。组 id 本身也参与匹配，
  /// 这样英文用户能直接搜 `mcp` / `agent`。
  ///
  /// 新增设置项时记得往这里补词，否则新选项搜不到（这是软约束，不会被
  /// 编译器发现，所以写在该选项的实现旁边最容易记住）。
  ///
  /// 中英词都放：界面切到英文后，用户看到的是 `Theme` / `Timeout`，不会
  /// 想到去搜「主题」「超时」。组标题不在这里（由匹配函数直接拼入）。
  static const kSettingsSearchIndex = <String, List<String>>{
    'terminal': [
      '回滚缓冲', '缓冲', '行数', '自动会话日志', '会话日志',
      '终端快捷键', '快捷键',
      'scrollback', 'buffer', 'session log', 'keybinding',
      'shortcut',
      // 主题 / 配色 / 字号已移到顶栏外观浮层，不参与设置搜索；
      // 但旧用户可能按「外观」找，留个兜底词能落到本组而不是空态。
      '外观', 'appearance', 'theme', 'font', 'palette',
    ],
    'ai': [
      '模型',
      '当前使用的模型',
      '端点',
      '接口地址',
      'api key',
      '添加端点',
      '编辑端点',
      '删除端点',
      'model',
      'endpoint',
      'api',
      'key',
      'add',
      'edit',
      'delete',
    ],
    'agent': [
      '最大执行步数',
      '步数',
      '单步响应超时',
      '超时',
      '命令超时倍数',
      '自定义提示词',
      '提示词',
      'step',
      'steps',
      'timeout',
      'multiplier',
      'prompt',
      'system prompt',
    ],
    'security': [
      '应用锁',
      '生物识别',
      '面容',
      '指纹',
      '凭据存储',
      '高危命令',
      '二次确认',
      '清除本机数据',
      '清除数据',
      'app lock',
      'biometric',
      'face',
      'fingerprint',
      'credential',
      'dangerous',
      'confirm',
      'clear',
      'wipe',
      'reset',
    ],
    'mcp': [
      '服务器',
      '启用',
      '添加服务器',
      '工具',
      'mcp',
      'server',
      'enable',
      'add',
      'tool',
      'tools',
    ],
    'web_search': [
      '联网',
      '联网搜索',
      '后端',
      '返回条数',
      '搜索',
      'web',
      'search',
      'backend',
      'provider',
      'results',
    ],
    'knowledge_rules': [
      '规范',
      '规则',
      '添加规则',
      '内部规范',
      'rule',
      'rules',
      'convention',
      'add',
    ],
    'notification': [
      '提醒',
      '任务完成提醒',
      '什么时候提醒',
      'webhook',
      '通知',
      'notify',
      'notification',
      'reminder',
      'trigger',
      'always',
      'failure',
    ],
  };

  /// 覆盖式弹出。barrier 就是设计稿的 .scrim，点它即关。
  static Future<void> show(
    BuildContext context, {
    required String section,
    String? initialGroup,
    void Function(HostConfig host)? onOpenHost,
    void Function(CommandSnippet snippet)? onRunSnippet,
    void Function(Runbook runbook)? onRunRunbook,
  }) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: UiText.t('关闭抽屉', 'Close drawer'),
      barrierColor: Colors.black.withValues(alpha: 0.38),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, __, ___) => NavDrawer(
        section: section,
        initialGroup: initialGroup,
        onOpenHost: onOpenHost,
        onRunSnippet: onRunSnippet,
        onRunRunbook: onRunRunbook,
      ),
      // 设计稿 @keyframes atdp-slide：右侧滑入 24px + 淡入
      transitionBuilder: (context, animation, _, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOut);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.06, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<NavDrawer> createState() => _NavDrawerState();
}

/// 抽屉里的下钻类型：表单不是新页面，只是这一层的内容。
enum _FormKind { host, snippet, runbook }

class _Level {
  const _Level(this.section, {this.form, this.itemId});

  final String section;
  final _FormKind? form;
  final String? itemId;
}

class _NavDrawerState extends State<NavDrawer> {
  late final List<_Level> _stack = [_Level(widget.section)];
  final _search = TextEditingController();
  final _searchNode = FocusNode();
  final _closeNode = FocusNode();

  /// 展开详情的条目 id（快捷命令 / 工作流 / 设置共用一张折叠表）。
  final Set<String> _expanded = {};

  _Level get _level => _stack.last;
  bool get _canBack => _stack.length > 1;

  @override
  void initState() {
    super.initState();
    // 指定了初始组就先摊开（外观浮层的「更多」直接落到终端组）。
    final group = widget.initialGroup;
    if (group != null) _expanded.add(group);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusForLevel());
  }

  void _focusForLevel() {
    if (_level.form == null && _level.section == NavDrawer.sectionHosts) {
      _searchNode.requestFocus();
    } else {
      _closeNode.requestFocus();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchNode.dispose();
    _closeNode.dispose();
    super.dispose();
  }

  void _resetListState() {
    _expanded.clear();
    _searchExpanded.clear();
    _search.clear();
    // 「已修改」的展开状态跟着列表一起复位：换分区回来还停在「全展开」，
    // 首屏就被摘要吃掉了。
    _changedAll = false;
  }

  /// 顶部分区标签：平级切换，历史清空（标签不是下钻，不该积累返回层级）。
  void _selectSection(String section) {
    if (_level.section == section && _level.form == null) return;
    setState(() {
      _stack
        ..clear()
        ..add(_Level(section));
      _resetListState();
    });
    _focusForLevel();
  }

  void _openForm(_FormKind kind, {String? itemId}) {
    setState(() {
      _stack.add(_Level(_level.section, form: kind, itemId: itemId));
      _resetListState();
    });
    _focusForLevel();
  }

  void _back() {
    if (!_canBack) {
      _close();
      return;
    }
    setState(() {
      _stack.removeLast();
      _resetListState();
    });
    _focusForLevel();
  }

  void _close() => Navigator.of(context).pop();

  /// 表单保存成功：退回列表层，列表直接读 DAO 缓存，立即看到新条目。
  void _saved() => _back();

  void _toggle(String id) => setState(() {
        if (!_expanded.remove(id)) _expanded.add(id);
      });

  String get _title {
    final form = _level.form;
    if (form == null) return NavDrawer.titleOf(_level.section);
    final editing = _level.itemId != null;
    return switch (form) {
      _FormKind.host =>
        editing ? UiText.t('编辑主机', 'Edit host') : UiText.t('新增主机', 'New host'),
      _FormKind.snippet => editing
          ? UiText.t('编辑快捷命令', 'Edit snippet')
          : UiText.t('新建快捷命令', 'New snippet'),
      _FormKind.runbook => editing
          ? UiText.t('编辑工作流', 'Edit runbook')
          : UiText.t('新建工作流', 'New runbook'),
    };
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        // showGeneralDialog 的 pageBuilder 不给 Material 祖先：TextField /
        // TextButton 会直接抛「No Material widget found」。透明 Material 只
        // 套在面板自身外侧 —— 套在 Align 外面会把点空白关闭的 barrier 挡住。
        child: Material(
          type: MaterialType.transparency,
          child: PopScope(
            // 手机返回键 / 手势：先退一层，退无可退才关抽屉。
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _back();
            },
            child: Focus(
              // Esc：同返回键，先退层再关。
              autofocus: true,
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  _back();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: LayoutBuilder(builder: (context, c) {
                final tc = ThemeColors.of(context);
                // 手机（窄于 640）直接占满屏宽：360 的侧栏在手机上既难打字又难滚。
                //
                // 桌面上设置分区比其它分区宽 120px：AI 端点行是「名称 + 状态 +
                // 编辑/删除」，600 宽下名称已经开始省略号截断；配色卡和字号滑杆
                // 也需要横向空间。抽屉是覆盖层，不参与布局，终端尺寸不受影响。
                final maxW =
                    _level.section == NavDrawer.sectionSettings ? 720.0 : 600.0;
                final width = c.maxWidth < 640
                    ? c.maxWidth
                    : (c.maxWidth * 0.92).clamp(0.0, maxW);
                return AnimatedContainer(
                  // 切分区时宽度有 150ms 过渡：600 ↔ 720 硬跳会晃眼。
                  duration: animFast,
                  curve: Curves.easeOut,
                  width: width,
                  height: c.maxHeight,
                  decoration: BoxDecoration(
                    color: tc.cardElevated,
                    border: Border(left: BorderSide(color: tc.borderHover)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 40,
                        offset: const Offset(-16, 0),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _head(),
                      if (_level.form == null) _sectionTabs(),
                      Expanded(child: _body()),
                    ],
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  Widget _head() {
    final tc = ThemeColors.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(_canBack ? 8 : 16, 10, 10, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tc.hairline)),
      ),
      child: Row(
        children: [
          if (_canBack) ...[
            _IconBox30(
              icon: Icons.arrow_back_rounded,
              tooltip: UiText.t('返回上一层', 'Back'),
              onTap: _back,
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: fBody, color: tc.textMain),
            ),
          ),
          const SizedBox(width: 8),
          _IconBox30(
            node: _closeNode,
            icon: Icons.close_rounded,
            tooltip: UiText.t('关闭 (Esc)', 'Close (Esc)'),
            onTap: _close,
          ),
        ],
      ),
    );
  }

  /// 五个分区的平级切换。点一下就换内容，不关闭抽屉、不新开浮层。
  Widget _sectionTabs() {
    final tc = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tc.hairline)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final s in NavDrawer.kDrawerSections) ...[
              _tab(tc, s),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tab(ThemeColors tc, String section) {
    final selected = _level.section == section;
    return GestureDetector(
      onTap: () => _selectSection(section),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? tc.brandBg : tc.surface,
          borderRadius: BorderRadius.circular(rFull),
          border: Border.all(color: selected ? tc.brand : tc.border),
        ),
        child: Text(
          NavDrawer.shortTitleOf(section),
          style: TextStyle(
            fontSize: fSmall,
            color: selected ? tc.brand : tc.textSub,
            fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final tc = ThemeColors.of(context);
    final form = _level.form;
    if (form != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: _formBody(form),
      );
    }
    return switch (_level.section) {
      NavDrawer.sectionHosts => _hosts(tc),
      NavDrawer.sectionSnippets => _snippets(tc),
      NavDrawer.sectionRunbooks => _runbooks(tc),
      NavDrawer.sectionAudit => _audit(tc),
      _ => _settings(tc),
    };
  }

  Widget _formBody(_FormKind kind) {
    final id = _level.itemId;
    return switch (kind) {
      _FormKind.host => HostEditPage(
          hostId: id,
          embedded: true,
          onSaved: _saved,
          onCancel: _back,
        ),
      _FormKind.snippet => SnippetEditorForm(
          initial: id == null ? null : SnippetsDao.getCachedById(id),
          onCancel: _back,
          onSaved: (s) async {
            await SnippetsDao.upsert(s);
            _saved();
          },
        ),
      _FormKind.runbook => RunbookEditorForm(
          initial: id == null ? null : RunbooksDao.getCachedById(id),
          onCancel: _back,
          onSaved: (r) async {
            await RunbooksDao.upsert(r);
            _saved();
          },
        ),
    };
  }

  // ==================== 主机 ====================

  Widget _hosts(ThemeColors tc) {
    // 直接读 DAO 缓存：新增/编辑回来后 setState 就能刷出新列表，
    // 不依赖打开抽屉那一刻传进来的快照。
    final all = HostsDao.cached;
    final matched =
        _filter(all, (h) => '${h.name} ${h.host} ${h.username} ${h.group}');
    // 按 group 分组；LinkedHashMap 保留 DAO 原序
    final grouped = <String, List<HostConfig>>{};
    for (final h in matched) {
      grouped.putIfAbsent(h.group, () => []).add(h);
    }
    return _list([
      _searchField(tc, UiText.t('搜索名称 / IP / 分组', 'Search name / IP / group')),
      const SizedBox(height: 10),
      _addRow(
          tc, UiText.t('新增主机', 'New host'), () => _openForm(_FormKind.host)),
      const SizedBox(height: 12),
      for (final e in grouped.entries) ...[
        _groupHead(tc, e.key, e.value.length, all.length),
        for (final h in e.value) _hostCard(tc, h),
      ],
      if (matched.isEmpty) _empty(tc, UiText.t('没有匹配的主机', 'No matching host')),
    ]);
  }

  Widget _hostCard(ThemeColors tc, HostConfig h) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _Hover(
        builder: (hovering) => _Tap(
          onTap: () {
            _close();
            widget.onOpenHost?.call(h);
          },
          tooltip: L10n.str.ut_7c37c17c72(h.name),
          child: Container(
            padding: const EdgeInsets.fromLTRB(13, 10, 8, 10),
            decoration: BoxDecoration(
              color: hovering ? tc.surface : tc.card,
              borderRadius: BorderRadius.circular(rMedium),
              border: Border.all(
                  color: hovering ? tc.borderHover : tc.border, width: 1),
            ),
            child: Row(
              children: [
                // 3px 语义色条（.host-card::before）：分组色优先，否则品牌青
                Container(
                  width: 3,
                  height: 30,
                  decoration: BoxDecoration(
                    color: _groupAccent(tc, h),
                    borderRadius: const BorderRadius.all(Radius.circular(2)),
                  ),
                ),
                const SizedBox(width: 10),
                _avatar(tc, h.name),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(h.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: fSmall,
                              fontWeight: FontWeight.w500,
                              color: tc.textMain)),
                      const SizedBox(height: 3),
                      Text('${h.host}:${h.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: fMicro,
                              fontFamily: 'JetBrainsMono',
                              fontFamilyFallback: kMonoFontFallback,
                              color: tc.textSub)),
                    ],
                  ),
                ),
                _IconBox30(
                  icon: Icons.edit_outlined,
                  tooltip: UiText.t('编辑主机', 'Edit host'),
                  onTap: () => _openForm(_FormKind.host, itemId: h.id),
                ),
                const SizedBox(width: 2),
                Icon(Icons.chevron_right_rounded,
                    size: 14, color: tc.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _groupAccent(ThemeColors tc, HostConfig h) {
    final parsed = _parseHex(h.tagColor ?? '');
    return parsed ?? tc.brand;
  }

  Widget _avatar(ThemeColors tc, String name) {
    final parts =
        name.trim().split(RegExp(r'[\s\-_]')).where((p) => p.isNotEmpty);
    final initials = parts.isEmpty
        ? '?'
        : parts.take(2).map((p) => p[0].toUpperCase()).join();
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tc.brandBg,
        borderRadius: BorderRadius.circular(rSmall),
      ),
      child: Text(initials,
          style: TextStyle(
              fontSize: fMicro, fontWeight: FontWeight.w500, color: tc.brand)),
    );
  }

  // ==================== 快捷命令 ====================

  Widget _snippets(ThemeColors tc) {
    final matched =
        _filter(SnippetsDao.cached, (s) => '${s.name} ${s.command}');
    return _list([
      _searchField(tc, UiText.t('搜索名称 / 命令', 'Search name / command')),
      const SizedBox(height: 10),
      _addRow(tc, UiText.t('新建快捷命令', 'New snippet'),
          () => _openForm(_FormKind.snippet)),
      const SizedBox(height: 12),
      for (final s in matched)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _RowCard(
            tc: tc,
            title: s.name,
            subtitle: s.command,
            expanded: _expanded.contains(s.id),
            onToggle: () => _toggle(s.id),
            detail: [
              _monoBlock(tc, s.command),
              if (s.description != null && s.description!.isNotEmpty)
                _rowSub(tc, s.description!),
              _cardActions(tc, [
                // 没有终端上下文时不摆「执行」：点了没处可执行，等于骗一次点击。
                if (widget.onRunSnippet != null)
                  (
                    UiText.t('执行', 'Run'),
                    () {
                      _close();
                      widget.onRunSnippet!(s);
                    }
                  ),
                (
                  UiText.t('编辑', 'Edit'),
                  () => _openForm(_FormKind.snippet, itemId: s.id)
                ),
              ]),
            ],
          ),
        ),
      if (matched.isEmpty)
        _empty(tc, UiText.t('没有匹配的快捷命令', 'No matching snippet')),
    ]);
  }

  // ==================== 工作流 ====================

  Widget _runbooks(ThemeColors tc) {
    final matched = _filter(BuiltinRunbookI18n.localizeAll(RunbooksDao.cached),
        (r) => '${r.name} ${r.description ?? ''}');
    return _list([
      _searchField(tc, UiText.t('搜索名称 / 说明', 'Search name / description')),
      const SizedBox(height: 10),
      _addRow(tc, UiText.t('新建工作流', 'New runbook'),
          () => _openForm(_FormKind.runbook)),
      const SizedBox(height: 12),
      for (final rb in matched)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _RowCard(
            tc: tc,
            title: '${rb.icon} ${rb.name}',
            subtitle: rb.description ??
                (rb.type == RunbookType.agent
                    ? UiText.t('AI 执行', 'AI run')
                    : UiText.t('直接执行', 'Run directly')),
            expanded: _expanded.contains(rb.id),
            onToggle: () => _toggle(rb.id),
            detail: [
              _monoBlock(tc, rb.content),
              _rowSub(
                  tc,
                  '${L10n.str.ut_393e236ec2(rb.runCount)}'
                  '${rb.lastRunAt != null ? ' · ${UiText.t('最近', 'last')} ${_fmtLocal(rb.lastRunAt!)}' : ''}'),
              _cardActions(tc, [
                if (widget.onRunRunbook != null)
                  (
                    UiText.t('运行', 'Run'),
                    () {
                      _close();
                      widget.onRunRunbook!(rb);
                    }
                  ),
                (
                  UiText.t('编辑', 'Edit'),
                  () => _openForm(_FormKind.runbook, itemId: rb.id)
                ),
              ]),
            ],
          ),
        ),
      if (matched.isEmpty)
        _empty(tc, UiText.t('没有匹配的工作流', 'No matching runbook')),
    ]);
  }

  // ==================== 审计日志 ====================

  Widget _audit(ThemeColors tc) {
    final logs = AuditLogsDao.getCachedRecentLogs(limit: 60)
        .where((l) =>
            _query.isEmpty ||
            (l['command'] as String? ?? '').toLowerCase().contains(_query))
        .toList();
    return _list([
      _searchField(tc, UiText.t('搜索命令', 'Search commands')),
      const SizedBox(height: 10),
      _addRow(
        tc,
        L10n.str.ut_4dbb782799(logs.length),
        () => _exportAudit(logs),
        icon: Icons.copy_all_rounded,
      ),
      const SizedBox(height: 12),
      for (final l in logs) _auditRow(tc, l),
      if (logs.isEmpty) _empty(tc, UiText.t('还没有审计记录', 'No audit records yet')),
    ]);
  }

  /// 导出 = 复制到剪贴板。原来这功能只在整页审计里，抽屉里点「走整页」才能用；
  /// 现在就地做完，不为一个复制动作跳走。
  void _exportAudit(List<Map<String, dynamic>> logs) {
    if (logs.isEmpty) {
      showTopSnackBar(
        context,
        SnackBar(content: Text(UiText.t('没有可复制的记录', 'Nothing to copy'))),
      );
      return;
    }
    final buffer = StringBuffer()
      ..writeln(UiText.t('AI Terminal 审计日志', 'AI Terminal audit log'))
      ..writeln(DateTime.now().toIso8601String())
      ..writeln('---');
    for (final log in logs) {
      buffer.writeln('[${log['timestamp']}] host=${log['hostId']} '
          'level=${log['safetyLevel']} executed=${log['executed']}');
      buffer.writeln('  cmd: ${log['command']}');
      final out = log['output'] as String?;
      if (out != null && out.isNotEmpty) buffer.writeln('  out: $out');
      buffer.writeln('');
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    showTopSnackBar(
      context,
      SnackBar(
        content: Text(L10n.str.ut_afa890cf1c(logs.length)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _auditRow(ThemeColors tc, Map<String, dynamic> log) {
    final blocked = (log['safetyLevel'] as String?) == 'blocked';
    final ts = log['timestamp'] as String? ?? '';
    final id = 'audit:$ts:${log['command']}';
    final out = log['output'] as String? ?? '';
    final host = log['hostId'] as String? ?? '';
    // 审计表存的是 hostId（uuid），直接铺出来没人读得懂；按 id 换成主机名，
    // 查不到（主机已删）再退回原始 id。
    final hostLabel = host.isEmpty
        ? UiText.t('本机', 'This machine')
        : (HostsDao.getCachedById(host)?.name ?? host);
    return _RowCard(
      tc: tc,
      title: '${_hhmm(ts)}  ${log['command'] as String? ?? ''}',
      subtitle: '$hostLabel'
          '${out.isEmpty ? ' · ${UiText.t('无输出', 'no output')}' : ' · ${out.split('\n').first}'}',
      titleMono: true,
      trailing: _statusChip(tc,
          text: blocked ? UiText.t('拦截', 'Blocked') : UiText.t('放行', 'Allowed'),
          fg: blocked ? tc.error : tc.ok,
          bg: blocked ? tc.errorBg : tc.okBg),
      expanded: _expanded.contains(id),
      onToggle: () => _toggle(id),
      detail: [
        _rowSub(
            tc,
            '$host · $ts'
            '\n${log['safetyLevel'] ?? ''} · '
            '${(log['executed'] as bool? ?? false) ? UiText.t('已执行', 'executed') : UiText.t('未执行', 'not run')}'),
        if (out.isNotEmpty) _monoBlock(tc, out),
        _cardActions(tc, [
          (
            UiText.t('复制这条', 'Copy this'),
            () {
              Clipboard.setData(ClipboardData(
                  text: '[$ts] host=$host cmd: ${log['command']}'
                      '${out.isEmpty ? '' : '\nout: $out'}'));
              showTopSnackBar(
                context,
                SnackBar(
                  content: Text(UiText.t('已复制', 'Copied')),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          ),
        ]),
      ],
    );
  }

  // ==================== 设置 ====================

  Widget _settings(ThemeColors tc) {
    final query = _query;
    final searching = query.isNotEmpty;
    final matched = searching
        ? kSettingsEntries.where(_settingsGroupMatches).toList()
        : kSettingsEntries;
    final changed = searching ? const <_ChangedRow>[] : _changedSettings();

    return _list([
      // 设置是五个分区里唯一带「组里有几十个选项」的：不搜索就只能靠猜
      // 组名。其它四个分区早就有搜索框，这里补齐。
      _searchField(tc, UiText.t('搜索设置项', 'Search settings')),
      const SizedBox(height: kSettingsGroupGap - kSettingsRowGap),

      // 搜索命中为 0 时给空态，而不是把八组全藏掉、屏幕一片空白。
      if (searching && matched.isEmpty) _settingsEmptyState(tc, query),

      // 「已修改」：只列偏离默认值的项。全默认时整块不渲染 —— 零占位，
      // 不给一个永远空着的区块。搜索时也不渲染（搜索已经把范围缩小了）。
      //
      // 超过 5 项就折叠：这一区是「扫一眼知道自己动过什么」，铺满一屏反而
      // 把八组挤出首屏。折叠时明确写出还剩几项 —— 静默截断会让人以为
      // 自己只改过前面这几条。
      if (changed.isNotEmpty) ...[
        SettingsSectionLabel(UiText.t('已修改', 'Changed')),
        // 传入已算好的 changed，别再让 _shownChanged 自己算一遍：它内部若
        // 重新调 _changedSettings()，每帧就白跑两次 DAO 缓存读取。
        for (final row in _shownChanged(changed)) _changedRow(tc, row),
        if (changed.length > kChangedPreview)
          _moreChangedRow(tc, changed.length),
        const SizedBox(height: kSettingsGroupGap - kSettingsRowGap),
      ],

      // 分组顺序和副标题读数都来自 kSettingsEntries；抽屉与整页设置同源。
      // 每组就地改（heavy: true，连本地文件授权都在），展开区里没有弹窗。
      for (final entry in matched) ...[
        SettingsRowCard(
          key: _cardKey(entry.id),
          title: entry.label,
          subtitle: entry.subtitle,
          // 展开态 = 手动展开 ∪ 本次搜索命中。两者分开是为了让搜索不污染手动
          // 状态（详见 _onSettingsQuery）；点击只翻手动那一半，于是搜索态下
          // 也能收起卡片 —— 此前写死 `searching || ...` 时点击毫无反馈。
          expanded: _expanded.contains(entry.id) ||
              _searchExpanded.contains(entry.id),
          onToggle: () {
            // 收起搜索自动展开的组：同步把它从 _searchExpanded 摘掉，
            // 否则并集又把它顶回来，点一下看着没反应。
            if (_searchExpanded.contains(entry.id)) {
              setState(() => _searchExpanded.remove(entry.id));
            } else {
              _toggle(entry.id);
            }
          },
          detail: [
            SettingsInlinePanel(
              settingsId: entry.id,
              heavy: true,
              onChanged: () => setState(() {}),
            ),
          ],
        ),
        const SizedBox(height: kSettingsRowGap),
      ],

      if (!searching) ...[
        const SizedBox(height: kSettingsGroupGap - kSettingsRowGap),
        // 这里没有「管理」区：主机 / 命令 / 工作流 / 审计就在顶部标签上，
        // 同一个入口在同一屏出现两次才是真的乱。台账在溢出菜单里；
        // 安全时段的菜单项直达设置安全组，不另设页面。
        SettingsSectionLabel(UiText.t('关于', 'About')),
        const SettingsAboutRows(),
      ],
    ]);
  }

  /// 搜索词变化时调用：重新计算「本次搜索要摊开哪些组」。
  ///
  /// **不写进 `_expanded`**：那是用户手动展开的状态，要跨搜索保留。混在
  /// 一起的话，搜过的每个组都会被记成「用户展开过」，清空搜索后首屏全是
  /// 展开的组，八组反而要滚着找 —— 搜索把布局搞乱了，这是倒退。
  void _onSettingsQuery() {
    _searchExpanded.clear();
    if (_query.isNotEmpty) {
      for (final entry in kSettingsEntries) {
        if (_settingsGroupMatches(entry)) _searchExpanded.add(entry.id);
      }
    }
    setState(() {});
  }

  /// 搜索态下命中的组（与手动展开的 `_expanded` 分开维护）。
  final Set<String> _searchExpanded = {};

  /// 一组设置是否命中当前搜索词。
  ///
  /// 匹配三段：组标题、组 id、索引词。**标题必须进来** —— 用户看到的是
  /// 「终端」「安全」这几个字，最自然的输入就是照着念；索引表里漏掉标题时，
  /// 搜「终端」会得到空态，比没有搜索框更糟。
  ///
  /// id 参与匹配是为了英文 locale：索引词几乎都是中文，`theme` / `font`
  /// 这类英文词只能靠 id（`terminal` 还匹配不到 theme，见下方索引）。
  bool _settingsGroupMatches(SettingsEntry entry) {
    final hay = <String>[
      entry.title,
      entry.titleEn,
      entry.id,
      ...?NavDrawer.kSettingsSearchIndex[entry.id],
    ].join(' ').toLowerCase();
    return hay.contains(_query);
  }

  /// 每张组卡一个稳定的 GlobalKey，供「已修改」的行滚到对应组。
  /// 只给当前渲染的组建，不在全局状态里囤。
  ///
  /// 键的取值域是 kSettingsEntries 的 id（8 个），不是无限增长的 —— 抽屉
  /// 反复开关也不会有数组越界或泄漏风险。
  final Map<String, GlobalKey> _cardKeys = {};
  GlobalKey _cardKey(String id) => _cardKeys.putIfAbsent(id, GlobalKey.new);

  /// 「已修改」折叠后显示的行数。
  static const kChangedPreview = 5;

  /// 全部展开「已修改」，与 [kChangedPreview] 一起决定显示几行。
  bool _changedAll = false;

  /// 「已修改」当前实际渲染的行（折叠时只给前 [kChangedPreview] 条）。
  List<_ChangedRow> _shownChanged(List<_ChangedRow> all) {
    if (_changedAll || all.length <= kChangedPreview) return all;
    return all.take(kChangedPreview).toList(growable: false);
  }

  /// 「还有 N 项」：点一下把剩下的摊开。
  Widget _moreChangedRow(ThemeColors tc, int total) {
    final rest = total - kChangedPreview;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: _Tap(
        onTap: () => setState(() => _changedAll = !_changedAll),
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          child: Text(
            _changedAll
                ? UiText.t('收起', 'Show less')
                : L10n.str.ut_63f8cd8765(rest),
            style: TextStyle(fontSize: fMicro, color: tc.brand),
          ),
        ),
      ),
    );
  }

  Widget _settingsEmptyState(ThemeColors tc, String query) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            UiText.t('没有叫「$query」的设置', 'No setting matches "$query"'),
            style: TextStyle(fontSize: fSmall, color: tc.textSub),
          ),
          const SizedBox(height: 4),
          // 不要在这里指路 Ctrl+K：抽屉是独立 route，按键不会冒泡到页面级
          // 快捷键，用户照着按没反应，比不给提示更糟。改成告诉他能搜什么。
          Text(
            UiText.t(
              '可搜组名或选项名，例如：终端、模型、超时、MCP',
              'Search a group or option, e.g. terminal, model, timeout, MCP',
            ),
            style: TextStyle(fontSize: fMicro, color: tc.textMuted),
          ),
        ],
      ),
    );
  }

  /// 「已修改」的一行：左名称、右当前值，点一下跳到对应组。
  Widget _changedRow(ThemeColors tc, _ChangedRow row) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: _Tap(
        onTap: () {
          _expanded.add(row.groupId);
          setState(() {});
          // 下一帧再滚：这一帧刚把组展开，高度还没算出来。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final ctx = _cardKeys[row.groupId]?.currentContext;
            if (ctx == null) return;
            Scrollable.ensureVisible(ctx,
                duration: const Duration(milliseconds: 220), alignment: 0.1);
          });
        },
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: tc.hairline),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  row.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: fSmall, color: tc.textBody),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                row.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: fMicro, color: tc.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 与默认值不同的设置项。空列表 = 全默认 = 不渲染「已修改」区。
  ///
  /// 只列**能可靠判断默认值**的键。MCP 的全局开关存在 McpStore 里、默认又是
  /// 开启，混进来会让「已修改」在全新安装时报一条假记录 —— 宁可少列。
  List<_ChangedRow> _changedSettings() {
    final rows = <_ChangedRow>[];
    int i(String key, int fallback) =>
        (SettingsDao.getCached(key) as num?)?.toInt() ?? fallback;

    // 主题 / 配色 / 字号已移到顶栏外观浮层，不在设置里，也不在此列。
    // （它们不在设置里出现后，这里再列会变成「摘要里有、组里没有」的错位。）

    // 终端组：回滚缓冲
    final scrollback = i('terminalScrollback', 10000);
    if (scrollback != 10000) {
      final scrollLabel = switch (scrollback) {
        1000 => UiText.t('1 千行', '1k'),
        50000 => UiText.t('5 万行', '50k'),
        100000 => UiText.t('10 万行', '100k'),
        _ => '$scrollback',
      };
      rows.add(_ChangedRow(
          'terminal', UiText.t('回滚缓冲行数', 'Scrollback'), scrollLabel));
    }

    // 终端组：会话日志
    if (SettingsDao.getCached('sessionLogEnabled') == true) {
      rows.add(_ChangedRow('terminal', UiText.t('自动会话日志', 'Session log'),
          UiText.t('已开启', 'On')));
    }

    final steps = i('agentMaxSteps', 0);
    if (steps != 0) {
      rows.add(_ChangedRow('agent', UiText.t('最大执行步数', 'Max steps'), '$steps'));
    }

    final timeout = i('agentAiTimeoutSeconds', 120);
    if (timeout != 120) {
      rows.add(
          _ChangedRow('agent', UiText.t('单步响应超时', 'Timeout'), '${timeout}s'));
    }

    final multiplier =
        (SettingsDao.getCached('commandTimeoutMultiplier') as num?)?.toDouble();
    if (multiplier != null && multiplier != 1.0) {
      rows.add(_ChangedRow(
          'agent', UiText.t('命令超时倍数', 'Timeout x'), '${multiplier}x'));
    }

    if (SettingsDao.getCached('appLockEnabled', defaultValue: false) == true) {
      rows.add(_ChangedRow(
          'security', UiText.t('应用锁', 'App lock'), UiText.t('已开启', 'On')));
    }

    // 不在这里截断：显示几行由 _shownChanged 决定（折叠时在末尾给
    // 「还有 N 项」）。此处静默 take(6) 会让用户以为只改过这六条。
    return rows;
  }

  // ==================== 通用零件 ====================

  String get _query => _search.text.trim().toLowerCase();

  List<T> _filter<T>(List<T> items, String Function(T) text) {
    if (_query.isEmpty) return items;
    return items.where((e) => text(e).toLowerCase().contains(_query)).toList();
  }

  /// 列表统一留白。上下都比卡片自身的内边距再宽一档 —— 挤在一起时用户分不清
  /// 哪行属于哪张卡（尤其手机端，手指比鼠标粗）。
  Widget _list(List<Widget> children) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: children,
      );

  /// 列表上方的主操作：新增主机 / 新建命令 / 新建工作流 / 复制日志。
  /// 高度 40，手机上够得着；不再用底部那行「走整页」小字。
  Widget _addRow(ThemeColors tc, String label, VoidCallback onTap,
      {IconData icon = Icons.add_rounded}) {
    return _Hover(
      builder: (hovering) => _Tap(
        onTap: onTap,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: hovering ? tc.brandBg : tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: hovering ? tc.brand : tc.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: tc.brand),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: fSmall, color: tc.brand)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardActions(ThemeColors tc, List<(String, VoidCallback)> actions) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          for (final (label, onTap) in actions) ...[
            _MiniButton(tc: tc, label: label, onTap: onTap),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _searchField(ThemeColors tc, String hint) {
    OutlineInputBorder border(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(rSmall),
          borderSide: BorderSide(color: c),
        );
    // 有内容时尾部给一个 ✕：设置分区的搜索会改变列表结构（未命中的组直接
    // 消失），没有清空出口就只能一个字一个字退格。
    final hasText = _search.text.isNotEmpty;
    return SizedBox(
      height: 36,
      child: TextField(
        controller: _search,
        focusNode: _searchNode,
        // 设置分区：命中即展开（_onSettingsQuery）；其余四个分区只要重绘过滤结果。
        onChanged: (_) => _level.section == NavDrawer.sectionSettings
            ? _onSettingsQuery()
            : setState(() {}),
        style: TextStyle(fontSize: fSmall, color: tc.textMain),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(fontSize: fSmall, color: tc.textMuted),
          prefixIcon: Icon(Icons.search_rounded, size: 15, color: tc.textSub),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 32, minHeight: 32),
          suffixIcon: hasText
              ? GestureDetector(
                  onTap: () {
                    // 只清查询词与搜索展开态，**不动 `_expanded`**：五个分区
                    // 共用这个搜索框，主机/命令分区清空搜索时不该顺手收掉
                    // 用户已展开的详情。
                    setState(() {
                      _search.clear();
                      _searchExpanded.clear();
                    });
                    _searchNode.requestFocus();
                  },
                  child:
                      Icon(Icons.close_rounded, size: 15, color: tc.textMuted),
                )
              : null,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 32, minHeight: 32),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
          filled: true,
          fillColor: tc.surface,
          border: border(tc.border),
          enabledBorder: border(tc.border),
          focusedBorder: border(tc.brand),
        ),
      ),
    );
  }

  /// 分组名的展示文案（'默认' → 当前语言的 Default）。
  String groupLabel(String group) => UiText.hostGroup(group);

  Widget _groupHead(ThemeColors tc, String label, int count, int total) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Row(
        children: [
          Text(groupLabel(label),
              style: TextStyle(fontSize: fSmall, color: tc.textSub)),
          const SizedBox(width: 6),
          _countChip(tc, '$count'),
          const Spacer(),
          _countChip(tc, L10n.str.ut_2565b39f32(total)),
        ],
      ),
    );
  }

  Widget _countChip(ThemeColors tc, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(rFull),
        border: Border.all(color: tc.border),
      ),
      child: Text(text, style: TextStyle(fontSize: fMicro, color: tc.textSub)),
    );
  }

  Widget _statusChip(ThemeColors tc,
      {required String text, required Color fg, required Color bg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(rFull)),
      child: Text(text,
          style: TextStyle(
              fontSize: fMicro, fontWeight: FontWeight.w500, color: fg)),
    );
  }

  Widget _monoBlock(ThemeColors tc, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: tc.terminalBg,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.hairline),
      ),
      child: SelectableText(text,
          style: TextStyle(
              fontSize: fSmall,
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: kMonoFontFallback,
              height: 1.5,
              color: tc.textBody)),
    );
  }

  Widget _rowSub(ThemeColors tc, String text) =>
      Text(text, style: TextStyle(fontSize: fSmall, color: tc.textSub));

  Widget _empty(ThemeColors tc, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Center(
            child: Text(text,
                style: TextStyle(fontSize: fSmall, color: tc.textMuted))),
      );
}

/// 折叠卡（设计稿 .rowcard）：标题行 + 展开后的详情区与动作按钮。
class _RowCard extends StatelessWidget {
  const _RowCard({
    required this.tc,
    required this.title,
    required this.subtitle,
    required this.expanded,
    required this.onToggle,
    required this.detail,
    this.trailing,
    this.titleMono = false,
  });

  final ThemeColors tc;
  final String title;
  final String subtitle;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> detail;

  /// 标题行右侧的小标记（例如审计的「拦截 / 放行」）。折叠着也要看得见 ——
  /// 这条是不是被拦掉的，是扫列表时最先要判断的事。
  final Widget? trailing;

  /// 标题是命令时用等宽字体 —— 命令里 `l`/`1`、`0`/`O` 要能分清。
  final bool titleMono;

  @override
  Widget build(BuildContext context) {
    return _Hover(
      builder: (hovering) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: tc.card,
          borderRadius: BorderRadius.circular(rMedium),
          border: Border.all(color: tc.border, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Tap(
              onTap: onToggle,
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                color: hovering ? tc.surface : null,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: fSmall,
                                  fontWeight: FontWeight.w500,
                                  fontFamily:
                                      titleMono ? 'JetBrainsMono' : null,
                                  fontFamilyFallback:
                                      titleMono ? kMonoFontFallback : null,
                                  color: tc.textMain)),
                          const SizedBox(height: 3),
                          Text(subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: fMicro, color: tc.textSub)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (trailing != null) ...[
                      trailing!,
                      const SizedBox(width: 6),
                    ],
                    Icon(
                        expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 15,
                        color: tc.textMuted),
                  ],
                ),
              ),
            ),
            if (expanded)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: tc.hairline)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, w) in detail.indexed) ...[
                      if (i > 0) const SizedBox(height: 8),
                      w,
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton(
      {required this.tc, required this.label, required this.onTap});

  final ThemeColors tc;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Hover(
      builder: (hovering) => _Tap(
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hovering ? tc.brandBg : null,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: tc.brand),
          ),
          child:
              Text(label, style: TextStyle(fontSize: fSmall, color: tc.brand)),
        ),
      ),
    );
  }
}

/// 30×30 圆角图标按钮（设计稿 .drawer-close）。
class _IconBox30 extends StatelessWidget {
  const _IconBox30({
    this.node,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final FocusNode? node;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return _Hover(
      builder: (hovering) => _Tap(
        onTap: onTap,
        tooltip: tooltip,
        child: Focus(
          focusNode: node,
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(rSmall),
              border: Border.all(
                  color: hovering ? tc.border : Colors.transparent, width: 1),
            ),
            child: Icon(icon,
                size: 15, color: hovering ? tc.textMain : tc.textSub),
          ),
        ),
      ),
    );
  }
}

/// hover 态包装：抽屉是浮层，卡片自己画底色，不用 InkWell。
class _Hover extends StatefulWidget {
  const _Hover({required this.builder});

  final Widget Function(bool hovering) builder;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: widget.builder(_hovering),
    );
  }
}

class _Tap extends StatelessWidget {
  const _Tap({required this.onTap, required this.child, this.tooltip});

  final VoidCallback onTap;
  final Widget child;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final w = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: child,
    );
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

/// 「已修改」摘要区的一行：哪一组、叫什么、现在是什么值。
class _ChangedRow {
  const _ChangedRow(this.groupId, this.label, this.value);

  final String groupId;
  final String label;
  final String value;
}

Color? _parseHex(String raw) {
  var s = raw.trim();
  if (!s.startsWith('#')) return null;
  s = s.substring(1);
  if (s.length == 6) s = 'FF$s';
  if (s.length != 8) return null;
  final v = int.tryParse(s, radix: 16);
  return v == null ? null : Color(v);
}

String _hhmm(String? raw) {
  if (raw == null || raw.isEmpty) return '--:--';
  final t = DateTime.tryParse(raw);
  if (t == null) return raw.length >= 5 ? raw.substring(0, 5) : raw;
  final local = t.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String _fmtLocal(DateTime t) {
  final now = DateTime.now();
  final local = t.toLocal();
  final sameDay = local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  final hm = '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  return sameDay
      ? '${UiText.t('今天', 'Today')} $hm'
      : '${local.month}/${local.day} $hm';
}
