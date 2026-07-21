import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'web_search_config.dart';

/// 一条搜索结果
class WebSearchResult {
  final String title;
  final String url;
  /// 摘要（部分 provider 提供，可能为空）
  final String snippet;

  const WebSearchResult({
    required this.title,
    required this.url,
    this.snippet = '',
  });

  /// 序列化为多行文本（供 AI 阅读）
  ///
  /// 仅给标题+url+snippet，由 AI 自己提取有用信息。
  /// 不抓取正文——若需要正文，AI 应主动调用 fetch_url 工具。
  String toDisplayString(int index) {
    final sb = StringBuffer();
    sb.writeln('[${index + 1}] ${title.isEmpty ? "(无标题)" : title}');
    sb.writeln('    URL: $url');
    if (snippet.isNotEmpty) {
      sb.writeln('    摘要: $snippet');
    }
    return sb.toString().trimRight();
  }
}

/// 搜索 provider 抽象
abstract class WebSearchProviderApi {
  WebSearchProvider get type;
  String get name;

  /// 执行搜索
  ///
  /// [apiKey] 对需要 key 的 provider 必填；[duckduckgo] 可为空。
  /// [cancelToken] 用于响应任务取消（与 AgentTool.cancelToken 桥接）。
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required int timeoutSeconds,
    String? apiKey,
    CancelToken? cancelToken,
  });
}

// ─────────────────────────────────────────────────────────────
// Tavily
// ─────────────────────────────────────────────────────────────

