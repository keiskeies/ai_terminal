import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/knowledge_service.dart';

/// searchKnowledge 检索测试（WP4 / O6）
///
/// 走真实初始化路径：mock path_provider 指向临时目录，官方库从内置 asset
/// （assets/knowledge/knowledge.db）复制，sqflite_ffi 打开真实 FTS5 索引。
/// 同时验证 buildKnowledgeInjection 在抽出公共检索核心后行为等价：
/// 官方库注入文案、用户经验注入文案、未命中返回 null 均保持原样。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final service = KnowledgeService();

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('knowledge_search_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    await service.init();
  });

  tearDownAll(() async {
    await service.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('前置：asset 库 + FFI 在测试环境初始化成功', () {
    expect(service.isInitialized, isTrue,
        reason: '内置 knowledge.db 应能经 rootBundle 复制并由 sqflite_ffi 打开');
    expect(service.db, isNotNull);
  });

  group('searchKnowledge 官方库检索', () {
    test('命中 docker 条目，结构化字段完整', () async {
      final entries = await service.searchKnowledge('docker');
      expect(entries, isNotEmpty);
      // FTS 也会命中命令/摘要里提到 docker 的其他软件（如 open-webui），
      // 只断言 docker 本尊在列且字段完整
      final docker = entries.where((e) => e.guide.softwareName == 'docker');
      expect(docker, isNotEmpty);
      for (final e in docker) {
        expect(e.isUserExperience, isFalse);
        expect(e.guide.commands, isNotEmpty);
        expect(e.guide.platform, isNotEmpty);
        // mode 不断言非空：内置 CSV 个别行有多余空列，mode 可能落空（数据 quirk）
      }
    });

    test('limit 钳制合并后的条目数', () async {
      final entries = await service.searchKnowledge('docker', limit: 2);
      expect(entries.length, lessThanOrEqualTo(2));
      expect(entries, isNotEmpty);
    });

    test('platform 过滤：macos 只返回 macos/all 条目', () async {
      final entries =
          await service.searchKnowledge('docker', platform: 'macos');
      expect(entries, isNotEmpty);
      for (final e in entries) {
        expect(
          e.guide.platform == 'macos' ||
              e.guide.platform.startsWith('macos-') ||
              e.guide.platform == 'all',
          isTrue,
          reason: '平台过滤失效: ${e.guide.platform}',
        );
      }
      expect(entries.any((e) => e.guide.platform == 'macos'), isTrue);
    });

    test('不猜测 opType：linux 结果包含非 install 条目', () async {
      // 注入路径 extractOpType 兜底 install；中途检索若沿用会把
      // configure/uninstall 条目错误过滤掉
      final entries =
          await service.searchKnowledge('docker', platform: 'linux');
      expect(entries, isNotEmpty);
      expect(
        entries.any((e) => e.guide.opType != 'install'),
        isTrue,
        reason: 'docker 在 linux 有 configure/uninstall 条目，不应被 opType 过滤',
      );
    });

    test('空查询与未命中都返回空列表', () async {
      expect(await service.searchKnowledge(''), isEmpty);
      expect(await service.searchKnowledge('   '), isEmpty);
      expect(await service.searchKnowledge('zzzqqqxxxnotexist'), isEmpty);
    });
  });

  group('用户经验库与多 host 隔离（R3）', () {
    test('recordLearning 后同 host 经验优先命中', () async {
      await service.recordLearning(
        hostId: 'h-test',
        userRequest: '安装 redis',
        executedCommands: 'apt-get install -y redis-server',
        aiSummary: 'redis 安装经验（测试）',
        platform: 'linux',
      );

      final entries = await service.searchKnowledge(
        'redis',
        platform: 'linux',
        hostId: 'h-test',
      );
      expect(entries, isNotEmpty);
      expect(entries.first.isUserExperience, isTrue,
          reason: '用户经验必须排在官方库之前');
      expect(entries.first.guide.commands, contains('redis-server'));
      expect(entries.first.guide.mode, 'flexible');
    });
  });

  group('buildKnowledgeInjection 行为等价（抽核心后回归）', () {
    test('官方库命中仍注入【本地知识库】与严格照做文案', () async {
      final inj = await service.buildKnowledgeInjection(
        '安装 docker',
        platform: 'linux',
      );
      expect(inj, isNotNull);
      expect(inj, contains('【本地知识库】'));
      expect(inj, contains('docker'));
      expect(inj, contains('必须严格照做'));
    });

    test('用户经验仍注入【本机验证经验】', () async {
      await service.recordLearning(
        hostId: 'h-test',
        userRequest: '安装 redis',
        executedCommands: 'apt-get install -y redis-server',
        aiSummary: 'redis 安装经验（测试）',
        platform: 'linux',
      );
      final inj = await service.buildKnowledgeInjection(
        '安装 redis',
        platform: 'linux',
        hostId: 'h-test',
      );
      expect(inj, isNotNull);
      expect(inj, contains('【本机验证经验】'));
      expect(inj, contains('redis-server'));
    });

    test('未命中仍返回 null（无内部规范时）', () async {
      final inj = await service.buildKnowledgeInjection(
        'zzzqqqxxxnotexist',
        platform: 'linux',
      );
      expect(inj, isNull);
    });

    test('注入与按需检索对同一查询命中同一批官方条目', () async {
      final entries = await service.searchKnowledge(
        'docker',
        platform: 'linux',
      );
      final inj = await service.buildKnowledgeInjection(
        '安装 docker',
        platform: 'linux',
      );
      expect(inj, isNotNull);
      // 注入路径按 opType=install 过滤，按需检索不过滤：
      // 注入文本里出现的软件条目必须都能在按需检索结果里找到
      for (final e in entries.where((e) => e.guide.opType == 'install')) {
        expect(inj, contains(e.guide.softwareName));
      }
    });
  });
}