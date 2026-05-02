import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/host_config.dart';

class HostCard extends StatelessWidget {
  final HostConfig host;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const HostCard({
    super.key,
    required this.host,
    this.onTap,
    this.onEdit,
    this.onDelete,
  });

  Color get _statusColor {
    switch (host.lastStatus) {
      case 'success':
        return cSuccess;
      case 'failed':
        return cDanger;
      default:
        return cTextSub;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: pStandard, vertical: pCompact / 2),
      child: Material(
        color: tc.card,
        borderRadius: BorderRadius.circular(rCard),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rCard),
          child: Container(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: pStandard),
            child: Row(
              children: [
                // 状态指示点
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                // 中间信息
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              host.name,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: tc.textMain,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (host.tagColor != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              width: 32,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Color(int.parse(host.tagColor!.replaceFirst('#', '0xFF'))),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${host.host}:${host.port} · ${host.username}',
                        style: TextStyle(
                          fontSize: 13,
                          color: tc.textSub,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // 右侧菜单
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, color: tc.textSub),
                  onSelected: (value) {
                    switch (value) {
                      case 'edit':
                        onEdit?.call();
                        break;
                      case 'delete':
                        onDelete?.call();
                        break;
                      case 'terminal':
                        context.push('/terminal/${host.id}');
                        break;
                      case 'sftp':
                        context.push('/sftp/${host.id}');
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'terminal',
                      child: Row(
                        children: [
                          Icon(Icons.terminal, size: 20),
                          SizedBox(width: 12),
                          Text('连接终端'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit, size: 20),
                          SizedBox(width: 12),
                          Text('编辑'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'sftp',
                      child: Row(
                        children: [
                          Icon(Icons.folder, size: 20),
                          SizedBox(width: 12),
                          Text('SFTP'),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, size: 20, color: cDanger),
                          const SizedBox(width: 12),
                          Text('删除', style: TextStyle(color: cDanger)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
