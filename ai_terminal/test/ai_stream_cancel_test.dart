import 'dart:async';
import 'dart:typed_data';

import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 取消聊天流时必须同时取消 Dio 上游响应订阅，否则连接会一直占着，
/// 网关继续推流、HTTP 连接池也无法回收。
void main() {
  test('取消令牌会关闭上游 SSE 响应流并结束下游流', () async {
    final body = _FakeResponseBody();
    final provider = OpenAIProvider(dio: _dioWith(body));
    final token = CancelToken();
    final done = Completer<void>();
    final errors = <Object>[];

    final stream = await provider.chatStream(
      history: const [],
      prompt: '',
      config: _config(),
      systemPrompt: 'test',
      cancelToken: token,
    );
    stream.listen(
      (_) {},
      onError: errors.add,
      onDone: done.complete,
    );
    await body.listening.future.timeout(const Duration(seconds: 1));

    token.cancel('测试取消');

    await body.cancelled.future.timeout(const Duration(seconds: 1));
    await done.future.timeout(const Duration(seconds: 1));
    expect(errors, isNotEmpty);
  });
}

Dio _dioWith(_FakeResponseBody body) {
  final dio = Dio();
  dio.httpClientAdapter = _FakeAdapter(body);
  return dio;
}

AIModelConfig _config() => AIModelConfig.create(
      id: 'cancel-test',
      provider: 'openai',
      name: 'Cancel Test',
      apiKey: 'test-key',
      baseUrl: 'https://test.example.com/v1',
      modelName: 'test-model',
      maxTokens: 128,
      contextWindow: 0,
    );

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.body);

  final _FakeResponseBody body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody(
        body.stream,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      );

  @override
  void close({bool force = false}) {}
}

class _FakeResponseBody {
  final _controller = StreamController<Uint8List>();
  final listening = Completer<void>();
  final cancelled = Completer<void>();

  _FakeResponseBody() {
    _controller
      ..onListen = (() {
        if (!listening.isCompleted) listening.complete();
      })
      ..onCancel = (() {
        if (!cancelled.isCompleted) cancelled.complete();
      });
    _controller.add(Uint8List.fromList(
        'data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'.codeUnits));
  }

  Stream<Uint8List> get stream => _controller.stream;
}
