import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/web_search_backends.dart';
import 'package:ai_terminal/services/web_search_config.dart';
import 'package:ai_terminal/services/web_search_service.dart';

void main() {
  group('WebSearchService 聚合调度', () {
    late Map<WebSearchProvider, WebSearchProviderApi> originalProviders;

    setUp(() {
      originalProviders =
          Map<WebSearchProvider, WebSearchProviderApi>.from(webSearchProviders);
    });

    tearDown(() {
      webSearchProviders
        ..clear()
        ..addAll(originalProviders);
    });

    test('并发 fan-out 后按 URL 去重合并来源', () async {
      webSearchProviders
        ..[WebSearchProvider.bingRss] = _FakeProvider(
          WebSearchProvider.bingRss,
          results: const [
            WebSearchResult(
              title: 'Shared',
              url: 'https://example.com/a?utm_source=bing',
              snippet: 'short',
            ),
          ],
        )
        ..[WebSearchProvider.brave] = _FakeProvider(
          WebSearchProvider.brave,
          results: const [
            WebSearchResult(
              title: 'Shared 2',
              url: 'http://www.example.com/a/',
              snippet: 'a longer snippet',
            ),
          ],
        );

      final response = await WebSearchService.instance.search(
        'flutter',
        configOverride: const WebSearchConfig(
          enabledBackends: [
            WebSearchProvider.bingRss,
            WebSearchProvider.brave,
          ],
          concurrency: 2,
          backendTimeoutMs: 5000,
        ),
        apiKeyOverrides: const {WebSearchProvider.brave: 'key'},
      );

      expect(response.results, hasLength(1));
      expect(response.results.first.snippet, 'a longer snippet');
      expect(response.results.first.sources, [
        WebSearchProvider.bingRss,
        WebSearchProvider.brave,
      ]);
      expect(response.successCount, 2);
      expect(response.failureCount, 0);
      expect(
        response.reports.map((r) => r.provider),
        [WebSearchProvider.bingRss, WebSearchProvider.brave],
      );
    });

    test('部分后端失败仍返回其他后端结果', () async {
      webSearchProviders
        ..[WebSearchProvider.bingRss] = _FakeProvider(
          WebSearchProvider.bingRss,
          results: const [
            WebSearchResult(title: 'ok', url: 'https://example.com/ok'),
          ],
        )
        ..[WebSearchProvider.duckduckgo] = _FakeProvider(
          WebSearchProvider.duckduckgo,
          error: const WebSearchTransientError('boom'),
        );

      final response = await WebSearchService.instance.search(
        'flutter',
        configOverride: const WebSearchConfig(
          enabledBackends: [
            WebSearchProvider.bingRss,
            WebSearchProvider.duckduckgo,
          ],
          backendTimeoutMs: 5000,
        ),
      );

      expect(response.results, hasLength(1));
      expect(response.successCount, 1);
      expect(response.failureCount, 1);
      expect(response.failures.single.error, 'boom');
    });

    test('所有后端失败时抛出聚合错误', () async {
      webSearchProviders
        ..[WebSearchProvider.bingRss] = _FakeProvider(
          WebSearchProvider.bingRss,
          error: const WebSearchTransientError('bing down'),
        )
        ..[WebSearchProvider.duckduckgo] = _FakeProvider(
          WebSearchProvider.duckduckgo,
          error: const WebSearchTransientError('ddg down'),
        );

      await expectLater(
        WebSearchService.instance.search(
          'flutter',
          configOverride: const WebSearchConfig(
            enabledBackends: [
              WebSearchProvider.bingRss,
              WebSearchProvider.duckduckgo,
            ],
            backendTimeoutMs: 5000,
          ),
        ),
        throwsA(
          isA<WebSearchTransientError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Bing RSS'), contains('DuckDuckGo')),
          ),
        ),
      );
    });

    test('超过 backendTimeoutMs 的后端记为超时', () async {
      webSearchProviders
        ..[WebSearchProvider.bingRss] = _FakeProvider(
          WebSearchProvider.bingRss,
          delay: const Duration(milliseconds: 400),
        )
        ..[WebSearchProvider.duckduckgo] = _FakeProvider(
          WebSearchProvider.duckduckgo,
          results: const [
            WebSearchResult(title: 'fast', url: 'https://example.com/fast'),
          ],
        );

      final response = await WebSearchService.instance.search(
        'flutter',
        configOverride: const WebSearchConfig(
          enabledBackends: [
            WebSearchProvider.bingRss,
            WebSearchProvider.duckduckgo,
          ],
          concurrency: 2,
          backendTimeoutMs: 80,
        ),
      );

      expect(response.results, hasLength(1));
      final bingReport = response.reports
          .firstWhere((r) => r.provider == WebSearchProvider.bingRss);
      expect(bingReport.ok, isFalse);
      expect(bingReport.error, '超时');
      expect(
        response.reports
            .firstWhere((r) => r.provider == WebSearchProvider.duckduckgo)
            .ok,
        isTrue,
      );
    });

    test('并发数不超过 concurrency', () async {
      var active = 0;
      var maxActive = 0;

      void onStart() {
        active++;
        if (active > maxActive) maxActive = active;
      }

      void onEnd() {
        active--;
      }

      webSearchProviders
        ..[WebSearchProvider.bingRss] = _FakeProvider(
          WebSearchProvider.bingRss,
          delay: const Duration(milliseconds: 60),
          results: const [
            WebSearchResult(title: '1', url: 'https://example.com/1'),
          ],
          onStart: onStart,
          onEnd: onEnd,
        )
        ..[WebSearchProvider.duckduckgo] = _FakeProvider(
          WebSearchProvider.duckduckgo,
          delay: const Duration(milliseconds: 60),
          results: const [
            WebSearchResult(title: '2', url: 'https://example.com/2'),
          ],
          onStart: onStart,
          onEnd: onEnd,
        )
        ..[WebSearchProvider.brave] = _FakeProvider(
          WebSearchProvider.brave,
          delay: const Duration(milliseconds: 60),
          results: const [
            WebSearchResult(title: '3', url: 'https://example.com/3'),
          ],
          onStart: onStart,
          onEnd: onEnd,
        );

      final response = await WebSearchService.instance.search(
        'flutter',
        configOverride: const WebSearchConfig(
          enabledBackends: [
            WebSearchProvider.bingRss,
            WebSearchProvider.duckduckgo,
            WebSearchProvider.brave,
          ],
          concurrency: 2,
          backendTimeoutMs: 5000,
        ),
        apiKeyOverrides: const {WebSearchProvider.brave: 'key'},
      );

      expect(response.results, hasLength(3));
      expect(maxActive, lessThanOrEqualTo(2));
      expect(maxActive, greaterThanOrEqualTo(1));
    });

    test('缺少 API Key 的后端不发起请求', () async {
      var called = false;
      webSearchProviders[WebSearchProvider.brave] = _FakeProvider(
        WebSearchProvider.brave,
        results: const [],
        onStart: () => called = true,
      );

      await expectLater(
        WebSearchService.instance.search(
          'flutter',
          configOverride: const WebSearchConfig(
            enabledBackends: [WebSearchProvider.brave],
            backendTimeoutMs: 5000,
          ),
          apiKeyOverrides: const {WebSearchProvider.brave: ''},
        ),
        throwsA(
          isA<WebSearchQuotaError>().having(
            (e) => e.message,
            'message',
            contains('未配置 API Key'),
          ),
        ),
      );
      expect(called, isFalse);
    });
  });
}

class _FakeProvider implements WebSearchProviderApi {
  _FakeProvider(
    this.type, {
    this.delay = Duration.zero,
    this.results = const [],
    this.error,
    this.onStart,
    this.onEnd,
  });

  @override
  final WebSearchProvider type;
  final Duration delay;
  final List<WebSearchResult> results;
  final Object? error;
  final void Function()? onStart;
  final void Function()? onEnd;

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
    onStart?.call();
    try {
      if (delay > Duration.zero) {
        final delayed = Future<void>.delayed(delay);
        if (cancelToken == null) {
          await delayed;
        } else {
          final cancelled = cancelToken.whenCancel.then<void>(
            (_) {},
            onError: (_) {},
          );
          await Future.any([delayed, cancelled]);
        }
      }
      if (cancelToken?.isCancelled == true) {
        throw const WebSearchCancelledError('cancelled');
      }
      if (error != null) throw error!;
      return results;
    } finally {
      onEnd?.call();
    }
  }
}
