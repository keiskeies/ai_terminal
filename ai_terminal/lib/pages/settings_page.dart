import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/constants.dart';
import '../core/settings_catalog.dart';
import '../core/ui_text.dart';
import '../l10n/app_localizations.dart';
import '../providers/agent_provider.dart';
import '../providers/app_providers.dart';
import '../providers/knowledge_rule_provider.dart';
import '../services/mcp_manager.dart';
import '../widgets/settings_extras.dart';
import '../widgets/settings_inline_panel.dart';
import '../widgets/settings_row_card.dart';

/// 设置中心（整页形态）。
///
/// **抽屉是设置的主载体**；这一页只是同一批组件的整页呈现（从聊天页、命令面板
/// 这类没有抽屉的位置进来时用）。两条路径共用 [SettingsInlinePanel] 和
/// [SettingsAboutRows]，不存在两套实现。
///
/// 编辑动作一律就地：加端点、改 MCP 服务器、写规范都是本组内容换一屏，
/// 没有对话框，也没有第二个浮层。
///
/// 视觉全部走 [SettingsGroupCard]（设计稿第 07 节的 `.rowcard` 去掉折叠态）。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.initialGroup});

  /// 从别处（网格菜单、模型胶囊的「模型设置」）跳进来时，直接把这一组滚到
  /// 视野里。以前这些入口会打开一个独立页面，现在同一页定位，不再多一层。
  final String? initialGroup;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final Map<String, GlobalKey> _groupKeys = {
    for (final e in kSettingsEntries) e.id: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    final target = widget.initialGroup;
    if (target == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _groupKeys[target]?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: 0.04,
      );
    });
  }

  /// 一组设置的卡片：标题 + 状态读数 + 就地控件。
  Widget _groupCard(SettingsEntry entry) {
    return SettingsGroupCard(
      key: _groupKeys[entry.id],
      title: entry.title,
      subtitle: entry.subtitle,
      children: [
        // 改完值要立刻反映到标题行的读数上（字号、后端数、连接数……），
        // 所以 onChanged 里重建整页。
        SettingsInlinePanel(
          settingsId: entry.id,
          heavy: true,
          onChanged: () => setState(() {}),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    // 标题行的状态读数（模型数、规则条数、步数）来自这几个 provider。
    // 不 watch 的话，从别处改完配置再进设置页，标题还写着旧值。
    ref.watch(aiEndpointsProvider);
    ref.watch(knowledgeRulesProvider);
    ref.watch(agentProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(pStandard, 4, pStandard, 40),
            children: [
              for (final entry in kSettingsEntries) ...[
                // MCP 的配置由 manager 异步载入（启动后连服务器），不走 Riverpod，
                // 只 listen 它才能在「还没有服务器」和「2/2 已连接」之间正确切换。
                if (entry.id == 'mcp')
                  ListenableBuilder(
                    listenable: McpManager.instance,
                    builder: (context, _) => _groupCard(entry),
                  )
                else
                  _groupCard(entry),
                const SizedBox(height: kSettingsRowGap),
              ],

              const SizedBox(height: kSettingsGroupGap - kSettingsRowGap),

              SettingsSectionLabel(UiText.t('管理', 'Manage')),
              SettingsManageRows(
                onNavigate: (route) => context.push(route),
              ),

              const SizedBox(height: kSettingsGroupGap),

              SettingsSectionLabel(UiText.t('关于', 'About')),
              const SettingsAboutRows(),
            ],
          ),
        ),
      ),
    );
  }
}
