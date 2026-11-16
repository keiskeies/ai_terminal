import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/conversation.dart';
import 'package:ai_terminal/services/conversation_service.dart';

/// 覆盖「空白会话不落盘」的缓存层行为。
///
/// 写库路径依赖 DbInit（测试环境未初始化，`DbInit.db` 会直接断言失败），
/// 因此这里的判定口径是：一旦代码尝试写库，测试就会红。
/// 真实入库（写出第一条消息后会话出现在列表里）需要数据库，不在单测范围内。
void main() {
  final service = ConversationService();

  group('Conversation.isBlank', () {
    test('新建即空白', () {
      final conv = Conversation.create(id: 'c1', hostId: 'h', title: 't');
      expect(conv.isBlank, isTrue);
    });

    test('有消息不再空白', () {
      final conv = Conversation.create(id: 'c2', hostId: 'h', title: 't');
      conv.addMessage(ConvMessage.create(role: 'user', content: 'ls'));
      expect(conv.isBlank, isFalse);
    });

    test('有摘要不再空白', () {
      final conv = Conversation.create(id: 'c3', hostId: 'h', title: 't')
        ..summary = '已排查过 nginx 配置';
      expect(conv.isBlank, isFalse);
    });

    test('空摘要不算内容', () {
      final conv = Conversation.create(id: 'c4', hostId: 'h', title: 't')
        ..summary = '';
      expect(conv.isBlank, isTrue);
    });
  });

  group('新建会话', () {
    test('空白会话不进历史列表，但确实是当前 active 会话', () {
      final conv = service.createSession(hostId: 'host-list');
      expect(service.listSessions('host-list'), isEmpty);
      expect(service.getActiveSession('host-list')?.id, conv.id);
    });

    test('连续新建不会堆叠空白会话', () {
      service.createSession(hostId: 'host-twice');
      final second = service.createSession(hostId: 'host-twice');
      expect(service.listSessions('host-twice'), isEmpty);
      expect(service.getActiveSession('host-twice')?.id, second.id);
    });

    test('空白会话重命名不触发写库', () async {
      final conv = service.createSession(hostId: 'host-rename');
      await service.rename(conv.id, '临时命名');
      expect(service.listSessions('host-rename'), isEmpty);
    });

    test('退出刷盘跳过空白会话', () async {
      final conv = service.createSession(hostId: 'host-flush');
      await expectLater(service.flush(conv.id), completes);
      expect(service.listSessions('host-flush'), isEmpty);
    });

    test('空白会话仍可被后续任务按 id 写入', () async {
      final conv = service.createSession(hostId: 'host-reuse');
      // 多 tab 场景：startTask 用 state.conversationId 定向写入，
      // 该会话即使还没落盘也必须能取到，否则消息会静默丢失
      await service.appendAgentLog(
        'host-reuse',
        level: 'INFO',
        tag: 'T',
        message: 'hello',
        conversationId: conv.id,
      );
      expect(service.listSessions('host-reuse'), isEmpty);
    });
  });
}
