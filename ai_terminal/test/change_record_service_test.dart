import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/change_record.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/change_record_service.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

class _MockExecutor implements CommandExecutor {
  String? lastCommand;

  @override
  bool get isConnected => true;

  @override
  Stream<String> get output => const Stream.empty();

  @override
  void execute(String command) {}

  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
    String? sudoPassword,
  }) async {
    lastCommand = command;
    return CommandResult(
      stdout: 'ok',
      stderr: '',
      exitCode: 0,
      duration: const Duration(milliseconds: 10),
    );
  }

  @override
  Future<String> runOnce(String command,
          {Duration timeout = const Duration(seconds: 5)}) async =>
      '';

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
      stderr: 'unsupported',
      exitCode: -1,
      duration: Duration.zero,
      failureKind: CommandFailureKind.unknown,
    );
  }

  @override
  void writeToTerminal(String data) {}
}

void main() {
  group('ChangeRecordService', () {
    test('classifies sudo service commands correctly', () {
      expect(
        ChangeRecordService.inferType('sudo systemctl restart nginx'),
        ChangeType.restartService,
      );
      expect(
        ChangeRecordService.inferType('sudo systemctl start nginx'),
        ChangeType.startService,
      );
      expect(
        ChangeRecordService.inferType('sudo apt install nginx'),
        ChangeType.install,
      );
      expect(
        ChangeRecordService.inferType('sudo cp /tmp/a /etc/a'),
        ChangeType.fileOperation,
      );
    });

    test('builds rollback commands and preserves sudo', () {
      expect(
        ChangeRecordService.buildRollbackCommand(
          'sudo apt install nginx',
          ChangeType.install,
        ),
        'sudo apt remove nginx',
      );
      expect(
        ChangeRecordService.buildRollbackCommand(
          'sudo systemctl start nginx',
          ChangeType.startService,
        ),
        'sudo systemctl stop nginx',
      );
      expect(
        ChangeRecordService.buildRollbackCommand(
          'systemctl stop nginx',
          ChangeType.stopService,
        ),
        'systemctl start nginx',
      );
    });

    test('describes file tool changes for the ledger', () {
      // 台账判定不再有工具名清单，改由 AgentTool.kind 派生
      final registry = AgentToolRegistry();
      expect(registry.isChangeRecordingTool('file_write'), isTrue);
      expect(registry.isChangeRecordingTool('sftp_download'), isTrue);
      expect(registry.isChangeRecordingTool('cert_check'), isFalse);
      // exec_command 不是工具，走 shell 台账分支
      expect(registry.isChangeRecordingTool('exec_command'), isFalse);
      expect(
        ChangeRecordService.describeFileToolChange(
          'file_write',
          const ToolArgs({'path': '/etc/nginx/nginx.conf'}),
        ),
        'file_write /etc/nginx/nginx.conf',
      );
      expect(
        ChangeRecordService.describeFileToolChange(
          'file_patch',
          const ToolArgs({'path': '/etc/hosts'}),
        ),
        'file_patch /etc/hosts',
      );
      expect(
        ChangeRecordService.describeFileToolChange(
          'sftp_upload',
          const ToolArgs({'local': 'dist/app.js', 'remote': '/var/www/app.js'}),
        ),
        'sftp_upload dist/app.js -> /var/www/app.js',
      );
      expect(
        ChangeRecordService.describeFileToolChange(
          'upload_to',
          const ToolArgs({'hostId': 'web-02', 'remote': '/tmp/a'}),
        ),
        'upload_to web-02:/tmp/a',
      );
      expect(
        ChangeRecordService.describeFileToolChange(
          'sftp_download',
          const ToolArgs({'remote': '/var/log/app.log', 'local': '/tmp/app.log'}),
        ),
        'sftp_download /var/log/app.log -> /tmp/app.log',
      );
      expect(
        ChangeRecordService.describeFileToolChange(
          'file_sync',
          const ToolArgs({'localDir': '/local/story', 'remoteDir': '/remote/story'}),
        ),
        'file_sync /local/story -> /remote/story',
      );
    });

    test('change-recording set is derived from tool kind', () {
      final registry = AgentToolRegistry();
      final recording = registry.changeRecordingToolNames.toSet();
      expect(
        recording.containsAll({
          'file_write',
          'file_patch',
          'sftp_upload',
          'sftp_download',
          'file_sync',
        }),
        isTrue,
      );
      // 只读工具与"改产物目录但不产生可回滚文件变更"的构建工具不进台账
      expect(recording.contains('cert_check'), isFalse);
      expect(recording.contains('project_analyze'), isFalse);
      expect(recording.contains('build_project'), isFalse);
      expect(recording.contains('package_project'), isFalse);
    });

    test('executeRollback runs the rollback command through executor', () async {
      final executor = _MockExecutor();
      final record = ChangeRecord(
        id: 'record-1',
        hostId: 'web-01',
        command: 'sudo apt install nginx',
        type: ChangeType.install,
        rollbackCommand: 'sudo apt remove nginx',
        timestamp: DateTime.now(),
        success: true,
      );

      final result = await ChangeRecordService.executeRollback(record, executor);

      expect(result, isNotNull);
      expect(result!.success, isTrue);
      expect(executor.lastCommand, 'sudo apt remove nginx');
    });

    test('restart/file/permission have no auto rollback', () {
      expect(
        ChangeRecordService.buildRollbackCommand(
          'sudo systemctl restart nginx',
          ChangeType.restartService,
        ),
        isNull,
      );
      expect(
        ChangeRecordService.buildRollbackCommand(
          'sudo chmod 777 /etc/nginx',
          ChangeType.permission,
        ),
        isNull,
      );
    });
  });

  group('本机文件还原', () {
    late Directory sandbox;
    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('ai_restore_');
      sandbox = Directory(await sandbox.resolveSymbolicLinks());
    });
    tearDown(() async {
      try {
        await sandbox.delete(recursive: true);
      } catch (_) {}
    });

    ChangeRecord rec({required String from, required String to}) => ChangeRecord(
          id: 'rec-${DateTime.now().microsecondsSinceEpoch}',
          hostId: 'local',
          command: 'local_file_delete $to',
          type: ChangeType.fileOperation,
          localRestoreFrom: from,
          localRestoreTo: to,
          timestamp: DateTime.now(),
          success: true,
        );

    test('可回滚性不依赖 rollbackCommand', () {
      final r = rec(from: '/tmp/a', to: '/tmp/b');
      expect(r.rollbackCommand, isNull);
      expect(r.isRollbackable, isTrue);
      expect(r.isLocalFileRestore, isTrue);
      expect(r.rollbackHint, contains('/tmp/b'));
      expect(
          ChangeRecord(
            id: 'x',
            hostId: 'h',
            command: 'apt install nginx',
            type: ChangeType.install,
            timestamp: DateTime.now(),
            success: true,
          ).isRollbackable,
          isFalse);
    });

    test('从回收区移回原位，且完全不经过 executor', () async {
      final copy = File('${sandbox.path}/trash_copy.txt')
        ..writeAsStringSync('original content');
      final target = '${sandbox.path}/project/app.conf';

      final executor = _MockExecutor();
      final result = await ChangeRecordService.executeRollback(
        rec(from: copy.path, to: target),
        executor,
      );

      expect(result, isNotNull);
      expect(result!.success, isTrue, reason: result.stderr);
      expect(File(target).readAsStringSync(), 'original content');
      expect(executor.lastCommand, isNull,
          reason: '本机还原绝不能把 mv 丢给 executor —— SSH 会话里那会打到远端机器');
      // 副本保留：同一条记录要能反复还原
      expect(copy.existsSync(), isTrue);
    });

    test('executor 传 null 也能还原本机文件', () async {
      final copy = File('${sandbox.path}/bak')..writeAsStringSync('v1');
      final target = '${sandbox.path}/cfg';

      final result = await ChangeRecordService.executeRollback(
        rec(from: copy.path, to: target),
        null,
      );
      expect(result!.success, isTrue);
      expect(File(target).readAsStringSync(), 'v1');
    });

    test('目标已存在时先另存再还原，不静默覆盖', () async {
      final copy = File('${sandbox.path}/bak')..writeAsStringSync('old');
      final target = File('${sandbox.path}/cfg')..writeAsStringSync('user edits');

      final result = await ChangeRecordService.executeRollback(
        rec(from: copy.path, to: target.path),
        null,
      );
      expect(result!.success, isTrue);
      expect(target.readAsStringSync(), 'old');
      final displaced = sandbox
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.displaced.'));
      expect(displaced, hasLength(1), reason: '用户改出来的内容必须留得住');
      expect(displaced.single.readAsStringSync(), 'user edits');
    });

    test('副本丢失时失败且不碰目标', () async {
      final target = File('${sandbox.path}/cfg')..writeAsStringSync('keep me');
      final result = await ChangeRecordService.executeRollback(
        rec(from: '${sandbox.path}/nope.bak', to: target.path),
        null,
      );
      expect(result!.success, isFalse);
      expect(result.stderr, contains('副本已不存在'));
      expect(target.readAsStringSync(), 'keep me');
    });

    test('目录整体放回原位', () async {
      final trashDir = Directory('${sandbox.path}/trash/run')..createSync(recursive: true);
      File('${trashDir.path}/inner.txt').writeAsStringSync('i');
      final target = '${sandbox.path}/restored/dir';

      final result = await ChangeRecordService.executeRollback(
        rec(from: trashDir.path, to: target),
        null,
      );
      expect(result!.success, isTrue, reason: result.stderr);
      expect(File('$target/inner.txt').readAsStringSync(), 'i');
      expect(Directory(trashDir.path).existsSync(), isFalse,
          reason: '目录用 rename 放回，回收区里不该再留一份');
    });

    test('目标父目录不存在时自动创建', () async {
      final copy = File('${sandbox.path}/bak')..writeAsStringSync('x');
      final deep = '${sandbox.path}/a/b/c/conf';

      final result = await ChangeRecordService.executeRollback(
        rec(from: copy.path, to: deep),
        null,
      );
      expect(result!.success, isTrue);
      expect(File(deep).readAsStringSync(), 'x');
    });
  });
}
