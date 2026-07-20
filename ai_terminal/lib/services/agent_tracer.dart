import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'agent_logger.dart';

/// Agent 执行追踪事件类型
enum TraceEventType {
  taskStart,
  taskEnd,
  step,
  aiCallStart,
  aiCallEnd,
  commandStart,
  commandEnd,
  toolCall,
  ask,
  info,
  error,
  cancel,
}

/// Agent 执行追踪事件
///
/// 结构化记录每个任务/步骤的关键信息，便于事后分析失败原因、性能瓶颈、AI 行为。
/// 与 [agentLogger] 不同，trace 只记录结构化数据（不记录文本日志），
/// 落盘到 trace.ndjson 文件，便于后续用 jq / datadog 等工具分析。
class TraceEvent {
  final String taskId;
  final String? hostId;
  final TraceEventType type;
  final DateTime timestamp;
  final int? generation;
  final int? step;
  final Map<String, dynamic> payload;

  TraceEvent({
    required this.taskId,
    this.hostId,
    required this.type,
    DateTime? timestamp,
    this.generation,
    this.step,
    required this.payload,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'task_id': taskId,
        if (hostId != null) 'host_id': hostId,
        'type': type.name,
        'ts': timestamp.toIso8601String(),
        if (generation != null) 'gen': generation,
        if (step != null) 'step': step,
        if (payload.isNotEmpty) 'payload': payload,
      };

  String toNdjson() => jsonEncode(toJson());

  @override
  String toString() => '[${timestamp.toIso8601String()}] $type $payload';
}

/// 任务级 metrics 聚合
class TaskMetrics {
  final String taskId;
  final String goal;
  final DateTime startTime;
  DateTime? endTime;
  String status = 'running'; // running / completed / failed / cancelled

  int stepCount = 0;
  int aiCallCount = 0;
  int commandCount = 0;
  int commandSuccessCount = 0;
  int commandFailureCount = 0;
  int retryCount = 0; // _callAI 重试次数
  int tokenUsagePrompt = 0;
  int tokenUsageCompletion = 0;
  int noCommandRetryCount = 0;
  int fallbackModelUsed = 0;

  TaskMetrics({
    required this.taskId,
    required this.goal,
    required this.startTime,
  });

  Duration get duration =>
      endTime != null ? endTime!.difference(startTime) : Duration.zero;

  Map<String, dynamic> toJson() => {
        'task_id': taskId,
        'goal': goal,
        'start_time': startTime.toIso8601String(),
        if (endTime != null)
          'end_time': endTime!.toIso8601String(),
        'duration_seconds': duration.inSeconds,
        'status': status,
        'step_count': stepCount,
        'ai_call_count': aiCallCount,
        'command_count': commandCount,
        'command_success_count': commandSuccessCount,
        'command_failure_count': commandFailureCount,
        'retry_count': retryCount,
        'token_usage_prompt': tokenUsagePrompt,
        'token_usage_completion': tokenUsageCompletion,
        'token_usage_total': tokenUsagePrompt + tokenUsageCompletion,
        'no_command_retry_count': noCommandRetryCount,
        'fallback_model_used': fallbackModelUsed,
      };
}

/// Agent 执行追踪器
///
/// 单例：每个 AgentEngine 持有自己的 instance，但写入共享的 trace 文件。
/// 文件位置：应用支持目录/agent_traces/trace_YYYYMMDD.ndjson
/// 每个 trace 事件一行（NDJSON），便于流式追加和工具解析。
class AgentTracer {
  static final AgentTracer instance = AgentTracer._();

  AgentTracer._();

  File? _traceFile;
  bool _disabled = false;

  /// 当前任务的 metrics（按 taskId 索引）
  /// 一个时刻只有一个活跃任务，但保留 map 便于异步延迟事件归属
  final Map<String, TaskMetrics> _activeMetrics = {};

  /// 启用/禁用（测试环境可禁用避免文件污染）
  void setDisabled(bool disabled) {
    _disabled = disabled;
  }

