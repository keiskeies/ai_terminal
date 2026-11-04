import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../services/web_search_config.dart';
import '../services/web_search_service.dart';

/// 联网搜索设置页（多后端聚合）
///
/// 12 个后端并发 fan-out；后端开关、Key、参数全部显式保存后生效。
/// 会话级临时开关在终端页底部栏，不在此处。
class WebSearchSettingsPage extends StatefulWidget {
  const WebSearchSettingsPage({super.key});

  @override
  State<WebSearchSettingsPage> createState() => _WebSearchSettingsPageState();
}

class _WebSearchSettingsPageState extends State<WebSearchSettingsPage> {
  static const List<WebSearchProvider> _freeBackends = [
    WebSearchProvider.bingRss,
    WebSearchProvider.duckduckgo,
    WebSearchProvider.searxng,
  ];

  /// 展示顺序与截图一致：DeepSeek 占位行保留在 Key 分组
  static const List<WebSearchProvider> _keyBackends = [
    WebSearchProvider.exa,
    WebSearchProvider.parallel,
    WebSearchProvider.brave,
    WebSearchProvider.tavily,
    WebSearchProvider.serper,
    WebSearchProvider.mojeek,
    WebSearchProvider.deepseek,
    WebSearchProvider.anthropic,
    WebSearchProvider.openai,
  ];

  /// 有 Key 输入框的后端（DeepSeek 不可用，SearXNG 单独在私有实例区）
  static const List<WebSearchProvider> _keyInputBackends = [
    WebSearchProvider.exa,
    WebSearchProvider.parallel,
    WebSearchProvider.brave,
    WebSearchProvider.tavily,
    WebSearchProvider.serper,
    WebSearchProvider.mojeek,
    WebSearchProvider.anthropic,
    WebSearchProvider.openai,
  ];

  static const List<WebSearchProvider> _allBackends = [
    ..._freeBackends,
    ..._keyBackends,
  ];

  late WebSearchConfig _draft;

  final Map<WebSearchProvider, TextEditingController> _keyControllers = {};
  final Map<WebSearchProvider, bool> _obscureKeys = {};
  final Map<WebSearchProvider, WebSearchApiKeyStatus> _keyStatus = {};
  final Set<WebSearchProvider> _clearKeys = {};

  late final TextEditingController _numResultsController;
  late final TextEditingController _concurrencyController;
  late final TextEditingController _timeoutController;
  late final TextEditingController _proxyController;
  late final TextEditingController _searxngUrlController;
  final TextEditingController _testController = TextEditingController();

  final Map<String, String> _fieldErrors = {};

  bool _statusLoading = true;
  int _statusGeneration = 0;

  bool _testRunning = false;
  int _testGeneration = 0;
  CancelToken? _testCancel;
  WebSearchResponse? _testResponse;
  String? _testError;

  @override
  void initState() {
    super.initState();
    final saved = WebSearchConfig.load();
    _draft = saved;
    for (final provider in [..._keyInputBackends, WebSearchProvider.searxng]) {
      _keyControllers[provider] = TextEditingController();
      _obscureKeys[provider] = true;
    }
    _numResultsController =
        TextEditingController(text: '${saved.numResults}');
    _concurrencyController =
        TextEditingController(text: '${saved.concurrency}');
    _timeoutController =
        TextEditingController(text: '${saved.backendTimeoutMs}');
    _proxyController = TextEditingController(text: saved.proxy);
    _searxngUrlController =
        TextEditingController(text: saved.searxngInstanceUrl);
    _refreshKeyStatus();
  }

  @override
  void dispose() {
    _testGeneration++;
    _testCancel?.cancel('dispose');
    for (final controller in _keyControllers.values) {
      controller.dispose();
    }
    _numResultsController.dispose();
    _concurrencyController.dispose();
    _timeoutController.dispose();
    _proxyController.dispose();
    _searxngUrlController.dispose();
    _testController.dispose();
    super.dispose();
  }

