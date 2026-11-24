import 'dart:async';
import 'dart:io';

import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/models/agent_state.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/agent_host_registry.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/change_window_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/services/multi_host_executor.dart';
import 'package:ai_terminal/services/sftp_service.dart';
import 'package:ai_terminal/services/ssh_service.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _RecordingSsh extends SSHService {
  _RecordingSsh(String hostId)
      : super(HostConfig.create(
          id: hostId,
          name: hostId,
          host: '127.0.0.1',
          username: 'tester',
          authType: 'password',
        ));

  final commands = <String>[];
  final seenCancelTokens = <Completer<void>?>[];
  final results = <CommandResult>[];
  int active = 0;
  int maxActive = 0;
  Duration delay = Duration.zero;
  String operatingSystem = 'Linux';
  void Function(bool entering)? onActivity;

  @override
  bool get isConnected => true;

  @override
  String get osInfo => operatingSystem;

  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
    String? sudoPassword,
    Future<String?> Function(String prompt)? onInteractivePrompt,
  }) async {
    commands.add(command);
    seenCancelTokens.add(cancelToken);
    active++;
    onActivity?.call(true);
    if (active > maxActive) maxActive = active;
    final completion = Completer<CommandResult>();
    Timer? timer;
    void finish(CommandResult result) {
      if (completion.isCompleted) return;
      completion.complete(result);
    }

    CommandResult nextResult() => results.isEmpty
        ? CommandResult(
            stdout: 'ok', stderr: '', exitCode: 0, duration: Duration.zero)
        : results.removeAt(0);
    if (cancelToken?.isCompleted == true) {
      finish(_result(
        exitCode: -1,
        failureReason: 'cancelled',
        failureKind: CommandFailureKind.cancelled,
      ));
    } else {
      if (delay > Duration.zero) {
        timer = Timer(delay, () => finish(nextResult()));
      } else {
        finish(nextResult());
      }
      cancelToken?.future.then(
        (_) => finish(_result(
          exitCode: -1,
          failureReason: 'cancelled',
          failureKind: CommandFailureKind.cancelled,
        )),
        onError: (Object error) => finish(_result(
          exitCode: -1,
          failureReason: '$error',
          failureKind: CommandFailureKind.unknown,
        )),
      );
    }
    try {
      return await completion.future;
    } finally {
      timer?.cancel();
      active--;
      onActivity?.call(false);
    }
  }
}

CommandResult _result({
  String stdout = '',
  String stderr = '',
  int exitCode = 0,
  String? failureReason,
  CommandFailureKind failureKind = CommandFailureKind.none,
}) =>
    CommandResult(
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      duration: Duration.zero,
      failureReason: failureReason,
      failureKind: failureKind,
    );

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

