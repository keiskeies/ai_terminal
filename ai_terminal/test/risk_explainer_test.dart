import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/risk_explainer.dart';

void main() {
  group('RiskExplainer', () {
    test('restart service explains interruption and no auto rollback', () {
      final explanation = RiskExplainer.explain('sudo systemctl restart nginx');
      expect(explanation.impact, contains('重启服务'));
      expect(explanation.reason, isNotNull);
      expect(explanation.canRollback, isFalse);
      expect(explanation.rollbackCommand, isNull);
    });

    test('install explains dependency impact and provides rollback', () {
      final explanation = RiskExplainer.explain('sudo apt install nginx');
      expect(explanation.impact, contains('安装'));
      expect(explanation.canRollback, isTrue);
      expect(explanation.rollbackCommand, contains('remove nginx'));
    });

    test('permission change explains access impact without auto rollback', () {
      final explanation = RiskExplainer.explain('sudo chmod 777 /etc/nginx');
      expect(explanation.impact, contains('权限'));
      expect(explanation.canRollback, isFalse);
    });
  });
}
