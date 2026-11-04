import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/models/ai_endpoint.dart';
import 'package:ai_terminal/services/ai_model_selection_service.dart';
import 'package:ai_terminal/widgets/model_picker_panel.dart';

void main() {
  const endpoint = AIEndpoint(
    id: 'ep-1',
    providerId: 'custom',
    name: 'gateway',
    baseUrl: 'http://localhost:1994/v1',
    protocol: 'openai',
    createdAt: 1,
    models: [
      AIEndpointModel(
        id: 'm-1',
        name: 'Agnes',
        modelName: 'agnes-3.0-flash',
        reasoningEnabled: true,
      ),
      AIEndpointModel(
        id: 'm-2',
        name: 'Qwen',
        modelName: 'qwen3.8-flash-next',
      ),
    ],
  );

  Widget wrap(Widget child) {
    return MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.darkTheme,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('zh')],
      home: Scaffold(
        body: Builder(
          builder: (context) => ThemeColors.of(context).isLight
              ? child
              : ColoredBox(color: Colors.black, child: child),
        ),
      ),
    );
  }

  testWidgets('模型列表按端点分组，默认选中 medium 档位', (tester) async {
    String? selectedModel;
    String? selectedTier;
    var manageTapped = false;
    var doneTapped = false;

    await tester.pumpWidget(wrap(Builder(
      builder: (context) => ModelPickerPanel(
        endpoints: const [endpoint],
        currentModelId: 'm-1',
        currentTierLevel: 'medium',
        tc: ThemeColors.of(context),
        onModelSelected: (choice, tier) {
          selectedModel = choice.modelId;
          selectedTier = tier?.level;
        },
        onTierSelected: (tier) => selectedTier = tier.level,
        onManage: () => manageTapped = true,
        onDone: () => doneTapped = true,
      ),
    )));

    expect(find.text('gateway'), findsOneWidget);
    expect(find.text('Agnes'), findsOneWidget);
    expect(find.text('Qwen'), findsOneWidget);
    expect(find.text('Medium'), findsOneWidget);

    await tester.tap(find.text('Agnes'));
    await tester.pump();
    expect(selectedModel, 'm-1');
    expect(selectedTier, 'medium');

    await tester.tap(find.text('High'));
    await tester.pump();
    expect(selectedTier, 'high');

    await tester.tap(find.text('Manage models…'));
    expect(manageTapped, isTrue);

    await tester.tap(find.text('OK'));
    expect(doneTapped, isTrue);
  });

  testWidgets('未启用推理的模型显示提示而不是档位 chips', (tester) async {
    await tester.pumpWidget(wrap(Builder(
      builder: (context) => ModelPickerPanel(
        endpoints: const [endpoint],
        currentModelId: 'm-2',
        currentTierLevel: null,
        tc: ThemeColors.of(context),
        onModelSelected: (_, __) {},
        onTierSelected: (_) {},
        onManage: () {},
        onDone: () {},
      ),
    )));

    expect(
      find.text(
          'This model has no reasoning tiers enabled; enable them in settings'),
      findsOneWidget,
    );
    expect(find.text('High'), findsNothing);
  });
}
