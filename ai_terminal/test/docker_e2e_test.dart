import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/models/operation_report.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/ssh_service.dart';
import 'package:ai_terminal/widgets/agent_event_cards.dart';
import 'package:ai_terminal/widgets/operation_sheet.dart';

class _ScriptedAI implements AIProvider {
  final List<String> _responses;
  int _index = 0;

  _ScriptedAI(this._responses);

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    List<Map<String, dynamic>>? tools,
  }) async {
    if (_index >= _responses.length) {
      throw StateError('No scripted response left (call=${_index + 1})');
    }
    return Stream<String>.value(_responses[_index++]);
  }
}

const _planStart = '''计划:
- [x] 检查系统
- [>] 写入测试文件
- [ ] 修改并验证文件
''';

final _env = Platform.environment;
final _sshHost = _env['E2E_SSH_HOST'];
final _sshUser = _env['E2E_SSH_USER'];
final _sshPassword = _env['E2E_SSH_PASSWORD'];
final _sshPort = int.tryParse(_env['E2E_SSH_PORT'] ?? '') ?? 22;
final _sshEnabled = _sshHost?.isNotEmpty == true &&
    _sshUser?.isNotEmpty == true &&
    _sshPassword != null;
const _sshSkipReason =
    'Set E2E_SSH_HOST / E2E_SSH_PORT / E2E_SSH_USER / E2E_SSH_PASSWORD to run';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  group('Docker E2E', skip: _sshEnabled ? false : _sshSkipReason, () {
    testWidgets('real docker SSH -> engine -> operation sheet', (tester) async {
      late List<AgentEvent> events;
      late OperationReport report;

      await tester.runAsync(() async {
        final host = HostConfig.create(
          id: 'e2e-docker',
          name: 'E2E Docker',
          host: _sshHost!,
          port: _sshPort,
          username: _sshUser!,
          authType: 'password',
        );
        final ssh = SSHService(host);
        var connected = false;

        try {
          await ssh.connect(password: _sshPassword!);
          expect(ssh.isConnected, isTrue);
          connected = true;

          final provider = _ScriptedAI([
            '思考: 先查看系统版本\n$_planStart动作: execute\n命令: cat /etc/os-release\n',
            '思考: 再确认监听端口\n'
                '计划:\n- [x] 检查系统\n- [>] 写入测试文件\n- [ ] 修改并验证文件\n'
                '动作: execute\n命令: ss -lntp\n',
            '思考: 写入测试文件\n'
                '计划:\n- [x] 检查系统\n- [x] 写入测试文件\n- [>] 修改并验证文件\n'
                '动作: tool\n工具: file_write\n参数:\n'
                '  path: /tmp/ai_terminal_e2e.txt\n'
                '  content_b64: aGVsbG8Kd29ybGQK\n'
                '  mode: write\n',
            '思考: 用补丁修改文件\n'
                '计划:\n- [x] 检查系统\n- [x] 写入测试文件\n- [>] 修改并验证文件\n'
                '动作: tool\n工具: file_patch\n参数:\n'
                '  path: /tmp/ai_terminal_e2e.txt\n'
                '  old_b64: d29ybGQ=\n'
                '  new_b64: YWktdGVybWluYWwKc2Vjb25kIGxpbmU=\n',
            '思考: 读取文件确认修改\n'
                '计划:\n- [x] 检查系统\n- [x] 写入测试文件\n- [x] 修改并验证文件\n'
                '动作: execute\n命令: cat /tmp/ai_terminal_e2e.txt\n',
            '思考: 结论: 已在测试服务器完成文件写入、补丁修改和读取验证\n'
                '现状: /tmp/ai_terminal_e2e.txt 内容包含 hello、ai-terminal、second line\n'
                '变更: 写入并修改了 /tmp/ai_terminal_e2e.txt\n'
                '建议: 可以删除测试文件\n'
                '计划:\n- [x] 检查系统\n- [x] 写入测试文件\n- [x] 修改并验证文件\n'
                '动作: finish\n',
          ]);

          final modelConfig = AIModelConfig.create(
            id: 'e2e-model',
            provider: 'openai',
            name: 'E2E Model',
            apiKey: 'test-key',
            baseUrl: 'http://127.0.0.1/v1',
            modelName: 'e2e-model',
          );
          final engine = AgentEngine(
            aiProvider: provider,
            modelConfig: modelConfig,
            memory: AgentMemory(),
            maxSteps: 12,
            hostId: 'e2e-docker',
          );
          events = [];
          engine.onEvent = events.add;

          await engine.startTask(
            '在测试服务器上写入并修改 /tmp/ai_terminal_e2e.txt',
            ssh,
          );

          final reportEvent = events.where((e) => e.isReport).single;
          report = reportEvent.operationReport!;
          expect(report.finishState, 'success');
          expect(report.plan, hasLength(3));
          expect(report.plan.every((s) => s.status.name == 'completed'), isTrue);
          expect(report.stateBadges.map((b) => b.text).join(','),
              contains('端口 22 监听'));
          expect(report.verified, isTrue);

          final patchResult = events.firstWhere(
            (e) => e.isResult && e.toolName == 'file_patch',
          );
          expect(patchResult.success, isTrue);
          expect(patchResult.diffAdditions, 2);
          expect(patchResult.diffDeletions, 1);

          final catResult = events.lastWhere(
            (e) => e.isResult && e.toolName == 'exec_command',
          );
          expect(catResult.output, contains('ai-terminal'));
        } finally {
          if (connected) {
            try {
              await ssh.executeAndWait(
                'rm -f /tmp/ai_terminal_e2e.txt /tmp/ai_terminal_e2e.txt.bak.*',
              );
            } catch (_) {}
          }
          await ssh.disconnect();
        }
      });

      final evidenceEvents =
          events.where((e) => !e.isReport && !e.isFinish).toList();
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(builder: (context) {
            final tc = ThemeColors.of(context);
            return SingleChildScrollView(
              child: OperationSheet(
                report: report,
                tc: tc,
                markdownBuilder: (text, tc) => Text(text),
                hasEvidence: true,
                evidenceBuilder: () => AgentEventContent(
                  events: evidenceEvents,
                  tc: tc,
                  markdownBuilder: (text, tc) => Text(text),
                ),
              ),
            );
          }),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('测试服务器'), findsWidgets);
      expect(find.text('执行清单'), findsOneWidget);
      expect(find.text('端口 22 监听'), findsOneWidget);
      expect(find.text('过程与证据'), findsOneWidget);

      await tester.tap(find.text('过程与证据'));
      await tester.pump();
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
