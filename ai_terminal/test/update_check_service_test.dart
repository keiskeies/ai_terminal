import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/services/update_check_service.dart';

void main() {
  group('normalizeVersion', () {
    test('去掉 v 前缀与 +build 元数据', () {
      expect(normalizeVersion('v1.4.0'), '1.4.0');
      expect(normalizeVersion('1.4.0+14'), '1.4.0');
      expect(normalizeVersion('V1.4.0+14'), '1.4.0');
      expect(normalizeVersion('  v2.0  '), '2.0');
    });
  });

  group('compareVersions', () {
    test('相等', () {
      expect(compareVersions('1.4.0', '1.4.0'), 0);
      expect(compareVersions('v1.4.0', '1.4.0+14'), 0);
    });

    test('逐段按数值比，不是字典序', () {
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.9.9', '1.10.0'), lessThan(0));
    });

    test('段数不等时缺位按 0', () {
      expect(compareVersions('1.4', '1.4.0'), 0);
      expect(compareVersions('1.4.1', '1.4'), greaterThan(0));
    });

    test('tag 与 PackageInfo 读数都能直接比', () {
      // GitHub 返回 v1.4.0，本地是 1.4.0+14 —— 归一化后应判为同版本。
      expect(compareVersions(normalizeVersion('v1.4.0'), '1.4.0'), 0);
      // 新版发布后（tag v1.5.0）应判为更新。
      expect(compareVersions('1.5.0', '1.4.0'), greaterThan(0));
    });
  });
}
