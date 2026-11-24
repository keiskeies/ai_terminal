import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/ssh_service.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

/// sftp_file_read 工具契约测试（O2）
///
/// SFTP 实际网络调用需要真实 SSH 服务器，不在单元测试覆盖范围
/// （与 file_edit_tools_test 的隔离方式一致）。
/// 大小判定 / 分行切片 / lossy 解码是纯函数，直接单测；
/// execute 层覆盖参数校验、scope 拒绝、本机路径误用等前置路径。
void main() {
  group('execute 参数校验', () {
    late SftpFileReadTool tool;
    late FakeExecutor executor;

    setUp(() {
      tool = SftpFileReadTool();
      executor = FakeExecutor();
    });

    test('path 缺失 → 报错', () async {
      final result = await tool.execute(
        executor: executor,
        args: const ToolArgs({'offset': 1}),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('path'));
    });

    test('path 全空白 → 报错', () async {
      final result = await tool.execute(
        executor: executor,
        args: const ToolArgs({'path': '   '}),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('path'));
    });

    test('offset < 1 → 报错（1-based 语义）', () async {
      for (final offset in [0, -3]) {
        final result = await tool.execute(
          executor: executor,
          args: ToolArgs({'path': '/etc/hosts', 'offset': offset}),
        );
        expect(result.success, isFalse);
        expect(result.error, contains('offset'));
      }
    });

    test('offset/limit 字符串形式可被 typed accessor 解析', () async {
      // 参数解析器把纯数字转 int；这里验证字符串兜底路径不会在参数层报错，
      // 而是走到非 SSH 拒绝（说明 offset/limit 校验已通过）
      final result = await tool.execute(
        executor: executor,
        args: const ToolArgs({
          'path': '/etc/hosts',
          'offset': '5',
          'limit': '50',
        }),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'));
    });

    test('非 SSH 会话 → 拒绝并指向 local_file_read', () async {
      final result = await tool.execute(
        executor: executor,
        args: const ToolArgs({'path': '/etc/hosts'}),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('SSH'));
      expect(result.error, contains('local_file_read'));
    });

    test('SSH 会话误传本机 Windows 路径 → 拒绝', () async {
      final ssh = SSHService(HostConfig.create(
        id: 'h1',
        name: 'h1',
        host: '127.0.0.1',
        username: 'tester',
        authType: 'password',
      ));
      final result = await tool.execute(
        executor: ssh,
        args: const ToolArgs({'path': r'D:\deploy\app.conf'}),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('本机路径'));
      expect(result.error, contains('local_file_read'));
    });

    test('SSH 未连接 → 明确报错', () async {
      final ssh = SSHService(HostConfig.create(
        id: 'h1',
        name: 'h1',
        host: '127.0.0.1',
        username: 'tester',
        authType: 'password',
      ));
      final result = await tool.execute(
        executor: ssh,
        args: const ToolArgs({'path': '/etc/hosts'}),
      );
      expect(result.success, isFalse);
      expect(result.error, contains('SSH 连接未建立'));
    });
  });

  group('oversizeError（2MB 上限，纯函数）', () {
    test('大小未知 / 0 / 恰好 2MB → 放行', () {
      expect(SftpFileReadTool.oversizeError(null), isNull);
      expect(SftpFileReadTool.oversizeError(0), isNull);
      expect(SftpFileReadTool.oversizeError(SftpFileReadTool.maxFileBytes),
          isNull);
    });

    test('2MB + 1 字节 → 拒绝并提示 grep / sftp_download', () {
      final err =
          SftpFileReadTool.oversizeError(SftpFileReadTool.maxFileBytes + 1);
      expect(err, isNotNull);
      expect(err, contains('grep'));
      expect(err, contains('sftp_download'));
      expect(err, contains('2MB'));
    });
  });

  group('formatSlice（分段读，纯函数）', () {
    final tenLines = List.generate(10, (i) => 'line${i + 1}').join('\n');

    test('默认范围读全文件：总行数 / 范围 / hasMore', () {
      final r = SftpFileReadTool.formatSlice(tenLines,
          path: '/tmp/a.txt', offset: 1, limit: 200);
      expect(r.success, isTrue);
      expect(r.output, contains('共 10 行'));
      expect(r.output, contains('本次范围: L1-L10 (10 行)'));
      expect(r.output, contains('L1: line1'));
      expect(r.output, contains('L10: line10'));
      expect(r.output, contains('hasMore: false'));
    });

    test('分段读：offset=3 limit=4 → L3-L6，hasMore 与下次 offset', () {
      final r = SftpFileReadTool.formatSlice(tenLines,
          path: '/tmp/a.txt', offset: 3, limit: 4);
      expect(r.success, isTrue);
      expect(r.output, contains('本次范围: L3-L6 (4 行)'));
      expect(r.output, contains('L3: line3'));
      expect(r.output, contains('L6: line6'));
      expect(r.output, isNot(contains('L2:')));
      expect(r.output, isNot(contains('L7:')));
      expect(r.output, contains('hasMore: true'));
      expect(r.output, contains('offset: 7'));
    });

    test('续读最后一段：offset=7 limit=4 → L7-L10，hasMore=false', () {
      final r = SftpFileReadTool.formatSlice(tenLines,
          path: '/tmp/a.txt', offset: 7, limit: 4);
      expect(r.success, isTrue);
      expect(r.output, contains('本次范围: L7-L10 (4 行)'));
      expect(r.output, contains('hasMore: false'));
    });

    test('offset 恰好等于总行数 → 只返回最后一行', () {
      final r = SftpFileReadTool.formatSlice(tenLines,
          path: '/tmp/a.txt', offset: 10, limit: 200);
      expect(r.success, isTrue);
      expect(r.output, contains('本次范围: L10-L10 (1 行)'));
      expect(r.output, contains('hasMore: false'));
    });

    test('offset 越界 → 失败并告知总行数', () {
      final r = SftpFileReadTool.formatSlice(tenLines,
          path: '/tmp/a.txt', offset: 11, limit: 200);
      expect(r.success, isFalse);
      expect(r.error, contains('offset 越界'));
      expect(r.error, contains('共 10 行'));
    });

    test('limit 恰好等于剩余行数 → 不产生 hasMore', () {
      final r = SftpFileReadTool.formatSlice(tenLines,
          path: '/tmp/a.txt', offset: 8, limit: 3);
      expect(r.success, isTrue);
      expect(r.output, contains('L8-L10'));
      expect(r.output, contains('hasMore: false'));
    });

    test('空文件 → 成功并标注 0 行', () {
      final r = SftpFileReadTool.formatSlice('',
          path: '/tmp/empty.txt', offset: 1, limit: 200);
      expect(r.success, isTrue);
      expect(r.output, contains('0 行'));
      expect(r.output, contains('空文件'));
    });

    test('末尾换行不算额外一行', () {
      final r = SftpFileReadTool.formatSlice('a\nb\n',
          path: '/tmp/a.txt', offset: 1, limit: 200);
      expect(r.output, contains('共 2 行'));
      expect(r.output, isNot(contains('L3:')));
    });

    test('CRLF 行尾被规范化', () {
      final r = SftpFileReadTool.formatSlice('a\r\nb\r\n',
          path: '/tmp/a.txt', offset: 1, limit: 200);
      expect(r.output, contains('共 2 行'));
      expect(r.output, contains('L1: a\n'));
      expect(r.output, isNot(contains('\r')));
    });

    test('offset / limit 非法 → 失败', () {
      expect(
          SftpFileReadTool.formatSlice(tenLines,
                  path: '/tmp/a.txt', offset: 0, limit: 10)
              .success,
          isFalse);
      expect(
          SftpFileReadTool.formatSlice(tenLines,
                  path: '/tmp/a.txt', offset: 1, limit: 0)
              .success,
          isFalse);
    });

    test('超长单行被截断，输出有界（R8）', () {
      final longLine = 'x' * 5000;
      final r = SftpFileReadTool.formatSlice(longLine,
          path: '/tmp/a.txt', offset: 1, limit: 200);
      expect(r.success, isTrue);
      expect(r.output, contains('行过长'));
      expect(r.output.length, lessThan(SftpFileReadTool.maxLineChars + 200));
    });

    test('总字符上限：返回行数收缩且 next offset 与实际末行一致', () {
      // 1000 行 × 100 字符 ≈ 100KB，远超 20000 上限
      final text =
          List.generate(1000, (i) => 'L${i + 1} ${'y' * 90}').join('\n');
      final r = SftpFileReadTool.formatSlice(text,
          path: '/tmp/big.txt', offset: 1, limit: 1000);
      expect(r.success, isTrue);
      expect(r.output, contains('hasMore: true'));
      expect(r.output.length,
          lessThanOrEqualTo(SftpFileReadTool.maxSliceChars + 300));
      final lineNos = RegExp(r'^L(\d+):', multiLine: true)
          .allMatches(r.output)
          .map((m) => int.parse(m.group(1)!))
          .toList();
      expect(lineNos, isNotEmpty);
      expect(lineNos.length, lessThan(1000));
      expect(r.output, contains('offset: ${lineNos.last + 1}'));
      expect(r.output, contains('本次范围: L1-L${lineNos.last}'));
    });
  });

  group('decodeLossy（UTF-8 非法字节）', () {
    test('非法字节替换为 U+FFFD 而不抛异常', () {
      final bytes = Uint8List.fromList([0x61, 0xFF, 0x62]);
      expect(SftpFileReadTool.decodeLossy(bytes), 'a\uFFFDb');
    });

    test('合法中文原样保留', () {
      final bytes = Uint8List.fromList(utf8.encode('配置项=值'));
      expect(SftpFileReadTool.decodeLossy(bytes), '配置项=值');
    });
  });

  group('注册与作用域', () {
    test('仅 SSH 会话可见，本地会话不暴露', () {
      final registry = AgentToolRegistry();
      expect(
        registry.visibleFor(isLocalSession: false).map((t) => t.name),
        contains('sftp_file_read'),
      );
      expect(
        registry.visibleFor(isLocalSession: true).map((t) => t.name),
        isNot(contains('sftp_file_read')),
      );
    });

    test('只读免确认、不进变更台账', () {
      final registry = AgentToolRegistry();
      final tool = registry.get('sftp_file_read')!;
      expect(tool.kind, ToolKind.read);
      expect(tool.isReadOnly, isTrue);
      expect(tool.recordsChanges, isFalse);
      expect(registry.isChangeRecordingTool('sftp_file_read'), isFalse);
    });

    test('工具清单提示词包含新工具（SSH 会话）', () {
      final registry = AgentToolRegistry();
      final sshPrompt = registry.buildToolsPrompt(isLocalSession: false);
      expect(sshPrompt, contains('sftp_file_read'));
      expect(sshPrompt, contains('offset'));
      expect(sshPrompt, contains('limit'));
      final localPrompt = registry.buildToolsPrompt(isLocalSession: true);
      expect(localPrompt, isNot(contains('sftp_file_read')));
    });

    test('FC schema 与 MCP 描述符合法', () {
      final tool = SftpFileReadTool();
      final schema = tool.toJsonSchema()!;
      expect(schema['required'], contains('path'));
      final props = schema['properties'] as Map<String, dynamic>;
      expect(props.keys, containsAll(['path', 'offset', 'limit']));
      expect((props['offset'] as Map)['type'], 'integer');

      final d = tool.mcpDescriptor;
      final a = d['annotations'] as Map<String, dynamic>;
      expect(a['readOnlyHint'], isTrue);
      expect(a['destructiveHint'], isFalse);
      expect(tool.paramSpec.trim().startsWith('{'), isFalse);
    });
  });
}

/// 假 CommandExecutor — 非 SSHService，用于测试参数校验路径
/// （与 file_edit_tools_test 的隔离方式一致）
class FakeExecutor implements CommandExecutor {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
