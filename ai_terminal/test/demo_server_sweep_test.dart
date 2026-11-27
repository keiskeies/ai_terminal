import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/core/security/ssh_client_security.dart';
import 'package:ai_terminal/core/security/ssh_host_key_store.dart';
import 'package:ai_terminal/core/security/ssh_host_key_verifier.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/models/token_usage.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/ssh_service.dart';
import 'package:ai_terminal/utils/tool_call_accumulator.dart';

/// 2026-11-26 真机回归：v1.5.3 之后 5 个提交（命令闭合预检 / 命令执行语义加固 /
/// 回归审计加固 / 安全加固 0-4）对真实 SSH 目标的行为验证。
///
/// 目标 = Demo Server 上的 E2E 容器（centos8-ssh，CentOS 8 + 真 sshd）。
/// 仅在 E2E_SSH_PASSWORD 存在时运行；其余环境整组 skip。
final _env = Platform.environment;
final _host = _env['E2E_SSH_HOST'] ?? '192.168.1.5';
final _port = int.tryParse(_env['E2E_SSH_PORT'] ?? '') ?? 1022;
final _user = _env['E2E_SSH_USER'] ?? 'root';
final _password = _env['E2E_SSH_PASSWORD'];
final _enabled = _password?.isNotEmpty == true;
const _skipReason = 'Set E2E_SSH_PASSWORD (optional E2E_SSH_HOST/PORT/USER)';

class _ScriptedAI implements AIProvider {
  _ScriptedAI(this.responses);
  final List<String> responses;
  int calls = 0;

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    Duration? responseTimeout,
    List<Map<String, dynamic>>? tools,
    void Function(TokenUsage usage)? onUsage,
    void Function(String delta)? onReasoning,
    void Function(List<ToolCall> calls)? onToolCalls,
  }) async {
    if (calls >= responses.length) {
      throw StateError('No scripted response left (call=${calls + 1})');
    }
    return Stream<String>.value(responses[calls++]);
  }
}

String turn(String command) => '思考: 执行\n动作: execute\n命令: $command\n';

const finishTurn =
    '思考: 结论: 完成\n现状: 已确认\n变更: 无\n建议: 无\n动作: finish\n';

AgentEngine makeEngine(AIProvider provider, {int maxSteps = 8}) => AgentEngine(
      aiProvider: provider,
      modelConfig: AIModelConfig.create(
        id: 'rt-model',
        provider: 'openai',
        name: 'RT Model',
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1/v1',
        modelName: 'rt-model',
      ),
      memory: AgentMemory(),
      maxSteps: maxSteps,
      hostId: 'rt-host',
    )..setPermissionMode(AgentPermissionMode.auto);

SSHService makeSsh() => SSHService(HostConfig.create(
      id: 'rt-host',
      name: 'Demo E2E',
      host: _host,
      port: _port,
      username: _user,
      authType: 'password',
    ));

