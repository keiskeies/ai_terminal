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
      final entryPath = p.join(path, name.filename);

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
}
