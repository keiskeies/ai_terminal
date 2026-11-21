import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';

/// 抽屉里的「子视图」：编辑端点、编辑 MCP 服务器、写规范时，抽屉内容整体
/// 换成这张表单，顶部一行返回，底部取消/保存。
///
/// **这里刻意不用 Dialog。** 设置只有一个载体（右侧抽屉）。同一件事一半在抽屉
/// 里、一半弹在屏幕中央，用户会问「这两个是什么关系」，而且弹窗一出现，抽屉就
/// 被压在下面，改完还得回来找自己刚才在哪一组。
class InlineSheet extends StatelessWidget {
  const InlineSheet({
    super.key,
    required this.title,
    required this.onBack,
    required this.children,
    this.actions = const [],
    this.error,
  });

  final String title;
  final VoidCallback onBack;
  final List<Widget> children;
  final List<Widget> actions;

  /// 保存校验失败时的红字；正常状态不占高度。
  final String? error;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tc.surface,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _BackButton(tc: tc, onTap: onBack),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fSmall,
                    fontWeight: FontWeight.w500,
                    color: tc.textMain,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
          if (error != null && error!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              error!,
              style: TextStyle(fontSize: fMicro, color: tc.error, height: 1.35),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Spacer(),
                for (final action in actions) ...[
                  action,
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.tc, required this.onTap});

  final ThemeColors tc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.arrow_back_rounded, size: 14, color: tc.textSub),
            const SizedBox(width: 3),
            Text(UiText.t('返回', 'Back'),
                style: TextStyle(fontSize: fMicro, color: tc.textSub)),
          ],
        ),
      ),
    );
  }
}

/// 表单里的一格输入：标签在上、输入框 32 高，跟抽屉里其他控件一个尺度。
class InlineField extends StatelessWidget {
  const InlineField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.obscure = false,
    this.mono = false,
    this.onChanged,
    this.trailing,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final int maxLines;
  final bool obscure;
  final bool mono;
  final ValueChanged<String>? onChanged;

  /// 输入框右侧的动作图标（例如显示/隐藏 API Key）
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final field = TextField(
      controller: controller,
      maxLines: obscure ? 1 : maxLines,
      obscureText: obscure,
      onChanged: onChanged,
      style: TextStyle(
        fontSize: mono ? fMono : fSmall,
        height: 1.4,
        color: tc.textMain,
        fontFamily: mono ? 'JetBrainsMono' : null,
        fontFamilyFallback: mono ? kMonoFontFallback : null,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(fontSize: fMicro, color: tc.textMuted),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: tc.border),
          borderRadius: BorderRadius.circular(rXSmall),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: tc.brand),
          borderRadius: BorderRadius.circular(rXSmall),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: fMicro, color: tc.textSub)),
        const SizedBox(height: 4),
        if (trailing == null)
          field
        else
          Row(
            children: [
              Expanded(child: field),
              const SizedBox(width: 4),
              trailing!,
            ],
          ),
      ],
    );
  }
}

/// 就地下拉：点开在表单内展开一列选项，不弹 Material 的 overlay 菜单。
///
/// 选项少（传输方式、协议、作用域）时这样最直观：展开的那一列就在眼皮底下，
/// 不会盖住表单别的内容。
class InlineSelect<T> extends StatefulWidget {
  const InlineSelect({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.leadingBuilder,
  });

  final String label;
  final T value;

  /// (值, 显示文字)
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  /// 可选：选项文字前的小图标（服务商 logo 之类）
  final Widget? Function(T value)? leadingBuilder;

  @override
  State<InlineSelect<T>> createState() => _InlineSelectState<T>();
}

class _InlineSelectState<T> extends State<InlineSelect<T>> {
  bool _open = false;

