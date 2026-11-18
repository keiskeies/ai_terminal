import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path/path.dart' as p;
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../providers/app_providers.dart';
import '../services/sftp_controller.dart';
import '../services/sftp_service.dart';
import '../core/app_toast.dart';
import '../core/route_observer.dart';
import '../core/l10n_holder.dart';

/// 可复用的 SFTP 面板组件，既可用于独立页面也可嵌入终端右侧
class SftpPanel extends ConsumerStatefulWidget {
  final String hostId;
  final VoidCallback? onClose; // 嵌入模式下的关闭回调
  final bool embedded; // 是否嵌入模式（无 AppBar）

  /// 打开后直接定位到的远端目录（终端右键「在 SFTP 中定位」）
  final String? initialPath;

  /// 桌面拖拽上传开关。DropTarget 监听全局事件，Offstage 保活的隐藏面板
  /// 必须关掉，否则拖放会命中不可见的兄弟 tab 面板。
  final bool dropEnabled;

  const SftpPanel({
    super.key,
    required this.hostId,
    this.onClose,
    this.embedded = false,
    this.initialPath,
    this.dropEnabled = true,
  });

  @override
  ConsumerState<SftpPanel> createState() => _SftpPanelState();
}

class _SftpPanelState extends ConsumerState<SftpPanel> with RouteAware {
  // desktop_drop 仅桌面平台有插件实现；移动端直接不构建 DropTarget
  static final bool _dropSupported =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  late final SftpController _controller;

  // 路径输入模式（纯 UI 状态）
  bool _isPathEditing = false;
  final _pathController = TextEditingController();
  final _pathFocusNode = FocusNode();

  // 拖拽上传：drag 悬停高亮 + 路由覆盖判定（弹层/编辑页在上时不接拖放）
  bool _dragging = false;
  /// 文件行 hover 下标（设计稿 .sftp-row:hover 的行块高亮）
  int _hoveredFileIndex = -1;
  /// 头部操作按钮 hover 标识（设计稿 .sftp-act:hover）
  String? _hoveredHeaderAct;
  bool _routeCovered = false;
  Route? _subscribedRoute;

  @override
  void initState() {
    super.initState();
    _controller = SftpController();
    _controller.addListener(_onChanged);
    _connect();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_dropSupported) return;
    final route = ModalRoute.of(context);
    if (route is PageRoute && route != _subscribedRoute) {
      if (_subscribedRoute != null) appRouteObserver.unsubscribe(this);
      _subscribedRoute = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    // 弹层/新页面盖住面板时禁用 DropTarget：拖放不应打到被遮挡的面板
    if (mounted) setState(() => _routeCovered = true);
  }

  @override
  void didPopNext() {
    if (mounted) setState(() => _routeCovered = false);
  }

