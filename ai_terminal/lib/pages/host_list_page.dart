import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/constants.dart';
import '../core/credentials_store.dart';
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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
                        h.username.toLowerCase().contains(_searchQuery.toLowerCase())
                      ).toList();

                if (filtered.isEmpty && hosts.isEmpty) {
                  return _buildEmptyState();
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

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.storage, size: 64, color: cTextSub),
          const SizedBox(height: 16),
          Text(
            '暂无服务器',
            style: TextStyle(color: cTextSub, fontSize: fBody),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => context.push('/host/edit'),
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupSection(String groupName, List<HostConfig> hosts) {
    return ExpansionTile(
      initiallyExpanded: true,
      leading: Icon(Icons.folder, color: cPrimary, size: 20),
      title: Text(
        groupName,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: cPrimary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '${hosts.length}',
          style: const TextStyle(color: Colors.white, fontSize: fSmall),
        ),
      ),
      children: hosts.map((host) => HostCard(
        host: host,
        onTap: () => context.push('/terminal/${host.id}'),
        onEdit: () => context.push('/host/edit/${host.id}'),
        onDelete: () => _showDeleteDialog(host),
      )).toList(),
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
