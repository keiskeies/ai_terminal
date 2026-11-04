import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'web_search_backends.dart';
import 'web_search_config.dart';
import 'web_search_merge.dart';
import 'web_search_models.dart';

export 'web_search_models.dart';

/// 联网搜索调度服务
///
/// 一次搜索并发 fan-out 到多个后端，合并去重后返回。工具层只调 [search]。
class WebSearchService {
  WebSearchService._();

  static final WebSearchService instance = WebSearchService._();

  WebSearchConfig get _config => WebSearchConfig.load();

  /// 是否应该注册联网工具：总开关打开且至少有一个可用后端
  bool get isEnabled {
    final config = _config;
    return config.enabled && config.hasUsableBackends;
  }

  /// 执行聚合搜索
  ///
  /// [maxResults] 覆盖全局 numResults；[configOverride] 供设置页用草稿测试；
  /// [apiKeyOverrides] 同样只用于测试（空字符串表示明确不使用 Key）。
  Future<WebSearchResponse> search(
    String query, {
    int? maxResults,
    CancelToken? dioCancelToken,
    WebSearchConfig? configOverride,
    Map<WebSearchProvider, String> apiKeyOverrides = const {},
  }) async {
    final config = configOverride ?? _config;
    final finalLimit = (maxResults != null && maxResults > 0)
        ? maxResults.clamp(1, 20)
        : config.numResults.clamp(1, 20);
    final backends = config.enabledBackends
        .where((p) => p.isAvailable)
        .toList(growable: false);
    if (backends.isEmpty) {
      throw const WebSearchTransientError(
        '未启用任何搜索后端。请在「设置 → 联网搜索」勾选至少一个后端。',
      );
    }

    final perBackendLimit = _perBackendLimit(finalLimit);
    final semaphore =
        _Semaphore(config.concurrency.clamp(1, 12));
    final reports = <WebSearchBackendReport>[];
    final batches = <WebSearchBatch>[];

    await Future.wait(backends.map((provider) async {
      if (dioCancelToken?.isCancelled == true) return;
      await semaphore.acquire();
      final stopwatch = Stopwatch()..start();
      var timedOut = false;
      var cancelled = false;
      final token = CancelToken();
      Timer? timer;
      try {
        final override = apiKeyOverrides[provider];
        final apiKey = (override != null
                ? override.trim()
                : await WebSearchConfig.getApiKey(provider)) ??
            '';

        if (provider.requiresApiKey && apiKey.isEmpty) {
          reports.add(WebSearchBackendReport(
            provider: provider,
            ok: false,
            resultCount: 0,
            elapsedMs: stopwatch.elapsedMilliseconds,
            error: '未配置 API Key',
            permanent: true,
          ));
          return;
        }
        if (provider.requiresInstanceUrl &&
            config.searxngInstanceUrl.trim().isEmpty) {
          reports.add(WebSearchBackendReport(
            provider: provider,
            ok: false,
            resultCount: 0,
            elapsedMs: stopwatch.elapsedMilliseconds,
            error: '未配置实例地址',
            permanent: true,
          ));
          return;
        }
        if (dioCancelToken?.isCancelled == true) {
          cancelled = true;
          return;
        }

        timer = Timer(config.backendTimeout, () {
          timedOut = true;
          if (!token.isCancelled) token.cancel('backend timeout');
        });
        if (dioCancelToken != null) {
          // R2: 父级取消要立即传导到子请求；whenCancel 完成于取消时
          dioCancelToken.whenCancel.then(
            (_) {
              if (!token.isCancelled) token.cancel('task cancelled');
            },
            onError: (_) {
              if (!token.isCancelled) token.cancel('task cancelled');
            },
          );
        }

        final results = await webSearchProviders[provider]!
            .search(
              query: query,
              maxResults: perBackendLimit,
              timeout: config.backendTimeout,
              apiKey: apiKey.isEmpty ? null : apiKey,
              instanceUrl:
                  provider.requiresInstanceUrl ? config.searxngInstanceUrl : null,
              proxy: config.proxy,
              cancelToken: token,
            )
            .timeout(
              config.backendTimeout + const Duration(seconds: 2),
              onTimeout: () => throw const WebSearchTransientError('后端响应超时'),
            );

        reports.add(WebSearchBackendReport(
          provider: provider,
          ok: true,
          resultCount: results.length,
          elapsedMs: stopwatch.elapsedMilliseconds,
        ));
        batches.add(WebSearchBatch(provider: provider, results: results));
      } on WebSearchCancelledError {
        if (timedOut) {
          reports.add(WebSearchBackendReport(
            provider: provider,
            ok: false,
            resultCount: 0,
            elapsedMs: stopwatch.elapsedMilliseconds,
            error: '超时',
          ));
        } else if (!cancelled && dioCancelToken?.isCancelled != true) {
          reports.add(WebSearchBackendReport(
            provider: provider,
            ok: false,
            resultCount: 0,
            elapsedMs: stopwatch.elapsedMilliseconds,
            error: '已取消',
          ));
        }
      } on WebSearchQuotaError catch (e) {
        reports.add(WebSearchBackendReport(
          provider: provider,
          ok: false,
          resultCount: 0,
          elapsedMs: stopwatch.elapsedMilliseconds,
          error: e.message,
          permanent: e.permanent,
        ));
      } on WebSearchTransientError catch (e) {
        reports.add(WebSearchBackendReport(
          provider: provider,
          ok: false,
          resultCount: 0,
          elapsedMs: stopwatch.elapsedMilliseconds,
          error: e.message,
        ));
      } catch (e) {
        reports.add(WebSearchBackendReport(
          provider: provider,
          ok: false,
          resultCount: 0,
          elapsedMs: stopwatch.elapsedMilliseconds,
          error: e.toString(),
        ));
      } finally {
        timer?.cancel();
        semaphore.release();
      }
    }));

    if (dioCancelToken?.isCancelled == true) {
      throw const WebSearchCancelledError('搜索已被取消');
    }

    reports.sort((a, b) {
      final ai = backends.indexOf(a.provider);
      final bi = backends.indexOf(b.provider);
      return ai.compareTo(bi);
    });

    if (reports.isNotEmpty && reports.every((r) => !r.ok)) {
      final message = reports
          .map((r) => '${r.provider.displayName}(${r.error})')
          .join('；');
      final first = reports.first;
      if (reports.every((r) => r.permanent)) {
        throw WebSearchQuotaError(
          '所有搜索后端均失败：$message',
          provider: first.provider,
          permanent: true,
        );
      }
      throw WebSearchTransientError('所有搜索后端均失败：$message');
    }

    final orderedBatches = <WebSearchBatch>[
      for (final provider in backends)
        ...batches.where((b) => b.provider == provider),
    ];

    return WebSearchResponse(
      results: mergeSearchResults(orderedBatches, limit: finalLimit),
      reports: reports,
    );
  }

  int _perBackendLimit(int finalLimit) {
    // 每个后端多取一点，给去重合并留余量；单个后端最多 20 条
    return math.min(20, math.max(finalLimit, (finalLimit * 1.5).ceil()));
  }
}

class _Semaphore {
  _Semaphore(this.max);

  final int max;
  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_active < max) {
      _active++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else if (_active > 0) {
      _active--;
    }
  }
}