  /// 初始化 trace 文件路径（懒初始化）
  Future<void> _ensureFile() async {
    if (_traceFile != null || _disabled) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final traceDir = Directory('${dir.path}/agent_traces');
      if (!traceDir.existsSync()) {
        traceDir.createSync(recursive: true);
      }
      final today = DateTime.now();
      final dateStr =
          '${today.year}${today.month.toString().padLeft(2, '0')}${today.day.toString().padLeft(2, '0')}';
      _traceFile = File('${traceDir.path}/trace_$dateStr.ndjson');
    } catch (e) {
      agentLogger.warn('Tracer', '初始化 trace 文件失败: $e');
      _disabled = true;
    }
  }

  /// 记录一个 trace 事件
  Future<void> emit(TraceEvent event) async {
    if (_disabled) return;
    try {
      await _ensureFile();
      if (_traceFile == null) return;
      // 异步追加写入，不阻塞主流程
      _traceFile!.writeAsString('${event.toNdjson()}\n', mode: FileMode.append);
      // 同步更新 metrics
      _updateMetrics(event);
    } catch (e) {
      // trace 失败不影响主流程
      agentLogger.warn('Tracer', '写入 trace 失败: $e');
    }
  }

  /// 同步版本（用于 emit 后立即返回的场景）
  /// 注意：_disabled=true 时跳过文件写入，但 metrics 始终更新（便于测试）
  void emitSync(TraceEvent event) {
    // 始终更新 metrics，无论是否禁用文件写入
    _updateMetrics(event);
    if (_disabled) return;
    _ensureFile().then((_) {
      if (_traceFile == null) return;
      _traceFile!.writeAsString('${event.toNdjson()}\n', mode: FileMode.append);
    });
  }

  /// 更新 metrics 状态
  void _updateMetrics(TraceEvent event) {
    final metrics = _activeMetrics[event.taskId];
    if (metrics == null) return;

    switch (event.type) {
      case TraceEventType.taskStart:
        break;
      case TraceEventType.taskEnd:
      case TraceEventType.cancel:
        metrics.endTime = DateTime.now();
        metrics.status = event.payload['status'] as String? ?? event.type.name;
        // 不立即从 _activeMetrics 移除：允许延迟事件归属，由调用方显式清理
        break;
      case TraceEventType.step:
        metrics.stepCount = event.step ?? metrics.stepCount;
        break;
      case TraceEventType.aiCallStart:
        metrics.aiCallCount++;
        break;
      case TraceEventType.aiCallEnd:
        metrics.tokenUsagePrompt += event.payload['prompt_tokens'] as int? ?? 0;
        metrics.tokenUsageCompletion +=
            event.payload['completion_tokens'] as int? ?? 0;
        if (event.payload['retry'] == true) metrics.retryCount++;
        if (event.payload['fallback'] == true) metrics.fallbackModelUsed++;
        break;
      case TraceEventType.commandStart:
        metrics.commandCount++;
        break;
      case TraceEventType.commandEnd:
        if (event.payload['success'] == true) {
          metrics.commandSuccessCount++;
        } else {
          metrics.commandFailureCount++;
        }
        break;
      default:
        break;
    }
  }

  /// 注册新任务
  void startTask(String taskId, String goal, {String? hostId}) {
    final metrics = TaskMetrics(
      taskId: taskId,
      goal: goal,
      startTime: DateTime.now(),
    );
    _activeMetrics[taskId] = metrics;
    emitSync(TraceEvent(
      taskId: taskId,
      hostId: hostId,
      type: TraceEventType.taskStart,
      payload: {'goal': goal},
    ));
  }

  /// 结束任务
  void endTask(String taskId,
      {required String status, String? summary, String? hostId}) {
    final metrics = _activeMetrics[taskId];
    if (metrics != null) {
      metrics.endTime ??= DateTime.now();
      metrics.status = status;
    }
    emitSync(TraceEvent(
      taskId: taskId,
      hostId: hostId,
      type: TraceEventType.taskEnd,
      payload: {
        'status': status,
        if (summary != null) 'summary': summary,
        if (metrics != null) 'metrics': metrics.toJson(),
      },
    ));
    // 延迟移除：让异步事件有机会归属
    Future.delayed(const Duration(seconds: 30), () {
      _activeMetrics.remove(taskId);
    });
  }

  /// 获取任务 metrics
  TaskMetrics? getMetrics(String taskId) => _activeMetrics[taskId];

  /// 清理所有 metrics（测试用）
  void reset() {
    _activeMetrics.clear();
  }
}
