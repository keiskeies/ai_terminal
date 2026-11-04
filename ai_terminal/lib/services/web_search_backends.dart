import 'dart:convert';

import 'package:dio/dio.dart';

import 'web_search_config.dart';
import 'web_search_http.dart';
import 'web_search_models.dart';

/// 搜索后端抽象
abstract class WebSearchProviderApi {
  WebSearchProvider get type;

  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  });
}

/// 所有后端的注册表（DeepSeek 不在此表，它在设置页仅占位）
final Map<WebSearchProvider, WebSearchProviderApi> webSearchProviders = {
  WebSearchProvider.exa: _ExaProvider(),
  WebSearchProvider.parallel: _ParallelProvider(),
  WebSearchProvider.bingRss: _BingRssProvider(),
  WebSearchProvider.duckduckgo: _DuckDuckGoProvider(),
  WebSearchProvider.searxng: _SearXngProvider(),
  WebSearchProvider.brave: _BraveProvider(),
  WebSearchProvider.tavily: _TavilyProvider(),
  WebSearchProvider.serper: _SerperProvider(),
  WebSearchProvider.mojeek: _MojeekProvider(),
  WebSearchProvider.anthropic: _AnthropicProvider(),
  WebSearchProvider.openai: _OpenAIProvider(),
};

/// 将 DioException 转换为业务可读错误
Exception translateSearchDioError(
  DioException e,
  WebSearchProvider provider,
) {
  if (e.type == DioExceptionType.cancel) {
    return const WebSearchCancelledError('搜索已被取消');
  }
  final code = e.response?.statusCode;
  final detail = _errorDetail(e.response?.data);
  if (code == 401 || code == 403) {
    return WebSearchQuotaError(
      '${provider.displayName} 认证失败 (HTTP $code)：API Key 无效或无权限，请检查配置。',
      provider: provider,
      permanent: true,
    );
  }
  if (code == 429) {
    return WebSearchQuotaError(
      '${provider.displayName} 触发速率限制 (HTTP 429)：免费额度可能已用尽，请稍后重试。',
      provider: provider,
      permanent: false,
    );
  }
  if (code == 400 || code == 422) {
    return WebSearchQuotaError(
      '${provider.displayName} 请求被拒绝 (HTTP $code)：$detail',
      provider: provider,
      permanent: true,
    );
  }
  if (code != null && code >= 500) {
    return WebSearchTransientError(
      '${provider.displayName} 服务端错误 (HTTP $code)：$detail',
    );
  }
  if (e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.connectionError) {
    return WebSearchTransientError(
      '${provider.displayName} 网络错误：${e.message ?? e.type.name}。'
      '若在国内访问，请在设置页配置出站代理。',
    );
  }
  return WebSearchTransientError(
    '${provider.displayName} 请求失败：${e.message ?? e.toString()}',
  );
}

String _errorDetail(dynamic data) {
  if (data is Map) {
    final error = data['error'];
    if (error is Map) {
      final msg = error['message'] ?? error['type'];
      if (msg != null) return msg.toString();
    } else if (error != null) {
      return error.toString();
    }
    for (final key in const ['message', 'detail', 'error_description']) {
      final value = data[key];
      if (value != null) return value.toString();
    }
  }
  if (data is String && data.trim().isNotEmpty) {
    final trimmed = data.trim();
    return trimmed.length > 300 ? '${trimmed.substring(0, 300)}…' : trimmed;
  }
  return '无返回内容';
}

String _requireApiKey(String? apiKey, WebSearchProvider provider) {
  final key = apiKey?.trim() ?? '';
  if (key.isNotEmpty) return key;
  throw WebSearchQuotaError(
    '${provider.displayName} 未配置 API Key。'
    '请在「设置 → 联网搜索」填写，或设置环境变量 ${provider.envKeyName}。',
    provider: provider,
    permanent: true,
  );
}

