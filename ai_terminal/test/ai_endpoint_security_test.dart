import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/services/ai_endpoint_security.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AI 端点策略', () {
    test('仅允许回环 HTTP，其他地址必须使用 HTTPS', () {
      for (final base in [
        'http://localhost:11434/v1',
        'http://127.0.0.1:11434/v1',
        'http://[::1]:11434/v1',
        'https://api.example.com/v1',
      ]) {
        expect(AiEndpointSecurity.validateBase(base).scheme,
            base.startsWith('https') ? 'https' : 'http');
      }
      for (final base in [
        'http://api.example.com/v1',
        'http://192.168.1.10:11434/v1',
        'http://localhost.example.com/v1',
        'file:///tmp/key',
      ]) {
        expect(() => AiEndpointSecurity.validateBase(base),
            throwsA(isA<AiEndpointSecurityException>()));
      }
    });

    test('拒绝 userinfo、片段和 Base URL 查询参数', () {
      for (final base in [
        'https://user:pass@api.example.com/v1',
        'https://api.example.com/v1#fragment',
        'https://api.example.com/v1?token=secret',
      ]) {
        expect(() => AiEndpointSecurity.validateBase(base),
            throwsA(isA<AiEndpointSecurityException>()));
      }
    });

    test('安全拼接端点路径并保留 Base URL 路径', () {
      expect(
          AiEndpointSecurity.endpoint(
                  'https://api.example.com/v1/', 'chat/completions')
              .toString(),
          'https://api.example.com/v1/chat/completions');
      expect(
          AiEndpointSecurity.endpoint('https://api.example.com', 'models')
              .toString(),
          'https://api.example.com/models');
    });

    test('重定向只允许同源，拒绝跨源和协议降级', () {
      final current = Uri.parse('https://api.example.com/v1/chat');
      expect(AiEndpointSecurity.resolveRedirect(current, '/v2/chat').toString(),
          'https://api.example.com/v2/chat');
      for (final location in [
        'https://other.example.com/v2/chat',
        'http://api.example.com/v2/chat',
        'https://user:pass@api.example.com/v2/chat',
      ]) {
        expect(() => AiEndpointSecurity.resolveRedirect(current, location),
            throwsA(isA<AiEndpointSecurityException>()));
      }
    });
  });

  group('AI 凭据请求边界', () {
    test('非回环 HTTP 在适配器收到请求前拒绝且不携带凭据', () async {
      final adapter = _RecordingAdapter([]);
      final client = AiEndpointClient(_dioWith(adapter));

      await expectLater(
        client.post('http://api.example.com/v1', 'chat/completions',
            data: const {}, apiKey: 'sk-secret'),
        throwsA(isA<DioException>().having(
          (error) => error.error,
          'error',
          isA<AiEndpointSecurityException>(),
        )),
      );
      expect(adapter.requests, isEmpty);
      expect(
          mapDioError(DioException(
            requestOptions: RequestOptions(path: 'https://api.example.com'),
            error: const AiEndpointSecurityException('安全拒绝'),
          )),
          '安全拒绝');
    });

    test('OpenAIProvider 同样在发送前拒绝非回环 HTTP', () async {
      final adapter = _RecordingAdapter([]);
      final provider = OpenAIProvider(dio: _dioWith(adapter));
      await expectLater(
        provider.chatStream(
          history: const [],
          prompt: 'hello',
          config: _config('http://api.example.com/v1'),
        ),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requests, isEmpty);
    });

    test('回环 HTTP 与 HTTPS 允许并携带 Bearer', () async {
      for (final base in [
        'http://127.0.0.1:11434/v1',
        'https://api.example.com/v1',
      ]) {
        final adapter = _RecordingAdapter([_Reply.json('{}')]);
        final response = await AiEndpointClient(_dioWith(adapter)).get(
          base,
          'models',
          apiKey: 'sk-secret',
        );
        expect(response.statusCode, 200);
        expect(adapter.requests.single.uri.toString(), '$base/models');
        expect(adapter.requests.single.headers['Authorization'],
            'Bearer sk-secret');
        expect(adapter.requests.single.followRedirects, isFalse);
      }
    });

    test('同源重定向逐跳复验并保留凭据', () async {
      final adapter = _RecordingAdapter([
        _Reply(307, {
          'location': ['/v2/chat']
        }),
        _Reply.json('{"ok":true}'),
      ]);
      final response = await AiEndpointClient(_dioWith(adapter)).post(
        'https://api.example.com/v1',
        'chat/completions',
        data: const {'model': 'test'},
        apiKey: 'sk-secret',
      );
      expect(response.statusCode, 200);
      expect(adapter.requests.map((request) => request.uri.toString()), [
        'https://api.example.com/v1/chat/completions',
        'https://api.example.com/v2/chat',
      ]);
      expect(
          adapter.requests.every((request) =>
              request.headers['Authorization'] == 'Bearer sk-secret'),
          isTrue);
    });

    test('跨源或降级重定向被拒绝且取消响应流', () async {
      for (final location in [
        'https://other.example.com/chat',
        'http://api.example.com/chat',
      ]) {
        final cancelled = Completer<void>();
        final controller = StreamController<Uint8List>(
          onCancel: () => cancelled.complete(),
        );
        final adapter = _RecordingAdapter([
          _Reply(
              307,
              {
                'location': [location]
              },
              body: controller.stream),
        ]);
        await expectLater(
          AiEndpointClient(_dioWith(adapter)).post(
            'https://api.example.com/v1',
            'chat/completions',
            data: const {},
            apiKey: 'sk-secret',
            responseType: ResponseType.stream,
          ),
          throwsA(isA<DioException>()),
        );
        expect(controller.hasListener, isTrue);
        await cancelled.future.timeout(const Duration(seconds: 1));
        expect(adapter.requests, hasLength(1));
        controller.close();
      }
    });

    test('重定向次数与缺失 Location 均失败关闭', () async {
      final tooMany = _RecordingAdapter([
        for (var i = 0; i < 4; i++)
          _Reply(307, {
            'location': ['/next']
          }),
      ]);
      await expectLater(
        AiEndpointClient(_dioWith(tooMany))
            .get('https://api.example.com/v1', 'models', apiKey: 'sk-secret'),
        throwsA(isA<DioException>()),
      );
      expect(tooMany.requests, hasLength(4));

      final missing = _RecordingAdapter([_Reply(302, const {})]);
      await expectLater(
        AiEndpointClient(_dioWith(missing))
            .get('https://api.example.com/v1', 'models', apiKey: 'sk-secret'),
        throwsA(isA<DioException>()),
      );
      expect(missing.requests, hasLength(1));
    });
  });
}

Dio _dioWith(HttpClientAdapter adapter) => Dio()..httpClientAdapter = adapter;

AIModelConfig _config(String baseUrl) => AIModelConfig.create(
      id: 'security-test',
      provider: 'openai',
      name: 'Test',
      apiKey: 'sk-secret',
      baseUrl: baseUrl,
      modelName: 'test-model',
      maxTokens: 128,
      contextWindow: 0,
    );

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.replies);

  final List<_Reply> replies;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (replies.isEmpty) throw StateError('unexpected request: $options');
    return replies.removeAt(0).toBody();
  }

  @override
  void close({bool force = false}) {}
}

class _Reply {
  _Reply(this.status, this.headers, {Stream<Uint8List>? body})
      : body = body ??
            Stream.value(Uint8List.fromList(utf8.encode('{"ok":true}')));

  _Reply.json(String json)
      : status = 200,
        headers = const {
          'content-type': ['application/json']
        },
        body = Stream.value(Uint8List.fromList(utf8.encode(json)));

  final int status;
  final Map<String, List<String>> headers;
  final Stream<Uint8List> body;

  ResponseBody toBody() => ResponseBody(body, status, headers: headers);
}
