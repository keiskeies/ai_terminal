import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/local_terminal_service.dart';
import 'package:ai_terminal/services/sftp_service.dart';
import 'package:ai_terminal/services/ssh_service.dart';

/// 真实 LLM + 真实 SSH/本地文件系统的端到端测试：
/// - LLM 主动调用 sftp_upload / sftp_download 完成上传下载
/// - LLM 调用 file_patch 修改服务器文件
/// - LLM 调用 file_patch 修改本地文件（本地 executor 用 Process 替代 PTY）
///
/// 运行：
///   E2E_LLM_BASE_URL=... E2E_LLM_API_KEY=... E2E_LLM_MODEL=... \
///   E2E_SSH_HOST=... E2E_SSH_PORT=... E2E_SSH_USER=... E2E_SSH_PASSWORD=... \
///   flutter test --no-pub test/local_llm_transfer_e2e_test.dart

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

String _shq(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// 本地 executor：复用 LocalTerminalService 类型以命中工具的本地文件分支，
/// 但命令通过 Process 执行（测试环境没有 Flutter 插件，无法启动 PTY）。
class _LocalProcessExecutor extends LocalTerminalService {
  @override
  bool get isConnected => true;

  @override
  Stream<String> get output => const Stream.empty();

  @override
  void execute(String command) {}

  @override
  void writeToTerminal(String data) {}

  @override
  Future<String> runOnce(String command,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final result = await executeAndWait(command, timeout: timeout);
    return result.stdout;
  }

  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run('cmd', ['/c', command]).timeout(timeout);
      } else {
        result = await Process.run('bash', ['-lc', command]).timeout(timeout);
      }
      return CommandResult(
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
        exitCode: result.exitCode,
        duration: stopwatch.elapsed,
      );
    } on TimeoutException {
      return CommandResult(
        stdout: '',
        stderr: '本地命令超时',
        exitCode: -1,
        duration: stopwatch.elapsed,
        timedOut: true,
      );
    }
  }

  @override
  Future<CommandResult> writeFileViaPty({
    required String path,
    required Uint8List content,
    bool useSudo = false,
    Duration timeout = const Duration(seconds: 30),
    Completer<void>? cancelToken,
  }) async {
    return CommandResult(
      stdout: '',
      stderr: '测试 executor 不支持 PTY 写文件',
      exitCode: -1,
      duration: Duration.zero,
      failureKind: CommandFailureKind.unknown,
      failureReason: '测试 executor 不支持 PTY 写文件',
    );
  }
}

