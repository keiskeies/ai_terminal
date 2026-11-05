import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/local_exec_tool.dart';
import 'package:ai_terminal/services/local_file_policy.dart';
import 'package:ai_terminal/utils/local_shell.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

class _NoopExecutor implements CommandExecutor {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePolicy extends LocalFilePolicy {
  bool allow;
  _FakePolicy({required this.allow})
      : super(enabled: true, allowedDirs: const ['/fake']);

  @override
  LocalPathDecision decide(String rawPath,
      {List<String> extraRoots = const []}) {
    if (rawPath.contains('sensitive')) {
      return LocalPathDecision(LocalPathVerdict.sensitive, rawPath, '敏感路径');
    }
    if (allow) {
      return LocalPathDecision(LocalPathVerdict.allowed, rawPath);
    }
    return LocalPathDecision(LocalPathVerdict.notInAllowlist, rawPath, '未授权');
  }
}

LocalCommandResult _ok(String stdout) => LocalCommandResult(
      exitCode: 0,
      stdout: stdout,
      stderr: '',
      duration: const Duration(milliseconds: 3),
      timedOut: false,
      cancelled: false,
      stdoutTotalChars: stdout.length,
      stderrTotalChars: 0,
      stdoutTruncated: false,
      stderrTruncated: false,
    );

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('local_exec_test_'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  ToolArgs args(String command, String cwd) =>
      ToolArgs({'command': command, 'cwd': cwd});

  group('LocalExecTool 元数据', () {
    test('本机 shell 是破坏性工具且不进远程变更台账', () {
      final tool = LocalExecTool();
      expect(tool.name, 'local_exec');
      expect(tool.kind, ToolKind.destructive);
      expect(tool.recordsChanges, isFalse);
    });

    test('只在 SSH 会话暴露，本地会话不重复给入口', () {
      final registry = AgentToolRegistry();
      expect(
        registry.visibleFor(isLocalSession: false).map((t) => t.name),
        contains('local_exec'),
      );
      expect(
        registry.visibleFor(isLocalSession: true).map((t) => t.name),
        isNot(contains('local_exec')),
      );
    });
  });

  group('LocalExecTool 参数与路径', () {
    test('缺 command / cwd 直接失败', () async {
      final tool = LocalExecTool(policyLoader: () => _FakePolicy(allow: true));
      final noCmd = await tool.execute(
          executor: _NoopExecutor(), args: const ToolArgs({'cwd': '/tmp'}));
      expect(noCmd.success, isFalse);
      expect(noCmd.error, contains('command'));

      final noCwd = await tool.execute(
          executor: _NoopExecutor(),
          args: const ToolArgs({'command': 'echo hi'}));
      expect(noCwd.success, isFalse);
      expect(noCwd.error, contains('cwd'));
    });

    test('相对 cwd 被拒绝', () async {
      final tool = LocalExecTool(policyLoader: () => _FakePolicy(allow: true));
      final result = await tool.execute(
          executor: _NoopExecutor(), args: args('echo hi', '.'));
      expect(result.success, isFalse);
      expect(result.error, contains('绝对路径'));
    });

    test('敏感目录直接拒绝，不触发授权弹窗', () async {
      final tool = LocalExecTool(policyLoader: () => _FakePolicy(allow: false));
      var asked = false;
      tool.localDirAuthorizationRequest = (path, reason) async {
        asked = true;
        return true;
      };
      final result = await tool.execute(
          executor: _NoopExecutor(),
          args: args('echo hi', p.join(temp.path, 'sensitive')));
      expect(result.success, isFalse);
      expect(result.error, contains('敏感路径'));
      expect(asked, isFalse);
    });
  });

  group('LocalExecTool 目录授权', () {
    test('未授权 → 用户允许 → 重新判定并执行', () async {
      final policy = _FakePolicy(allow: false);
      var runs = 0;
      final tool = LocalExecTool(
        policyLoader: () => policy,
        runner: ({
          required String command,
          required String cwd,
          required LocalShellKind shell,
          required Duration timeout,
          Completer<void>? cancelToken,
        }) async {
          runs++;
          return _ok('hello from local');
        },
      );
      var askedPath = '';
      tool.localDirAuthorizationRequest = (path, reason) async {
        askedPath = path;
        policy.allow = true;
        return true;
      };
      final cwd = p.join(temp.path, 'work');
      final result = await tool.execute(
          executor: _NoopExecutor(), args: args('echo hi', cwd));
      expect(askedPath, cwd);
      expect(result.success, isTrue);
      expect(result.output, contains('hello from local'));
      expect(runs, 1);
      expect(Directory(cwd).existsSync(), isTrue, reason: '授权后应创建 cwd');
    });

    test('用户拒绝 → 不执行', () async {
      final policy = _FakePolicy(allow: false);
      var runs = 0;
      final tool = LocalExecTool(
        policyLoader: () => policy,
        runner: ({
          required String command,
          required String cwd,
          required LocalShellKind shell,
          required Duration timeout,
          Completer<void>? cancelToken,
        }) async {
          runs++;
          return _ok('should not run');
        },
      );
      tool.localDirAuthorizationRequest = (path, reason) async => false;
      final result = await tool.execute(
          executor: _NoopExecutor(),
          args: args('echo hi', p.join(temp.path, 'work')));
      expect(result.success, isFalse);
      expect(result.error, contains('拒绝授权'));
      expect(runs, 0);
    });

    test('没有 UI 授权回调时给出设置页提示', () async {
      final tool = LocalExecTool(policyLoader: () => _FakePolicy(allow: false));
      final result = await tool.execute(
          executor: _NoopExecutor(),
          args: args('echo hi', p.join(temp.path, 'work')));
      expect(result.success, isFalse);
      expect(result.error, contains('设置'));
    });

    test('授权等待期间任务被取消 → 不创建目录也不执行', () async {
      final policy = _FakePolicy(allow: false);
      var runs = 0;
      final tool = LocalExecTool(
        policyLoader: () => policy,
        runner: ({
          required String command,
          required String cwd,
          required LocalShellKind shell,
          required Duration timeout,
          Completer<void>? cancelToken,
        }) async {
          runs++;
          return _ok('should not run');
        },
      );
      var active = true;
      tool.isTaskActive = () => active;
      tool.localDirAuthorizationRequest = (path, reason) async {
        active = false;
        policy.allow = true;
        return true;
      };
      final cwd = p.join(temp.path, 'work_after_cancel');
      final result = await tool.execute(
          executor: _NoopExecutor(), args: args('echo hi', cwd));
      expect(result.success, isFalse);
      expect(result.error, contains('取消'));
      expect(runs, 0);
      expect(Directory(cwd).existsSync(), isFalse);
    });
  });

  group('LocalExecTool 执行结果', () {
    test('成功输出包含状态/cwd/退出码', () async {
      final tool = LocalExecTool(
        policyLoader: () => _FakePolicy(allow: true),
        runner: ({
          required String command,
          required String cwd,
          required LocalShellKind shell,
          required Duration timeout,
          Completer<void>? cancelToken,
        }) async =>
            _ok('ok'),
      );
      final result = await tool.execute(
          executor: _NoopExecutor(), args: args('echo ok', temp.path));
      expect(result.success, isTrue);
      expect(result.output, contains('本机命令执行成功'));
      expect(result.output, contains('退出码'));
      expect(result.output, contains('ok'));
    });

    test('超时/失败输出明确标注', () async {
      final tool = LocalExecTool(
        policyLoader: () => _FakePolicy(allow: true),
        runner: ({
          required String command,
          required String cwd,
          required LocalShellKind shell,
          required Duration timeout,
          Completer<void>? cancelToken,
        }) async {
          return const LocalCommandResult(
            exitCode: -1,
            stdout: '',
            stderr: 'boom',
            duration: Duration(seconds: 60),
            timedOut: true,
            cancelled: false,
            stdoutTotalChars: 0,
            stderrTotalChars: 4,
            stdoutTruncated: false,
            stderrTruncated: false,
          );
        },
      );
      final result = await tool.execute(
          executor: _NoopExecutor(), args: args('sleep 999', temp.path));
      expect(result.success, isFalse);
      expect(result.error, contains('超时'));
      expect(result.error, contains('boom'));
    });
  });
}