WebSearchResult _result(
  Map<dynamic, dynamic> raw, {
  required List<String> urlKeys,
  required List<String> titleKeys,
  required List<String> snippetKeys,
}) {
  String pick(List<String> keys) {
    for (final key in keys) {
      final value = raw[key];
      if (value != null) {
        final text = value.toString().trim();
        if (text.isNotEmpty) return text;
      }
    }
    return '';
  }

  return WebSearchResult(
    title: pick(titleKeys),
    url: pick(urlKeys),
    snippet: pick(snippetKeys),
  );
}

// ─────────────────────────────────────────────────────────────
// 免密钥后端
// ─────────────────────────────────────────────────────────────

/// Bing RSS：`format=rss` 输出，免 Key。国内会跳转到 cn.bing.com。
class _BingRssProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.bingRss;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final dio = createSearchDio(
      timeout: timeout,
      proxy: proxy,
      headers: {
        'User-Agent': _browserUa,
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      },
    );
    try {
      final resp = await dio.get<String>(
        'https://www.bing.com/search',
        queryParameters: {
          'q': query,
          'format': 'rss',
          'count': maxResults,
          'setlang': 'en-US',
        },
        options: Options(responseType: ResponseType.plain),
        cancelToken: cancelToken,
      );
      final xml = resp.data ?? '';
      final results = _parseRss(xml, maxResults);
      if (results.isEmpty && _looksLikeBlockedPage(xml)) {
        throw const WebSearchTransientError(
          'Bing 返回了验证页面，可能因请求频次过高被临时限制。请稍后重试。',
        );
      }
      return results;
    } on DioException catch (e) {
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }

  List<WebSearchResult> _parseRss(String xml, int max) {
    final results = <WebSearchResult>[];
    final itemRegex = RegExp(
      r'<item>(.*?)</item>',
      multiLine: true,
      dotAll: true,
      caseSensitive: false,
    );
    final titleRegex = RegExp(
      r'<title>(.*?)</title>',
      dotAll: true,
      caseSensitive: false,
    );
    final linkRegex = RegExp(
      r'<link>(.*?)</link>',
      dotAll: true,
      caseSensitive: false,
    );
    final descRegex = RegExp(
      r'<description>(.*?)</description>',
      dotAll: true,
      caseSensitive: false,
    );
    for (final item in itemRegex.allMatches(xml)) {
      if (results.length >= max) break;
      final block = item.group(1) ?? '';
      final url = _decodeEntities(linkRegex.firstMatch(block)?.group(1) ?? '')
          .trim();
      if (!url.startsWith('http')) continue;
      final title = _stripHtml(
        _decodeEntities(
          _stripCdata(titleRegex.firstMatch(block)?.group(1) ?? ''),
        ),
      );
      final snippet = _stripHtml(
        _decodeEntities(
          _stripCdata(descRegex.firstMatch(block)?.group(1) ?? ''),
        ),
      );
      results.add(WebSearchResult(
        title: title,
        url: url,
        snippet: snippet,
      ));
    }
    return results;
  }
}

