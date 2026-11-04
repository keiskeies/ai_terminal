import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import '../core/credentials_store.dart';
import 'daos.dart';

/// 联网搜索后端
///
/// 12 个后端与设置页一一对应。DeepSeek 没有公开网页搜索 API，仅作为占位行
/// （[isAvailable] = false），不会参与 fan-out。
///
/// 认证：Exa / Parallel / Brave / Tavily / Serper / Mojeek / OpenAI / Anthropic
/// 需要 API Key；Bing RSS / DuckDuckGo / SearXNG 免 Key（SearXNG 支持可选 Token）。
enum WebSearchProvider {
  exa,
  parallel,
  bingRss,
  duckduckgo,
  searxng,
  brave,
  tavily,
  serper,
  mojeek,
  deepseek,
  anthropic,
  openai;

  /// 宽松解析（兼容旧配置 / 手写 JSON）；未知值返回 null
  static WebSearchProvider? tryFromString(String? s) {
    switch ((s ?? '').trim().toLowerCase()) {
      case 'exa':
        return WebSearchProvider.exa;
      case 'parallel':
        return WebSearchProvider.parallel;
      case 'bingrss':
      case 'bing_rss':
      // 旧版 HTML 抓取统一迁移到更稳定的 RSS 输出
      case 'binghtml':
      case 'bing_html':
        return WebSearchProvider.bingRss;
      case 'duckduckgo':
      case 'ddg':
        return WebSearchProvider.duckduckgo;
      case 'searxng':
        return WebSearchProvider.searxng;
      case 'brave':
        return WebSearchProvider.brave;
      case 'tavily':
        return WebSearchProvider.tavily;
      case 'serper':
      case 'serperdev':
      case 'serper_dev':
        return WebSearchProvider.serper;
      case 'mojeek':
        return WebSearchProvider.mojeek;
      case 'deepseek':
        return WebSearchProvider.deepseek;
      case 'anthropic':
      case 'claude':
        return WebSearchProvider.anthropic;
      case 'openai':
        return WebSearchProvider.openai;
      default:
        return null;
    }
  }

  static WebSearchProvider fromString(String? s) =>
      tryFromString(s) ?? WebSearchProvider.bingRss;

  /// 是否可参与搜索
  bool get isAvailable => this != WebSearchProvider.deepseek;

  /// 是否必须配置 API Key（SearXNG 的 Token 是可选的，不计入）
  bool get requiresApiKey {
    switch (this) {
      case WebSearchProvider.exa:
      case WebSearchProvider.parallel:
      case WebSearchProvider.brave:
      case WebSearchProvider.tavily:
      case WebSearchProvider.serper:
      case WebSearchProvider.mojeek:
      case WebSearchProvider.anthropic:
      case WebSearchProvider.openai:
        return true;
      case WebSearchProvider.bingRss:
      case WebSearchProvider.duckduckgo:
      case WebSearchProvider.searxng:
      case WebSearchProvider.deepseek:
        return false;
    }
  }

  /// 该后端的 Key/Token 环境变量名；为空表示完全免密钥
  String get envKeyName {
    switch (this) {
      case WebSearchProvider.exa:
        return 'EXA_API_KEY';
      case WebSearchProvider.parallel:
        return 'PARALLEL_API_KEY';
      case WebSearchProvider.brave:
        return 'BRAVE_API_KEY';
      case WebSearchProvider.tavily:
        return 'TAVILY_API_KEY';
      case WebSearchProvider.serper:
        return 'SERPER_API_KEY';
      case WebSearchProvider.mojeek:
        return 'MOJEEK_API_KEY';
      case WebSearchProvider.anthropic:
        return 'ANTHROPIC_API_KEY';
      case WebSearchProvider.openai:
        return 'OPENAI_API_KEY';
      case WebSearchProvider.searxng:
        return 'SEARXNG_API_KEY';
      case WebSearchProvider.bingRss:
      case WebSearchProvider.duckduckgo:
      case WebSearchProvider.deepseek:
        return '';
    }
  }

  /// SearXNG 实例地址是必填项
  bool get requiresInstanceUrl => this == WebSearchProvider.searxng;

  String get displayName {
    switch (this) {
      case WebSearchProvider.exa:
        return 'Exa';
      case WebSearchProvider.parallel:
        return 'Parallel';
      case WebSearchProvider.bingRss:
        return 'Bing RSS';
      case WebSearchProvider.duckduckgo:
        return 'DuckDuckGo';
      case WebSearchProvider.searxng:
        return 'SearXNG';
      case WebSearchProvider.brave:
        return 'Brave';
      case WebSearchProvider.tavily:
        return 'Tavily';
      case WebSearchProvider.serper:
        return 'Serper.dev';
      case WebSearchProvider.mojeek:
        return 'Mojeek';
      case WebSearchProvider.deepseek:
        return 'DeepSeek';
      case WebSearchProvider.anthropic:
        return 'Anthropic';
      case WebSearchProvider.openai:
        return 'OpenAI';
    }
  }

