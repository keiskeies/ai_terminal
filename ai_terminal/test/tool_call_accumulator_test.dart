import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

void main() {
  group('ToolCallAccumulator', () {
    test('空 delta 不产生 tool_calls', () {
      final acc = ToolCallAccumulator();
      expect(acc.finalize(), isEmpty);
      expect(acc.hasPendingCalls, isFalse);
    });

    test('null delta 安全处理', () {
      final acc = ToolCallAccumulator();
      acc.addDelta(null);
      expect(acc.finalize(), isEmpty);
    });

    test('单个 tool_call 完整累积', () {
      final acc = ToolCallAccumulator();
      // 首个 chunk：id + name + 部分 arguments
      acc.addDelta([
        {
          'index': 0,
          'id': 'call_abc123',
          'type': 'function',
          'function': {
            'name': 'sftp_upload',
            'arguments': '{"local":"/path',
          },
        },
      ]);
      // 后续 chunk：仅追加 arguments
      acc.addDelta([
        {
          'index': 0,
          'function': {
            'arguments': '","remote":"/tmp"}',
          },
        },
      ]);
      expect(acc.hasPendingCalls, isTrue);
      final calls = acc.finalize();
      expect(calls.length, 1);
      expect(calls[0].id, 'call_abc123');
      expect(calls[0].name, 'sftp_upload');
      expect(calls[0].arguments, '{"local":"/path","remote":"/tmp"}');
    });

    test('多个 tool_calls 按 index 排序', () {
      final acc = ToolCallAccumulator();
      acc.addDelta([
        {
          'index': 1,
          'id': 'call_1',
          'function': {'name': 'tool_b', 'arguments': '{}'},
        },
        {
          'index': 0,
          'id': 'call_0',
          'function': {'name': 'tool_a', 'arguments': '{}'},
        },
      ]);
      final calls = acc.finalize();
      expect(calls.length, 2);
      expect(calls[0].name, 'tool_a'); // index 0 在前
      expect(calls[1].name, 'tool_b'); // index 1 在后
    });

    test('无 name 的 partial 丢弃', () {
      final acc = ToolCallAccumulator();
      acc.addDelta([
        {
          'index': 0,
          'id': 'call_x',
          // 缺 function.name
          'function': {'arguments': '{}'},
        },
      ]);
      final calls = acc.finalize();
      expect(calls, isEmpty);
    });

    test('id 缺失时使用 fallback id', () {
      final acc = ToolCallAccumulator();
      acc.addDelta([
        {
          'index': 2,
          'function': {'name': 'tool_x', 'arguments': '{}'},
        },
      ]);
      final calls = acc.finalize();
      expect(calls.length, 1);
      expect(calls[0].id, 'call_2');
    });

    test('toReActText 转换为 ReAct 多行 key:value 格式（不再用 JSON）', () {
      final calls = [
        const ToolCall(id: 'call_1', name: 'sftp_upload', arguments: '{"local":"/a","remote":"/b"}'),
      ];
      final text = ToolCallAccumulator.toReActText(calls);
      expect(text, contains('动作: tool'));
      expect(text, contains('工具: sftp_upload'));
      expect(text, contains('参数:'));
      // 关键：不再以 { 开头（ToolArgsParser 已拒绝 JSON 格式）
      expect(text, isNot(contains('参数: {')));
      expect(text, contains('  local: /a'));
      expect(text, contains('  remote: /b'));
    });

    test('toReActText 多个 tool_call 用空行分隔', () {
      final calls = [
        const ToolCall(id: '1', name: 'tool_a', arguments: '{}'),
        const ToolCall(id: '2', name: 'tool_b', arguments: '{}'),
      ];
      final text = ToolCallAccumulator.toReActText(calls);
      expect(text, contains('工具: tool_a'));
      expect(text, contains('工具: tool_b'));
      // 两个 tool 之间应有空行分隔
      expect(text.split('\n\n').length, greaterThanOrEqualTo(2));
    });

    test('空 arguments 输出空 参数: 行', () {
      final calls = [
        const ToolCall(id: '1', name: 'tool_a', arguments: ''),
      ];
      final text = ToolCallAccumulator.toReActText(calls);
      expect(text, contains('参数:'));
      expect(text, isNot(contains('参数: {}')));
    });

    test('List 参数输出为逗号分隔（兼容 ToolArgsParser 的列表字段约定）', () {
      final calls = [
        const ToolCall(
          id: 'call_1',
          name: 'exec_batch',
          arguments: '{"hostIds":["web1","web2","db1"],"command":"uptime"}',
        ),
      ];
      final text = ToolCallAccumulator.toReActText(calls);
      expect(text, contains('  hostIds: web1,web2,db1'));
      expect(text, contains('  command: uptime'));
    });

    test('bool 参数输出为字符串 true/false', () {
      final calls = [
        const ToolCall(
          id: 'call_1',
          name: 'sftp_upload',
          arguments: '{"local":"/a","recursive":true}',
        ),
      ];
      final text = ToolCallAccumulator.toReActText(calls);
      expect(text, contains('  recursive: true'));
    });

    test('int 参数输出为数字字符串', () {
      final calls = [
        const ToolCall(
          id: 'call_1',
          name: 'exec_on',
          arguments: '{"hostId":"web1","timeout":30}',
        ),
      ];
      final text = ToolCallAccumulator.toReActText(calls);
      expect(text, contains('  timeout: 30'));
    });

    test('arguments 缺失尾部 } 自动修复', () {
      final acc = ToolCallAccumulator();
      acc.addDelta([
        {
          'index': 0,
          'id': 'call_1',
          'function': {'name': 'tool_x', 'arguments': '{"key":"value"'}, // 缺少尾部 }
        },
      ]);
      final calls = acc.finalize();
      expect(calls.length, 1);
      // 修复后应为合法 JSON
      expect(calls[0].arguments, '{"key":"value"}');
    });

    test('已完整的 arguments 不被修改', () {
      final acc = ToolCallAccumulator();
      acc.addDelta([
        {
          'index': 0,
          'id': 'call_1',
          'function': {'name': 'tool_x', 'arguments': '{"a":1,"b":2}'},
        },
      ]);
      final calls = acc.finalize();
      expect(calls[0].arguments, '{"a":1,"b":2}');
    });

    test('P2-6 修复：finalize 后再调用返回空（防止重复投递）', () {
      // 场景：流式同时收到 finish_reason='tool_calls' 和 [DONE]，
      // 两个事件都会调用 finalize()。第一次应返回累积的 calls，
      // 第二次应返回空（避免 ReAct 文本被投递两次）
      final acc = ToolCallAccumulator();
      acc.addDelta([
        {
          'index': 0,
          'id': 'call_1',
          'function': {'name': 'tool_a', 'arguments': '{"x":1}'},
        },
      ]);
      final first = acc.finalize();
      expect(first.length, 1);
      expect(first[0].name, 'tool_a');
      // 第二次调用：应返回空
      final second = acc.finalize();
      expect(second, isEmpty);
      // hasPendingCalls 也应为 false
      expect(acc.hasPendingCalls, isFalse);
    });

    test('toReActText 开头自带换行（与已有 thought 文本拼接时保证 "动作:" 独立成行）', () {
      // 场景：OpenAI FC 协议允许 delta.content 和 delta.tool_calls 同时存在
      // AI 先输出 thought "好的，我来执行工具"，再触发 tool_calls
      // 若 toReActText 开头无换行，拼接后变成 "好的，我来执行工具动作: tool\n..."
      // _parseReActResponse 找不到独立的 "动作:" 行，工具调用被忽略
      final calls = [
        const ToolCall(id: '1', name: 'sftp_upload', arguments: '{"local":"/a"}'),
      ];
      final thought = '好的，我来执行工具';
      final reactText = ToolCallAccumulator.toReActText(calls);
      // 模拟 _callAI 中的 fullResponse += chunk
      final fullResponse = thought + reactText;
      // 关键断言：fullResponse 中必须存在独立的 "动作: tool" 行
      // 即某行 trim 后正好是 "动作: tool"，不能与其他文本拼接
      final lines = fullResponse.split('\n');
      final hasStandaloneActionLine =
          lines.any((l) => l.trim() == '动作: tool');
      expect(hasStandaloneActionLine, isTrue,
          reason: 'thought + tool_calls 拼接后 "动作: tool" 必须独立成行，'
              '否则 _parseReActResponse 会忽略工具调用。fullResponse=$fullResponse');
    });
  });
}
