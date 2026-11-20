import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/services/event_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EventStore', () {
    test('同作用域内相同 stableId 幂等映射到同一 finalId', () {
      final scope = EventStore().newScope();
      final a = AgentEvent.thought('a', id: 'stable_abc12345');
      final b = AgentEvent.thought('b', id: 'stable_abc12345');

      final id1 = scope.assignFinalId(a);
      final id2 = scope.assignFinalId(b);

      expect(id1, id2);
      // 首次分配会改写 event.id；命中缓存时不改写（由调用方按需 finalIdFor）
      expect(a.id, id1);
      expect(b.id, 'stable_abc12345');
    });

    test('不同 stableId 分配递增序号，finalId 含哈希前 8 位', () {
      final scope = EventStore().newScope();
      final a = AgentEvent.thought('a', id: 'hash_aaaaaaaa');
      final b = AgentEvent.thought('b', id: 'hash_bbbbbbbb');

      expect(scope.assignFinalId(a), 'evt_1_hash_aaa');
      expect(scope.assignFinalId(b), 'evt_2_hash_bbb');
    });

    test('stableId 短于 8 位时安全取全串', () {
      final scope = EventStore().newScope();
      final e = AgentEvent.thought('x', id: 'abc');

      expect(scope.assignFinalId(e), 'evt_1_abc');
    });

    test('finalIdFor 未分配时原样返回', () {
      final scope = EventStore().newScope();

      expect(scope.finalIdFor('unknown_stable_id'), 'unknown_stable_id');
    });

    test('跨作用域相同 stableId 拿到不同 finalId（回归：重复 key bug）', () {
      final store = EventStore();
      final first = store.newScope();
      final second = store.newScope();
      // 两轮里内容相同的 ask 事件：若序号每轮重置会撞 id，
      // Flutter 同层重复 key 会让整块提问步骤渲染失败。
      final ask1 = AgentEvent.thought('ask', id: 'same_hash_1');
      final ask2 = AgentEvent.thought('ask', id: 'same_hash_1');

      final id1 = first.assignFinalId(ask1);
      final id2 = second.assignFinalId(ask2);

      expect(id1, 'evt_1_same_has');
      expect(id2, 'evt_2_same_has');
      expect(id1, isNot(id2));
    });

    test('去重集合按作用域隔离（轮内去重不跨轮）', () {
      final store = EventStore();
      final first = store.newScope();
      final second = store.newScope();

      expect(first.isNew('mid'), isTrue);
      first.markEmitted('mid');
      expect(first.isNew('mid'), isFalse);
      // 下一轮不继承上一轮的已发出记录
      expect(second.isNew('mid'), isTrue);
    });

    test('幂等分配不重复递增序号', () {
      final store = EventStore();
      final scope = store.newScope();
      final e = AgentEvent.thought('x', id: 'hash_cccccccc');
      // 命中缓存时事件 id 未被改写，用另一事件对象模拟同一 stableId 复现
      final eAgain = AgentEvent.thought('x', id: 'hash_cccccccc');

      expect(scope.assignFinalId(e), 'evt_1_hash_ccc');
      expect(scope.assignFinalId(eAgain), 'evt_1_hash_ccc');
      final other = AgentEvent.thought('y', id: 'hash_dddddddd');
      expect(scope.assignFinalId(other), 'evt_2_hash_ddd');
    });
  });
}
