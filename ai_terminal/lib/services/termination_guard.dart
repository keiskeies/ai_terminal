import '../models/agent_event.dart';
import '../models/agent_model.dart';

/// 终态收口器（R5：唯一终态收口）。
///
/// 职责单一：把「status → report → finish → flush → tracer」这一组终态动作
/// 按固定顺序执行，包 try/finally，并支持入口代际检查。具体动作由引擎以
/// 闭包注入 —— Guard 本身不持有任何引擎实例字段，只做编排。
///
/// **必须每引擎一个实例，严禁 static**：幂等标志与代际读取闭包都是实例级
/// 状态，多 tab / 多 scope 各自独立，避免终态串台。
///
/// 顺序不变量（改动前请读 agent_engine.dart 的 _finishTask 注释）：
/// - status 先于 report/finish：UI 靠 status 退出 running 态
/// - report 先于 finish：消费方看到 finish 即停止渲染，report 必须更早
/// - finish 先于 flush：持久化要带上 finish 事件
/// - 清理放 finally：任一回调抛异常都不能跳过资源释放，否则 Completer 悬挂
class TerminationGuard {
  TerminationGuard({
    required this.hostId,
    required int Function() generation,
  }) : _generation = generation;

  /// 所属引擎的主机 id（用于日志/诊断）
  final String? hostId;

  final int Function() _generation;

  /// 同一引擎、同一代际的终态只收口一次；新任务代际变化后自动重新开放。
  bool _terminated = false;
  int _terminatedGeneration = -1;

  /// 是否已为当前代际收口过（供引擎查询，避免重复 emit）。
  bool get isTerminatedForCurrentGeneration {
    final gen = _generation();
    return _terminated && _terminatedGeneration == gen;
  }

  /// 执行终态收口。
  ///
  /// [status] 当前终态；[finishState] finish 事件携带的终态类型；
  /// [writeStatus] 写 status/phase/completedAt 并通知 provider；
  /// [emitReport] 构造并发出 operation report（幂等由引擎侧守卫）；
  /// [emitFinish] 发出 finish 事件；
  /// [flush] 把流式正文落盘（provider 侧已 flush 时可省略）；
  /// [endTracer] 结束 trace；
  /// [cleanup] 放 finally，释放 Completer/Timer/Token 等瞬态资源。
  ///
  /// [expectedGeneration] 非空时做代际检查：若与当前代际不符则整组动作不执行。
  /// 返回是否真正执行了收口（代际不匹配 / 本代际已收口时返回 false）。
  bool terminate({
    required AgentStatus status,
    required AgentFinishState finishState,
    required void Function(AgentStatus status) writeStatus,
    required void Function() emitReport,
    required void Function() emitFinish,
    void Function()? flush,
    void Function()? endTracer,
    void Function()? cleanup,
    int? expectedGeneration,
  }) {
    final gen = _generation();
    if (expectedGeneration != null && expectedGeneration != gen) return false;
    if (_terminated && _terminatedGeneration == gen) return false;

    _terminated = true;
    _terminatedGeneration = gen;
    try {
      writeStatus(status);
      emitReport();
      emitFinish();
      if (flush != null) flush();
      if (endTracer != null) endTracer();
    } finally {
      // 清理必须在 finally：任一回调抛异常都不能跳过资源释放。
      cleanup?.call();
    }
    return true;
  }
}
