import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'dart:io';
import '../core/constants.dart';
import '../core/credentials_store.dart';
import '../services/daos.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../models/host_config.dart';
import '../providers/app_providers.dart';
import '../widgets/host_card.dart';
import '../widgets/logo_widget.dart';

class HostListPage extends ConsumerStatefulWidget {
  const HostListPage({super.key});

  @override
  ConsumerState<HostListPage> createState() => _HostListPageState();
}

class _HostListPageState extends ConsumerState<HostListPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  // P1-4: 分组展开状态
  final Map<String, bool> _groupExpanded = {};

  @override
  void initState() {
    super.initState();
    _loadGroupExpandedState();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// P1-4: 加载分组展开状态
  void _loadGroupExpandedState() {
    try {
      final saved = SettingsDao.getCached('hostGroupExpanded');
      if (saved != null && saved is Map) {
        for (final entry in saved.entries) {
          _groupExpanded[entry.key.toString()] = entry.value as bool;
        }
      }
    } catch (_) {}
  }

  /// P1-4: 保存分组展开状态
  void _saveGroupExpandedState() {
    SettingsDao.set('hostGroupExpanded', Map<String, bool>.from(_groupExpanded));
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final hostsAsync = ref.watch(hostsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const LogoWidget(type: LogoType.wordmark, iconSize: 24),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/host/edit'),
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索栏
          Padding(
            padding: const EdgeInsets.fromLTRB(pStandard, 0, pStandard, pStandard),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
              style: const TextStyle(fontSize: fBody),
              decoration: InputDecoration(
                hintText: l10n.hostListSearchHint,
                hintStyle: TextStyle(color: ThemeColors.of(context).textMuted),
                filled: true,
                fillColor: tc.card,
                prefixIcon: Icon(Icons.search, color: tc.textSub, size: 18),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: tc.textSub, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(rSmall),
                  borderSide: BorderSide(color: tc.border, width: 1),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(rSmall),
                  borderSide: BorderSide(color: tc.border, width: 1),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(rSmall),
                  borderSide: const BorderSide(color: cPrimary, width: 1),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
              ),
            ),
          ),
          // 主机列表
          Expanded(
            child: hostsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: cDanger),
                    const SizedBox(height: 16),
                    Text(l10n.hostListLoadFailed('$error'), style: TextStyle(color: tc.textSub)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => ref.read(hostsProvider.notifier).loadHosts(),
                      child: Text(l10n.retry),
                    ),
                  ],
                ),
              ),
              data: (hosts) {
                // 过滤
                final filtered = _searchQuery.isEmpty
                    ? hosts
                    : hosts.where((h) =>
                        h.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                        h.host.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                        h.username.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                        h.group.toLowerCase().contains(_searchQuery.toLowerCase())
                      ).toList();

                if (filtered.isEmpty && hosts.isEmpty) {
                  return _buildEmptyState();
                }

                if (filtered.isEmpty && _searchQuery.isNotEmpty) {
                  return _buildNoSearchResults();
                }

                // 分组
                final grouped = <String, List<HostConfig>>{};
                for (final host in filtered) {
                  grouped.putIfAbsent(host.group, () => []).add(host);
                }

                return RefreshIndicator(
                  onRefresh: () => ref.read(hostsProvider.notifier).loadHosts(),
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: grouped.length,
                    itemBuilder: (context, index) {
                      final groupName = grouped.keys.elementAt(index);
                      final groupHosts = grouped[groupName]!;
                      return _buildGroupSection(groupName, groupHosts);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showTipDialog(context),
        backgroundColor: cPrimary,
        child: const Icon(Icons.smart_toy, color: Colors.white),
      ),
    );
  }

  void _showTipDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.lightbulb, color: Colors.amber),
            const SizedBox(width: 8),
            Text(l10n.hostListAITipTitle),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.hostListAITipIntro),
            const SizedBox(height: 12),
            Text(l10n.hostListAITipStep1),
            const SizedBox(height: 8),
            Text(l10n.hostListAITipStep2),
            const SizedBox(height: 8),
            Text(l10n.hostListAITipStep3),
            const SizedBox(height: 12),
            Text(
              l10n.hostListAITipNote,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonGotIt),
          ),
        ],
      ),
    );
  }

  /// P1-4: 空状态重设计 - 情感化引导
  Widget _buildEmptyState() {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(pStandard * 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 品牌化插图
            const LogoWidget(size: 80),
            const SizedBox(height: 24),
            Text(
              l10n.hostListNoServers,
              style: TextStyle(
                fontSize: fTitle,
                fontWeight: FontWeight.w600,
                color: tc.textMain,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.hostListAddFirstServer,
              style: TextStyle(
                fontSize: fBody,
                color: tc.textSub,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => context.push('/host/edit'),
              icon: const Icon(Icons.add),
              label: Text(l10n.addServer),
            ),
          ],
        ),
      ),
    );
  }

  /// P1-4: 搜索无结果状态
  Widget _buildNoSearchResults() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 48, color: ThemeColors.of(context).textMuted),
          const SizedBox(height: 16),
          Text(
            l10n.hostListNoSearchResults,
            style: TextStyle(
              color: ThemeColors.of(context).textSub,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.hostListNoSearchResultsHint,
            style: TextStyle(
              color: ThemeColors.of(context).textMuted,
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () {
              _searchController.clear();
              setState(() => _searchQuery = '');
            },
            icon: const Icon(Icons.clear),
            label: Text(l10n.hostListClearSearch),
          ),
        ],
      ),
    );
  }

  /// P1-4: 分组区域 - 支持展开/收起状态持久化
  Widget _buildGroupSection(String groupName, List<HostConfig> hosts) {
    final l10n = AppLocalizations.of(context)!;
    // 默认只展开"默认"分组
    final isExpanded = _groupExpanded.putIfAbsent(groupName, () => groupName == '默认');

    return Column(
      children: [
        // 分组标题栏
        InkWell(
          onTap: () {
            setState(() {
              _groupExpanded[groupName] = !isExpanded;
            });
            _saveGroupExpandedState();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: pStandard, vertical: 12),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: isExpanded ? 0.25 : 0,
                  duration: animFast,
                  child: const Icon(
                    Icons.chevron_right,
                    color: cPrimary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.folder, color: cPrimary, size: 18),
                const SizedBox(width: 8),
                Text(
                  groupName == '默认' ? l10n.hostDefaultGroup : groupName,
                  style: TextStyle(
                    fontSize: fBody,
                    fontWeight: FontWeight.w600,
                    color: ThemeColors.of(context).textMain,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: cPrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rFull),
                  ),
                  child: Text(
                    '${hosts.length}',
                    style: const TextStyle(
                      color: cPrimary,
                      fontSize: fMicro,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 分组内容
        AnimatedCrossFade(
          firstChild: Column(
            children: hosts.map((host) => _buildSwipeableHostCard(host)).toList(),
          ),
          secondChild: const SizedBox.shrink(),
          crossFadeState: isExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
          duration: animNormal,
        ),
      ],
    );
  }

  /// 移动端左滑快捷操作（编辑/删除），桌面端直接 HostCard
  Widget _buildSwipeableHostCard(HostConfig host) {
    final isMobile = Platform.isAndroid || Platform.isIOS;

    if (!isMobile) {
      // 桌面端：直接 HostCard，右键菜单已内置
      return HostCard(
        host: host,
        onTap: () => context.push('/terminal/${host.id}'),
        onEdit: () => context.push('/host/edit/${host.id}'),
        onDelete: () => _showDeleteDialog(host),
      );
    }

    // 移动端：左滑显示快捷操作
    return Dismissible(
      key: ValueKey(host.id),
      direction: DismissDirection.endToStart, // 仅左滑
      confirmDismiss: (direction) async => false, // 不自动消失，只显示操作
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: pStandard, vertical: pCompact / 2),
        padding: const EdgeInsets.only(right: pStandard),
        decoration: BoxDecoration(
          color: cPrimary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(rCard),
        ),
        alignment: Alignment.centerRight,
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.edit_outlined, color: cPrimary, size: 20),
            SizedBox(width: 12),
            Icon(Icons.delete_outline, color: cDanger, size: 20),
          ],
        ),
      ),
      // 滑动触发时弹出操作菜单
      onDismissed: (_) {}, // confirmDismiss 返回 false，不会触发
      onUpdate: (details) {
        if (details.reached && !details.previousReached) {
          // 滑动到达阈值时弹出底部操作菜单
          _showSwipeActionSheet(host);
        }
      },
      child: HostCard(
        host: host,
        onTap: () => context.push('/terminal/${host.id}'),
        onEdit: () => context.push('/host/edit/${host.id}'),
        onDelete: () => _showDeleteDialog(host),
      ),
    );
  }

  /// 左滑后弹出的底部操作菜单
  void _showSwipeActionSheet(HostConfig host) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      backgroundColor: tc.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rLarge)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽指示条
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: tc.textMuted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 主机名称
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: pStandard, vertical: 8),
              child: Text(
                host.name,
                style: TextStyle(fontSize: fBody, fontWeight: FontWeight.w600, color: tc.textMain),
              ),
            ),
            const Divider(height: 1),
            // 连接终端
            ListTile(
              leading: const Icon(Icons.terminal, color: cPrimary),
              title: Text(l10n.hostListConnectTerminal),
              onTap: () {
                Navigator.pop(context);
                this.context.push('/terminal/${host.id}');
              },
            ),
            // SFTP
            ListTile(
              leading: const Icon(Icons.folder_open, color: cPrimary),
              title: const Text('SFTP'),
              onTap: () {
                Navigator.pop(context);
                this.context.push('/sftp/${host.id}');
              },
            ),
            // 编辑
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: cPrimary),
              title: Text(l10n.hostListEditConfig),
              onTap: () {
                Navigator.pop(context);
                this.context.push('/host/edit/${host.id}');
              },
            ),
            // 删除
            ListTile(
              leading: const Icon(Icons.delete_outline, color: cDanger),
              title: Text(l10n.delete, style: const TextStyle(color: cDanger)),
              onTap: () {
                Navigator.pop(context);
                _showDeleteDialog(host);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteDialog(HostConfig host) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.hostListDeleteServer),
        content: Text(l10n.hostListDeleteConfirm(host.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await CredentialsStore.deleteAll(host.id);
              await ref.read(hostsProvider.notifier).deleteHost(host.id);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.hostListDeleteSuccess)),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }
}

