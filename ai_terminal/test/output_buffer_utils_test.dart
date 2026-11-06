import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/exit_marker_scanner.dart';
import 'package:ai_terminal/utils/tail_text_buffer.dart';

void main() {
  group('TailTextBuffer', () {
    test('trims once the buffer exceeds 2x the cap', () {
      final buffer = TailTextBuffer(10);
      buffer.write('0123456789ABCDEFGHIJK'); // 21 chars > 20
      expect(buffer.length, 10);
      expect(buffer.tail(), 'BCDEFGHIJK');
    });

    test('tail() always caps at maxChars', () {
      final buffer = TailTextBuffer(8);
      buffer.write('abcdefghijklmnop');
      expect(buffer.toString().length, 8);
      expect(buffer.toString(), 'ijklmnop');
    });
  });

  group('ExitMarkerScanner', () {
    test('detects a marker inside one chunk', () {
      final scanner = ExitMarkerScanner('EXITCODE_1:');
      expect(scanner.add('output\nEXITCODE_1:0\n'), isTrue);
    });

    test('detects a marker split across chunks', () {
      final scanner = ExitMarkerScanner('EXITCODE_7:');
      expect(scanner.add('EXITCODE_7'), isFalse);
      expect(scanner.add(':123'), isTrue);
    });

    test('does not match the command echo without an exit code', () {
      final scanner = ExitMarkerScanner('EXITCODE_2:');
      expect(scanner.add('echo "EXITCODE_2:\$?"'), isFalse);
      expect(scanner.add('\nEXITCODE_2:1'), isTrue);
    });

    test('keeps enough carry for a marker split near the boundary', () {
      final scanner = ExitMarkerScanner('EXITCODE_12:');
      expect(scanner.add('x' * 100 + 'EXITCODE_12'), isFalse);
      expect(scanner.add(':0'), isTrue);
    });
  });
}
