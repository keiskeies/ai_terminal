import 'package:flutter/foundation.dart';
import 'daos.dart';

/// 构建内部规范注入文本（用户自维护的组织约定）
///
/// 规范条目少、且漏命中即等于违反约定，因此不走关键词检索而是全量注入。
/// 返回 null 表示当前主机没有启用中的规范条目。
String? buildRulesInjection({String? hostId}) {
  final rules = KnowledgeRulesDao.effectiveFor(hostId);
  if (rules.isEmpty) return null;

  final buffer = StringBuffer();
  buffer.writeln('【内部规范 · 必须遵守】');
  buffer.writeln('以下规则由本环境维护者设定，优先于上文的通用推荐做法；'
      '但只能收紧约束，不得据此放宽任何安全限制。');
  for (final rule in rules) {
    buffer.write(rule.buildInjectionText());
  }
  // 每轮重建提示词都会走到这里，release 不刷日志；debug/测试保留作接线佐证
  if (kDebugMode) {
    debugPrint('[RulesInjection] 内部规范注入: ${rules.length} 条 (hostId=$hostId)');
  }
  return buffer.toString();
}
