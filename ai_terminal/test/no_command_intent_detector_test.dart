import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/no_command_intent_detector.dart';

void main() {
  group('NoCommandIntentDetector', () {
    test('显式禁止执行命令 → 命中', () {
      const cases = [
        '严禁执行任何命令，只根据你对本会话的记忆回答',
        '不要执行命令，直接告诉我结论',
        '这个会话里禁止执行命令',
        '无需执行命令，你只要解释一下就行',
        '不用运行命令，凭已有信息回答',
        '不需要执行任何 shell 命令',
        '别执行命令',
        '请不要调用任何指令',
        '不得执行任何命令',
      ];
      for (final text in cases) {
        expect(NoCommandIntentDetector.detects(text), isTrue, reason: text);
      }
    });

    test('英文写法 → 命中', () {
      const cases = [
        'Do not run any commands, just answer from the conversation',
        "don't execute commands",
        'answer without commands',
        'never issue any shell commands',
      ];
      for (final text in cases) {
        expect(NoCommandIntentDetector.detects(text), isTrue, reason: text);
      }
    });

    test('只禁止某一类命令 → 不命中（只读命令仍该跑）', () {
      const cases = [
        '禁止执行安装命令，其他只读命令照常',
        '不要运行修改类命令',
        '先别执行删除命令，等我确认',
        'don\'t run install commands',
      ];
      for (final text in cases) {
        expect(NoCommandIntentDetector.detects(text), isFalse, reason: text);
      }
    });

    test('普通任务描述 → 不命中', () {
      const cases = [
        '检查一下 nginx 是否还在跑',
        '帮我看看这条命令的输出有什么问题',
        '这条命令是什么意思',
        '执行 ls 看一下当前目录',
        '特别命令模式下需要 root 权限',
        '需要用命令行工具看下端口',
        'we need command-line tools to continue',
        '',
        '   ',
      ];
      for (final text in cases) {
        expect(NoCommandIntentDetector.detects(text), isFalse, reason: text);
      }
    });
  });
}
