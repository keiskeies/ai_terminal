import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/credentials_store.dart';
import 'daos.dart';

/// 联网搜索 API 提供商
///
/// 各 provider 的差异：
/// - [tavily]：专为 AI agent 设计，返回结构化摘要，免费 1000 次/月
/// - [bing]：Azure 官方，结果丰富稳定，需 Azure 订阅
/// - [bingHtml]：直接抓取 bing.com 搜索结果页 HTML 解析，完全免费无 key（推荐零成本场景）
/// - [brave]：Brave Search API，独立索引，免费 2000 次/月（需注册）
/// - [searxng]：开源元搜索引擎，聚合 70+ 搜索引擎结果。需自建实例（公共实例有反爬）
/// - [serpapi]：聚合 Google/Bing 等多家，免费 100 次/月
/// - [duckduckgo]：免 API key，非官方接口、速率低、结果质量一般
enum WebSearchProvider {
  tavily,
  bing,
  bingHtml,
  brave,
  searxng,
  serpapi,
  duckduckgo;

  static WebSearchProvider fromString(String? s) {
    switch (s) {
      case 'tavily':
        return WebSearchProvider.tavily;
      case 'bing':
        return WebSearchProvider.bing;
      case 'bing_html':
        return WebSearchProvider.bingHtml;
      case 'brave':
        return WebSearchProvider.brave;
      case 'searxng':
        return WebSearchProvider.searxng;
      case 'serpapi':
        return WebSearchProvider.serpapi;
      case 'duckduckgo':
        return WebSearchProvider.duckduckgo;
      default:
        // 未知值/首次安装：用免费的 bing_html
        return WebSearchProvider.bingHtml;
    }
  }

  /// 该 provider 是否需要 API key
  ///
  /// - [duckduckgo] / [bingHtml]：完全免 key
  /// - [searxng]：不需要 API key，但需要 instanceUrl（自建实例地址）
  /// - 其他：需要 API key
  bool get requiresApiKey =>
      this != WebSearchProvider.duckduckgo &&
      this != WebSearchProvider.bingHtml &&
      this != WebSearchProvider.searxng;

  /// 该 provider 是否需要 instanceUrl（仅 searxng）
  bool get requiresInstanceUrl => this == WebSearchProvider.searxng;

  /// 显示名
  String get displayName {
    switch (this) {
      case WebSearchProvider.tavily:
        return 'Tavily';
      case WebSearchProvider.bing:
        return 'Bing Search (Azure API)';
      case WebSearchProvider.bingHtml:
        return 'Bing 网页 (免 key 推荐)';
      case WebSearchProvider.brave:
        return 'Brave Search (免费 2000/月)';
      case WebSearchProvider.searxng:
        return 'SearXNG (自建实例)';
      case WebSearchProvider.serpapi:
        return 'SerpAPI';
      case WebSearchProvider.duckduckgo:
        return 'DuckDuckGo (免 key)';
    }
  }

  /// 申请 API key 的入口
  String get signupUrl {
    switch (this) {
      case WebSearchProvider.tavily:
        return 'https://tavily.com';
      case WebSearchProvider.bing:
        return 'https://www.microsoft.com/bing/apis/bing-web-search-api';
      case WebSearchProvider.bingHtml:
        return '';
      case WebSearchProvider.brave:
        return 'https://brave.com/search/api/';
      case WebSearchProvider.searxng:
        return 'https://docs.searxng.org/admin/installation.html';
      case WebSearchProvider.serpapi:
        return 'https://serpapi.com';
      case WebSearchProvider.duckduckgo:
        return '';
    }
  }
}

/// 联网搜索全局配置
///
/// 持久化分两层：
/// - 非敏感字段（enabled / provider / maxResults / timeoutSeconds）存 [SettingsDao]
/// - API key 走 [CredentialsStore]（R7：敏感数据必须经 secure_storage，AES 加密 SQLite 兜底）
///
/// 会话级开关（覆盖此处的 enabled）不在此类，存在 AgentState.isWebSearchEnabled。
class WebSearchConfig {
  /// 全局开关（会话级开关可覆盖）
  final bool enabled;

  /// 当前选择的 provider
  final WebSearchProvider provider;

