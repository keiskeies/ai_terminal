import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/choice_request_detector.dart';

void main() {
  group('ChoiceRequestDetector', () {
    test('字母选项 + 明确请求 → 提取按钮文字', () {
      final r = ChoiceRequestDetector.detect(
        '安装 Docker 有两种方式：\n'
        'A. 使用官方源安装\n'
        'B. 使用清华镜像安装\n'
        '请回复选择 A 还是 B，我立即执行。',
      );
      expect(r, isNotNull);
      expect(r!.options, ['A. 使用官方源安装', 'B. 使用清华镜像安装']);
      expect(r.question, contains('安装 Docker 有两种方式'));
      expect(r.question, contains('请回复选择 A 还是 B'));
      expect(r.question, isNot(contains('A. 使用官方源安装')), reason: '选项行不该重复进提问正文');
    });

    test('选项写在提问之前也能识别', () {
      final r = ChoiceRequestDetector.detect(
        'A：先备份再升级\n'
        'B：直接升级\n'
        '请选择一个方案。',
      );
      expect(r, isNotNull);
      expect(r!.options, hasLength(2));
      expect(r.options.first, startsWith('A. '));
    });

    test('只有“请回复选择 A 还是 B”没有描述 → 生成字母按钮', () {
      final r = ChoiceRequestDetector.detect(
        '如需免 sudo 使用 docker，安装完成后我可以再给命令。\n'
        '请回复选择 A 还是 B（或直接说“用 A 但走清华镜像”），我立即执行。',
      );
      expect(r, isNotNull);
      expect(r!.options, ['方案 A', '方案 B']);
    });

    test('没有明确选择请求的长总结不误伤', () {
      final r = ChoiceRequestDetector.detect(
        '结论: 已完成检查\n'
        '现状: 服务运行正常\n'
        '变更: 无\n'
        '建议: 后续可以考虑 A 或 B 两种优化方式。',
      );
      expect(r, isNull);
    });

    test('普通编号列表没有选择请求不误伤', () {
      final r = ChoiceRequestDetector.detect(
        '执行完成，结果如下：\n'
        '1. 系统版本已确认\n'
        '2. 磁盘空间充足\n'
        '3. 服务状态正常',
      );
      expect(r, isNull);
    });

    test('单独的“请确认”不当作选择请求', () {
      final r = ChoiceRequestDetector.detect('请确认以上信息。');
      expect(r, isNull);
    });

    test('代码块里的示例不误伤', () {
      final r = ChoiceRequestDetector.detect(
        '这是一个格式示例：\n'
        '```\n'
        '请回复选择 A 还是 B\n'
        'A. 示例一\n'
        'B. 示例二\n'
        '```\n'
        '结论: 任务已完成',
      );
      expect(r, isNull);
    });

    test('中文编号选项 + 明确请求可识别', () {
      final r = ChoiceRequestDetector.detect(
        '请选择要安装的版本：\n'
        '1、稳定版\n'
        '2、最新版',
      );
      expect(r, isNotNull);
      expect(r!.options, ['1. 稳定版', '2. 最新版']);
    });
  });
}
