import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/live_thought_text.dart';

void main() {
  group('extractLiveThought', () {
    test('没有协议头时原样返回（纯文本回答）', () {
      expect(extractLiveThought('先看一下磁盘占用'), '先看一下磁盘占用');
    });

    test('取最后一段思考，不含协议头', () {
      const raw = '思考: 第一步先确认系统版本\n'
          '动作: execute\n'
          '命令: uname -a\n'
          '思考：第二步再看磁盘\n'
          '动作: execute';
      expect(extractLiveThought(raw), '第二步再看磁盘');
    });

    test('思考后面紧跟协议行时在协议行处截断', () {
      const raw = '思考: 我先确认一下\n动作: execute\n命令: df -h';
      expect(extractLiveThought(raw), '我先确认一下');
    });

    test('超长推理只保留尾部，避免把整段历史推进界面', () {
      final raw = '思考: ${'甲' * 200}\n动作: execute';
      final text = extractLiveThought(raw, maxChars: 50);
      expect(text.length, 50);
      expect(text, '甲' * 50);
    });

    test('思考还没写内容时返回空串', () {
      expect(extractLiveThought('思考: '), isEmpty);
      expect(extractLiveThought('思考: \n动作: execute'), isEmpty);
    });

    // 性能优化后只扫尾部 4096 字符窗口，以下用例保证长文本行为不变
    test('超长历史 + 尾部当前思考：仍取最后一段思考', () {
      final raw = '思考: 旧思考\n动作: execute\n命令: uname -a\n'
          '${'填' * 80}\n' * 80 +
          '思考: 当前正在想的内容';
      expect(raw.length, greaterThan(4096));
      expect(extractLiveThought(raw), '当前正在想的内容');
    });

    test('单段思考超过扫描窗口：仍只保留尾部 maxChars', () {
      final raw = '思考: ${'甲' * 5000}';
      final text = extractLiveThought(raw);
      expect(text.length, 1200);
      expect(text, '甲' * 1200);
    });

    test('窗口内的思考后跟协议行：仍在协议行处截断', () {
      final raw = '${'填' * 80}\n' * 80 + '思考: 我先确认一下\n命令: df -h';
      expect(raw.length, greaterThan(4096));
      expect(extractLiveThought(raw), '我先确认一下');
    });

    test('思考标记在窗口外 + 超长回答：仍显示思考而非回答尾部（回退全扫）', () {
      // 「思考:」距离文末超过 4096，窗口内没有标记；若直接用窗口文本
      // 会把回答尾部误显示为思考。必须回退全量扫描并在协议行截断。
      final raw = '思考: 当前步骤的思考内容\n回答: ${'答' * 5000}';
      expect(extractLiveThought(raw), '当前步骤的思考内容');
    });

    test('全文无思考标记的超长纯文本：保留尾部 maxChars', () {
      final raw = '纯' * 6000;
      final text = extractLiveThought(raw);
      expect(text.length, 1200);
      expect(text, '纯' * 1200);
    });
  });
}
