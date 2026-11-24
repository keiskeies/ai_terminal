import '../models/agent_event.dart';

/// 事件 id 分配与去重的独立存储（R4：每引擎一个实例）。
///
/// 序号 [_seq] 跨 AI 轮次单调递增，保证 `evt_<序号>_<内容哈希前8位>`
/// 在整个引擎生命周期内不重复 —— 否则两轮里内容相同的 ask 事件会拿到
/// 同一个 id，Flutter 同层重复 key 会让整块提问步骤渲染失败。
///
/// 去重状态则按调用作用域隔离：[newScope] 每次 AI 调用创建独立的
/// [EventScope]，轮内已发出的事件不会在下一轮被误判为重复。
class EventStore {
  int _seq = 0;

  /// 为一次 AI 调用创建独立作用域。
  EventScope newScope() => EventScope(_nextSeq);

  int _nextSeq() => ++_seq;
}

/// 单次 AI 调用内的事件去重与 id 分配。
///
/// 由 [EventStore.newScope] 创建；调用方持有它并在本次调用的
/// 提前执行回调与流结束合并处共用同一份状态。
class EventScope {
  EventScope(this._nextSeq);

  final int Function() _nextSeq;
  final Set<String> _emittedStableIds = <String>{};
  final Map<String, String> _stableIdToFinalId = <String, String>{};

  /// 分配（或复用）稳定 id 对应的最终全局唯一 id，并改写 [event].id。
  ///
  /// 同一 stableId 在同一作用域内幂等：重复调用返回同一个 finalId，
  /// 序号不会重复递增。调用方若需原始 stableId，须在调用本方法前取。
  String assignFinalId(AgentEvent event) {
    final stableId = event.id;
    final existing = _stableIdToFinalId[stableId];
    if (existing != null) return existing;

    final seq = _nextSeq();
    final finalId =
        'evt_${seq}_${stableId.substring(0, stableId.length > 8 ? 8 : stableId.length)}';
    _stableIdToFinalId[stableId] = finalId;
    event.id = finalId;
    return finalId;
  }

  /// 该 stableId 在本作用域内是否尚未发出。
  bool isNew(String stableId) => !_emittedStableIds.contains(stableId);

  /// 标记该 stableId 已发出。
  void markEmitted(String stableId) => _emittedStableIds.add(stableId);

  /// 查询 stableId 对应的 finalId；未分配时原样返回。
  String finalIdFor(String stableId) =>
      _stableIdToFinalId[stableId] ?? stableId;
}