  /// 设置页行内说明（如实描述能力与限制）
  String get tagline {
    switch (this) {
      case WebSearchProvider.exa:
        return '语义搜索 · 需 Key';
      case WebSearchProvider.parallel:
        return '搜索 API · 需 Key';
      case WebSearchProvider.bingRss:
        return 'RSS · 免密钥';
      case WebSearchProvider.duckduckgo:
        return 'HTML · 国内需代理';
      case WebSearchProvider.searxng:
        return '需自建实例';
      case WebSearchProvider.brave:
        return '独立索引';
      case WebSearchProvider.tavily:
        return 'AI 优化摘要';
      case WebSearchProvider.serper:
        return 'Google 结果';
      case WebSearchProvider.mojeek:
        return '独立索引';
      case WebSearchProvider.deepseek:
        return '暂无搜索 API';
      case WebSearchProvider.anthropic:
        return 'Claude 搜索工具';
      case WebSearchProvider.openai:
        return 'Responses 搜索';
    }
  }

  String get signupUrl {
    switch (this) {
      case WebSearchProvider.exa:
        return 'https://dashboard.exa.ai/api-keys';
      case WebSearchProvider.parallel:
        return 'https://platform.parallel.ai';
      case WebSearchProvider.brave:
        return 'https://brave.com/search/api/';
      case WebSearchProvider.tavily:
        return 'https://app.tavily.com';
      case WebSearchProvider.serper:
        return 'https://serper.dev';
      case WebSearchProvider.mojeek:
        return 'https://www.mojeek.com/services/search/web-search-api/';
      case WebSearchProvider.anthropic:
        return 'https://console.anthropic.com/settings/keys';
      case WebSearchProvider.openai:
        return 'https://platform.openai.com/api-keys';
      case WebSearchProvider.searxng:
        return 'https://docs.searxng.org/admin/installation.html';
      case WebSearchProvider.deepseek:
        return 'https://api-docs.deepseek.com';
      case WebSearchProvider.bingRss:
      case WebSearchProvider.duckduckgo:
        return '';
    }
  }

  /// LLM 型后端的默认模型（设置页不暴露，后续需要再加）
  String get defaultModel {
    switch (this) {
      case WebSearchProvider.anthropic:
        return 'claude-sonnet-4-5';
      case WebSearchProvider.openai:
        return 'gpt-4.1-mini';
      default:
        return '';
    }
  }
}

/// API Key 配置状态
class WebSearchApiKeyStatus {
  final bool fromStore;
  final bool fromEnv;

  const WebSearchApiKeyStatus({this.fromStore = false, this.fromEnv = false});

  bool get configured => fromStore || fromEnv;
  bool get clearable => fromStore;
}

/// 联网搜索全局配置
///
/// 持久化分两层：
/// - 非敏感字段（开关、后端列表、参数、代理）存 [SettingsDao]（SQLite 全库加密）
/// - API Key 走 [CredentialsStore]（R7），环境变量只读兜底
class WebSearchConfig {
  /// 总开关（会话级开关可覆盖）
  final bool enabled;

  /// 参与 fan-out 的后端（顺序即设置页展示顺序）
  final List<WebSearchProvider> enabledBackends;

  /// 最终返回的结果条数
  final int numResults;

  /// 同时请求的后端数
  final int concurrency;

  /// 单个后端的最长等待时间
  final int backendTimeoutMs;

  /// 出站 HTTP 代理（仅搜索后端与 fetch_url 使用）
  final String proxy;

  /// SearXNG 自建实例 URL
  final String searxngInstanceUrl;

  const WebSearchConfig({
    this.enabled = false,
    // 默认只开 Bing RSS：免 Key、国内可直连。开总开关即可用。
    this.enabledBackends = const [WebSearchProvider.bingRss],
    this.numResults = 8,
    this.concurrency = 6,
    this.backendTimeoutMs = 30000,
    this.proxy = '',
    this.searxngInstanceUrl = '',
  });

  Duration get backendTimeout => Duration(milliseconds: backendTimeoutMs);

  bool get hasUsableBackends =>
      enabledBackends.any((p) => p.isAvailable);

  int get enabledCount => enabledBackends.where((p) => p.isAvailable).length;