Future<List<AgentEvent>> _runAgent({
  required String goal,
  required CommandExecutor executor,
  required String hostId,
  int maxSteps = 10,
}) async {
  final engine = AgentEngine(
    aiProvider: OpenAIProvider(),
    modelConfig: AIModelConfig.create(
      id: hostId,
      provider: 'openai',
      name: hostId,
      apiKey: _llmKey!,
      baseUrl: _llmBase!,
      modelName: _llmModel!,
      maxTokens: 2048,
      supportsFunctionCalling: false,
    ),
    memory: AgentMemory(),
    maxSteps: maxSteps,
    hostId: hostId,
  );
  final events = <AgentEvent>[];
  engine.onEvent = events.add;

  final running = engine.startTask(goal, executor);
  final timeout = Completer<bool>();
  final timer = Timer(const Duration(minutes: 4), () {
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
  return events;
}

List<AgentEvent> _toolResults(List<AgentEvent> events, String toolName) =>
    events.where((e) => e.isResult && e.toolName == toolName).toList();

void _dumpFailures(List<AgentEvent> events) {
  for (final e in events) {
    if (e.isResult && e.success != true) {
      // ignore: avoid_print
      print('TOOL_FAIL: ${e.toolName} ${e.output}');
    }
    if (e.isReport) {
      // ignore: avoid_print
      print('REPORT: ${e.operationReport?.finishState} '
          '${e.operationReport?.conclusion}');
    }
  }
}

void main() {
  setUpAll(() {
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  group('Real LLM file transfer E2E', skip: _enabled ? false : _skipReason, () {
    late SSHService ssh;
    late Directory localRoot;
    const remoteRoot = '/tmp/ai_terminal_llm_transfer_e2e';

    setUpAll(() async {
      ssh = SSHService(HostConfig.create(
        id: 'llm-transfer-e2e',
        name: 'LLM Transfer E2E',
        host: _sshHost!,
        port: _sshPort,
        username: _sshUser!,
        authType: 'password',
      ));
      await ssh.connect(password: _sshPassword!);
      await ssh.executeAndWait('rm -rf ${_shq(remoteRoot)}');
      await ssh.executeAndWait('mkdir -p ${_shq(remoteRoot)}');
      localRoot = await Directory.systemTemp.createTemp('ai_terminal_llm_transfer_');
    });

    tearDownAll(() async {
      try {
        if (ssh.isConnected) {
          await ssh.executeAndWait('rm -rf ${_shq(remoteRoot)}');
        }
      } catch (_) {}
      try {
        await ssh.disconnect();
      } catch (_) {}
      try {
        if (localRoot.existsSync()) {
          await localRoot.delete(recursive: true);
        }
      } catch (_) {}
    });

    Future<Uint8List> readRemote(String path) async {
      final sftp = SftpService();
      await sftp.attachToClient(ssh.client!);
      try {
        return await sftp.readFileBytes(path, maxSize: 8 * 1024 * 1024);
      } finally {
        sftp.closeSftpOnly();
      }
    }

    test('real LLM uploads and downloads a file with sftp tools', () async {
      final localDir = Directory(p.join(localRoot.path, 'LLM 上传 本地 😀'));
      await localDir.create(recursive: true);
      final localSource = p.join(localDir.path, '源文件 😀.txt');
      const remotePath = '$remoteRoot/LLM 服务器 文件 😀.txt';
      final localDownload = p.join(localDir.path, '下载回来 😀.txt');
      const content = '第一行：LLM 传输中文 😀\r\n'
          '第二行：特殊字符 \$HOME `id` & ;\r\n'
          '第三行：无尾换行';
      final bytes = utf8.encode(content);
      await File(localSource).writeAsBytes(bytes, flush: true);

      final goal = '在测试服务器上完成一次文件上传和下载，必须使用工具而不是 shell 命令：\n'
          '1) 使用 sftp_upload 工具，把本地文件「$localSource」上传到远程路径「$remotePath」'
          '（local=$localSource, remote=$remotePath）。\n'
          '2) 使用 sftp_download 工具，把远程路径「$remotePath」下载到本地路径「$localDownload」'
          '（remote=$remotePath, local=$localDownload）。\n'
          '3) 不要用 shell 的 scp/cp/cat/echo 写文件，直接执行，完成后用 finish 总结。';

      final events =
          await _runAgent(goal: goal, executor: ssh, hostId: 'llm-transfer-e2e');

      final uploads = _toolResults(events, 'sftp_upload');
      final downloads = _toolResults(events, 'sftp_download');
      if (uploads.every((e) => e.success != true) ||
          downloads.every((e) => e.success != true)) {
        _dumpFailures(events);
      }

      expect(uploads, isNotEmpty, reason: '模型没有调用 sftp_upload');
      expect(uploads.any((e) => e.success == true), isTrue,
          reason: 'sftp_upload 未成功');
      expect(downloads, isNotEmpty, reason: '模型没有调用 sftp_download');
      expect(downloads.any((e) => e.success == true), isTrue,
          reason: 'sftp_download 未成功');

      expect(await readRemote(remotePath), bytes);
      final downloaded = File(localDownload);
      expect(downloaded.existsSync(), isTrue);
      expect(await downloaded.readAsBytes(), bytes);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('real LLM patches a server file with file_patch', () async {
      const remotePath = '$remoteRoot/llm_patch_服务器.conf';
      final original = utf8.encode(
        '第一行：保留中文 😀\n'
        'listen 80;\n'
        '第三行：保留 ✅\n',
      );

      final sftp = SftpService();
      await sftp.attachToClient(ssh.client!);
      try {
        await sftp.writeFileBytes(remotePath, Uint8List.fromList(original));
      } finally {
        sftp.closeSftpOnly();
      }

      const goal = '修改测试服务器上的远程文件「$remotePath」：\n'
          '把其中的 "listen 80;" 这一行改成 "listen 8080;"。\n'
          '必须使用 file_patch 工具（path=$remotePath，old_b64/new_b64 用原文 UTF-8 的 base64），'
          '不要用 file_write 整体重写，不要用 shell 的 sed/echo。\n'
          '其他行必须原样保留。完成后用 cat 验证，再用 finish 总结，不要询问用户。';

      final events =
          await _runAgent(goal: goal, executor: ssh, hostId: 'llm-patch-e2e');

      final patches = _toolResults(events, 'file_patch');
      if (patches.every((e) => e.success != true)) {
        _dumpFailures(events);
      }
      expect(patches, isNotEmpty, reason: '模型没有调用 file_patch');
      expect(patches.any((e) => e.success == true), isTrue,
          reason: 'file_patch 未成功');

      final bytes = await readRemote(remotePath);
      final text = utf8.decode(bytes);
      expect(text, contains('listen 8080;'));
      expect(text, isNot(contains('listen 80;')));
      expect(text, contains('第一行：保留中文 😀'));
      expect(text, contains('第三行：保留 ✅'));
      expect(text, isNot(contains('�')));
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('real LLM patches a local file with file_patch', () async {
      final localDir = Directory(p.join(localRoot.path, 'LLM 本地编辑 😀'));
      await localDir.create(recursive: true);
      final localPath = p.join(localDir.path, '本地 配置.txt');
      const original = '配置开始\nname = 旧值\n结束 ✅\n';
      await File(localPath).writeAsString(original, encoding: utf8);

      final goal = '修改本地文件「$localPath」：\n'
          '把其中的 "name = 旧值" 改成 "name = 新值 😀"。\n'
          '必须使用 file_patch 工具（path=$localPath，用 old 和 new 纯文本参数，'
          '不要自己计算 base64），不要用 file_write 整体重写，不要执行任何 shell 命令。\n'
          '其他内容必须原样保留。完成后直接用 finish 动作总结，不要询问用户。';

      final events = await _runAgent(
        goal: goal,
        executor: _LocalProcessExecutor(),
        hostId: 'llm-local-patch-e2e',
        maxSteps: 6,
      );

      final patches = _toolResults(events, 'file_patch');
      if (patches.every((e) => e.success != true)) {
        _dumpFailures(events);
      }
      expect(patches, isNotEmpty, reason: '模型没有调用 file_patch');
      expect(patches.any((e) => e.success == true), isTrue,
          reason: '本地 file_patch 未成功');

      final text = await File(localPath).readAsString(encoding: utf8);
      expect(text, contains('name = 新值 😀'));
      expect(text, contains('配置开始'));
      expect(text, contains('结束 ✅'));
      expect(text, isNot(contains('name = 旧值')));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
