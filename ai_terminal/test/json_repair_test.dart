import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/json_repair.dart';

void main() {
  group('JsonRepair.extractMap', () {
    test('标准 JSON 解析', () {
      final result = JsonRepair.extractMap('{"key": "value"}');
      expect(result, isNotNull);
      expect(result!['key'], 'value');
    });

    test('带 markdown 代码块', () {
      final result = JsonRepair.extractMap('''以下是命令：
```json
{"command": "ls -la", "timeout": 60}
```
''');
      expect(result, isNotNull);
      expect(result!['command'], 'ls -la');
      expect(result['timeout'], 60);
    });

    test('代码块无 json 标识', () {
      final result = JsonRepair.extractMap('''
```
{"command": "pwd"}
```
''');
      expect(result, isNotNull);
      expect(result!['command'], 'pwd');
    });

    test('前后带说明文字', () {
      final result = JsonRepair.extractMap(
          '好的，我来执行这个命令：{"command": "df -h"} 希望有帮助。');
      expect(result, isNotNull);
      expect(result!['command'], 'df -h');
    });

    test('尾随逗号', () {
      final result = JsonRepair.extractMap('{"a": 1, "b": 2,}');
      expect(result, isNotNull);
      expect(result!['a'], 1);
      expect(result['b'], 2);
    });

    test('单引号字符串', () {
      final result = JsonRepair.extractMap("{'command': 'ls', 'count': 3}");
      expect(result, isNotNull);
      expect(result!['command'], 'ls');
      expect(result['count'], 3);
    });

    test('未引用的 key', () {
      final result = JsonRepair.extractMap('{command: "ls", count: 3}');
      expect(result, isNotNull);
      expect(result!['command'], 'ls');
      expect(result['count'], 3);
    });

    test('单行注释', () {
      final result = JsonRepair.extractMap('''{
  "command": "ls", // list files
  "count": 3
}''');
      expect(result, isNotNull);
      expect(result!['command'], 'ls');
      expect(result['count'], 3);
    });

    test('多行注释', () {
      final result = JsonRepair.extractMap('''{
  "command": "ls", /* list files */
  "count": 3
}''');
      expect(result, isNotNull);
      expect(result!['command'], 'ls');
    });

    test('嵌套对象', () {
      final result = JsonRepair.extractMap(
          '{"outer": {"inner": "value"}}');
      expect(result, isNotNull);
      expect(result!['outer']['inner'], 'value');
    });

    test('数组', () {
      final result = JsonRepair.extractMap(
          '{"commands": ["ls", "pwd", "df -h"]}');
      expect(result, isNotNull);
      expect(result!['commands'], isA<List>());
      expect(result['commands'].length, 3);
    });

    test('流式截断（括号未闭合）', () {
      final result = JsonRepair.extractMap(
          '{"command": "ls", "thought": "我正在');
      expect(result, isNotNull);
      expect(result!['command'], 'ls');
    });

    test('空字符串返回 null', () {
      expect(JsonRepair.extractMap(''), isNull);
    });

    test('无 JSON 内容返回 null', () {
      expect(JsonRepair.extractMap('just plain text'), isNull);
    });

    test('多个 JSON 对象取第一个', () {
      final result = JsonRepair.extractMap(
          '{"a": 1} {"b": 2}');
      expect(result, isNotNull);
      expect(result!['a'], 1);
    });

    test('特殊字符在字符串内', () {
      final result = JsonRepair.extractMap(
          r'{"command": "echo \"hello\""}');
      expect(result, isNotNull);
      expect(result!['command'], 'echo "hello"');
    });

    test('字符串内含括号', () {
      final result = JsonRepair.extractMap(
          '{"command": "echo {test}"}');
      expect(result, isNotNull);
      expect(result!['command'], 'echo {test}');
    });

    test('HTML 实体保持原样', () {
      // JSON 字符串值中的 &quot; 是字面量字符，不应被转换
      // 转换会破坏 JSON 结构
      final result = JsonRepair.extractMap(
          '{"command": "echo &quot;test&quot;"}');
      expect(result, isNotNull);
      expect(result!['command'], 'echo &quot;test&quot;');
    });

    test('BOM 字符', () {
      final result = JsonRepair.extractMap(
          '\uFEFF{"command": "ls"}');
      expect(result, isNotNull);
      expect(result!['command'], 'ls');
    });

    test('复杂嵌套结构', () {
      final result = JsonRepair.extractMap('''{
        "thought": "需要先检查服务状态",
        "actions": [
          {"type": "execute", "command": "systemctl status nginx"},
          {"type": "execute", "command": "df -h"}
        ],
        "metadata": {
          "priority": "high",
          "tags": ["urgent", "system"]
        }
      }''');
      expect(result, isNotNull);
      expect(result!['thought'], '需要先检查服务状态');
      expect(result['actions'], isA<List>());
      expect(result['actions'].length, 2);
      expect(result['metadata']['priority'], 'high');
    });

    test('混合中文标点的 key', () {
      // AI 偶尔输出中文冒号
      final result = JsonRepair.extractMap('{"命令"："ls"}');
      // 中文冒号不是合法 JSON，应返回 null 或尝试修复
      // 当前实现不处理中文冒号，返回 null 是合理的
      expect(result, isNull);
    });
  });

  group('JsonRepair.extractList', () {
    test('数组解析', () {
      final result = JsonRepair.extractList('[1, 2, 3]');
      expect(result, isNotNull);
      expect(result!.length, 3);
    });

    test('带代码块的数组', () {
      final result = JsonRepair.extractList('''```json
[{"a": 1}, {"b": 2}]
```''');
      expect(result, isNotNull);
      expect(result!.length, 2);
    });
  });

  group('JsonRepair.extractAndDecode', () {
    test('返回 Map', () {
      final result = JsonRepair.extractAndDecode('{"a": 1}');
      expect(result, isA<Map>());
    });

    test('返回 List', () {
      final result = JsonRepair.extractAndDecode('[1, 2, 3]');
      expect(result, isA<List>());
    });

    test('失败返回 null', () {
      final result = JsonRepair.extractAndDecode('not json at all');
      expect(result, isNull);
    });
  });
}
