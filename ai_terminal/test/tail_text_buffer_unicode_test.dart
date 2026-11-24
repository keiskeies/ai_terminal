import 'package:ai_terminal/utils/tail_text_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tail 与写时裁剪都不会截出孤立代理项', () {
    final writeTrimmed = TailTextBuffer(4)..write('xxx😀aaaa');
    expect(writeTrimmed.tail(), 'aaaa');
    expect(writeTrimmed.toString(), 'aaaa');
    expect(writeTrimmed.length, lessThanOrEqualTo(8));

    final tailOnly = TailTextBuffer(4)..write('x😀abc');
    expect(tailOnly.length, 6);
    expect(tailOnly.tail(), 'abc');
  });

  test('maxChars=0 保持空尾部且不越界', () {
    final buffer = TailTextBuffer(0)..write('abc');
    expect(buffer.tail(), isEmpty);
    expect(buffer.length, 0);
  });
}
