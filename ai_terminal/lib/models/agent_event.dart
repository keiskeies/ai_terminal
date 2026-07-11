import 'package:hive/hive.dart';

part 'agent_event.g.dart';

/// Agent 事件类型枚举
///
/// 用于结构化渲染 Agent 的输出：思考、命令、结果、询问、完成、普通文本。
/// 每种事件对应一个独立的 UI 卡片，避免把所有内容混在一个字符串里。
@HiveType(typeId: 20)
enum AgentEventType {
  @HiveField(0)
  thought, // 思考文本
  @HiveField(1)
  command, // 命令（待执行或已执行）
  @HiveField(2)
  result, // 命令执行结果
  @HiveField(3)
  ask, // 询问用户选择
  @HiveField(4)
  finish, // 任务完成
  @HiveField(5)
  text, // 普通文本（非 ReAct 格式）
  @HiveField(6)
  info, // 状态提示（🚀 开始、⏳ 继续执行等）
}

/// Agent 结构化事件基类
///
/// 设计要点：
/// - 每个事件有唯一 id，便于流式更新时定位
/// - 命令事件有 commandId，结果事件通过 commandId 关联到对应命令
/// - 持久化时整个事件列表存到 Conversation.messages（用 Hive 适配器）
@HiveType(typeId: 21)
class AgentEvent extends HiveObject {
  @HiveField(0)
  late String id;

  @HiveField(1)
  late AgentEventType type;

  @HiveField(2)
  late DateTime timestamp;

  /// 文本内容（thought/text/info 用）
  @HiveField(3)
  String? text;

  /// 命令内容（command/result 用）
  @HiveField(4)
  String? command;

  /// 命令关联 id（result 用，指向对应 command 的 id）
  @HiveField(5)
  String? commandId;

  /// 命令是否危险（command 用）
  @HiveField(6)
  bool? dangerous;

  /// 命令是否被安全系统拦截（command 用）
  @HiveField(7)
  bool? blocked;

  /// 执行是否成功（result 用）
  @HiveField(8)
  bool? success;

  /// 命令输出（result 用）
  @HiveField(9)
  String? output;

  /// 错误信息（result 用）
  @HiveField(10)
  String? error;

  /// 选项列表（ask 用）
  @HiveField(11)
  List<String>? options;

  /// 询问的问题文本（ask 用）
  @HiveField(12)
  String? question;

  /// 完成摘要（finish 用）
  @HiveField(13)
  String? summary;

  /// 事件是否已完成流式接收（用于流式渲染判断）
  @HiveField(14)
  bool isStreaming = false;

  AgentEvent();

  // ═══════════════════════════════════════════
  // 工厂构造：便捷创建各类事件
  // ═══════════════════════════════════════════

  AgentEvent.thought(this.text, {String? id})
      : id = id ?? _genId(),
        type = AgentEventType.thought,
        timestamp = DateTime.now();

  AgentEvent.command(this.command, {String? id, this.dangerous, this.blocked})
      : id = id ?? _genId(),
        type = AgentEventType.command,
        timestamp = DateTime.now();

  AgentEvent.result({
    required this.commandId,
    required this.success,
    this.output,
    this.error,
    this.command,
  })  : id = _genId(),
        type = AgentEventType.result,
        timestamp = DateTime.now();

  AgentEvent.ask(this.question, this.options, {String? id})
      : id = id ?? _genId(),
        type = AgentEventType.ask,
        timestamp = DateTime.now();

  AgentEvent.finish({this.summary, String? id})
      : id = id ?? _genId(),
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