void main() {
  late Directory temp;
  late Directory allowed;
  late Directory outside;
  late AgentHostRegistry registry;
  late MultiHostExecutor multi;
  late _RecordingSsh disconnected;

  Future<void> configurePolicy(List<String> roots) async {
    await SettingsDao.set('localFilePolicy', {
      'enabled': true,
      'allowedDirs': roots,
      'maxReadBytes': 2 * 1024 * 1024,
    });
  }

  Future<ToolResult> run(
    AgentTool tool,
    Map<String, dynamic> args, {
    CommandExecutor? executor,
  }) =>
      tool.execute(
        executor: executor ?? disconnected,
        args: ToolArgs(args),
      );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ai_tool_security_');
    allowed = Directory(p.join(temp.path, 'allowed'))..createSync();
    outside = Directory(p.join(temp.path, 'outside'))..createSync();
    await configurePolicy([allowed.path]);
    await ChangeWindowService.save(const ChangeWindowConfig(enabled: false));
    registry = AgentHostRegistry();
    multi = MultiHostExecutor(registry);
    disconnected = _RecordingSsh('disconnected');
  });

  tearDown(() async {
    disconnected.dispose();
    registry.dispose();
    await configurePolicy([]);
    await ChangeWindowService.save(const ChangeWindowConfig(enabled: false));
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('本地路径策略与无 I/O 拒绝', () {
    test('sftp_download 在连接和创建目标前拒绝白名单外路径', () async {
      final target = p.join(outside.path, 'new', 'download.txt');
      final result = await run(SftpDownloadTool(), {
        'remote': '/remote/file.txt',
        'local': target,
      });
      expect(result.success, isFalse);
      expect(result.error, contains('未获授权'));
      expect(await File(target).exists(), isFalse);
      expect(await Directory(p.dirname(target)).exists(), isFalse);
    });

    test('sftp_upload / upload_to / broadcast_upload 拒绝白名单外源文件', () async {
      final source = File(p.join(outside.path, 'secret.txt'))
        ..writeAsStringSync('secret');
      final results = await Future.wait([
        run(SftpUploadTool(), {'local': source.path, 'remote': '/tmp/x'}),
        run(UploadToTool(multi), {
          'hostId': 'missing',
          'local': source.path,
          'remote': '/tmp',
        }),
        run(BroadcastUploadTool(multi), {
          'hostIds': ['h1', 'h2'],
          'local': source.path,
          'remote': '/tmp',
        }),
      ]);
      for (final result in results) {
        expect(result.success, isFalse);
        expect(result.error, contains('未获授权'));
      }
    });

    test('目录上传逐个文件预检，敏感嵌套文件不会走到远程连接', () async {
      final root = Directory(p.join(allowed.path, 'upload'))..createSync();
      File(p.join(root.path, 'ok.txt')).writeAsStringSync('ok');
      File(p.join(root.path, '.env')).writeAsStringSync('SECRET=1');
      final result = await run(UploadToTool(multi), {
        'hostId': 'missing',
        'local': root.path,
        'remote': '/tmp',
        'recursive': true,
      });
      expect(result.success, isFalse);
      expect(result.error, contains('未获授权'));
      expect(result.error, contains('.env'));
      expect(result.error, isNot(contains('未连接')));
    });

    test('collect_file 检查 localDir 且拒绝时不创建目录', () async {
      final root = p.join(outside.path, 'collected');
      final result = await run(CollectFileTool(multi), {
        'hostIds': ['h1'],
        'remote': '/remote/app.log',
        'localDir': root,
      });
      expect(result.success, isFalse);
      expect(result.error, contains('未获授权'));
      expect(await Directory(root).exists(), isFalse);
    });

    test('collect_file 在创建目录前检查每个最终文件', () async {
      final root = p.join(allowed.path, 'new-collect');
      final result = await run(CollectFileTool(multi), {
        'hostIds': ['h1'],
        'remote': '/remote/private.key',
        'localDir': root,
      });
      expect(result.success, isFalse);
      expect(result.error, contains('未获授权'));
      expect(await Directory(root).exists(), isFalse);
    });

    test('目录下载清单检查目标根和嵌套最终路径', () async {
      var listed = false;
      final deniedRoot =
          await SftpDownloadTool.validateDirectoryDownloadPathsForTest(
        remoteDir: '/remote',
        localRoot: outside.path,
        listDirectory: (_) async {
          listed = true;
          return [];
        },
      );
      expect(deniedRoot, contains('未获授权'));
      expect(listed, isFalse);

      final root = p.join(allowed.path, 'new-download');
      final nestedDenied =
          await SftpDownloadTool.validateDirectoryDownloadPathsForTest(
        remoteDir: '/remote',
        localRoot: root,
        listDirectory: (_) async => [
          SftpEntry(name: '.env', path: '/remote/.env', isDirectory: false),
        ],
      );
      expect(nestedDenied, contains('未获授权'));
      expect(nestedDenied, contains('.env'));
      expect(await Directory(root).exists(), isFalse);
    });
  });

  group('工具副作用元数据', () {
    test('collect_file 是 write，exec_on/exec_batch 是 destructive', () {
      expect(CollectFileTool(multi).kind, ToolKind.write);
      expect(CollectFileTool(multi).isReadOnly, isFalse);
      expect(ExecOnTool(multi).kind, ToolKind.destructive);
      expect(ExecBatchTool(multi).kind, ToolKind.destructive);
      expect(ExecOnTool(multi).recordsChanges, isTrue);
      expect(ExecBatchTool(multi).recordsChanges, isTrue);
    });
  });

  group('MultiHostExecutor 每条命令预检', () {
    test('blocked、只读、链式修改、未闭合和交互命令均不派发', () async {
      final cases = <({
        String command,
        AgentPermissionMode mode,
        CommandFailureKind kind
      })>[
        (
          command: 'rm -rf /',
          mode: AgentPermissionMode.fullAuto,
          kind: CommandFailureKind.permissionDenied
        ),
        (
          command: 'rm /tmp/a',
          mode: AgentPermissionMode.readOnly,
          kind: CommandFailureKind.permissionDenied
        ),
        (
          command: 'echo ok && rm /tmp/a',
          mode: AgentPermissionMode.fullAuto,
          kind: CommandFailureKind.permissionDenied
        ),
        (
          command: "echo 'unterminated",
          mode: AgentPermissionMode.fullAuto,
          kind: CommandFailureKind.syntaxError
        ),
        (
          command: 'top',
          mode: AgentPermissionMode.fullAuto,
          kind: CommandFailureKind.interactivePrompt
        ),
        (
          command: 'tail -f /tmp/a',
          mode: AgentPermissionMode.fullAuto,
          kind: CommandFailureKind.interactivePrompt
        ),
      ];
      for (final item in cases) {
        final executor = _RecordingSsh(item.command);
        registry.setExecutor('h', executor);
        final result = await multi.executeOn(
          'h',
          item.command,
          permissionMode: item.mode,
        );
        expect(result, isNotNull);
        expect(result!.success, isFalse, reason: item.command);
        expect(result.failureKind, item.kind, reason: item.command);
        expect(executor.commands, isEmpty, reason: item.command);
        executor.dispose();
      }
    });

    test('权限档位绑定归属 tab，不随活跃 tab 漂移', () async {
      final executor = _RecordingSsh('h1');
      registry.setScopeHost('task-tab', 'h1');
      registry.setScopeExecutor('task-tab', executor);
      registry.setScopeHost('other-tab', 'h2');
      registry.setActive('other-tab');
      registry.setState('other-tab',
          AgentState(permissionMode: AgentPermissionMode.fullAuto));

      // 归属引擎为只读，而当时的活跃 tab 是全自动：必须以归属档位为准。
      final bound = MultiHostExecutor(registry,
          permissionModeProvider: () => AgentPermissionMode.readOnly);
      final blocked = await bound.executeOn('h1', 'rm /tmp/a');
      expect(blocked, isNotNull);
      expect(blocked!.success, isFalse);
      expect(blocked.failureKind, CommandFailureKind.permissionDenied);
      expect(executor.commands, isEmpty);

      // 未注入归属档位时回退到活跃 tab（全自动），同一条命令会派发。
      final fallback = MultiHostExecutor(registry);
      final allowed = await fallback.executeOn('h1', 'rm /tmp/a');
      expect(allowed, isNotNull);
      expect(allowed!.success, isTrue);
      expect(executor.commands, ['rm /tmp/a']);

      // 活跃 tab 改成只读也不影响已绑定的任务档位。
      registry.setState('other-tab',
          AgentState(permissionMode: AgentPermissionMode.readOnly));
      final stillBlocked = await bound.executeOn('h1', 'rm /tmp/b');
      expect(stillBlocked!.success, isFalse);
      expect(stillBlocked.failureKind, CommandFailureKind.permissionDenied);
      expect(executor.commands, ['rm /tmp/a']);

      executor.dispose();
    });

    test('stopOnFailure 标记 skipped 而不是 cancelled', () async {
      final failing = _RecordingSsh('h1');
      failing.results.add(_result(exitCode: 1, stderr: 'boom'));
      final untouched = _RecordingSsh('h2');
      registry.setExecutor('h1', failing);
      registry.setExecutor('h2', untouched);

      final results = await multi.executeBatch(
        ['h1', 'h2'],
        'chmod 600 /tmp/x',
        stopOnFailure: true,
      );
      expect(results['h1']!.success, isFalse);
      expect(results['h2']!.success, isFalse);
      expect(results['h2']!.failureKind, CommandFailureKind.skipped);
      expect(untouched.commands, isEmpty);

      failing.dispose();
      untouched.dispose();
    });

    test('模型传入的 timeout 被夹到 1..600 秒', () {
      expect(MultiHostExecutor.clampTimeoutSeconds(0), 1);
      expect(MultiHostExecutor.clampTimeoutSeconds(-5), 1);
      expect(MultiHostExecutor.clampTimeoutSeconds(60), 60);
      expect(MultiHostExecutor.clampTimeoutSeconds(99999), 600);
    });

    test('后台续行与末尾注释续行使用共享预检且不派发', () async {
      final executor = _RecordingSsh('posix-reliability');
      registry.setExecutor('h', executor);
      const commands = [
        'echo ok \\\n&',
        'echo ok\n# note \\',
      ];
      for (final command in commands) {
        final result = await multi.executeOn(
          'h',
          command,
          permissionMode: AgentPermissionMode.fullAuto,
        );
        expect(result!.failureKind, CommandFailureKind.syntaxError,
            reason: command);
        expect(result.failureReason, contains('命令无法可靠执行'));
      }
      expect(executor.commands, isEmpty);
      executor.dispose();
    });

    test('封网期拒绝修改命令但允许只读命令', () async {
      final now = DateTime.now();
      await ChangeWindowService.save(ChangeWindowConfig(
        enabled: true,
        startHour: 0,
        endHour: 0,
        allowedWeekdays: [now.weekday % 7 + 1],
      ));
      final executor = _RecordingSsh('window');
      registry.setExecutor('h', executor);
      final blocked = await multi.executeOn('h', 'rm /tmp/a');
      expect(blocked!.success, isFalse);
      expect(blocked.failureReason, contains('封网'));
      expect(executor.commands, isEmpty);
      final safe = await multi.executeOn('h', 'echo ok');
      expect(safe!.success, isTrue);
      expect(executor.commands, ['echo ok']);
      executor.dispose();
    });

    test('executeBatch 保留 safe 并行、修改命令串行', () async {
      var concurrent = 0;
      var maxConcurrent = 0;
      void observe(bool entering) {
        concurrent += entering ? 1 : -1;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
      }

      final a = _RecordingSsh('a')
        ..delay = const Duration(milliseconds: 25)
        ..onActivity = observe;
      final b = _RecordingSsh('b')
        ..delay = const Duration(milliseconds: 25)
        ..onActivity = observe;
      registry
        ..setExecutor('a', a)
        ..setExecutor('b', b);
      final parallel = await multi.executeBatch(['a', 'b'], 'echo ok');
      expect(parallel.values.every((r) => r.success), isTrue);
      expect(maxConcurrent, 2, reason: 'safe 命令必须并行');

      concurrent = 0;
      maxConcurrent = 0;
      final serialA = _RecordingSsh('serial-a')
        ..delay = const Duration(milliseconds: 25)
        ..onActivity = observe;
      final serialB = _RecordingSsh('serial-b')
        ..delay = const Duration(milliseconds: 25)
        ..onActivity = observe;
      registry
        ..setExecutor('a', serialA)
        ..setExecutor('b', serialB);
      final serial = await multi.executeBatch(['a', 'b'], 'rm /tmp/a');
      expect(serial.values.every((r) => r.success), isTrue);
      expect(maxConcurrent, 1, reason: '修改命令必须串行');
      expect(serialA.commands, hasLength(1));
      expect(serialB.commands, hasLength(1));
      for (final executor in [a, b, serialA, serialB]) {
        executor.dispose();
      }
    });

    test('executeOn 捕获令牌，await 后替换共享令牌按取消处理', () async {
      final executor = _RecordingSsh('token-swap')
        ..delay = const Duration(seconds: 5);
      registry.setExecutor('h', executor);
      final original = Completer<void>();
      multi.cancelToken = original;
      final pending = multi.executeOn('h', 'echo ok',
          permissionMode: AgentPermissionMode.fullAuto);
      await Future<void>.delayed(Duration.zero);
      expect(executor.commands, hasLength(1));
      multi.cancelToken = Completer<void>();
      original.complete();
      final result = await pending;
      expect(result!.failureKind, CommandFailureKind.cancelled);
      expect(executor.seenCancelTokens.single, same(original));
      multi.cancelToken = null;
      executor.dispose();
    });

    test('executeBatch 每轮使用入口令牌快照，替换后不派发下一台', () async {
      final a = _RecordingSsh('batch-token-a')
        ..delay = const Duration(seconds: 5);
      final b = _RecordingSsh('batch-token-b');
      registry
        ..setExecutor('a', a)
        ..setExecutor('b', b);
      final original = Completer<void>();
      multi.cancelToken = original;
      final pending = multi.executeBatch(['a', 'b'], 'rm /tmp/a');
      await Future<void>.delayed(Duration.zero);
      expect(a.commands, hasLength(1));
      multi.cancelToken = Completer<void>();
      original.complete();
      final results = await pending;
      expect(results['a']!.failureKind, CommandFailureKind.cancelled);
      expect(results['b']!.success, isFalse);
      expect(b.commands, isEmpty);
      expect(a.seenCancelTokens.single, same(original));
      multi.cancelToken = null;
      a.dispose();
      b.dispose();
    });

    test('批次权限从活跃 scope 捕获，缺失时保守 ask', () async {
      registry
        ..setActive('scope')
        ..setState(
            'scope', AgentState(permissionMode: AgentPermissionMode.readOnly));
      final executor = _RecordingSsh('readonly');
      registry.setExecutor('h', executor);
      final result = await multi.executeOn('h', 'rm /tmp/a');
      expect(result!.success, isFalse);
      expect(result.failureReason, contains('只读'));
      expect(executor.commands, isEmpty);
      executor.dispose();
    });
  });

  group('只读查询转义与假成功', () {
    test('multi_grep 逐个引用 pattern/files，tail 严格正整数', () async {
      final executor = _RecordingSsh('grep');
      registry.setExecutor('h', executor);
      const pattern = "x'; touch /tmp/pwn; #";
      const firstFile = "/tmp/a'; touch /tmp/pwn; #.log";
      const secondFile = '/tmp/b file.log';
      final result = await run(MultiGrepTool(multi), {
        'hostIds': ['h'],
        'pattern': pattern,
        'files': [firstFile, secondFile],
        'tail': '25',
      });
      expect(result.success, isTrue, reason: result.error ?? result.output);
      expect(
        executor.commands,
        [
          'tail -n 25 -- ${_quote(firstFile)} | grep -E -- ${_quote(pattern)}',
          'tail -n 25 -- ${_quote(secondFile)} | grep -E -- ${_quote(pattern)}',
        ],
      );
      for (final invalid in ['0', '-1', '1; touch /tmp/pwn', 'abc', ' 2']) {
        final rejected = await run(MultiGrepTool(multi), {
          'hostIds': ['h'],
          'pattern': 'x',
          'files': [firstFile],
          'tail': invalid,
        });
        expect(rejected.success, isFalse, reason: invalid);
        expect(rejected.error, contains('正整数'));
      }
      expect(executor.commands, hasLength(2));
      executor.dispose();
    });

    test('multi_grep 保留命中输入状态且任一输入失败则整体失败', () async {
      final executor = _RecordingSsh('partial-grep');
      executor.results.addAll([
        _result(stdout: '/tmp/a:needle'),
        _result(
          stderr: '/tmp/b: Permission denied',
          exitCode: 2,
          failureReason: '读取失败',
          failureKind: CommandFailureKind.unknown,
        ),
      ]);
      registry.setExecutor('h', executor);
      final result = await run(MultiGrepTool(multi), {
        'hostIds': ['h'],
        'pattern': 'needle',
        'files': ['/tmp/a', '/tmp/b'],
      });
      expect(result.success, isFalse, reason: '一个输入不可读不能被另一个输入的命中掩盖');
      expect(result.output, contains('[命中] /tmp/a'));
      expect(result.output, contains('/tmp/a:needle'));
      expect(result.output, contains('[失败] /tmp/b'));
      expect(result.output, contains('Permission denied'));
      expect(result.output, isNot(contains('所有输入搜索完成')));
      expect(executor.commands, [
        'grep -E -- ${_quote('needle')} ${_quote('/tmp/a')}',
        'grep -E -- ${_quote('needle')} ${_quote('/tmp/b')}',
      ]);
      executor.dispose();
    });

    test('multi_grep exit 1/空输出才是无匹配', () async {
      final missing = await run(MultiGrepTool(multi), {
        'hostIds': ['missing'],
        'pattern': 'x',
        'files': ['/tmp/a'],
      });
      expect(missing.success, isFalse);

      final executor = _RecordingSsh('failed-grep');
      executor.results.add(_result(
        stdout: 'diagnostic',
        stderr: 'read failed',
        exitCode: 2,
        failureReason: 'structured failure',
        failureKind: CommandFailureKind.unknown,
      ));
      executor.results.add(_result(exitCode: 1));
      registry.setExecutor('h', executor);
      final failed = await run(MultiGrepTool(multi), {
        'hostIds': ['h'],
        'pattern': 'x',
        'files': ['/tmp/a'],
      });
      expect(failed.success, isFalse);
      expect(failed.output, contains('structured failure'));

      final noMatch = await run(MultiGrepTool(multi), {
        'hostIds': ['h'],
        'pattern': 'x',
        'files': ['/tmp/a'],
      });
      expect(noMatch.success, isTrue, reason: 'grep exit 1/空输出才是无匹配');
      executor.dispose();
    });

    test('multi_grep 已取消时不派发且返回 failure', () async {
      final executor = _RecordingSsh('cancelled-grep');
      registry.setExecutor('h', executor);
      final token = Completer<void>()..complete();
      multi.cancelToken = token;
      final result = await run(MultiGrepTool(multi), {
        'hostIds': ['h'],
        'pattern': 'x',
        'files': ['/tmp/a'],
      });
      expect(result.success, isFalse);
      expect(executor.commands, isEmpty);
      multi.cancelToken = null;
      executor.dispose();
    });

    test('multi_grep 执行中收到真实取消令牌时立即失败', () async {
      final executor = _RecordingSsh('inflight-cancel')
        ..delay = const Duration(seconds: 5);
      registry.setExecutor('h', executor);
      final token = Completer<void>();
      multi.cancelToken = token;
      final pending = run(MultiGrepTool(multi), {
        'hostIds': ['h'],
        'pattern': 'x',
        'files': ['/tmp/a'],
      });
      await Future<void>.delayed(Duration.zero);
      expect(executor.commands, hasLength(1));
      token.complete();
      final result = await pending;
      expect(result.success, isFalse);
      expect(result.output, contains('已取消'));
      expect(executor.seenCancelTokens.single, same(token));
      expect(executor.active, 0);
      multi.cancelToken = null;
      executor.dispose();
    });

    test('multi_grep 令牌替换后不借用新任务派发后续主机', () async {
      final first = _RecordingSsh('swap-grep-first')
        ..delay = const Duration(seconds: 5);
      final second = _RecordingSsh('swap-grep-second');
      registry
        ..setExecutor('first', first)
        ..setExecutor('second', second);
      final original = Completer<void>();
      multi.cancelToken = original;
      final pending = run(MultiGrepTool(multi), {
        'hostIds': ['first', 'second'],
        'pattern': 'x',
        'files': ['/tmp/a'],
      });
      await Future<void>.delayed(Duration.zero);
      expect(first.commands, hasLength(1));
      multi.cancelToken = Completer<void>();
      original.complete();
      final result = await pending;
      expect(result.success, isFalse);
      expect(result.output, contains('已取消'));
      expect(second.commands, isEmpty);
      expect(first.seenCancelTokens.single, same(original));
      multi.cancelToken = null;
      first.dispose();
      second.dispose();
    });

    test('diff_files 拒绝重复 hostIds 且不派发任何命令', () async {
      final executor = _RecordingSsh('duplicate-diff');
      registry.setExecutor('h', executor);
      final result = await run(DiffFilesTool(multi), {
        'hostIds': ['h', 'h'],
        'remote': '/tmp/a',
      });
      expect(result.success, isFalse);
      expect(result.error, contains('重复'));
      expect(executor.commands, isEmpty);
      executor.dispose();
    });

    test('Windows 或未知 shell 不派发 POSIX grep/diff 命令', () async {
      final windows = _RecordingSsh('windows')..operatingSystem = 'Windows';
      final unknown = _RecordingSsh('unknown')..operatingSystem = 'Unknown';
      registry
        ..setExecutor('windows', windows)
        ..setExecutor('unknown', unknown);
      final grep = await run(MultiGrepTool(multi), {
        'hostIds': ['windows', 'unknown'],
        'pattern': 'x',
        'files': ['/tmp/a'],
      });
      expect(grep.success, isFalse);
      expect(grep.output, contains('Windows shell'));
      expect(grep.output, contains('无法确认'));
      final diff = await run(DiffFilesTool(multi), {
        'hostIds': ['windows', 'unknown'],
        'remote': '/tmp/a',
      });
      expect(diff.success, isFalse);
      expect(windows.commands, isEmpty);
      expect(unknown.commands, isEmpty);
      windows.dispose();
      unknown.dispose();
    });

    test('diff_files 引用 remote，任一读取失败不宣称一致', () async {
      final a = _RecordingSsh('diff-a');
      final b = _RecordingSsh('diff-b');
      registry
        ..setExecutor('a', a)
        ..setExecutor('b', b);
      const remote = "/tmp/a'; touch /tmp/pwn; #";
      final success = await run(DiffFilesTool(multi), {
        'hostIds': ['a', 'b'],
        'remote': remote,
      });
      expect(success.success, isFalse);
      expect(success.output, isNot(contains('所有主机文件一致')));
      final expectedCommand = 'md5sum -- ${_quote(remote)} && '
          "printf '%s\\n' '---CONTENT---' && head -n 200 -- ${_quote(remote)}";
      expect(a.commands.single, expectedCommand);
      expect(b.commands.single, expectedCommand);

      a.results.add(_result(
          stdout: '${'a' * 32}  ${_quote(remote)}\n---CONTENT---\none'));
      b.results.add(_result(
          stdout: '${'a' * 32}  ${_quote(remote)}\n---CONTENT---\none'));
      final valid = await run(DiffFilesTool(multi), {
        'hostIds': ['a', 'b'],
        'remote': remote,
      });
      expect(valid.success, isTrue, reason: valid.error ?? valid.output);
      expect(valid.output, contains('所有主机文件一致'));

      a.results.add(_result(stdout: '${'a' * 32}  ${_quote(remote)}'));
      b.results.add(_result(
          stdout: '${'b' * 32}  ${_quote(remote)}\n---CONTENT---\ntwo'));
      final incomplete = await run(DiffFilesTool(multi), {
        'hostIds': ['a', 'b'],
        'remote': remote,
      });
      expect(incomplete.success, isFalse);
      expect(incomplete.output, isNot(contains('所有主机文件一致')));
      a.dispose();
      b.dispose();
    });

    test('batch 失败详情按 failureReason → stderr → stdout', () async {
      final reason = _result(
        stderr: 'stderr detail',
        stdout: 'stdout detail',
        exitCode: 1,
        failureReason: 'reason detail',
      );
      final stderr =
          _result(stderr: 'stderr only', stdout: 'stdout only', exitCode: 1);
      final stdout = _result(stdout: 'stdout only', exitCode: 1);
      expect(MultiHostExecutor.failureDetail(reason), 'reason detail');
      expect(MultiHostExecutor.failureDetail(stderr), 'stderr only');
      expect(MultiHostExecutor.failureDetail(stdout), 'stdout only');
      final text = MultiHostExecutor.formatBatchResult('cmd', {
        'reason': reason,
        'stderr': stderr,
        'stdout': stdout,
      });
      expect(text, contains('reason detail'));
      expect(text, isNot(contains('stderr detail')));
      expect(text, contains('stderr only'));
      expect(text, contains('stdout only'));

      final executor = _RecordingSsh('batch');
      executor.results.add(reason);
      registry.setExecutor('h', executor);
      final result = await run(ExecBatchTool(multi), {
        'hostIds': ['h'],
        'command': 'echo ok',
      });
      expect(result.success, isFalse);
      expect(result.hostResults!['h']!.error, 'reason detail');
      executor.dispose();
    });
  });
}
