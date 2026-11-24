import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/widgets/provider_logo.dart';

/// 服务商 logo 资源校验。
///
/// 图标按 `assets/provider_logos/<id>.svg` 约定查找，配置里没有任何字段指向它，
/// 所以「新增了服务商但没下载 logo」不会有任何编译期或运行期报错——UI 只会悄悄
/// 退回 emoji。这个测试把资源与 `ai_providers.json` 的 id 列表、以及单色/彩色
/// 染色集合绑在一起校验。
void main() {
  const logoDir = 'assets/provider_logos';
  // 没有自有品牌的条目：统一走 emoji 回退
  const noBrandIds = {'custom'};

  Map<String, dynamic> loadConfig() {
    final raw = File('assets/config/ai_providers.json').readAsStringSync();
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  test('每个有品牌的服务商都有 logo 资源', () {
    final ids = (loadConfig()['providers'] as List<dynamic>)
        .map((e) => (e as Map<String, dynamic>)['id'] as String)
        .where((id) => !noBrandIds.contains(id))
        .toList();

    expect(ids, isNotEmpty);

    final missing =
        ids.where((id) => !File('$logoDir/$id.svg').existsSync()).toList();
    expect(missing, isEmpty, reason: '缺少官方 logo，需下载后放入 $logoDir');
  });

  test('单色染色集合与 svg 实际填充方式一致', () {
    final files = Directory(logoDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.svg'))
        .toList();
    expect(files, isNotEmpty);

    final monoFiles = files
        .where((f) => f.readAsStringSync().contains('currentColor'))
        .map((f) => f.uri.pathSegments.last.replaceAll('.svg', ''))
        .toSet();

    expect(ProviderLogo.monoLogoIds, monoFiles,
        reason: 'svg 用 fill="currentColor" 才需要按主题染色，集合需与资源对齐');
  });

  test('已注册 logo 的 id 与目录里的资源一一对应', () {
    final fileIds = Directory(logoDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.svg'))
        .map((f) => f.uri.pathSegments.last.replaceAll('.svg', ''))
        .toSet();

    expect(ProviderLogo.logoIds, fileIds,
        reason: '资源存在但未登记（或未清理），未登记的服务商会退回 emoji');
  });
}
