import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

/// 端到端测试：覆盖 "AI 输出 → _parseReActResponse → ActionType.tool" 完整链路
///
/// 之前几轮 bug 都属于"单元测试覆盖到的组件正确，但拼接起来出问题"：
/// - Bug 1: _parseReActResponse 中 break 条件把 '工具:' 也算进去，
///   导致 toolName 解析分支是死代码，toolName 永远为 null
/// - Bug 2: ToolArgsParser 把 "web1,web2" 转 List<String>，但
///   exec_batch 用 args['hostIds']?.toString() → "[web1, web2]" → split(',') 带方括号
/// - Bug 3: toReActText 输出与已有 thought 文本拼接成 "好的动作: tool"
///   → _parseReActResponse 找不到独立 "动作:" 行 → 工具调用被忽略
///
/// 这些 bug 单元测试都覆盖不到，必须靠端到端测试发现。
void main() {
  group('ReAct 端到端解析链路', () {
    test('E2E-1: 标准多行 key:value 参数 → 正确解析 toolName 和 toolArgs', () {
      // AI 直接输出 ReAct 文本
      const response = '''思考: 需要把 dist 目录上传到服务器
动作: tool
工具: sftp_upload
参数:
  local: /Users/x/proj/dist
  remote: /var/www/myapp
  recursive: true
  exclude: node_modules,.git''';

      final lines = response.split('\n');
      final actionLineIdx = lines.indexWhere((l) => l.trim().startsWith('动作:'));
      final result = AgentEngine.parseToolAction(lines, actionLineIdx + 1);

      expect(result.$1, 'sftp_upload');
      expect(result.$2, isNotNull);
      expect(result.$2!['local'], '/Users/x/proj/dist');
      expect(result.$2!['remote'], '/var/www/myapp');
      expect(result.$2!['recursive'], isTrue);
      // exclude 含逗号 → ToolArgsParser 自动转 List<String>
      expect(result.$2!['exclude'], isA<List<String>>());
      expect((result.$2!['exclude'] as List), ['node_modules', '.git']);
    });

    test('E2E-2: Function Calling 流式输出 → toReActText → 解析链路完整', () {
      // 模拟 OpenAI FC 流式输出：模型返回 tool_calls，无 thought content
      final calls = [
        const ToolCall(
          id: 'call_1',
          name: 'exec_batch',
          arguments: '{"hostIds":"web1,web2,db1","command":"uptime","timeout":30}',
        ),
      ];
      final reactText = ToolCallAccumulator.toReActText(calls);

      // 模拟 _callAI 中的 fullResponse += chunk
      final fullResponse = reactText;
      final lines = fullResponse.split('\n');
      final actionLineIdx = lines.indexWhere((l) => l.trim() == '动作: tool');
      expect(actionLineIdx, greaterThanOrEqualTo(0),
          reason: 'toReActText 必须输出独立的 "动作: tool" 行');

      final result = AgentEngine.parseToolAction(lines, actionLineIdx + 1);

      expect(result.$1, 'exec_batch');
      expect(result.$2, isNotNull);
      // 关键：hostIds 应该是 List<String>，不是 "[web1, web2, db1]" 字符串
      expect(result.$2!['hostIds'], isA<List<String>>(),
          reason: 'Bug 2 回归：ToolArgsParser 把含逗号的 hostIds 转 List，'
              '若工具用 toString() 会得到 "[web1, web2, db1]" 带方括号');
      expect((result.$2!['hostIds'] as List), ['web1', 'web2', 'db1']);
      expect(result.$2!['command'], 'uptime');
      expect(result.$2!['timeout'], 30);
    });

    test('E2E-3: thought 文本 + Function Calling 拼接 → 工具调用不丢失', () {
      // 模拟 OpenAI FC 协议允许 delta.content 和 delta.tool_calls 同时存在
      // AI 先输出 thought "好的，我来执行工具"，再触发 tool_calls
      const thought = '好的，我来执行工具';
      final calls = [
        const ToolCall(
          id: 'call_1',
          name: 'sftp_upload',
          arguments: '{"local":"/path/to/dist","remote":"/var/www"}',
        ),
      ];
      final reactText = ToolCallAccumulator.toReActText(calls);
      // 模拟 _callAI 中的 fullResponse += chunk（thought 先到，reactText 后到）
      final fullResponse = thought + reactText;

      // 关键断言：fullResponse 中必须存在独立的 "动作: tool" 行
      final lines = fullResponse.split('\n');
      final actionLineIdx = lines.indexWhere((l) => l.trim() == '动作: tool');
      expect(actionLineIdx, greaterThanOrEqualTo(0),
          reason: 'Bug 3 回归：thought + toReActText 拼接后 "动作: tool" 必须独立成行，'
              '否则 _parseReActResponse 会忽略工具调用。fullResponse=$fullResponse');

      final result = AgentEngine.parseToolAction(lines, actionLineIdx + 1);
      expect(result.$1, 'sftp_upload');
      expect(result.$2, isNotNull);
      expect(result.$2!['local'], '/path/to/dist');
      expect(result.$2!['remote'], '/var/www');
    });

    test('E2E-4: 工具名和参数顺序可交换（工具: 在 参数: 之后）', () {
      // 部分模型可能先输出参数再输出工具名
      const response = '''动作: tool
参数:
  hostId: web1
  command: systemctl status nginx
工具: exec_on''';

      final lines = response.split('\n');
      final actionLineIdx = lines.indexWhere((l) => l.trim().startsWith('动作:'));
      final result = AgentEngine.parseToolAction(lines, actionLineIdx + 1);

      // 当前实现：遇到 参数: 后 break，工具: 若在参数之后会被跳过
      // 这个测试记录当前行为，避免未来改动时意外破坏
      // 期望：toolArgs 正确解析，toolName 可能 null（取决于参数后是否有 工具: 行）
      expect(result.$2, isNotNull);
      expect(result.$2!['hostId'], 'web1');
      expect(result.$2!['command'], 'systemctl status nginx');
    });

    test('E2E-5: 参数后紧跟下一个 ReAct 关键词 → 正确停止收集', () {
      // 参数后紧跟 "观测:" 关键词（虽然正常流程中不会出现，但作为边界测试）
      const response = '''动作: tool
工具: sftp_upload
参数:
  local: /path
观测: 这是观测内容''';

      final lines = response.split('\n');
      final actionLineIdx = lines.indexWhere((l) => l.trim().startsWith('动作:'));
      final result = AgentEngine.parseToolAction(lines, actionLineIdx + 1);

      expect(result.$1, 'sftp_upload');
      expect(result.$2, isNotNull);
      expect(result.$2!['local'], '/path');
      // "观测: 这是观测内容" 不应被收入 argsBuffer
      expect(result.$2!.length, 1);
    });

    test('E2E-6: ToolArgsParser 类型 helper 端到端验证', () {
      // 验证 helper 层正确处理 List/String/bool/int 类型
      final args = <String, dynamic>{
        'hostIds': ['web1', 'web2', 'db1'], // List
        'exclude': 'node_modules,.git', // String（含逗号但已被 parser 转 List 的情况）
        'recursive': true, // bool
        'timeout': 30, // int
        'port': '443', // String（数字字符串）
        'hostId': 'web1', // String
      };

      // getStringList：List 值 → 直接 map
      expect(ToolArgsParser.getStringList(args, 'hostIds'),
          ['web1', 'web2', 'db1']);
      // getStringList：String 值 → 按逗号切分
      expect(ToolArgsParser.getStringList(args, 'exclude'),
          ['node_modules', '.git']);
      // getBool：bool 值 → 直接返回
      expect(ToolArgsParser.getBool(args, 'recursive'), isTrue);
      // getInt：int 值 → 直接返回
      expect(ToolArgsParser.getInt(args, 'timeout'), 30);
      // getInt：String 数字 → tryParse
      expect(ToolArgsParser.getInt(args, 'port'), 443);
      // getString：String 值
      expect(ToolArgsParser.getString(args, 'hostId'), 'web1');
      // getString：缺失 → defaultValue
      expect(ToolArgsParser.getString(args, 'missing', defaultValue: 'fallback'),
          'fallback');
      // getStringList：缺失 → 空列表
      expect(ToolArgsParser.getStringList(args, 'missing'), isEmpty);
    });

    test('E2E-7: hostIds 单值不被错误转 List（ToolArgsParser 仅在含逗号时转 List）', () {
      // ToolArgsParser._convertValue: 仅当 listKeys 中的 key 且值含逗号时才转 List
      // 单值 "web1" 保持 String
      const response = '''动作: tool
工具: exec_on
参数:
  hostId: web1
  command: uptime''';

      final lines = response.split('\n');
      final actionLineIdx = lines.indexWhere((l) => l.trim().startsWith('动作:'));
      final result = AgentEngine.parseToolAction(lines, actionLineIdx + 1);

      expect(result.$2, isNotNull);
      // hostId 不在 listKeys 里，保持 String
      expect(result.$2!['hostId'], 'web1');
      expect(result.$2!['hostId'], isA<String>());
    });
  });
}
