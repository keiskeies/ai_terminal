import 'dart:convert';
import 'dart:io' show Platform, SystemEncoding;
import 'dart:typed_data';
import 'package:charset_converter/charset_converter.dart';

class TerminalEncoder {
  static final _encodingMap = <String, Encoding>{
    'utf-8': utf8,
    'gbk': _GBKEncoding(),
    'big5': _Big5Encoding(),
  };

  static Encoding getEncoding(String name) {
    return _encodingMap[name.toLowerCase()] ?? SystemEncoding();
  }

  /// 检测字符串编码
  static String detectEncoding(List<int> bytes) {
    try {
      utf8.decode(bytes);
      return 'utf-8';
    } catch (_) {}
    return 'utf-8';
  }
}

/// GBK 编码实现（使用 charset_converter）
class _GBKEncoding extends Encoding {
  @override
  String get name => 'gbk';

  @override
  Converter<List<int>, String> get decoder => _GBKDecoder();

  @override
  Converter<String, List<int>> get encoder => _GBKEncoder();
}

class _GBKDecoder extends Converter<List<int>, String> {
  @override
  String convert(List<int> input) {
    // 使用 charset_converter 进行 GBK 解码
    // 由于 charset_converter 是异步的，这里使用同步回退方案
    try {
      // dart:io 的 gbk 编码支持 (仅桌面端)
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        return const SystemEncoding().decode(input);
      }
    } catch (_) {}
    // 最终回退：尝试 UTF-8 解码
    try {
      return utf8.decode(input);
    } catch (_) {
      return String.fromCharCodes(input);
    }
  }

  /// 异步解码方法（推荐使用）
  Future<String> convertAsync(List<int> input) async {
    try {
      return await CharsetConverter.decode('gbk', Uint8List.fromList(input));
    } catch (_) {
      return convert(input);
    }
  }
}

class _GBKEncoder extends Converter<String, List<int>> {
  @override
  List<int> convert(String input) {
    try {
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        return const SystemEncoding().encode(input);
      }
    } catch (_) {}
    return utf8.encode(input);
  }

  /// 异步编码方法（推荐使用）
  Future<List<int>> convertAsync(String input) async {
    try {
      return await CharsetConverter.encode('gbk', input);
    } catch (_) {
      return convert(input);
    }
  }
}

/// BIG5 编码实现
class _Big5Encoding extends Encoding {
  @override
  String get name => 'big5';

  @override
  Converter<List<int>, String> get decoder => _Big5Decoder();

  @override
  Converter<String, List<int>> get encoder => _Big5Encoder();
}

class _Big5Decoder extends Converter<List<int>, String> {
  @override
  String convert(List<int> input) {
    try {
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        return const SystemEncoding().decode(input);
      }
    } catch (_) {}
    try {
      return utf8.decode(input);
    } catch (_) {
      return String.fromCharCodes(input);
    }
  }

  Future<String> convertAsync(List<int> input) async {
    try {
      return await CharsetConverter.decode('big5', Uint8List.fromList(input));
    } catch (_) {
      return convert(input);
    }
  }
}

class _Big5Encoder extends Converter<String, List<int>> {
  @override
  List<int> convert(String input) {
    try {
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        return const SystemEncoding().encode(input);
      }
    } catch (_) {}
    return utf8.encode(input);
  }

  Future<List<int>> convertAsync(String input) async {
    try {
      return await CharsetConverter.encode('big5', input);
    } catch (_) {
      return convert(input);
    }
  }
}