/// DuckDuckGo lite HTML（免 Key；国内直连通常超时，需要代理）
class _DuckDuckGoProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.duckduckgo;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final dio = createSearchDio(
      timeout: timeout,
      proxy: proxy,
      headers: {'User-Agent': _browserUa},
    );
    try {
      final resp = await dio.get<String>(
        'https://lite.duckduckgo.com/lite/',
        queryParameters: {'q': query, 'kl': 'us-en'},
        options: Options(responseType: ResponseType.plain),
        cancelToken: cancelToken,
      );
      final html = resp.data ?? '';
      final results = _parseDdgLite(html, maxResults);
      if (results.isEmpty && _looksLikeBlockedPage(html)) {
        throw const WebSearchTransientError(
          'DuckDuckGo 返回了反爬页面，请稍后重试或配置代理。',
        );
      }
      return results;
    } on DioException catch (e) {
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }

  List<WebSearchResult> _parseDdgLite(String html, int max) {
    final results = <WebSearchResult>[];
    final linkRegex = RegExp(
      r'<a[^>]*class="result-link"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
      multiLine: true,
      dotAll: true,
    );
    final snippetRegex = RegExp(
      r'<td[^>]*class="result-snippet"[^>]*>(.*?)</td>',
      multiLine: true,
      dotAll: true,
    );
    final links = linkRegex.allMatches(html).toList();
    final snippets = snippetRegex.allMatches(html).toList();
    for (var i = 0; i < links.length && results.length < max; i++) {
      final url = _unwrapDdgRedirect(links[i].group(1) ?? '');
      if (!url.startsWith('http')) continue;
      final snippet =
          i < snippets.length ? _stripHtml(snippets[i].group(1) ?? '') : '';
      results.add(WebSearchResult(
        title: _stripHtml(links[i].group(2) ?? ''),
        url: url,
        snippet: snippet,
      ));
    }
    return results;
  }

  String _unwrapDdgRedirect(String url) {
    var value = url;
    if (value.startsWith('//')) value = 'https:$value';
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    if (uri.host.contains('duckduckgo.com')) {
      final encoded = uri.queryParameters['uddg'];
      if (encoded != null) return Uri.decodeComponent(encoded);
    }
    return value;
  }
}

