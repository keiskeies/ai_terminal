import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 创建带 HTTP 代理的 Dio
///
/// Dart 的 [HttpClient.findProxy] 只支持 HTTP 代理（HTTPS 目标通过 CONNECT
/// 隧道），不支持 SOCKS5、HTTPS 代理或代理账号密码；设置页只接受
/// `http://host:port` 或 `host:port`。
Dio createSearchDio({
  required Duration timeout,
  String? proxy,
  Map<String, String>? headers,
}) {
  final dio = Dio(BaseOptions(
    connectTimeout: timeout,
    receiveTimeout: timeout,
    headers: headers,
  ));

  final hostPort = _parseProxy(proxy);
  if (hostPort == null) return dio;

  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.connectionTimeout = timeout;
      client.findProxy = (_) => 'PROXY $hostPort';
      return client;
    },
  );
  return dio;
}

String? _parseProxy(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final withScheme =
      trimmed.contains('://') ? trimmed : 'http://$trimmed';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http') return null;
  if (uri.userInfo.isNotEmpty) return null;
  final port = uri.hasPort ? uri.port : 80;
  return '${uri.host}:$port';
}
