import 'dart:async';
import 'dart:io';
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
  final int size;
  final DateTime? modifiedTime;
  final int permissions;

  SftpEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
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

    // 1. 收集所有要上传的文件（排除指定目录）
    await for (final entity in localDirObj.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        // 检查路径里是否包含排除目录
        final relative = p.relative(entity.path, from: localDir);
        final parts = p.split(relative);
        final excluded = parts.any((part) => excludeNames.contains(part));
        if (!excluded) {
          allFiles.add(entity);
        }
      }
    }
    result.totalFiles = allFiles.length;

    // 2. 确保远程根目录存在
    await _ensureRemoteDir(remoteDir);

    // 3. 逐个上传
    for (final file in allFiles) {
      final relative = p.relative(file.path, from: localDir);
      // R6: 远程路径用 posix join
      final remotePath = p.posix.join(remoteDir, p.posix.split(relative).join('/'));
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
  Future<void> _ensureRemoteDir(String remotePath) async {
    if (_sftp == null) throw Exception('SFTP 未连接');
    if (remotePath.isEmpty || remotePath == '.' || remotePath == '/') return;

    // 检查是否已存在
    try {
      final stat = await _sftp!.stat(remotePath);
      if (stat.isDirectory) return;
    } catch (_) {
      // 不存在，继续创建
    }

    // 递归创建父目录
    final parent = p.posix.dirname(remotePath);
    if (parent != remotePath) {
      await _ensureRemoteDir(parent);
    }

    try {
      await _sftp!.mkdir(remotePath);
    } catch (_) {
      // 可能已被并发创建，忽略
    }
  }

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

  /// 删除文件
  Future<void> deleteFile(String path) async {
    if (_sftp == null) throw Exception('SFTP 未连接');
    await _sftp!.remove(path);
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

  /// 下载文件到本地
  Future<void> downloadFile(String remotePath, String localPath,
      {void Function(int, int)? onProgress}) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final file = await _sftp!.open(remotePath);
    final stat = await file.stat();
    final totalSize = stat.size ?? 0;

    final sink = File(localPath).openWrite();
    try {
      int offset = 0;
      await for (final chunk in file.read(onProgress: (bytesRead) {
        onProgress?.call(bytesRead, totalSize);
      })) {
        sink.add(chunk);
        offset += chunk.length;
      }
    } finally {
      await sink.close();
      await file.close();
    }
  }

  /// 上传本地文件到远程
  Future<void> uploadFile(String localPath, String remotePath,
      {void Function(int, int)? onProgress}) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final localFile = File(localPath);
    final totalSize = await localFile.length();

    final remoteFile = await _sftp!.open(
      remotePath,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );

    try {
      final stream = localFile.openRead().map((chunk) => Uint8List.fromList(chunk));
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
  }

  /// 读取文件内容（小文件预览）
  Future<String> readFileContent(String path, {int maxSize = 1024 * 100}) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final file = await _sftp!.open(path);
    try {
      final data = await file.readBytes(length: maxSize);
      return String.fromCharCodes(data);
    } finally {
      await file.close();
    }
  }

  /// 写入文件内容（编辑后保存）
  Future<void> writeFileContent(String path, String content) async {
    if (_sftp == null) throw Exception('SFTP 未连接');

    final remoteFile = await _sftp!.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    try {
      final data = Uint8List.fromList(content.codeUnits);
      final stream = Stream.fromIterable([data]);
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
