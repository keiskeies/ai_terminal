import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

/// file_write / file_patch 工具测试
///
/// 重点覆盖参数校验和错误路径：
/// - path/content_b64/old_b64 缺失
/// - mode 非法值
/// - base64 解码失败
/// - 单次写入超 8KB 拒绝
/// - 非 SSH 会话拒绝
/// - file_patch 唯一性校验（_countOccurrences 边界）
///
/// SFTP 实际网络调用需要真实 SSH 服务器，不在单元测试覆盖范围。
/// 真实链路集成由人工测试或 e2e 测试覆盖。
void main() {
  group('FileWriteTool 参数校验', () {
    late FileWriteTool tool;
    late FakeExecutor executor;

    setUp(() {
      tool = FileWriteTool();
      executor = FakeExecutor();
    });

    test('W-1: path 缺失 → 报错', () async {
      final result = await tool.execute(
        executor: executor,
        args: {'content_b64': 'aGVsbG8=', 'mode': 'write'},
      );
      expect(result.success, isFalse);
      expect(result.error, contains('path'));
    });

    test('W-2: content_b64 缺失 → 报错', () async {
      final result = await tool.execute(
        executor: executor,
        args: {'path': '/tmp/test.txt', 'mode': 'write'},
      );
      expect(result.success, isFalse);
      expect(result.error, contains('content_b64'));
    });

    test('W-3: mode 非法值 → 报错', () async {
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'content_b64': 'aGVsbG8=',
          'mode': 'invalid',
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('mode'));
    });

    test('W-4: base64 解码失败 → 报错', () async {
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'content_b64': '!!!not_base64!!!',
          'mode': 'write',
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('base64'));
    });

    test('W-5: 单次写入 > 8KB → 拒绝并提示分块', () async {
      // 构造 > 8KB 原文
      final bigContent = 'A' * (8 * 1024 + 1);
      final bigB64 = base64Encode(utf8.encode(bigContent));
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/big.txt',
          'content_b64': bigB64,
          'mode': 'write',
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('过大'));
      expect(result.error, contains('分块'));
    });

    test('W-6: 单次写入 = 8KB（边界值）→ 允许通过大小校验', () async {
      // 8KB 正好等于上限，应通过大小校验（非 SSH 会话会在后续报错）
      final content = 'A' * (8 * 1024);
      final b64 = base64Encode(utf8.encode(content));
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/exact.txt',
          'content_b64': b64,
          'mode': 'write',
        },
      );
      // 通过大小校验后，因非 SSH 会话拒绝
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'),
          reason: '大小校验通过，但 FakeExecutor 非 SSHService，应拒绝');
    });

    test('W-7: 非 SSH 会话 → 拒绝', () async {
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'content_b64': 'aGVsbG8=',
          'mode': 'write',
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'));
    });

    test('W-8: mode 缺省 → 默认 write', () async {
      // 不传 mode，应默认 write，不会报 mode 错误
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'content_b64': 'aGVsbG8=',
        },
      );
      // 走到非 SSH 拒绝，说明 mode 校验已通过
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'));
      expect(result.error, isNot(contains('mode')));
    });

    test('W-9: backup=false 参数能被正确解析', () async {
      // backup=false 不应导致参数校验失败
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'content_b64': 'aGVsbG8=',
          'mode': 'write',
          'backup': 'false',
        },
      );
      // 走到非 SSH 拒绝，说明 backup=false 已被解析
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'));
      expect(result.error, isNot(contains('backup')));
    });

    test('W-10: backup 参数缺省 → 默认 true（不报错）', () async {
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'content_b64': 'aGVsbG8=',
          'mode': 'write',
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'));
    });
  });

  group('FilePatchTool 参数校验', () {
    late FilePatchTool tool;
    late FakeExecutor executor;

    setUp(() {
      tool = FilePatchTool();
      executor = FakeExecutor();
    });

    test('P-1: path 缺失 → 报错', () async {
      final result = await tool.execute(
        executor: executor,
        args: {'old_b64': 'aGVsbG8=', 'new_b64': ''},
      );
      expect(result.success, isFalse);
      expect(result.error, contains('path'));
    });

    test('P-2: old_b64 缺失 → 报错', () async {
      final result = await tool.execute(
        executor: executor,
        args: {'path': '/tmp/test.txt', 'new_b64': ''},
      );
      expect(result.success, isFalse);
      expect(result.error, contains('old_b64'));
    });

    test('P-3: old_b64 base64 解码失败 → 报错', () async {
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'old_b64': '!!!not_base64!!!',
          'new_b64': '',
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('base64'));
    });

    test('P-4: new_b64 base64 解码失败 → 报错', () async {
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'old_b64': 'aGVsbG8=',
          'new_b64': '!!!not_base64!!!',
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('new_b64'));
      expect(result.error, contains('base64'));
    });

    test('P-5: new_b64 允许为空（表示删除 old）', () async {
      // 空 new_b64 不应触发 base64 解码错误
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'old_b64': 'aGVsbG8=',
          'new_b64': '',
        },
      );
      // 走到非 SSH 拒绝，说明 new_b64="" 已通过校验
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'));
      expect(result.error, isNot(contains('base64')));
    });

    test('P-6: 非 SSH 会话 → 拒绝', () async {
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'old_b64': 'aGVsbG8=',
          'new_b64': 'd29ybGQ=',
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'));
    });

    test('P-7: backup=false 参数能被正确解析', () async {
      // backup=false 不应导致参数校验失败
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'old_b64': 'aGVsbG8=',
          'new_b64': 'd29ybGQ=',
          'backup': 'false',
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'));
      expect(result.error, isNot(contains('backup')));
    });

    test('P-8: backup 参数缺省 → 默认 true（不报错）', () async {
      final result = await tool.execute(
        executor: executor,
        args: {
          'path': '/tmp/test.txt',
          'old_b64': 'aGVsbG8=',
          'new_b64': 'd29ybGQ=',
        },
      );
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'));
    });
  });

  group('FilePatchTool._countOccurrences 唯一性校验', () {
    test('C-1: 0 次出现', () {
      expect(FilePatchTool.countOccurrencesForTest('hello world', 'foo'), 0);
    });

    test('C-2: 1 次出现（唯一）', () {
      expect(FilePatchTool.countOccurrencesForTest('hello world', 'hello'), 1);
    });

    test('C-3: 多次出现（非唯一）', () {
      expect(FilePatchTool.countOccurrencesForTest('ababab', 'ab'), 3);
    });

    test('C-4: 重叠不计数（非重叠匹配）', () {
      // "aaa" 中 "aa" 非重叠匹配只算 1 次（idx=0 后跳到 idx=2）
      expect(FilePatchTool.countOccurrencesForTest('aaa', 'aa'), 1);
    });

    test('C-5: 空子串 → 0', () {
      expect(FilePatchTool.countOccurrencesForTest('hello', ''), 0);
    });

    test('C-6: 多行内容匹配', () {
      // 模拟配置文件改端口场景
      const content = 'server {\n  listen 80;\n  server_name example.com;\n}\n';
      const target = 'listen 80;';
      expect(FilePatchTool.countOccurrencesForTest(content, target), 1);
    });

    test('C-7: 多次出现 → file_patch 应拒绝', () {
      // 同一配置文件中"listen 80;"出现 2 次，patch 应拒绝
      const content = 'server {\n  listen 80;\n}\nserver {\n  listen 80;\n}\n';
      const target = 'listen 80;';
      expect(FilePatchTool.countOccurrencesForTest(content, target), 2);
    });
  });

  group('ToolArgsParser 解析 file_write / file_patch 参数', () {
    test('A-1: 解析 file_write 多行参数', () {
      const argsText = '''
path: /etc/nginx/conf.d/default.conf
content_b64: c2VydmVyIHsKICBsaXN0ZW4gODA7Cn0=
mode: write''';
      final args = ToolArgsParser.parse(argsText);
      expect(args, isNotNull);
      expect(args!['path'], '/etc/nginx/conf.d/default.conf');
      expect(args['content_b64'], 'c2VydmVyIHsKICBsaXN0ZW4gODA7Cn0=');
      expect(args['mode'], 'write');
    });

    test('A-2: 解析 file_patch 多行参数', () {
      const argsText = '''
path: /etc/nginx/nginx.conf
old_b64: bGlzdGVuIDgwOw==
new_b64: bGlzdGVuIDgwODA7''';
      final args = ToolArgsParser.parse(argsText);
      expect(args, isNotNull);
      expect(args!['path'], '/etc/nginx/nginx.conf');
      expect(args['old_b64'], 'bGlzdGVuIDgwOw==');
      expect(args['new_b64'], 'bGlzdGVuIDgwODA7');
    });

    test('A-3: 端到端 base64 往返 — 中文配置内容', () {
      // 模拟 AI 生成中文配置文件的完整流程
      const originalContent = '# nginx 配置\nserver_name 中文网站.com;\n';
      final b64 = base64Encode(utf8.encode(originalContent));
      // 通过 parser 解析参数
      final args = ToolArgsParser.parse('path: /tmp/test.conf\ncontent_b64: $b64');
      expect(args, isNotNull);
      expect(args!['content_b64'], b64);
      // 工具内部解码后应得到原文（UTF-8 完整保留）
      final decoded = utf8.decode(base64Decode(args['content_b64'] as String));
      expect(decoded, originalContent);
      expect(decoded, contains('中文网站'));
    });

    test('A-4: 端到端 base64 往返 — 含特殊字符的脚本（heredoc 必失败的场景）', () {
      // 这是 heredoc 必然出错的内容，但 base64 完全保留
      // 用 raw string (r'''...''') 避免 Dart 字符串转义
      const originalContent = r'''#!/bin/bash
echo "PATH is $PATH"
echo 'Single quotes: $HOME'
VAR="hello\nworld"
EOF'''; // 故意包含 EOF 字符串、$ 变量替换、单双引号
      final b64 = base64Encode(utf8.encode(originalContent));
      final args = ToolArgsParser.parse('path: /tmp/test.sh\ncontent_b64: $b64');
      expect(args, isNotNull);
      final decoded = utf8.decode(base64Decode(args!['content_b64'] as String));
      expect(decoded, originalContent);
      expect(decoded, contains(r'$PATH'));
      expect(decoded, contains('EOF'));
    });
  });
}

/// 假 CommandExecutor — 非 SSHService，用于测试参数校验路径
///
/// file_write / file_patch 在通过参数校验后会检查 `executor is SSHService`，
/// FakeExecutor 不是 SSHService，会被拒绝。这正好测了"非 SSH 拒绝"路径。
class FakeExecutor implements CommandExecutor {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
