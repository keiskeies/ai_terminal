import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/output_processor.dart';

/// O2 观测分级截断纯函数单测
///
/// 覆盖：查询尾 20000 不变、非查询成功尾 2000、失败头 2000 + 尾 6000，
/// 以及 R8 边界（恰好等于上限 / 空输出 / 短文本头尾不重叠）。
void main() {
  group('truncateQueryOutput（查询：尾 20000 不变）', () {
    test('null / 空输出 → (无输出)', () {
      expect(truncateQueryOutput(null), '(无输出)');
      expect(truncateQueryOutput(''), '(无输出)');
    });

    test('短输出原样返回', () {
      expect(truncateQueryOutput('hello\nworld'), 'hello\nworld');
    });

    test('恰好 20000 字符 → 不截断（R8 off-by-one）', () {
      final s = 'a' * maxQueryOutputChars;
      expect(truncateQueryOutput(s), s);
    });

    test('20001 字符 → 保留尾 20000，标注截断 1 字符', () {
      final s = 'H${'b' * maxQueryOutputChars}';
      final out = truncateQueryOutput(s);
      expect(out, contains('已截断前 1 字符'));
      expect(out, endsWith('b' * maxQueryOutputChars));
      expect(out, isNot(startsWith('H')));
    });

    test('超长输出保留尾部内容', () {
      final s = '${'x' * 30000}TAIL_MARKER';
      final out = truncateQueryOutput(s);
      expect(out, endsWith('TAIL_MARKER'));
      expect(out.length, lessThan(s.length));
    });
  });

  group('truncateSuccessOutput（非查询成功：尾 2000）', () {
    test('null / 空输出 → (无输出)', () {
      expect(truncateSuccessOutput(null), '(无输出)');
      expect(truncateSuccessOutput(''), '(无输出)');
    });

    test('恰好 2000 字符 → 不截断', () {
      final s = 'a' * maxSuccessOutputChars;
      expect(truncateSuccessOutput(s), s);
    });

    test('2001 字符 → 保留尾 2000，头部被丢弃', () {
      final s = 'HEAD_MARKER${'b' * (maxSuccessOutputChars - 10)}';
      expect(s.length, maxSuccessOutputChars + 1);
      final out = truncateSuccessOutput(s);
      expect(out, contains('已截断前 1 字符'));
      expect(out, endsWith('b' * (maxSuccessOutputChars - 10)));
      expect(out, isNot(contains('HEAD_MARKER')));
    });

    test('长输出保留尾部（Complete! 在末尾）', () {
      final s = '${'line\n' * 1000}Complete!';
      final out = truncateSuccessOutput(s);
      expect(out, endsWith('Complete!'));
    });
  });

  group('truncateFailureOutput（失败：头 2000 + 尾 6000）', () {
    const keep = failureHeadChars + failureTailChars; // 8000

    test('null / 空输出 → (无输出)', () {
      expect(truncateFailureOutput(null), '(无输出)');
      expect(truncateFailureOutput(''), '(无输出)');
    });

    test('短文本原样返回，不产生头尾重叠拼接', () {
      const s = 'error: something broke\nstack line 1\nstack line 2';
      expect(truncateFailureOutput(s), s);
    });

    test('恰好 8000 字符 → 不截断（R8 off-by-one）', () {
      final s = 'H' * failureHeadChars + 'T' * failureTailChars;
      expect(s.length, keep);
      expect(truncateFailureOutput(s), s);
    });

    test('8001 字符 → 头 2000 + 尾 6000 + 省略 1 字符标注', () {
      final s = '${'H' * failureHeadChars}M${'T' * failureTailChars}';
      final out = truncateFailureOutput(s);
      expect(out, startsWith('H' * failureHeadChars));
      expect(out, endsWith('T' * failureTailChars));
      expect(out, contains('…(中间省略 1 字符)…'));
      expect(out, isNot(contains('M')));
      expect(out.length, keep + '…(中间省略 1 字符)…'.length + 2);
    });

    test('超长失败输出：报错头部与 stack 尾部都保留', () {
      const head = 'HEAD_ERROR: compilation failed at step 1\n';
      const tail = '\nTAIL_SUMMARY: 42 errors, build aborted';
      final s = '$head${'x' * 50000}$tail';
      final out = truncateFailureOutput(s);
      expect(out, startsWith(head));
      expect(out, endsWith(tail));
      expect(out, contains('…(中间省略 ${s.length - keep} 字符)…'));
      expect(out.length, lessThan(s.length));
      expect(out.length, lessThanOrEqualTo(keep + 40));
    });

    test('头尾内容不重复（恰好上限的文本不会被拼两遍）', () {
      final s = 'A' * 4000 + 'B' * 4000;
      expect(truncateFailureOutput(s), s);
    });
  });

  group('stripTrailingPromptLine（H2：替代尾部单字符清洗）', () {
    test('bash 提示符尾行被删', () {
      expect(stripTrailingPromptLine('file1\nfile2\nuser@host:~\$ '),
          'file1\nfile2');
      expect(stripTrailingPromptLine('out\n[root@host ~]#'), 'out');
    });

    test('cmd / PS 提示符尾行被删', () {
      expect(stripTrailingPromptLine('out\nC:\\Users\\test>'), 'out');
      expect(stripTrailingPromptLine('out\nPS D:\\item>'), 'out');
    });

    test('合法末字符不再被吃（旧单字符清洗的回归）', () {
      expect(stripTrailingPromptLine('[1,2,3]'), '[1,2,3]');
      expect(stripTrailingPromptLine('pass\$'), 'pass\$');
      expect(stripTrailingPromptLine('{"a": 1}'), '{"a": 1}');
    });

    test('空输出与无提示符输出原样返回', () {
      expect(stripTrailingPromptLine(''), '');
      expect(stripTrailingPromptLine('total 0\nfile1'), 'total 0\nfile1');
    });
  });

  group('stripWrappedEcho（执行器层唯一回显清洗点，R8）', () {
    test('精确回显被剥离', () {
      expect(stripWrappedEcho('ls -la; echo "EXITCODE_1:\$?"\nfile1\n',
          'ls -la; echo "EXITCODE_1:\$?"'), '\nfile1\n');
    });

    test('折行回显被容忍剥离', () {
      final cmd = 'echo ${'x' * 100} ; echo "EXITCODE_1:\$?"';
      final wrapped = cmd.substring(0, 80) + '\r\n' + cmd.substring(80);
      final out = stripWrappedEcho('$wrapped\r\nreal-output\r\n', cmd);
      expect(out, '\r\nreal-output\r\n');
    });

    test('找不到回显时原样返回（不误删真实输出）', () {
      final wrapped = 'pwd; echo "EXITCODE_1:\$?"';
      expect(stripWrappedEcho('/home/user/pwd\nx', wrapped), '/home/user/pwd\nx');
    });
  });

  group('stripInteractiveEcho（O3：提示+答案回显不污染观测）', () {
    test('整行回显被删除，真实输出保留', () {
      final out = stripInteractiveEcho(
        'Continue? y\ngot-y',
        [(prompt: 'Continue? ', answer: 'y')],
      );
      expect(out, 'got-y');
    });

    test('空答案（回车）匹配裸提示行', () {
      final out = stripInteractiveEcho(
        'Press ENTER to continue\nstarted',
        [(prompt: 'Press ENTER to continue', answer: '')],
      );
      expect(out, 'started');
    });

    test('R8：正文里包含同样文字但不是整行相等的行不被删除', () {
      const output = 'Continue? y is the prompt echo we expect to see\n'
          'got-y';
      final out = stripInteractiveEcho(
        output,
        [(prompt: 'Continue? ', answer: 'y')],
      );
      expect(out, output, reason: '只删整行逐字相等的回显');
    });

    test('空白折叠后仍匹配（PTY 补空格/制表符）', () {
      final out = stripInteractiveEcho(
        'Continue?   y\ndone',
        [(prompt: 'Continue? ', answer: 'y')],
      );
      expect(out, 'done');
    });

    test('没有记录交互时原样返回', () {
      const output = 'Continue? y\nok';
      expect(stripInteractiveEcho(output, const []), output);
    });
  });
}