class _TavilyProvider extends WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.tavily;
  @override
  String get name => 'Tavily';

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required int timeoutSeconds,
    String? apiKey,
    CancelToken? cancelToken,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw WebSearchQuotaError(
        'Tavily API key 未配置。请在「设置 → 联网搜索」中填写 API key 后重试。',
        provider: type,
        permanent: true,
      );
    }
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: timeoutSeconds),
      receiveTimeout: Duration(seconds: timeoutSeconds),
    ));
    try {
      final resp = await dio.post(
        'https://api.tavily.com/search',
        options: Options(headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        }),
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
          .map((r) => WebSearchResult(
                title: (r is Map ? r['title'] : null)?.toString() ?? '',
                url: (r is Map ? r['url'] : null)?.toString() ?? '',
                snippet: (r is Map ? r['content'] : null)?.toString() ?? '',
              ))
          .where((r) => r.url.isNotEmpty)
          .take(maxResults)
          .toList();
    } on DioException catch (e) {
      throw _translateDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Bing Search API (Azure)
// ─────────────────────────────────────────────────────────────

class _BingProvider extends WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.bing;
  @override
  String get name => 'Bing';

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required int timeoutSeconds,
    String? apiKey,
    CancelToken? cancelToken,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw WebSearchQuotaError(
        'Bing API key 未配置。请在「设置 → 联网搜索」中填写 API key 后重试。',
        provider: type,
        permanent: true,
      );
    }
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: timeoutSeconds),
      receiveTimeout: Duration(seconds: timeoutSeconds),
    ));
    try {
      final resp = await dio.get(
        'https://api.bing.microsoft.com/v7.0/search',
        queryParameters: {
          'q': query,
          'count': maxResults,
          'safeSearch': 'Moderate',
        },
        options: Options(headers: {
          'Ocp-Apim-Subscription-Key': apiKey,
        }),
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final webPages = data is Map ? data['webPages'] : null;
      final value = webPages is Map ? webPages['value'] : null;
      if (value is! List) return [];
      return value
          .map((r) => WebSearchResult(
                title: (r is Map ? r['name'] : null)?.toString() ?? '',
                url: (r is Map ? r['url'] : null)?.toString() ?? '',
                snippet: (r is Map ? r['snippet'] : null)?.toString() ?? '',
              ))
          .where((r) => r.url.isNotEmpty)
          .take(maxResults)
          .toList();
    } on DioException catch (e) {
      throw _translateDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

// ─────────────────────────────────────────────────────────────
// SerpAPI (聚合 Google/Bing 等)
// ─────────────────────────────────────────────────────────────

class _SerpApiProvider extends WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.serpapi;
  @override
  String get name => 'SerpAPI';

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required int timeoutSeconds,
    String? apiKey,
    CancelToken? cancelToken,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw WebSearchQuotaError(
        'SerpAPI key 未配置。请在「设置 → 联网搜索」中填写 API key 后重试。',
        provider: type,
        permanent: true,
      );
    }
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: timeoutSeconds),
      receiveTimeout: Duration(seconds: timeoutSeconds),
    ));
    try {
      final resp = await dio.get(
        'https://serpapi.com/search',
        queryParameters: {
          'engine': 'google',
          'q': query,
          'num': maxResults,
          'api_key': apiKey,
        },
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final organic = data is Map ? data['organic_results'] : null;
      if (organic is! List) return [];
      return organic
          .map((r) => WebSearchResult(
                title: (r is Map ? r['title'] : null)?.toString() ?? '',
                url: ((r is Map ? r['link'] : null) ??
                        (r is Map ? r['url'] : null))
                    ?.toString() ??
                    '',
                snippet: (r is Map ? r['snippet'] : null)?.toString() ?? '',
              ))
          .where((r) => r.url.isNotEmpty)
          .take(maxResults)
          .toList();
    } on DioException catch (e) {
      throw _translateDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Brave Search API（免费 2000 次/月，独立索引）
// ─────────────────────────────────────────────────────────────

/// Brave Search API provider
///
/// 与 Bing/Tavily 的区别：Brave 用自己的独立索引（不依赖 Google/Bing），
/// 免费层 2000 次/月，无信用卡。注册地址：https://brave.com/search/api/
///
/// 文档：GET https://api.search.brave.com/res/v1/web/search
/// Header: `X-Subscription-Token: <API_KEY>`
/// 返回 JSON，结果在 `web.results[]`，每条含 title/url/description
class _BraveProvider extends WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.brave;
  @override
  String get name => 'Brave';

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required int timeoutSeconds,
    String? apiKey,
    CancelToken? cancelToken,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw WebSearchQuotaError(
        'Brave API key 未配置。请在「设置 → 联网搜索」中填写 API key 后重试。',
        provider: type,
        permanent: true,
      );
    }
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: timeoutSeconds),
      receiveTimeout: Duration(seconds: timeoutSeconds),
    ));
    try {
      final resp = await dio.get(
        'https://api.search.brave.com/res/v1/web/search',
        queryParameters: {
          'q': query,
          'count': maxResults,
          // fresh 搜索（不用个性化）
          'freshness': 'pw',
        },
        options: Options(headers: {
          'Accept': 'application/json',
          'X-Subscription-Token': apiKey,
        }),
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final web = data is Map ? data['web'] : null;
      final results = web is Map ? web['results'] : null;
      if (results is! List) return [];
      return results
          .map((r) => WebSearchResult(
                title: (r is Map ? r['title'] : null)?.toString() ?? '',
                url: (r is Map ? r['url'] : null)?.toString() ?? '',
                snippet: ((r is Map ? r['description'] : null) ??
                        (r is Map ? r['text'] : null))
                    ?.toString() ??
                    '',
              ))
          .where((r) => r.url.isNotEmpty)
          .take(maxResults)
          .toList();
    } on DioException catch (e) {
      throw _translateDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

// ─────────────────────────────────────────────────────────────
// SearXNG（自建实例，聚合 70+ 搜索引擎）
// ─────────────────────────────────────────────────────────────

/// SearXNG provider（需自建实例）
///
/// SearXNG 是开源元搜索引擎，聚合 Google/Bing/DuckDuckGo/Wikipedia 等 70+ 搜索引擎结果。
/// 公共实例几乎都启用了反爬保护，无法直接 HTTP 调用。
/// 用户需自建实例（Docker 部署），填入 [instanceUrl]。
///
/// API 格式：GET `<instanceUrl>/search?q=xxx&format=json&categories=general`
/// 返回 JSON，结果在 `results[]`，每条含 title/url/content/engines
///
/// 部署文档：https://docs.searxng.org/admin/installation.html
/// Docker 一行启动：`docker run -d -p 8080:8080 searxng/searxng:latest`
/// （需在 settings.yml 开启 `search.formats: [html, json]`）
class _SearXngProvider extends WebSearchProviderApi {
  /// 从 apiKey 参数中取 instanceUrl（复用现有签名，避免改接口）
  ///
  /// 设计权衡：不改 WebSearchProviderApi.search 签名（保持 LSP），
  /// 通过 apiKey 字段传 instanceUrl。WebSearchService._doSearch 会处理这个转换。
  /// 若 apiKey 为空或不是 URL，抛错引导用户配置。
  String _resolveInstanceUrl(String? apiKey) {
    final url = apiKey?.trim() ?? '';
    if (url.isEmpty) {
      throw WebSearchQuotaError(
        'SearXNG 实例地址未配置。请在「设置 → 联网搜索」中填入自建实例 URL（如 http://localhost:8080）。',
        provider: type,
        permanent: true,
      );
    }
    // 去掉末尾斜杠
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  @override
  WebSearchProvider get type => WebSearchProvider.searxng;
  @override
  String get name => 'SearXNG';

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required int timeoutSeconds,
    String? apiKey,
    CancelToken? cancelToken,
  }) async {
    final baseUrl = _resolveInstanceUrl(apiKey);
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: timeoutSeconds),
      receiveTimeout: Duration(seconds: timeoutSeconds),
    ));
    try {
      final resp = await dio.get(
        '$baseUrl/search',
        queryParameters: {
          'q': query,
          'format': 'json',
          'categories': 'general',
          // 不限语言，让 SearXNG 自动选
          'pageno': 1,
        },
        cancelToken: cancelToken,
      );
      final data = resp.data;
      final results = data is Map ? data['results'] : null;
      if (results is! List) return [];
      final out = <WebSearchResult>[];
      for (final r in results) {
        if (r is! Map) continue;
        final url = r['url']?.toString() ?? '';
        if (url.isEmpty) continue;
        // SearXNG 结果里的 image/ad 类结果跳过，只保留 web 结果
        final template = r['template']?.toString() ?? '';
        if (template.contains('images.html') || template.contains('videos.html')) {
          continue;
        }
        out.add(WebSearchResult(
          title: r['title']?.toString() ?? '',
          url: url,
          snippet: r['content']?.toString() ?? '',
        ));
        if (out.length >= maxResults) break;
      }
      return out;
    } on DioException catch (e) {
      // SearXNG 常见问题：未在 settings.yml 开启 json format
      final code = e.response?.statusCode;
      if (code == 422) {
        throw WebSearchQuotaError(
          'SearXNG 实例未开启 JSON API。请在实例的 settings.yml 中添加 `search.formats: [html, json]` 后重启。',
          provider: type,
          permanent: true,
        );
      }
      throw _translateDioError(e, type);
    } finally {
      dio.close();
    }
  }
}

