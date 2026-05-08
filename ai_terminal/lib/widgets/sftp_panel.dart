import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/credentials_store.dart';
import '../models/host_config.dart';
import '../providers/app_providers.dart';
import '../services/sftp_service.dart';

/// 排序字段
enum _SftpSortBy { name, size, modified }

/// 可复用的 SFTP 面板组件，既可用于独立页面也可嵌入终端右侧
class SftpPanel extends ConsumerStatefulWidget {
  final String hostId;
  final VoidCallback? onClose; // 嵌入模式下的关闭回调
  final bool embedded; // 是否嵌入模式（无 AppBar）

  const SftpPanel({
    super.key,
    required this.hostId,
    this.onClose,
    this.embedded = false,
  });

  @override
  ConsumerState<SftpPanel> createState() => _SftpPanelState();
}

class _SftpPanelState extends ConsumerState<SftpPanel> {
  final SftpService _sftpService = SftpService();
  List<SftpEntry> _entries = [];
  String _currentPath = '/';
  bool _isLoading = false;
  bool _isConnecting = false;
  String? _error;
  final List<String> _pathHistory = [];
  String? _hostName;

  // 路径输入模式
  bool _isPathEditing = false;
  final _pathController = TextEditingController();
  final _pathFocusNode = FocusNode();

  // 上传/下载进度
  bool _isTransferring = false;
  double _transferProgress = 0;
  String _transferName = '';

  // 排序
  _SftpSortBy _sortBy = _SftpSortBy.name;
  bool _sortAsc = true; // 名称默认升序

  @override
  void initState() {
    super.initState();
    _connectAndLoad();
  }

  @override
  void dispose() {
    _pathController.dispose();
    _pathFocusNode.dispose();
    _sftpService.disconnect();
    super.dispose();
  }

