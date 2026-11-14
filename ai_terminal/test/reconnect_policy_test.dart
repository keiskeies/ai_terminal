import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/reconnect_policy.dart';

void main() {
  group('ReconnectPolicy.delayForAttempt', () {
    test('指数退避 1s/2s/4s', () {
      expect(ReconnectPolicy.delayForAttempt(0), const Duration(seconds: 1));
      expect(ReconnectPolicy.delayForAttempt(1), const Duration(seconds: 2));
      expect(ReconnectPolicy.delayForAttempt(2), const Duration(seconds: 4));
    });

    test('负数按 0 处理', () {
      expect(ReconnectPolicy.delayForAttempt(-1), const Duration(seconds: 1));
      expect(ReconnectPolicy.delayForAttempt(-100), const Duration(seconds: 1));
    });
  });

  group('ReconnectPolicy.shouldRetry', () {
    test('最多 3 次', () {
      expect(ReconnectPolicy.maxAttempts, 3);
      expect(ReconnectPolicy.shouldRetry(0), isTrue);
      expect(ReconnectPolicy.shouldRetry(1), isTrue);
      expect(ReconnectPolicy.shouldRetry(2), isTrue);
      expect(ReconnectPolicy.shouldRetry(3), isFalse);
      expect(ReconnectPolicy.shouldRetry(99), isFalse);
    });
  });
}