// ─────────────────────────────────────────────────────────────
// HTML 解析工具 mixin（DDG / Bing 网页抓取共享）
// ─────────────────────────────────────────────────────────────

/// HTML 解析共享工具
///
/// 抽出 DDG 和 Bing 网页抓取共用的 HTML 处理方法。
/// 不依赖外部 html 解析库（pubspec 无 html 依赖），正则够用：
/// AI 能从中提取有用信息即可，不需要像素级 markdown 还原。
mixin _HtmlParseMixin {
  /// 通用 User-Agent（避免被反爬识别为 bot）
  static const String browserUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';

  /// 剥离 HTML 标签 + 解码常见实体
  String stripHtml(String s) {
    return s
        .replaceAll(RegExp(r'<[^>]*>'), '')
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
        })
        .trim();
  }
}

// ─────────────────────────────────────────────────────────────
// Bing 网页抓取（免 key，直接解析 bing.com/search HTML）
// ─────────────────────────────────────────────────────────────

/// 直接抓取 Bing 搜索结果页 HTML 并解析
///
/// 与 [_BingProvider]（Azure API）的区别：
/// - 完全免费，无 API key、无配额限制
/// - 结果与 bing.com 浏览器搜索完全一致（同一搜索引擎）
/// - 依赖 HTML 结构稳定；Bing 改版会导致解析失效（需更新正则）
/// - 高频请求可能触发反爬封锁 IP（AI agent 场景频次低，风险可控）
///
/// HTML 结构（bing.com/search?q=xxx）：
/// ```html
/// <ol id="b_results">
///   <li class="b_algo">
///     <h2><a href="URL">title</a></h2>
///     <p class="b_lineclamp...">snippet</p>  或  <div class="b_caption"><p>snippet</p></div>
///   </li>
///   ...
/// </ol>
/// ```
class _BingHtmlProvider extends WebSearchProviderApi with _HtmlParseMixin {
  @override
  WebSearchProvider get type => WebSearchProvider.bingHtml;
  @override
  String get name => 'Bing 网页';

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required int timeoutSeconds,
    String? apiKey,
    CancelToken? cancelToken,
  }) async {
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: timeoutSeconds),
      receiveTimeout: Duration(seconds: timeoutSeconds),
      headers: {
        'User-Agent': _HtmlParseMixin.browserUa,
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      },
    ));
    try {
      final resp = await dio.get(
        'https://www.bing.com/search',
        queryParameters: {
          'q': query,
          'count': maxResults,
          // setlang=en 让结果更通用，避免被本地化到小语种
          'setlang': 'en-US',
        },
        cancelToken: cancelToken,
      );
      final html = resp.data?.toString() ?? '';
      final results = _parseBingHtml(html, maxResults);
      // Bing 偶尔会对可疑 UA 返回空结果或验证页，检测一下
      if (results.isEmpty && _looksLikeCaptchaPage(html)) {
        throw WebSearchTransientError(
          'Bing 返回了验证页面，可能因请求频次过高被临时限制。请稍后重试或换用其他 provider。',
        );
      }
      return results;
    } on DioException catch (e) {
      throw _translateDioError(e, type);
    } finally {
      dio.close();
    }
  }

  /// 解析 bing.com/search 的结果 HTML
  ///
  /// 每个结果位于 `<li class="b_algo">` 内：
  /// - 标题链接：`<h2><a href="URL">title</a></h2>`
  /// - 摘要：`<p class="b_lineclamp*">` 或 `<div class="b_caption">` 内的 `<p>`
  List<WebSearchResult> _parseBingHtml(String html, int max) {
    final results = <WebSearchResult>[];
    // 切出每个 b_algo 块，避免跨结果串扰
    final blockRegex = RegExp(
      r'<li[^>]*class="[^"]*b_algo[^"]*"[^>]*>(.*?)</li>',
      multiLine: true,
      dotAll: true,
    );
    final linkRegex = RegExp(
      r'<h2>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    );
    final snippetRegex = RegExp(
      r'<p[^>]*class="[^"]*b_lineclamp[^"]*"[^>]*>(.*?)</p>',
      caseSensitive: false,
      dotAll: true,
    );
    final captionRegex = RegExp(
      r'<div[^>]*class="[^"]*b_caption[^"]*"[^>]*>.*?<p[^>]*>(.*?)</p>',
      caseSensitive: false,
      dotAll: true,
    );

    for (final block in blockRegex.allMatches(html)) {
      if (results.length >= max) break;
      final blockHtml = block.group(1) ?? '';
      final link = linkRegex.firstMatch(blockHtml);
      if (link == null) continue;
      final url = link.group(1) ?? '';
      if (url.isEmpty || url.startsWith('javascript:')) continue;
      final title = stripHtml(link.group(2) ?? '');
      // 摘要：优先 b_lineclamp，兜底 b_caption
      String snippet = '';
      final snipM = snippetRegex.firstMatch(blockHtml);
      if (snipM != null) {
        snippet = stripHtml(snipM.group(1) ?? '');
      } else {
        final capM = captionRegex.firstMatch(blockHtml);
        if (capM != null) {
          snippet = stripHtml(capM.group(1) ?? '');
        }
      }
      results.add(WebSearchResult(
        title: title,
        url: url,
        snippet: snippet,
      ));
    }
    return results;
  }

  /// 检测是否是反爬验证页（Bing 异常时返回的 captcha / 阻断页）
  bool _looksLikeCaptchaPage(String html) {
    final lower = html.toLowerCase();
    // 常见 captcha 标识
    return lower.contains('captcha') ||
        lower.contains('verify you are human') ||
        lower.contains('验证您是否是真人') ||
        // 异常短响应通常是错误页
        (html.length < 2000 && !lower.contains('b_algo'));
  }
}

