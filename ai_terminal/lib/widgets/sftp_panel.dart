import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../providers/app_providers.dart';
import '../services/sftp_controller.dart';
import '../services/sftp_service.dart';

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
  late final SftpController _controller;

  // 路径输入模式（纯 UI 状态）
  bool _isPathEditing = false;
  final _pathController = TextEditingController();
  final _pathFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = SftpController();
    _controller.addListener(_onChanged);
    _connect();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    final host = ref.read(hostsProvider.notifier).getHostById(widget.hostId);
    if (host == null) {
      _controller.setError('主机不存在');
      return;
    }
    await _controller.connectAndLoad(host);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _pathController.dispose();
    _pathFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _submitPath() {
    final path = _pathController.text.trim();
    if (path.isNotEmpty) {
      setState(() => _isPathEditing = false);
      _controller.navigateTo(path);
    }
  }

  void _startPathEditing() {
    _pathController.text = _controller.currentPath;
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
              _actionTile(context, Icons.folder_open, '打开', () {
                Navigator.pop(ctx);
                _controller.navigateTo(entry.path);
              }),
            if (!entry.isDirectory)
              _actionTile(context, Icons.download, '下载到本地', () {
                Navigator.pop(ctx);
                _downloadFile(entry);
              }),
            if (!entry.isDirectory)
              _actionTile(context, Icons.visibility, '预览内容', () {
                Navigator.pop(ctx);
                _editOrPreviewFile(entry, readOnly: true);
              }),
            if (!entry.isDirectory)
              _actionTile(context, Icons.edit_outlined, '编辑', () {
                Navigator.pop(ctx);
                _editOrPreviewFile(entry, readOnly: false);
              }),
            _actionTile(context, Icons.drive_file_rename_outline, '重命名', () {
              Navigator.pop(ctx);
              _renameEntry(entry);
            }),
            _actionTile(
              context,
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

  Widget _actionTile(BuildContext context, IconData icon, String label, VoidCallback onTap, {Color? color}) {
    final tc = ThemeColors.of(context);
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color ?? tc.textSub, size: 18),
      title: Text(label, style: TextStyle(color: color, fontSize: fSmall)),
      onTap: onTap,
    );
  }

  Future<void> _downloadFile(SftpEntry entry) async {
    try {
      await _controller.downloadFile(entry);
      if (mounted) {
        // 与 controller 内下载路径保持一致（系统临时目录）
        final localPath = '${Directory.systemTemp.path}/${entry.name}';
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
      content = await _controller.readFile(entry.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取失败: $e'), backgroundColor: cDanger),
        );
      }
      return;
    }

    if (!mounted) return;

    final tc = ThemeColors.of(context);
    final controller = TextEditingController(text: content);
    bool hasModified = false;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: DialogTheme.of(context).backgroundColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
              titlePadding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              title: Row(
                children: [
                  const Icon(Icons.insert_drive_file, size: 14, color: cPrimary),
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
                        color: tc.textMuted.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('只读', style: TextStyle(fontSize: 9, color: tc.textMuted)),
                    ),
                  if (!readOnly && hasModified)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cWarning.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('已修改', style: TextStyle(fontSize: 9, color: cWarning)),
                    ),
                ],
              ),
              content: SizedBox(
                width: MediaQuery.of(context).size.width * 0.7,
                height: MediaQuery.of(context).size.height * 0.55,
                child: Container(
                  decoration: BoxDecoration(
                    color: tc.bg,
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
                      color: tc.terminalGreen,
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
                        await _controller.writeFile(entry.path, controller.text);
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                              content: Text('已保存'),
                              duration: Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      } catch (e) {
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
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
        backgroundColor: DialogTheme.of(context).backgroundColor,
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
        await _controller.renameEntry(entry, controller.text);
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
        backgroundColor: DialogTheme.of(context).backgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
        title: const Text('确认删除', style: TextStyle(color: cDanger, fontSize: fSmall)),
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
        await _controller.deleteEntry(entry);
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
      final remotePath = _controller.currentPath == '/'
          ? '/$fileName'
          : '${_controller.currentPath}/$fileName';

      try {
        await _controller.uploadFile(localPath, remotePath);
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
      await _controller.loadDirectory(_controller.currentPath);
    }
  }

  void _showCreateDirectoryDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DialogTheme.of(context).backgroundColor,
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
                await _controller.createDirectory(controller.text);
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

  Color _getFileIconColor(BuildContext context, SftpEntry entry) {
    if (entry.isDirectory) return cWarning;
    final tc = ThemeColors.of(context);
    final ext = p.extension(entry.name).toLowerCase();
    switch (ext) {
      case '.py': case '.js': case '.ts': case '.dart': case '.java':
      case '.go': case '.rs': case '.c': case '.cpp': case '.sh': return cPrimary;
      case '.json': case '.yaml': case '.yml': case '.xml': case '.toml': return tc.agentGreen;
      case '.jpg': case '.jpeg': case '.png': case '.gif': case '.svg': return cInfo;
      case '.zip': case '.tar': case '.gz': case '.bz2': return tc.textSub;
      default: return tc.textSub;
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
          Divider(height: 1, color: tc.border.withValues(alpha: 0.5)),
          // 文件列表
          Expanded(child: _buildBody()),
          // 传输进度条
          if (_controller.isTransferring) _buildTransferProgress(),
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
          const Text(
            'SFTP',
            style: TextStyle(fontSize: fSmall, fontWeight: FontWeight.w600, color: cPrimary),
          ),
          if (_controller.hostName != null) ...[
            const SizedBox(width: 4),
            Text(
              '- ${_controller.hostName}',
              style: TextStyle(fontSize: fMicro, color: tc.textSub),
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const Spacer(),
          // 排序按钮
          PopupMenuButton<String>(
            icon: Icon(Icons.sort, size: 16, color: _controller.isConnected ? tc.textSub : tc.textMuted),
            tooltip: '排序',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onSelected: _controller.toggleSort,
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: SftpSortFields.name,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('名称', style: TextStyle(fontSize: fSmall)),
                    if (_controller.sortBy == SftpSortFields.name) ...[
                      const SizedBox(width: 4),
                      Icon(_controller.sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: cPrimary),
                    ],
                  ],
                ),
              ),
              PopupMenuItem(
                value: SftpSortFields.size,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('大小', style: TextStyle(fontSize: fSmall)),
                    if (_controller.sortBy == SftpSortFields.size) ...[
                      const SizedBox(width: 4),
                      Icon(_controller.sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: cPrimary),
                    ],
                  ],
                ),
              ),
              PopupMenuItem(
                value: SftpSortFields.modified,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('修改时间', style: TextStyle(fontSize: fSmall)),
                    if (_controller.sortBy == SftpSortFields.modified) ...[
                      const SizedBox(width: 4),
                      Icon(_controller.sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: cPrimary),
                    ],
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            icon: Icon(Icons.upload_file, size: 16, color: _controller.isConnected ? tc.textSub : tc.textMuted),
            tooltip: '上传',
            onPressed: _controller.isConnected ? _uploadFiles : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
          IconButton(
            icon: Icon(Icons.create_new_folder_outlined, size: 16, color: _controller.isConnected ? tc.textSub : tc.textMuted),
            tooltip: '新建目录',
            onPressed: _controller.isConnected ? _showCreateDirectoryDialog : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
          IconButton(
            icon: Icon(Icons.refresh, size: 16, color: _controller.isConnected ? tc.textSub : tc.textMuted),
            tooltip: '刷新',
            onPressed: _controller.isConnected ? () => _controller.loadDirectory(_controller.currentPath) : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
          if (widget.onClose != null)
            IconButton(
              icon: Icon(Icons.close, size: 16, color: tc.textSub),
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
            icon: Icon(Icons.arrow_back, size: 14, color: _controller.pathHistory.isNotEmpty ? cPrimary : tc.textMuted),
            onPressed: _controller.pathHistory.isNotEmpty ? _controller.goBack : null,
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
              icon: Icon(Icons.edit_outlined, size: 13, color: tc.textMuted),
              onPressed: _startPathEditing,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              tooltip: '输入路径',
            ),
          // 根目录按钮（右侧）
          IconButton(
            icon: const Icon(Icons.home_outlined, size: 14, color: cPrimary),
            onPressed: () => _controller.navigateTo('/'),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            tooltip: '根目录',
          ),
        ],
      ),
    );
  }

  Widget _buildPathInput() {
    final tc = ThemeColors.of(context);
    return TextField(
      controller: _pathController,
      focusNode: _pathFocusNode,
      style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: fMicro, color: tc.textMain),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), gapPadding: 0),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: cPrimary, width: 1)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide(color: tc.border, width: 0.5)),
      ),
      onSubmitted: (_) => _submitPath(),
    );
  }

  Widget _buildBreadcrumbPath() {
    // 路径格式：/home/user/docs → 面包屑: /home/user/docs（每段可点击）
    final tc = ThemeColors.of(context);
    final parts = _controller.currentPath.split('/').where((s) => s.isNotEmpty).toList();
    final widgets = <Widget>[];

    if (parts.isEmpty) {
      // 当前就在根目录
      widgets.add(_pathSegment('/', () => _controller.navigateTo('/')));
    } else {
      // 根斜杠（可点击回到 /）
      widgets.add(_pathSegment('/', () => _controller.navigateTo('/')));
      // 子路径段，每段前面紧跟斜杠
      for (int i = 0; i < parts.length; i++) {
        final accumulated = '/${parts.sublist(0, i + 1).join('/')}';
        final targetPath = accumulated;
        widgets.add(_pathSegment(parts[i], () => _controller.navigateTo(targetPath)));
        // 非最后一段后面加斜杠分隔
        if (i < parts.length - 1) {
          widgets.add(Text('/', style: TextStyle(fontSize: fMicro, color: tc.textMuted, fontFamily: 'JetBrainsMono', height: 1.2)));
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
        style: const TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: fMicro,
          color: cPrimary,
          height: 1.2,
        ),
      ),
    );
  }

  Widget _buildBody() {
    final tc = ThemeColors.of(context);
    if (_controller.isConnecting) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: cPrimary),
            ),
            const SizedBox(height: 8),
            Text('正在连接...', style: TextStyle(color: tc.textSub, fontSize: fSmall)),
          ],
        ),
      );
    }

    if (_controller.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 28, color: cDanger),
              const SizedBox(height: 8),
              Text(_controller.error!, style: const TextStyle(color: cDanger, fontSize: fMicro), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _connect,
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
                child: const Text('重试', style: TextStyle(fontSize: fSmall)),
              ),
            ],
          ),
        ),
      );
    }

    if (_controller.isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    if (_controller.entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open, size: 32, color: tc.textMuted),
            const SizedBox(height: 6),
            Text('空目录', style: TextStyle(color: tc.textSub, fontSize: fSmall)),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _controller.entries.length,
      itemExtent: 32, // 固定行高，紧凑显示
      itemBuilder: (context, index) {
        final entry = _controller.entries[index];
        return _buildFileItem(entry);
      },
    );
  }

  Widget _buildFileItem(SftpEntry entry) {
    final tc = ThemeColors.of(context);
    // 右侧信息: 大小、修改时间、权限
    final sizeStr = entry.isDirectory ? '--' : entry.displaySize;
    final timeStr = entry.displayModifiedTime;
    final permStr = entry.displayPermissions;

    return InkWell(
      onTap: () {
        if (entry.isDirectory) {
          _controller.navigateTo(entry.path);
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
            Icon(_getFileIcon(entry), size: 15, color: _getFileIconColor(context, entry)),
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
                style: TextStyle(fontSize: 9, color: tc.textMuted, fontFamily: 'JetBrainsMono'),
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
                style: TextStyle(fontSize: 9, color: tc.textMuted, fontFamily: 'JetBrainsMono'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            // 权限
            Text(
              permStr,
              style: TextStyle(fontSize: 9, color: tc.textMuted, fontFamily: 'JetBrainsMono'),
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
        color: cPrimary.withValues(alpha: 0.08),
        border: Border(top: BorderSide(color: cPrimary.withValues(alpha: 0.2))),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 12, height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: cPrimary, value: _controller.transferProgress),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${_controller.transferName} ${(_controller.transferProgress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 9, color: cPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
