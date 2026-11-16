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

  group('stripCommandEcho 不受分级截断改动影响', () {
    test('首行回显被剥离', () {
      expect(stripCommandEcho('ls -la\nfile1\nfile2', 'ls -la'),
          'file1\nfile2');
    });

    test('真实输出不被误删', () {
      expect(stripCommandEcho('total 0\nfile1', 'ls -la'), 'total 0\nfile1');
    });
  });
}