// ─────────────────────────────────────────────────────────────
// DuckDuckGo (lite HTML 接口，免 key)
// ─────────────────────────────────────────────────────────────

class _DuckDuckGoProvider extends WebSearchProviderApi with _HtmlParseMixin {
  @override
  WebSearchProvider get type => WebSearchProvider.duckduckgo;
  @override
  String get name => 'DuckDuckGo';

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required int timeoutSeconds,
    String? apiKey,
    CancelToken? cancelToken,
  }) async {
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: timeoutSeconds),
      receiveTimeout: Duration(seconds: timeoutSeconds),
      headers: {
        'User-Agent': _HtmlParseMixin.browserUa,
      },
      // DDG 返回 HTML， responseType 保持 default
    ));
    try {
      // 用 lite 接口：返回结构简单的 HTML，便于解析
      final resp = await dio.get(
        'https://lite.duckduckgo.com/lite/',
        queryParameters: {'q': query, 'kl': 'us-en'},
        cancelToken: cancelToken,
      );
      final html = resp.data?.toString() ?? '';
      return _parseDdgLite(html, maxResults);
    } on DioException catch (e) {
      throw _translateDioError(e, type);
    } finally {
      dio.close();
    }
  }

  /// 解析 DDG lite HTML 表格结果
  ///
  /// lite.duckduckgo.com/lite 返回一个 0border 表格，每个结果行含：
  /// `<a class="result-link" href="URL">title</a>` 和 `<td class="result-snippet">...</td>`
  List<WebSearchResult> _parseDdgLite(String html, int max) {
    final results = <WebSearchResult>[];
    // 链接 + 标题：匹配 href="..."，取其后到 </a> 的文本作为标题
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
      final url = links[i].group(1) ?? '';
      // DDG lite 有时会把链接包成 //duckduckgo.com/l/?uddg=ENC，解一下
      final cleanedUrl = _unwrapDdgRedirect(url);
      if (cleanedUrl.isEmpty) continue;
      final titleRaw = links[i].group(2) ?? '';
      final snippet = i < snippets.length ? stripHtml(snippets[i].group(1) ?? '') : '';
      results.add(WebSearchResult(
        title: stripHtml(titleRaw),
        url: cleanedUrl,
        snippet: snippet,
      ));
    }
    return results;
  }

  String _unwrapDdgRedirect(String url) {
    // lite 接口可能给 //duckduckgo.com/l/?uddg=ENC
    if (url.startsWith('//')) url = 'https:$url';
    final u = Uri.tryParse(url);
    if (u == null) return url;
    if (u.host.contains('duckduckgo.com')) {
      final enc = u.queryParameters['uddg'];
      if (enc != null) {
        return Uri.decodeComponent(enc);
      }
    }
    return url;
  }
}

