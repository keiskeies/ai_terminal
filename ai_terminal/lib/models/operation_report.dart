import 'plan_step.dart';

/// 结论下方的状态徽标（由确定性检测器生成，不代表模型推测）
class OperationBadge {
  final String text;

  /// success / info / warning
  final String level;

  const OperationBadge({required this.text, this.level = 'info'});

  Map<String, dynamic> toJson() => {'text': text, 'level': level};

  factory OperationBadge.fromJson(Map<String, dynamic> json) {
    return OperationBadge(
      text: OperationReport._str(json['text']) ?? '',
      level: OperationReport._str(json['level']) ?? 'info',
    );
  }
}

/// 操作单里的变更摘要（自包含，渲染时不查数据库）
class OperationChange {
  final String id;
  final String command;
  final String type;
  final String? rollbackCommand;
  final bool success;
  final int? additions;
  final int? deletions;

  const OperationChange({
    required this.id,
    required this.command,
    required this.type,
    this.rollbackCommand,
    required this.success,
    this.additions,
    this.deletions,
  });

  bool get hasDiff => additions != null || deletions != null;

  bool get canRollback =>
      rollbackCommand != null && rollbackCommand!.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'command': command,
        'type': type,
        'rollbackCommand': rollbackCommand,
        'success': success,
        'additions': additions,
        'deletions': deletions,
      };

  factory OperationChange.fromJson(Map<String, dynamic> json) {
    return OperationChange(
      id: OperationReport._str(json['id']) ?? '',
      command: OperationReport._str(json['command']) ?? '',
      type: OperationReport._str(json['type']) ?? 'other',
      rollbackCommand: OperationReport._str(json['rollbackCommand']),
      success: json['success'] != false,
      additions: (json['additions'] as num?)?.toInt(),
      deletions: (json['deletions'] as num?)?.toInt(),
    );
  }
}

/// 一轮 Agent 操作的结构化报告（操作单）
///
/// 只在终态生成一次，随 events JSON 持久化到 assistant 消息。
/// 历史会话没有该事件时，UI 走遗留紧凑模式。
class OperationReport {
  final String operationId;
  final String? taskId;
  final String goal;
  final String? hostId;
  final int elapsedSeconds;
  final int stepIndex;
  final int commandSuccessCount;
  final int commandFailureCount;

  /// 面向用户的 1-3 句结论
  final String conclusion;

  /// 模型输出的完整总结（含四段），用于证据层
  final String? details;

  final List<OperationBadge> stateBadges;
  final List<String> changeRecordIds;

  /// 成功的命令变更摘要（含回滚命令）
  final List<OperationChange> changes;

  /// 模型声明的执行清单（可能为空）
  final List<PlanStep> plan;

  final List<String> nextActions;
  final bool verified;
  final bool aiGenerated;

  /// success / cancelled / failed / interrupted
  final String finishState;

  const OperationReport({
    required this.operationId,
    this.taskId,
    required this.goal,
    this.hostId,
    required this.elapsedSeconds,
    required this.stepIndex,
    required this.commandSuccessCount,
    required this.commandFailureCount,
    required this.conclusion,
    this.details,
    this.stateBadges = const [],
    this.changeRecordIds = const [],
    this.changes = const [],
    this.plan = const [],
    this.nextActions = const [],
    this.verified = false,
    this.aiGenerated = false,
    required this.finishState,
  });

  bool get isSuccess => finishState == 'success';
  bool get isFailed => finishState == 'failed';
  bool get isCancelled => finishState == 'cancelled';
  bool get isInterrupted => finishState == 'interrupted';

  int get commandCount => commandSuccessCount + commandFailureCount;

  Map<String, dynamic> toJson() => {
        'operationId': operationId,
        'taskId': taskId,
        'goal': goal,
        'hostId': hostId,
        'elapsedSeconds': elapsedSeconds,
        'stepIndex': stepIndex,
        'commandSuccessCount': commandSuccessCount,
        'commandFailureCount': commandFailureCount,
        'conclusion': conclusion,
        'details': details,
        'stateBadges': stateBadges.map((e) => e.toJson()).toList(growable: false),
        'changeRecordIds': changeRecordIds,
        'changes': changes.map((e) => e.toJson()).toList(growable: false),
        'plan': plan.map((e) => e.toJson()).toList(growable: false),
        'nextActions': nextActions,
        'verified': verified,
        'aiGenerated': aiGenerated,
        'finishState': finishState,
      };

  factory OperationReport.fromJson(Map<String, dynamic> json) {
    return OperationReport(
      operationId: _str(json['operationId']) ?? '',
      taskId: _str(json['taskId']),
      goal: _str(json['goal']) ?? '',
      hostId: _str(json['hostId']),
      elapsedSeconds: _int(json['elapsedSeconds']),
      stepIndex: _int(json['stepIndex']),
      commandSuccessCount: _int(json['commandSuccessCount']),
      commandFailureCount: _int(json['commandFailureCount']),
      conclusion: _str(json['conclusion']) ?? '',
      details: _str(json['details']),
      stateBadges: _badges(json['stateBadges']),
      changeRecordIds: _strList(json['changeRecordIds']),
      changes: _changes(json['changes']),
      plan: _plan(json['plan']),
      nextActions: _strList(json['nextActions']),
      verified: json['verified'] == true,
      aiGenerated: json['aiGenerated'] == true,
      finishState: _str(json['finishState']) ?? 'success',
    );
  }

