import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/ansi_stripper.dart';

void main() {
  group('AnsiStripper', () {
    test('removes CSI color sequences', () {
      expect(
        AnsiStripper.strip('\x1b[1;32mActive: running\x1b[0m'),
        'Active: running',
      );
    });

    test('removes OSC title sequences and their partial residue', () {
      expect(
        AnsiStripper.strip('\x1b]0;root@host:~\x07[root@host ~]# ls'),
        'ls',
      );
      expect(AnsiStripper.strip(']0;root@host:~\nresult'), 'result');
    });

    test('removes partial CSI fragments left after lost ESC', () {
      expect(AnsiStripper.strip('[?2004h[Koutput[>0;10;1c'), 'output');
    });

    test('keeps newlines/tabs but removes other control chars and BEL', () {
      expect(AnsiStripper.strip('a\x07b\tc\nd'), 'ab\tc\nd');
    });

    test('collapses 3+ blank lines into one blank line', () {
      expect(AnsiStripper.strip('a\n\n\n\nb'), 'a\n\nb');
    });

    test('trims trailing spaces per line', () {
      expect(AnsiStripper.strip('a   \nb  '), 'a\nb');
    });

    test('strips prompt prefixes at line starts', () {
      expect(
        AnsiStripper.strip('[root@host ~]# echo hi\n[deploy@web-1 ~]\$ uptime'),
        'echo hi\nuptime',
      );
    });

    test('leaves plain Chinese output untouched', () {
      expect(AnsiStripper.strip('正在启动 nginx 服务...'), '正在启动 nginx 服务...');
    });
  });
}
