import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/command_markers.dart';
import 'package:ai_terminal/utils/exit_marker_scanner.dart';

void main() {
  tearDown(() => CommandMarkers.nonceForTesting = null);

  group('CommandMarkers', () {
    test('生产格式为 EXITCODE_seq_6位hex:', () {
      final m = CommandMarkers.next(1);
      expect(RegExp(r'^EXITCODE_1_[0-9a-f]{6}:$').hasMatch(m), isTrue,
          reason: m);
    });

    test('nonce 有随机性（连开 20 次不重复）', () {
      final markers = List.generate(20, (_) => CommandMarkers.next(1));
      expect(markers.toSet().length, greaterThan(1));
    });

    test('测试缝隙空 nonce 回退旧格式，兼容硬编码断言', () {
      CommandMarkers.nonceForTesting = '';
      expect(CommandMarkers.next(1), 'EXITCODE_1:');
      expect(CommandMarkers.next(42), 'EXITCODE_42:');
    });

    test('随机 marker 能被 ExitMarkerScanner 识别完成', () {
      final m = CommandMarkers.next(7);
      final scanner = ExitMarkerScanner(m);
      expect(scanner.add('some output\n'), isFalse);
      expect(scanner.add('$m' '0\r\n'), isTrue);
    });

    test('旧格式文本不再触发随机 marker 的完成判定（防碰撞）', () {
      final m = CommandMarkers.next(7);
      final scanner = ExitMarkerScanner(m);
      // 命令输出里出现旧格式 marker 文本，不应误判完成
      expect(scanner.add('log line: EXITCODE_7:0 from old run\n'), isFalse);
    });
  });
}
