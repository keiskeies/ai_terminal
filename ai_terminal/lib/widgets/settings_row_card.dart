import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';

/// 设置行卡片。设计稿第 07 节的 `.rowcard` 唯一实现。
///
/// 规范：1px 边框 + 10px 圆角 + `card` 底；头行 min-height 44、padding 9×11；
/// detail 区用 1px hairline 上边框、padding 9×11、行距 6；箭头 13px `textMuted`。
/// 抽屉和整页设置都走这一个组件，避免「同一个开关在两处长得不一样」。
///
/// 两种形态：
/// - **展开式**（[detail] 非空）：向下箭头，点开就地改
/// - **跳转式**（[onNavigate] 非空）：向右箭头，点进去是另一个页面
///
/// 箭头方向就是行为预告，用户不用试才知道。
class SettingsRowCard extends StatefulWidget {
  const SettingsRowCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.detail,
    this.expanded = false,
    this.onToggle,
    this.onNavigate,
    this.actionLabel,
    this.dense = false,
  });

  final String title;
  final String subtitle;

  /// 展开后的就地控件。给 null 表示这是跳转式卡片。
  final List<Widget>? detail;

  final bool expanded;
  final VoidCallback? onToggle;

  /// 跳转式卡片的点击回调（通常是 context.push）
  final VoidCallback? onNavigate;

  /// 展开区底部那行「打开完整设置」的文案。
  ///
  /// 留空给渲染期兜底：默认值写成 `'打开完整设置'` 会在编译期把中文钉死，
  /// 英文界面下 const 构造不会重新求值。
  final String? actionLabel;

  /// 抽屉里字号更小一档
  final bool dense;

  @override
  State<SettingsRowCard> createState() => _SettingsRowCardState();
}

class _SettingsRowCardState extends State<SettingsRowCard> {
  bool _hovering = false;

  bool get _isLink => widget.detail == null && widget.onNavigate != null;

  /// 展开式卡片底部那行「打开完整设置」需要 onNavigate；跳转式整张卡片就是
  /// onNavigate。两种形态都有 onNavigate，判形态只能看 detail 有没有给。 
  bool get _hasAction => widget.detail != null && widget.onNavigate != null;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final titleSize = widget.dense ? fMicro : fBody;
    final subSize = widget.dense ? fMicro : fSmall;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: tc.card,
          borderRadius: BorderRadius.circular(rMedium),
          border: Border.all(color: tc.border, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(tc, titleSize, subSize),
            if (!_isLink && widget.expanded && widget.detail != null)
              Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: tc.hairline)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...widget.detail!,
                    if (_hasAction) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _buildAction(tc),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeColors tc, double titleSize, double subSize) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _isLink ? widget.onNavigate : widget.onToggle,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        color: _hovering ? tc.surface : null,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: titleSize,
                      fontWeight: FontWeight.w500,
                      color: tc.textMain,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: subSize, color: tc.textSub),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _isLink
                  ? Icons.chevron_right_rounded
                  : (widget.expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded),
              size: 14,
              color: tc.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAction(ThemeColors tc) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onNavigate,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.actionLabel ??
                    UiText.t('打开完整设置', 'Open full settings'),
                style: TextStyle(fontSize: fMicro, color: tc.brand),
              ),
              const SizedBox(width: 2),
              Icon(Icons.arrow_forward_rounded, size: 12, color: tc.brand),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分组小标题。设计稿里抽屉没有分组标题，整页设置需要它来分段。
class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: fMicro,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: tc.textMuted,
        ),
      ),
    );
  }
}

/// 一组设置行之间的统一间距
const double kSettingsRowGap = 10;

/// 分区间距
const double kSettingsGroupGap = 26;

/// 整页设置里的一组：标题行 + 常驻内容区。
///
/// 和 [SettingsRowCard] 的展开式不一样 —— 这里**不折叠**。设置就是设置，
/// 控件全摆在这一页上，滚一下就能看到，不必「点开 → 找控件 → 想加条目
/// 再点一次打开完整页面」。抽屉宽度只有 320，继续用可折叠的 rowcard。
class SettingsGroupCard extends StatelessWidget {
  const SettingsGroupCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;

  /// 当前真实状态读数（「深色 · 石墨 · 13px」这种），不是说明文案
  final String subtitle;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tc.card,
        borderRadius: BorderRadius.circular(rMedium),
        border: Border.all(color: tc.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fBody,
                    fontWeight: FontWeight.w500,
                    color: tc.textMain,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: fSmall, color: tc.textSub),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: tc.hairline)),
            ),
            padding: const EdgeInsets.fromLTRB(11, 11, 11, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}
