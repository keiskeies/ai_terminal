import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/terminal_charset.dart';

void main() {
  group('charsetSafeEnd GBK/GB18030 边界', () {
    test('纯 ASCII 全部安全', () {
      expect(charsetSafeEnd([0x61, 0x62, 0x63], allowFourByte: true), 3);
      expect(charsetSafeEnd([], allowFourByte: true), 0);
    });

    test('完整双字节字符在末尾不扣留', () {
      // 0xC4 0xE3 = "你"（GBK）
      expect(charsetSafeEnd([0x61, 0xC4, 0xE3], allowFourByte: true), 3);
    });

    test('尾部孤立 lead 字节扣留到下一 chunk', () {
      expect(charsetSafeEnd([0x61, 0xC4], allowFourByte: true), 1);
      expect(charsetSafeEnd([0xC4], allowFourByte: true), 0);
    });

    test('GB18030 四字节完整/不完整', () {
      // 0x81 0x30 0x81 0x30 是合法四字节序列
      expect(charsetSafeEnd([0x81, 0x30, 0x81, 0x30], allowFourByte: true), 4);
      expect(charsetSafeEnd([0x61, 0x81, 0x30, 0x81], allowFourByte: true), 1);
      expect(charsetSafeEnd([0x81, 0x30], allowFourByte: true), 0);
    });

    test('Big5 模式不认四字节形式', () {
      // Big5 只有双字节：0x81 0x30 中 0x30 不是合法 trail，逐字节推进
      expect(charsetSafeEnd([0x81, 0x30], allowFourByte: false), 2);
      // 合法 Big5 双字节（0xA4 0x40 = "一"）
      expect(charsetSafeEnd([0xA4, 0x40], allowFourByte: false), 2);
      expect(charsetSafeEnd([0xA4], allowFourByte: false), 0);
    });

    test('ASCII 与 GBK 混排', () {
      // "a你b" = 0x61 0xC4 0xE3 0x62
      expect(charsetSafeEnd([0x61, 0xC4, 0xE3, 0x62], allowFourByte: true), 4);
      // 末尾半个字符
      expect(
          charsetSafeEnd([0x61, 0xC4, 0xE3, 0x62, 0xC4], allowFourByte: true),
          4);
    });
  });

  group('编码判定', () {
    test('utf-8 及未知编码按 UTF-8 处理', () {
      expect(isUtf8Encoding('utf-8'), isTrue);
      expect(isUtf8Encoding('UTF-8'), isTrue);
      expect(isUtf8Encoding(''), isTrue);
      expect(isUtf8Encoding('gbk'), isFalse);
      expect(isUtf8Encoding('GBK'), isFalse);
      expect(isUtf8Encoding('big5'), isFalse);
    });
  });

  group('OrderedCharsetWriter 写入顺序', () {
    test('UTF-8 同步落盘，不排队', () async {
      final written = <String>[];
      var encoderCalls = 0;
      final w = OrderedCharsetWriter(encoder: (t, e) async {
        encoderCalls++;
        return Uint8List.fromList(utf8.encode(t));
      });
      await w.write('ls\n', 'utf-8', (b) => written.add(utf8.decode(b)));
      expect(written, ['ls\n']);
      expect(encoderCalls, 0);
    });

    test('慢编码下仍按调用顺序写入（命令 → 内容 → Ctrl+D）', () async {
      final written = <String>[];
      // 编码耗时与文本长度成反比：后入队的短文本先编完，没有队列就会插队
      final w = OrderedCharsetWriter(encoder: (t, e) async {
        await Future.delayed(Duration(milliseconds: 12 - t.length));
        return Uint8List.fromList(utf8.encode(t));
      });
      final futures = [
        w.write('cat > /tmp/a\n', 'gbk', (b) => written.add(utf8.decode(b))),
        w.write('中文内容\n', 'gbk', (b) => written.add(utf8.decode(b))),
        w.write('\x04', 'gbk', (b) => written.add(utf8.decode(b))),
      ];
      await Future.wait(futures);
      expect(written, ['cat > /tmp/a\n', '中文内容\n', '\x04']);
    });

    test('单次编码失败不阻断后续写入，错误回传给该次调用方', () async {
      final written = <String>[];
      final w = OrderedCharsetWriter(encoder: (t, e) async {
        if (t.contains('bad')) throw StateError('编码失败');
        return Uint8List.fromList(utf8.encode(t));
      });
      final bad = w.write('bad\n', 'gbk', (b) => written.add(utf8.decode(b)));
      final good = w.write('next\n', 'gbk', (b) => written.add(utf8.decode(b)));
      await expectLater(bad, throwsStateError);
      await good;
      expect(written, ['next\n']);
    });
  });
}