/// SearXNG 自建实例（JSON API）
class _SearXngProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.searxng;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final base = (instanceUrl ?? '').trim();
    if (base.isEmpty) {
      throw const WebSearchQuotaError(
        'SearXNG 实例地址未配置。请在「设置 → 联网搜索」填入自建实例 URL。',
        provider: WebSearchProvider.searxng,
        permanent: true,
      );
    }
    final normalizedBase =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final token = apiKey?.trim() ?? '';
    final dio = createSearchDio(
      timeout: timeout,
      proxy: proxy,
      headers: token.isEmpty ? null : {'Authorization': 'Bearer $token'},
    );
    try {
      final resp = await dio.get(
        '$normalizedBase/search',
        queryParameters: {
          'q': query,
          'format': 'json',
          'categories': 'general',
          'pageno': 1,
        },
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final results = data is Map ? data['results'] : null;
      if (results is! List) return [];
      final out = <WebSearchResult>[];
      for (final raw in results) {
        if (raw is! Map) continue;
        final url = raw['url']?.toString() ?? '';
        if (!url.startsWith('http')) continue;
        final template = raw['template']?.toString() ?? '';
        if (template.contains('images.html') ||
            template.contains('videos.html')) {
          continue;
        }
        out.add(WebSearchResult(
          title: raw['title']?.toString() ?? '',
          url: url,
          snippet: raw['content']?.toString() ?? '',
        ));
        if (out.length >= maxResults) break;
      }
      return out;
    } on DioException catch (e) {
      if (e.response?.statusCode == 422) {
        throw const WebSearchQuotaError(
          'SearXNG 实例未开启 JSON API。请在实例的 settings.yml 中添加 '
          '`search.formats: [html, json]` 后重启。',
          provider: WebSearchProvider.searxng,
          permanent: true,
        );
      }
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

// ─────────────────────────────────────────────────────────────
// 需要 API Key 的后端
// ─────────────────────────────────────────────────────────────

class _TavilyProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.tavily;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final key = _requireApiKey(apiKey, type);
    final dio = createSearchDio(
      timeout: timeout,
      proxy: proxy,
      headers: {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
      },
    );
    try {
      final resp = await dio.post(
        'https://api.tavily.com/search',
        data: jsonEncode({
          'query': query,
          'max_results': maxResults,
          'search_depth': 'basic',
          'include_answer': false,
        }),
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final results = data is Map ? data['results'] : null;
      if (results is! List) return [];
      return results
          .whereType<Map>()
          .map((r) => _result(
                r,
                urlKeys: const ['url'],
                titleKeys: const ['title'],
                snippetKeys: const ['content'],
              ))
          .where((r) => r.url.startsWith('http'))
          .take(maxResults)
          .toList();
    } on DioException catch (e) {
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

class _BraveProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.brave;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final key = _requireApiKey(apiKey, type);
    final dio = createSearchDio(timeout: timeout, proxy: proxy, headers: {
      'Accept': 'application/json',
      'X-Subscription-Token': key,
    });
    try {
      final resp = await dio.get(
        'https://api.search.brave.com/res/v1/web/search',
        queryParameters: {
          'q': query,
          'count': maxResults,
          'safesearch': 'moderate',
        },
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final web = data is Map ? data['web'] : null;
      final results = web is Map ? web['results'] : null;
      if (results is! List) return [];
      return results
          .whereType<Map>()
          .map((r) => _result(
                r,
                urlKeys: const ['url'],
                titleKeys: const ['title'],
                snippetKeys: const ['description', 'text'],
              ))
          .where((r) => r.url.startsWith('http'))
          .take(maxResults)
          .toList();
    } on DioException catch (e) {
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

class _SerperProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.serper;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final key = _requireApiKey(apiKey, type);
    final dio = createSearchDio(
      timeout: timeout,
      proxy: proxy,
      headers: {
        'X-API-KEY': key,
        'Content-Type': 'application/json',
      },
    );
    try {
      final resp = await dio.post(
        'https://google.serper.dev/search',
        data: jsonEncode({'q': query, 'num': maxResults}),
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final organic = data is Map ? data['organic'] : null;
      if (organic is! List) return [];
      return organic
          .whereType<Map>()
          .map((r) => _result(
                r,
                urlKeys: const ['link'],
                titleKeys: const ['title'],
                snippetKeys: const ['snippet'],
              ))
          .where((r) => r.url.startsWith('http'))
          .take(maxResults)
          .toList();
    } on DioException catch (e) {
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

class _MojeekProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.mojeek;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final key = _requireApiKey(apiKey, type);
    final dio = createSearchDio(timeout: timeout, proxy: proxy);
    try {
      final resp = await dio.get(
        'https://api.mojeek.com/search',
        queryParameters: {
          'q': query,
          'fmt': 'json',
          'api_key': key,
        },
        cancelToken: cancelToken,
      );
      final data = resp.data;
      dynamic payload = data is Map ? (data['response'] ?? data) : data;
      if (payload is String) {
        try {
          payload = jsonDecode(payload);
        } catch (_) {
          payload = null;
        }
      }
      final results = payload is Map ? payload['results'] : null;
      if (results is! List) return [];
      return results
          .whereType<Map>()
          .map((r) => _result(
                r,
                urlKeys: const ['url'],
                titleKeys: const ['title'],
                snippetKeys: const ['desc', 'description'],
              ))
          .where((r) => r.url.startsWith('http'))
          .take(maxResults)
          .toList();
    } on DioException catch (e) {
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

class _ExaProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.exa;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final key = _requireApiKey(apiKey, type);
    final dio = createSearchDio(
      timeout: timeout,
      proxy: proxy,
      headers: {
        'x-api-key': key,
        'Content-Type': 'application/json',
      },
    );
    try {
      final resp = await dio.post(
        'https://api.exa.ai/search',
        data: jsonEncode({
          'query': query,
          'numResults': maxResults,
          'contents': {
            'text': {'maxCharacters': 500},
          },
        }),
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final results = data is Map ? data['results'] : null;
      if (results is! List) return [];
      final out = <WebSearchResult>[];
      for (final raw in results) {
        if (raw is! Map) continue;
        final url = raw['url']?.toString() ?? '';
        if (!url.startsWith('http')) continue;
        var snippet = raw['text']?.toString() ?? '';
        if (snippet.isEmpty) {
          final highlights = raw['highlights'];
          if (highlights is List) {
            snippet = highlights.map((h) => h.toString()).join(' ');
          }
        }
        out.add(WebSearchResult(
          title: raw['title']?.toString() ?? '',
          url: url,
          snippet: snippet,
        ));
        if (out.length >= maxResults) break;
      }
      return out;
    } on DioException catch (e) {
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

class _ParallelProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.parallel;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final key = _requireApiKey(apiKey, type);
    final dio = createSearchDio(
      timeout: timeout,
      proxy: proxy,
      headers: {
        'x-api-key': key,
        'Content-Type': 'application/json',
      },
    );
    try {
      final resp = await dio.post(
        'https://api.parallel.ai/v1/search',
        data: jsonEncode({
          'objective': query,
          'search_queries': [query],
          'advanced_settings': {'max_results': maxResults},
        }),
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final results = data is Map ? data['results'] : null;
      if (results is! List) return [];
      final out = <WebSearchResult>[];
      for (final raw in results) {
        if (raw is! Map) continue;
        final url = raw['url']?.toString() ?? '';
        if (!url.startsWith('http')) continue;
        final excerpts = raw['excerpts'];
        final snippet = excerpts is List
            ? excerpts.map((e) => e.toString()).join(' ')
            : (excerpts?.toString() ?? '');
        out.add(WebSearchResult(
          title: raw['title']?.toString() ?? '',
          url: url,
          snippet: snippet,
        ));
        if (out.length >= maxResults) break;
      }
      return out;
    } on DioException catch (e) {
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

class _OpenAIProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.openai;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final key = _requireApiKey(apiKey, type);
    final dio = createSearchDio(
      timeout: timeout,
      proxy: proxy,
      headers: {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
      },
    );
    try {
      final resp = await dio.post(
        'https://api.openai.com/v1/responses',
        data: jsonEncode({
          'model': type.defaultModel,
          'input': query,
          'tools': [
            {'type': 'web_search'},
          ],
          'tool_choice': 'auto',
          'include': ['web_search_call.action.sources'],
          'max_output_tokens': 1200,
        }),
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final output = data is Map ? data['output'] : null;
      if (output is! List) return [];
      final merged = <String, WebSearchResult>{};
      for (final item in output) {
        if (item is! Map) continue;
        final itemType = item['type']?.toString();
        if (itemType == 'message') {
          final content = item['content'];
          if (content is! List) continue;
          for (final block in content) {
            if (block is! Map) continue;
            final text = block['text']?.toString() ?? '';
            final annotations = block['annotations'];
            if (annotations is! List) continue;
            for (final annotation in annotations) {
              if (annotation is! Map) continue;
              if (annotation['type']?.toString() != 'url_citation') continue;
              final url = annotation['url']?.toString() ?? '';
              if (!url.startsWith('http')) continue;
              final start = int.tryParse(
                annotation['start_index']?.toString() ?? '',
              );
              final end = int.tryParse(annotation['end_index']?.toString() ?? '');
              _putOpenAiResult(
                merged,
                url: url,
                title: annotation['title']?.toString() ?? '',
                snippet: _sliceText(text, start, end),
              );
            }
          }
        } else if (itemType == 'web_search_call') {
          final action = item['action'];
          final sources = action is Map ? action['sources'] : null;
          if (sources is! List) continue;
          for (final source in sources) {
            if (source is! Map) continue;
            final url = source['url']?.toString() ?? '';
            if (!url.startsWith('http')) continue;
            _putOpenAiResult(merged, url: url, title: '', snippet: '');
          }
        }
      }
      return merged.values.take(maxResults).toList();
    } on DioException catch (e) {
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

class _AnthropicProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.anthropic;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    final key = _requireApiKey(apiKey, type);
    final dio = createSearchDio(
      timeout: timeout,
      proxy: proxy,
      headers: {
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      },
    );
    try {
      final resp = await dio.post(
        'https://api.anthropic.com/v1/messages',
        data: jsonEncode({
          'model': type.defaultModel,
          'max_tokens': 1024,
          'messages': [
            {'role': 'user', 'content': query},
          ],
          'tools': [
            {
              'type': 'web_search_20250305',
              'name': 'web_search',
              'max_uses': maxResults.clamp(1, 10),
            },
          ],
        }),
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final content = data is Map ? data['content'] : null;
      if (content is! List) return [];
      final merged = <String, WebSearchResult>{};
      for (final block in content) {
        if (block is! Map) continue;
        final blockType = block['type']?.toString();
        if (blockType == 'web_search_tool_result') {
          final result = block['content'];
          if (result is Map && result['error_code'] != null) {
            throw WebSearchTransientError(
              'Anthropic 搜索失败：${result['error_code']}',
            );
          }
          if (result is! List) continue;
          for (final raw in result) {
            if (raw is! Map) continue;
            if (raw['type']?.toString() != 'web_search_result') continue;
            final url = raw['url']?.toString() ?? '';
            if (!url.startsWith('http')) continue;
            _putOpenAiResult(
              merged,
              url: url,
              title: raw['title']?.toString() ?? '',
              snippet: '',
            );
          }
        } else if (blockType == 'text') {
          final citations = block['citations'];
          if (citations is! List) continue;
          for (final citation in citations) {
            if (citation is! Map) continue;
            final url = citation['url']?.toString() ?? '';
            if (!url.startsWith('http')) continue;
            _putOpenAiResult(
              merged,
              url: url,
              title: citation['title']?.toString() ?? '',
              snippet: citation['cited_text']?.toString() ?? '',
            );
          }
        }
      }
      return merged.values.take(maxResults).toList();
    } on DioException catch (e) {
      throw translateSearchDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

void _putOpenAiResult(
  Map<String, WebSearchResult> out, {
  required String url,
  required String title,
  required String snippet,
}) {
  final existing = out[url];
  if (existing == null) {
    out[url] = WebSearchResult(title: title, url: url, snippet: snippet);
    return;
  }
  out[url] = WebSearchResult(
    title: existing.title.isEmpty ? title : existing.title,
    url: url,
    snippet: snippet.length > existing.snippet.length
        ? snippet
        : existing.snippet,
  );
}

String _sliceText(String text, int? start, int? end) {
  if (start == null || end == null) return '';
  if (start < 0 || end <= start || start >= text.length) return '';
  final safeEnd = end.clamp(start, text.length);
  final value = text.substring(start, safeEnd).trim();
  return value.length > 300 ? '${value.substring(0, 300)}…' : value;
}

// ─────────────────────────────────────────────────────────────
// HTML/XML 工具
// ─────────────────────────────────────────────────────────────

const String _browserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';

String _stripHtml(String input) {
  return _decodeEntities(input.replaceAll(RegExp(r'<[^>]*>'), ''))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _decodeEntities(String input) {
  return input
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
        final code = int.tryParse(m.group(1) ?? '');
        return code != null ? String.fromCharCode(code) : (m.group(0) ?? '');
      })
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
        final code = int.tryParse(m.group(1) ?? '', radix: 16);
        return code != null ? String.fromCharCode(code) : (m.group(0) ?? '');
      });
}

String _stripCdata(String input) {
  final trimmed = input.trim();
  if (trimmed.startsWith('<![CDATA[') && trimmed.endsWith(']]>')) {
    return trimmed.substring(9, trimmed.length - 3);
  }
  return input;
}

bool _looksLikeBlockedPage(String body) {
  final lower = body.toLowerCase();
  return lower.contains('captcha') ||
      lower.contains('verify you are human') ||
      lower.contains('unusual traffic') ||
      lower.contains('anomaly-modal') ||
      lower.contains('验证您是否是真人');
}
