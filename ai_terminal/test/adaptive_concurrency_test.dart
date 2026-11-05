import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/adaptive_concurrency.dart';

void main() {
  group('chooseInitialUploadConcurrency', () {
    test('按平均文件大小分档', () {
      expect(
        chooseInitialUploadConcurrency(fileCount: 0, averageBytes: 0),
        1,
      );
      expect(
        chooseInitialUploadConcurrency(fileCount: 1, averageBytes: 1),
        1,
      );
      expect(
        chooseInitialUploadConcurrency(
            fileCount: 100, averageBytes: 100 * 1024),
        16,
      );
      expect(
        chooseInitialUploadConcurrency(
            fileCount: 100, averageBytes: 1 * 1024 * 1024),
        8,
      );
      expect(
        chooseInitialUploadConcurrency(
            fileCount: 100, averageBytes: 4 * 1024 * 1024),
        4,
      );
      expect(
        chooseInitialUploadConcurrency(
            fileCount: 100, averageBytes: 16 * 1024 * 1024),
        2,
      );
    });
  });

  group('AdaptiveConcurrency', () {
    test('连续失败 3 次减半，最低 1', () {
      final c = AdaptiveConcurrency(initial: 16);
      c.onFailure();
      c.onFailure();
      expect(c.current, 16, reason: '不足 3 次不降');
      c.onFailure();
      expect(c.current, 8);
      for (var i = 0; i < 3; i++) {
        c.onFailure();
      }
      expect(c.current, 4);
      for (var i = 0; i < 3; i++) {
        c.onFailure();
      }
      expect(c.current, 2);
      for (var i = 0; i < 3; i++) {
        c.onFailure();
      }
      expect(c.current, 1);
      for (var i = 0; i < 9; i++) {
        c.onFailure();
      }
      expect(c.current, 1, reason: '不能低于 1');
      expect(c.degraded, isTrue);
    });

    test('持续成功逐步恢复到初始值，不超过初始', () {
      final c = AdaptiveConcurrency(initial: 8);
      for (var i = 0; i < 3; i++) {
        c.onFailure();
      }
      expect(c.current, 4);
      for (var i = 0; i < 20; i++) {
        c.onSuccess();
      }
      expect(c.current, 5);
      for (var i = 0; i < 200; i++) {
        c.onSuccess();
      }
      expect(c.current, 8);
    });

    test('成功会重置失败连击', () {
      final c = AdaptiveConcurrency(initial: 16);
      c.onFailure();
      c.onFailure();
      c.onSuccess();
      c.onFailure();
      c.onFailure();
      expect(c.current, 16, reason: '失败不连续时不降');
    });

    test('固定模式不随成功/失败变化', () {
      final c = AdaptiveConcurrency(initial: 8, adaptive: false);
      for (var i = 0; i < 10; i++) {
        c.onFailure();
      }
      expect(c.current, 8);
      expect(c.degraded, isFalse);
    });
  });
}