  Future<void> _connectAndLoad() async {
    final host = ref.read(hostsProvider.notifier).getHostById(widget.hostId);
    if (host == null) {
      setState(() => _error = '主机不存在');
      return;
    }

    _hostName = host.name;
    setState(() => _isConnecting = true);

    try {
      final password = await CredentialsStore.get(hostId: host.id, type: 'password');
      final privateKey = await CredentialsStore.get(hostId: host.id, type: 'privateKey');

      if (password == null && privateKey == null) {
        setState(() {
          _isConnecting = false;
          _error = '未找到登录凭据';
        });
        return;
      }

      await _sftpService.connect(
        config: host,
        password: password,
        privateKeyContent: privateKey,
      );

      final cwd = await _sftpService.getCurrentDirectory();
      _currentPath = cwd;

      setState(() => _isConnecting = false);
      await _loadDirectory(cwd);
    } catch (e) {
      setState(() {
        _isConnecting = false;
        _error = '连接失败: $e';
      });
    }
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final entries = await _sftpService.listDirectory(path);
      setState(() {
        _currentPath = path;
        _entries = entries;
        _sortEntries();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = '读取目录失败: $e';
      });
    }
  }

  void _sortEntries() {
    _entries.sort((a, b) {
      // 目录始终在前
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;

      int cmp;
      switch (_sortBy) {
        case _SftpSortBy.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _SftpSortBy.size:
          cmp = a.size.compareTo(b.size);
        case _SftpSortBy.modified:
          final aTime = a.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b.modifiedTime ?? DateTime.fromMillisecondsSinceEpoch(0);
          cmp = aTime.compareTo(bTime);
      }
      return _sortAsc ? cmp : -cmp;
    });
  }

  void _toggleSort(_SftpSortBy sortBy) {
    setState(() {
      if (_sortBy == sortBy) {
        _sortAsc = !_sortAsc;
      } else {
        _sortBy = sortBy;
        _sortAsc = true;
      }
      _sortEntries();
    });
  }

  Future<void> _navigateTo(String path) async {
    _pathHistory.add(_currentPath);
    await _loadDirectory(path);
  }

  Future<void> _goBack() async {
    if (_pathHistory.isNotEmpty) {
      final prev = _pathHistory.removeLast();
      await _loadDirectory(prev);
    } else {
      final parent = p.dirname(_currentPath);
      if (parent != _currentPath) {
        await _loadDirectory(parent);
      }
    }
  }

  void _submitPath() {
    final path = _pathController.text.trim();
    if (path.isNotEmpty) {
      setState(() => _isPathEditing = false);
      _pathHistory.add(_currentPath);
      _loadDirectory(path);
    }
  }

  void _startPathEditing() {
    _pathController.text = _currentPath;
    setState(() => _isPathEditing = true);
    Future.delayed(const Duration(milliseconds: 50), () {
      _pathFocusNode.requestFocus();
    });
  }

  void _showEntryActions(SftpEntry entry) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rLarge)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Icon(
                    entry.isDirectory ? Icons.folder : Icons.insert_drive_file,
                    color: entry.isDirectory ? cWarning : cPrimary,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.name,
                      style: const TextStyle(fontWeight: FontWeight.w500, fontSize: fSmall),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (entry.isDirectory)
              _actionTile(Icons.folder_open, '打开', () {
                Navigator.pop(ctx);
                _navigateTo(entry.path);
              }),
            if (!entry.isDirectory)
              _actionTile(Icons.download, '下载到本地', () {
                Navigator.pop(ctx);
                _downloadFile(entry);
              }),
            if (!entry.isDirectory)
              _actionTile(Icons.visibility, '预览内容', () {
                Navigator.pop(ctx);
                _editOrPreviewFile(entry, readOnly: true);
              }),
            if (!entry.isDirectory)
              _actionTile(Icons.edit_outlined, '编辑', () {
                Navigator.pop(ctx);
                _editOrPreviewFile(entry, readOnly: false);
              }),
            _actionTile(Icons.drive_file_rename_outline, '重命名', () {
              Navigator.pop(ctx);
              _renameEntry(entry);
            }),
            _actionTile(
              Icons.delete,
              entry.isDirectory ? '删除目录' : '删除文件',
              () {
                Navigator.pop(ctx);
                _deleteEntry(entry);
              },
              color: cDanger,
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionTile(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color ?? cTextSub, size: 18),
      title: Text(label, style: TextStyle(color: color, fontSize: fSmall)),
      onTap: onTap,
    );
  }

  Future<void> _downloadFile(SftpEntry entry) async {
    setState(() {
      _isTransferring = true;
      _transferProgress = 0;
      _transferName = entry.name;
    });

    try {
      final tempDir = Directory.systemTemp;
      final localPath = '${tempDir.path}/${entry.name}';
      await _sftpService.downloadFile(
        entry.path,
        localPath,
        onProgress: (current, total) {
          setState(() {
            _transferProgress = total > 0 ? current / total : 0;
          });
        },
      );

      if (mounted) {
        setState(() => _isTransferring = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已下载到: $localPath'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isTransferring = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('下载失败: $e'),
            backgroundColor: cDanger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// 预览或编辑远程文件
  Future<void> _editOrPreviewFile(SftpEntry entry, {bool readOnly = false}) async {
    // 先加载文件内容
    String? content;
    try {
      content = await _sftpService.readFileContent(entry.path, maxSize: 1024 * 500);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取失败: $e'), backgroundColor: cDanger),
        );
      }
      return;
    }

    if (!mounted) return;

    final controller = TextEditingController(text: content);
    bool hasModified = false;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: Theme.of(context).dialogBackgroundColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
              titlePadding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              title: Row(
                children: [
                  Icon(Icons.insert_drive_file, size: 14, color: cPrimary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      entry.name,
                      style: const TextStyle(fontSize: fSmall),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (readOnly)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cTextMuted.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('只读', style: TextStyle(fontSize: 9, color: cTextMuted)),
                    ),
                  if (!readOnly && hasModified)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cWarning.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('已修改', style: TextStyle(fontSize: 9, color: cWarning)),
                    ),
                ],
              ),
              content: SizedBox(
                width: MediaQuery.of(context).size.width * 0.7,
                height: MediaQuery.of(context).size.height * 0.55,
                child: Container(
                  decoration: BoxDecoration(
                    color: ThemeColors.of(context).bg,
                    borderRadius: BorderRadius.circular(rSmall),
                  ),
                  padding: const EdgeInsets.all(6),
                  child: TextField(
                    controller: controller,
                    maxLines: null,
                    expands: true,
                    readOnly: readOnly,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: fMono,
                      color: cTerminalGreen,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (_) {
                      if (!hasModified) setDialogState(() => hasModified = true);
                    },
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭'),
                ),
                if (!readOnly)
                  ElevatedButton(
                    onPressed: hasModified ? () async {
                      try {
                        await _sftpService.writeFileContent(entry.path, controller.text);
                        if (mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已保存'),
                              duration: Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('保存失败: $e'), backgroundColor: cDanger),
                          );
                        }
                      }
                    } : null,
                    child: const Text('保存'),
                  ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
  }

  Future<void> _renameEntry(SftpEntry entry) async {
    final controller = TextEditingController(text: entry.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).dialogBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: const Text('重命名', style: TextStyle(fontSize: fSmall)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: fSmall),
          decoration: const InputDecoration(labelText: '新名称', isDense: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirmed == true && controller.text.isNotEmpty) {
      try {
        final newPath = p.join(p.dirname(entry.path), controller.text);
        await _sftpService.rename(entry.path, newPath);
        await _loadDirectory(_currentPath);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('重命名失败: $e'), backgroundColor: cDanger),
          );
        }
      }
    }
  }

  Future<void> _deleteEntry(SftpEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).dialogBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Text('确认删除', style: TextStyle(color: cDanger, fontSize: fSmall)),
        content: Text('确定删除 "${entry.name}" 吗？此操作不可恢复。', style: const TextStyle(fontSize: fSmall)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        if (entry.isDirectory) {
          await _sftpService.deleteDirectory(entry.path);
        } else {
          await _sftpService.deleteFile(entry.path);
        }
        await _loadDirectory(_currentPath);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('删除失败: $e'), backgroundColor: cDanger),
          );
        }
      }
    }
  }

  Future<void> _uploadFiles() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(allowMultiple: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('打开文件选择器失败: $e'),
            backgroundColor: cDanger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (result == null || result.files.isEmpty) return;

    for (final file in result.files) {
      final localPath = file.path;
      if (localPath == null) continue;

      final fileName = p.basename(localPath);
      // 手动拼接远程路径，避免 p.join 在不同平台行为差异
      final remotePath = _currentPath == '/'
          ? '/$fileName'
          : '$_currentPath/$fileName';

      setState(() {
        _isTransferring = true;
        _transferProgress = 0;
        _transferName = fileName;
      });

      try {
        await _sftpService.uploadFile(
          localPath,
          remotePath,
          onProgress: (current, total) {
            setState(() {
              _transferProgress = total > 0 ? current / total : 0;
            });
          },
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已上传: $fileName'),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('上传 $fileName 失败: $e'),
              backgroundColor: cDanger,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }

    if (mounted) {
      setState(() => _isTransferring = false);
      await _loadDirectory(_currentPath);
    }
  }

  void _showCreateDirectoryDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).dialogBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: const Text('新建目录', style: TextStyle(fontSize: fSmall)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: fSmall),
          decoration: const InputDecoration(labelText: '目录名称', isDense: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isEmpty) return;
              Navigator.pop(ctx);
              try {
                final newPath = p.join(_currentPath, controller.text);
                await _sftpService.createDirectory(newPath);
                await _loadDirectory(_currentPath);
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('创建目录失败: $e'), backgroundColor: cDanger),
                  );
                }
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon(SftpEntry entry) {
    if (entry.isDirectory) return Icons.folder;
    final ext = p.extension(entry.name).toLowerCase();
    switch (ext) {
      case '.txt': case '.md': case '.log': return Icons.description;
      case '.py': case '.js': case '.ts': case '.dart': case '.java':
      case '.go': case '.rs': case '.c': case '.cpp': case '.h':
      case '.sh': case '.bash': case '.zsh': return Icons.code;
      case '.json': case '.yaml': case '.yml': case '.xml': case '.toml':
      case '.ini': case '.conf': case '.cfg': return Icons.settings;
      case '.jpg': case '.jpeg': case '.png': case '.gif': case '.svg':
      case '.webp': return Icons.image;
      case '.zip': case '.tar': case '.gz': case '.bz2': case '.xz':
      case '.7z': case '.rar': return Icons.archive;
      default: return Icons.insert_drive_file;
    }
  }

  Color _getFileIconColor(SftpEntry entry) {
    if (entry.isDirectory) return cWarning;
    final ext = p.extension(entry.name).toLowerCase();
    switch (ext) {
      case '.py': case '.js': case '.ts': case '.dart': case '.java':
      case '.go': case '.rs': case '.c': case '.cpp': case '.sh': return cPrimary;
      case '.json': case '.yaml': case '.yml': case '.xml': case '.toml': return cAgentGreen;
      case '.jpg': case '.jpeg': case '.png': case '.gif': case '.svg': return cInfo;
      case '.zip': case '.tar': case '.gz': case '.bz2': return cTextSub;
      default: return cTextSub;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tc.bg,
        border: Border(left: BorderSide(color: tc.border, width: 1)),
      ),
      child: Column(
        children: [
          // 顶部工具栏
          _buildToolbar(tc),
          Divider(height: 1, thickness: 1, color: tc.border),
          // 路径栏
          _buildPathBar(tc),
          Divider(height: 1, color: tc.border.withOpacity(0.5)),
          // 文件列表
          Expanded(child: _buildBody()),
          // 传输进度条
          if (_isTransferring) _buildTransferProgress(),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeColors tc) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      color: tc.card,
      child: Row(
        children: [
          Text(
            'SFTP',
            style: TextStyle(fontSize: fSmall, fontWeight: FontWeight.w600, color: cPrimary),
          ),
          if (_hostName != null) ...[
            const SizedBox(width: 4),
            Text(
              '- $_hostName',
              style: TextStyle(fontSize: fMicro, color: cTextSub),
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const Spacer(),
          // 排序按钮
          PopupMenuButton<_SftpSortBy>(
            icon: Icon(Icons.sort, size: 16, color: _sftpService.isConnected ? cTextSub : cTextMuted),
            tooltip: '排序',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onSelected: _toggleSort,
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: _SftpSortBy.name,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('名称', style: TextStyle(fontSize: fSmall)),
                    if (_sortBy == _SftpSortBy.name) ...[
                      const SizedBox(width: 4),
                      Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: cPrimary),
                    ],
                  ],
                ),
              ),
              PopupMenuItem(
                value: _SftpSortBy.size,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('大小', style: TextStyle(fontSize: fSmall)),
                    if (_sortBy == _SftpSortBy.size) ...[
                      const SizedBox(width: 4),
                      Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: cPrimary),
                    ],
                  ],
                ),
              ),
              PopupMenuItem(
                value: _SftpSortBy.modified,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('修改时间', style: TextStyle(fontSize: fSmall)),
                    if (_sortBy == _SftpSortBy.modified) ...[
                      const SizedBox(width: 4),
                      Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: cPrimary),
                    ],
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            icon: Icon(Icons.upload_file, size: 16, color: _sftpService.isConnected ? cTextSub : cTextMuted),
            tooltip: '上传',
            onPressed: _sftpService.isConnected ? _uploadFiles : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
          IconButton(
            icon: Icon(Icons.create_new_folder_outlined, size: 16, color: _sftpService.isConnected ? cTextSub : cTextMuted),
            tooltip: '新建目录',
            onPressed: _sftpService.isConnected ? _showCreateDirectoryDialog : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
          IconButton(
            icon: Icon(Icons.refresh, size: 16, color: _sftpService.isConnected ? cTextSub : cTextMuted),
            tooltip: '刷新',
            onPressed: _sftpService.isConnected ? () => _loadDirectory(_currentPath) : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
          if (widget.onClose != null)
            IconButton(
              icon: Icon(Icons.close, size: 16, color: cTextSub),
              tooltip: '关闭',
              onPressed: widget.onClose,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            ),
        ],
      ),
    );
  }

  Widget _buildPathBar(ThemeColors tc) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      color: tc.card,
      child: Row(
        children: [
          // 返回按钮
          IconButton(
            icon: Icon(Icons.arrow_back, size: 14, color: _pathHistory.isNotEmpty ? cPrimary : cTextMuted),
            onPressed: _pathHistory.isNotEmpty ? _goBack : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
          ),
          // 路径紧贴返回按钮
          Expanded(
            child: _isPathEditing
                ? _buildPathInput()
                : _buildBreadcrumbPath(),
          ),
          // 编辑路径按钮
          if (!_isPathEditing)
            IconButton(
              icon: Icon(Icons.edit_outlined, size: 13, color: cTextMuted),
              onPressed: _startPathEditing,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              tooltip: '输入路径',
            ),
          // 根目录按钮（右侧）
          IconButton(
            icon: Icon(Icons.home_outlined, size: 14, color: cPrimary),
            onPressed: () => _navigateTo('/'),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            tooltip: '根目录',
          ),
        ],
      ),
    );
  }

  Widget _buildPathInput() {
    return TextField(
      controller: _pathController,
      focusNode: _pathFocusNode,
      style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: fMicro, color: cTextMain),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), gapPadding: 0),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: cPrimary, width: 1)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: cBorder, width: 0.5)),
      ),
      onSubmitted: (_) => _submitPath(),
    );
  }

  Widget _buildBreadcrumbPath() {
    // 路径格式：/home/user/docs → 面包屑: /home/user/docs（每段可点击）
    final parts = _currentPath.split('/').where((s) => s.isNotEmpty).toList();
    final widgets = <Widget>[];

    if (parts.isEmpty) {
      // 当前就在根目录
      widgets.add(_pathSegment('/', () => _navigateTo('/')));
    } else {
      // 根斜杠（可点击回到 /）
      widgets.add(_pathSegment('/', () => _navigateTo('/')));
      // 子路径段，每段前面紧跟斜杠
      for (int i = 0; i < parts.length; i++) {
        final accumulated = '/${parts.sublist(0, i + 1).join('/')}';
        final targetPath = accumulated;
        widgets.add(_pathSegment(parts[i], () => _navigateTo(targetPath)));
        // 非最后一段后面加斜杠分隔
        if (i < parts.length - 1) {
          widgets.add(Text('/', style: TextStyle(fontSize: fMicro, color: cTextMuted, fontFamily: 'JetBrainsMono', height: 1.2)));
        }
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: widgets,
      ),
    );
  }

  Widget _pathSegment(String name, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Text(
        name,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: fMicro,
          color: cPrimary,
          height: 1.2,
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isConnecting) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: cPrimary),
            ),
            const SizedBox(height: 8),
            Text('正在连接...', style: TextStyle(color: cTextSub, fontSize: fSmall)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 28, color: cDanger),
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: cDanger, fontSize: fMicro), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _connectAndLoad,
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
                child: const Text('重试', style: TextStyle(fontSize: fSmall)),
              ),
            ],
          ),
        ),
      );
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open, size: 32, color: cTextMuted),
            const SizedBox(height: 6),
            Text('空目录', style: TextStyle(color: cTextSub, fontSize: fSmall)),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _entries.length,
      itemExtent: 32, // 固定行高，紧凑显示
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return _buildFileItem(entry);
      },
    );
  }

  Widget _buildFileItem(SftpEntry entry) {
    // 右侧信息: 大小、修改时间、权限
    final sizeStr = entry.isDirectory ? '--' : entry.displaySize;
    final timeStr = entry.displayModifiedTime;
    final permStr = entry.displayPermissions;

    return InkWell(
      onTap: () {
        if (entry.isDirectory) {
          _navigateTo(entry.path);
        } else {
          _showEntryActions(entry);
        }
      },
      onLongPress: () => _showEntryActions(entry),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.3)),
        ),
        child: Row(
          children: [
            Icon(_getFileIcon(entry), size: 15, color: _getFileIconColor(entry)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                entry.name,
                style: TextStyle(
                  fontSize: fMicro,
                  fontWeight: entry.isDirectory ? FontWeight.w500 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            // 大小
            SizedBox(
              width: 52,
              child: Text(
                sizeStr,
                style: TextStyle(fontSize: 9, color: cTextMuted, fontFamily: 'JetBrainsMono'),
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            // 修改时间
            SizedBox(
              width: 80,
              child: Text(
                timeStr,
                style: TextStyle(fontSize: 9, color: cTextMuted, fontFamily: 'JetBrainsMono'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            // 权限
            Text(
              permStr,
              style: TextStyle(fontSize: 9, color: cTextMuted, fontFamily: 'JetBrainsMono'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferProgress() {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: cPrimary.withOpacity(0.08),
        border: Border(top: BorderSide(color: cPrimary.withOpacity(0.2))),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 12, height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: cPrimary, value: _transferProgress),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$_transferName ${(_transferProgress * 100).toStringAsFixed(0)}%',
              style: TextStyle(fontSize: 9, color: cPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
