import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;
import '../models/host_config.dart';
import '../core/credentials_store.dart';

/// SFTP 文件条目
class SftpEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final bool isSymbolicLink;
  final int size;
  final DateTime? modifiedTime;
  final int permissions;

  SftpEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.isSymbolicLink = false,
    this.size = 0,
    this.modifiedTime,
    this.permissions = 0,
  });

  String get displaySize {
    if (isDirectory) return '--';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String get displayPermissions {
    final mode = permissions;
    final owner = _permChar(mode, 8, 'r') + _permChar(mode, 7, 'w') + _execChar(mode, 6);
    final group = _permChar(mode, 5, 'r') + _permChar(mode, 4, 'w') + _execChar(mode, 3);
    final other = _permChar(mode, 2, 'r') + _permChar(mode, 1, 'w') + _execChar(mode, 0);
    return (isDirectory ? 'd' : '-') + owner + group + other;
  }

  String get displayModifiedTime {
    if (modifiedTime == null) return '--';
    final d = modifiedTime!;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _permChar(int mode, int bit, String char) =>
      (mode & (1 << bit)) != 0 ? char : '-';
  String _execChar(int mode, int bit) =>
      (mode & (1 << bit)) != 0 ? 'x' : '-';
}

/// 目录上传结果
class UploadDirectoryResult {
  int totalFiles = 0;
  int uploadedFiles = 0;
  List<String> failedFiles = [];
  List<String> errors = [];

  bool get allSuccess => failedFiles.isEmpty;

  String get summary {
    final buffer = StringBuffer();
    buffer.writeln('上传完成: $uploadedFiles/$totalFiles 个文件');
    if (failedFiles.isNotEmpty) {
      buffer.writeln('失败 ${failedFiles.length} 个:');
      for (final f in failedFiles.take(5)) {
        buffer.writeln('  - $f');
      }
      if (failedFiles.length > 5) {
        buffer.writeln('  ...(共 ${failedFiles.length} 个失败)');
      }
      if (errors.isNotEmpty) {
        buffer.writeln('失败原因:');
        for (final e in errors.take(3)) {
          buffer.writeln('  - $e');
        }
      }
    }
    return buffer.toString().trimRight();
  }
}

/// 目录下载结果
class DownloadDirectoryResult {
  int totalFiles = 0;
  int downloadedFiles = 0;
  List<String> failedFiles = [];
  List<String> errors = [];
  List<String> skippedLinks = [];

  bool get allSuccess => failedFiles.isEmpty;

  String get summary {
    final buffer = StringBuffer();
    buffer.writeln('下载完成: $downloadedFiles/$totalFiles 个文件');
    if (skippedLinks.isNotEmpty) {
      buffer.writeln('跳过 ${skippedLinks.length} 个符号链接:');
      for (final f in skippedLinks.take(5)) {
        buffer.writeln('  - $f');
      }
    }
    if (failedFiles.isNotEmpty) {
      buffer.writeln('失败 ${failedFiles.length} 个:');
      for (final f in failedFiles.take(5)) {
        buffer.writeln('  - $f');
      }
      if (failedFiles.length > 5) {
        buffer.writeln('  ...(共 ${failedFiles.length} 个失败)');
      }
      if (errors.isNotEmpty) {
        buffer.writeln('失败原因:');
        for (final e in errors.take(3)) {
          buffer.writeln('  - $e');
        }
      }
    }
    return buffer.toString().trimRight();
  }
}

/// SFTP 服务
class SftpService {
  SSHClient? _client;
  SSHSocket? _socket;
  SftpClient? _sftp;
  SSHClient? _jumpClient;
  SSHSocket? _jumpSocket;
  bool _isConnected = false;

  bool get isConnected => _isConnected;

  /// 连接 SSH 并打开 SFTP 子系统
  Future<void> connect({
    required HostConfig config,
    String? password,
    String? privateKeyContent,
  }) async {
    try {
      // 跳板机
      if (config.hasJumpHost) {
        final jumpConfig = HostConfig.create(
          id: '${config.id}_jump',
          name: '跳板机 ${config.jumpHost}',
          host: config.jumpHost!,
          port: config.jumpPort,
          username: config.jumpUsername ?? 'root',
          authType: config.jumpAuthType ?? 'password',
        );
        final jumpPassword = await CredentialsStore.get(
          hostId: '${config.id}_jump', type: 'password',
        );
        final jumpPrivateKey = await CredentialsStore.get(
          hostId: '${config.id}_jump', type: 'privateKey',
        );

        _jumpSocket = await SSHSocket.connect(jumpConfig.host, jumpConfig.port);
        _jumpClient = SSHClient(
          _jumpSocket!,
          username: jumpConfig.username,
          onPasswordRequest: () => jumpPassword ?? '',
          identities: jumpPrivateKey != null
              ? [...SSHKeyPair.fromPem(jumpPrivateKey)]
              : null,
        );
        final forwardSocket = await _jumpClient!.forwardLocal(config.host, config.port);
        _socket = forwardSocket;
      } else {
        _socket = await SSHSocket.connect(config.host, config.port);
      }

      _client = SSHClient(
        _socket!,
        username: config.username,
        onPasswordRequest: () => password ?? '',
        identities: privateKeyContent != null
            ? [...SSHKeyPair.fromPem(privateKeyContent)]
            : null,
      );

      _sftp = await _client!.sftp();
      _isConnected = true;
    } catch (e) {
      _isConnected = false;
      rethrow;
    }
  }

  /// 复用已有 SSH 连接打开 SFTP 子系统（避免重新建连）
  /// 用于 agent 工具调用场景：从 SSHService 拿到已认证的 SSHClient
  Future<void> attachToClient(SSHClient client) async {
    try {
      _client = client;
      _sftp = await client.sftp();
      _isConnected = true;
    } catch (e) {
      _isConnected = false;
      rethrow;
    }
  }

  /// 递归上传本地目录到远程
  /// [localDir] 本地目录绝对路径
  /// [remoteDir] 远程目标目录绝对路径（不存在会自动创建）
  /// [excludeNames] 要跳过的文件/目录名（如 node_modules、.git）
  /// [onProgress] 进度回调 (uploadedFiles, totalFiles)
  Future<UploadDirectoryResult> uploadDirectory(
    String localDir,
    String remoteDir, {
    List<String> excludeNames = const ['node_modules', '.git', '.DS_Store'],
    void Function(int uploaded, int total)? onProgress,
  }) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final localDirObj = Directory(localDir);
    if (!await localDirObj.exists()) {
      throw Exception('本地目录不存在: $localDir');
    }

    final result = UploadDirectoryResult();
    final allFiles = <File>[];
    final allDirs = <String>[];

    // 1. 收集所有要上传的文件和目录（排除指定目录）
    await for (final entity in localDirObj.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: localDir);
      final parts = p.split(relative);
      final excluded = parts.any((part) => excludeNames.contains(part));
      if (excluded) continue;
      if (entity is File) {
        allFiles.add(entity);
      } else if (entity is Directory) {
        allDirs.add(relative);
      }
    }
    result.totalFiles = allFiles.length;

    // 2. 确保远程根目录存在，并保留空目录结构
    await _ensureRemoteDir(remoteDir);
    for (final dir in allDirs) {
      // dir 来自 p.relative（本机路径），必须先按本机分隔符拆分，
      // 再统一用 '/' 拼成远程路径；对 Windows 相对路径用 p.posix.split
      // 会把 "sub\a.txt" 当成单个文件名，导致平铺出带反斜杠的文件名。
      final remoteDirPath = p.posix.join(remoteDir, p.split(dir).join('/'));
      await _ensureRemoteDir(remoteDirPath);
    }

    // 3. 逐个上传
    for (final file in allFiles) {
      final relative = p.relative(file.path, from: localDir);
      // R6: 远程路径用 posix join
      final remotePath = p.posix.join(remoteDir, p.split(relative).join('/'));
      final remoteParent = p.posix.dirname(remotePath);

      // 确保远程父目录存在
      await _ensureRemoteDir(remoteParent);

      try {
        await uploadFile(file.path, remotePath);
        result.uploadedFiles++;
        onProgress?.call(result.uploadedFiles, result.totalFiles);
      } catch (e) {
        result.failedFiles.add(relative);
        result.errors.add('$relative: $e');
      }
    }

    return result;
  }

  /// 递归确保远程目录存在（类似 mkdir -p）
  Future<void> _ensureRemoteDir(String remotePath) => ensureDirectory(remotePath);

  /// 列出目录内容
  Future<List<SftpEntry>> listDirectory(String path) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final names = await _sftp!.listdir(path);
    final items = <SftpEntry>[];

    for (final name in names) {
      // 跳过 . 和 ..
      if (name.filename == '.' || name.filename == '..') continue;

      final attr = name.attr;
      final isDir = attr.isDirectory;
      final entryPath = p.posix.join(path, name.filename);

      items.add(SftpEntry(
        name: name.filename,
        path: entryPath,
        isDirectory: isDir,
        isSymbolicLink: attr.isSymbolicLink,
        size: attr.size ?? 0,
        modifiedTime: attr.modifyTime != null
            ? DateTime.fromMillisecondsSinceEpoch(attr.modifyTime! * 1000)
            : null,
        permissions: attr.mode?.value ?? 0,
      ));
    }

    // 排序：目录在前，然后按名称
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return items;
  }

  /// 获取当前工作目录的绝对路径
  Future<String> getCurrentDirectory() async {
    if (_sftp == null) throw Exception('SFTP 未连接');
    return _sftp!.absolute('.');
  }

  /// 创建目录
  Future<void> createDirectory(String path) async {
    if (_sftp == null) throw Exception('SFTP 未连接');
    await _sftp!.mkdir(path);
  }

  /// 幂等确保远程目录存在（mkdir -p 语义）
  ///
  /// 文件写入/上传类工具只关心“父目录可用”，目标目录已存在时不能报错。
  /// 面板的“新建文件夹”仍使用 [createDirectory]，保留重复创建时的错误提示。
  Future<void> ensureDirectory(String path) async {
    if (_sftp == null) throw Exception('SFTP 未连接');
    if (path.isEmpty || path == '.' || path == '/') return;

    try {
      final stat = await _sftp!.stat(path);
      if (stat.isDirectory) return;
    } catch (_) {
      // 不存在，继续创建
    }

    final parent = p.posix.dirname(path);
    if (parent != path) {
      await ensureDirectory(parent);
    }

    try {
      await _sftp!.mkdir(path);
    } catch (e) {
      // 并发创建或目录已存在：stat 确认后视为成功
      try {
        final stat = await _sftp!.stat(path);
        if (stat.isDirectory) return;
      } catch (_) {}
      rethrow;
    }
  }

  /// 删除文件
  Future<void> deleteFile(String path) async {
    if (_sftp == null) throw Exception('SFTP 未连接');
    await _sftp!.remove(path);
  }

  /// 获取文件属性（大小 + 修改时间），用于 H1 原子性校验和 H2 文件存在校验
  /// 文件不存在时返回 null
  Future<SftpFileAttrs?> statFile(String path) async {
    if (_sftp == null) throw Exception('SFTP 未连接');
    try {
      return await _sftp!.stat(path);
    } catch (_) {
      return null;
    }
  }

  /// 远程文件复制（用于 H3/H5 备份）
  /// 通过 read → write 实现，不依赖服务端 cp 命令（跨平台兼容）
  Future<void> copyFile(String srcPath, String dstPath) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    // 读源文件
    final srcFile = await _sftp!.open(srcPath);
    final bytes = await srcFile.readBytes();
    await srcFile.close();

    // 写目标
    final dstFile = await _sftp!.open(
      dstPath,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    try {
      final stream = Stream.fromIterable([bytes]);
      final writer = dstFile.write(stream);
      await writer.done;
    } finally {
      await dstFile.close();
    }
  }

  /// 删除目录
  Future<void> deleteDirectory(String path) async {
    if (_sftp == null) throw Exception('SFTP 未连接');
    await _sftp!.rmdir(path);
  }

  /// 重命名
  Future<void> rename(String oldPath, String newPath) async {
    if (_sftp == null) throw Exception('SFTP 未连接');
    await _sftp!.rename(oldPath, newPath);
  }

  /// 生成临时文件名后缀（时间戳 + 安全随机数，避免并发冲突）
  String _tempToken() {
    final rand = Random.secure();
    final randomPart = List.generate(
      4,
      (_) => rand.nextInt(0x10000).toRadixString(16).padLeft(4, '0'),
    ).join();
    return '${DateTime.now().microsecondsSinceEpoch}-$randomPart';
  }

  /// 原子替换远程文件：优先使用 OpenSSH posix-rename；不支持覆盖语义时
  /// 先移走旧文件再落位，失败则恢复旧文件，避免目标被清空。
  Future<void> _renameReplace(String src, String dst) async {
    if (_sftp == null) throw Exception('SFTP 未连接');
    try {
      await _sftp!.rename(src, dst);
      return;
    } catch (_) {
      SftpFileAttrs? target;
      try {
        target = await _sftp!.stat(dst);
      } catch (_) {}
      if (target == null) rethrow;
      if (target.isDirectory) {
        throw Exception('目标路径是目录，不能按文件覆盖: $dst');
      }

      final oldPath = '$dst.ai-old-${_tempToken()}';
      await _sftp!.rename(dst, oldPath);
      try {
        await _sftp!.rename(src, dst);
      } catch (_) {
        try {
          await _sftp!.rename(oldPath, dst);
        } catch (_) {}
        rethrow;
      }
      try {
        await _sftp!.remove(oldPath);
      } catch (_) {}
    }
  }

  /// 下载文件到本地。
  ///
  /// 先写同目录临时文件，完整落盘后再原子替换目标；中途失败只删除临时文件，
  /// 不会把目标文件截断成半成品。自动创建本地父目录。
  Future<void> downloadFile(String remotePath, String localPath,
      {void Function(int, int)? onProgress}) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final localParent = p.dirname(localPath);
    if (localParent.isNotEmpty && localParent != '.') {
      await Directory(localParent).create(recursive: true);
    }
    final tempPath = '$localPath.ai-download-${_tempToken()}.part';

    final remoteStat = await statFile(remotePath);
    if (remoteStat == null) {
      throw Exception('远程文件不存在: $remotePath');
    }
    if (remoteStat.isDirectory) {
      throw Exception('远程路径是目录，不能按文件下载: $remotePath');
    }
    final totalSize = remoteStat.size ?? 0;

    final remoteFile = await _sftp!.open(remotePath);
    IOSink? sink;
    try {

      sink = File(tempPath).openWrite();
      await for (final chunk in remoteFile.read(onProgress: (bytesRead) {
        onProgress?.call(bytesRead, totalSize);
      })) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        final temp = File(tempPath);
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    } finally {
      await remoteFile.close();
    }

    try {
      await File(tempPath).rename(localPath);
    } catch (e) {
      throw Exception('下载已完成但保存到 $localPath 失败: $e；临时文件保留在 $tempPath');
    }
  }

  /// 上传本地文件到远程。
  ///
  /// 先写同目录远程临时文件，完整上传后再原子替换目标；中途失败只删除临时
  /// 文件，不会把服务器上的原文件截断成半成品。
  Future<void> uploadFile(String localPath, String remotePath,
      {void Function(int, int)? onProgress}) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final localFile = File(localPath);
    final totalSize = await localFile.length();

    final existing = await statFile(remotePath);
    if (existing != null && existing.isDirectory) {
      throw Exception('远程目标是目录，不能按文件上传: $remotePath');
    }

    final remoteParent = p.posix.dirname(remotePath);
    final tempName =
        '.${p.posix.basename(remotePath)}.ai-upload-${_tempToken()}.part';
    final tempPath = remoteParent == '.'
        ? tempName
        : p.posix.join(remoteParent, tempName);

    try {
      final remoteFile = await _sftp!.open(
        tempPath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        final stream =
            localFile.openRead().map((chunk) => Uint8List.fromList(chunk));
        final writer = remoteFile.write(
          stream,
          onProgress: (total) {
            onProgress?.call(total, totalSize);
          },
        );
        await writer.done;
      } finally {
        await remoteFile.close();
      }
      await _renameReplace(tempPath, remotePath);
    } catch (_) {
      try {
        await _sftp!.remove(tempPath);
      } catch (_) {}
      rethrow;
    }
  }

  /// 递归下载远程目录到本地
  /// [remoteDir] 远程目录绝对路径
  /// [localDir] 本地目标目录（不存在会自动创建）
  Future<DownloadDirectoryResult> downloadDirectory(
    String remoteDir,
    String localDir, {
    List<String> excludeNames = const ['node_modules', '.git', '.DS_Store'],
    void Function(int downloaded, int total)? onProgress,
  }) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final result = DownloadDirectoryResult();
    final relativeFiles = <String>[];
    final relativeDirs = <String>[];
    await _collectRemoteFiles(
      remoteDir,
      '',
      excludeNames,
      relativeFiles,
      relativeDirs,
      result,
    );
    result.totalFiles = relativeFiles.length;

    await Directory(localDir).create(recursive: true);
    for (final relative in relativeDirs) {
      final localPath = p.joinAll([localDir, ...p.posix.split(relative)]);
      await Directory(localPath).create(recursive: true);
    }
    for (final relative in relativeFiles) {
      final remotePath = p.posix.join(remoteDir, relative);
      final localPath = p.joinAll([localDir, ...p.posix.split(relative)]);
      try {
        await downloadFile(remotePath, localPath);
        result.downloadedFiles++;
        onProgress?.call(result.downloadedFiles, result.totalFiles);
      } catch (e) {
        result.failedFiles.add(relative);
        result.errors.add('$relative: $e');
      }
    }
    return result;
  }

  Future<void> _collectRemoteFiles(
    String dirPath,
    String relative,
    List<String> excludeNames,
    List<String> out,
    List<String> outDirs,
    DownloadDirectoryResult result,
  ) async {
    final entries = await listDirectory(dirPath);
    for (final entry in entries) {
      if (excludeNames.contains(entry.name)) continue;
      final childRelative = relative.isEmpty
          ? entry.name
          : p.posix.join(relative, entry.name);
      if (entry.isDirectory) {
        outDirs.add(childRelative);
        await _collectRemoteFiles(
          entry.path,
          childRelative,
          excludeNames,
          out,
          outDirs,
          result,
        );
      } else if (entry.isSymbolicLink) {
        // 不跟随符号链接，避免循环或下载到预期之外的目标
        result.skippedLinks.add(childRelative);
      } else {
        out.add(childRelative);
      }
    }
  }

  /// 读取文件内容（文本编辑器/预览）
  ///
  /// 超过 [maxSize] 或不是有效 UTF-8 时直接报错：编辑器保存会整文件覆盖，
  /// 若只读取前 N 字节再保存，会静默截断文件剩余内容。
  Future<String> readFileContent(String path, {int maxSize = 1024 * 100}) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final stat = await _sftp!.stat(path);
    if (stat.isDirectory) {
      throw Exception('远程路径是目录，不能作为文本读取: $path');
    }
    final size = stat.size;
    if (size != null && size > maxSize) {
      throw Exception(
        '文件过大 ($size 字节 > $maxSize 字节)，文本编辑器只读取部分内容会截断文件。'
        '请先下载到本地编辑，或用 file_patch 修改。',
      );
    }

    final file = await _sftp!.open(path);
    try {
      final data = await file.readBytes(length: maxSize + 1);
      if (data.length > maxSize) {
        throw Exception(
          '文件过大 (> $maxSize 字节)，文本编辑器只读取部分内容会截断文件。'
          '请先下载到本地编辑，或用 file_patch 修改。',
        );
      }
      // 严格 UTF-8：无效字节若被替换字符解码后再保存，会永久损坏原文件
      final text = utf8.decode(data);
      // Dart 的 utf8.decode 会自动去掉 BOM；编辑器保存时需原样带回
      final hasBom = data.length >= 3 &&
          data[0] == 0xEF &&
          data[1] == 0xBB &&
          data[2] == 0xBF;
      return hasBom ? '\uFEFF$text' : text;
    } on FormatException catch (e) {
      throw Exception('文件不是有效的 UTF-8 文本，无法在编辑器中打开: ${e.message}');
    } finally {
      await file.close();
    }
  }

  /// 写入文件内容（编辑后保存）
  ///
  /// 先保留原内容，写入失败时恢复，避免网络中断把原文件截断成半成品。
  Future<void> writeFileContent(String path, String content) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    Uint8List? previous;
    try {
      final stat = await _sftp!.stat(path);
      if (!stat.isDirectory && (stat.size ?? 0) <= 2 * 1024 * 1024) {
        previous = await readFileBytes(path, maxSize: 2 * 1024 * 1024 + 1);
      }
    } catch (_) {
      // 文件不存在或无权限读取：没有可恢复的旧内容
    }

    final data = Uint8List.fromList(utf8.encode(content));
    try {
      await writeFileBytes(path, data);
    } catch (e) {
      if (previous != null) {
        try {
          await writeFileBytes(path, previous);
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 追加文件内容（分块写入场景：AI 多次调用 file_write mode=append）
  ///
  /// 设计理由：AI 一次输出大文件 base64 易出错（>10KB 风险高），
  /// 强制分块写入：第一次 mode=write，后续 mode=append，每块保持小尺寸
  /// 保证 base64 编码不会算错。
  Future<void> appendFileContent(String path, String content) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final remoteFile = await _sftp!.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.append,
    );
    try {
      final data = Uint8List.fromList(utf8.encode(content));
      final stream = Stream.fromIterable([data]);
      final writer = remoteFile.write(stream);
      await writer.done;
    } finally {
      await remoteFile.close();
    }
  }

  /// 读取文件字节（用于 file_patch 唯一性校验和替换）
  Future<Uint8List> readFileBytes(String path, {int maxSize = 1024 * 1024}) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final file = await _sftp!.open(path);
    try {
      return await file.readBytes(length: maxSize);
    } finally {
      await file.close();
    }
  }

  /// 写入文件字节（truncate 模式，完全覆盖原文件）
  /// 用于 file_write mode=write
  Future<void> writeFileBytes(String path, Uint8List bytes) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final remoteFile = await _sftp!.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    try {
      final stream = Stream.fromIterable([bytes]);
      final writer = remoteFile.write(stream);
      await writer.done;
    } finally {
      await remoteFile.close();
    }
  }

  /// 追加文件字节（append 模式，写到文件末尾）
  /// 用于 file_write mode=append（分块写入场景）
  Future<void> appendFileBytes(String path, Uint8List bytes) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final remoteFile = await _sftp!.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.append,
    );
    try {
      final stream = Stream.fromIterable([bytes]);
      final writer = remoteFile.write(stream);
      await writer.done;
    } finally {
      await remoteFile.close();
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    _isConnected = false;
    _sftp?.close();
    _sftp = null;
    _client?.close();
    _socket?.destroy();
    _jumpClient?.close();
    _jumpSocket?.destroy();
    _client = null;
    _socket = null;
    _jumpClient = null;
    _jumpSocket = null;
  }

  /// 仅关闭 SFTP 子系统通道，不关闭借用的 SSHClient
  /// 用于 agent 工具（SftpUploadTool/UploadToTool）场景：
  /// SSHClient 是从 SSHService 借用的，不能在此关闭，否则会断开宿主 SSH 连接
  void closeSftpOnly() {
    _isConnected = false;
    _sftp?.close();
    _sftp = null;
    // 不关闭 _client（借用自 SSHService）
    _client = null;
  }
}
