import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

void main() {
  group('ToolArgsParser', () {
    group('新格式（多行 key:value）', () {
      test('基础多行解析', () {
        final result = ToolArgsParser.parse('''
            local: /Users/x/proj/dist
            remote: /var/www/myapp
            recursive: true
        ''');
        expect(result, isNotNull);
        expect(result!['local'], '/Users/x/proj/dist');
        expect(result['remote'], '/var/www/myapp');
        expect(result['recursive'], isTrue);
      });

      test('bool false 转换', () {
        final result = ToolArgsParser.parse('recursive: false');
        expect(result, isNotNull);
        expect(result!['recursive'], isFalse);
      });

      test('int 自动转换', () {
        final result = ToolArgsParser.parse('''
            timeout: 60
            port: 8080
        ''');
        expect(result, isNotNull);
        expect(result!['timeout'], 60);
        expect(result['port'], 8080);
      });

      test('路径含空格 — 值是冒号后整行', () {
        final result = ToolArgsParser.parse(
            'local: /Users/x/My Project/dist');
        expect(result, isNotNull);
        expect(result!['local'], '/Users/x/My Project/dist');
      });

      test('值含冒号 — 只按第一个冒号切分', () {
        final result = ToolArgsParser.parse(
            'path: C:\\\\Users\\\\x\\\\file.txt');
        expect(result, isNotNull);
        expect(result!['path'], 'C:\\\\Users\\\\x\\\\file.txt');
      });

      test('exclude 字段逗号分隔转 List', () {
        final result = ToolArgsParser.parse(
            'exclude: node_modules,.git,.DS_Store');
        expect(result, isNotNull);
        expect(result!['exclude'], isA<List>());
        expect((result['exclude'] as List).length, 3);
        expect((result['exclude'] as List)[0], 'node_modules');
      });

      test('hostIds 字段逗号分隔转 List', () {
        final result = ToolArgsParser.parse(
            'hostIds: web1,web2,db1');
        expect(result, isNotNull);
        expect(result!['hostIds'], isA<List>());
        expect((result['hostIds'] as List).length, 3);
      });

      test('缩进 2 空格', () {
        final result = ToolArgsParser.parse('''
  local: /path
  remote: /remote
        ''');
        expect(result, isNotNull);
        expect(result!['local'], '/path');
      });

      test('Tab 缩进', () {
        final result = ToolArgsParser.parse('''
\tlocal: /path
\tremote: /remote
        ''');
        expect(result, isNotNull);
        expect(result!['local'], '/path');
      });

      test('空值参数 — 值为空字符串', () {
        final result = ToolArgsParser.parse('local: ');
        expect(result, isNotNull);
        expect(result!['local'], '');
      });

      test('无冒号的行 → 整块判为不可解析（不静默丢内容）', () {
        expect(
          ToolArgsParser.parse('''
            local: /path
            这是一行没有冒号的文字
            remote: /remote
        '''),
          isNull,
          reason: '逐行跳过会让模型以为整段都写进去了',
        );
      });

      test('content 写成跨行正文 → null，而不是只剩第一行', () {
        // 真机复现：22:09 那次 E2E 里 /tmp/ai_terminal_llm_cn.txt 只剩 12 字节
        // （"中文测试"），后两行 emoji/结束被当无冒号行丢掉，而 file_write 仍报 success。
        final result = ToolArgsParser.parse('''
            path: /tmp/ai_terminal_llm_cn.txt
            content: 中文测试
              emoji 😀🚀
              结束
        ''');
        expect(result, isNull);
      });

      test('content 一行内用 \\n 转义 → 正常解析（纠错提示的形状）', () {
        final result = ToolArgsParser.parse(
          r'path: /tmp/x.txt' '\n' r'content: 中文测试\nemoji 😀🚀\n结束',
        );
        expect(result, isNotNull);
        expect(result!['content'], r'中文测试\nemoji 😀🚀\n结束');
      });

      test('空字符串返回 null', () {
        expect(ToolArgsParser.parse(''), isNull);
        expect(ToolArgsParser.parse('   '), isNull);
        expect(ToolArgsParser.parse('\\n\\n'), isNull);
      });

      test('JSON 格式输入直接返回 null（已弃用 JSON）', () {
        // 用户要求彻底弃用 JSON，JSON 格式不再被识别
        // 即使输入是合法 JSON，也返回 null（强制 AI 使用多行格式）
        expect(ToolArgsParser.parse('{"local":"/path"}'), isNull);
        expect(ToolArgsParser.parse('{local: path}'), isNull);
      });
    });
  });
}
