import 'host_execution_result.dart';
import 'operation_report.dart';
import 'plan_step.dart';

/// Agent 事件类型枚举
///
/// 用于结构化渲染 Agent 的输出：思考、命令、结果、询问、完成、普通文本。
/// 每种事件对应一个独立的 UI 卡片，避免把所有内容混在一个字符串里。
enum AgentEventType {
  thought, // 思考文本
  command, // 命令（待执行或已执行）
  result, // 命令执行结果
  ask, // 询问用户选择
  finish, // 任务完成
  text, // 普通文本（非 ReAct 格式）
  info, // 状态提示（🚀 开始、⏳ 继续执行等）
  report, // 操作单报告（终态生成一次）
  plan, // 模型声明的执行计划
}

/// 任务终态（finish 事件用）
///
/// finish 事件不只代表成功：取消、失败、达到步数上限也会走 finish 路径
/// 以关闭 UI 的运行状态，因此必须显式区分终态，避免取消被显示成“任务完成”。
enum AgentFinishState {
  success,
  cancelled,
  failed,
  interrupted,
}

/// Agent 结构化事件基类
///
/// 设计要点：
/// - 每个事件有唯一 id，便于流式更新时定位
/// - 命令事件有 commandId，结果事件通过 commandId 关联到对应命令
/// - 持久化时整个事件列表存到 Conversation.messages
class AgentEvent {
  late String id;

  late AgentEventType type;

  late DateTime timestamp;

  /// 文本内容（thought/text/info 用）
  String? text;

  /// 命令内容（command/result 用）
  String? command;

  /// 命令关联 id（result 用，指向对应 command 的 id）
  String? commandId;

  /// 命令是否危险（command 用）
  bool? dangerous;

  /// 命令是否被安全系统拦截（command 用）
  bool? blocked;

  /// 执行是否成功（result 用）
  bool? success;

  /// 命令输出（result 用）
  String? output;

  /// 错误信息（result 用）
  String? error;

  /// 选项列表（ask 用）
  List<String>? options;

  /// 询问的问题文本（ask 用）
  String? question;

  /// 完成摘要（finish 用）
  String? summary;

  /// 任务终态（finish 用）；null 兼容旧数据，按成功处理
  AgentFinishState? finishState;

  /// 事件所属主机（command/result/report 用）
  String? hostId;

  /// 工具名（command/result 用），如 exec_command / file_write
  String? toolName;

  /// 风险等级（command 用）：safe / info / warn / blocked
  String? riskLevel;

  /// 命令耗时（result 用）
  int? durationMs;

  /// 退出码（result 用）
  int? exitCode;

  /// 失败类型（result 用）：timeout / disconnected / permissionDenied 等
  String? failureKind;

  /// 截断前输出字符数（result 用）
  int? outputTotalChars;

  /// 输出是否被截断（result 用）
  bool? outputTruncated;

  /// 原始输出尾部（result 用，最大 8KB）
  String? outputTail;

  /// 文件补丁行级改动（result 用）
  int? diffAdditions;
  int? diffDeletions;

  /// 操作单报告（report 用）
  OperationReport? operationReport;

  /// 执行计划（plan 用）
  List<PlanStep>? planSteps;

  /// 多主机批量结果（result 用）
  Map<String, HostExecutionResult>? hostResults;

  /// 事件是否已完成流式接收（用于流式渲染判断）
  bool isStreaming = false;

  AgentEvent();

  // ═══════════════════════════════════════════
  // 工厂构造：便捷创建各类事件
  // ═══════════════════════════════════════════

  AgentEvent.thought(this.text, {String? id})
      : id = id ?? _genId(),
        type = AgentEventType.thought,
        timestamp = DateTime.now();

  AgentEvent.command(
    this.command, {
    String? id,
    this.dangerous,
    this.blocked,
    this.hostId,
    this.toolName,
    this.riskLevel,
  })  : id = id ?? _genId(),
        type = AgentEventType.command,
        timestamp = DateTime.now();

  AgentEvent.result({
    required this.commandId,
    required this.success,
    this.output,
    this.error,
    this.command,
    this.hostId,
    this.toolName,
    this.durationMs,
    this.exitCode,
    this.failureKind,
    this.outputTotalChars,
    this.outputTruncated,
    this.outputTail,
    this.diffAdditions,
    this.diffDeletions,
    this.hostResults,
  })  : id = _genId(),
        type = AgentEventType.result,
        timestamp = DateTime.now();

  AgentEvent.ask(this.question, this.options, {String? id})
      : id = id ?? _genId(),
        type = AgentEventType.ask,
        timestamp = DateTime.now();

  AgentEvent.finish({
    this.summary,
    this.finishState = AgentFinishState.success,
    String? id,
  })  : id = id ?? _genId(),
        type = AgentEventType.finish,
        timestamp = DateTime.now();

  AgentEvent.text(this.text, {String? id})
      : id = id ?? _genId(),
        type = AgentEventType.text,
        timestamp = DateTime.now();

  AgentEvent.info(this.text, {String? id})
      : id = id ?? _genId(),
        type = AgentEventType.info,
        timestamp = DateTime.now();

  AgentEvent.report(this.operationReport, {String? id, this.hostId})
      : id = id ?? _genId(),
        type = AgentEventType.report,
        timestamp = DateTime.now();

  AgentEvent.plan(this.planSteps, {String? id, this.hostId})
      : id = id ?? _genId(),
        type = AgentEventType.plan,
        timestamp = DateTime.now();

  static String _genId() =>
      'evt_${DateTime.now().millisecondsSinceEpoch}_${_counter++}';
  static int _counter = 0;

  /// 是否为命令类事件
  bool get isCommand => type == AgentEventType.command;
  bool get isResult => type == AgentEventType.result;
  bool get isThought => type == AgentEventType.thought;
  bool get isAsk => type == AgentEventType.ask;
  bool get isFinish => type == AgentEventType.finish;
  bool get isText => type == AgentEventType.text;
  bool get isInfo => type == AgentEventType.info;
  bool get isReport => type == AgentEventType.report;
  bool get isPlan => type == AgentEventType.plan;

  /// 事件状态：待执行 / 执行中 / 成功 / 失败 / 被拦截
  String get statusLabel {
    switch (type) {
      case AgentEventType.command:
        if (blocked == true) return '已拦截';
        if (dangerous == true) return '需确认';
        return '待执行';
      case AgentEventType.result:
        if (success == true) return '成功';
        return '失败';
      default:
        return '';
    }
  }
}
