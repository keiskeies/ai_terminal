import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/widgets/agent_command_block.dart';

const _blockedCmd = 'rm -f /etc/systemd/system/virt-edid.service';

Widget _host({
  required String? permissionDecision,
  String? pendingConfirmCommand,
}) {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => AgentCommandBlock(
          command: _blockedCmd,
          tc: ThemeColors.of(context),
          riskLevel: 'blocked',
          permissionDecision: permissionDecision,
          pendingConfirmCommand: pendingConfirmCommand,
          onConfirm: (_) {},
          onReject: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('blocked 等待确认时显示需确认和批准入口，不再显示已拦截', (tester) async {
    await tester.pumpWidget(_host(
      permissionDecision: 'confirm',
      pendingConfirmCommand: _blockedCmd,
    ));

    expect(find.text('Needs confirmation'), findsOneWidget);
    expect(find.text('Blocked'), findsNothing);
    expect(find.text('Run'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('自动/全自动放行的 blocked 命令显示已放行', (tester) async {
    await tester.pumpWidget(_host(permissionDecision: 'execute'));

    expect(find.text('Allowed'), findsOneWidget);
    expect(find.text('Blocked'), findsNothing);
  });

  testWidgets('只读拒绝的 blocked 命令显示已拦截', (tester) async {
    await tester.pumpWidget(_host(permissionDecision: 'reject'));

    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('Allowed'), findsNothing);
  });

  testWidgets('旧事件没有 permissionDecision 时维持已拦截', (tester) async {
    await tester.pumpWidget(_host(permissionDecision: null));

    expect(find.text('Blocked'), findsOneWidget);
  });
}
