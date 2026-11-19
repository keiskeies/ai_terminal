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

    test('removes OSC title sequences (with ESC present)', () {
      expect(
        AnsiStripper.strip('\x1b]0;root@host:~\x07[root@host ~]# ls'),
        'ls',
      );
    });

    // 新契约（F2）：残留清洗仅在输入含 ESC/BEL 时启用。无 ESC 的输入不存在
    // "ESC 丢失后的残留"这一前提，旧行为（无条件清理）会毁掉合法文本。
    test('leaves OSC-shaped text untouched when input has no ESC', () {
      expect(AnsiStripper.strip(']0;root@host:~\nresult'),
          ']0;root@host:~\nresult');
      expect(AnsiStripper.strip('arr[0]; done'), 'arr[0]; done');
    });

    test('removes partial CSI fragments when ESC present', () {
      expect(AnsiStripper.strip('\x1b[?2004houtput\x1b[>0;10;1c'), 'output');
      expect(AnsiStripper.strip('\x1b]0;title\noutput'), 'output');
    });

    // F2 回归：合法文本在有无 ESC 两种输入下都必须原样保留
    test('preserves bracketed legitimate text', () {
      expect(AnsiStripper.strip('[INFO] service started'), '[INFO] service started');
      expect(AnsiStripper.strip('[1,2,3]'), '[1,2,3]');
      expect(AnsiStripper.strip('[2026-11-19] log line'), '[2026-11-19] log line');
      expect(AnsiStripper.strip('arr[0]; done'), 'arr[0]; done');
      expect(
        AnsiStripper.strip('\x1b[32m[1,2,3]\x1b[0m\n\x1b[1m[INFO]\x1b[0m ok'),
        '[1,2,3]\n[INFO] ok',
      );
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