// ─────────────────────────────────────────────────────────────
// 错误转换
// ─────────────────────────────────────────────────────────────

/// 不可恢复的搜索错误（如配额耗尽、key 失效）
///
/// 设计意图：当 AI 反复调用 web_search 失败时，工具返回的明确错误信息能让
/// AI 知道"不要再试了"，避免 ReAct 循环陷入死循环（与 _noCommandRetryCount 配合）。
class WebSearchQuotaError implements Exception {
  final String message;
  final WebSearchProvider provider;
  /// true 表示重试也不会成功（如 401/403/配额耗尽），AI 应放弃此路径
  final bool permanent;
  const WebSearchQuotaError(this.message, {required this.provider, this.permanent = false});

  @override
  String toString() => message;
}

/// 将 DioException 转换为业务可读错误
///
/// 关键：401/403 → WebSearchQuotaError(permanent=true)，AI 应停止重试；
/// 429 → WebSearchQuotaError(permanent=false)，AI 可换 provider 或稍后再试。
Exception _translateDioError(DioException e, WebSearchProvider provider) {
  final code = e.response?.statusCode;
  if (code == 401 || code == 403) {
    return WebSearchQuotaError(
      '${provider.displayName} 认证失败 (HTTP $code)：API key 无效或已过期，请检查配置。',
      provider: provider,
      permanent: true,
    );
  }
  if (code == 429) {
    return WebSearchQuotaError(
      '${provider.displayName} 触发速率限制 (HTTP 429)：免费额度可能已用尽，请稍后重试或更换 provider。',
      provider: provider,
      permanent: false,
    );
  }
  if (e.type == DioExceptionType.cancel) {
    return WebSearchCancelledError('搜索已被用户取消');
  }
  if (e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.connectionError) {
    return WebSearchTransientError('网络错误：${e.message ?? e.type.name}。请检查网络连接后重试。');
  }
  return WebSearchTransientError('搜索请求失败：${e.message ?? e.toString()}');
}

