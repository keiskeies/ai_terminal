import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_terminal/services/local_access.dart';
import 'package:ai_terminal/services/local_file_policy.dart';
import 'package:ai_terminal/services/local_terminal_service.dart';
import 'package:ai_terminal/services/project_tools.dart';
import 'package:ai_terminal/utils/local_shell.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _LocalExecutor implements LocalTerminalService {
  @override
  bool get isConnected => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LocalCommandResult _ok(String stdout) => LocalCommandResult(
      exitCode: 0,
      stdout: stdout,
      stderr: '',
      duration: const Duration(milliseconds: 1),
      timedOut: false,
      cancelled: false,
      stdoutTotalChars: stdout.length,
      stderrTotalChars: 0,
      stdoutTruncated: false,
      stderrTruncated: false,
    );

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('project_auth_test_'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  LocalAccessService accessFor(
    Future<bool> Function(String path, String reason, LocalAccessMode mode)
        request, {
    bool Function()? isActive,
    Duration grantTtl = const Duration(minutes: 15),
  }) =>
      LocalAccessService(
        taskId: 'project-task',
        generation: 1,
        isActive: isActive ?? () => true,
        grantTtl: grantTtl,
        authorizationRequest: request,
      );

  test('项目分析未授权时不读取目录', () async {
    final project = Directory(p.join(temp.path, 'project'))..createSync();
    File(p.join(project.path, 'package.json')).writeAsStringSync('{}');
    final tool =
        ProjectAnalyzeTool(policyLoader: () => const LocalFilePolicy());

    final result = await tool.execute(
      executor: _LocalExecutor(),
      args: ToolArgs({'path': project.path}),
    );

    expect(result.success, isFalse);
    expect(result.error, contains('未授权读取'));
  });

  test('项目分析只签发读取授权并输出元数据', () async {
    final project = Directory(p.join(temp.path, 'project'))..createSync();
    File(p.join(project.path, 'package.json')).writeAsStringSync('{}');
    final modes = <LocalAccessMode>[];
    final access = accessFor((path, reason, mode) async {
      modes.add(mode);
      return true;
    });
    final tool = ProjectAnalyzeTool(policyLoader: () => const LocalFilePolicy())
      ..localAccess = access;

    final result = await tool.execute(
      executor: _LocalExecutor(),
      args: ToolArgs({'path': project.path}),
    );

    expect(result.success, isTrue);
    expect(result.output, contains('package.json'));
    expect(modes, [LocalAccessMode.read]);
    expect(access.decide(project.path, LocalAccessMode.read),
        isA<LocalAccessGrant>());
    expect(access.decide(project.path, LocalAccessMode.write),
        isA<LocalAccessDenial>());
  });

  test('构建未授权时不会启动进程', () async {
    final project = Directory(p.join(temp.path, 'project'))..createSync();
    var runs = 0;
    final tool = BuildProjectTool(
      policyLoader: () => const LocalFilePolicy(),
      runner: ({
        required String command,
        required String cwd,
        required LocalShellKind shell,
        required Duration timeout,
        Completer<void>? cancelToken,
      }) async {
        runs++;
        return _ok('unexpected');
      },
    );

    final result = await tool.execute(
      executor: _LocalExecutor(),
      args: ToolArgs({'path': project.path, 'command': 'echo build'}),
    );

    expect(result.success, isFalse);
    expect(result.error, contains('未授权执行'));
    expect(runs, 0);
  });

  test('构建按工作目录传参且不扩展为读取授权', () async {
    final project = Directory(p.join(temp.path, 'project with space ; literal'))
      ..createSync();
    final modes = <LocalAccessMode>[];
    String? actualCommand;
    String? actualCwd;
    final access = accessFor((path, reason, mode) async {
      modes.add(mode);
      return true;
    });
    final tool = BuildProjectTool(
      policyLoader: () => const LocalFilePolicy(),
      runner: ({
        required String command,
        required String cwd,
        required LocalShellKind shell,
        required Duration timeout,
        Completer<void>? cancelToken,
      }) async {
        actualCommand = command;
        actualCwd = cwd;
        return _ok('built');
      },
    )..localAccess = access;

    final result = await tool.execute(
      executor: _LocalExecutor(),
      args: ToolArgs({'path': project.path, 'command': 'echo build'}),
    );

    expect(result.success, isTrue);
    expect(actualCommand, 'echo build');
    expect(actualCwd, project.path);
    expect(modes, [LocalAccessMode.execute]);
    expect(access.decide(project.path, LocalAccessMode.read),
        isA<LocalAccessDenial>());
  });

  test('自动推断构建命令先申请读取再申请执行', () async {
    final project = Directory(p.join(temp.path, 'project'))..createSync();
    File(p.join(project.path, 'package.json'))
        .writeAsStringSync('{"scripts":{"build":"vite build"}}');
    final modes = <LocalAccessMode>[];
    String? actualCommand;
    final access = accessFor((path, reason, mode) async {
      modes.add(mode);
      return true;
    });
    final tool = BuildProjectTool(
      policyLoader: () => const LocalFilePolicy(),
      runner: ({
        required String command,
        required String cwd,
        required LocalShellKind shell,
        required Duration timeout,
        Completer<void>? cancelToken,
      }) async {
        actualCommand = command;
        return _ok('built');
      },
    )..localAccess = access;

    final result = await tool.execute(
      executor: _LocalExecutor(),
      args: ToolArgs({'path': project.path}),
    );

    expect(result.success, isTrue);
    expect(actualCommand, 'npm run build');
    expect(modes, [LocalAccessMode.execute, LocalAccessMode.read]);
  });

  test('构建授权等待期间任务取消不会执行', () async {
    final project = Directory(p.join(temp.path, 'project'))..createSync();
    var active = true;
    var runs = 0;
    final access = accessFor(
      (path, reason, mode) async {
        active = false;
        return true;
      },
      isActive: () => active,
    );
    final tool = BuildProjectTool(
      policyLoader: () => const LocalFilePolicy(),
      runner: ({
        required String command,
        required String cwd,
        required LocalShellKind shell,
        required Duration timeout,
        Completer<void>? cancelToken,
      }) async {
        runs++;
        return _ok('unexpected');
      },
    )
      ..localAccess = access
      ..isTaskActive = () => active;

    final result = await tool.execute(
      executor: _LocalExecutor(),
      args: ToolArgs({'path': project.path, 'command': 'echo build'}),
    );

    expect(result.success, isFalse);
    expect(runs, 0);
    expect(access.decide(project.path, LocalAccessMode.execute),
        isA<LocalAccessDenial>());
  });

  test('构建授权在执行前过期会阻止进程启动', () async {
    final project = Directory(p.join(temp.path, 'project'))..createSync();
    var runs = 0;
    final access = accessFor(
      (path, reason, mode) async => true,
      grantTtl: Duration.zero,
    );
    final tool = BuildProjectTool(
      policyLoader: () => const LocalFilePolicy(),
      runner: ({
        required String command,
        required String cwd,
        required LocalShellKind shell,
        required Duration timeout,
        Completer<void>? cancelToken,
      }) async {
        runs++;
        return _ok('unexpected');
      },
    )..localAccess = access;

    final result = await tool.execute(
      executor: _LocalExecutor(),
      args: ToolArgs({'path': project.path, 'command': 'echo build'}),
    );

    expect(result.success, isFalse);
    expect(runs, 0);
  });

  test('打包分别申请产物读取和输出写入，参数不经 shell 拼接', () async {
    final project = Directory(p.join(temp.path, 'project'))..createSync();
    final artifact = Directory(p.join(project.path, 'dist'))..createSync();
    File(p.join(artifact.path, 'app.js')).writeAsStringSync('build');
    final output = p.join(temp.path, 'bundle.tar.gz');
    final modes = <LocalAccessMode>[];
    String? actualExecutable;
    List<String>? actualArgs;
    String? actualCwd;
    final access = accessFor((path, reason, mode) async {
      modes.add(mode);
      return true;
    });
    final tool = PackageProjectTool(
      policyLoader: () => const LocalFilePolicy(),
      runner: ({
        required String executable,
        required List<String> args,
        required String cwd,
        required Duration timeout,
        Completer<void>? cancelToken,
        Encoding? encoding,
      }) async {
        actualExecutable = executable;
        actualArgs = args;
        actualCwd = cwd;
        File(output).writeAsStringSync('archive');
        return _ok('packaged');
      },
    )..localAccess = access;

    final result = await tool.execute(
      executor: _LocalExecutor(),
      args: ToolArgs({
        'path': project.path,
        'artifact_dir': 'dist',
        'output': output,
        'exclude': 'x; echo injected',
      }),
    );

    expect(result.success, isTrue);
    expect(modes, [LocalAccessMode.read, LocalAccessMode.write]);
    expect(actualExecutable, 'tar');
    expect(actualCwd, artifact.path);
    expect(actualArgs, contains(output));
    expect(actualArgs, contains('--exclude=./x; echo injected'));
    expect(actualArgs?.any((arg) => arg.contains(' && ')), isFalse);
    expect(
        access.decide(output, LocalAccessMode.write), isA<LocalAccessGrant>());
  });

  test('打包的读取授权不能复用为输出写入授权', () async {
    final project = Directory(p.join(temp.path, 'project'))..createSync();
    Directory(p.join(project.path, 'dist')).createSync();
    final output = p.join(temp.path, 'bundle.zip');
    var runs = 0;
    final access =
        accessFor((path, reason, mode) async => mode == LocalAccessMode.read);
    final tool = PackageProjectTool(
      policyLoader: () => const LocalFilePolicy(),
      runner: ({
        required String executable,
        required List<String> args,
        required String cwd,
        required Duration timeout,
        Completer<void>? cancelToken,
        Encoding? encoding,
      }) async {
        runs++;
        File(output).writeAsStringSync('archive');
        return _ok('packaged');
      },
    )..localAccess = access;

    final result = await tool.execute(
      executor: _LocalExecutor(),
      args: ToolArgs({
        'path': project.path,
        'artifact_dir': 'dist',
        'output': output,
        'format': 'zip',
      }),
    );

    expect(result.success, isFalse);
    expect(result.error, contains('未授权写入'));
    expect(runs, 0);
    expect(File(output).existsSync(), isFalse);
  });

  test('打包产物目录不能通过 .. 跳出项目', () async {
    final project = Directory(p.join(temp.path, 'project'))..createSync();
    final outside = Directory(p.join(temp.path, 'outside'))..createSync();
    var asked = false;
    final tool = PackageProjectTool(
      policyLoader: () => const LocalFilePolicy(),
    )..localAccess = accessFor((path, reason, mode) async {
        asked = true;
        return true;
      });

    final result = await tool.execute(
      executor: _LocalExecutor(),
      args: ToolArgs({
        'path': project.path,
        'artifact_dir': p.join('..', p.basename(outside.path)),
        'output': p.join(temp.path, 'bundle.tar.gz'),
      }),
    );

    expect(result.success, isFalse);
    expect(result.error, contains('不能跳出项目'));
    expect(asked, isFalse);
  });
}
