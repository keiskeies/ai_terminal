import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/services/sftp_service.dart';

void main() {
  test('同一 key 串行：第二个上传等待第一个释放', () async {
    const key = 'test-lock-a';
    await DirectoryUploadLock.acquire(key);
    expect(DirectoryUploadLock.isLocked(key), isTrue);

    var secondAcquired = false;
    final second =
        DirectoryUploadLock.acquire(key).then((_) => secondAcquired = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(secondAcquired, isFalse);

    DirectoryUploadLock.release(key);
    await second;
    expect(secondAcquired, isTrue);
    DirectoryUploadLock.release(key);
  });

  test('等待锁时取消会抛 SftpTransferCancelled', () async {
    const key = 'test-lock-b';
    await DirectoryUploadLock.acquire(key);

    final cancel = Completer<void>();
    final waiting = DirectoryUploadLock.acquire(key, cancelToken: cancel);
    cancel.complete();

    await expectLater(waiting, throwsA(isA<SftpTransferCancelled>()));
    DirectoryUploadLock.release(key);
  });

  test('不同 host:port:user 不互相阻塞', () async {
    const keyC = 'test-lock-c';
    const keyD = 'test-lock-d';
    await DirectoryUploadLock.acquire(keyC);
    await DirectoryUploadLock.acquire(keyD)
        .timeout(const Duration(seconds: 1));
    DirectoryUploadLock.release(keyC);
    DirectoryUploadLock.release(keyD);
  });

  test('取消令牌已完成时 acquire 直接失败', () async {
    final cancel = Completer<void>()..complete();
    await expectLater(
      DirectoryUploadLock.acquire('test-lock-e', cancelToken: cancel),
      throwsA(isA<SftpTransferCancelled>()),
    );
  });
}
