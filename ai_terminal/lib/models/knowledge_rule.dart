/// 内部规范的作用域
enum KnowledgeRuleScope {
  /// 对所有主机生效
  global,

  /// 对某个主机组生效（对应 HostConfig.group）
  group,

  /// 对单台主机生效
  host,
}

/// 用户自维护的内部运维规范条目
///
/// 与官方知识库（software_guides 结构化命令卡）不同，本条目以自然语言规则为主体，
/// 因为「统一走内网源」「不要改主配置」这类约定无法用命令字段表达，
/// 且 LLM 对自然语言约束的遵循度高于结构化字段。
class KnowledgeRule {
  late String id;

  /// 规则标题，用于列表展示与注入时的小标题
  late String title;

  /// 规则正文（自然语言，直接进 system prompt）
  late String content;

  /// 可选的参考命令，非空时随正文一并注入
  String commands = '';

  late KnowledgeRuleScope scope;

  /// scope == group 时的主机组名
  String? group;

  /// scope == host 时的主机 id
  String? hostId;

  /// true = 必须原样执行；false = 允许 AI 调整非关键参数
  late bool strict;

  late bool enabled;

  DateTime createdAt = DateTime.now();
  DateTime updatedAt = DateTime.now();

  KnowledgeRule();

  KnowledgeRule.create({
    required this.id,
    required this.title,
    required this.content,
    this.commands = '',
    this.scope = KnowledgeRuleScope.global,
    this.group,
    this.hostId,
    this.strict = true,
    this.enabled = true,
  })  : createdAt = DateTime.now(),
        updatedAt = DateTime.now();

  /// 该规则是否对给定主机生效
  ///
  /// [targetGroup] 由调用方按目标 hostId 反查 HostConfig.group 得到；
  /// 目标为空（本机终端/普通聊天）时只有全局规则生效。
  bool appliesTo({String? targetHostId, String? targetGroup}) {
    switch (scope) {
      case KnowledgeRuleScope.global:
        return true;
      case KnowledgeRuleScope.group:
        final g = group;
        if (g == null || g.isEmpty || targetGroup == null || targetGroup.isEmpty) {
          return false;
        }
        return g == targetGroup;
      case KnowledgeRuleScope.host:
        final h = hostId;
        if (h == null || h.isEmpty || targetHostId == null || targetHostId.isEmpty) {
          return false;
        }
        return h == targetHostId;
    }
  }

  /// 构建注入到 system prompt 的条目文本
  String buildInjectionText() {
    final buffer = StringBuffer();
    buffer.writeln('- ${strict ? '[严格] ' : '[建议] '}$title');
    for (final line in content.split('\n')) {
      if (line.trim().isEmpty) continue;
      buffer.writeln('  $line');
    }
    if (commands.trim().isNotEmpty) {
      buffer.writeln('  参考命令：');
      for (final line in commands.split('\n')) {
        if (line.trim().isEmpty) continue;
        buffer.writeln('    ${line.trim()}');
      }
    }
    return buffer.toString();
  }
}
