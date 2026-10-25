import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/line_diff.dart';

void main() {
  group('LineDiff', () {
    test('identical content has zero changes', () {
      final diff = LineDiff.compute('a\nb\n', 'a\nb\n');
      expect(diff?.additions, 0);
      expect(diff?.deletions, 0);
    });

    test('added lines', () {
      final diff = LineDiff.compute('a\n', 'a\nb\nc\n');
      expect(diff?.additions, 2);
      expect(diff?.deletions, 0);
    });

    test('removed lines', () {
      final diff = LineDiff.compute('a\nb\n', 'a\n');
      expect(diff?.additions, 0);
      expect(diff?.deletions, 1);
    });

    test('changed line counts as add + delete', () {
      final diff = LineDiff.compute('listen 80;', 'listen 8080;');
      expect(diff?.additions, 1);
      expect(diff?.deletions, 1);
    });

    test('normalizes CRLF', () {
      final diff = LineDiff.compute('a\r\nb\r\n', 'a\nb\n');
      expect(diff?.additions, 0);
      expect(diff?.deletions, 0);
    });

    test('too many lines returns null instead of doing expensive LCS', () {
      final oldText = List.generate(LineDiff.maxLines + 1, (i) => 'a$i').join('\n');
      final diff = LineDiff.compute(oldText, 'b');
      expect(diff, isNull);
    });
  });
}
