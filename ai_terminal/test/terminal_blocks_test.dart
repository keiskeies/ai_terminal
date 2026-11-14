import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:ai_terminal/utils/terminal_blocks.dart';

/// OSC 133 的转义序列（ESC ] ... BEL）。写成显式转义而不是裸控制字符：
/// 源文件里的裸 ESC 看不见也搜不到，漏一个就是「测试悄悄没测」。
const String esc = '\x1B';
const String bel = '\x07';

String osc133(String body) => '$esc]133;$body$bel';

/// 一个终端 + 一个跟踪器：把 OSC 133 序列喂给 xterm，走真实的 onPrivateOSC
/// 通路（这是唯一能证明「不必 fork xterm」的测法）。
/// rows 保持 xterm 的默认 24：Buffer 构造时按 viewHeight 铺满 24 行，
/// 视口缩小会 pop 行，配上很小的 maxLines 直接触发 xterm 自己的断言。
class _Harness {
  _Harness({int cols = 80, int rows = 24, int maxLines = 200})
      : terminal = xterm.Terminal(maxLines: maxLines) {
    terminal.resize(cols, rows);
    tracker = TerminalBlockTracker(terminal: terminal);
    terminal.onPrivateOSC = tracker.onPrivateOsc;
  }

  final xterm.Terminal terminal;
  late final TerminalBlockTracker tracker;

  /// 模拟装了 shell integration 的 shell：提示符 → 命令 → 回车 → 输出 → 退出码。
  /// C 之前必须换行：真实 shell 是用户按回车后才把光标挪到下一行再打 C，
  /// 只发 \r 会让输出盖掉命令行本身（buffer 里就看不到命令了）。
  void feed(String command, String output, {int exit = 0}) {
    terminal.write(osc133('A'));
    terminal.write('user@web1:~\$ $command');
    terminal.write(osc133('B'));
    terminal.write('\r\n');
    terminal.write(osc133('C'));
    terminal.write('$output\r\n');
    terminal.write(osc133('D;$exit'));
    terminal.write('\r\n');
  }

  void feedMany(int n) {
    for (var i = 1; i <= n; i++) {
      feed('cmd$i', 'out$i');
    }
  }

  String lineAt(int i) => i < 0 || i >= terminal.buffer.height
      ? ''
      : terminal.buffer.lines[i].getText();

  void dispose() {
    tracker.dispose();
  }
}

