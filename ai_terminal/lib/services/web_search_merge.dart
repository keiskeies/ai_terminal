import 'web_search_config.dart';
import 'web_search_models.dart';

/// 跨后端合并结果
///
/// 去重键是规范化后的 URL（忽略 http/https、www.、跟踪参数、query 顺序）；
/// 同一 URL 合并标题/摘要并记录来源。排序：命中后端数降序 → 最好排名升序 →
/// 首次出现顺序。最终截断到 [limit]。
List<WebSearchResult> mergeSearchResults(
  List<WebSearchBatch> batches, {
  required int limit,
}) {
  if (limit <= 0) return const [];
  final merged = <String, _MergedResult>{};
  var sequence = 0;

  for (final batch in batches) {
    for (var rank = 0; rank < batch.results.length; rank++) {
      final raw = batch.results[rank];
      final key = normalizeSearchUrl(raw.url);
      if (key.isEmpty) continue;
      final existing = merged[key];
      if (existing == null) {
        merged[key] = _MergedResult(
          title: raw.title.trim(),
          url: raw.url,
          snippet: _truncate(raw.snippet.trim(), 400),
          sources: {batch.provider},
          bestRank: rank,
          firstSeen: sequence++,
        );
        continue;
      }
      if (existing.title.isEmpty && raw.title.trim().isNotEmpty) {
        existing.title = raw.title.trim();
      }
      final snippet = _truncate(raw.snippet.trim(), 400);
      if (snippet.length > existing.snippet.length) {
        existing.snippet = snippet;
      }
      existing.sources.add(batch.provider);
      if (rank < existing.bestRank) existing.bestRank = rank;
    }
  }

  final ordered = merged.values.toList()
    ..sort((a, b) {
      final bySources = b.sources.length.compareTo(a.sources.length);
      if (bySources != 0) return bySources;
      final byRank = a.bestRank.compareTo(b.bestRank);
      if (byRank != 0) return byRank;
      return a.firstSeen.compareTo(b.firstSeen);
    });

  return ordered
      .take(limit.clamp(1, 20))
      .map((m) => WebSearchResult(
            title: m.title.isEmpty ? _titleFromUrl(m.url) : m.title,
            url: m.url,
            snippet: m.snippet,
            sources: List<WebSearchProvider>.unmodifiable(m.sources),
            bestRank: m.bestRank,
          ))
      .toList();
}

class _MergedResult {
  String title;
  final String url;
  String snippet;
  final Set<WebSearchProvider> sources;
  int bestRank;
  final int firstSeen;

  _MergedResult({
    required this.title,
    required this.url,
    required this.snippet,
    required this.sources,
    required this.bestRank,
    required this.firstSeen,
  });
}

const Set<String> _trackingParams = {
  'gclid',
  'fbclid',
  'msclkid',
  'yclid',
  'spm',
  'ref',
  'ref_src',
  'source',
  'igshid',
  'si',
  'srsltid',
  'mkt_tok',
  'trk',
  'trk_contact',
  'trk_module',
  'trk_sid',
  'mc_cid',
  'mc_eid',
  '_hsenc',
  '_hsmi',
  'vero_id',
  'wickedid',
  'oly_anon_id',
  'oly_enc_id',
  '__s',
  'rb_clickid',
  's_cid',
  'elqtrackid',
  'elqtrack',
};

const List<String> _trackingPrefixes = ['utm_', 'hsa_', 'pk_', 'mtm_'];

/// URL 规范化：仅用于去重比较，不用于展示或请求
String normalizeSearchUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return trimmed.toLowerCase();

  final scheme = uri.scheme.toLowerCase();
  if (scheme.isNotEmpty && scheme != 'http' && scheme != 'https') {
    return trimmed.toLowerCase();
  }

  var host = uri.host.toLowerCase();
  if (host.isEmpty) return trimmed.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);

  final isDefaultPort = (scheme == 'http' && uri.port == 80) ||
      (scheme == 'https' && uri.port == 443);
  final port = (uri.hasPort && !isDefaultPort) ? ':${uri.port}' : '';

  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }

  final params = <String, String>{};
  uri.queryParametersAll.forEach((key, values) {
    final lower = key.toLowerCase();
    if (_isTrackingParam(lower)) return;
    params[lower] = values.isEmpty ? '' : values.first;
  });
  final keys = params.keys.toList()..sort();
  final query = Uri(queryParameters: {
    for (final key in keys) key: params[key]!,
  }).query;

  return '$host$port$path${query.isEmpty ? '' : '?$query'}';
}

bool _isTrackingParam(String key) {
  if (_trackingParams.contains(key)) return true;
  for (final prefix in _trackingPrefixes) {
    if (key.startsWith(prefix)) return true;
  }
  return false;
}

String _titleFromUrl(String url) {
  final uri = Uri.tryParse(url);
  var host = uri?.host ?? '';
  if (host.startsWith('www.')) host = host.substring(4);
  return host.isEmpty ? url : host;
}

String _truncate(String input, int max) {
  if (input.length <= max) return input;
  var end = max;
  if (end > 0) {
    final last = input.codeUnitAt(end - 1);
    // 避免截断 UTF-16 代理对
    if (last >= 0xD800 && last <= 0xDBFF) end--;
  }
  return '${input.substring(0, end)}…';
}
