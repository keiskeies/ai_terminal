import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/credentials_store.dart';
import '../models/host_config.dart';
import '../providers/app_providers.dart';
import '../services/sftp_service.dart';

class SftpPage extends ConsumerStatefulWidget {
  final String hostId;

  const SftpPage({super.key, required this.hostId});

  @override
  ConsumerState<SftpPage> createState() => _SftpPageState();
}

class _SftpPageState extends ConsumerState<SftpPage> {
  final SftpService _sftpService = SftpService();
  List<SftpEntry> _entries = [];
  String _currentPath = '/';
  bool _isLoading = false;
  bool _isConnecting = false;
  String? _error;
  final List<String> _pathHistory = [];
  String? _hostName;

  // 上传/下载进度
  bool _isTransferring = false;
  double _transferProgress = 0;
  String _transferName = '';

  @override
  void initState() {
    super.initState();
    _connectAndLoad();
  }

  @override
  void dispose() {
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
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = '读取目录失败: $e';
      });
    }
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
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    entry.isDirectory ? Icons.folder : Icons.insert_drive_file,
                    color: entry.isDirectory ? cWarning : cPrimary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.name,
                      style: const TextStyle(fontWeight: FontWeight.w500),
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
                _previewFile(entry);
              }),
            _actionTile(Icons.edit, '重命名', () {
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
      leading: Icon(icon, color: color ?? cTextSub, size: 20),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }

  Future<void> _downloadFile(SftpEntry entry) async {
    // 简单实现：下载到应用的临时目录
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

  Future<void> _previewFile(SftpEntry entry) async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).dialogBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: Row(
          children: [
            Icon(Icons.insert_drive_file, size: 18, color: cPrimary),
            const SizedBox(width: 8),
            Flexible(child: Text(entry.name, style: const TextStyle(fontSize: fBody), overflow: TextOverflow.ellipsis)),
          ],
        ),
        content: FutureBuilder<String>(
          future: _sftpService.readFileContent(entry.path),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 100,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            if (snapshot.hasError) {
              return Text('预览失败: ${snapshot.error}', style: TextStyle(color: cDanger, fontSize: fSmall));
            }
            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
                maxWidth: MediaQuery.of(context).size.width * 0.8,
              ),
              decoration: BoxDecoration(
                color: ThemeColors.of(context).bg,
                borderRadius: BorderRadius.circular(rSmall),
              ),
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                child: SelectableText(
                  snapshot.data ?? '(空文件)',
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: fMono,
                    color: cTerminalGreen,
                  ),
                ),
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _renameEntry(SftpEntry entry) async {
    final controller = TextEditingController(text: entry.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).dialogBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: const Text('重命名', style: TextStyle(fontSize: fBody)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '新名称'),
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
        title: Text('确认删除', style: TextStyle(color: cDanger, fontSize: fBody)),
        content: Text('确定删除 "${entry.name}" 吗？此操作不可恢复。'),
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

  void _showCreateDirectoryDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).dialogBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: const Text('新建目录', style: TextStyle(fontSize: fBody)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '目录名称'),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(_hostName != null ? 'SFTP - $_hostName' : 'SFTP'),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined, size: 20),
            tooltip: '新建目录',
            onPressed: _sftpService.isConnected ? _showCreateDirectoryDialog : null,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: '刷新',
            onPressed: _sftpService.isConnected
                ? () => _loadDirectory(_currentPath)
                : null,
          ),
        ],
      ),
      body: Column(
        children: [
          // 路径导航栏
          _buildPathBar(),
          const Divider(height: 1),

          // 文件列表
          Expanded(
            child: _buildBody(),
          ),

          // 传输进度条
          if (_isTransferring) _buildTransferProgress(),
        ],
      ),
    );
  }

  Widget _buildPathBar() {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: Theme.of(context).cardColor,
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, size: 18, color: _pathHistory.isNotEmpty ? cPrimary : cTextMuted),
            onPressed: _pathHistory.isNotEmpty ? _goBack : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const SizedBox(width: 8),
          Icon(Icons.folder_open, size: 16, color: cWarning),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Text(
                _currentPath,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: fSmall,
                  color: cTextSub,
                ),
              ),
            ),
          ),
        ],
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
              width: 24, height: 24,
              child: CircularProgressIndicator(strokeWidth: 2, color: cPrimary),
            ),
            const SizedBox(height: 12),
            Text('正在连接 SFTP...', style: TextStyle(color: cTextSub, fontSize: fBody)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 40, color: cDanger),
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: cDanger, fontSize: fSmall), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _connectAndLoad,
                child: const Text('重试'),
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
            Icon(Icons.folder_open, size: 48, color: cTextMuted),
            const SizedBox(height: 8),
            Text('空目录', style: TextStyle(color: cTextSub, fontSize: fBody)),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return _buildFileItem(entry);
      },
    );
  }

  Widget _buildFileItem(SftpEntry entry) {
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
        ),
        child: Row(
          children: [
            Icon(_getFileIcon(entry), size: 22, color: _getFileIconColor(entry)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: TextStyle(
                      fontSize: fBody,
                      fontWeight: entry.isDirectory ? FontWeight.w500 : FontWeight.normal,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${entry.displaySize}  ${entry.displayPermissions}${entry.modifiedTime != null ? '  ${_formatDate(entry.modifiedTime!)}' : ''}',
                    style: TextStyle(fontSize: fMicro, color: cTextMuted, fontFamily: 'JetBrainsMono'),
                  ),
                ],
              ),
            ),
            Icon(Icons.more_vert, size: 16, color: cTextMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferProgress() {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cPrimary.withOpacity(0.08),
        border: Border(top: BorderSide(color: cPrimary.withOpacity(0.2))),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: cPrimary, value: _transferProgress),
          ),
          const SizedBox(width: 8),
          Text(
            '$_transferName ${(_transferProgress * 100).toStringAsFixed(0)}%',
            style: TextStyle(fontSize: fMicro, color: cPrimary),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