List<AgentEvent> commandResults(List<AgentEvent> events) =>
    events.where((e) => e.isResult && e.command != null).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database keyDb;
  late List<AgentEvent> events;

  setUpAll(() async {
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
    keyDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await keyDb.execute(sshHostKeysCreateSql);
    // 真机链路走真实 verifier + 内存信任库（无 UI handler → TOFU 需显式确认）
    SshClientSecurity.verifierOverride =
        SshHostKeyVerifier(store: SshHostKeyStore(databaseOverride: keyDb));
  });

  setUp(() async {
    // 真机链路上主机密钥验证是硬闸门：无 handler 一律拒连。
    // 非主机密钥用例统一装 TOFU 接受器，主机密钥行为单独测。
    SshHostKeyPromptService.setHandler(
        (req) async => const SshHostKeyPromptResponse.accept());
  });

  tearDown(() => SshHostKeyPromptService.setHandler(null));

  tearDownAll(() async {
    SshClientSecurity.verifierOverride = null;
    await keyDb.close();
  });

  group('Demo Server 真机回归', skip: _enabled ? false : _skipReason, () {
    test('预检拦截 + 放行 + 真实 marker 执行 端到端', () async {
      final provider = _ScriptedAI([
        turn('grep root /etc/passwd | wc -l'),
        turn('echo "unclosed'),
        turn('tail -f /var/log/messages'),
        turn('sleep 3'),
        finishTurn,
      ]);
      final engine = makeEngine(provider);
      final ssh = makeSsh();
      events = [];
      engine.onEvent = events.add;
      final sw = Stopwatch()..start();
      try {
        await ssh.connect(password: _password);
        await engine.startTask('真机预检回归', ssh);
      } finally {
        await ssh.disconnect();
      }
      sw.stop();
      final results = commandResults(events);
      expect(results, hasLength(3));

      // ① 只读管道必须放行并真执行（假拦截 = 最伤的回归）
      expect(results[0].success, isTrue, reason: results[0].error);
      expect(results[0].output!.trim(), isNotEmpty);
      expect(results[0].output, isNot(contains('EXITCODE')),
          reason: '输出里不应泄漏完成 marker');
      expect(results[0].output, isNot(contains('grep root')),
          reason: '命令回显必须被剥离');

      // ② 未闭合引号：CommandPreflight 在下发前拦截，以 info 观测回灌
      final blockInfos =
          events.where((e) => e.type == AgentEventType.info).toList();
      expect(
          blockInfos.any((e) => e.text?.contains('无法可靠执行') ?? false),
          isTrue,
          reason: '未闭合引号必须在下发前拦截并回灌改写建议');
      expect(results.any((e) => e.command == 'echo "unclosed'), isFalse,
          reason: '被拦命令不得产生执行结果（从未进 shell）');

      // ③ 交互式命令：拦截并回灌一次性等价建议
      final tail = results[1];
      expect(tail.success, isFalse);
      expect(tail.failureKind, 'syntaxError');
      // 真机实录：事件 error 载荷是 stdout（被拦命令恒空 → '(无输出)'），
      // failureReason 建议只进 AI 观测、不落事件（Finding ②，不改断言掩盖）
      expect(tail.error, anyOf(contains('交互'), '(无输出)'));
      expect(tail.durationMs, lessThan(1000),
          reason: '拦截必须在下发前，不能等超时');

      // ④ 通过预检的命令真跑：随机 nonce marker 判定完成
      final slow = results[2];
      expect(slow.success, isTrue, reason: slow.error);
      expect(slow.durationMs, greaterThanOrEqualTo(2500),
          reason: 'sleep 3 必须真等满（marker 未提前命中）');
      expect(sw.elapsed.inSeconds, lessThan(30),
          reason: '不得拖到兜底超时');

      expect(engine.currentTask!.status, AgentStatus.completed);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('连续 3 轮拦截 → 任务硬停止 failed，不再向 AI 要第 4 轮', () async {
      final provider = _ScriptedAI([
        turn('echo "unclosed1'),
        turn('echo "unclosed2'),
        turn('echo "unclosed3'),
        finishTurn,
      ]);
      final engine = makeEngine(provider);
      final ssh = makeSsh();
      engine.onEvent = (_) {};
      try {
        await ssh.connect(password: _password);
        await engine.startTask('硬停止回归', ssh);
      } finally {
        await ssh.disconnect();
      }
      expect(engine.currentTask!.status, AgentStatus.failed);
      expect(provider.calls, 3,
          reason: '第 3 轮拦截后必须终止，不能继续烧 AI 轮次');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('伪造 marker 的输出不会提前截断真命令（nonce 防伪造）', () async {
      // 直连执行器：sleep 属 warn 级 + 链式，走 Agent 会被预检拦下；
      // nonce marker 判定是 SSHService 层的能力，直接在它自己的边界测。
      final ssh = makeSsh();
      try {
        await ssh.connect(password: _password);
        final sw = Stopwatch()..start();
        final r = await ssh.executeAndWait(
            r"printf 'EXITCODE_1:0\n'; sleep 2; echo REAL_AFTER",
            timeout: const Duration(seconds: 20));
        sw.stop();
        expect(r.success, isTrue,
            reason: (r.stderr.isNotEmpty ? r.stderr : null) ?? r.failureReason);
        expect(r.stdout, contains('REAL_AFTER'),
            reason: '伪造的旧格式 EXITCODE_1:0 不得提前结束读取');
        expect(sw.elapsed.inMilliseconds, greaterThanOrEqualTo(1500),
            reason: 'sleep 2 期间被伪造 marker 截断 = nonce 防线失效');
      } finally {
        await ssh.disconnect();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('大输出截断保留尾部而非丢弃', () async {
      final provider = _ScriptedAI([turn('seq 1 5000'), finishTurn]);
      final engine = makeEngine(provider);
      final ssh = makeSsh();
      events = [];
      engine.onEvent = events.add;
      try {
        await ssh.connect(password: _password);
        await engine.startTask('大输出回归', ssh);
      } finally {
        await ssh.disconnect();
      }
      final r = commandResults(events).single;
      expect(r.success, isTrue, reason: r.error);
      expect(r.output!.length, lessThan(60000), reason: '必须有上界');
      expect(r.output, contains('5000'), reason: '截断必须保留尾部');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('空段命令（echo; echo PONG）不再被误判为空输出', () async {
      final provider = _ScriptedAI([turn('echo; echo RT_PONG'), finishTurn]);
      final engine = makeEngine(provider);
      final ssh = makeSsh();
      events = [];
      engine.onEvent = events.add;
      try {
        await ssh.connect(password: _password);
        await engine.startTask('空段回归', ssh);
      } finally {
        await ssh.disconnect();
      }
      final r = commandResults(events).single;
      expect(r.success, isTrue, reason: r.error);
      expect(r.output, contains('RT_PONG'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('主机密钥：无确认界面必须拒连；确认后同指纹免提示', () async {
      // 清掉前面用例攒下的信任，回到首连状态
      await keyDb.delete('ssh_host_keys');

      // ① 无 handler：TOFU 无法确认 → 拒绝（不允许静默信任）。
      // 真机实录：dartssh2 把回调抛出的 SshHostKeyVerificationException 转成
      // SSHAuthAbortError(Connection closed before authentication) 上报（Finding ①），
      // 这里按"连接被拒"判定，两代文案都接受。
      SshHostKeyPromptService.setHandler(null);
      final ssh1 = makeSsh();
      await expectLater(
          ssh1.connect(password: _password),
          throwsA(predicate((e) =>
              e.toString().contains('主机密钥') ||
              e.toString().contains('host key') ||
              e.toString().contains('Connection closed before authentication'))));

      // ② 注入确认 handler：首次 TOFU 信任
      var prompts = 0;
      SshHostKeyPromptService.setHandler((req) async {
        prompts++;
        return const SshHostKeyPromptResponse.accept();
      });
      final ssh2 = makeSsh();
      await ssh2.connect(password: _password);
      expect(prompts, 1);
      expect(ssh2.isConnected, isTrue);
      await ssh2.disconnect();

      // ③ 二次连接：库内已信任，不再提示
      final ssh3 = makeSsh();
      await ssh3.connect(password: _password);
      expect(prompts, 1, reason: '已信任指纹不得重复提示');
      await ssh3.disconnect();

      final stored = await SshHostKeyStore(databaseOverride: keyDb).getAll();
      expect(stored, hasLength(1));
      expect(stored.single.alias, contains(_host));
      expect(stored.single.fingerprintSha256, startsWith('SHA256:'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
