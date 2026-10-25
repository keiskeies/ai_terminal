import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/host_execution_result.dart';
import 'package:ai_terminal/widgets/agent_event_cards.dart';
import 'package:ai_terminal/widgets/host_result_matrix.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  group('HostExecutionResult JSON', () {
    test('round-trip preserves fields', () {
      const result = HostExecutionResult(
        hostId: 'web-01',
        success: false,
        output: 'partial',
        error: 'permission denied',
        exitCode: 126,
        durationMs: 1200,
        failureKind: 'permissionDenied',
      );
      final restored = HostExecutionResult.fromJson(result.toJson());
      expect(restored.hostId, 'web-01');
      expect(restored.success, isFalse);
      expect(restored.error, 'permission denied');
      expect(restored.exitCode, 126);
      expect(restored.durationMs, 1200);
      expect(restored.failureKind, 'permissionDenied');
    });
  });

  group('HostResultMatrix', () {
    Map<String, HostExecutionResult> results() => const {
          'web-01': HostExecutionResult(
            hostId: 'web-01',
            success: true,
            output: 'ok',
            exitCode: 0,
            durationMs: 1000,
          ),
          'web-02': HostExecutionResult(
            hostId: 'web-02',
            success: true,
            output: 'ok',
            exitCode: 0,
            durationMs: 1500,
          ),
          'web-03': HostExecutionResult(
            hostId: 'web-03',
            success: false,
            error: 'permission denied\nplease use sudo',
            exitCode: 126,
            durationMs: 800,
            failureKind: 'permissionDenied',
          ),
        };

    testWidgets('shows per-host status and expands details', (tester) async {
      List<String>? retriedHosts;
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => HostResultMatrix(
          results: results(),
          tc: ThemeColors.of(context),
          onRetryFailedHosts: (ids) => retriedHosts = ids,
        ),
      )));

      expect(find.text('3 台主机 · 2 成功 · 1 失败'), findsOneWidget);
      expect(find.text('web-01'), findsOneWidget);
      expect(find.text('web-03'), findsOneWidget);
      expect(find.textContaining('权限不足'), findsOneWidget);
      expect(find.textContaining('退出码 126'), findsOneWidget);

      expect(find.text('重试失败主机'), findsOneWidget);
      await tester.tap(find.text('重试失败主机'));
      expect(retriedHosts, ['web-03']);

      await tester.tap(find.text('web-03'));
      await tester.pump();

      expect(find.textContaining('please use sudo'), findsOneWidget);
    });

    testWidgets('does not overflow at 360px', (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => HostResultMatrix(
          results: results(),
          tc: ThemeColors.of(context),
        ),
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('result card uses matrix for multi-host results',
        (tester) async {
      final command = AgentEvent.command(
        'exec_batch',
        id: 'cmd-batch',
        toolName: 'exec_batch',
      );
      final result = AgentEvent.result(
        commandId: 'cmd-batch',
        success: false,
        command: 'exec_batch',
        output: 'aggregate text',
        hostResults: results(),
      );

      List<String>? retriedHosts;
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => AgentEventContent(
          events: [command, result],
          tc: ThemeColors.of(context),
          markdownBuilder: (text, tc) => Text(text),
          onRetryFailedHosts: (ids) => retriedHosts = ids,
        ),
      )));

      expect(find.text('3 台主机 · 2 成功 · 1 失败'), findsOneWidget);
      expect(find.text('web-02'), findsOneWidget);
      await tester.tap(find.text('重试失败主机'));
      expect(retriedHosts, ['web-03']);
    });
  });
}