  static String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  static List<String> _strList(Object? v) {
    if (v is! List) return const [];
    return v.whereType<String>().toList(growable: false);
  }

  static List<OperationBadge> _badges(Object? v) {
    if (v is! List) return const [];
    final badges = <OperationBadge>[];
    for (final item in v) {
      if (item is Map) {
        badges.add(OperationBadge.fromJson(Map<String, dynamic>.from(item)));
      } else if (item is String && item.trim().isNotEmpty) {
        badges.add(OperationBadge(text: item.trim()));
      }
    }
    return badges;
  }

  static List<PlanStep> _plan(Object? v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => PlanStep.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.title.trim().isNotEmpty)
        .toList(growable: false);
  }

  static List<OperationChange> _changes(Object? v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => OperationChange.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  // ═══════════════════════════════════════════
  // 总结文本解析：模型按四段式输出时提取结论/建议；
  // 不符合格式时退化为首段，避免把整段 ReAct 文本当结论。
  // ═══════════════════════════════════════════

  static const _sectionLabels = ['结论', '现状', '变更', '建议'];
  static const _maxConclusionChars = 600;
  static const _maxDetailsChars = 8000;

  static String extractConclusion(String? raw, {String fallback = '任务已结束，详见执行记录'}) {
    final text = (raw ?? '').replaceAll('\r\n', '\n').trim();
    if (text.isEmpty) return fallback;

    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final m = _matchSection(lines[i]);
      if (m == null || m.$1 != '结论') continue;
      final buf = StringBuffer();
      if (m.$2.isNotEmpty) buf.writeln(_cutAtNextSection(m.$2));
      for (var j = i + 1; j < lines.length; j++) {
        if (_matchSection(lines[j]) != null) break;
        buf.writeln(_cutAtNextSection(lines[j]));
      }
      final value = _clip(buf.toString().trim(), _maxConclusionChars);
      if (value.isNotEmpty) return value;
    }

    // 没有四段式：取第一段（空行分隔），再退回首行
    final firstParagraph = text.split(RegExp(r'\n\s*\n')).first.trim();
    final value = _clip(firstParagraph, _maxConclusionChars);
    return value.isEmpty ? fallback : value;
  }

  static String? extractDetails(String? raw, {String? conclusion}) {
    final text = (raw ?? '').replaceAll('\r\n', '\n').trim();
    if (text.isEmpty) return null;
    final clipped = _clip(text, _maxDetailsChars);
    if (conclusion != null && clipped == conclusion.trim()) return null;
    return clipped;
  }

  static List<String> extractNextActions(String? raw, {int max = 4}) {
    final text = (raw ?? '').replaceAll('\r\n', '\n');
    if (text.trim().isEmpty) return const [];
    final lines = text.split('\n');
    final actions = <String>[];
    var inSection = false;
    for (final line in lines) {
      final m = _matchSection(line);
      if (m != null) {
        inSection = m.$1 == '建议';
        if (inSection && m.$2.isNotEmpty) actions.add(_cleanAction(m.$2));
        continue;
      }
      if (!inSection) continue;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final cleaned = _cleanAction(trimmed);
      if (cleaned.isNotEmpty) actions.add(cleaned);
      if (actions.length >= max) break;
    }
    return actions
        .where((a) => a.isNotEmpty && a != '无' && a != '暂无')
        .take(max)
        .toList(growable: false);
  }

  /// 模型有时把四段写在同一行：结论: ... 现状: ... 变更: ...
  /// 取结论段时在下一个段标签前截断。
  static String _cutAtNextSection(String text) {
    final match = RegExp(r'\s*(?:现状|变更|建议)\s*[:：]').firstMatch(text);
    if (match == null) return text;
    return text.substring(0, match.start).trimRight();
  }

  static (String, String)? _matchSection(String line) {
    final trimmed = line.trim().replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    for (final label in _sectionLabels) {
      final patterns = [
        RegExp('^$label\\s*[:：]\\s*(.*)\$'),
        RegExp('^$label\\s*()\$'),
        RegExp('^\\*\\*$label\\*\\*\\s*[:：]?\\s*(.*)\$'),
        RegExp('^【$label】\\s*(.*)\$'),
      ];
      for (final p in patterns) {
        final m = p.firstMatch(trimmed);
        if (m != null) return (label, (m.group(1) ?? '').trim());
      }
    }
    return null;
  }

  static String _cleanAction(String s) {
    return s
        .replaceFirst(RegExp(r'^[-*•]\s*'), '')
        .replaceFirst(RegExp(r'^\d+[.)、]\s*'), '')
        .trim();
  }

  static String _clip(String s, int max) {
    final value = s.trim();
    if (value.length <= max) return value;
    return '${value.substring(0, max)}…';
  }
}