  String get _currentLabel {
    for (final (value, label) in widget.items) {
      if (value == widget.value) return label;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label,
            style: TextStyle(fontSize: fMicro, color: tc.textSub)),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => setState(() => _open = !_open),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(rXSmall),
              border: Border.all(color: _open ? tc.brand : tc.border),
            ),
            child: Row(
              children: [
                if (widget.leadingBuilder?.call(widget.value) case final leading?) ...[
                  leading,
                  const SizedBox(width: 7),
                ],
                Expanded(
                  child: Text(
                    _currentLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: fSmall, color: tc.textMain),
                  ),
                ),
                Icon(
                  _open
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 15,
                  color: tc.textMuted,
                ),
              ],
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: tc.card,
              borderRadius: BorderRadius.circular(rXSmall),
              border: Border.all(color: tc.hairline),
            ),
            child: Column(
              children: [
                for (final (value, label) in widget.items)
                  GestureDetector(
                    onTap: () {
                      setState(() => _open = false);
                      widget.onChanged(value);
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 7),
                      decoration: BoxDecoration(
                        color: value == widget.value
                            ? tc.brandBg
                            : Colors.transparent,
                        border: Border(
                          top: BorderSide(
                              color: value == widget.items.first.$1
                                  ? Colors.transparent
                                  : tc.hairline),
                        ),
                      ),
                      child: Row(
                        children: [
                          if (widget.leadingBuilder?.call(value)
                              case final leading?) ...[
                            leading,
                            const SizedBox(width: 7),
                          ],
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: fMicro,
                                color: value == widget.value
                                    ? tc.brand
                                    : tc.textMain,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 表单里的一行开关：文字在左，18px 小开关在右。
class InlineSwitchRow extends StatelessWidget {
  const InlineSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(fontSize: fMicro, color: tc.textMain)),
                if (subtitle != null)
                  Text(subtitle!,
                      style: TextStyle(fontSize: fMicro, color: tc.textMuted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InlineSwitch(tc: tc, value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// 18px 高的小开关（Material Switch 会撑到 40+，抽屉里放不下）。
class InlineSwitch extends StatelessWidget {
  const InlineSwitch({
    super.key,
    required this.tc,
    required this.value,
    required this.onChanged,
  });

  final ThemeColors tc;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: animFast,
        width: 32,
        height: 18,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value ? tc.brand : tc.border,
          borderRadius: BorderRadius.circular(rFull),
        ),
        child: AnimatedAlign(
          duration: animFast,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: value ? tc.bg : tc.cardElevated,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// 表单底部按钮。primary 是实心品牌色，其余是描边。
class InlineButton extends StatelessWidget {
  const InlineButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.danger = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final fg = danger
        ? tc.error
        : primary
            ? (tc.onAccent)
            : tc.textSub;
    final bg = danger
        ? Colors.transparent
        : primary
            ? tc.brand
            : Colors.transparent;
    final enabled = onTap != null && !busy;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(rXSmall),
          border: Border.all(
            color: danger
                ? tc.error
                : primary
                    ? tc.brand
                    : tc.border,
          ),
        ),
        child: busy
            ? SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                    strokeWidth: 1.4, color: fg),
              )
            : Text(label,
                style: TextStyle(fontSize: fMicro, color: fg, height: 1.1)),
      ),
    );
  }
}

/// 就地确认条：删除服务器/规则前，在该行下方展开一条红的确认，不弹 AlertDialog。
///
/// 抽屉里已经有「下拉再收起」的心智，确认条只是同一种展开，不会把用户带到
/// 另一个浮层上。
class InlineConfirm extends StatelessWidget {
  const InlineConfirm({
    super.key,
    required this.message,
    required this.onCancel,
    required this.onConfirm,
    this.confirmLabel,
    this.danger = true,
  });

  final String message;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final String? confirmLabel;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.fromLTRB(9, 7, 7, 7),
      decoration: BoxDecoration(
        color: tc.errorBg,
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: tc.error),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  fontSize: fMicro, color: tc.textMain, height: 1.35),
            ),
          ),
          const SizedBox(width: 8),
          InlineButton(
            label: UiText.t('取消', 'Cancel'),
            onTap: onCancel,
          ),
          const SizedBox(width: 6),
          InlineButton(
            label: confirmLabel ?? UiText.t('确认', 'Confirm'),
            onTap: onConfirm,
            danger: danger,
          ),
        ],
      ),
    );
  }
}

/// 表单小标题（把一坨字段分成两段，例如「基本」/「模型」）。
class InlineSectionLabel extends StatelessWidget {
  const InlineSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Row(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: fMicro,
              fontWeight: FontWeight.w500,
              color: tc.textSub,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(child: Container(height: 1, color: tc.hairline)),
        ],
      ),
    );
  }
}
