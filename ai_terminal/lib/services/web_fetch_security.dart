import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset_converter/charset_converter.dart';
import 'package:dio/dio.dart';

class WebFetchBlockedException implements Exception {
  final String message;

  const WebFetchBlockedException(this.message);

  @override
  String toString() => message;
}

class WebFetchTooLargeException implements Exception {
  final int maxBytes;

  const WebFetchTooLargeException(this.maxBytes);

  @override
  String toString() => '响应正文超过 $maxBytes 字节上限';
}

class WebFetchHttpException implements Exception {
  final int statusCode;

  const WebFetchHttpException(this.statusCode);

  @override
  String toString() => 'HTTP $statusCode';
}

class WebFetchNetworkException implements Exception {
  final Object cause;

  const WebFetchNetworkException(this.cause);

  @override
  String toString() => cause.toString();
}

void _throwIfCancelled(CancelToken? token) {
  if (token?.isCancelled == true) {
    throw DioException(
      requestOptions: RequestOptions(path: ''),
      type: DioExceptionType.cancel,
      error: 'task cancelled',
    );
  }
}

class WebFetchResponse {
  final String body;
  final String contentType;
  final Uri finalUri;

  const WebFetchResponse({
    required this.body,
    required this.contentType,
    required this.finalUri,
  });
}

class WebFetchClient {
  final Duration timeout;
  final int maxBytes;
  final int maxRedirects;

  const WebFetchClient({
    required this.timeout,
    required this.maxBytes,
    this.maxRedirects = 5,
  });

