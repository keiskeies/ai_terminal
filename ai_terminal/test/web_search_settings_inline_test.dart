import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/services/web_search_backends.dart';
import 'package:ai_terminal/services/web_search_config.dart';
import 'package:ai_terminal/services/web_search_models.dart';
import 'package:ai_terminal/widgets/settings_inline_panel.dart';

/// 联网搜索设置曾经只剩「开关 + 后端胶囊 + 一行只读条数」：加了 SearXNG 却
/// 无处填实例地址，每次搜索都静默跳过它；代理、条数、并发、超时也全没了入口。
/// 这组测试盯的就是这些入口真的在、校验真的拦、改动真的落盘。
void main() {
  late WebSearchProviderApi originalBing;

  setUp(() async {
    await SettingsDao.remove('webSearchConfig');
    originalBing = webSearchProviders[WebSearchProvider.bingRss]!;
    webSearchProviders[WebSearchProvider.bingRss] = _FakeBingProvider();
  });

  tearDown(() async {
    webSearchProviders[WebSearchProvider.bingRss] = originalBing;
    await SettingsDao.remove('webSearchConfig');
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: SettingsInlinePanel(settingsId: 'web_search'),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> addBackend(WidgetTester tester, String label) async {
    await tester.tap(find.text('+ 添加'));
    await tester.pump();
    await tester.tap(find.text(label));
    await tester.pump();
  }

  testWidgets('添加 SearXNG 先要实例地址，而不是闷头启用', (tester) async {
    await pumpPanel(tester);
    await addBackend(tester, 'SearXNG');

    // 表单出现，且后端还没进已启用列表——这是当年的核心 bug
    expect(find.text('SearXNG 实例地址'), findsOneWidget);
    expect(WebSearchConfig.load().enabledBackends,
        isNot(contains(WebSearchProvider.searxng)));

    // 空地址点「保存并启用」被拦下
    await tester.tap(find.text('保存并启用'));
    await tester.pump();
    expect(find.textContaining('http(s)://host:port'), findsWidgets);
    expect(WebSearchConfig.load().enabledBackends,
        isNot(contains(WebSearchProvider.searxng)));
  });

  testWidgets('填了实例地址才落盘并启用，尾斜杠会被去掉', (tester) async {
    await pumpPanel(tester);
    await addBackend(tester, 'SearXNG');

    // 表单里就两个输入框：地址在前，Token 在后
    await tester.enterText(
        find.byType(TextField).first, 'http://192.168.1.5:8080/');
    await tester.tap(find.text('保存并启用'));
    await tester.pump();
    await tester.pump();

    final cfg = WebSearchConfig.load();
    expect(cfg.searxngInstanceUrl, 'http://192.168.1.5:8080');
    expect(cfg.enabledBackends, contains(WebSearchProvider.searxng));
    // 勾选后端即视为要用联网搜索，总开关自动跟上
    expect(cfg.enabled, isTrue);
  });

  testWidgets('点已启用的 SearXNG 胶囊是补地址，不是删掉后端', (tester) async {
    await WebSearchConfig.load()
        .copyWith(
          enabled: true,
          enabledBackends: const [
            WebSearchProvider.bingRss,
            WebSearchProvider.searxng,
          ],
          searxngInstanceUrl: 'http://127.0.0.1:8888',
        )
        .save();
    await pumpPanel(tester);

    await tester.tap(find.text('SearXNG'));
    await tester.pump();

    expect(find.text('SearXNG 实例地址'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'http://127.0.0.1:8888');
    expect(WebSearchConfig.load().enabledBackends,
        contains(WebSearchProvider.searxng));
  });

  testWidgets('缺地址的 SearXNG 挂警示角标，缺 Key 的后端挂金锁', (tester) async {
    await WebSearchConfig.load().copyWith(
      enabled: true,
      enabledBackends: const [
        WebSearchProvider.searxng,
        WebSearchProvider.tavily,
      ],
    ).save();
    await pumpPanel(tester);
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.key_rounded), findsOneWidget);
    expect(find.text('SearXNG'), findsOneWidget);
  });

  testWidgets('高级区能改返回条数，加到 20 封顶', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.textContaining('高级'));
    await tester.pump();
    expect(find.text('返回条数'), findsOneWidget);

    // 三个步进器的加号按序是条数/并发/超时；条数默认 8，越界后按钮禁用
    for (var i = 0; i < 25; i++) {
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pump();
    }
    expect(WebSearchConfig.load().numResults, 20);
  });

  testWidgets('代理非法不落库，合法则补上 http://', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.textContaining('高级'));
    await tester.pump();

    // 高级区两个输入框：代理在前（保存按钮紧随其后），测试关键词在后
    final proxyField = find.byType(TextField).first;

    await tester.enterText(proxyField, 'socks5://127.0.0.1:7890');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.textContaining('仅支持 http://host:port'), findsWidgets);
    expect(WebSearchConfig.load().proxy, '');

    await tester.enterText(proxyField, '127.0.0.1:7890');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(WebSearchConfig.load().proxy, 'http://127.0.0.1:7890');
  });

  testWidgets('立即测试要先展开，跑完把每个后端的结果摊开', (tester) async {
    await WebSearchConfig.load().copyWith(
        enabled: true,
        enabledBackends: const [WebSearchProvider.bingRss]).save();
    await pumpPanel(tester);

    await tester.tap(find.textContaining('高级'));
    await tester.pump();
    // 常驻一整个测试表单太占地方，默认只留一颗入口
    expect(find.text('立即测试'), findsOneWidget);
    expect(find.text('测试'), findsNothing);

    await tester.tap(find.text('立即测试'));
    await tester.pump();
    await tester.tap(find.text('测试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('Bing RSS · 1 条'), findsOneWidget);

    // 「返回」是收起面板，不是只清掉结果留着半屏空表单
    await tester.tap(find.text('返回'));
    await tester.pump();
    expect(find.text('立即测试'), findsOneWidget);
    expect(find.text('测试'), findsNothing);
  });

  testWidgets('360px 窄屏下联网搜索面板不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpPanel(tester);
    await tester.tap(find.textContaining('高级'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

class _FakeBingProvider implements WebSearchProviderApi {
  @override
  WebSearchProvider get type => WebSearchProvider.bingRss;

  @override
  Future<List<WebSearchResult>> search({
    required String query,
    required int maxResults,
    required Duration timeout,
    String? apiKey,
    String? instanceUrl,
    String? proxy,
    CancelToken? cancelToken,
  }) async {
    return const [
      WebSearchResult(
        title: 'Fake result',
        url: 'https://example.com/fake',
        snippet: 'fake snippet',
      ),
    ];
  }
}
