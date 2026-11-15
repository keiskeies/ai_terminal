import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/knowledge_rule.dart';
import 'package:ai_terminal/providers/knowledge_rule_provider.dart';
import 'package:ai_terminal/services/daos.dart';

/// 覆盖内部规范的作用域匹配与注入文本构建。
///
/// 只覆盖 DAO/provider 缓存层（DbInit 未初始化时降级为只写缓存，与
/// command_history_test.dart 同口径）；SQL 路径不在单测范围内。
void main() {
  KnowledgeRule rule({
    required String id,
    required String title,
    String content = '统一走内网镜像源',
    String commands = '',
    KnowledgeRuleScope scope = KnowledgeRuleScope.global,
    String? group,
    String? hostId,
    bool strict = true,
    bool enabled = true,
  }) {
    return KnowledgeRule()
      ..id = id
      ..title = title
      ..content = content
      ..commands = commands
      ..scope = scope
      ..group = group
      ..hostId = hostId
      ..strict = strict
      ..enabled = enabled;
  }

  setUp(() async {
    for (final r in KnowledgeRulesDao.cached.toList()) {
      await KnowledgeRulesDao.delete(r.id);
    }
  });

  group('作用域匹配', () {
    test('全局规则对任何主机生效，包括无主机上下文', () {
      final r = rule(id: 'g1', title: '全局约定');
      expect(r.appliesTo(), isTrue);
      expect(r.appliesTo(targetHostId: 'h1', targetGroup: '生产'), isTrue);
    });

    test('分组规则只对该分组主机生效', () {
      final r = rule(id: 'gr1', title: '生产约定', scope: KnowledgeRuleScope.group, group: '生产');
      expect(r.appliesTo(targetHostId: 'h1', targetGroup: '生产'), isTrue);
      expect(r.appliesTo(targetHostId: 'h2', targetGroup: '测试'), isFalse);
      // 本机终端/普通聊天没有分组上下文，分组规则不生效
      expect(r.appliesTo(), isFalse);
    });

    test('主机规则只对绑定的那台主机生效', () {
      final r = rule(id: 'h1r', title: 'db01 约定', scope: KnowledgeRuleScope.host, hostId: 'db01');
      expect(r.appliesTo(targetHostId: 'db01'), isTrue);
      expect(r.appliesTo(targetHostId: 'db02'), isFalse);
      expect(r.appliesTo(), isFalse);
    });

    test('分组规则缺分组名时不生效（避免空值意外匹配）', () {
      final r = rule(id: 'bad', title: '缺分组', scope: KnowledgeRuleScope.group);
      expect(r.appliesTo(targetHostId: 'h1', targetGroup: '生产'), isFalse);
    });
  });

  group('effectiveFor', () {
    test('禁用条目不注入', () async {
      await KnowledgeRulesDao.upsert(rule(id: 'on', title: '启用', enabled: true));
      await KnowledgeRulesDao.upsert(rule(id: 'off', title: '停用', enabled: false));
      expect(KnowledgeRulesDao.effectiveFor(null).map((r) => r.id), ['on']);
    });

    test('未知 hostId 只拿到全局条目', () async {
      await KnowledgeRulesDao.upsert(rule(id: 'g', title: '全局'));
      await KnowledgeRulesDao.upsert(rule(id: 'p', title: '生产', scope: KnowledgeRuleScope.group, group: '生产'));
      expect(KnowledgeRulesDao.effectiveFor('不存在的id').map((r) => r.id), ['g']);
    });
  });

  group('注入文本', () {
    test('严格/建议标记与正文缩进', () {
      final strict = rule(id: 'a', title: '走内网源', content: '不要用公网 apt 源');
      expect(strict.buildInjectionText(), contains('- [严格] 走内网源'));
      expect(strict.buildInjectionText(), contains('  不要用公网 apt 源'));

      final soft = rule(id: 'b', title: '平滑重载', content: '优先 reload', strict: false);
      expect(soft.buildInjectionText(), contains('- [建议] 平滑重载'));
    });

    test('有参考命令时才输出命令块', () {
      final withCmd = rule(id: 'a', title: 't', commands: 'apt update\napt upgrade -y');
      final text = withCmd.buildInjectionText();
      expect(text, contains('参考命令：'));
      expect(text, contains('    apt update'));

      final without = rule(id: 'b', title: 't');
      expect(without.buildInjectionText(), isNot(contains('参考命令')));
    });

    test('正文空行被丢弃', () {
      final r = rule(id: 'a', title: 't', content: '第一行\n\n第三行');
      final lines = r.buildInjectionText().trimRight().split('\n');
      expect(lines.length, 3);
    });
  });

  group('导入导出', () {
    test('导出的 JSON 再导入不新增条目', () async {
      final notifier = KnowledgeRuleNotifier();
      await notifier.addRule(rule(id: 'x1', title: '走内网源', content: '用 mirrors.corp'));
      final json = notifier.exportJson();

      final before = notifier.state.length;
      final result = await notifier.importFromJson(json);
      expect(result.imported, 1);
      expect(notifier.state.length, before);
      expect(notifier.state.first.content, '用 mirrors.corp');
    });

    test('同一次导入里重复标题只保留一条', () async {
      final notifier = KnowledgeRuleNotifier();
      const json = '[{"title":"A","content":"c1","scope":"global"},'
          '{"title":"A","content":"c2","scope":"global"}]';
      await notifier.importFromJson(json);
      expect(notifier.state.length, 1);
      expect(notifier.state.first.content, 'c2');
    });

    test('本机不存在的主机作用域条目被跳过，不放大成全局', () async {
      final notifier = KnowledgeRuleNotifier();
      const json = '[{"title":"A","content":"c","scope":"host","hostId":"remote-only"}]';
      final result = await notifier.importFromJson(json);
      expect(result.imported, 0);
      expect(result.skippedUnknownHost, 1);
      expect(notifier.state, isEmpty);
    });

    test('主机 id 在本机存在时保留主机作用域', () async {
      final notifier = KnowledgeRuleNotifier();
      const json = '[{"title":"A","content":"c","scope":"host","hostId":"h9"}]';
      final result = await notifier.importFromJson(json, knownHostIds: {'h9'});
      expect(result.imported, 1);
      expect(notifier.state.single.scope, KnowledgeRuleScope.host);
      expect(notifier.state.single.hostId, 'h9');
    });

    test('分组作用域原样保留', () async {
      final notifier = KnowledgeRuleNotifier();
      const json = '[{"title":"A","content":"c","scope":"group","group":"生产"}]';
      await notifier.importFromJson(json);
      expect(notifier.state.single.scope, KnowledgeRuleScope.group);
      expect(notifier.state.single.group, '生产');
    });

    test('缺少 title 或 content 的条目被跳过', () async {
      final notifier = KnowledgeRuleNotifier();
      const json = '[{"title":"","content":"c"},{"title":"B","content":""},{"title":"C","content":"ok"}]';
      final imported = await notifier.importFromJson(json);
      expect(imported.imported, 1);
      expect(notifier.state.single.title, 'C');
    });
  });
}
