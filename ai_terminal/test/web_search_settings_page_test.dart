import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/pages/web_search_settings_page.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/services/web_search_backends.dart';
import 'package:ai_terminal/services/web_search_config.dart';
import 'package:ai_terminal/services/web_search_service.dart';

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

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const WebSearchSettingsPage(),
      ),
    );
    await tester.pump();
  }

  testWidgets('联网搜索设置页渲染关键区域', (tester) async {
    await pumpPage(tester);

    expect(find.text('免密钥（开箱即用）'), findsOneWidget);
    expect(find.text('需要 API Key'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('立即测试'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('立即测试'), findsOneWidget);
  });

  testWidgets('立即测试调用聚合服务并展示结果', (tester) async {
    await pumpPage(tester);
    await tester.scrollUntilVisible(
      find.text('立即测试'),
      400,
      scrollable: find.byType(Scrollable).first,
    );

    await tester.enterText(find.byType(TextField).last, 'flutter');
    await tester.ensureVisible(find.widgetWithText(FilledButton, '搜索'));
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.scrollUntilVisible(
      find.text('Fake result'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Fake result'), findsOneWidget);
    expect(find.textContaining('Bing RSS'), findsWidgets);
  });

  testWidgets('勾选后端会自动打开总开关', (tester) async {
    await pumpPage(tester);

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.ensureVisible(find.text('DuckDuckGo'));
    await tester.tap(find.text('DuckDuckGo'));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('已启用后端: '), findsOneWidget);
  });

  testWidgets('保存后提示立即生效', (tester) async {    await pumpPage(tester);

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text('已保存，立即生效'), findsOneWidget);
  });

  testWidgets('360px 窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpPage(tester);
    expect(find.text('保存'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('立即测试'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('立即测试'), findsOneWidget);
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
