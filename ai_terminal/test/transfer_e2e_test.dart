import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/agent_host_registry.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/multi_host_executor.dart';
import 'package:ai_terminal/services/sftp_service.dart';
import 'package:ai_terminal/services/ssh_service.dart';

/// 真实 SSH 服务器的文件传输 E2E：
/// - 单文件上传/下载、覆盖、CRLF/BOM、无尾换行
/// - 二进制/大文件 SHA-256
/// - 目录递归上传/下载、exclude、空目录
/// - 特殊字符文件名、失败路径、临时文件残留
///
/// 运行：
///   E2E_SSH_HOST=127.0.0.1 E2E_SSH_PORT=1022 E2E_SSH_USER=root \
///   E2E_SSH_PASSWORD=*** flutter test --no-pub test/transfer_e2e_test.dart

final _env = Platform.environment;
final _sshHost = _env['E2E_SSH_HOST'];
final _sshUser = _env['E2E_SSH_USER'];
final _sshPassword = _env['E2E_SSH_PASSWORD'];
final _sshPort = int.tryParse(_env['E2E_SSH_PORT'] ?? '') ?? 22;
final _enabled = _sshHost?.isNotEmpty == true &&
    _sshUser?.isNotEmpty == true &&
    _sshPassword != null;
const _skipReason =
    'Set E2E_SSH_HOST / E2E_SSH_PORT / E2E_SSH_USER / E2E_SSH_PASSWORD to run';

const _remoteRoot = '/tmp/ai_terminal_transfer_e2e';

