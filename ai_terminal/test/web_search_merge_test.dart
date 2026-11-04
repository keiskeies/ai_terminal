import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/web_search_config.dart';
import 'package:ai_terminal/services/web_search_merge.dart';
import 'package:ai_terminal/services/web_search_models.dart';

void main() {
  group('normalizeSearchUrl', () {
    test('忽略协议、www、默认端口、尾斜杠和 fragment', () {
      expect(
        normalizeSearchUrl('HTTPS://www.Example.com:443/docs/?utm_source=x#top'),
        'example.com/docs',
      );
      expect(
        normalizeSearchUrl('http://example.com:80/docs'),
        'example.com/docs',
      );
      expect(
        normalizeSearchUrl('http://example.com:8080/a/'),
        'example.com:8080/a',
      );
    });

    test('删除跟踪参数并按 key 排序', () {
      expect(
        normalizeSearchUrl(
          'https://example.com/search?b=2&utm_medium=email&a=1&fbclid=xyz',
        ),
        'example.com/search?a=1&b=2',
      );
    });

    test('保留非跟踪 query', () {
      expect(
        normalizeSearchUrl('https://example.com/p?id=42&lang=zh'),
        'example.com/p?id=42&lang=zh',
      );
    });

    test('空 URL 返回空串', () {
      expect(normalizeSearchUrl('   '), '');
    });
  });

  group('mergeSearchResults', () {
    test('跨后端同 URL 去重并合并来源与更长摘要', () {
      final merged = mergeSearchResults(
        [
          const WebSearchBatch(
            provider: WebSearchProvider.bingRss,
            results: [
              WebSearchResult(
                title: 'Example A',
                url: 'https://example.com/a?utm_source=bing',
                snippet: 'short',
              ),
              WebSearchResult(
                title: 'Example B',
                url: 'https://example.com/b',
                snippet: 'b',
              ),
            ],
          ),
          const WebSearchBatch(
            provider: WebSearchProvider.brave,
            results: [
              WebSearchResult(
                title: 'Example A (Brave)',
                url: 'http://www.example.com/a/',
                snippet: 'a much longer snippet',
              ),
              WebSearchResult(
                title: 'Example C',
                url: 'https://example.com/c',
                snippet: 'c',
              ),
            ],
          ),
        ],
        limit: 10,
      );

      expect(merged, hasLength(3));
      expect(merged.first.url, 'https://example.com/a?utm_source=bing');
      expect(merged.first.title, 'Example A');
      expect(merged.first.snippet, 'a much longer snippet');
      expect(
        merged.first.sources,
        [WebSearchProvider.bingRss, WebSearchProvider.brave],
      );
      expect(merged[1].url, 'https://example.com/b');
      expect(merged[2].url, 'https://example.com/c');
    });

    test('多后端共同命中的结果排在最前', () {
      final merged = mergeSearchResults(
        [
          const WebSearchBatch(
            provider: WebSearchProvider.bingRss,
            results: [
              WebSearchResult(title: 'single', url: 'https://example.com/1'),
              WebSearchResult(title: 'shared', url: 'https://example.com/shared'),
            ],
          ),
          const WebSearchBatch(
            provider: WebSearchProvider.brave,
            results: [
              WebSearchResult(title: 'shared 2', url: 'https://example.com/shared/'),
            ],
          ),
        ],
        limit: 10,
      );

      expect(merged.first.url, 'https://example.com/shared');
      expect(merged.first.sources, hasLength(2));
      expect(merged[1].url, 'https://example.com/1');
    });

    test('limit 截断且无标题时回落到域名', () {
      final merged = mergeSearchResults(
        [
          const WebSearchBatch(
            provider: WebSearchProvider.bingRss,
            results: [
              WebSearchResult(title: '', url: 'https://www.example.com/x'),
              WebSearchResult(title: 'two', url: 'https://example.com/2'),
            ],
          ),
        ],
        limit: 1,
      );

      expect(merged, hasLength(1));
      expect(merged.first.title, 'example.com');
    });

    test('limit <= 0 返回空列表', () {
      expect(
        mergeSearchResults(
          [
            const WebSearchBatch(
              provider: WebSearchProvider.bingRss,
              results: [
                WebSearchResult(title: 'x', url: 'https://example.com'),
              ],
            ),
          ],
          limit: 0,
        ),
        isEmpty,
      );
    });
  });
}
