import 'package:flutter/foundation.dart';

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
    bool Function(AgentStatus status)? isTerminalAllowed,
  })  : _generation = generation,
        _isTerminalAllowed = isTerminalAllowed;

  /// 所属引擎的主机 id（用于日志/诊断）
  final String? hostId;

  final int Function() _generation;
  final bool Function(AgentStatus status)? _isTerminalAllowed;

  /// 同一引擎、同一代际的终态只收口一次；新任务代际变化后自动重新开放。
  bool _terminated = false;
  int _terminatedGeneration = -1;

  /// 最近一次收口的回调错误摘要。单项失败不阻止后续终态动作，也不向任务循环
  /// 抛异常；否则 report/finish/flush 会被同一个异常永久跳过。
  List<String> _lastErrors = const [];
  List<String> get lastErrors => List.unmodifiable(_lastErrors);

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
    if (_isTerminalAllowed?.call(status) == false) return false;
    if (_terminated && _terminatedGeneration == gen) return false;

    // 先记终态，保证同代际重入不会造成重复报告/持久化。
    _terminated = true;
    _terminatedGeneration = gen;
    final errors = <String>[];
    _lastErrors = const [];

    void attempt(String name, void Function()? action) {
      if (action == null) return;
      try {
        action();
      } catch (e, stack) {
        errors.add('$name: $e');
        debugPrint(
            '[TerminationGuard] host=$hostId gen=$gen $name 失败: $e\n$stack');
      }
    }

    attempt('writeStatus', () => writeStatus(status));
    attempt('emitReport', emitReport);
    attempt('emitFinish', emitFinish);
    if (flush != null) attempt('flush', flush);
    if (endTracer != null) attempt('endTracer', endTracer);
    // cleanup 不是 finally 的附加项，而是与其它项一样必须独立尝试的终态动作。
    if (cleanup != null) attempt('cleanup', cleanup);
    _lastErrors = List.unmodifiable(errors);
    if (errors.isNotEmpty) {
      debugPrint('[TerminationGuard] host=$hostId gen=$gen 收口完成，'
          '${errors.length} 项失败: ${errors.join('; ')}');
    }
    return true;
  }

  /// UI 状态层（AgentNotifier 的 AgentState.status）终态决策的唯一入口。
  ///
  /// 与 [terminate] 不同：这里是 provider 的 UI 态（让界面退出运行态），
  /// 没有 engine 的 report/finish/tracer 骨架，也不做代际检查（provider
  /// 不持有 engine generation）。返回传入的终态原值供 `copyWith` 使用，
  /// 同时记入 [_uiStatusHistory] 便于诊断；流式落盘由调用方在写入前完成。
  ///
  /// 所有 UI 终态赋值都经此入口，棘轮检查才能安全降为硬禁令。
  AgentStatus resolveUiStatus(AgentStatus status) {
    _uiStatusHistory.add(status);
    if (_uiStatusHistory.length > 32) {
      _uiStatusHistory.removeAt(0);
    }
    return status;
  }

  /// 最近若干次 UI 终态决策（诊断用，有界避免无界增长）。
  final List<AgentStatus> _uiStatusHistory = <AgentStatus>[];

  /// UI 终态决策次数（诊断用）。
  int get uiStatusCount => _uiStatusHistory.length;
}
