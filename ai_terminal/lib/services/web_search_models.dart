import 'web_search_config.dart';

/// 一条搜索结果
class WebSearchResult {
  final String title;
  final String url;
  final String snippet;

  /// 命中该结果的后端（合并后可能多个）
  final List<WebSearchProvider> sources;

  /// 在各后端中的最好排名（0-based）
  final int bestRank;

  const WebSearchResult({
    required this.title,
    required this.url,
    this.snippet = '',
    this.sources = const [],
    this.bestRank = 0,
  });

  /// 序列化为多行文本（供 AI 阅读）
  String toDisplayString(int index) {
    final sb = StringBuffer();
    sb.writeln('[${index + 1}] ${title.isEmpty ? "(无标题)" : title}');
    sb.writeln('    URL: $url');
    if (snippet.isNotEmpty) {
      sb.writeln('    摘要: $snippet');
    }
    if (sources.length > 1) {
      sb.writeln('    来源: ${sources.map((p) => p.displayName).join(' / ')}');
    }
    return sb.toString().trimRight();
  }
}

/// 单个后端的原始结果批次
class WebSearchBatch {
  final WebSearchProvider provider;
  final List<WebSearchResult> results;

  const WebSearchBatch({required this.provider, required this.results});
}

/// 单个后端的执行报告
class WebSearchBackendReport {
  final WebSearchProvider provider;
  final bool ok;
  final int resultCount;
  final int elapsedMs;
  final String? error;
  final bool permanent;

  const WebSearchBackendReport({
    required this.provider,
    required this.ok,
    required this.resultCount,
    required this.elapsedMs,
    this.error,
    this.permanent = false,
  });

  String get summary =>
      ok ? '$resultCount 条 · ${elapsedMs}ms' : (error ?? '失败');
}

/// 聚合搜索返回
class WebSearchResponse {
  final List<WebSearchResult> results;
  final List<WebSearchBackendReport> reports;

  const WebSearchResponse({required this.results, required this.reports});

  int get successCount => reports.where((r) => r.ok).length;
  int get failureCount => reports.length - successCount;
  List<WebSearchBackendReport> get failures =>
      reports.where((r) => !r.ok).toList();
}

/// 不可恢复的搜索错误（配额耗尽、Key 失效等）
class WebSearchQuotaError implements Exception {
  final String message;
  final WebSearchProvider provider;
  final bool permanent;

  const WebSearchQuotaError(
    this.message, {
    required this.provider,
    this.permanent = false,
  });

  @override
  String toString() => message;
}

/// 可重试的瞬时错误（网络、服务端 5xx、超时等）
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