  /// 单次搜索返回的最大结果数
  final int maxResults;

  /// 单次搜索请求超时（秒）
  final int timeoutSeconds;

  /// SearXNG 自建实例 URL（如 `http://localhost:8080`）
  ///
  /// 仅 [WebSearchProvider.searxng] 使用。公共实例有反爬，不预填默认值。
  /// 用户需自建后填入。存储在 SettingsDao（非敏感，且方便用户编辑）。
  final String searxngInstanceUrl;

  const WebSearchConfig({
    this.enabled = false,
    // 默认 bing_html：开箱即用、零成本（无 key、无配额限制）
    // 已有配置的用户从持久化读取，不会被此默认值覆盖
    this.provider = WebSearchProvider.bingHtml,
    this.maxResults = 5,
    this.timeoutSeconds = 15,
    this.searxngInstanceUrl = '',
  });

  WebSearchConfig copyWith({
    bool? enabled,
    WebSearchProvider? provider,
    int? maxResults,
    int? timeoutSeconds,
    String? searxngInstanceUrl,
  }) {
    return WebSearchConfig(
      enabled: enabled ?? this.enabled,
      provider: provider ?? this.provider,
      maxResults: maxResults ?? this.maxResults,
      timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      searxngInstanceUrl: searxngInstanceUrl ?? this.searxngInstanceUrl,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'provider': provider.name,
        'maxResults': maxResults,
        'timeoutSeconds': timeoutSeconds,
        'searxngInstanceUrl': searxngInstanceUrl,
      };

  factory WebSearchConfig.fromJson(Map<String, dynamic> json) {
    return WebSearchConfig(
      enabled: json['enabled'] == true,
      provider: WebSearchProvider.fromString(json['provider'] as String?),
      maxResults: json['maxResults'] is int
          ? json['maxResults'] as int
          : int.tryParse(json['maxResults']?.toString() ?? '') ?? 5,
      timeoutSeconds: json['timeoutSeconds'] is int
          ? json['timeoutSeconds'] as int
          : int.tryParse(json['timeoutSeconds']?.toString() ?? '') ?? 15,
      searxngInstanceUrl: json['searxngInstanceUrl'] as String? ?? '',
    );
  }

  static const String _settingsKey = 'webSearchConfig';
  static const String _credHostId = '__web_search__';
  static const String _credTypePrefix = 'apiKey_';

  /// 从持久化加载配置
  ///
  /// 顺序：SettingsDao 缓存（同步）→ 兜底默认值。
  /// API key 不在此处加载（仅在 [WebSearchService] 调用时按需读取，避免明文常驻内存）。
  static WebSearchConfig load() {
    final raw = SettingsDao.getCached(_settingsKey);
    if (raw == null) return const WebSearchConfig();
    try {
      if (raw is String) {
        return WebSearchConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
      if (raw is Map) {
        return WebSearchConfig.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (e) {
      debugPrint('[WebSearchConfig] 加载失败: $e');
    }
    return const WebSearchConfig();
  }

  /// 持久化非敏感字段
  Future<void> save() async {
    await SettingsDao.set(_settingsKey, jsonEncode(toJson()));
  }

  /// 读取指定 provider 的 API key（从 CredentialsStore）
  static Future<String?> getApiKey(WebSearchProvider provider) async {
    if (!provider.requiresApiKey) return null;
    try {
      return await CredentialsStore.get(
        hostId: _credHostId,
        type: '$_credTypePrefix${provider.name}',
      );
    } catch (e) {
      debugPrint('[WebSearchConfig] 读取 apiKey 失败 (${provider.name}): $e');
      return null;
    }
  }

  /// 保存指定 provider 的 API key
  static Future<bool> saveApiKey(WebSearchProvider provider, String apiKey) async {
    if (!provider.requiresApiKey) return true;
    return CredentialsStore.save(
      hostId: _credHostId,
      type: '$_credTypePrefix${provider.name}',
      value: apiKey,
    );
  }

  /// 删除指定 provider 的 API key
  static Future<void> deleteApiKey(WebSearchProvider provider) async {
    if (!provider.requiresApiKey) return;
    await CredentialsStore.delete(
      hostId: _credHostId,
      type: '$_credTypePrefix${provider.name}',
    );
  }
}
