import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/change_record.dart';
import 'package:ai_terminal/services/change_record_service.dart';
import 'package:ai_terminal/services/command_executor.dart';

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
      expect(ChangeRecordService.isFileChangeTool('file_write'), isTrue);
      expect(ChangeRecordService.isFileChangeTool('exec_command'), isFalse);
      expect(
        ChangeRecordService.describeFileToolChange(
          'file_write',
          {'path': '/etc/nginx/nginx.conf'},
        ),
        'file_write /etc/nginx/nginx.conf',
      );
      expect(
        ChangeRecordService.describeFileToolChange(
          'file_patch',
          {'path': '/etc/hosts'},
        ),
        'file_patch /etc/hosts',
      );
      expect(
        ChangeRecordService.describeFileToolChange(
          'sftp_upload',
          {'local': 'dist/app.js', 'remote': '/var/www/app.js'},
        ),
        'sftp_upload dist/app.js -> /var/www/app.js',
      );
      expect(
        ChangeRecordService.describeFileToolChange(
          'upload_to',
          {'hostId': 'web-02', 'remote': '/tmp/a'},
        ),
        'upload_to web-02:/tmp/a',
      );
      expect(ChangeRecordService.isFileChangeTool('sftp_download'), isTrue);
      expect(
        ChangeRecordService.describeFileToolChange(
          'sftp_download',
          {'remote': '/var/log/app.log', 'local': '/tmp/app.log'},
        ),
        'sftp_download /var/log/app.log -> /tmp/app.log',
      );
      expect(
        ChangeRecordService.describeFileToolChange(
          'file_sync',
          {'localDir': '/local/story', 'remoteDir': '/remote/story'},
        ),
        'file_sync /local/story -> /remote/story',
      );
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
}
