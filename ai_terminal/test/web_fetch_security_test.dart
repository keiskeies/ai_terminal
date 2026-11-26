import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/web_fetch_security.dart';
import 'package:ai_terminal/services/web_tools.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _NullExecutor implements CommandExecutor {
  @override
  bool get isConnected => true;

  @override
  Stream<String> get output => const Stream.empty();

  @override
  void execute(String command) {}

  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 1),
    Completer<void>? cancelToken,
    String? sudoPassword,
    Future<String?> Function(String prompt)? onInteractivePrompt,
  }) async =>
      CommandResult(
          stdout: '', stderr: '', exitCode: 0, duration: Duration.zero);

  @override
  Future<String> runOnce(String command,
          {Duration timeout = const Duration(seconds: 1)}) async =>
      '';

  @override
  Future<CommandResult> writeFileViaPty({
    required String path,
    required Uint8List content,
    bool useSudo = false,
    Duration timeout = const Duration(seconds: 1),
    Completer<void>? cancelToken,
  }) async =>
      CommandResult(
          stdout: '', stderr: '', exitCode: 0, duration: Duration.zero);

  @override
  void writeToTerminal(String data) {}
}

void main() {
  group('WebFetchPolicy', () {
    test('只接受公网 HTTPS 且拒绝 URL 内嵌凭据', () {
      expect(WebFetchPolicy.validate(Uri.parse('https://8.8.8.8/docs')).host,
          '8.8.8.8');
      expect(
          WebFetchPolicy.validate(Uri.parse('https://[2606:4700:4700::1111]/'))
              .scheme,
          'https');
      expect(() => WebFetchPolicy.validate(Uri.parse('http://example.com/')),
          throwsA(isA<WebFetchBlockedException>()));
      expect(
          () => WebFetchPolicy.validate(
              Uri.parse('https://user:password@example.com/')),
          throwsA(isA<WebFetchBlockedException>()));
    });

    test('拒绝 IPv4 私网、保留、链路本地和元数据地址', () {
      const blocked = [
        '0.0.0.0',
        '10.1.2.3',
        '100.64.0.1',
        '127.0.0.1',
        '169.254.169.254',
        '172.16.0.1',
        '172.31.255.255',
        '192.0.0.1',
        '192.168.1.1',
        '198.18.0.1',
        '192.0.2.1',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
        '255.255.255.255',
      ];
      for (final value in blocked) {
        expect(
          WebFetchPolicy.isPublicAddress(InternetAddress(value)),
          isFalse,
          reason: value,
        );
      }
      expect(
          WebFetchPolicy.isPublicAddress(InternetAddress('8.8.8.8')), isTrue);
      expect(
          WebFetchPolicy.isPublicAddress(InternetAddress('1.1.1.1')), isTrue);
    });

    test('拒绝 IPv6 回环、映射私网、ULA、链路本地和特殊前缀', () {
      const blocked = [
        '::',
        '::1',
        '::ffff:127.0.0.1',
        '::ffff:10.0.0.1',
        '::127.0.0.1',
        '64:ff9b::7f00:1',
        '64:ff9b:1::a00:1',
        '100::1',
        '2001::1',
        '2001:db8::1',
        '2002:7f00:1::1',
        '3fff::1',
        'fc00::1',
        'fd00::1',
        'fe80::1',
        'fec0::1',
        'ff02::1',
        '5f00::1',
      ];
      for (final value in blocked) {
        expect(
          WebFetchPolicy.isPublicAddress(InternetAddress(value)),
          isFalse,
          reason: value,
        );
      }
      expect(
        WebFetchPolicy.isPublicAddress(InternetAddress('2606:4700:4700::1111')),
        isTrue,
      );
      expect(
        WebFetchPolicy.isPublicAddress(InternetAddress('::ffff:8.8.8.8')),
        isTrue,
      );
    });

    test('拒绝单标签、localhost 和保留内网后缀', () {
      for (final host in [
        'metadata',
        'localhost',
        'router.local',
        'service.internal',
        'host.lan',
        'nas.home.arpa',
      ]) {
        expect(
          () => WebFetchPolicy.validate(Uri.parse('https://$host/')),
          throwsA(isA<WebFetchBlockedException>()),
          reason: host,
        );
      }
    });

    test('拒绝畸形主机名和非标准数字 IPv4 写法', () {
      for (final host in [
        'example..com',
        '-example.com',
        'example-.com',
        'example.123',
        '2130706433',
        '127.1',
        '0x7f000001',
        '0177.0.0.1',
      ]) {
        expect(
          () => WebFetchPolicy.validate(Uri.parse('https://$host/')),
          throwsA(isA<WebFetchBlockedException>()),
          reason: host,
        );
      }
    });

    test('混合 DNS 结果中只要有一个非公网地址就整体拒绝', () {
      expect(
        () => WebFetchPolicy.validateResolvedAddresses([
          InternetAddress('8.8.8.8'),
          InternetAddress('127.0.0.1'),
        ]),
        throwsA(isA<WebFetchBlockedException>()),
      );
      expect(
        () => WebFetchPolicy.validateResolvedAddresses(const []),
        throwsA(isA<WebFetchBlockedException>()),
      );
    });

    test('每一跳重定向重新校验协议和目的地', () {
      expect(
        WebFetchPolicy.resolveRedirect(
          Uri.parse('https://example.com/a'),
          '/b',
        ).toString(),
        'https://example.com/b',
      );
      for (final location in [
        'http://example.com/b',
        'https://127.0.0.1/b',
        'https://169.254.169.254/latest/meta-data',
        'https://user:pass@example.com/b',
        'file:///etc/passwd',
      ]) {
        expect(
          () => WebFetchPolicy.resolveRedirect(
            Uri.parse('https://example.com/a'),
            location,
          ),
          throwsA(isA<WebFetchBlockedException>()),
          reason: location,
        );
      }
    });
  });

  group('HTTP 响应解析与字节边界', () {
    test('同一网络 chunk 中的头部和 Content-Length 正文不丢失', () async {
      final parser = await WebFetchResponseParser.parse(Stream.value(utf8.encode(
          'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello')));
      addTearDown(parser.close);

      expect(parser.statusCode, 200);
      expect(parser.contentType, 'text/plain');
      expect(await parser.readBody(5), utf8.encode('hello'));
    });

    test('恰好等于正文上限时接受，超过时拒绝', () async {
      final parser = await WebFetchResponseParser.parse(Stream.value(
          utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello')));
      addTearDown(parser.close);
      expect(await parser.readBody(5), utf8.encode('hello'));

      final oversized = await WebFetchResponseParser.parse(Stream.value(
          utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nhello!')));
      addTearDown(oversized.close);
      await expectLater(
        oversized.readBody(5),
        throwsA(isA<WebFetchTooLargeException>()),
      );
    });

    test('无 Content-Length 时按连接关闭读取且有界', () async {
      final parser = await WebFetchResponseParser.parse(Stream.value(utf8
          .encode('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello')));
      addTearDown(parser.close);
      expect(await parser.readBody(5), utf8.encode('hello'));

      final oversized = await WebFetchResponseParser.parse(
          Stream.value(utf8.encode('HTTP/1.1 200 OK\r\n\r\nhello!')));
      addTearDown(oversized.close);
      await expectLater(
        oversized.readBody(5),
        throwsA(isA<WebFetchTooLargeException>()),
      );
    });

    test('chunked 支持扩展和 trailer，并逐字节保留正文', () async {
      final wire =
          utf8.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
              '2;ext=value\r\nhe\r\n3\r\nllo\r\n0\r\nX-Trailer: done\r\n\r\n');
      final parser = await WebFetchResponseParser.parse(
        Stream.fromIterable(wire.map((byte) => [byte])),
      );
      addTearDown(parser.close);
      expect(await parser.readBody(5), utf8.encode('hello'));
    });

    test('chunked 正文超限或截断均失败', () async {
      final oversized = await WebFetchResponseParser.parse(Stream.value(
          utf8.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
              '3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n')));
      addTearDown(oversized.close);
      await expectLater(
        oversized.readBody(5),
        throwsA(isA<WebFetchTooLargeException>()),
      );

      final truncated = await WebFetchResponseParser.parse(Stream.value(
          utf8.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
              '3\r\nab')));
      addTearDown(truncated.close);
      await expectLater(
        truncated.readBody(5),
        throwsA(isA<WebFetchNetworkException>()),
      );
    });

    test('Content-Length 截断、非法值和 framing 冲突均失败', () async {
      for (final wire in [
        'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhell',
        'HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n',
        'HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n',
        'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n'
            'Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
      ]) {
        final parser = await WebFetchResponseParser.parse(
          Stream.value(utf8.encode(wire)),
        );
        addTearDown(parser.close);
        await expectLater(
          parser.readBody(10),
          throwsA(isA<WebFetchNetworkException>()),
          reason: wire,
        );
      }
    });

    test('缺少头部空行终止符时拒绝而不是当作空头', () async {
      await expectLater(
        WebFetchResponseParser.parse(Stream.value(
            utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n'))),
        throwsA(isA<WebFetchNetworkException>()),
      );
    });

    test('跳过 1xx 响应并使用最终状态', () async {
      final parser = await WebFetchResponseParser.parse(
          Stream.value(utf8.encode('HTTP/1.1 100 Continue\r\n\r\n'
              'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')));
      addTearDown(parser.close);
      expect(parser.statusCode, 200);
      expect(await parser.readBody(2), utf8.encode('ok'));
    });

    test('响应头和单行都受上限约束', () async {
      await expectLater(
        WebFetchResponseParser.parse(Stream.value(
            utf8.encode('HTTP/1.1 200 OK\r\nX-Long: ${'a' * 9000}\r\n\r\n'))),
        throwsA(isA<WebFetchNetworkException>()),
      );
      await expectLater(
        WebFetchResponseParser.parse(Stream.value(utf8.encode(
            'HTTP/1.1 200 OK\r\n${List.filled(40, 'X: ${'a' * 1000}').join('\r\n')}'
            '\r\n\r\n'))),
        throwsA(isA<WebFetchNetworkException>()),
      );
    });

    test('头部解析失败时取消上游流', () async {
      final cancelled = Completer<void>();
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled.complete(),
      );
      addTearDown(controller.close);
      controller.add(utf8.encode('not-http\r\n'));

      await expectLater(
        WebFetchResponseParser.parse(controller.stream),
        throwsA(isA<WebFetchNetworkException>()),
      );
      await cancelled.future.timeout(const Duration(seconds: 1));
    });

    test('读取阶段使用绝对超时，慢速流不会无限续期', () async {
      final controller = StreamController<List<int>>();
      addTearDown(controller.close);
      await expectLater(
        WebFetchResponseParser.parse(
          controller.stream,
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<WebFetchNetworkException>()),
      );
    });
  });

  test('抓取前已取消时不进行 DNS 解析', () async {
    final token = CancelToken()..cancel();
    await expectLater(
      const WebFetchClient(timeout: Duration(seconds: 1), maxBytes: 10)
          .fetch(Uri.parse('https://example.com/'), cancelToken: token),
      throwsA(isA<DioException>().having(
        (error) => error.type,
        'type',
        DioExceptionType.cancel,
      )),
    );
  });

  test('FetchUrlTool 在进度回调和网络请求前拒绝危险 URL', () async {
    for (final url in [
      'https://127.0.0.1/private',
      'http://example.com/',
      'https://user:password@example.com/',
    ]) {
      final progress = <String>[];
      final result = await FetchUrlTool().execute(
        executor: _NullExecutor(),
        args: ToolArgs({'url': url}),
        onProgress: progress.add,
      );
      expect(result.success, isFalse);
      expect(result.error, contains('安全策略拒绝'));
      expect(progress, isEmpty, reason: url);
    }
  });
}
