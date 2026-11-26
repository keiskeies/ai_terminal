import 'dart:async';
import 'dart:io';

import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/local_access.dart';
import 'package:ai_terminal/services/local_file_policy.dart';
import 'package:ai_terminal/services/local_file_tools.dart';
import 'package:ai_terminal/services/local_terminal_service.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _NoopExecutor implements CommandExecutor {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('local_access_test_'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('授权按模式分离，只覆盖根目录自身和后代', () {
    final access = LocalAccessService(
      taskId: 'task-a',
      generation: 7,
      isActive: () => true,
    );
    final root = p.join(temp.path, 'work');
    access.issue(
      canonicalPath: root,
      mode: LocalAccessMode.read,
      reason: 'test',
    );

    expect(access.decide(root, LocalAccessMode.read), isA<LocalAccessGrant>());
    expect(
      access.decide(p.join(root, 'sub', 'file.txt'), LocalAccessMode.read),
      isA<LocalAccessGrant>(),
    );
    expect(
      access.decide(
          p.join(root, '..', 'work-evil', 'file.txt'), LocalAccessMode.read),
      isA<LocalAccessDenial>(),
    );
    expect(
        access.decide(root, LocalAccessMode.write), isA<LocalAccessDenial>());
    expect(
      access.decide(root, LocalAccessMode.execute),
      isA<LocalAccessDenial>(),
    );
  });

  test('过期、撤销和任务失效都会立即拒绝', () {
    final root = p.join(temp.path, 'work');
    final expired = LocalAccessService(
      taskId: 'expired',
      generation: 1,
      isActive: () => true,
      grantTtl: Duration.zero,
    );
    expired.issue(
      canonicalPath: root,
      mode: LocalAccessMode.read,
      reason: 'test',
    );
    expect(
        expired.decide(root, LocalAccessMode.read), isA<LocalAccessDenial>());

    var active = true;
    final revoked = LocalAccessService(
      taskId: 'revoked',
      generation: 1,
      isActive: () => active,
    );
    revoked.issue(
      canonicalPath: root,
      mode: LocalAccessMode.write,
      reason: 'test',
    );
    revoked.revokeAll();
    expect(
        revoked.decide(root, LocalAccessMode.write), isA<LocalAccessDenial>());

    final inactive = LocalAccessService(
      taskId: 'inactive',
      generation: 1,
      isActive: () => active,
    );
    inactive.issue(
      canonicalPath: root,
      mode: LocalAccessMode.execute,
      reason: 'test',
    );
    active = false;
    expect(
      inactive.decide(root, LocalAccessMode.execute),
      isA<LocalAccessDenial>(),
    );
  });

  test('授权等待期间任务取消不会签发授权', () async {
    var active = true;
    final answer = Completer<bool>();
    final access = LocalAccessService(
      taskId: 'cancel-during-approval',
      generation: 3,
      isActive: () => active,
      authorizationRequest: (path, reason, mode) => answer.future,
    );
    final root = p.join(temp.path, 'work');
    final pending = access.authorize(root, LocalAccessMode.read, 'test');
    active = false;
    answer.complete(true);

    expect(await pending, isFalse);
    expect(access.decide(root, LocalAccessMode.read), isA<LocalAccessDenial>());
  });

  test('全局开关关闭时任务授权仍可读，且不扩展为写或执行', () async {
    final root = p.join(temp.path, 'work');
    Directory(root).createSync();
    final file = File(p.join(root, 'note.txt'))
      ..writeAsStringSync('hello grant');
    const policy = LocalFilePolicy();
    final access = LocalAccessService(
      taskId: 'read-only',
      generation: 1,
      isActive: () => true,
      authorizationRequest: (path, reason, mode) async =>
          mode == LocalAccessMode.read,
    );

    final read = await authorizeLocalPath(
      rawPath: file.path,
      mode: LocalAccessMode.read,
      access: access,
      policy: policy,
      reason: 'test read',
    );
    expect(read.isAllowed, isTrue);
    expect(policy.enabled, isFalse);
    expect(policy.allowedDirs, isEmpty);

    final write = await authorizeLocalPath(
      rawPath: file.path,
      mode: LocalAccessMode.write,
      access: access,
      policy: policy,
      reason: 'test write',
    );
    final execute = await authorizeLocalPath(
      rawPath: root,
      mode: LocalAccessMode.execute,
      access: access,
      policy: policy,
      reason: 'test execute',
    );
    expect(write.isAllowed, isFalse);
    expect(execute.isAllowed, isFalse);
  });

  test('授权弹窗返回后路径被换走会 fail closed', () async {
    final authorized = Directory(p.join(temp.path, 'authorized'))..createSync();
    final outside = Directory(p.join(temp.path, 'outside'))..createSync();
    final link = Link(p.join(temp.path, 'link'));
    link.createSync(authorized.path);
    addTearDown(() {
      if (link.existsSync()) link.deleteSync();
    });
    final access = LocalAccessService(
      taskId: 'link-swap',
      generation: 1,
      isActive: () => true,
      authorizationRequest: (path, reason, mode) async {
        link.deleteSync();
        link.createSync(outside.path);
        return true;
      },
    );

    final decision = await authorizeLocalPath(
      rawPath: link.path,
      mode: LocalAccessMode.read,
      access: access,
      policy: const LocalFilePolicy(),
      reason: 'test link swap',
    );
    expect(decision.isAllowed, isFalse);
  }, skip: Platform.isWindows ? 'Windows 创建符号链接通常需要额外权限' : false);

  test('任务失效时全局白名单也不能继续放行工具 I/O', () async {
    final root = p.join(temp.path, 'work');
    Directory(root).createSync();
    var active = true;
    final access = LocalAccessService(
      taskId: 'inactive-global',
      generation: 1,
      isActive: () => active,
    );
    const policy = LocalFilePolicy(enabled: true, allowedDirs: []);

    final allowed = await authorizeLocalPath(
      rawPath: root,
      mode: LocalAccessMode.read,
      access: access,
      policy: LocalFilePolicy(enabled: true, allowedDirs: [root]),
      reason: 'test',
    );
    expect(allowed.isAllowed, isTrue);

    active = false;
    final denied = verifyLocalPathAccess(
      rawPath: root,
      expectedResolved: root,
      mode: LocalAccessMode.read,
      access: access,
      policy: policy.copyWith(allowedDirs: [root]),
    );
    expect(denied.isAllowed, isFalse);
    expect(denied.reason, contains('授权失效'));
  });

  test('写授权覆盖父目录后，新建文件与补丁不再被临时文件权限卡住', () async {
    final root = p.join(temp.path, 'work');
    Directory(root).createSync();
    final requested = <String>[];
    final access = LocalAccessService(
      taskId: 'write-parent',
      generation: 1,
      isActive: () => true,
      authorizationRequest: (path, reason, mode) async {
        requested.add('$mode:$path');
        return mode == LocalAccessMode.write;
      },
    );
    final file = File(p.join(root, 'new.txt'));
    final write = LocalFileWriteTool(
      policyLoader: () => const LocalFilePolicy(),
    )..localAccess = access;
    final created = await write.execute(
      executor: _NoopExecutor(),
      args: ToolArgs({'path': file.path, 'content': 'hello'}),
    );
    expect(created.success, isTrue, reason: created.error);
    expect(file.readAsStringSync(), 'hello');

    final patch = LocalFilePatchTool(
      policyLoader: () => const LocalFilePolicy(),
    )..localAccess = access;
    final patched = await patch.execute(
      executor: _NoopExecutor(),
      args: ToolArgs({'path': file.path, 'old': 'hello', 'new': 'world'}),
    );
    expect(patched.success, isTrue, reason: patched.error);
    expect(file.readAsStringSync(), 'world');
    expect(requested, everyElement(contains('write:$root')));
  });

  test('旧 file_write 本地分支使用父目录写授权且保留最终文件复验', () async {
    final root = p.join(temp.path, 'work');
    Directory(root).createSync();
    final access = LocalAccessService(
      taskId: 'legacy-write-parent',
      generation: 1,
      isActive: () => true,
      authorizationRequest: (path, reason, mode) async =>
          mode == LocalAccessMode.write &&
          p.normalize(path) == p.normalize(root),
    );
    final file = File(p.join(root, 'new.txt'));
    final tool = FileWriteTool()..localAccess = access;
    final result = await tool.execute(
      executor: LocalTerminalService(),
      args: ToolArgs({'path': file.path, 'content': 'created'}),
    );
    expect(result.success, isTrue, reason: result.error);
    expect(file.readAsStringSync(), 'created');
  });

  test('本地搜索使用读授权，写工具不能复用读授权', () async {
    final root = p.join(temp.path, 'work');
    Directory(root).createSync();
    final file = File(p.join(root, 'note.txt'))
      ..writeAsStringSync('hello grant');
    final access = LocalAccessService(
      taskId: 'tools',
      generation: 1,
      isActive: () => true,
      authorizationRequest: (path, reason, mode) async =>
          mode == LocalAccessMode.read,
    );
    final search = LocalFileSearchTool(
      policyLoader: () => const LocalFilePolicy(),
    )..localAccess = access;
    final found = await search.execute(
      executor: _NoopExecutor(),
      args: ToolArgs({'path': root, 'query': 'hello'}),
    );
    expect(found.success, isTrue);
    expect(found.output, contains('note.txt'));

    final write = LocalFileWriteTool(
      policyLoader: () => const LocalFilePolicy(),
    )..localAccess = access;
    final denied = await write.execute(
      executor: _NoopExecutor(),
      args: ToolArgs({'path': file.path, 'content': 'overwrite'}),
    );
    expect(denied.success, isFalse);
    expect(file.readAsStringSync(), 'hello grant');
  });
}