  WebSearchConfig copyWith({
    bool? enabled,
    List<WebSearchProvider>? enabledBackends,
    int? numResults,
    int? concurrency,
    int? backendTimeoutMs,
    String? proxy,
    String? searxngInstanceUrl,
  }) {
    return WebSearchConfig(
      enabled: enabled ?? this.enabled,
      enabledBackends: enabledBackends ?? this.enabledBackends,
      numResults: numResults ?? this.numResults,
      concurrency: concurrency ?? this.concurrency,
      backendTimeoutMs: backendTimeoutMs ?? this.backendTimeoutMs,
      proxy: proxy ?? this.proxy,
      searxngInstanceUrl: searxngInstanceUrl ?? this.searxngInstanceUrl,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 2,
        'enabled': enabled,
        'enabledBackends': enabledBackends.map((p) => p.name).toList(),
        'numResults': numResults,
        'concurrency': concurrency,
        'backendTimeoutMs': backendTimeoutMs,
        'proxy': proxy,
        'searxngInstanceUrl': searxngInstanceUrl,
      };

  factory WebSearchConfig.fromJson(Map<String, dynamic> json) {
    final hasBackendList = json['enabledBackends'] is List;
    final backends = <WebSearchProvider>[];
    if (hasBackendList) {
      for (final raw in json['enabledBackends'] as List) {
        final p = WebSearchProvider.tryFromString(raw?.toString());
        if (p != null && p.isAvailable && !backends.contains(p)) {
          backends.add(p);
        }
      }
    } else {
      // 旧版单 provider 配置迁移；bing(Azure)/serpapi 已下线，回落到免费 Bing RSS
      final legacy =
          WebSearchProvider.tryFromString(json['provider']?.toString());
      if (legacy != null && legacy.isAvailable) backends.add(legacy);
      if (backends.isEmpty) backends.add(WebSearchProvider.bingRss);
    }

    final legacyTimeoutSeconds = json['timeoutSeconds'];
    final timeoutMs = json['backendTimeoutMs'] != null
        ? _readInt(json['backendTimeoutMs'], 30000, 3000, 120000)
        : (legacyTimeoutSeconds != null
            ? _readInt(legacyTimeoutSeconds, 15, 3, 120) * 1000
            : 30000);

    return WebSearchConfig(
      enabled: json['enabled'] == true,
      enabledBackends: backends,
      numResults: _readInt(json['numResults'] ?? json['maxResults'], 8, 1, 20),
      concurrency: _readInt(json['concurrency'], 6, 1, 12),
      backendTimeoutMs: timeoutMs,
      proxy: (json['proxy'] as String? ?? '').trim(),
      searxngInstanceUrl:
          (json['searxngInstanceUrl'] as String? ?? '').trim(),
    );
  }

  static int _readInt(dynamic raw, int fallback, int min, int max) {
    final value =
        raw is int ? raw : int.tryParse(raw?.toString() ?? '') ?? fallback;
    return value.clamp(min, max);
  }

  static const String _settingsKey = 'webSearchConfig';
  static const String _credHostId = '__web_search__';
  static const String _credTypePrefix = 'apiKey_';

  /// 从持久化加载配置（同步：SettingsDao 缓存）
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

  Future<void> save() async {
    await SettingsDao.set(_settingsKey, jsonEncode(toJson()));
  }

  /// 读取指定后端的 API Key：凭据库优先，环境变量兜底
  static Future<String?> getApiKey(WebSearchProvider provider) async {
    if (provider.envKeyName.isEmpty) return null;
    final stored = await _readStored(provider);
    if (stored != null) return stored;
    return _readEnv(provider);
  }

  /// UI 展示用的 Key 状态（区分凭据库 / 环境变量）
  static Future<WebSearchApiKeyStatus> apiKeyStatus(
    WebSearchProvider provider,
  ) async {
    if (provider.envKeyName.isEmpty) {
      return const WebSearchApiKeyStatus();
    }
    final stored = await _readStored(provider);
    if (stored != null) {
      return const WebSearchApiKeyStatus(fromStore: true);
    }
    return WebSearchApiKeyStatus(fromEnv: _readEnv(provider) != null);
  }

  static Future<String?> _readStored(WebSearchProvider provider) async {
    try {
      final value = await CredentialsStore.get(
        hostId: _credHostId,
        type: '$_credTypePrefix${provider.name}',
      );
      final trimmed = value?.trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    } catch (e) {
      debugPrint('[WebSearchConfig] 读取 apiKey 失败 (${provider.name}): $e');
      return null;
    }
  }

  static String? _readEnv(WebSearchProvider provider) {
    final name = provider.envKeyName;
    if (name.isEmpty) return null;
    try {
      final value = Platform.environment[name]?.trim();
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> saveApiKey(
    WebSearchProvider provider,
    String apiKey,
  ) async {
    if (provider.envKeyName.isEmpty) return true;
    return CredentialsStore.save(
      hostId: _credHostId,
      type: '$_credTypePrefix${provider.name}',
      value: apiKey,
    );
  }

  static Future<void> deleteApiKey(WebSearchProvider provider) async {
    if (provider.envKeyName.isEmpty) return;
    await CredentialsStore.delete(
      hostId: _credHostId,
      type: '$_credTypePrefix${provider.name}',
    );
  }
}