  Future<WebFetchResponse> fetch(
    Uri input, {
    CancelToken? cancelToken,
  }) async {
    var uri = WebFetchPolicy.validate(input);
    final stopwatch = Stopwatch()..start();
    Socket? activeSocket;
    final cancellation = cancelToken?.whenCancel.then(
      (_) => activeSocket?.destroy(),
      onError: (Object _, StackTrace __) => activeSocket?.destroy(),
    );
    unawaited(cancellation);
    for (var redirects = 0; redirects <= maxRedirects; redirects++) {
      _throwIfCancelled(cancelToken);
      uri = WebFetchPolicy.validate(uri);
      final WebFetchResponseParser response;
      try {
        response = await WebFetchResponseParser.open(
          uri,
          timeout: timeout,
          stopwatch: stopwatch,
          cancelToken: cancelToken,
          onSocket: (socket) => activeSocket = socket,
        );
      } on WebFetchNetworkException catch (error) {
        if (cancelToken?.isCancelled == true) {
          throw DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
            error: error,
          );
        }
        rethrow;
      }
      try {
        final status = response.statusCode;
        if (status >= 300 && status < 400) {
          final location = response.headers['location'];
          if (redirects == maxRedirects) {
            throw const WebFetchBlockedException('重定向次数超过上限');
          }
          if (location == null || location.trim().isEmpty) {
            throw WebFetchHttpException(status);
          }
          uri = WebFetchPolicy.resolveRedirect(uri, location);
          continue;
        }
        if (status == 404) throw const WebFetchHttpException(404);
        if (status == 403) throw const WebFetchHttpException(403);
        if (status < 200 || status >= 300) {
          throw WebFetchHttpException(status);
        }
        final encoding =
            response.headers['content-encoding']?.trim().toLowerCase();
        if (encoding != null && encoding.isNotEmpty && encoding != 'identity') {
          throw const WebFetchBlockedException('目标服务器返回了不支持的压缩编码');
        }
        final Uint8List bytes;
        try {
          bytes = await response.readBody(maxBytes);
        } on WebFetchNetworkException catch (error) {
          if (cancelToken?.isCancelled == true) {
            throw DioException(
              requestOptions: RequestOptions(path: ''),
              type: DioExceptionType.cancel,
              error: error,
            );
          }
          rethrow;
        }
        return WebFetchResponse(
          body: await _decodeBody(
              bytes, _charsetFromContentType(response.contentType)),
          contentType: response.contentType ?? '',
          finalUri: uri,
        );
      } finally {
        response.close();
        activeSocket = null;
      }
    }
    throw const WebFetchBlockedException('重定向次数超过上限');
  }

  static String? _charsetFromContentType(String? contentType) {
    if (contentType == null) return null;
    final match = RegExp(
      r'charset\s*=\s*["\x27]?([^;"\x27\s]+)',
      caseSensitive: false,
    ).firstMatch(contentType);
    return match?.group(1);
  }

  static Future<String> _decodeBody(Uint8List bytes, String? charset) async {
    final normalized = charset?.trim().toLowerCase();
    if (normalized == null ||
        normalized.isEmpty ||
        normalized == 'utf-8' ||
        normalized == 'utf8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    if (normalized == 'iso-8859-1' || normalized == 'latin1') {
      return latin1.decode(bytes);
    }
    try {
      return await CharsetConverter.decode(charset!, bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}

class WebFetchResponseParser {
  final Socket? _socket;
  final _HttpByteReader _reader;
  final int statusCode;
  final Map<String, String> headers;
  final String? contentType;
  final Duration timeout;

  WebFetchResponseParser._(
    this._socket,
    this._reader,
    this.statusCode,
    this.headers,
    this.timeout,
  ) : contentType = headers['content-type'];

  static Future<WebFetchResponseParser> parse(
    Stream<List<int>> stream, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final reader = _HttpByteReader.fromStream(stream, timeout);
    try {
      final head = await _readHead(reader);
      return WebFetchResponseParser._(
          null, reader, head.statusCode, head.headers, timeout);
    } catch (_) {
      unawaited(reader.iterator.cancel());
      rethrow;
    }
  }

  static Future<({int statusCode, Map<String, String> headers})> _readHead(
    _HttpByteReader reader,
  ) async {
    while (true) {
      final status = _parseStatusLine(await _requiredLine(reader));
      final headers = <String, String>{};
      var headerBytes = 0;
      while (true) {
        final line = await _requiredLine(reader);
        headerBytes += line.length + 2;
        if (headerBytes > 32768) {
          throw const WebFetchNetworkException('HTTP 响应头超过 32KB 上限');
        }
        if (line.isEmpty) break;
        final separator = line.indexOf(':');
        if (separator <= 0) {
          throw const WebFetchNetworkException('HTTP 响应头格式无效');
        }
        final name = line.substring(0, separator).trim().toLowerCase();
        if (!RegExp(r'^[!#$%&\x27*+.^_`|~0-9a-z-]+$').hasMatch(name)) {
          throw const WebFetchNetworkException('HTTP 响应头名称无效');
        }
        final value = line.substring(separator + 1).trim();
        if (value.contains('\r') || value.contains('\n')) {
          throw const WebFetchNetworkException('HTTP 响应头格式无效');
        }
        final previous = headers[name];
        headers[name] = previous == null ? value : '$previous, $value';
      }
      if (status >= 200) return (statusCode: status, headers: headers);
    }
  }

  static Future<WebFetchResponseParser> open(
    Uri uri, {
    required Duration timeout,
    Stopwatch? stopwatch,
    CancelToken? cancelToken,
    void Function(Socket? socket)? onSocket,
  }) async {
    stopwatch ??= Stopwatch()..start();
    final addresses = await _resolvePublicAddresses(
        uri.host, _remaining(timeout, stopwatch), cancelToken);
    Socket? socket;
    try {
      SocketException? lastError;
      for (final address in addresses) {
        try {
          socket = await Socket.connect(address, uri.port,
                  timeout: _remaining(timeout, stopwatch))
              .timeout(_remaining(timeout, stopwatch));
          onSocket?.call(socket);
          break;
        } on SocketException catch (error) {
          lastError = error;
        } on TimeoutException {
          lastError = const SocketException('连接超时');
        }
      }
      if (socket == null) {
        throw WebFetchNetworkException(
            lastError ?? const SocketException('没有可用的公网地址'));
      }
      _throwIfCancelled(cancelToken);
      if (uri.scheme == 'https') {
        socket = await SecureSocket.secure(
          socket,
          host: uri.host,
          onBadCertificate: (_) => false,
        ).timeout(_remaining(timeout, stopwatch));
        onSocket?.call(socket);
      }
      socket.add(_buildRequest(uri));
      await socket.flush().timeout(_remaining(timeout, stopwatch));
      final reader = _HttpByteReader(socket, timeout, stopwatch);
      final head = await _readHead(reader);
      return WebFetchResponseParser._(
          socket, reader, head.statusCode, head.headers, timeout);
    } on DioException {
      socket?.destroy();
      rethrow;
    } on WebFetchBlockedException {
      socket?.destroy();
      rethrow;
    } on WebFetchNetworkException {
      socket?.destroy();
      rethrow;
    } on WebFetchHttpException {
      socket?.destroy();
      rethrow;
    } on SocketException catch (error) {
      socket?.destroy();
      throw WebFetchNetworkException(error);
    } on HandshakeException catch (error) {
      socket?.destroy();
      throw WebFetchNetworkException(error);
    } on TimeoutException {
      socket?.destroy();
      throw const WebFetchNetworkException('TLS 握手或请求发送超时');
    } on HttpException catch (error) {
      socket?.destroy();
      throw WebFetchNetworkException(error);
    } on FormatException catch (error) {
      socket?.destroy();
      throw WebFetchNetworkException(error);
    }
  }

  Future<Uint8List> readBody(int maxBytes) async {
    final transferEncoding = headers['transfer-encoding']?.trim().toLowerCase();
    final rawContentLength = headers['content-length']?.trim();
    final contentLength =
        rawContentLength == null ? null : int.tryParse(rawContentLength);
    if (rawContentLength != null && contentLength == null) {
      throw const WebFetchNetworkException('Content-Length 无效');
    }
    if (contentLength != null && contentLength < 0) {
      throw const WebFetchNetworkException('Content-Length 无效');
    }
    if (contentLength != null && contentLength > maxBytes) {
      throw WebFetchTooLargeException(maxBytes);
    }
    if (transferEncoding != null && transferEncoding != 'identity') {
      if (transferEncoding != 'chunked') {
        throw const WebFetchBlockedException('不支持的 Transfer-Encoding');
      }
      if (contentLength != null) {
        throw const WebFetchNetworkException('响应同时包含 Content-Length 和 chunked');
      }
      return _readChunkedBody(maxBytes);
    }
    if (contentLength != null) {
      final body = await _reader.readExact(contentLength, maxBytes);
      if (body.length != contentLength) {
        throw const WebFetchNetworkException('响应正文在 Content-Length 完成前断开');
      }
      return body;
    }
    return _reader.readToEnd(maxBytes);
  }

  Future<Uint8List> _readChunkedBody(int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    while (true) {
      final line = await _requiredLine(_reader);
      final sizeText = line.split(';').first.trim();
      final size = int.tryParse(sizeText, radix: 16);
      if (size == null || size < 0) {
        throw const WebFetchNetworkException('chunked 长度无效');
      }
      if (size == 0) {
        var trailerBytes = 0;
        while (true) {
          final trailer = await _requiredLine(_reader);
          trailerBytes += trailer.length;
          if (trailerBytes > 32768) {
            throw const WebFetchNetworkException('chunked trailer 超过上限');
          }
          if (trailer.isEmpty) return builder.takeBytes();
        }
      }
      total += size;
      if (total > maxBytes) throw WebFetchTooLargeException(maxBytes);
      builder.add(await _reader.readExact(size, maxBytes - (total - size)));
      final ending = await _reader.readExact(2, 2);
      if (ending[0] != 13 || ending[1] != 10) {
        throw const WebFetchNetworkException('chunked 结尾格式无效');
      }
    }
  }

  void close() {
    _socket?.destroy();
    unawaited(_reader.iterator.cancel());
  }

  static Future<String> _requiredLine(_HttpByteReader reader) async {
    final line = await reader.readLineBytes(8192);
    if (line == null) {
      throw const WebFetchNetworkException('HTTP 响应在行结束前断开');
    }
    return utf8.decode(line, allowMalformed: true);
  }

  static Future<List<InternetAddress>> _resolvePublicAddresses(
    String host,
    Duration timeout,
    CancelToken? cancelToken,
  ) async {
    _throwIfCancelled(cancelToken);
    try {
      final addresses = await InternetAddress.lookup(host).timeout(timeout);
      WebFetchPolicy.validateResolvedAddresses(addresses);
      return addresses;
    } on WebFetchBlockedException {
      rethrow;
    } on SocketException catch (error) {
      throw WebFetchNetworkException(error);
    } on TimeoutException {
      throw const WebFetchNetworkException('DNS 解析超时');
    }
  }

  static Uint8List _buildRequest(Uri uri) {
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    final hostHeader =
        uri.hasPort && uri.port != defaultPort ? '$host:${uri.port}' : host;
    final encodedPath = uri.pathSegments.map(Uri.encodeComponent).join('/');
    final path = encodedPath.isEmpty ? '/' : '/$encodedPath';
    final target = uri.hasQuery ? '$path?${uri.query}' : path;
    final lines = [
      'GET $target HTTP/1.1',
      'Host: $hostHeader',
      'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Encoding: identity',
      'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
      'Connection: close',
      '',
      '',
    ];
    return Uint8List.fromList(utf8.encode(lines.join('\r\n')));
  }

  static Duration _remaining(Duration timeout, Stopwatch stopwatch) {
    final elapsed = stopwatch.elapsed;
    if (elapsed >= timeout) return Duration.zero;
    return timeout - elapsed;
  }

  static int _parseStatusLine(String line) {
    final match = RegExp(r'^HTTP/1\.[01] (\d{3})(?: .*)?$').firstMatch(line);
    final status = int.tryParse(match?.group(1) ?? '');
    if (status == null || status < 100 || status > 599) {
      throw const WebFetchNetworkException('HTTP 状态行格式无效');
    }
    return status;
  }
}

class _HttpByteReader {
  final StreamIterator<List<int>> iterator;
  final Duration timeout;
  final Stopwatch stopwatch;
  final BytesBuilder pending = BytesBuilder(copy: false);

  _HttpByteReader(Socket socket, this.timeout, this.stopwatch)
      : iterator = StreamIterator<List<int>>(socket);

  _HttpByteReader.fromStream(Stream<List<int>> stream, this.timeout)
      : iterator = StreamIterator<List<int>>(stream),
        stopwatch = Stopwatch()..start();

  Future<Uint8List?> readLineBytes(int maxBytes) async {
    final bytes = <int>[];
    while (true) {
      final next = await _nextByte();
      if (next == null) {
        if (bytes.isEmpty) return null;
        throw const WebFetchNetworkException('HTTP 响应行未完成');
      }
      if (next == 10) {
        if (bytes.isNotEmpty && bytes.last == 13) bytes.removeLast();
        return Uint8List.fromList(bytes);
      }
      bytes.add(next);
      if (bytes.length > maxBytes) {
        throw const WebFetchNetworkException('HTTP 响应行超过上限');
      }
    }
  }

  Future<Uint8List> readExact(int length, int maxBytes) async {
    if (length < 0 || length > maxBytes) {
      throw WebFetchTooLargeException(maxBytes);
    }
    final builder = BytesBuilder(copy: false);
    while (builder.length < length) {
      final buffered = pending.takeBytes();
      final chunk = buffered.isEmpty ? await _nextChunk() : buffered;
      if (chunk == null) {
        throw const WebFetchNetworkException('响应正文提前断开');
      }
      final remaining = length - builder.length;
      if (chunk.length > remaining) {
        pending.add(Uint8List.sublistView(chunk, remaining));
        builder.add(Uint8List.sublistView(chunk, 0, remaining));
      } else {
        builder.add(chunk);
      }
    }
    return builder.takeBytes();
  }

  Future<Uint8List> readToEnd(int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    while (true) {
      final buffered = pending.takeBytes();
      final chunk = buffered.isEmpty ? await _nextChunk() : buffered;
      if (chunk == null) return builder.takeBytes();
      if (builder.length + chunk.length > maxBytes) {
        throw WebFetchTooLargeException(maxBytes);
      }
      builder.add(chunk);
    }
  }

  Future<int?> _nextByte() async {
    while (true) {
      final pending = this.pending.takeBytes();
      if (pending.isNotEmpty) {
        if (pending.length == 1) return pending[0];
        this.pending.add(Uint8List.sublistView(pending, 1));
        return pending[0];
      }
      final chunk = await _nextChunk();
      if (chunk == null) return null;
      if (chunk.isEmpty) continue;
      this.pending.add(chunk);
    }
  }

  Future<Uint8List?> _nextChunk() async {
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      throw const WebFetchNetworkException('读取响应超时');
    }
    try {
      final hasNext = await iterator.moveNext().timeout(remaining);
      return hasNext ? Uint8List.fromList(iterator.current) : null;
    } on TimeoutException {
      throw const WebFetchNetworkException('读取响应超时');
    } on SocketException catch (error) {
      throw WebFetchNetworkException(error);
    } on HandshakeException catch (error) {
      throw WebFetchNetworkException(error);
    }
  }
}

class WebFetchPolicy {
  static Uri validate(Uri input) {
    if (input.scheme != 'https') {
      throw const WebFetchBlockedException('仅允许抓取公网 HTTPS 地址');
    }
    if (input.userInfo.isNotEmpty) {
      throw const WebFetchBlockedException('URL 不得内嵌用户名或密码');
    }
    if (input.host.isEmpty) {
      throw const WebFetchBlockedException('URL 缺少主机名');
    }
    if (input.host.contains('%')) {
      throw const WebFetchBlockedException('不支持带作用域标识的 IPv6 地址');
    }
    final host = input.host.toLowerCase();
    final normalizedHost =
        host.endsWith('.') ? host.substring(0, host.length - 1) : host;
    final address = InternetAddress.tryParse(normalizedHost);
    if (address != null) {
      if (!isPublicAddress(address)) {
        throw WebFetchBlockedException('禁止抓取非公网地址: $normalizedHost');
      }
    } else {
      final labels = normalizedHost.split('.');
      if (labels.length < 2 ||
          labels.any((label) =>
              label.isEmpty ||
              label.length > 63 ||
              !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label)) ||
          RegExp(r'^\d+$').hasMatch(labels.last)) {
        throw const WebFetchBlockedException('主机名格式无效');
      }
      const reservedSuffixes = [
        '.localhost',
        '.local',
        '.localdomain',
        '.internal',
        '.lan',
        '.home',
        '.home.arpa',
        '.onion',
        '.test',
        '.invalid',
        '.example',
      ];
      if (reservedSuffixes.any(normalizedHost.endsWith)) {
        throw WebFetchBlockedException('禁止抓取保留或内网主机名: $normalizedHost');
      }
    }
    return normalizedHost == input.host
        ? input
        : input.replace(host: normalizedHost);
  }

  static Uri resolveRedirect(Uri current, String location) {
    final Uri target;
    try {
      target = current.resolve(location);
    } on FormatException {
      throw const WebFetchBlockedException('重定向 Location 格式无效');
    }
    return validate(target);
  }

  static void validateResolvedAddresses(Iterable<InternetAddress> addresses) {
    final list = addresses.toList(growable: false);
    if (list.isEmpty) {
      throw const WebFetchBlockedException('主机名未解析到任何 IP 地址');
    }
    for (final address in list) {
      if (!isPublicAddress(address)) {
        throw WebFetchBlockedException('主机名解析到非公网地址: ${address.address}');
      }
    }
  }

  static bool isPublicAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return _isPublicIPv4(bytes);
    }
    return _isPublicIPv6(bytes);
  }

  static bool _isPublicIPv4(Uint8List bytes) {
    if (bytes.length != 4) return false;
    final a = bytes[0];
    final b = bytes[1];
    if (a == 0 || a == 10 || a == 127) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 192 && b == 0) return false;
    if (a == 192 && b == 88 && bytes[2] == 99) return false;
    if (a == 198 && (b == 18 || b == 19)) return false;
    if (a >= 224) return false;
    if (a == 198 && b == 51 && bytes[2] == 100) return false;
    if (a == 203 && b == 0 && bytes[2] == 113) return false;
    return true;
  }

  static bool _isPublicIPv6(Uint8List bytes) {
    if (bytes.length != 16) return false;
    final first = bytes[0];
    final second = bytes[1];
    final firstTenZero = bytes.take(10).every((byte) => byte == 0);
    if (firstTenZero && bytes[10] == 0xff && bytes[11] == 0xff) {
      return _isPublicIPv4(bytes.sublist(12));
    }
    if (firstTenZero) return false;
    if ((first & 0xfe) == 0xfc) return false;
    if ((first & 0xffc0) == 0xfe80) return false;
    if ((first & 0xffc0) == 0xfec0) return false;
    if (first == 0xff) return false;
    if (first == 0x00 &&
        second == 0x64 &&
        bytes[2] == 0xff &&
        bytes[3] == 0x9b) {
      return false;
    }
    if (first == 0x01 &&
        second == 0x00 &&
        bytes.skip(2).take(6).every((byte) => byte == 0)) {
      return false;
    }
    if (first == 0x20 &&
        second == 0x01 &&
        bytes[2] == 0x00 &&
        bytes[3] <= 0x01) {
      return false;
    }
    if (first == 0x20 &&
        second == 0x01 &&
        bytes[2] == 0x0d &&
        bytes[3] == 0xb8) {
      return false;
    }
    if (first == 0x20 && second == 0x02) return false;
    if (first == 0x3f && second == 0xff && (bytes[2] & 0xf0) == 0) return false;
    if (first == 0x5f && second == 0x00) return false;
    return true;
  }
}
