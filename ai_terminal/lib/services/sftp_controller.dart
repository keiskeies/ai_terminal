import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/credentials_store.dart';
import '../models/host_config.dart';
import 'sftp_service.dart';

/// SFTP 排序字段常量
class SftpSortFields {
  static const name = 'name';
  static const size = 'size';
  static const modified = 'modified';
}

/// SFTP 面板业务逻辑控制器
///
/// 将 SFTP 连接管理、目录加载、排序、文件操作（CRUD/上传/下载/重命名/删除）
/// 从 UI 层下沉到 controller，State 仅持有 UI 状态并 watch controller。
///
/// controller 内部通过 [SftpService] 完成实际操作，凭据读取使用
/// [CredentialsStore]。方法执行成功后调用 [notifyListeners] 通知 UI 刷新；
/// 连接/目录加载出错时设置 [error] 字段并通知；文件操作出错时重新抛出异常，
/// 供 UI 层展示错误反馈。
class SftpController extends ChangeNotifier {
  final SftpService _sftpService = SftpService();

  // ===== 状态字段 =====
  List<SftpEntry> entries = [];
  String currentPath = '/';
  bool isLoading = false;
  bool isConnecting = false;
  String? error;
  final List<String> pathHistory = [];
  bool isTransferring = false;
  double transferProgress = 0;
  String transferName = '';

  // 排序状态
  String sortBy = SftpSortFields.name;
  bool sortAsc = true; // 名称默认升序

  /// 当前连接的主机名称（供 UI 显示）
  String? hostName;

  /// SFTP 是否已连接
  bool get isConnected => _sftpService.isConnected;

  /// 设置错误信息并通知 UI（用于连接前置条件失败等场景，如主机不存在）
  void setError(String message) {
    error = message;
    notifyListeners();
  }

  // ===== 方法 =====

  /// SFTP 连接 + 凭据读取 + 初始目录加载
  Future<void> connectAndLoad(HostConfig host) async {
    hostName = host.name;
    isConnecting = true;
    error = null;
    notifyListeners();

    try {
      final password = await CredentialsStore.get(hostId: host.id, type: 'password');
      final privateKey = await CredentialsStore.get(hostId: host.id, type: 'privateKey');

      if (password == null && privateKey == null) {
        isConnecting = false;
        error = '未找到登录凭据';
        notifyListeners();
        return;
      }

      await _sftpService.connect(
        config: host,
        password: password,
        privateKeyContent: privateKey,
      );

      final cwd = await _sftpService.getCurrentDirectory();
      currentPath = cwd;

      isConnecting = false;
      notifyListeners();
      await loadDirectory(cwd);
    } catch (e) {
      isConnecting = false;
      error = '连接失败: $e';
      notifyListeners();
    }
  }

  /// 加载指定路径
  Future<void> loadDirectory(String path) async {
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      final items = await _sftpService.listDirectory(path);
      currentPath = path;
      entries = items;
      _sortEntries();
      isLoading = false;
      notifyListeners();
    } catch (e) {
      isLoading = false;
      error = '读取目录失败: $e';
      notifyListeners();
    }
  }

  /// 导航到路径
  Future<void> navigateTo(String path) async {
    pathHistory.add(currentPath);
    await loadDirectory(path);
  }

  /// 返回上一级
  Future<void> goBack() async {
    if (pathHistory.isNotEmpty) {
      final prev = pathHistory.removeLast();
      await loadDirectory(prev);
    } else {
      final parent = p.posix.dirname(currentPath);
      if (parent != currentPath) {
        await loadDirectory(parent);
      }
    }
  }

  /// 切换排序
  void toggleSort(String field) {
    if (sortBy == field) {
      sortAsc = !sortAsc;
    } else {
      sortBy = field;
      sortAsc = true;
    }
    _sortEntries();
    notifyListeners();
  }

  void _sortEntries() {
    entries.sort((a, b) {
      // 目录始终在前
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;

      int cmp;
      switch (sortBy) {
        case SftpSortFields.size:
          cmp = a.size.compareTo(b.size);
        case SftpSortFields.modified:
          final aTime = a.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
          cmp = aTime.compareTo(bTime);
        default:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      return sortAsc ? cmp : -cmp;
    });
  }

  /// 下载文件到系统临时目录
  ///
  /// 成功后关闭 [isTransferring]；失败时同样关闭并重新抛出异常，
  /// 供 UI 层展示错误反馈（SnackBar）。
  Future<void> downloadFile(SftpEntry entry) async {
    isTransferring = true;
    transferProgress = 0;
    transferName = entry.name;
    notifyListeners();

    try {
      final tempDir = Directory.systemTemp;
      final localPath = '${tempDir.path}/${entry.name}';
      await _sftpService.downloadFile(
        entry.path,
        localPath,
        onProgress: (current, total) {
          transferProgress = total > 0 ? current / total : 0;
          notifyListeners();
        },
      );
      isTransferring = false;
      notifyListeners();
    } catch (e) {
      isTransferring = false;
      notifyListeners();
      rethrow;
    }
  }

  /// 重命名
  Future<void> renameEntry(SftpEntry entry, String newName) async {
    final newPath = p.posix.join(p.posix.dirname(entry.path), newName);
    await _sftpService.rename(entry.path, newPath);
    await loadDirectory(currentPath);
  }

  /// 删除文件或目录
  Future<void> deleteEntry(SftpEntry entry) async {
    if (entry.isDirectory) {
      await _sftpService.deleteDirectory(entry.path);
    } else {
      await _sftpService.deleteFile(entry.path);
    }
    await loadDirectory(currentPath);
  }

  /// 在当前目录下创建子目录
  Future<void> createDirectory(String name) async {
    final newPath = p.posix.join(currentPath, name);
    await _sftpService.createDirectory(newPath);
    await loadDirectory(currentPath);
  }

  /// 上传本地文件到远程路径
  ///
  /// 失败时关闭 [isTransferring] 并重新抛出异常，供 UI 层展示错误反馈。
  Future<void> uploadFile(String localPath, String remotePath) async {
    final fileName = p.basename(localPath);
    isTransferring = true;
    transferProgress = 0;
    transferName = fileName;
    notifyListeners();

    try {
      await _sftpService.uploadFile(
        localPath,
        remotePath,
        onProgress: (current, total) {
          transferProgress = total > 0 ? current / total : 0;
          notifyListeners();
        },
      );
      isTransferring = false;
      notifyListeners();
    } catch (e) {
      isTransferring = false;
      notifyListeners();
      rethrow;
    }
  }

  /// 读取文件内容（供编辑/预览用）
  Future<String?> readFile(String path) async {
    return _sftpService.readFileContent(path, maxSize: 1024 * 500);
  }

  /// 写入文件内容
  Future<void> writeFile(String path, String content) async {
    await _sftpService.writeFileContent(path, content);
  }

  @override
  void dispose() {
    _sftpService.disconnect();
    super.dispose();
  }
}
