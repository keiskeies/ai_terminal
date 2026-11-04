import 'package:dio/dio.dart';

/// Web 平台无法使用 dart:io 代理；直接返回普通 Dio
Dio createSearchDio({
  required Duration timeout,
  String? proxy,
  Map<String, String>? headers,
}) {
  return Dio(BaseOptions(
    connectTimeout: timeout,
    receiveTimeout: timeout,
    headers: headers,
  ));
}