/// 可重试的瞬时错误（网络、服务端 5xx 等）
class WebSearchTransientError implements Exception {
  final String message;
  const WebSearchTransientError(this.message);
  @override
  String toString() => message;
}

/// 用户取消
class WebSearchCancelledError implements Exception {
  final String message;
  const WebSearchCancelledError(this.message);
  @override
  String toString() => message;
}

// ─────────────────────────────────────────────────────────────
// WebSearchService — 对外调度入口
// ─────────────────────────────────────────────────────────────

/// 联网搜索调度服务
///
/// 工具层（[WebSearchTool]）只调 [search]，无需关心当前 provider。
/// 配置由 [WebSearchConfig.load()] 提供；apiKey 按需异步读取（不缓存明文）。
class WebSearchService {
  WebSearchService._();
  static final WebSearchService instance = WebSearchService._();

  static final Map<WebSearchProvider, WebSearchProviderApi> _providers = {
    WebSearchProvider.tavily: _TavilyProvider(),
    WebSearchProvider.bing: _BingProvider(),
    WebSearchProvider.bingHtml: _BingHtmlProvider(),
    WebSearchProvider.brave: _BraveProvider(),
    WebSearchProvider.searxng: _SearXngProvider(),
    WebSearchProvider.serpapi: _SerpApiProvider(),
    WebSearchProvider.duckduckgo: _DuckDuckGoProvider(),
  };

  /// 当前配置（每次调用重新读取，保证 UI 修改后立即生效）
  WebSearchConfig get _config => WebSearchConfig.load();

  /// 当前是否启用（仅用于工具注册决策；运行时是否真正调用由工具存在性决定）
  bool get isEnabled => _config.enabled;

  /// 当前 provider（暴露给 UI 显示）
  WebSearchProvider get currentProvider => _config.provider;

