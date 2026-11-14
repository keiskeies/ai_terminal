/// 终端显示/输入的编码接线。
///
/// AI 的 executeAndWait 链路同样走这里：其 EXITCODE marker 是纯 ASCII，
/// 在 GBK/GB18030/Big5 下字节不变，完成判定不受编码影响；写入侧用
/// [OrderedCharsetWriter] 保证「命令 → 文件内容 → Ctrl+D」的字节顺序。
///
/// GBK 用 GB18030（CP54936）解码：它是 GBK/GB2312 的严格超集，且 charset_converter
/// 的 Windows 码页表里没有 "gbk" 这个名字（只有 gb2312/big5/gb18030）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:charset_converter/charset_converter.dart';

bool isUtf8Encoding(String encoding) {
  final name = encoding.toLowerCase();
  return name != 'gbk' && name != 'big5';
}

typedef CharsetEncoder = Future<Uint8List> Function(String text, String encoding);
typedef ByteSink = void Function(Uint8List bytes);

/// 顺序保证的编码写入队列。
///
/// charset_converter 是异步平台通道：若「命令 → 文件内容 → Ctrl+D」各自触发一次异步
/// 编码，落到 PTY 的字节顺序就取决于谁先编完，文件内容会错位甚至跑到命令前面。
/// 这里把非 UTF-8 的写入串成一条 future 链；UTF-8 保持同步写入，零开销零回归。
class OrderedCharsetWriter {
  OrderedCharsetWriter({CharsetEncoder encoder = encodeTerminalInput})
      : _encoder = encoder;

  final CharsetEncoder _encoder;
  Future<void> _chain = Future<void>.value();

  /// 写入 [text]。UTF-8 同步落盘并返回已完成的 future；
  /// 其他编码排队异步编码后写入，返回的 future 在该次写入完成（或失败）时结束。
  /// 单次失败只让该次的 future 出错，不会中断队列。
  Future<void> write(String text, String encoding, ByteSink sink) {
    if (isUtf8Encoding(encoding)) {
      sink(Uint8List.fromList(utf8.encode(text)));
      return Future.value();
    }
    final future = _chain.then((_) async {
      sink(await _encoder(text, encoding));
    });
    // 队列本身吞掉错误：一次编码失败不能让后续所有写入被跳过。
    // 调用方仍拿到带错误的 [future]，可据此上报。
    _chain = future.catchError((Object _) {});
    return future;
  }
}

String _charsetName(String encoding) =>
    encoding.toLowerCase() == 'gbk' ? 'gb18030' : 'big5';

/// 输出解码：UTF-8 走同步流式解码（跨包半个多字节字符由 Utf8Decoder 暂存）；
/// GBK/BIG5 走 charset_converter 异步解码，按字符边界切块，避免把双字节字符劈开。
Stream<String> decodeTerminalOutput(Stream<List<int>> source, String encoding) {
  if (isUtf8Encoding(encoding)) {
    return source.transform(const Utf8Decoder(allowMalformed: true));
  }
  return _decodeCharset(source, _charsetName(encoding),
      allowFourByte: encoding.toLowerCase() == 'gbk');
}

Stream<String> _decodeCharset(
    Stream<List<int>> source, String charset,
    {required bool allowFourByte}) async* {
  var pending = <int>[];
  await for (final chunk in source) {
    pending.addAll(chunk);
    final safe = charsetSafeEnd(pending, allowFourByte: allowFourByte);
    if (safe == 0) continue;
    final bytes = Uint8List.fromList(pending.sublist(0, safe));
    pending = pending.sublist(safe);
    yield await _decodeChunk(charset, bytes);
  }
  if (pending.isNotEmpty) {
    yield await _decodeChunk(charset, Uint8List.fromList(pending));
  }
}

Future<String> _decodeChunk(String charset, Uint8List bytes) async {
  try {
    return await CharsetConverter.decode(charset, bytes);
  } catch (_) {
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }
}

/// 用户输入编码。失败回退 UTF-8（宁可乱码也不丢按键）。
Future<Uint8List> encodeTerminalInput(String text, String encoding) async {
  if (isUtf8Encoding(encoding)) return Uint8List.fromList(utf8.encode(text));
  try {
    return await CharsetConverter.encode(_charsetName(encoding), text);
  } catch (_) {
    return Uint8List.fromList(utf8.encode(text));
  }
}

/// [bytes] 中最后一个完整字符的结束偏移。GBK/GB18030 双字节 lead 0x81-0xFE，
/// GB18030 另有四字节形式（lead + 0x30-0x39 + 2 字节）；Big5 只有双字节。
/// 尾部不完整序列留在缓冲区等下一个 chunk，流结束时再强制解码。
int charsetSafeEnd(List<int> bytes, {required bool allowFourByte}) {
  var i = 0;
  var safe = 0;
  final n = bytes.length;
  while (i < n) {
    final b = bytes[i];
    if (b < 0x81 || b > 0xFE) {
      i++;
      safe = i;
      continue;
    }
    if (i + 1 >= n) break;
    final t = bytes[i + 1];
    if (allowFourByte && t >= 0x30 && t <= 0x39) {
      if (i + 3 >= n) break;
      i += 4;
      safe = i;
      continue;
    }
    final validTrail = allowFourByte
        ? (t >= 0x40 && t <= 0xFE && t != 0x7F)
        : ((t >= 0x40 && t <= 0x7E) || (t >= 0xA1 && t <= 0xFE));
    if (validTrail) {
      i += 2;
      safe = i;
    } else {
      i++;
      safe = i;
    }
  }
  return safe;
}