String _shq(String value) => "'${value.replaceAll("'", "'\\''")}'";

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  setUpAll(() {
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  group('File transfer E2E', skip: _enabled ? false : _skipReason, () {
    late SSHService ssh;
    late SftpService sftp;
    late Directory localRoot;

    setUpAll(() async {
      ssh = SSHService(HostConfig.create(
        id: 'transfer-e2e',
        name: 'Transfer E2E',
        host: _sshHost!,
        port: _sshPort,
        username: _sshUser!,
        authType: 'password',
      ));
      await ssh.connect(password: _sshPassword!);
      expect(ssh.isConnected, isTrue);

      sftp = SftpService();
      await sftp.attachToClient(ssh.client!);

      await ssh.executeAndWait('rm -rf ${_shq(_remoteRoot)}');
      await ssh.executeAndWait('mkdir -p ${_shq(_remoteRoot)}');

      localRoot = await Directory.systemTemp.createTemp('ai_terminal_transfer_');
    });

    tearDownAll(() async {
      try {
        if (ssh.isConnected) {
          await ssh.executeAndWait('rm -rf ${_shq(_remoteRoot)}');
        }
      } catch (_) {}
      try {
        sftp.closeSftpOnly();
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

    Future<Uint8List> readRemote(String path) =>
        sftp.readFileBytes(path, maxSize: 8 * 1024 * 1024);

    Future<void> expectNoTransferArtifacts(String remoteDir) async {
      final entries = await sftp.listDirectory(remoteDir);
      for (final entry in entries) {
        expect(entry.name, isNot(contains('.ai-upload-')),
            reason: '上传临时文件残留: ${entry.path}');
        expect(entry.name, isNot(contains('.ai-download-')),
            reason: '下载临时文件残留: ${entry.path}');
        expect(entry.name, isNot(contains('.ai-old-')),
            reason: '覆盖旧文件残留: ${entry.path}');
        expect(entry.name, isNot(endsWith('.part')),
            reason: '临时文件残留: ${entry.path}');
      }
    }

    Future<ToolResult> upload(
      String local,
      String remote, {
      bool recursive = false,
      List<String>? exclude,
    }) {
      return SftpUploadTool().execute(
        executor: ssh,
        args: {
          'local': local,
          'remote': remote,
          'recursive': recursive,
          if (exclude != null) 'exclude': exclude,
        },
      );
    }

    Future<ToolResult> download(
      String remote,
      String local, {
      bool recursive = false,
      List<String>? exclude,
    }) {
      return SftpDownloadTool().execute(
        executor: ssh,
        args: {
          'remote': remote,
          'local': local,
          'recursive': recursive,
          if (exclude != null) 'exclude': exclude,
        },
      );
    }

    test('single file upload/download preserves bytes, names and overwrite safety',
        () async {
      const remoteDir = '$_remoteRoot/单文件 上传 😀/nested';
      const remotePath = '$remoteDir/配置 名称 😀.txt';
      final localDir = Directory(p.join(localRoot.path, '本地 上传 😀'));
      await localDir.create(recursive: true);
      final localPath = p.join(localDir.path, '配置 名称 😀.txt');

      const textV1 = '第一行：中文 😀\r\n'
          '第二行：\$HOME `whoami` "double" \'single\' \\backslash & | ; > %\r\n'
          '第三行：无尾换行';
      final bytesV1 = utf8.encode(textV1);
      await File(localPath).writeAsBytes(bytesV1, flush: true);

      final uploadResult = await upload(localPath, remotePath);
      expect(uploadResult.success, isTrue,
          reason: uploadResult.error ?? uploadResult.output);
      expect(await readRemote(remotePath), bytesV1);
      expect(await sftp.statFile(remotePath), isNotNull);
      await expectNoTransferArtifacts(remoteDir);

      // 覆盖已存在的远程文件：内容必须完全替换，且不残留临时文件
      const textV2 = '覆盖后：第二版 🚀\n第二行\n';
      final bytesV2 = utf8.encode(textV2);
      await File(localPath).writeAsBytes(bytesV2, flush: true);
      final overwriteResult = await upload(localPath, remotePath);
      expect(overwriteResult.success, isTrue,
          reason: overwriteResult.error ?? overwriteResult.output);
      expect(await readRemote(remotePath), bytesV2);
      await expectNoTransferArtifacts(remoteDir);

      // 下载到已存在目录：自动拼接远程文件名
      final downloadDir = Directory(p.join(localRoot.path, '下载 目录 😀'));
      await downloadDir.create(recursive: true);
      final downloadResult = await download(remotePath, downloadDir.path);
      expect(downloadResult.success, isTrue,
          reason: downloadResult.error ?? downloadResult.output);
      final downloadedPath = p.join(downloadDir.path, '配置 名称 😀.txt');
      expect(await File(downloadedPath).readAsBytes(), bytesV2);
      expect(
        downloadDir
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path)),
        isNot(anyElement(endsWith('.part'))),
      );

      // 覆盖已存在的本地文件：原子替换后内容为最新版本
      const textV3 = '第三版：本地覆盖 ✅\r\n';
      final bytesV3 = utf8.encode(textV3);
      await File(localPath).writeAsBytes(bytesV3, flush: true);
      expect((await upload(localPath, remotePath)).success, isTrue);
      expect((await download(remotePath, downloadedPath)).success, isTrue);
      expect(await File(downloadedPath).readAsBytes(), bytesV3);
      expect(
        downloadDir
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path)),
        isNot(anyElement(endsWith('.part'))),
      );

      // BOM + CRLF + 无尾换行：逐字节一致
      final bomBytes = <int>[
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('BOM 第一行\r\nBOM 第二行 😀\r\nBOM 无尾'),
      ];
      final bomLocal = p.join(localDir.path, 'bom.txt');
      const bomRemote = '$remoteDir/bom.txt';
      await File(bomLocal).writeAsBytes(bomBytes, flush: true);
      expect((await upload(bomLocal, bomRemote)).success, isTrue);
      expect(await readRemote(bomRemote), bomBytes);
      final bomDownload = p.join(downloadDir.path, 'bom 下载.txt');
      expect((await download(bomRemote, bomDownload)).success, isTrue);
      expect(await File(bomDownload).readAsBytes(), bomBytes);
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('binary and large file upload/download match SHA-256', () async {
      final rand = Random(20261026);
      final payload = Uint8List(2 * 1024 * 1024 + 37);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = rand.nextInt(256);
      }
      payload[0] = 0x00;
      payload[1] = 0xFF;
      payload[2] = 0xFE;

      final localPath = p.join(localRoot.path, 'payload.bin');
      const remotePath = '$_remoteRoot/payload.bin';
      await File(localPath).writeAsBytes(payload, flush: true);
      final expectedSha = _sha256(payload);

      final uploadResult = await upload(localPath, remotePath);
      expect(uploadResult.success, isTrue,
          reason: uploadResult.error ?? uploadResult.output);
      expect(await readRemote(remotePath), payload);

      final remoteShaResult =
          await ssh.executeAndWait('sha256sum ${_shq(remotePath)}');
      expect(remoteShaResult.success, isTrue);
      expect(remoteShaResult.stdout, contains(expectedSha));

      final downloadedPath = p.join(localRoot.path, 'payload 下载.bin');
      final downloadResult = await download(remotePath, downloadedPath);
      expect(downloadResult.success, isTrue,
          reason: downloadResult.error ?? downloadResult.output);
      final downloaded = await File(downloadedPath).readAsBytes();
      expect(downloaded.length, payload.length);
      expect(_sha256(downloaded), expectedSha);
      expect(File(downloadedPath).existsSync(), isTrue);
      expect(
        localRoot
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path)),
        isNot(anyElement(endsWith('.part'))),
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('recursive directory upload/download keeps tree, empty dir and excludes',
        () async {
      final source = Directory(p.join(localRoot.path, 'tree 源 😀'));
      final sub = Directory(p.join(source.path, 'sub'));
      final emptyDir = Directory(p.join(source.path, 'empty-dir'));
      final ignored = Directory(p.join(source.path, 'node_modules'));
      final nestedIgnored = Directory(p.join(sub.path, 'node_modules'));
      final gitDir = Directory(p.join(source.path, '.git'));
      await sub.create(recursive: true);
      await emptyDir.create(recursive: true);
      await ignored.create(recursive: true);
      await nestedIgnored.create(recursive: true);
      await gitDir.create(recursive: true);

      final files = <String, List<int>>{
        p.join(source.path, 'index.html'):
            utf8.encode('<h1>首页 中文 😀</h1>\r\n'),
        p.join(sub.path, '中文 文件.txt'): utf8.encode('子目录内容\n无尾换行'),
        p.join(sub.path, 'emoji 😀.log'): utf8.encode('log 😀🚀\r\nline2\r\n'),
        p.join(ignored.path, 'ignored.js'): utf8.encode('ignored'),
        p.join(nestedIgnored.path, 'nested.txt'): utf8.encode('ignored nested'),
        p.join(gitDir.path, 'config'): utf8.encode('ignored git'),
      };
      for (final entry in files.entries) {
        await File(entry.key).writeAsBytes(entry.value, flush: true);
      }

      const remoteBase = '$_remoteRoot/部署 目标 😀';
      final uploadResult = await upload(source.path, remoteBase, recursive: true);
      expect(uploadResult.success, isTrue,
          reason: uploadResult.error ?? uploadResult.output);

      const remoteTree = '$remoteBase/tree 源 😀';
      expect(await readRemote('$remoteTree/index.html'),
          files[p.join(source.path, 'index.html')]);
      expect(await readRemote('$remoteTree/sub/中文 文件.txt'),
          files[p.join(sub.path, '中文 文件.txt')]);
      expect(await readRemote('$remoteTree/sub/emoji 😀.log'),
          files[p.join(sub.path, 'emoji 😀.log')]);

      final remoteEmpty = await sftp.statFile('$remoteTree/empty-dir');
      expect(remoteEmpty, isNotNull);
      expect(remoteEmpty!.isDirectory, isTrue);
      expect(await sftp.statFile('$remoteTree/node_modules'), isNull);
      expect(await sftp.statFile('$remoteTree/sub/node_modules'), isNull);
      expect(await sftp.statFile('$remoteTree/.git'), isNull);
      await expectNoTransferArtifacts(remoteTree);

      // 目录下载：local 传父目录，自动创建 basename(remote) 子目录
      final restoreParent = Directory(p.join(localRoot.path, 'restore'));
      await restoreParent.create(recursive: true);
      final downloadResult =
          await download(remoteTree, restoreParent.path, recursive: true);
      expect(downloadResult.success, isTrue,
          reason: downloadResult.error ?? downloadResult.output);

      final restored = Directory(p.join(restoreParent.path, 'tree 源 😀'));
      expect(await restored.exists(), isTrue);
      expect(await Directory(p.join(restored.path, 'empty-dir')).exists(),
          isTrue);

      final restoredFiles = <String, List<int>>{};
      await for (final entity
          in restored.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final rel = p.relative(entity.path, from: restored.path);
          restoredFiles[rel] = await entity.readAsBytes();
        }
      }

      final expectedRelative = <String, List<int>>{
        'index.html': files[p.join(source.path, 'index.html')]!,
        p.join('sub', '中文 文件.txt'):
            files[p.join(sub.path, '中文 文件.txt')]!,
        p.join('sub', 'emoji 😀.log'):
            files[p.join(sub.path, 'emoji 😀.log')]!,
      };
      expect(restoredFiles.keys.toSet(), expectedRelative.keys.toSet());
      for (final entry in expectedRelative.entries) {
        expect(restoredFiles[entry.key], entry.value,
            reason: '下载内容不一致: ${entry.key}');
      }

      // 目录未设置 recursive → 明确拒绝
      final noRecursive = await upload(source.path, '$_remoteRoot/no-recursive');
      expect(noRecursive.success, isFalse);
      expect(noRecursive.error, contains('recursive'));
      expect(await sftp.statFile('$_remoteRoot/no-recursive'), isNull);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('special-character names round trip without shell interpretation',
        () async {
      // Windows 本地文件名不允许双引号，因此本地/远程使用不同名字：
      // 远程包含引号/空格/emoji/中文，本地包含 $、反引号、&、;、空格和 emoji。
      // 传输全程走 SFTP，不能经过 shell 解释。
      const localName = r'本地 $NAME `tick` & ; (1) 😀.txt';
      const remoteName = r'''特殊 $NAME `tick` "double" 'single' & ; (1) 😀.txt''';
      final content = utf8.encode('特殊文件名内容 😀\n\$HOME `id` & ;\n');
      final localPath = p.join(localRoot.path, localName);
      const remotePath = '$_remoteRoot/特殊 目录 😀/$remoteName';
      await File(localPath).writeAsBytes(content, flush: true);

      final uploadResult = await upload(localPath, remotePath);
      expect(uploadResult.success, isTrue,
          reason: uploadResult.error ?? uploadResult.output);
      expect(await readRemote(remotePath), content);

      final downloadDir = Directory(p.join(localRoot.path, '特殊 下载 😀'));
      await downloadDir.create(recursive: true);
      final downloadTarget = p.join(downloadDir.path, localName);
      final downloadResult = await download(remotePath, downloadTarget);
      expect(downloadResult.success, isTrue,
          reason: downloadResult.error ?? downloadResult.output);
      final downloaded = File(downloadTarget);
      expect(await downloaded.readAsBytes(), content);
      expect(downloaded.existsSync(), isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('failure paths do not corrupt existing files or leave partial files',
        () async {
      // 1) 本地源不存在
      final missingUpload = await upload(
        p.join(localRoot.path, 'not-exist.txt'),
        '$_remoteRoot/not-exist-target.txt',
      );
      expect(missingUpload.success, isFalse);
      expect(await sftp.statFile('$_remoteRoot/not-exist-target.txt'), isNull);

      // 2) 远程目标不存在
      final missingDownload = await download(
        '$_remoteRoot/not-exist-remote.txt',
        p.join(localRoot.path, 'not-exist-local.txt'),
      );
      expect(missingDownload.success, isFalse);
      expect(File(p.join(localRoot.path, 'not-exist-local.txt')).existsSync(),
          isFalse);

      // 3) 远程目录未 recursive
      const remoteDir = '$_remoteRoot/failure-dir';
      await sftp.ensureDirectory(remoteDir);
      await ssh.executeAndWait(
          'printf keep > ${_shq('$remoteDir/sentinel.txt')}');
      final dirAsFile = await download(remoteDir,
          p.join(localRoot.path, 'failure-dir-local.txt'));
      expect(dirAsFile.success, isFalse);
      expect(dirAsFile.error, contains('目录'));
      expect(File(p.join(localRoot.path, 'failure-dir-local.txt')).existsSync(),
          isFalse);

      // 4) 上传目标本身是已存在目录：必须拒绝，且目录和内部文件不受影响
      final localFile = p.join(localRoot.path, 'upload-into-dir.txt');
      await File(localFile).writeAsString('should-not-land');
      final uploadIntoDir = await upload(localFile, remoteDir);
      expect(uploadIntoDir.success, isFalse);
      final dirStat = await sftp.statFile(remoteDir);
      expect(dirStat, isNotNull);
      expect(dirStat!.isDirectory, isTrue);
      expect(utf8.decode(await readRemote('$remoteDir/sentinel.txt')), 'keep');
      await expectNoTransferArtifacts(remoteDir);

      // 5) 本地父路径是文件：下载失败，原文件不被改写
      final blocker = File(p.join(localRoot.path, 'blocker'));
      await blocker.writeAsString('blocker-content');
      final badLocal = await download(
        '$_remoteRoot/payload.bin',
        p.join(blocker.path, 'child.bin'),
      );
      expect(badLocal.success, isFalse);
      expect(await blocker.readAsString(), 'blocker-content');

      // 6) 服务器不可写路径：失败且目标不存在
      const unwritableTarget = '/proc/ai_terminal_should_fail.txt';
      final unwritable = await upload(localFile, unwritableTarget);
      expect(unwritable.success, isFalse);
      expect(await sftp.statFile(unwritableTarget), isNull);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('orchestration upload_to/broadcast_upload/collect_file use real SFTP',
        () async {
      final registry = AgentHostRegistry()
        ..setExecutor('web1', ssh)
        ..setExecutor('web2', ssh);
      final multi = MultiHostExecutor(registry);

      final localPath = p.join(localRoot.path, 'orchestration 源 😀.txt');
      final localBytes = utf8.encode('编排传输：中文 😀\r\n\$HOME `id`\n');
      await File(localPath).writeAsBytes(localBytes, flush: true);

      const remoteSingle = '$_remoteRoot/orchestration/web1/app 文件 😀.txt';
      final uploadTo = await UploadToTool(multi).execute(
        executor: ssh,
        args: {'hostId': 'web1', 'local': localPath, 'remote': remoteSingle},
      );
      expect(uploadTo.success, isTrue,
          reason: uploadTo.error ?? uploadTo.output);
      expect(await readRemote(remoteSingle), localBytes);

      const remoteBroadcast = '$_remoteRoot/orchestration/broadcast';
      final broadcast = await BroadcastUploadTool(multi).execute(
        executor: ssh,
        args: {
          'hostIds': ['web1', 'web2'],
          'local': localPath,
          'remote': remoteBroadcast,
        },
      );
      expect(broadcast.success, isTrue,
          reason: broadcast.error ?? broadcast.output);
      expect(
        await readRemote(
            '$remoteBroadcast/${p.basename(localPath)}'),
        localBytes,
      );

      final collectDir = Directory(p.join(localRoot.path, 'collect 结果 😀'));
      final collect = await CollectFileTool(multi).execute(
        executor: ssh,
        args: {
          'hostIds': ['web1', 'web2'],
          'remote': remoteSingle,
          'localDir': collectDir.path,
        },
      );
      expect(collect.success, isTrue, reason: collect.error ?? collect.output);
      final remoteBase = p.posix.basename(remoteSingle);
      expect(await File(p.join(collectDir.path, 'web1_$remoteBase'))
          .readAsBytes(), localBytes);
      expect(await File(p.join(collectDir.path, 'web2_$remoteBase'))
          .readAsBytes(), localBytes);
      expect(
        collectDir
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path)),
        isNot(anyElement(endsWith('.part'))),
      );
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('remote file_patch plain old/new keeps other bytes intact', () async {
      const path = '$_remoteRoot/plain_patch 中文 😀.conf';
      final prefix = <int>[0xEF, 0xBB, 0xBF];
      final head = utf8.encode('第一行：保留 😀\r\nlisten 80;\r\n第三行：保留 ✅\r\n');
      final invalidTail = <int>[0xFF, 0xFE, 0x00];
      await sftp.writeFileBytes(
          path, Uint8List.fromList([...prefix, ...head, ...invalidTail]));

      final result = await FilePatchTool().execute(
        executor: ssh,
        args: {
          'path': path,
          'old': 'listen 80;',
          'new': 'listen 8080;',
          'backup': false,
        },
      );
      expect(result.success, isTrue, reason: result.error ?? result.output);
      expect(result.diffAdditions, 1);
      expect(result.diffDeletions, 1);

      final expected = <int>[
        ...prefix,
        ...utf8.encode('第一行：保留 😀\r\nlisten 8080;\r\n第三行：保留 ✅\r\n'),
        ...invalidTail,
      ];
      expect(await readRemote(path), expected);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('SFTP text editor round-trips text and refuses truncation risks',
        () async {
      const editorPath = '$_remoteRoot/editor 文本 😀.txt';
      const text = '第一行：中文 😀\r\n第二行：保留 CRLF\n第三行：无尾';
      await sftp.writeFileContent(editorPath, text);
      expect(await sftp.readFileContent(editorPath), text);

      // BOM + CRLF 经编辑器读/写后逐字节保留
      const bomPath = '$_remoteRoot/editor_bom.txt';
      final bomBytes = <int>[
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('BOM 第一行\r\nBOM 第二行 😀\r\n'),
      ];
      await sftp.writeFileBytes(bomPath, Uint8List.fromList(bomBytes));
      final bomText = await sftp.readFileContent(bomPath);
      await sftp.writeFileContent(bomPath, bomText);
      expect(await readRemote(bomPath), bomBytes);

      // 权限位不应因编辑器保存而改变
      const modePath = '$_remoteRoot/editor_mode.conf';
      await sftp.writeFileContent(modePath, 'keep-mode\n');
      await ssh.executeAndWait('chmod 600 ${_shq(modePath)}');
      final beforeMode = (await sftp.statFile(modePath))!.mode?.value ?? 0;
      await sftp.writeFileContent(modePath, 'keep-mode-updated\n');
      final afterMode = (await sftp.statFile(modePath))!.mode?.value ?? 0;
      expect(afterMode & 0x1FF, beforeMode & 0x1FF);

      // 非 UTF-8 文件：拒绝打开（否则保存会用替换字符覆盖原字节）
      const binaryPath = '$_remoteRoot/editor_binary.bin';
      await sftp.writeFileBytes(
          binaryPath, Uint8List.fromList([0xFF, 0xFE, 0x00, 0x01]));
      await expectLater(
        sftp.readFileContent(binaryPath),
        throwsA(predicate((e) => e.toString().contains('UTF-8'))),
      );

      // 超过读取上限：拒绝打开，避免“只保存前半部分”
      const largePath = '$_remoteRoot/editor_large.txt';
      final largeBytes = utf8.encode('A' * (100 * 1024 + 1));
      await sftp.writeFileBytes(largePath, Uint8List.fromList(largeBytes));
      await expectLater(
        sftp.readFileContent(largePath),
        throwsA(predicate((e) => e.toString().contains('文件过大'))),
      );
      expect(await readRemote(largePath), largeBytes);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('single file download with explicit local file path and trailing separator',
        () async {
      const remotePath = '$_remoteRoot/trailing-remote.txt';
      final content = utf8.encode('trailing separator test ✅');
      final localSource = p.join(localRoot.path, 'trailing-source.txt');
      await File(localSource).writeAsBytes(content, flush: true);
      expect((await upload(localSource, remotePath)).success, isTrue);

      final explicitTarget = p.join(localRoot.path, 'explicit-target.txt');
      expect((await download(remotePath, explicitTarget)).success, isTrue);
      expect(await File(explicitTarget).readAsBytes(), content);

      final dir = Directory(p.join(localRoot.path, 'trailing-dir'));
      await dir.create();
      final withSeparator = '${dir.path}${Platform.pathSeparator}';
      expect((await download(remotePath, withSeparator)).success, isTrue);
      expect(
          await File(p.join(dir.path, 'trailing-remote.txt')).readAsBytes(),
          content);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
