import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/host_config.dart';
import '../core/l10n_holder.dart';

/// P1-4: 服务器卡片重设计
/// - 高度从 72px 增加到 88px
/// - 增加头像区域（首字母 + 颜色）
/// - 增加最后连接时间
/// - 快捷操作按钮外露（连接、SFTP）
/// - 状态点增加脉冲动画
class HostCard extends StatefulWidget {
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

  @override
  State<HostCard> createState() => _HostCardState();
}

class _HostCardState extends State<HostCard> {
  bool _isHovered = false;

  Color get _statusColor {
    final tc = ThemeColors.of(context);
    switch (widget.host.lastStatus) {
      case 'success':
        return tc.ok;
      case 'failed':
        return tc.error;
      default:
        return tc.textSub;
    }
  }

  /// 头像色：设计稿里只有「品牌青 / 数据金 / 弱灰」三档，不再用紫、粉、亮青
  /// 这类装饰色板——它们会和成功/警告/错误的语义色撞在同一块卡片里。
  /// 带标签的主机沿用标签分类色（tagColors 已是石墨青体系），
  /// 连接成功取品牌青，失败取语义红，其余降级到弱灰。
  Color get _avatarColor {
    final tc = ThemeColors.of(context);
    if (widget.host.tagColor != null) {
      return Color(int.parse(widget.host.tagColor!.replaceFirst('#', '0xFF')));
    }
    switch (widget.host.lastStatus) {
      case 'success':
        return tc.brand;
      case 'failed':
        return tc.error;
      default:
        return tc.textSub;
    }
  }

  String? get _lastConnectedText {
    if (widget.host.lastConnectedAt == null) return null;
    final diff = DateTime.now().difference(widget.host.lastConnectedAt!);
    if (diff.inMinutes < 1) return UiText.t('刚刚', 'just now');
    if (diff.inMinutes < 60)
      return UiText.count(diff.inMinutes, '分钟前', 'min ago');
    if (diff.inHours < 24) return UiText.count(diff.inHours, '小时前', 'h ago');
    if (diff.inDays < 30) return UiText.count(diff.inDays, '天前', 'd ago');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final lastConnected = _lastConnectedText;

    final tagColor = widget.host.tagColor != null
        ? Color(int.parse(widget.host.tagColor!.replaceFirst('#', '0xFF')))
        : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: animFast,
          margin: const EdgeInsets.symmetric(
              horizontal: pStandard, vertical: pCompact / 2),
          decoration: BoxDecoration(
            color: _isHovered ? tc.cardElevated : tc.card,
            borderRadius: BorderRadius.circular(rCard),
            border: Border.all(color: tc.border, width: 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
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
                      Stack(
                        alignment: Alignment.topRight,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _avatarColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(rMedium),
                            ),
                            child: Center(
                              child: Text(
                                widget.host.name.isNotEmpty
                                    ? widget.host.name[0].toUpperCase()
                                    : '?',
                                style: TextStyle(
                                  fontSize: fTitle,
                                  fontWeight: FontWeight.w600,
                                  color: _avatarColor,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: -1,
                            right: -1,
                            child: widget.host.lastStatus == 'success'
                                ? _PulsingDot(color: _statusColor)
                                : Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: _statusColor,
                                      shape: BoxShape.circle,
                                      border:
                                          Border.all(color: tc.card, width: 2),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.host.name,
                              style: TextStyle(
                                fontSize: fTitle,
                                fontWeight: FontWeight.w600,
                                color: tc.textMain,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${widget.host.username}@${widget.host.host}:${widget.host.port}',
                              style: TextStyle(
                                fontSize: fBody,
                                color: tc.textSub,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (lastConnected != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                L10n.str.ut_0408a4e88d(lastConnected),
                                style: TextStyle(
                                  fontSize: fMicro,
                                  color: tc.textMuted,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ActionButton(
                            icon: Icons.terminal,
                            tooltip: UiText.t('连接终端', 'Open terminal'),
                            onTap: () =>
                                context.push('/terminal/${widget.host.id}'),
                          ),
                          const SizedBox(width: 2),
                          _ActionButton(
                            icon: Icons.folder_open,
                            tooltip: 'SFTP',
                            onTap: () =>
                                context.push('/sftp/${widget.host.id}'),
                          ),
                          const SizedBox(width: 2),
                          PopupMenuButton<String>(
                            icon: Icon(Icons.more_vert,
                                color: tc.textSub, size: 20),
                            onSelected: (value) {
                              switch (value) {
                                case 'edit':
                                  widget.onEdit?.call();
                                  break;
                                case 'delete':
                                  widget.onDelete?.call();
                                  break;
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'edit',
                                child: Row(
                                  children: [
                                    const Icon(Icons.edit, size: 20),
                                    const SizedBox(width: 12),
                                    Text(UiText.t('编辑', 'Edit')),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(Icons.delete,
                                        size: 20, color: tc.error),
                                    const SizedBox(width: 12),
                                    Text(UiText.t('删除', 'Delete'),
                                        style: TextStyle(color: tc.error)),
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
                color: widget.color
                    .withValues(alpha: 0.4 * (1 - _controller.value)),
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