  /// 执行搜索（含自动降级）
  ///
  /// [maxResults] 可覆盖全局配置；null 或 <=0 表示用全局默认。
  /// 硬上限 20 条，防止 AI 请求过多浪费配额。
  /// 调用者需传入与 AgentTool.cancelToken 桥接的 [dioCancelToken]。
  ///
  /// 降级策略（仅瞬时错误触发，认证/配额/取消不降级）：
  /// - [WebSearchProvider.bingHtml] 瞬时失败 → DDG
  /// - [WebSearchProvider.brave] 瞬时失败 → bingHtml → DDG（两级）
  /// - [WebSearchProvider.searxng] 瞬时失败 → bingHtml → DDG（两级）
  /// - 其他 provider（tavily/bing api/serpapi）失败不降级
  ///   因为它们的失败多为配额/key 问题，换 DDG 反而掩盖真实错误
  /// - [WebSearchCancelledError] 永不降级（取消是用户意图）
  /// - [WebSearchQuotaError] 永不降级（认证问题换 provider 没用）
  ///
  /// 失败抛 [WebSearchQuotaError] / [WebSearchTransientError] / [WebSearchCancelledError]。
  Future<List<WebSearchResult>> search(
    String query, {
    int? maxResults,
    CancelToken? dioCancelToken,
  }) async {
    final cfg = _config;
    final effectiveMax = (maxResults != null && maxResults > 0)
        ? maxResults.clamp(1, 20)
        : cfg.maxResults;

    // 根据当前 provider 计算降级链
    final fallbackChain = _buildFallbackChain(cfg.provider);

    WebSearchTransientError? lastError;

    for (var i = 0; i < fallbackChain.length; i++) {
      final p = fallbackChain[i];
      try {
        final r = await _doSearch(
          provider: p,
          query: query,
          maxResults: effectiveMax,
          timeoutSeconds: cfg.timeoutSeconds,
          dioCancelToken: dioCancelToken,
          config: cfg,
        );
        if (i == 0) {
          // 主 provider 成功，直接返回
          return r;
        }
        // 降级成功：在第一条结果前加标记（透明告知 AI 用了 fallback）
        if (r.isEmpty) return r;
        final providerNames = fallbackChain
            .take(i)
            .map((x) => x.displayName.split(' ').first)
            .join(' → ');
        return [
          WebSearchResult(
            title: '[降级提示] 主搜索源 $providerNames 失败，已自动降级到 ${p.displayName.split(' ').first}',
            url: '',
            snippet: '原始错误: ${lastError?.message ?? "未知错误"}',
          ),
          ...r,
        ];
      } on WebSearchCancelledError {
        rethrow; // 用户取消，永不降级
      } on WebSearchQuotaError {
        rethrow; // 认证/配额问题，降级无意义
      } on WebSearchTransientError catch (e) {
        lastError = e;
        // 继续下一个 fallback
        continue;
      }
    }
    // 所有 fallback 都失败：抛最后一个错误
    throw lastError ?? WebSearchTransientError('所有搜索 provider 均失败');
  }

  /// 构建 provider 降级链
  ///
  /// 返回的列表首元素是主 provider，后续是降级顺序。
  /// 降级链只包含"免 key 的网页抓取" provider（bingHtml / duckduckgo），
  /// 因为这些才是真正的"瞬时失败可重试"场景。
  /// API 类 provider（tavily/bing/brave/serpapi）失败不参与降级链。
  List<WebSearchProvider> _buildFallbackChain(WebSearchProvider primary) {
    switch (primary) {
      case WebSearchProvider.bingHtml:
        return [WebSearchProvider.bingHtml, WebSearchProvider.duckduckgo];
      case WebSearchProvider.brave:
        // Brave 失败 → bingHtml → DDG
        return [
          WebSearchProvider.brave,
          WebSearchProvider.bingHtml,
          WebSearchProvider.duckduckgo,
        ];
      case WebSearchProvider.searxng:
        // 自建实例失败 → bingHtml → DDG
        return [
          WebSearchProvider.searxng,
          WebSearchProvider.bingHtml,
          WebSearchProvider.duckduckgo,
        ];
      default:
        // tavily/bing/serpapi/duckduckgo 不降级
        return [primary];
    }
  }

  /// 实际调用单个 provider
  ///
  /// [config] 用于读取 searxngInstanceUrl（searxng provider 专用）
  Future<List<WebSearchResult>> _doSearch({
    required WebSearchProvider provider,
    required String query,
    required int maxResults,
    required int timeoutSeconds,
    required WebSearchConfig config,
    CancelToken? dioCancelToken,
  }) async {
    final api = _providers[provider]!;
    // 解析 apiKey / instanceUrl
    String? apiKey;
    if (provider.requiresApiKey) {
      apiKey = await WebSearchConfig.getApiKey(provider);
    } else if (provider.requiresInstanceUrl) {
      // searxng：复用 apiKey 参数位传 instanceUrl（见 _SearXngProvider 文档）
      apiKey = config.searxngInstanceUrl;
    }
    return api.search(
      query: query,
      maxResults: maxResults,
      timeoutSeconds: timeoutSeconds,
      apiKey: apiKey,
      cancelToken: dioCancelToken,
    );
  }
}
