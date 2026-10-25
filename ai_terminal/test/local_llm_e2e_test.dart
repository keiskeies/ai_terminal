import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/sftp_service.dart';
import 'package:ai_terminal/services/ssh_service.dart';

Future<Uint8List> _readBytes(SSHService ssh, String path) async {
  final sftp = SftpService();
  await sftp.attachToClient(ssh.client!);
  try {
    return await sftp.readFileBytes(path);
  } finally {
    sftp.closeSftpOnly();
  }
}

final _env = Platform.environment;
final _llmBase = _env['E2E_LLM_BASE_URL'];
final _llmKey = _env['E2E_LLM_API_KEY'];
final _llmModel = _env['E2E_LLM_MODEL'];
final _sshHost = _env['E2E_SSH_HOST'];
final _sshUser = _env['E2E_SSH_USER'];
final _sshPassword = _env['E2E_SSH_PASSWORD'];
final _sshPort = int.tryParse(_env['E2E_SSH_PORT'] ?? '') ?? 22;
final _enabled = _llmBase?.isNotEmpty == true &&
    _llmKey?.isNotEmpty == true &&
    _llmModel?.isNotEmpty == true &&
    _sshHost?.isNotEmpty == true &&
    _sshUser?.isNotEmpty == true &&
    _sshPassword != null;
const _skipReason =
    'Set E2E_LLM_BASE_URL / E2E_LLM_API_KEY / E2E_LLM_MODEL and E2E_SSH_* to run';

