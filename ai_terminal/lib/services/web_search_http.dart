import 'package:dio/dio.dart';
import 'web_search_http_stub.dart'
    if (dart.library.io) 'web_search_http_io.dart' as impl;

/// 创建搜索用 Dio
///
/// 代理只在这里注入，保证它只影响搜索后端与 fetch_url，不影响 AI/SSH 请求。
Dio createSearchDio({
  required Duration timeout,
  String? proxy,
  Map<String, String>? headers,
}) {
  return impl.createSearchDio(
    timeout: timeout,
    proxy: proxy,
    headers: headers,
  );
}
