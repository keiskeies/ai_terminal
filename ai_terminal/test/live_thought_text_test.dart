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
  });
}
