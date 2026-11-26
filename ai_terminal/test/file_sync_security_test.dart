import 'dart:async';
import 'dart:io';

import 'package:ai_terminal/services/file_sync_service.dart';
import 'package:ai_terminal/services/sftp_service.dart';
import 'package:ai_terminal/utils/local_file_ops.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSshClient implements SSHClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSftpService implements SftpService {
  final List<Completer<void>> started = [];
  final List<Completer<UploadDirectoryResult>> completers = [];

  @override
  Future<void> attachToClient(SSHClient client) async {}

  @override
  Future<UploadDirectoryResult> uploadDirectory(
    String localDir,
    String remoteDir, {
    List<String> excludeNames = const ['node_modules', '.git', '.DS_Store'],
    void Function(int uploaded, int total)? onProgress,
    int? concurrency,
    Completer<void>? cancelToken,
    LocalPathAuthorizer? validateLocalPath,
  }) async {
    final signal = Completer<void>();
    final completion = Completer<UploadDirectoryResult>();
    started.add(signal);
    completers.add(completion);
    signal.complete();
    return completion.future;
  }

  void release(int index) {
    completers[index].complete(UploadDirectoryResult());
  }

  Future<void> waitForUpload(int index) async {
    while (started.length <= index) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory sandbox;
  late _FakeSftpService sftp;
  late FileSyncService service;
  late SSHClient client;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('ai_file_sync_security_');
    sandbox = Directory(await sandbox.resolveSymbolicLinks());
    sftp = _FakeSftpService();
    service = FileSyncService(sftp: sftp);
    client = _FakeSshClient();
  });

  tearDown(() async {
    service.dispose();
    await sandbox.delete(recursive: true);
  });

  SyncConfig config() => SyncConfig(
        localDir: sandbox.path,
        remoteDir: '/remote/story',
      );

  test('授权失效后看门狗主动停止 watcher 和定时器', () async {
    var authorized = true;
    final stopped = service.events.firstWhere(
      (event) => event.type == SyncEventType.info && event.message == '同步已停止',
    );
    final started = await service.start(
      clientGetter: () => client,
      config: config(),
      authorizationCheck: () => authorized,
      authorizationCheckInterval: const Duration(milliseconds: 10),
    );
    expect(started, isTrue);
    expect(service.isRunning, isTrue);

    authorized = false;
    await stopped.timeout(const Duration(seconds: 3));

    expect(service.isRunning, isFalse);
    service.dispose();
  });

  test('启动授权等待期间拒绝重复启动', () async {
    final gate = Completer<void>();
    final first = service.start(
      clientGetter: () => client,
      config: config(),
      validateLocalPath: (_, __) async {
        await gate.future;
        return null;
      },
    );

    final second = await service.start(
      clientGetter: () => client,
      config: config(),
    );
    expect(second, isFalse);

    gate.complete();
    expect(await first, isTrue);
    expect(service.isRunning, isTrue);
  });

  test('启动等待期间停止会让旧启动失败且不挂载资源', () async {
    final gate = Completer<void>();
    final starting = service.start(
      clientGetter: () => client,
      config: config(),
      validateLocalPath: (_, __) async {
        await gate.future;
        return null;
      },
    );

    await service.stop();
    gate.complete();

    expect(await starting, isFalse);
    expect(service.isRunning, isFalse);
    expect(sftp.started, isEmpty);
  });

  test('旧全量同步结束不会清除新运行的同步槽', () async {
    final events = <SyncEvent>[];
    final subscription = service.events.listen(events.add);
    expect(await service.start(clientGetter: () => client, config: config()),
        isTrue);
    final oldSync = service.fullSync();
    await sftp.waitForUpload(0);

    await service.stop();
    expect(await service.start(clientGetter: () => client, config: config()),
        isTrue);
    final newSync = service.fullSync();
    await sftp.waitForUpload(1);

    sftp.release(0);
    await oldSync;
    expect(events.where((event) => event.type == SyncEventType.uploadSuccess),
        isEmpty);
    await service.fullSync();
    await Future<void>.delayed(Duration.zero);
    expect(sftp.started, hasLength(2), reason: '新运行仍在同步时必须跳过第三次全量同步');

    sftp.release(1);
    await newSync;
    await Future<void>.delayed(Duration.zero);
    expect(events.where((event) => event.type == SyncEventType.uploadSuccess),
        hasLength(1));
    await subscription.cancel();
  });
}