  @override
  void dispose() {
    if (_subscribedRoute != null) appRouteObserver.unsubscribe(this);
    _controller.removeListener(_onChanged);
    _pathController.dispose();
    _pathFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    final host = ref.read(hostsProvider.notifier).getHostById(widget.hostId);
    if (host == null) {
      _controller.setError(UiText.t('主机不存在', 'Host not found'));
      return;
    }
    await _controller.connectAndLoad(host);
    final initial = widget.initialPath;
    if (initial != null && initial.isNotEmpty && mounted) {
      await _controller.navigateTo(initial);
    }
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
              _actionTile(
                  context,
                  Icons.folder_open,
                  UiText.t('打开', 'Open'),
                  () {
                    Navigator.pop(ctx);
                    _controller.navigateTo(entry.path);
                  }),
            if (!entry.isDirectory)
              _actionTile(context, Icons.download,
                  UiText.t('下载到本地', 'Download'), () {
                Navigator.pop(ctx);
                _downloadFile(entry);
              }),
            if (!entry.isDirectory)
              _actionTile(context, Icons.visibility,
                  UiText.t('预览内容', 'Preview'), () {
                Navigator.pop(ctx);
                _editOrPreviewFile(entry, readOnly: true);
              }),
            if (!entry.isDirectory)
              _actionTile(context, Icons.edit_outlined,
                  UiText.t('编辑', 'Edit'), () {
                Navigator.pop(ctx);
                _editOrPreviewFile(entry, readOnly: false);
              }),
            _actionTile(context, Icons.drive_file_rename_outline,
                UiText.t('重命名', 'Rename'), () {
              Navigator.pop(ctx);
              _renameEntry(entry);
            }),
            _actionTile(
              context,
              Icons.delete,
              entry.isDirectory
                  ? UiText.t('删除目录', 'Delete folder')
                  : UiText.t('删除文件', 'Delete file'),
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
        showTopSnackBar(context, 
          SnackBar(
            content: Text(L10n.str.ut_e42173cc90(localPath)),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, 
          SnackBar(
            content: Text(L10n.str.ut_7a77df19f2(e)),
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
        showTopSnackBar(context, 
          SnackBar(content: Text(L10n.str.ut_9c9db79438(e)), backgroundColor: cDanger),
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
                      child: Text(UiText.t('只读', 'Read-only'), style: TextStyle(fontSize: 9, color: tc.textMuted)),
                    ),
                  if (!readOnly && hasModified)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: cWarning.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(UiText.t('已修改', 'Modified'), style: TextStyle(fontSize: 9, color: cWarning)),
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
                      fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
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
                  child: Text(UiText.t('关闭', 'Close')),
                ),
                if (!readOnly)
                  ElevatedButton(
                    onPressed: hasModified ? () async {
                      try {
                        await _controller.writeFile(entry.path, controller.text);
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          showTopSnackBar(ctx, 
                            SnackBar(
                              content: Text(UiText.t('已保存', 'Saved')),
                              duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      } catch (e) {
                        if (ctx.mounted) {
                          showTopSnackBar(ctx, 
                            SnackBar(content: Text(L10n.str.ut_5fe0b81932(e)), backgroundColor: cDanger),
                          );
                        }
                      }
                    } : null,
                    child: Text(UiText.t('保存', 'Save')),
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
        title: Text(UiText.t('重命名', 'Rename'), style: const TextStyle(fontSize: fSmall)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: fSmall),
          decoration: InputDecoration(labelText: UiText.t('新名称', 'New name'), isDense: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(UiText.t('取消', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(UiText.t('确定', 'OK')),
          ),
        ],
      ),
    );

    if (confirmed == true && controller.text.isNotEmpty) {
      try {
        await _controller.renameEntry(entry, controller.text);
      } catch (e) {
        if (mounted) {
          showTopSnackBar(context, 
            SnackBar(
                content: Text(L10n.str.ut_6f2c34a667(e)),
                backgroundColor: cDanger),
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
        title: Text(UiText.t('确认删除', 'Confirm delete'), style: const TextStyle(color: cDanger, fontSize: fSmall)),
        content: Text(UiText.t('确定删除 "${entry.name}" 吗？此操作不可恢复。', 'Delete "${entry.name}"? This cannot be undone.'), style: const TextStyle(fontSize: fSmall)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(UiText.t('取消', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: Text(UiText.t('删除', 'Delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _controller.deleteEntry(entry);
      } catch (e) {
        if (mounted) {
          showTopSnackBar(context, 
            SnackBar(content: Text(L10n.str.ut_cf4419589b(e)), backgroundColor: cDanger),
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
        showTopSnackBar(context, 
          SnackBar(
            content: Text(L10n.str.ut_c3b890cd74(e)),
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
          showTopSnackBar(context, 
            SnackBar(
              content: Text(L10n.str.ut_3f446bd9fe(fileName)),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          showTopSnackBar(context, 
            SnackBar(
              content: Text(L10n.str.ut_9e12df0a1f(fileName, e)),
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
        title: Text(UiText.t('新建目录', 'New folder'), style: const TextStyle(fontSize: fSmall)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: fSmall),
          decoration: InputDecoration(labelText: UiText.t('目录名称', 'Folder name'), isDense: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(UiText.t('取消', 'Cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isEmpty) return;
              Navigator.pop(ctx);
              try {
                await _controller.createDirectory(controller.text);
              } catch (e) {
                if (mounted) {
                  showTopSnackBar(context, 
                    SnackBar(content: Text(L10n.str.ut_e89a046c8b(e)), backgroundColor: cDanger),
                  );
                }
              }
            },
            child: Text(UiText.t('创建', 'Create')),
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
    // 设计稿 .sftp-ic：目录统一金色，文件统一品牌色（不再按扩展名分色）
    final tc = ThemeColors.of(context);
    return entry.isDirectory ? tc.gold : tc.brand;
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final panel = Container(
      decoration: BoxDecoration(
        // 设计稿 .sftp-panel 与 AI 面板同底（--m-elev = cardElevated）
        color: tc.cardElevated,
        border: Border(left: BorderSide(color: tc.border, width: 1)),
      ),
      child: Stack(
        children: [
          Column(
            children: [
              // 顶部工具栏
              _buildToolbar(tc),
              // 路径栏
              _buildPathBar(tc),
              // 文件列表
              Expanded(child: _buildBody()),
              // 计数页脚（设计稿 .sftp-foot）
              if (_controller.isConnected) _buildFoot(tc),
              // 传输进度条
              if (_controller.isTransferring) _buildTransferProgress(),
            ],
          ),
          // 拖拽悬停提示
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: cPrimary.withValues(alpha: 0.12),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: tc.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: cPrimary),
                    ),
                    child: Text(
                      UiText.t('松开以上传到当前目录', 'Drop to upload to the current folder'),
                      style: const TextStyle(fontSize: fSmall, color: cPrimary),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (!_dropSupported) return panel;
    // 隐藏面板（Offstage 兄弟 tab）与被弹层遮挡时都不接拖放：
    // desktop_drop 是全局监听，bounds 判定拦不住看不见的目标
    return DropTarget(
      enable: widget.dropEnabled && !_routeCovered,
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _handleDrop(details);
      },
      child: panel,
    );
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    if (_controller.isConnecting || _controller.error != null) return;
    final base = _controller.currentPath;
    var uploaded = 0;
    var failed = 0;
    for (final item in details.files) {
      final path = item.path;
      if (path.isEmpty) continue;
      final name = p.basename(path);
      if (name.isEmpty) continue;
      final remotePath = base == '/' ? '/$name' : '$base/$name';
      try {
        if (await Directory(path).exists()) {
          await _controller.uploadDirectory(path, remotePath);
        } else {
          await _controller.uploadFile(path, remotePath);
        }
        uploaded++;
      } catch (e) {
        failed++;
        if (mounted) {
          showTopSnackBar(context,
            SnackBar(
              content: Text(L10n.str.ut_6c61736431(name, e)),
              backgroundColor: cDanger,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
    if (!mounted) return;
    if (uploaded > 0) {
      showTopSnackBar(context,
        SnackBar(
          content: Text(
              UiText.t('拖拽上传完成: $uploaded 项${failed > 0 ? '，失败 $failed 项' : ''}',
                  'Drop upload complete: $uploaded item(s)${failed > 0 ? ', $failed failed' : ''}')),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    if (uploaded > 0 || failed > 0) {
      await _controller.loadDirectory(_controller.currentPath);
    }
  }

  Widget _buildToolbar(ThemeColors tc) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tc.hairline)),
      ),
      child: Row(
        children: [
          Text(
            'SFTP',
            style: TextStyle(
                fontSize: fSmall, fontWeight: FontWeight.w500, color: tc.brand),
          ),
          if (_controller.hostName != null) ...[
            const SizedBox(width: 6),
            // 主机名做成胶囊（设计稿 .sftp-host）：面板可以开多个，标题行
            // 要一眼分清是哪个主机的。
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              constraints: const BoxConstraints(maxWidth: 140),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(rFull),
                border: Border.all(color: tc.border),
              ),
              child: Text(
                _controller.hostName!,
                style: TextStyle(fontSize: fMicro, color: tc.textSub),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const Spacer(),
          // 排序按钮
          PopupMenuButton<String>(
            icon: Icon(Icons.sort, size: 16, color: _controller.isConnected ? tc.textSub : tc.textMuted),
            tooltip: UiText.t('排序', 'Sort'),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onSelected: _controller.toggleSort,
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: SftpSortFields.name,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(UiText.t('名称', 'Name'), style: const TextStyle(fontSize: fSmall)),
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
                    Text(UiText.t('大小', 'Size'), style: const TextStyle(fontSize: fSmall)),
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
                    Text(UiText.t('修改时间', 'Modified'), style: const TextStyle(fontSize: fSmall)),
                    if (_controller.sortBy == SftpSortFields.modified) ...[
                      const SizedBox(width: 4),
                      Icon(_controller.sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: cPrimary),
                    ],
                  ],
                ),
              ),
            ],
          ),
          _headerActButton(tc,
              id: 'upload',
              icon: Icons.upload_file,
              tooltip: UiText.t('上传', 'Upload'),
              onPressed: _controller.isConnected ? _uploadFiles : null),
          const SizedBox(width: 4),
          _headerActButton(tc,
              id: 'mkdir',
              icon: Icons.create_new_folder_outlined,
              tooltip: UiText.t('新建目录', 'New folder'),
              onPressed: _controller.isConnected ? _showCreateDirectoryDialog : null),
          const SizedBox(width: 4),
          _headerActButton(tc,
              id: 'refresh',
              icon: Icons.refresh,
              tooltip: UiText.t('刷新', 'Refresh'),
              onPressed: _controller.isConnected ? () => _controller.loadDirectory(_controller.currentPath) : null),
          if (widget.onClose != null) ...[
            const SizedBox(width: 4),
            _headerActButton(tc,
                id: 'close',
                icon: Icons.close,
                tooltip: UiText.t('关闭', 'Close'),
                onPressed: widget.onClose),
          ],
        ],
      ),
    );
  }

  /// 头部操作按钮（设计稿 .sftp-act）：26×26 圆角块，surface 底色 + 透明边框，
  /// hover 时边框显现、图标提亮到正文色
  Widget _headerActButton(
    ThemeColors tc, {
    required String id,
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
  }) {
    final enabled = onPressed != null;
    final isHovered = enabled && _hoveredHeaderAct == id;
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: enabled ? (_) => setState(() => _hoveredHeaderAct = id) : null,
        onExit: enabled
            ? (_) {
                if (_hoveredHeaderAct == id) setState(() => _hoveredHeaderAct = null);
              }
            : null,
        child: GestureDetector(
          onTap: onPressed,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tc.surface,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: isHovered ? tc.border : Colors.transparent,
              ),
            ),
            child: Icon(icon,
                size: 16,
                color: !enabled
                    ? tc.textMuted
                    : (isHovered ? tc.textMain : tc.textSub)),
          ),
        ),
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
              tooltip: UiText.t('输入路径', 'Enter path'),
            ),
          // 根目录按钮（右侧）
          IconButton(
            icon: const Icon(Icons.home_outlined, size: 14, color: cPrimary),
            onPressed: () => _controller.navigateTo('/'),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            tooltip: UiText.t('根目录', 'Root folder'),
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
      style: TextStyle(fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback, fontSize: fMicro, color: tc.textMain),
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
          widgets.add(Text('/', style: TextStyle(fontSize: fMicro, color: tc.textMuted, fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback, height: 1.2)));
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
    final tc = ThemeColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Text(
        name,
        style: TextStyle(
          fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
          fontSize: fMicro,
          // 设计稿 .sftp-crumb：常态灰、悬停才品牌色（hover 由父级
          // InkWell 的 textColor 状态属性驱动）
          color: tc.textSub,
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
            Text(UiText.t('正在连接...', 'Connecting...'), style: TextStyle(color: tc.textSub, fontSize: fSmall)),
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
                child: Text(UiText.t('重试', 'Retry'), style: const TextStyle(fontSize: fSmall)),
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
      // 设计稿 .sftp-empty：居中、muted、11px、16 padding
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.folder_open, size: 32, color: tc.textMuted),
              const SizedBox(height: 6),
              Text(UiText.t('空目录', 'Empty folder'), style: TextStyle(color: tc.textMuted, fontSize: fMicro)),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
      itemCount: _controller.entries.length,
      itemBuilder: (context, index) {
        final entry = _controller.entries[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: _buildFileItem(entry, index),
        );
      },
    );
  }

  Widget _buildFileItem(SftpEntry entry, int index) {
    final tc = ThemeColors.of(context);
    // 右侧信息: 大小、修改时间（设计稿网格 1fr/58/76，无权限列）
    final sizeStr = entry.isDirectory ? '--' : entry.displaySize;
    final timeStr = entry.displayModifiedTime;
    final isHovered = _hoveredFileIndex == index;

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredFileIndex = index),
      onExit: (_) {
        if (_hoveredFileIndex == index) setState(() => _hoveredFileIndex = -1);
      },
      child: InkWell(
        onTap: () {
          if (entry.isDirectory) {
            _controller.navigateTo(entry.path);
          } else {
            _showEntryActions(entry);
          }
        },
        onLongPress: () => _showEntryActions(entry),
        borderRadius: BorderRadius.circular(7),
        child: Container(
          constraints: const BoxConstraints(minHeight: 30),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          // 设计稿 .sftp-row：行本身是圆角块，hover 上控件底色；
          // 不再用 0.3px 分隔线切行。
          decoration: BoxDecoration(
            color: isHovered ? tc.surface : null,
            borderRadius: BorderRadius.circular(7),
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
                    color: tc.textBody,
                    fontWeight: entry.isDirectory ? FontWeight.w500 : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              // 大小（设计稿 58px）
              SizedBox(
                width: 58,
                child: Text(
                  sizeStr,
                  style: TextStyle(fontSize: fMicro, color: tc.textMuted, fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback),
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              // 修改时间
              SizedBox(
                width: 76,
                child: Text(
                  timeStr,
                  style: TextStyle(fontSize: fMicro, color: tc.textMuted, fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback),
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 计数页脚（设计稿 .sftp-foot：已连接 <host> · <path> · N 项）
  Widget _buildFoot(ThemeColors tc) {
    final n = _controller.entries.length;
    final host = _controller.hostName;
    final label = host == null || host.isEmpty
        ? '${_controller.currentPath} · ${UiText.count(n, '项', 'items')}'
        : '${UiText.t('已连接', 'Connected')} $host'
            ' · ${_controller.currentPath}'
            ' · ${UiText.count(n, '项', 'items')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tc.hairline)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: fMicro, color: tc.textSub),
        overflow: TextOverflow.ellipsis,
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
