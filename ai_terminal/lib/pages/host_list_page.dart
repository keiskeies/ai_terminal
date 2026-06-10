import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/constants.dart';
import '../core/credentials_store.dart';
import '../core/hive_init.dart';
import '../core/theme_colors.dart';
import '../models/host_config.dart';
import '../providers/app_providers.dart';
import '../widgets/host_card.dart';

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
      final saved = HiveInit.settingsBox.get('hostGroupExpanded');
      if (saved != null && saved is Map) {
        for (final entry in saved.entries) {
          _groupExpanded[entry.key.toString()] = entry.value as bool;
        }
      }
    } catch (_) {}
  }

  /// P1-4: 保存分组展开状态
  void _saveGroupExpandedState() {
    HiveInit.settingsBox.put('hostGroupExpanded', Map<String, bool>.from(_groupExpanded));
  }

  @override
  Widget build(BuildContext context) {
    final hostsAsync = ref.watch(hostsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器管理'),
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
            padding: const EdgeInsets.all(pStandard),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: InputDecoration(
                hintText: '搜索服务器...',
                prefixIcon: const Icon(Icons.search, color: cTextSub),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: cTextSub),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
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
                    Icon(Icons.error_outline, size: 48, color: cDanger),
                    const SizedBox(height: 16),
                    Text('加载失败: $error', style: TextStyle(color: cTextSub)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => ref.read(hostsProvider.notifier).loadHosts(),
                      child: const Text('重试'),
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.lightbulb, color: Colors.amber),
            SizedBox(width: 8),
            Text('AI 助手使用提示'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('AI 助手需要在连接服务器后使用：'),
            SizedBox(height: 12),
            Text('1️⃣  点击服务器卡片进入终端'),
            SizedBox(height: 8),
            Text('2️⃣  连接成功后，右下角会出现 AI 按钮'),
            SizedBox(height: 8),
            Text('3️⃣  点击 AI 按钮，开始智能命令助手'),
            SizedBox(height: 12),
            Text(
              '💡 AI 可以帮你生成命令、解释输出、排查问题',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// P1-4: 空状态重设计 - 情感化引导
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 终端光标闪烁动画
          _BlinkingCursor(),
          const SizedBox(height: 24),
          Text(
            '还没有服务器',
            style: TextStyle(
              color: ThemeColors.of(context).textMain,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '添加第一台服务器，开启 AI 辅助运维之旅',
            style: TextStyle(
              color: ThemeColors.of(context).textSub,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => context.push('/host/edit'),
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              // TODO: 打开文档链接
            },
            child: const Text('了解功能'),
          ),
        ],
      ),
    );
  }

  /// P1-4: 搜索无结果状态
  Widget _buildNoSearchResults() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 48, color: ThemeColors.of(context).textMuted),
          const SizedBox(height: 16),
          Text(
            '未找到匹配的服务器',
            style: TextStyle(
              color: ThemeColors.of(context).textSub,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '尝试其他关键词或检查拼写',
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
            label: const Text('清除搜索'),
          ),
        ],
      ),
    );
  }

  /// P1-4: 分组区域 - 支持展开/收起状态持久化
  Widget _buildGroupSection(String groupName, List<HostConfig> hosts) {
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
                  child: Icon(
                    Icons.chevron_right,
                    color: cPrimary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.folder, color: cPrimary, size: 18),
                const SizedBox(width: 8),
                Text(
                  groupName,
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
                    color: cPrimary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(rFull),
                  ),
                  child: Text(
                    '${hosts.length}',
                    style: TextStyle(
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
            children: hosts.map((host) => HostCard(
              host: host,
              onTap: () => context.push('/terminal/${host.id}'),
              onEdit: () => context.push('/host/edit/${host.id}'),
              onDelete: () => _showDeleteDialog(host),
            )).toList(),
          ),
          secondChild: const SizedBox.shrink(),
          crossFadeState: isExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
          duration: animNormal,
        ),
      ],
    );
  }

  void _showDeleteDialog(HostConfig host) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除服务器'),
        content: Text('确定要删除 "${host.name}" 吗？\n\n同时将删除保存的凭据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await CredentialsStore.deleteAll(host.id);
              await ref.read(hostsProvider.notifier).deleteHost(host.id);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('删除成功')),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

/// P1-4: 闪烁光标动画（空状态装饰）
class _BlinkingCursor extends StatefulWidget {
  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: cPrimary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(rLarge),
          ),
          child: Center(
            child: Text(
              '_',
              style: TextStyle(
                fontSize: fDisplay,
                fontWeight: FontWeight.w300,
                color: cPrimary.withOpacity(0.3 + 0.7 * _controller.value),
              ),
            ),
          ),
        );
      },
    );
  }
}