void main() {
  group('OSC 133 解析', () {
    test('A/B/C/D 各自映射到标记', () {
      expect(parseOsc133('133', ['A']), BlockMarker.promptStart);
      expect(parseOsc133('133', ['B']), BlockMarker.promptEnd);
      expect(parseOsc133('133', ['C']), BlockMarker.commandStart);
      expect(parseOsc133('133', ['D']), BlockMarker.commandFinished);
    });

    test('非 133 的 OSC（改标题/超链接）与未知子参数被忽略', () {
      expect(parseOsc133('0', ['title']), isNull);
      expect(parseOsc133('8', ['id=x', 'https://a']), isNull);
      expect(parseOsc133('133', ['E']), isNull);
      expect(parseOsc133('133', const []), isNull);
    });

    test('退出码只在 D 上取，非数字返回 null', () {
      expect(parseOsc133ExitCode('133', ['D', '0']), 0);
      expect(parseOsc133ExitCode('133', ['D', '127']), 127);
      expect(parseOsc133ExitCode('133', ['D']), isNull);
      expect(parseOsc133ExitCode('133', ['D', 'abc']), isNull);
      expect(parseOsc133ExitCode('133', ['C', '0']), isNull);
    });
  });

  group('TerminalBlockTracker', () {
    test('没装 shell 集成：一条 OSC 也没有 → 一个块都没有', () {
      final h = _Harness();
      h.terminal.write('user@web1:~\$ ls\r\nfile\r\n');
      expect(h.tracker.isEmpty, isTrue);
      h.dispose();
    });

    test('OSC 序列真的到达了跟踪器（xterm 转交未知 OSC）', () {
      final h = _Harness();
      final seen = <String>[];
      final titles = <String>[];
      h.terminal.onTitleChange = titles.add;
      h.terminal.onPrivateOSC = (code, args) => seen.add('$code:$args');
      // OSC 0 是 xterm 自己认的（改标题），不该混进私有通道
      h.terminal.write('$esc]0;window title$bel');
      h.terminal.write(osc133('A'));
      h.terminal.write('$esc]7;file:///tmp$bel');
      expect(seen, ['133:[A]', '7:[file:///tmp]']);
      expect(titles, ['window title']);
      h.dispose();
    });

    test('一条命令 = 一个块，退出码记下来', () {
      final h = _Harness();
      h.feed('ls -l', 'total 8');
      expect(h.tracker.length, 1);
      expect(h.tracker.blocks.single.exitCode, 0);
      h.dispose();
    });

    test('块按提示符锚点定位，行号取自 buffer 实际位置', () {
      final h = _Harness();
      h.feed('first', 'o1');
      h.feed('second', 'o2');
      final blocks = h.tracker.blocks;
      expect(blocks.length, 2);
      final a = blocks[0].startLine;
      final b = blocks[1].startLine;
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(b!, greaterThan(a!));
      expect(h.lineAt(a), contains('first'));
      expect(h.lineAt(b), contains('second'));
      h.dispose();
    });

    test('命令被 ^C 掐断（没有 D）也不影响下一块', () {
      final h = _Harness();
      h.terminal.write(osc133('A'));
      h.terminal.write('user@web1:~\$ sleep 100');
      h.terminal.write('\r\n^C\r\n');
      h.feed('ls', 'ok');
      expect(h.tracker.length, 2);
      expect(h.tracker.blocks[0].exitCode, isNull);
      expect(h.tracker.blocks[1].exitCode, 0);
      h.dispose();
    });

    test('重复的 B/D 只认第一次（shell 实现不规范也不串块）', () {
      final h = _Harness();
      h.terminal.write(osc133('A'));
      h.terminal.write('user@web1:~\$ ls');
      h.terminal.write(osc133('B'));
      h.terminal.write(osc133('B'));
      h.terminal.write('\r');
      h.terminal.write('${osc133('C')}out\r\n');
      h.terminal.write(osc133('D;1'));
      h.terminal.write(osc133('D;2'));
      expect(h.tracker.length, 1);
      // 第一个 D 生效：1 而不是 2
      expect(h.tracker.blocks.single.exitCode, 1);
      h.dispose();
    });

    test('A 里的 cmd= 参数当作命令原文', () {
      final h = _Harness();
      h.terminal.write(osc133('A;cmd=echo hi'));
      h.terminal.write('user@web1:~\$ echo hi\r\nhi\r\n');
      h.terminal.write(osc133('D;0'));
      expect(blockCommandOf(h.tracker.blocks.single, h.lineAt), 'echo hi');
      h.dispose();
    });

    test('块数超过上限只留最新的', () {
      final h = _Harness(maxLines: 100000, rows: 4);
      const cap = TerminalBlockTracker.maxBlocks;
      for (var i = 0; i < cap + 40; i++) {
        h.feed('cmd$i', 'out$i');
      }
      expect(h.tracker.length, cap);
      expect(h.lineAt(h.tracker.blocks.last.startLine!), contains('cmd${cap + 39}'));
      h.dispose();
    });

    test('reset 后块清空（重连场景）', () {
      final h = _Harness();
      h.feedMany(3);
      h.tracker.reset();
      expect(h.tracker.isEmpty, isTrue);
      h.feed('after', 'out');
      expect(h.tracker.length, 1);
      h.dispose();
    });
  });

  group('块定位与文本', () {
    test('命中：光标落在块内任意行都归属该块', () {
      final h = _Harness();
      h.feed('df -h', 'filesystem\n/dev/sda1  50G');
      h.feed('uptime', 'load 0.1');
      final blocks = h.tracker.blocks;
      final height = h.terminal.buffer.height;
      final first = blocks[0].startLine!;
      expect(blockIndexAtLine(blocks, first, height), 0);
      expect(blockIndexAtLine(blocks, first + 1, height), 0);
      expect(blockIndexAtLine(blocks, blocks[1].startLine!, height), 1);
      h.dispose();
    });

    test('已结束（有 D）的块不吞掉 D 之后的裸输出行', () {
      final h = _Harness();
      h.feed('a', 'x');
      h.terminal.write('一些没有标记的裸输出\r\n');
      h.feed('b', 'y');
      final blocks = h.tracker.blocks;
      final height = h.terminal.buffer.height;
      // 第一块有 D，它的尾巴在 D 那一行就收住了；D 之后的裸行不属于它，
      // 也不属于下一块（下一块从自己的提示符才开始）
      final afterD = blocks[1].startLine! - 1;
      expect(blockIndexAtLine(blocks, blocks[0].startLine!, height), 0);
      expect(blockIndexAtLine(blocks, afterD, height), isNull);
      expect(blockIndexAtLine(blocks, blocks[1].startLine!, height), 1);
      h.dispose();
    });

    test('未结束（无 D）的块一直延伸到下一块之前', () {
      final h = _Harness();
      h.terminal.write(osc133('A'));
      h.terminal.write('user@web1:~\$ sleep 100\r\n');
      h.terminal.write('^C\r\n');
      h.feed('ls', 'ok');
      final blocks = h.tracker.blocks;
      final height = h.terminal.buffer.height;
      // ^C 之后没有任何标记的行仍属第一块（它就是那条命令的现场）
      final gap = blocks[1].startLine! - 1;
      expect(blockIndexAtLine(blocks, gap, height), 0);
      expect(blockTextOf(blocks, 0, height, h.lineAt), contains('sleep 100'));
      h.dispose();
    });

    test('上一块 / 下一块跳转；到边界返回 null', () {
      final h = _Harness();
      h.feedMany(3);
      final blocks = h.tracker.blocks;
      final mid = blocks[1].startLine!;
      expect(blockIndexNearLine(blocks, mid, forward: true), 2);
      expect(blockIndexNearLine(blocks, mid, forward: false), 0);
      expect(blockIndexNearLine(blocks, blocks.last.startLine!, forward: true),
          isNull);
      expect(
          blockIndexNearLine(blocks, blocks.first.startLine!, forward: false),
          isNull);
      h.dispose();
    });

    test('块文本 = 命令行 + 输出，行尾填充已裁掉', () {
      final h = _Harness();
      h.feed('echo hi', 'hi');
      final text =
          blockTextOf(h.tracker.blocks, 0, h.terminal.buffer.height, h.lineAt);
      expect(text, isNotEmpty);
      expect(text, contains('echo hi'));
      expect(text, contains('hi'));
      for (final line in text.split('\n')) {
        expect(line, equals(line.trimRight()));
      }
      h.dispose();
    });

    test('块命令剥掉提示符', () {
      final h = _Harness();
      h.feed('git status', 'clean');
      expect(blockCommandOf(h.tracker.blocks.single, h.lineAt), 'git status');
      h.dispose();
    });

    test('没有提示符的裸行不当命令（宁可给 null）', () {
      final h = _Harness();
      h.terminal.write(osc133('A'));
      h.terminal.write('plain output without prompt');
      expect(blockCommandOf(h.tracker.blocks.single, h.lineAt), isNull);
      h.dispose();
    });

    test('索引越界与空块列表都安静返回空', () {
      final h = _Harness();
      h.feed('ls', 'x');
      final blocks = h.tracker.blocks;
      final height = h.terminal.buffer.height;
      expect(blockTextOf(blocks, 9, height, h.lineAt), isEmpty);
      expect(blockTextOf(const [], 0, height, h.lineAt), isEmpty);
      expect(blockIndexAtLine(const [], 0, height), isNull);
      expect(blockStartLine(blocks, -1), isNull);
      expect(blockStartLine(blocks, 99), isNull);
      h.dispose();
    });
  });

  group('回滚裁剪后', () {
    test('锚点被裁掉的块作废：不给跨命令的假块', () {
      // maxLines 必须 >= 行数（xterm 构造时先铺满视口），给 30 行再灌噪声
      final h = _Harness(maxLines: 30);
      h.feed('oldest', 'o1');
      final first = h.tracker.blocks.first;
      expect(first.startLine, isNotNull);
      for (var i = 0; i < 60; i++) {
        h.terminal.write('noise $i\r\n');
      }
      expect(first.isAttached, isFalse);
      expect(first.startLine, isNull);
      expect(blockLineRange([first], 0, h.terminal.buffer.height), isNull);
      // 后续正常块仍可用
      h.feed('newest', 'o2');
      expect(h.tracker.blocks.last.isAttached, isTrue);
      h.dispose();
    });

    test('裁剪后下一次事件回收失效块，列表里只剩活着的', () {
      final h = _Harness(maxLines: 30);
      h.feedMany(2);
      for (var i = 0; i < 80; i++) {
        h.terminal.write('noise $i\r\n');
      }
      h.feed('fresh', 'o');
      expect(h.tracker.blocks, isNotEmpty);
      expect(h.tracker.blocks.every((b) => b.isAttached), isTrue);
      h.dispose();
    });

    test('回滚边界上取不到光标锚点时不抛异常（write 不能被搞崩）', () {
      // xterm 的循环缓冲在回卷时本身可能越界；跟踪器必须安静放弃这块
      final h = _Harness(maxLines: 30);
      h.feedMany(3);
      for (var i = 0; i < 200; i++) {
        h.terminal.write('${'x' * 79}$i\r\n');
        h.terminal.write(osc133('A'));
        h.terminal.write(osc133('D;0'));
      }
      expect(h.tracker.blocks.every((b) => b.isAttached), isTrue);
      h.dispose();
    });
  });

  group('喂给 AI 前的裁剪', () {
    test('短文本原样返回', () {
      expect(clipBlockForAgent('a\nb', maxChars: 100), 'a\nb');
    });

    test('超长时保头保尾，中间标注省略行数', () {
      final text = List.generate(400, (i) => 'line-$i-${'x' * 20}').join('\n');
      final clipped = clipBlockForAgent(text, maxChars: 800);
      expect(clipped.length, lessThanOrEqualTo(900));
      expect(clipped, contains('line-0-'));
      expect(clipped, contains('line-399-'));
      expect(clipped, contains('省略'));
      expect(clipped.contains('line-200-'), isFalse);
    });

    test('省略行数与实际保留行数对得上（不谎报）', () {
      final lines = List.generate(50, (i) => 'l$i');
      final clipped = clipBlockForAgent(lines.join('\n'), maxChars: 60);
      final m = RegExp(r'省略 (\d+) 行').firstMatch(clipped);
      expect(m, isNotNull);
      final skipped = int.parse(m!.group(1)!);
      final kept = clipped.split('\n').length - 1; // 减去标注行
      expect(kept + skipped, lines.length);
      expect(skipped, greaterThan(0));
    });
  });
}
