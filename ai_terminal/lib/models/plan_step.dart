/// 模型声明的执行计划步骤
///
/// 计划只用于展示与追踪，不作为执行依据；真实执行仍由 ReAct 动作驱动。
enum PlanStepStatus {
  pending,
  inProgress,
  completed,
  failed,
  skipped,
}

class PlanStep {
  final String title;
  final PlanStepStatus status;
  final List<String> hostIds;
  final String? note;

  const PlanStep({
    required this.title,
    this.status = PlanStepStatus.pending,
    this.hostIds = const [],
    this.note,
  });

  bool get isDone =>
      status == PlanStepStatus.completed || status == PlanStepStatus.skipped;

  Map<String, dynamic> toJson() => {
        'title': title,
        'status': status.name,
        'hostIds': hostIds,
        if (note != null) 'note': note,
      };

  factory PlanStep.fromJson(Map<String, dynamic> json) {
    final title = json['title'];
    final rawStatus = json['status'];
    return PlanStep(
      title: title is String ? title : '',
      status: parseStatus(rawStatus is String ? rawStatus : null),
      hostIds: json['hostIds'] is List
          ? (json['hostIds'] as List).whereType<String>().toList(growable: false)
          : const [],
      note: json['note'] is String ? json['note'] as String : null,
    );
  }

  static PlanStepStatus parseStatus(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'inprogress':
      case 'in_progress':
      case 'in-progress':
      case 'current':
      case 'doing':
      case '进行中':
        return PlanStepStatus.inProgress;
      case 'completed':
      case 'complete':
      case 'done':
      case '完成':
      case '已完成':
        return PlanStepStatus.completed;
      case 'failed':
      case 'fail':
      case '失败':
        return PlanStepStatus.failed;
      case 'skipped':
      case 'skip':
      case '跳过':
        return PlanStepStatus.skipped;
      default:
        return PlanStepStatus.pending;
    }
  }
}