  Future<void> _refreshKeyStatus() async {
    final generation = ++_statusGeneration;
    if (mounted) setState(() => _statusLoading = true);
    try {
      final entries = await Future.wait(
        _keyControllers.keys.map((provider) async {
          return MapEntry(provider, await WebSearchConfig.apiKeyStatus(provider));
        }),
      );
      if (!mounted || generation != _statusGeneration) return;
      setState(() {
        _keyStatus
          ..clear()
          ..addEntries(entries);
        _statusLoading = false;
      });
    } catch (e) {
      if (!mounted || generation != _statusGeneration) return;
      setState(() => _statusLoading = false);
      _showSnack('读取 Key 状态失败：$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('联网搜索')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              pStandard,
              pStandard,
              pStandard,
              pXLarge,
            ),
            children: [
              _buildStatusCard(tc),
              const SizedBox(height: 12),
              Text(
                '聚合网络搜索：12 个后端并发 fan-out、URL 去重合并。'
                '开关后端、填 API Key、调参数，保存即生效。',
                style: TextStyle(
                  color: tc.textSub,
                  fontSize: fSmall,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              _buildSectionTitle('免密钥（开箱即用）', tc),
              _buildPanel(
                tc,
                _twoColumn(
                  [
                    for (final provider in _freeBackends)
                      _buildBackendRow(provider, tc),
                  ],
                  runSpacing: 2,
                ),
              ),
              const SizedBox(height: 20),
              _buildSectionTitle('需要 API Key', tc),
              _buildPanel(
                tc,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _twoColumn(
                      [
                        for (final provider in _keyBackends)
                          _buildBackendRow(provider, tc),
                      ],
                      runSpacing: 2,
                    ),
                    const SizedBox(height: 12),
                    Divider(height: 1, color: tc.hairline),
                    const SizedBox(height: 14),
                    _twoColumn(
                      [
                        for (final provider in _keyInputBackends)
                          _buildKeyField(provider, tc),
                      ],
                      runSpacing: 16,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'DeepSeek 官方 API 不提供网页搜索，保留占位行且不会发起请求。',
                      style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _buildSectionTitle('私有实例可选 Key', tc),
              _buildPanel(tc, _buildSearxngPanel(tc)),
              const SizedBox(height: 20),
              _buildSectionTitle('全局参数', tc),
              _buildPanel(tc, _buildGlobalParams(tc)),
              const SizedBox(height: 20),
              _buildSectionTitle('立即测试', tc),
              _buildPanel(tc, _buildTestPanel(tc)),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomBar(tc),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // 状态卡
  // ─────────────────────────────────────────────────────────────

  Widget _buildStatusCard(ThemeColors tc) {
    final configuredKeys = _keyInputBackends
        .where((provider) => _keyStatus[provider]?.configured == true)
        .length;
    return Container(
      padding: const EdgeInsets.all(pStandard),
      decoration: BoxDecoration(
        color: tc.card,
        border: Border.all(color: tc.border),
        borderRadius: BorderRadius.circular(rLarge),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 18,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _statText(
                      _draft.enabled ? '已启用后端: ' : '已选后端: ',
                      '${_draft.enabledCount}/${WebSearchProvider.values.length}',
                      tc,
                    ),
                    _statText(
                      '已配置密钥: ',
                      '$configuredKeys/'
                          '${WebSearchProvider.values.where((p) => p.requiresApiKey).length}',
                      tc,
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _statusLoading ? null : _refreshKeyStatus,
                icon: _statusLoading
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: tc.textSub,
                        ),
                      )
                    : const Icon(Icons.refresh, size: 16),
                label: const Text('刷新状态'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: tc.hairline),
          const SizedBox(height: 4),
          Row(
            children: [
              Switch(
                value: _draft.enabled,
                onChanged: (value) =>
                    setState(() => _draft = _draft.copyWith(enabled: value)),
                activeThumbColor: tc.brand,
                activeTrackColor: tc.brandBg,
                inactiveThumbColor: tc.textMuted,
                inactiveTrackColor: tc.surface,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '启用联网搜索（总开关）。关闭后 AI 不会调用 web_search / fetch_url；'
                  '勾选任意后端会自动开启，会话页底部栏仍可临时覆盖。',
                  style: TextStyle(
                    color: tc.textSub,
                    fontSize: fSmall,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statText(String label, String value, ThemeColors tc) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
        Text(
          value,
          style: TextStyle(
            color: tc.textMain,
            fontSize: fBody,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────
  // 后端行
  // ─────────────────────────────────────────────────────────────

  Widget _buildBackendRow(WebSearchProvider provider, ThemeColors tc) {
    final enabled = _draft.enabledBackends.contains(provider);
    final available = provider.isAvailable;
    final keyStatus = _keyStatus[provider];
    final needsKey = provider.requiresApiKey && keyStatus?.configured != true;
    final needsInstance = provider == WebSearchProvider.searxng &&
        _searxngUrlController.text.trim().isEmpty;

    final dotColor = !available || !enabled
        ? tc.textMuted
        : (needsKey || needsInstance)
            ? tc.warn
            : tc.ok;

    return Semantics(
      checked: enabled,
      enabled: available,
      child: InkWell(
        borderRadius: BorderRadius.circular(rSmall),
        onTap: available ? () => _toggleBackend(provider, !enabled) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
          child: Row(
            children: [
              _buildSquareCheck(enabled, available, tc),
              const SizedBox(width: 10),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        provider.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: available ? tc.textBody : tc.textMuted,
                          fontSize: fBody,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        provider.tagline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tc.textMuted,
                          fontSize: fMicro,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!available)
                _badge('不可用', tc.textMuted)
              else if (enabled && needsKey)
                _badge('需 Key', tc.warn),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSquareCheck(bool checked, bool enabled, ThemeColors tc) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: checked ? tc.brand : Colors.transparent,
        border: Border.all(
          color: checked
              ? tc.brand
              : (enabled ? tc.borderHover : tc.border),
          width: 1.2,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: checked
          ? Icon(
              Icons.check,
              size: 14,
              color: tc.isLight ? Colors.white : cBg,
            )
          : null,
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(rFull),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: fMicro,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  void _toggleBackend(WebSearchProvider provider, bool enabled) {
    if (!provider.isAvailable) return;
    setState(() {
      final backends = [..._draft.enabledBackends];
      if (enabled) {
        if (!backends.contains(provider)) backends.add(provider);
      } else {
        backends.remove(provider);
      }
      backends.sort(
        (a, b) => _allBackends.indexOf(a).compareTo(_allBackends.indexOf(b)),
      );
      _draft = _draft.copyWith(
        enabledBackends: List<WebSearchProvider>.unmodifiable(backends),
        // 勾选后端即视为要使用联网搜索；取消勾选不擅自打开总开关
        enabled: enabled ? true : (_draft.enabled && backends.isNotEmpty),
      );
    });
  }

  // ─────────────────────────────────────────────────────────────
  // API Key
  // ─────────────────────────────────────────────────────────────

  Widget _buildKeyField(WebSearchProvider provider, ThemeColors tc) {
    final controller = _keyControllers[provider]!;
    final status = _keyStatus[provider];
    final configured = status?.configured == true;
    final fromEnv = status?.fromEnv == true && status?.fromStore != true;
    final obscure = _obscureKeys[provider] ?? true;
    final badgeText = _statusLoading
        ? '检查中'
        : fromEnv
            ? '环境变量'
            : configured
                ? '已配置'
                : '未配置';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${provider.displayName} API Key',
              style: TextStyle(
                color: tc.textBody,
                fontSize: fSmall,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (provider.signupUrl.isNotEmpty &&
                provider != WebSearchProvider.searxng)
              InkWell(
                onTap: () => _copyUrl(provider.signupUrl),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      provider == WebSearchProvider.searxng
                          ? '部署文档'
                          : '获取 Key',
                      style: TextStyle(color: tc.brand, fontSize: fMicro),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.open_in_new, size: 11, color: tc.brand),
                  ],
                ),
              ),
            _badge(badgeText, configured ? tc.ok : tc.textMuted),
            if (status?.clearable == true)
              InkWell(
                onTap: () => _requestClearKey(provider),
                child: Text(
                  '清除',
                  style: TextStyle(color: tc.warn, fontSize: fMicro),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: TextStyle(color: tc.textMain, fontSize: fSmall),
          onChanged: (_) {
            setState(() {
              _clearKeys.remove(provider);
            });
          },
          decoration: InputDecoration(
            hintText: provider.envKeyName,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            helperText: provider == WebSearchProvider.searxng
                ? '可选 Token：作为 Authorization: Bearer 发送'
                : '留空表示不修改；也可使用同名环境变量',
            helperStyle: TextStyle(color: tc.textMuted, fontSize: fMicro),
            helperMaxLines: 1,
            suffixIconConstraints:
                const BoxConstraints(minWidth: 36, minHeight: 32),
            suffixIcon: IconButton(
              icon: Icon(
                obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 17,
              ),
              onPressed: () => setState(
                () => _obscureKeys[provider] = !obscure,
              ),
            ),
          ),
        ),
        if (_clearKeys.contains(provider))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '保存后将清除已保存的 Key',
              style: TextStyle(color: tc.warn, fontSize: fMicro),
            ),
          ),
      ],
    );
  }

  void _requestClearKey(WebSearchProvider provider) {
    setState(() {
      _keyControllers[provider]?.clear();
      _clearKeys.add(provider);
    });
  }

  // ─────────────────────────────────────────────────────────────
  // SearXNG 私有实例
  // ─────────────────────────────────────────────────────────────

  Widget _buildSearxngPanel(ThemeColors tc) {
    final keyField = _buildKeyField(WebSearchProvider.searxng, tc);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SearXNG 实例地址',
          style: TextStyle(
            color: tc.textBody,
            fontSize: fSmall,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _searxngUrlController,
          style: TextStyle(color: tc.textMain, fontSize: fSmall),
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'http://127.0.0.1:8888',
            isDense: true,
            contentPadding:
                EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '公共实例（含 searx.be）通常禁用 format=json，只回 HTML，必须自建：'
          'docker run -d -p 8080:8080 searxng/searxng，并在 settings.yml 启用 '
          'search.formats: [json]。本机实例直接填 http://127.0.0.1:8888 这类地址即可。',
          style: TextStyle(color: tc.textSub, fontSize: fMicro, height: 1.5),
        ),
        const SizedBox(height: 4),
        InkWell(
          onTap: () => _copyUrl(
            'https://docs.searxng.org/admin/installation.html',
          ),
          child: Text(
            'SearXNG 部署文档 →',
            style: TextStyle(
              color: tc.brand,
              fontSize: fMicro,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
        const SizedBox(height: 16),
        keyField,
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────
  // 全局参数
  // ─────────────────────────────────────────────────────────────

  Widget _buildGlobalParams(ThemeColors tc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _twoColumn(
          [
            _buildNumberField(
              label: 'numResults',
              errorKey: 'numResults',
              controller: _numResultsController,
              hint: '8',
              helper: '最终返回条数（1-20）',
              tc: tc,
            ),
            _buildNumberField(
              label: 'concurrency',
              errorKey: 'concurrency',
              controller: _concurrencyController,
              hint: '6',
              helper: '同时请求的后端数（1-12）',
              tc: tc,
            ),
            _buildNumberField(
              label: 'backendTimeoutMs',
              errorKey: 'backendTimeoutMs',
              controller: _timeoutController,
              hint: '30000',
              helper: '单个后端最长等待（3000-120000ms）',
              tc: tc,
            ),
          ],
          runSpacing: 14,
        ),
        const SizedBox(height: 14),
        Text(
          '出站代理',
          style: TextStyle(
            color: tc.textBody,
            fontSize: fSmall,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _proxyController,
          style: TextStyle(color: tc.textMain, fontSize: fSmall),
          onChanged: (_) {
            if (_fieldErrors.containsKey('proxy')) {
              setState(() => _fieldErrors.remove('proxy'));
            }
          },
          decoration: InputDecoration(
            hintText: 'http://127.0.0.1:7890',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            helperText: 'HTTP 代理，留空直连；HTTPS 目标自动走 CONNECT，不支持 SOCKS5',
            helperStyle: TextStyle(color: tc.textMuted, fontSize: fMicro),
            helperMaxLines: 2,
            errorText: _fieldErrors['proxy'],
            errorStyle: TextStyle(color: tc.error, fontSize: fMicro),
          ),
        ),
      ],
    );
  }

  Widget _buildNumberField({
    required String label,
    required String errorKey,
    required TextEditingController controller,
    required String hint,
    required String helper,
    required ThemeColors tc,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: tc.textBody,
            fontSize: fSmall,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: TextStyle(color: tc.textMain, fontSize: fSmall),
          onChanged: (_) {
            if (_fieldErrors.containsKey(errorKey)) {
              setState(() => _fieldErrors.remove(errorKey));
            }
          },
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            helperText: _fieldErrors.containsKey(errorKey) ? null : helper,
            helperStyle: TextStyle(color: tc.textMuted, fontSize: fMicro),
            helperMaxLines: 1,
            errorText: _fieldErrors[errorKey],
            errorStyle: TextStyle(color: tc.error, fontSize: fMicro),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────
  // 立即测试
  // ─────────────────────────────────────────────────────────────

  Widget _buildTestPanel(ThemeColors tc) {
    final response = _testResponse;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _testController,
                style: TextStyle(color: tc.textMain, fontSize: fSmall),
                onSubmitted: (_) => _runTest(),
                decoration: const InputDecoration(
                  hintText: '输入查询，例如 OpenAI latest news',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _testRunning ? null : _runTest,
              style: FilledButton.styleFrom(
                backgroundColor: tc.brand,
                foregroundColor: tc.isLight ? Colors.white : cBg,
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              icon: _testRunning
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: tc.isLight ? Colors.white : cBg,
                      ),
                    )
                  : const Icon(Icons.search, size: 16),
              label: Text(_testRunning ? '搜索中' : '搜索'),
            ),
          ],
        ),
        if (_testRunning) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(
            minHeight: 2,
            color: tc.brand,
            backgroundColor: tc.brandBg,
          ),
        ],
        if (_testError != null) ...[
          const SizedBox(height: 12),
          _errorBox(_testError!, tc),
        ],
        if (response != null) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final report in response.reports)
                _reportChip(report, tc),
            ],
          ),
          if (response.failures.isNotEmpty) ...[
            const SizedBox(height: 10),
            _errorBox(
              response.failures
                  .map((r) => '${r.provider.displayName}: ${r.error}')
                  .join('\n'),
              tc,
            ),
          ],
          const SizedBox(height: 10),
          if (response.results.isEmpty)
            Text(
              '没有匹配结果。',
              style: TextStyle(color: tc.textSub, fontSize: fSmall),
            )
          else
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: tc.hairline),
                borderRadius: BorderRadius.circular(rMedium),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < response.results.length; i++) ...[
                    if (i > 0) Divider(height: 1, color: tc.hairline),
                    _buildTestResult(response.results[i], i, tc),
                  ],
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _reportChip(WebSearchBackendReport report, ThemeColors tc) {
    final color = report.ok ? tc.ok : tc.error;
    final background = report.ok ? tc.okBg : tc.errorBg;
    return Tooltip(
      message: report.summary,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(rFull),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '${report.provider.displayName} ${report.summary}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: fMicro),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestResult(
    WebSearchResult result,
    int index,
    ThemeColors tc,
  ) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${index + 1}.',
                  style: TextStyle(color: tc.textMuted, fontSize: fSmall),
                ),
              ),
              Expanded(
                child: Text(
                  result.title.isEmpty ? result.url : result.title,
                  style: TextStyle(
                    color: tc.textMain,
                    fontSize: fBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () => _copyUrl(result.url),
                  child: Text(
                    result.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tc.brand, fontSize: fMicro),
                  ),
                ),
                if (result.snippet.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    result.snippet,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tc.textSub,
                      fontSize: fSmall,
                      height: 1.4,
                    ),
                  ),
                ],
                if (result.sources.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '来源: ${result.sources.map((p) => p.displayName).join(' / ')}',
                    style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBox(String text, ThemeColors tc) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tc.errorBg,
        borderRadius: BorderRadius.circular(rSmall),
      ),
      child: Text(
        text,
        style: TextStyle(color: tc.error, fontSize: fSmall, height: 1.4),
      ),
    );
  }

  Future<void> _runTest() async {
    final query = _testController.text.trim();
    if (query.isEmpty) {
      _showSnack('请输入查询关键词');
      return;
    }
    final config = _readConfigFromForm();
    if (config == null) return;

    final overrides = <WebSearchProvider, String>{};
    for (final provider in _keyControllers.keys) {
      final text = _keyControllers[provider]!.text.trim();
      if (text.isNotEmpty) {
        overrides[provider] = text;
      } else if (_clearKeys.contains(provider)) {
        overrides[provider] = '';
      }
    }

    _testCancel?.cancel('superseded');
    final cancel = CancelToken();
    final generation = ++_testGeneration;
    setState(() {
      _testRunning = true;
      _testResponse = null;
      _testError = null;
      _testCancel = cancel;
    });

    try {
      final response = await WebSearchService.instance.search(
        query,
        maxResults: config.numResults,
        configOverride: config,
        apiKeyOverrides: overrides,
        dioCancelToken: cancel,
      );
      if (!mounted || generation != _testGeneration) return;
      setState(() => _testResponse = response);
    } on WebSearchCancelledError {
      // 新一轮测试或页面关闭
    } on WebSearchQuotaError catch (e) {
      if (!mounted || generation != _testGeneration) return;
      setState(() => _testError = e.message);
    } on WebSearchTransientError catch (e) {
      if (!mounted || generation != _testGeneration) return;
      setState(() => _testError = e.message);
    } catch (e) {
      if (!mounted || generation != _testGeneration) return;
      setState(() => _testError = '测试失败：$e');
    } finally {
      if (mounted && generation == _testGeneration) {
        setState(() {
          _testRunning = false;
          _testCancel = null;
        });
      }
    }
  }

  // ─────────────────────────────────────────────────────────────
  // 保存 / 重置
  // ─────────────────────────────────────────────────────────────

  WebSearchConfig? _readConfigFromForm() {
    final errors = <String, String>{};
    final numResults = _parseInt(
      _numResultsController.text,
      1,
      20,
      errors,
      'numResults',
      '需在 1-20 之间',
    );
    final concurrency = _parseInt(
      _concurrencyController.text,
      1,
      12,
      errors,
      'concurrency',
      '需在 1-12 之间',
    );
    final backendTimeoutMs = _parseInt(
      _timeoutController.text,
      3000,
      120000,
      errors,
      'backendTimeoutMs',
      '需在 3000-120000 之间',
    );
    final proxyRaw = _proxyController.text.trim();
    final proxy = _normalizeProxy(proxyRaw);
    if (proxyRaw.isNotEmpty && proxy == null) {
      errors['proxy'] = '仅支持 http://host:port，不支持 SOCKS5/代理账号密码';
    }
    setState(() {
      _fieldErrors
        ..clear()
        ..addAll(errors);
    });
    if (errors.isNotEmpty) {
      _showSnack('参数有误，请检查高亮字段', error: true);
      return null;
    }
    return _draft.copyWith(
      numResults: numResults,
      concurrency: concurrency,
      backendTimeoutMs: backendTimeoutMs,
      proxy: proxy ?? '',
      searxngInstanceUrl: _searxngUrlController.text.trim(),
      enabledBackends: List<WebSearchProvider>.unmodifiable(
        _draft.enabledBackends,
      ),
    );
  }

  int? _parseInt(
    String raw,
    int min,
    int max,
    Map<String, String> errors,
    String key,
    String message,
  ) {
    final value = int.tryParse(raw.trim());
    if (value == null || value < min || value > max) {
      errors[key] = message;
      return null;
    }
    return value;
  }

  String? _normalizeProxy(String raw) {
    if (raw.isEmpty) return '';
    final withScheme = raw.contains('://') ? raw : 'http://$raw';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http') return null;
    if (uri.userInfo.isNotEmpty) return null;
    return withScheme;
  }

  Future<void> _save() async {
    final config = _readConfigFromForm();
    if (config == null) return;

    try {
      await config.save();
    } catch (e) {
      _showSnack('配置保存失败：$e', error: true);
      return;
    }

    final failedProviders = <WebSearchProvider>{};
    for (final provider in _keyControllers.keys) {
      final text = _keyControllers[provider]!.text.trim();
      if (text.isNotEmpty) {
        final ok = await WebSearchConfig.saveApiKey(provider, text);
        if (!ok) failedProviders.add(provider);
      } else if (_clearKeys.contains(provider)) {
        await WebSearchConfig.deleteApiKey(provider);
      }
    }
    if (!mounted) return;

    setState(() {
      _draft = config;
      for (final provider in _keyControllers.keys) {
        // 写入失败的 Key 保留在输入框，方便用户直接重试
        if (!failedProviders.contains(provider)) {
          _keyControllers[provider]!.clear();
        }
      }
      _clearKeys.clear();
    });

    if (failedProviders.isNotEmpty) {
      _showSnack(
        '配置已保存，但这些 Key 写入失败：'
        '${failedProviders.map((p) => p.displayName).join('、')}',
        error: true,
      );
    } else {
      _showSnack('已保存，立即生效');
    }
    // 状态刷新异步进行，不阻塞保存确认
    _refreshKeyStatus();
  }

  void _reset() {
    _testGeneration++;
    _testCancel?.cancel('reset');
    final saved = WebSearchConfig.load();
    setState(() {
      _draft = saved;
      _numResultsController.text = '${saved.numResults}';
      _concurrencyController.text = '${saved.concurrency}';
      _timeoutController.text = '${saved.backendTimeoutMs}';
      _proxyController.text = saved.proxy;
      _searxngUrlController.text = saved.searxngInstanceUrl;
      for (final controller in _keyControllers.values) {
        controller.clear();
      }
      _clearKeys.clear();
      _fieldErrors.clear();
      _testRunning = false;
      _testCancel = null;
      _testResponse = null;
      _testError = null;
    });
    _refreshKeyStatus();
    _showSnack('已恢复上次保存的状态');
  }

  // ─────────────────────────────────────────────────────────────
  // 布局工具
  // ─────────────────────────────────────────────────────────────

  Widget _buildSectionTitle(String title, ThemeColors tc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title,
        style: TextStyle(
          color: tc.textMain,
          fontSize: fTitle,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildPanel(ThemeColors tc, Widget child) {
    return Container(
      padding: const EdgeInsets.all(pStandard),
      decoration: BoxDecoration(
        color: tc.card,
        border: Border.all(color: tc.border),
        borderRadius: BorderRadius.circular(rLarge),
      ),
      child: child,
    );
  }

  Widget _twoColumn(
    List<Widget> children, {
    double runSpacing = 4,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 16.0;
        final twoColumns = constraints.maxWidth >= 620;
        final itemWidth = twoColumns
            ? (constraints.maxWidth - gap) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: gap,
          runSpacing: runSpacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }

  Widget _buildBottomBar(ThemeColors tc) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: pStandard,
          vertical: pCompact,
        ),
        decoration: BoxDecoration(
          color: tc.card,
          border: Border(top: BorderSide(color: tc.hairline)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('重置状态'),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                backgroundColor: tc.brand,
                foregroundColor: tc.isLight ? Colors.white : cBg,
                minimumSize: const Size(88, 38),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    _showSnack('链接已复制: $url');
  }

  void _showSnack(String message, {bool error = false}) {
    if (!mounted) return;
    final tc = ThemeColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? tc.error : null,
      ),
    );
  }
}
