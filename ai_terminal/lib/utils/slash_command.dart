// 斜杠命令解析：把输入拆成「命令名 + 原样参数」。
//
// 只承认命中已知命令名的输入为命令，这一点是硬要求：本输入框的目标文本经常
// 以远程路径开头（`/etc/nginx 目录权限`），若把首个 `/` 开头一律当命令，
// 用户就没法让 agent 处理绝对路径了。

/// 解析结果
class ParsedSlashCommand {
  /// 已小写化的命令名，如 `/goal`
  final String name;

  /// 命令名之后剩余的全部原文（去掉分隔空格，保留内部与原始大小写）。
  /// 没有参数时为 null。
  final String? rest;

  const ParsedSlashCommand({required this.name, this.rest});

  bool get hasRest => rest != null && rest!.isNotEmpty;
}

/// [knownNames] 为已注册命令名（带前导 `/`，大小写不敏感匹配）。
/// 不是命令时返回 null，调用方按普通文本发送。
ParsedSlashCommand? parseSlashCommand(
  String input, {
  required Iterable<String> knownNames,
}) {
  final trimmed = input.trim();
  if (!trimmed.startsWith('/')) return null;

  final firstSpace = trimmed.indexOf(' ');
  final head = firstSpace < 0 ? trimmed : trimmed.substring(0, firstSpace);
  final normalised = head.toLowerCase();

  for (final name in knownNames) {
    if (name.toLowerCase() != normalised) continue;
    if (firstSpace < 0) return ParsedSlashCommand(name: normalised);
    // 参数只去掉命令名与正文之间的空白，正文本身一律原样保留：
    // 目标描述里的大小写、空格、标点都是用户意图
    final rest = trimmed.substring(firstSpace + 1).trimLeft();
    return ParsedSlashCommand(
      name: normalised,
      rest: rest.isEmpty ? null : rest,
    );
  }
  return null;
}

/// `/model` 的名称匹配：先精确（忽略大小写），再子串。
///
/// 返回命中的原始名称列表；长度 > 1 表示歧义，由调用方列候选让用户选，
/// **不自动挑一个**——猜错等于把任务发到另一个计费与能力都不同的后端。
List<String> matchModelNames(Iterable<String> names, String wanted) {
  final needle = wanted.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  final exact = names.where((n) => n.toLowerCase() == needle).toList();
  if (exact.isNotEmpty) return exact;
  return names.where((n) => n.toLowerCase().contains(needle)).toList();
}

/// `/plan` 结束后是否要把只读模式拨回去。
///
/// 规则是"恢复原值"，不是"恢复 false"：本来就在只读模式的用户，跑一次 `/plan`
/// 不该被顺手解锁——那等于让一次临时操作改掉他的安全边界。
bool shouldRestoreReadOnly({
  required bool wasReadOnly,
  required bool nowReadOnly,
}) =>
    nowReadOnly != wasReadOnly;
const Set<String> kGoalSubCommands = {
  'pause',
  'resume',
  'edit',
  'done',
  'clear',
};

/// 一条 `/goal` 的解析结果。
class GoalCommand {
  /// 命中的子命令（已小写）；null 表示整句都是目标文本
  final String? sub;

  /// 子命令之后的内容；sub 为 null 时即整句目标（空串表示裸 `/goal`）
  final String objective;

  const GoalCommand({required this.sub, required this.objective});
}

/// 子命令与目标文本的消歧。
///
/// 规则：
/// - `edit` 是唯一带参数的子命令，后面整句是新目标；
/// - `pause` / `resume` / `done` / `clear` 不接受参数，**必须独占整句**才算指令；
///   后面还有正文就退回成目标文本——`/goal pause the server 卡住了` 是用户在
///   描述问题，不是下达指令。宁可把一句指令当成目标建出来（横幅看得见、
///   `/goal clear` 可撤销），也不该把用户输入的目标悄悄吞掉。
GoalCommand parseGoalCommand(String? rest) {
  final text = (rest ?? '').trim();
  if (text.isEmpty) {
    return const GoalCommand(sub: null, objective: '');
  }
  final firstSpace = text.indexOf(' ');
  final head = firstSpace < 0 ? text : text.substring(0, firstSpace);
  final lower = head.toLowerCase();
  if (!kGoalSubCommands.contains(lower)) {
    return GoalCommand(sub: null, objective: text);
  }
  final tail = firstSpace < 0 ? '' : text.substring(firstSpace + 1).trim();
  if (lower == 'edit') {
    return GoalCommand(sub: 'edit', objective: tail);
  }
  if (tail.isNotEmpty) {
    return GoalCommand(sub: null, objective: text);
  }
  return GoalCommand(sub: lower, objective: '');
}
