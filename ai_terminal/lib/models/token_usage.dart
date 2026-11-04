/// 模型一次调用返回的真实 token 用量（来自响应里的 `usage` 对象）。
///
/// 字段可空是刻意的：各家 provider 给的程度差别很大，「没给」必须与「给了 0」
/// 区分开。缓存命中尤其如此——缺失时 UI 整项不渲染；显示 0% 会被读成
/// 「这个模型没有提示缓存」，那是错的结论。
class TokenUsage {
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  /// 提示缓存命中数（`usage.prompt_tokens_details.cached_tokens`）。
  /// 自建与多数国产模型不提供。
  final int? cachedTokens;

  const TokenUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.cachedTokens,
  });

  /// 至少有一个真实数字才值得上报；全空说明这个 provider 没给
  bool get hasAny =>
      promptTokens != null || completionTokens != null || totalTokens != null;

  /// 解析 OpenAI 兼容的 usage 对象。结构不符或没有任何数字时返回 null。
  static TokenUsage? tryParse(Object? usage) {
    if (usage is! Map) return null;
    final details = usage['prompt_tokens_details'];
    final parsed = TokenUsage(
      promptTokens: _asInt(usage['prompt_tokens']),
      completionTokens: _asInt(usage['completion_tokens']),
      totalTokens: _asInt(usage['total_tokens']),
      cachedTokens: details is Map ? _asInt(details['cached_tokens']) : null,
    );
    return parsed.hasAny ? parsed : null;
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }
}

/// 紧凑显示 token 数：1280 → `1.3k`，2400000 → `2.4M`。
///
/// 指标带在右侧窄面板里放不下 7 位数，而 `165M tok` 这种写法正是参照 UI 的形态。
String formatTokenCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${_oneDecimal(n / 1000)}k';
  return '${_oneDecimal(n / 1000000)}M';
}

String _oneDecimal(double v) {
  final rounded = (v * 10).roundToDouble() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.round().toString()
      : rounded.toString();
}
