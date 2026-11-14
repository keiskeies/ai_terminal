import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/port_forward_service.dart';

class _RecordingSink implements StreamSink<List<int>> {
  final written = <List<int>>[];
  bool closed = false;

  @override
  void add(List<int> data) {
    if (closed) throw StateError('sink already closed');
    written.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> get done => Future.value();
}

class _FakeEndpoint {
  final incoming = StreamController<List<int>>();
  final sink = _RecordingSink();
  bool closed = false;

  PipeEndpoint get endpoint => (
        stream: incoming.stream,
        sink: sink,
        close: () async {
          closed = true;
        },
      );

  Future<void> dispose() => incoming.close();
}

void main() {
  group('pipeEndpoints', () {
    test('双向泵送数据', () async {
      final a = _FakeEndpoint();
      final b = _FakeEndpoint();
      final done = pipeEndpoints(a.endpoint, b.endpoint);
      a.incoming.add([1, 2]);
      b.incoming.add([3, 4]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(b.sink.written, [
        [1, 2]
      ]);
      expect(a.sink.written, [
        [3, 4]
      ]);
      a.incoming.close();
      await done;
      await a.dispose();
      await b.dispose();
    });

    test('一侧结束即关闭两侧', () async {
      final a = _FakeEndpoint();
      final b = _FakeEndpoint();
      final done = pipeEndpoints(a.endpoint, b.endpoint);
      a.incoming.close();
      await done;
      expect(a.closed, isTrue);
      expect(b.closed, isTrue);
      await a.dispose();
      await b.dispose();
    });

    test('一侧出错即关闭两侧', () async {
      final a = _FakeEndpoint();
      final b = _FakeEndpoint();
      final done = pipeEndpoints(a.endpoint, b.endpoint);
      a.incoming.addError('boom');
      await done;
      expect(a.closed, isTrue);
      expect(b.closed, isTrue);
      await a.dispose();
      await b.dispose();
    });
  });

  group('PortForwardRule', () {
    test('label 按方向展示', () {
      final local = PortForwardRule(
        id: '1',
        direction: ForwardDirection.local,
        bindHost: '127.0.0.1',
        bindPort: 8080,
        targetHost: '10.0.0.5',
        targetPort: 80,
      );
      expect(local.label, '127.0.0.1:8080 → 10.0.0.5:80');
      final remote = PortForwardRule(
        id: '2',
        direction: ForwardDirection.remote,
        bindHost: '0.0.0.0',
        bindPort: 9000,
        targetHost: '127.0.0.1',
        targetPort: 3000,
      );
      expect(remote.label, '127.0.0.1:3000 ← 0.0.0.0:9000');
    });
  });

  group('PortForwardService', () {
    test('remove 未知 id 无副作用，dispose 可重复调用', () async {
      final service = PortForwardService();
      await service.remove('missing');
      expect(service.rules, isEmpty);
      service.dispose();
      service.dispose();
    });
  });
}