import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/conversation.dart';

void main() {
  group('Conversation agentLogs lazy decoding', () {
    test('create() keeps provided logs and has no raw JSON', () {
      final conversation = Conversation.create(
        id: 'c1',
        hostId: 'h1',
        title: 't',
        agentLogs: [ConvAgentLog.create(
          timestamp: DateTime(2026, 1, 1),
          level: 'INFO',
          tag: 'tag',
          message: 'hello',
        )],
      );
      expect(conversation.agentLogs.length, 1);
      expect(conversation.agentLogs.first.message, 'hello');
      expect(conversation.rawAgentLogsJson, isNull);
    });

    test('raw JSON is kept until logs are actually accessed', () {
      final json = jsonEncode([
        {
          'timestamp': '2026-01-01T00:00:00.000',
          'level': 'WARN',
          'tag': 'x',
          'message': 'deferred',
        }
      ]);
      final conversation = Conversation.create(
        id: 'c2',
        hostId: 'h1',
        title: 't',
      )..setAgentLogsJson(json);

      expect(conversation.rawAgentLogsJson, json);
      expect(conversation.agentLogs.single.level, 'WARN');
      // 展开后应改为编码当前列表
      expect(conversation.rawAgentLogsJson, isNull);
    });

    test('mutating a lazily loaded list is reflected in re-encoding', () {
      final conversation = Conversation.create(
        id: 'c3',
        hostId: 'h1',
        title: 't',
      )..setAgentLogsJson('[]');
      conversation.addAgentLog(ConvAgentLog.create(
        timestamp: DateTime(2026, 1, 2),
        level: 'ERROR',
        tag: 't',
        message: 'boom',
      ));
      expect(conversation.agentLogs.length, 1);
      expect(conversation.rawAgentLogsJson, isNull);
    });

    test('malformed JSON degrades to an empty list', () {
      final conversation = Conversation.create(
        id: 'c4',
        hostId: 'h1',
        title: 't',
      )..setAgentLogsJson('{not-json');
      expect(conversation.agentLogs, isEmpty);
    });
  });
}
