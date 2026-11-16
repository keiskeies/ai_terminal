import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/settings_catalog.dart';

/// 抽屉和整页设置此前各维护一份分组：抽屉 8 项、整页 17 项，同一个开关在
/// 两处措辞不同，加一项要改两个地方，漏一个就出现「这里能看到、那里看不到」。
/// 这组测试盯的是单一数据源的完整性。
void main() {
  test('分组 id 唯一，路由严格等于 /settings/<id>', () {
    final ids = kSettingsEntries.map((e) => e.id).toList();
    expect(ids.toSet().length, ids.length,
        reason: 'id 重复会让抽屉的折叠状态互相串台');

    for (final entry in kSettingsEntries) {
      expect(entry.route, '/settings/${entry.id}');
    }
  });

  test('分组顺序按上手顺序：外观 → AI → Agent → 安全 → MCP → 联网 → 规范 → 通知', () {
    // 顺序按「用户第几周会碰它」排，不按功能分类排：
    // 安全（应用锁、高危确认）是运维用户第一周就要碰的，所以排在 Agent 之后；
    // 联网搜索和内部规范是「让 AI 更懂我」的调优项，属于第二阶段；通知压在最后。
    // 这条断言把顺序固定下来，避免以后随手插队。
    expect(
      kSettingsEntries.map((e) => e.id).toList(),
      const [
        'appearance',
        'ai',
        'agent',
        'security',
        'mcp',
        'web_search',
        'knowledge_rules',
        'notification',
      ],
    );
  });

  test('每组的标题和副标题都不为空', () {
    for (final entry in kSettingsEntries) {
      expect(entry.title.trim(), isNotEmpty, reason: '${entry.id} 缺标题');
      // 副标题是状态读数；数据源为空时也要给「还没有…」而不是空白。
      expect(entry.subtitle.trim(), isNotEmpty, reason: '${entry.id} 缺副标题');
    }
  });

  test('管理区入口的都是独立页面，不是就地开关', () {
    final shortcuts = settingsShortcuts();
    expect(shortcuts, isNotEmpty);
    for (final s in shortcuts) {
      expect(s.route.startsWith('/'), isTrue);
      expect(s.title.trim(), isNotEmpty);
      // 管理区是跳转式卡片，副标题描述「里面装什么」，同样不许空白。
      expect(s.subtitle.trim(), isNotEmpty);
    }
  });
}
