import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

class AiEndpointSecurityException implements Exception {
  const AiEndpointSecurityException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AiEndpointSecurity {
  static Uri endpoint(String baseUrl, String path) {
    final base = validateBase(baseUrl);
    final basePath = base.path.replaceAll(RegExp(r'/+$'), '');
    final suffix = path.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return base.replace(path: '$basePath/$suffix');
  }

  static Uri validateBase(String input) {
    final uri = _parse(input);
    _validate(uri);
    if (uri.hasQuery) {
      throw const AiEndpointSecurityException('Base URL 不得包含查询参数');
    }
    return uri.replace(host: _normalizedHost(uri.host));
  }

  static Uri resolveRedirect(Uri current, String location) {
    final target = _parse(current.resolve(location));
    _validate(target);
    if (_origin(current) != _origin(target)) {
      throw const AiEndpointSecurityException('AI 服务重定向不得跨源或降级协议');
    }
    return target;
  }

  static Uri _parse(Object input) {
    final text = input is Uri ? input.toString() : input.toString();
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.host.isEmpty) {
      throw const AiEndpointSecurityException('AI 服务 URL 无效');
    }
    return uri;
  }

  static void _validate(Uri uri) {
    if (uri.userInfo.isNotEmpty) {
      throw const AiEndpointSecurityException('AI 服务 URL 不得内嵌凭据');
    }
    if (uri.hasFragment) {
      throw const AiEndpointSecurityException('AI 服务 URL 不得包含片段');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const AiEndpointSecurityException('AI 服务仅支持 HTTP 或 HTTPS');
    }
    if (uri.scheme == 'http' && !_isLoopback(uri.host)) {
      throw const AiEndpointSecurityException('AI 凭据不得通过非回环 HTTP 发送，请使用 HTTPS');
    }
  }

  static bool _isLoopback(String host) {
    final normalized = _normalizedHost(host);
    if (normalized == 'localhost') return true;
    final address = InternetAddress.tryParse(normalized);
    return address?.isLoopback ?? false;
  }

  static String _normalizedHost(String host) =>
      host.toLowerCase().replaceAll(RegExp(r'\.+$'), '');

  static ({String scheme, String host, int port}) _origin(Uri uri) => (
        scheme: uri.scheme,
        host: _normalizedHost(uri.host),
        port: uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80),
      );
}

class AiEndpointClient {
  const AiEndpointClient(this.dio);

  final Dio dio;

  Future<Response<T>> post<T>(
    String baseUrl,
    String path, {
    required Object data,
    required String apiKey,
    CancelToken? cancelToken,
    Duration? receiveTimeout,
    ResponseType responseType = ResponseType.json,
  }) =>
      _request<T>(
        baseUrl,
        path,
        method: 'POST',
        data: data,
        apiKey: apiKey,
        cancelToken: cancelToken,
        receiveTimeout: receiveTimeout,
        responseType: responseType,
      );

  Future<Response<T>> get<T>(
    String baseUrl,
    String path, {
    required String apiKey,
    CancelToken? cancelToken,
    Duration? receiveTimeout,
  }) =>
      _request<T>(
        baseUrl,
        path,
        method: 'GET',
        apiKey: apiKey,
        cancelToken: cancelToken,
        receiveTimeout: receiveTimeout,
        responseType: ResponseType.json,
      );

  Future<Response<T>> _request<T>(
    String baseUrl,
    String path, {
    required String method,
    required String apiKey,
    Object? data,
    CancelToken? cancelToken,
    Duration? receiveTimeout,
    required ResponseType responseType,
  }) async {
    if (cancelToken?.isCancelled == true) {
      throw DioException(
        requestOptions: RequestOptions(path: baseUrl, method: method),
        type: DioExceptionType.cancel,
        error: cancelToken?.cancelError,
      );
    }
    RequestOptions initialOptions;
    Uri uri;
    try {
      uri = AiEndpointSecurity.endpoint(baseUrl, path);
      initialOptions = RequestOptions(path: uri.toString(), method: method);
    } on AiEndpointSecurityException catch (error) {
      initialOptions = RequestOptions(path: baseUrl, method: method);
      throw _securityError(initialOptions, error.message);
    }

    var redirects = 0;
    while (true) {
      final hopToken = CancelToken();
      final cancellation = cancelToken?.whenCancel.then(
        (_) {
          if (!hopToken.isCancelled) hopToken.cancel('task cancelled');
        },
        onError: (Object _, StackTrace __) {
          if (!hopToken.isCancelled) hopToken.cancel('task cancelled');
        },
      );
      unawaited(cancellation);
      final Response<T> response;
      try {
        response = await _send<T>(
          uri,
          method: method,
          data: data,
          apiKey: apiKey,
          cancelToken: hopToken,
          receiveTimeout: receiveTimeout,
          responseType: responseType,
        );
      } catch (_) {
        if (!hopToken.isCancelled) hopToken.cancel('request failed');
        rethrow;
      }
      final status = response.statusCode ?? 0;
      if (status < 300 || status >= 400) return response;
      if (!hopToken.isCancelled) hopToken.cancel('redirect');
      _cancelBody(response.data);
      if (redirects >= 3) {
        throw _securityError(response.requestOptions, 'AI 服务重定向次数超过上限');
      }
      final location = response.headers.value('location');
      if (location == null || location.trim().isEmpty) {
        throw _securityError(response.requestOptions, 'AI 服务重定向缺少 Location');
      }
      Uri next;
      try {
        next = AiEndpointSecurity.resolveRedirect(uri, location);
      } on AiEndpointSecurityException catch (error) {
        throw _securityError(response.requestOptions, error.message);
      }
      if (method == 'POST' && status == 303) {
        method = 'GET';
        data = null;
      }
      uri = next;
      redirects++;
    }
  }

  Future<Response<T>> _send<T>(
    Uri uri, {
    required String method,
    required Object? data,
    required String apiKey,
    required CancelToken? cancelToken,
    required Duration? receiveTimeout,
    required ResponseType responseType,
  }) {
    final options = Options(
      method: method,
      headers: {
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      responseType: responseType,
      receiveTimeout: receiveTimeout,
      followRedirects: false,
      validateStatus: (status) =>
          status != null &&
          ((status >= 200 && status < 300) || (status >= 300 && status < 400)),
    );
    if (method == 'GET') {
      return dio.get<T>(uri.toString(),
          options: options, cancelToken: cancelToken);
    }
    return dio.post<T>(uri.toString(),
        data: data, options: options, cancelToken: cancelToken);
  }

  static void _cancelBody(Object? data) {
    if (data is! ResponseBody) return;
    final subscription = data.stream.listen(
      null,
      onDone: () {},
      onError: (_) {},
    );
    unawaited(subscription.cancel());
  }

  static DioException _securityError(RequestOptions options, String message) =>
      DioException(
        requestOptions: options,
        type: DioExceptionType.unknown,
        error: AiEndpointSecurityException(message),
        message: message,
      );
}