void main() {
  setUpAll(() {
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  group('Local LLM E2E', skip: _enabled ? false : _skipReason, () {
    test('real LLM + docker SSH -> report', () async {
      final host = HostConfig.create(
        id: 'local-llm-e2e',
        name: 'Local LLM E2E',
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

        final modelConfig = AIModelConfig.create(
          id: 'local-llm-e2e',
          provider: 'openai',
          name: 'Local LLM E2E',
          apiKey: _llmKey!,
          baseUrl: _llmBase!,
          modelName: _llmModel!,
          maxTokens: 2048,
          supportsFunctionCalling: false,
        );
        final engine = AgentEngine(
          aiProvider: OpenAIProvider(),
          modelConfig: modelConfig,
          memory: AgentMemory(),
          maxSteps: 8,
          hostId: 'local-llm-e2e',
        );
        final events = <AgentEvent>[];
        engine.onEvent = events.add;

        const goal = '在测试服务器上检查系统版本和监听端口：'
            '1) 用 cat /etc/os-release 查看系统版本；'
            '2) 用 ss -lntp 查看监听端口；'
            '3) 用 finish 动作，并按四段式总结（结论/现状/变更/建议）。'
            '请使用“计划:”块跟踪进度，按 ReAct 格式回复，不要询问用户，直接执行。';

        final running = engine.startTask(goal, ssh);
        final timeout = Completer<bool>();
        final timer = Timer(const Duration(minutes: 3), () {
          if (!timeout.isCompleted) timeout.complete(false);
        });
        running.whenComplete(() {
          if (!timeout.isCompleted) timeout.complete(true);
          timer.cancel();
        });
        final finished = await timeout.future;
        timer.cancel();
        if (!finished) {
          engine.cancelTask();
          await running;
        }

        final reportEvents = events.where((e) => e.isReport).toList();
        expect(reportEvents, isNotEmpty);
        final report = reportEvents.last.operationReport!;

        // ignore: avoid_print
        print('E2E_FINISH: ${report.finishState}');
        // ignore: avoid_print
        print('E2E_CONCLUSION: ${report.conclusion}');
        // ignore: avoid_print
        print(
            'E2E_PLAN: ${report.plan.map((s) => '${s.status.name}:${s.title}').join(' | ')}');
        // ignore: avoid_print
        print('E2E_BADGES: ${report.stateBadges.map((b) => b.text).join(', ')}');

        expect(report.finishState, 'success');
        expect(report.conclusion.trim(), isNotEmpty);
        expect(events.any((e) => e.isResult && e.success == true), isTrue);
        expect(report.plan, isNotEmpty);
        expect(report.stateBadges.map((b) => b.text).join(','),
            contains('端口 22 监听'));
      } finally {
        if (connected) {
          try {
            await ssh.executeAndWait('rm -f /tmp/ai_terminal_llm_e2e.txt');
          } catch (_) {}
        }
        await ssh.disconnect();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('real LLM writes Chinese/emoji file on server', () async {
      final ssh = SSHService(HostConfig.create(
        id: 'local-llm-cn',
        name: 'Local LLM CN',
        host: _sshHost!,
        port: _sshPort,
        username: _sshUser!,
        authType: 'password',
      ));
      var connected = false;
      const path = '/tmp/ai_terminal_llm_cn.txt';

      try {
        await ssh.connect(password: _sshPassword!);
        expect(ssh.isConnected, isTrue);
        connected = true;
        await ssh.executeAndWait('rm -f $path');

        final modelConfig = AIModelConfig.create(
          id: 'local-llm-cn',
          provider: 'openai',
          name: 'Local LLM CN',
          apiKey: _llmKey!,
          baseUrl: _llmBase!,
          modelName: _llmModel!,
          maxTokens: 2048,
          supportsFunctionCalling: false,
        );
        final engine = AgentEngine(
          aiProvider: OpenAIProvider(),
          modelConfig: modelConfig,
          memory: AgentMemory(),
          maxSteps: 8,
          hostId: 'local-llm-cn',
        );
        final events = <AgentEvent>[];
        engine.onEvent = events.add;

        const goal = '在测试服务器上创建 $path（路径不要改），内容必须严格为以下三行，不要增删：\n'
            '第一行：中文测试\n'
            '第二行：emoji 😀🚀\n'
            '第三行：结束\n'
            '请使用 file_write 工具的 content 纯文本参数写入（整个 content 写在一行，'
            '用 \\n 表示换行），不要使用 content_b64，不要自己计算 base64。'
            '写完后用 cat 验证并 finish，不要询问用户，直接执行。';

        final running = engine.startTask(goal, ssh);
        final timeout = Completer<bool>();
        final timer = Timer(const Duration(minutes: 3), () {
          if (!timeout.isCompleted) timeout.complete(false);
        });
        running.whenComplete(() {
          if (!timeout.isCompleted) timeout.complete(true);
          timer.cancel();
        });
        final finished = await timeout.future;
        timer.cancel();
        if (!finished) {
          engine.cancelTask();
          await running;
        }

        final reportEvents = events.where((e) => e.isReport).toList();
        expect(reportEvents, isNotEmpty);
        final report = reportEvents.last.operationReport!;
        // ignore: avoid_print
        print('CN_FINISH: ${report.finishState}');
        // ignore: avoid_print
        print('CN_CONCLUSION: ${report.conclusion}');

        final bytes = await _readBytes(ssh, path);
        final text = utf8.decode(bytes); // strict UTF-8 decode
        // ignore: avoid_print
        print('CN_FILE_BYTES: ${bytes.length}');
        // ignore: avoid_print
        print('CN_FILE:\n$text');

        final normalized = text.replaceAll('\r\n', '\n');
        // 模型可能省略“第 N 行：”前缀；编码测试关注中文/emoji 是否原样落盘
        expect(normalized, contains('中文测试'));
        expect(normalized, contains('emoji 😀🚀'));
        expect(normalized, contains('结束'));
        expect(text, isNot(contains('�')));
        expect(
          bytes.length >= 3 &&
              bytes[0] == 0xEF &&
              bytes[1] == 0xBB &&
              bytes[2] == 0xBF,
          isFalse,
          reason: 'file should not gain a UTF-8 BOM',
        );
      } finally {
        if (connected) {
          try {
            await ssh.executeAndWait('rm -f $path');
          } catch (_) {}
        }
        await ssh.disconnect();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
