import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/host_config.dart';

/// P1-4: 服务器卡片重设计
/// - 高度从 72px 增加到 88px
/// - 增加头像区域（首字母 + 颜色）
/// - 增加最后连接时间
/// - 快捷操作按钮外露（连接、SFTP）
/// - 状态点增加脉冲动画
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

  /// 生成头像背景色（基于名称哈希）
  Color get _avatarColor {
    final colors = [
      cPrimary,
      cSuccess,
      cWarning,
      const Color(0xFF8B5CF6),
      const Color(0xFFEC4899),
      const Color(0xFF06B6D4),
    ];
    int hash = 0;
    for (var i = 0; i < host.name.length; i++) {
      hash = host.name.codeUnitAt(i) + ((hash << 5) - hash);
    }
    return colors[hash.abs() % colors.length];
  }

  /// 格式化最后连接时间
  String? get _lastConnectedText {
    if (host.lastConnectedAt == null) return null;
    final diff = DateTime.now().difference(host.lastConnectedAt!);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final lastConnected = _lastConnectedText;

    final tagColor = host.tagColor != null
        ? Color(int.parse(host.tagColor!.replaceFirst('#', '0xFF')))
        : null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: pStandard, vertical: pCompact / 2),
      decoration: BoxDecoration(
        color: tc.card,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: tc.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              // 左侧标签色条
              Container(
                width: 3,
                height: 88,
                color: tagColor ?? tc.border,
              ),
              Expanded(
                child: Container(
                  height: 88,
                  padding: const EdgeInsets.symmetric(horizontal: pStandard),
                  child: Row(
                    children: [
                      // 状态指示点 + 头像
                      Stack(
                        alignment: Alignment.topRight,
                        children: [
                          // 头像
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _avatarColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(rMedium),
                            ),
                            child: Center(
                              child: Text(
                                host.name.isNotEmpty ? host.name[0].toUpperCase() : '?',
                                style: TextStyle(
                                  fontSize: fTitle,
                                  fontWeight: FontWeight.w600,
                                  color: _avatarColor,
                                ),
                              ),
                            ),
                          ),
                          // 状态点
                          Positioned(
                            top: -2,
                            right: -2,
                            child: host.lastStatus == 'success'
                                ? _PulsingDot(color: _statusColor)
                                : Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: _statusColor,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: tc.card, width: 2),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      // 中间信息
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              host.name,
                              style: TextStyle(
                                fontSize: fTitle,
                                fontWeight: FontWeight.w600,
                                color: tc.textMain,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${host.username}@${host.host}:${host.port}',
                              style: TextStyle(
                                fontSize: fBody,
                                color: tc.textSub,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (lastConnected != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                '最后连接: $lastConnected',
                                style: TextStyle(
                                  fontSize: fMicro,
                                  color: tc.textMuted,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // 右侧快捷操作按钮
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 连接终端按钮
                          _ActionButton(
                            icon: Icons.terminal,
                            tooltip: '连接终端',
                            onTap: () => context.push('/terminal/${host.id}'),
                          ),
                          const SizedBox(width: 4),
                          // SFTP 按钮
                          _ActionButton(
                            icon: Icons.folder_open,
                            tooltip: 'SFTP',
                            onTap: () => context.push('/sftp/${host.id}'),
                          ),
                          const SizedBox(width: 4),
                          // 更多菜单
                          PopupMenuButton<String>(
                            icon: Icon(Icons.more_vert, color: tc.textSub, size: 20),
                            onSelected: (value) {
                              switch (value) {
                                case 'edit':
                                  onEdit?.call();
                                  break;
                                case 'delete':
                                  onDelete?.call();
                                  break;
                              }
                            },
                            itemBuilder: (context) => [
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
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete, size: 20, color: cDanger),
                                    SizedBox(width: 12),
                                    Text('删除', style: TextStyle(color: cDanger)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 快捷操作按钮
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      ),
    );
  }
}

/// 脉冲动画状态点（在线状态）
class _PulsingDot extends StatefulWidget {
  final Color color;

  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.6).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
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
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            border: Border.all(
              color: ThemeColors.of(context).card,
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.4 * (1 - _controller.value)),
                blurRadius: 4 * _scaleAnimation.value,
                spreadRadius: 2 * _scaleAnimation.value,
              ),
            ],
          ),
        );
      },
    );
  }
}