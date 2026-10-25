import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/verification_detector.dart';

void main() {
  group('VerificationDetector', () {
    test('systemctl is-active active/inactive', () {
      final active = VerificationDetector.detect(
        command: 'systemctl is-active nginx',
        output: 'active\n',
        success: true,
      );
      expect(active?.text, 'nginx 运行中');
      expect(active?.level, 'success');

      final inactive = VerificationDetector.detect(
        command: 'systemctl is-active nginx',
        output: 'inactive\n',
        success: false,
      );
      expect(inactive?.text, 'nginx 未运行');
      expect(inactive?.level, 'warning');
    });

    test('systemctl is-enabled', () {
      final badge = VerificationDetector.detect(
        command: 'systemctl is-enabled nginx',
        output: 'enabled',
        success: true,
      );
      expect(badge?.text, 'nginx 开机自启');
      expect(badge?.level, 'success');
    });

    test('ss listening ports', () {
      const output = '''
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port
LISTEN 0      511          0.0.0.0:80         0.0.0.0:*
LISTEN 0      511             [::]:443           [::]:*
''';
      final badge = VerificationDetector.detect(
        command: 'ss -lntp',
        output: output,
        success: true,
      );
      expect(badge?.text, '端口 80/443 监听');
      expect(badge?.level, 'success');
    });

    test('nginx -t', () {
      final ok = VerificationDetector.detect(
        command: 'nginx -t',
        output: 'syntax is ok',
        success: true,
      );
      expect(ok?.text, 'Nginx 配置检查通过');

      final failed = VerificationDetector.detect(
        command: 'nginx -t',
        output: 'syntax error',
        success: false,
      );
      expect(failed?.text, 'Nginx 配置检查失败');
      expect(failed?.level, 'warning');
    });

    test('curl HTTP status', () {
      final ok = VerificationDetector.detect(
        command: 'curl -I https://example.com',
        output: 'HTTP/2 200\nserver: nginx',
        success: true,
      );
      expect(ok?.text, 'HTTP 200');
      expect(ok?.level, 'success');

      final notFound = VerificationDetector.detect(
        command: 'curl -I https://example.com',
        output: 'HTTP/1.1 404 Not Found',
        success: false,
      );
      expect(notFound?.text, 'HTTP 404');
      expect(notFound?.level, 'warning');
    });

    test('unknown command produces no badge', () {
      expect(
        VerificationDetector.detect(
          command: 'ls -la',
          output: 'total 0',
          success: true,
        ),
        isNull,
      );
    });
  });
}
