import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/reconnect_policy.dart';

void main() {
  group('ReconnectPolicy.delayForAttempt', () {
    test('指数退避 1s/2s/4s/8s/16s/32s', () {
      expect(ReconnectPolicy.delayForAttempt(0), const Duration(seconds: 1));
      expect(ReconnectPolicy.delayForAttempt(1), const Duration(seconds: 2));
      expect(ReconnectPolicy.delayForAttempt(2), const Duration(seconds: 4));
      expect(ReconnectPolicy.delayForAttempt(3), const Duration(seconds: 8));
      expect(ReconnectPolicy.delayForAttempt(4), const Duration(seconds: 16));
      expect(ReconnectPolicy.delayForAttempt(5), const Duration(seconds: 32));
    });

    test('累计窗口覆盖 NAT 回收/对端重启（≥60s）', () {
      final total = List.generate(ReconnectPolicy.maxAttempts,
              (i) => ReconnectPolicy.delayForAttempt(i))
          .fold(Duration.zero, (a, b) => a + b);
      expect(total, const Duration(seconds: 63));
    });

    test('负数按 0 处理', () {
      expect(ReconnectPolicy.delayForAttempt(-1), const Duration(seconds: 1));
      expect(ReconnectPolicy.delayForAttempt(-100), const Duration(seconds: 1));
    });
  });

  group('ReconnectPolicy.shouldRetry', () {
    test('最多 6 次', () {
      expect(ReconnectPolicy.maxAttempts, 6);
      for (var i = 0; i < ReconnectPolicy.maxAttempts; i++) {
        expect(ReconnectPolicy.shouldRetry(i), isTrue, reason: '第 $i 次应允许');
      }
      expect(ReconnectPolicy.shouldRetry(ReconnectPolicy.maxAttempts), isFalse);
      expect(ReconnectPolicy.shouldRetry(99), isFalse);
    });
  });
}
