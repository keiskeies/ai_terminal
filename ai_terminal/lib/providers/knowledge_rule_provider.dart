import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/knowledge_rule.dart';
import '../services/daos.dart';

const _uuid = Uuid();

/// 导入结果：写入条数 + 因本机没有对应主机而跳过的条数
typedef KnowledgeRuleImportResult = ({int imported, int skippedUnknownHost});

/// 内部规范 Provider
final knowledgeRulesProvider =
    StateNotifierProvider<KnowledgeRuleNotifier, List<KnowledgeRule>>((ref) {
  return KnowledgeRuleNotifier();
});

class KnowledgeRuleNotifier extends StateNotifier<List<KnowledgeRule>> {
  KnowledgeRuleNotifier() : super([]) {
    reload();
  }

  /// 从 DAO 缓存刷新 state（按创建时间倒序，新条目在前）
  void reload() {
    final list = KnowledgeRulesDao.cached.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    state = list;
  }

  Future<void> addRule(KnowledgeRule rule) async {
    await KnowledgeRulesDao.upsert(rule);
    reload();
  }

  Future<void> updateRule(KnowledgeRule rule) async {
    rule.updatedAt = DateTime.now();
    await KnowledgeRulesDao.upsert(rule);
    reload();
  }

  Future<void> toggleEnabled(KnowledgeRule rule, bool enabled) async {
    rule.enabled = enabled;
    rule.updatedAt = DateTime.now();
    await KnowledgeRulesDao.upsert(rule);
    reload();
  }

  Future<void> deleteRule(String id) async {
    await KnowledgeRulesDao.delete(id);
    reload();
  }

  /// 导出为 JSON 文本（含主机 id，便于同机往返）
  String exportJson() {
    final list = state
        .map((r) => {
              'title': r.title,
              'content': r.content,
              if (r.commands.trim().isNotEmpty) 'commands': r.commands,
              'scope': r.scope.name,
              if (r.scope == KnowledgeRuleScope.group) 'group': r.group,
              if (r.scope == KnowledgeRuleScope.host) 'hostId': r.hostId,
              'strict': r.strict,
            })
        .toList();
    return const JsonEncoder.withIndent('  ').convert(list);
  }

  /// 从 JSON 文本导入
  ///
  /// 同标题同作用域的既有条目视为更新（覆盖内容），其余作为新增，
  /// 这样团队反复导入同一份共享规范不会产生重复条目。
  ///
  /// [knownHostIds] 是本机已有的主机 id 集合：命中则保留主机作用域，
  /// 未命中则跳过该条而不是降级成全局 —— 降级会把只属于某台机器的约定
  /// 放大到所有主机，比丢弃更危险。
  Future<KnowledgeRuleImportResult> importFromJson(
    String source, {
    Set<String> knownHostIds = const {},
  }) async {
    final decoded = jsonDecode(source);
    if (decoded is! List) {
      throw const FormatException('顶层结构必须是数组');
    }

    var imported = 0;
    var skipped = 0;
    // state 在整个循环期间不刷新，用本地副本承接本轮已写入的条目，
    // 否则同一次导入里重复的标题会各建一条而非覆盖
    final pending = state.toList();

    for (final item in decoded) {
      if (item is! Map) continue;
      final title = (item['title'] ?? '').toString().trim();
      final content = (item['content'] ?? '').toString().trim();
      if (title.isEmpty || content.isEmpty) continue;

      final scope = KnowledgeRuleScope.values.firstWhere(
        (s) => s.name == item['scope'],
        orElse: () => KnowledgeRuleScope.global,
      );
      final group = item['group']?.toString();
      final hostId = item['hostId']?.toString();
      if (scope == KnowledgeRuleScope.host &&
          (hostId == null || !knownHostIds.contains(hostId))) {
        skipped++;
        continue;
      }

      final idx = pending.indexWhere((r) =>
          r.title == title &&
          r.scope == scope &&
          r.group == group &&
          r.hostId == hostId);
      final KnowledgeRule rule;
      if (idx >= 0) {
        rule = pending[idx];
      } else {
        rule = KnowledgeRule.create(id: _uuid.v4(), title: title, content: content);
        pending.add(rule);
      }
      rule.title = title;
      rule.content = content;
      rule.commands = (item['commands'] ?? '').toString();
      rule.scope = scope;
      rule.group = scope == KnowledgeRuleScope.group ? group : null;
      rule.hostId = scope == KnowledgeRuleScope.host ? hostId : null;
      rule.strict = item['strict'] != false;
      rule.enabled = true;
      await KnowledgeRulesDao.upsert(rule);
      imported++;
    }

    reload();
    debugPrint('[KnowledgeRuleNotifier] 导入完成: $imported 条，跳过 $skipped 条未知主机规则');
    return (imported: imported, skippedUnknownHost: skipped);
  }
}
