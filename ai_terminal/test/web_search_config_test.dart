import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/web_search_config.dart';

void main() {
  group('WebSearchConfig 迁移', () {
    test('旧版单 provider 配置迁移到 enabledBackends', () {
      final config = WebSearchConfig.fromJson({
        'enabled': true,
        'provider': 'bing_html',
        'maxResults': 10,
        'timeoutSeconds': 25,
        'searxngInstanceUrl': ' http://127.0.0.1:8888 ',
      });

      expect(config.enabled, isTrue);
      expect(config.enabledBackends, [WebSearchProvider.bingRss]);
      expect(config.numResults, 10);
      expect(config.backendTimeoutMs, 25000);
      expect(config.searxngInstanceUrl, 'http://127.0.0.1:8888');
    });

    test('旧版 bing(Azure)/serpapi 回落到免费 Bing RSS', () {
      final bing = WebSearchConfig.fromJson({'provider': 'bing'});
      final serp = WebSearchConfig.fromJson({'provider': 'serpapi'});

      expect(bing.enabledBackends, [WebSearchProvider.bingRss]);
      expect(serp.enabledBackends, [WebSearchProvider.bingRss]);
    });

    test('新配置保留显式空后端列表', () {
      final config = WebSearchConfig.fromJson({
        'enabledBackends': <String>[],
      });

      expect(config.enabledBackends, isEmpty);
      expect(config.hasUsableBackends, isFalse);
    });

    test('过滤不可用后端、未知值和重复项', () {
      final config = WebSearchConfig.fromJson({
        'enabledBackends': [
          'deepseek',
          'brave',
          'unknown',
          'bing_rss',
          'brave',
        ],
      });

      expect(config.enabledBackends, [
        WebSearchProvider.brave,
        WebSearchProvider.bingRss,
      ]);
      expect(config.enabledCount, 2);
    });

    test('数值越界时 clamp', () {
      final config = WebSearchConfig.fromJson({
        'numResults': 99,
        'concurrency': 0,
        'backendTimeoutMs': 999999,
      });

      expect(config.numResults, 20);
      expect(config.concurrency, 1);
      expect(config.backendTimeoutMs, 120000);
    });

    test('toJson / fromJson 往返', () {
      const config = WebSearchConfig(
        enabled: true,
        enabledBackends: [
          WebSearchProvider.bingRss,
          WebSearchProvider.serper,
        ],
        numResults: 12,
        concurrency: 4,
        backendTimeoutMs: 15000,
        proxy: 'http://127.0.0.1:7890',
        searxngInstanceUrl: 'http://127.0.0.1:8888',
      );

      final restored = WebSearchConfig.fromJson(config.toJson());

      expect(restored.enabled, isTrue);
      expect(restored.enabledBackends, config.enabledBackends);
      expect(restored.numResults, 12);
      expect(restored.concurrency, 4);
      expect(restored.backendTimeoutMs, 15000);
      expect(restored.proxy, 'http://127.0.0.1:7890');
    });
  });

  group('后端元数据', () {
    test('12 个后端，8 个需要 Key，DeepSeek 不可用', () {
      expect(WebSearchProvider.values, hasLength(12));
      expect(
        WebSearchProvider.values.where((p) => p.requiresApiKey),
        hasLength(8),
      );
      expect(WebSearchProvider.deepseek.isAvailable, isFalse);
      expect(
        WebSearchProvider.values.where((p) => p.isAvailable),
        hasLength(11),
      );
    });

    test('免密钥后端没有环境变量名', () {
      for (final provider in [
        WebSearchProvider.bingRss,
        WebSearchProvider.duckduckgo,
      ]) {
        expect(provider.envKeyName, isEmpty);
        expect(provider.requiresApiKey, isFalse);
      }
    });

    test('SearXNG 需要实例地址且支持可选 Token', () {
      expect(WebSearchProvider.searxng.requiresInstanceUrl, isTrue);
      expect(WebSearchProvider.searxng.requiresApiKey, isFalse);
      expect(WebSearchProvider.searxng.envKeyName, 'SEARXNG_API_KEY');
    });
  });
}
