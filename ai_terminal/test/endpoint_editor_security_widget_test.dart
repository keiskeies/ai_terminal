import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/ai_endpoint.dart';
import 'package:ai_terminal/widgets/endpoint_editor_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() {
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  testWidgets('模型拉取拒绝非回环 HTTP 并恢复按钮状态', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: EndpointEditorForm(
            initial: const AIEndpoint(
              id: 'endpoint-security-test',
              providerId: 'custom',
              name: 'Test',
              baseUrl: 'http://api.example.com/v1',
              protocol: 'openai',
              apiKey: 'sk-test',
              models: [
                AIEndpointModel(id: 'model-1', name: 'Test', modelName: 'test'),
              ],
              createdAt: 1,
            ),
            onSave: (_) async {},
            onCancel: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('从服务商拉取'));
    await tester.pumpAndSettle();

    expect(find.textContaining('AI 凭据不得通过非回环 HTTP 发送'), findsOneWidget);
    expect(find.text('从服务商拉取'), findsOneWidget);
    expect(find.text('拉取中…'), findsNothing);
  });
}
