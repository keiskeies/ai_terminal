import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../services/web_search_config.dart';

/// 联网搜索设置页
///
/// 配置全局开关、搜索 provider、API key、结果数、超时。
/// 会话级临时开关在终端页底部栏 toggle，不在此处。
class WebSearchSettingsPage extends StatefulWidget {
  const WebSearchSettingsPage({super.key});

  @override
  State<WebSearchSettingsPage> createState() => _WebSearchSettingsPageState();
}

class _WebSearchSettingsPageState extends State<WebSearchSettingsPage> {
  late WebSearchConfig _config;
  final _apiKeyController = TextEditingController();
  bool _apiKeyLoaded = false;
  bool _obscureApiKey = true;
  Timer? _apiKeyDebounce;

  @override
  void initState() {
    super.initState();
    _config = WebSearchConfig.load();
    _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    final key = await WebSearchConfig.getApiKey(_config.provider);
    if (mounted) {
      _apiKeyController.text = key ?? '';
      setState(() => _apiKeyLoaded = true);
    }
  }

  @override
  void dispose() {
    // 页面关闭时立即 flush 未保存的 apiKey（debounce 可能还没触发）
    if (_apiKeyDebounce?.isActive ?? false) {
      _apiKeyDebounce!.cancel();
      WebSearchConfig.saveApiKey(_config.provider, _apiKeyController.text.trim());
    }
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _saveConfig(WebSearchConfig newConfig) async {
    setState(() => _config = newConfig);
    await newConfig.save();
  }

  Future<void> _saveApiKey() async {
    // debounce：用户快速打字时避免每次按键都写 Keychain（慢 IO）
    _apiKeyDebounce?.cancel();
    _apiKeyDebounce = Timer(const Duration(milliseconds: 600), () async {
      await WebSearchConfig.saveApiKey(_config.provider, _apiKeyController.text.trim());
    });
  }

  /// 切换 provider 时，重新加载对应的 API key
  Future<void> _onProviderChanged(WebSearchProvider newProvider) async {
    // 先立即 flush 当前 provider 的 apiKey（跳过 debounce，确保切换前已落盘）
    _apiKeyDebounce?.cancel();
    await WebSearchConfig.saveApiKey(_config.provider, _apiKeyController.text.trim());
    final newConfig = _config.copyWith(provider: newProvider);
    setState(() {
      _config = newConfig;
      _apiKeyLoaded = false;
    });
    await newConfig.save();
    // 重新加载新 provider 的 apiKey
    _apiKeyController.clear();
    final key = await WebSearchConfig.getApiKey(newProvider);
    if (mounted) {
      _apiKeyController.text = key ?? '';
      setState(() => _apiKeyLoaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('联网搜索')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(pStandard),
            children: [
              // 全局开关
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(pStandard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('启用联网搜索', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                                const SizedBox(height: 4),
                                Text(
                                  '开启后，AI 在自身知识不足时可主动调用 web_search 工具搜索网络信息。会话页底部栏可临时覆盖此开关。',
                                  style: TextStyle(color: tc.textSub, fontSize: fSmall),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: _config.enabled,
                            onChanged: (v) => _saveConfig(_config.copyWith(enabled: v)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Provider 选择
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(pStandard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('搜索引擎', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text('选择搜索数据源。不同 provider 的免费额度和结果质量有差异。', style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<WebSearchProvider>(
                        value: _config.provider,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                        items: WebSearchProvider.values.map((p) {
                          return DropdownMenuItem(
                            value: p,
                            child: Text(p.displayName),
                          );
                        }).toList(),
                        onChanged: (v) {
                          if (v != null) _onProviderChanged(v);
                        },
                      ),
                      if (_config.provider.signupUrl.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        InkWell(
                          onTap: () => _launchUrl(_config.provider.signupUrl),
                          child: Text(
                            '申请 ${_config.provider.displayName} API key →',
                            style: TextStyle(color: cPrimary, fontSize: fSmall, decoration: TextDecoration.underline),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // API Key（tavily/bing/brave/serpapi 需要）
              if (_config.provider.requiresApiKey)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(pStandard),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${_config.provider.displayName} API Key', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('API key 加密存储在系统 Keychain 中，不会明文落盘。', style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                        const SizedBox(height: 12),
                        if (!_apiKeyLoaded)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5)),
                          )
                        else
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _apiKeyController,
                                  obscureText: _obscureApiKey,
                                  decoration: InputDecoration(
                                    border: const OutlineInputBorder(),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    hintText: '输入 API key',
                                    suffixIcon: IconButton(
                                      icon: Icon(_obscureApiKey ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                                      onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
                                    ),
                                  ),
                                  onChanged: (_) => _saveApiKey(),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),

              // SearXNG 实例 URL（仅 searxng provider，存 SettingsDao，不加密）
              if (_config.provider.requiresInstanceUrl)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(pStandard),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('SearXNG 实例地址', style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('自建实例的访问地址，需在实例的 settings.yml 中开启 search.formats: [html, json]。', style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                        const SizedBox(height: 12),
                        TextField(
                          controller: TextEditingController(text: _config.searxngInstanceUrl),
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            hintText: 'http://localhost:8080',
                          ),
                          onSubmitted: (v) => _saveConfig(_config.copyWith(searxngInstanceUrl: v.trim())),
                        ),
                        const SizedBox(height: 8),
                        InkWell(
                          onTap: () => _launchUrl('https://docs.searxng.org/admin/installation.html'),
                          child: Text(
                            'SearXNG 部署文档 →',
                            style: TextStyle(color: cPrimary, fontSize: fSmall, decoration: TextDecoration.underline),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 16),

              // 结果数 + 超时
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(pStandard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // maxResults
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('单次结果数', style: TextStyle(color: tc.textMain, fontSize: fBody)),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: cPrimary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(rSmall),
                            ),
                            child: Text('${_config.maxResults}', style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      Slider(
                        value: _config.maxResults.clamp(1, 20).toDouble(),
                        min: 1,
                        max: 20,
                        divisions: 19,
                        label: '${_config.maxResults}',
                        onChanged: (v) => _saveConfig(_config.copyWith(maxResults: v.toInt())),
                      ),
                      const SizedBox(height: 12),
                      // timeoutSeconds
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('请求超时（秒）', style: TextStyle(color: tc.textMain, fontSize: fBody)),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: cPrimary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(rSmall),
                            ),
                            child: Text('${_config.timeoutSeconds}s', style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      Slider(
                        value: _config.timeoutSeconds.clamp(5, 60).toDouble(),
                        min: 5,
                        max: 60,
                        divisions: 55,
                        label: '${_config.timeoutSeconds}s',
                        onChanged: (v) => _saveConfig(_config.copyWith(timeoutSeconds: v.toInt())),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // 说明
              Card(
                color: tc.surface,
                child: Padding(
                  padding: const EdgeInsets.all(pStandard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: tc.textSub, size: 16),
                          const SizedBox(width: 6),
                          Text('工作原理', style: TextStyle(color: tc.textMain, fontSize: fSmall, fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '• AI 自主决定何时搜索（不会每轮盲目搜索）\n'
                        '• web_search 返回标题/URL/摘要列表\n'
                        '• fetch_url 抓取指定 URL 正文（封顶 20000 字符）\n'
                        '• 会话页底部栏 toggle 可临时覆盖此处的全局开关\n'
                        '• 运行中切换开关，下次任务生效（避免污染当前 ReAct 上下文）',
                        style: TextStyle(color: tc.textSub, fontSize: fSmall, height: 1.6),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _launchUrl(String url) {
    // 简化：通过 clipboard 让用户粘贴到浏览器
    // 不引入 url_launcher 依赖（项目 pubspec 没有）
    Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('链接已复制: $url'), duration: const Duration(seconds: 3)),
      );
    }
  }
}
