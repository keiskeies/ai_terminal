import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/terminal_keybindings.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';

/// 快捷键编辑面板：列出每个可重绑动作的当前组合，点一条即可重新录入。
///
/// 编辑粒度是「一条组合」而不是「一个动作」：一个动作本来就有多条
/// （Ctrl+Shift+F 与 mac 的 ⌘F 并存），按动作覆盖会把另一平台的习惯一起抹掉。
class KeybindingEditorPanel extends StatefulWidget {
  const KeybindingEditorPanel({
    super.key,
    required this.overrides,
    required this.onChanged,
  });

  /// 设置里存的覆盖表：`{动作 id: [组合串]}`，只含用户改过的动作
  final Map<String, List<String>> overrides;

  /// 参数为新的覆盖表
  final ValueChanged<Map<String, List<String>>> onChanged;

  @override
  State<KeybindingEditorPanel> createState() => _KeybindingEditorPanelState();
}

class _KeybindingEditorPanelState extends State<KeybindingEditorPanel> {
  TerminalKeymap get _map => TerminalKeymap.fromSettings(widget.overrides);

  Future<void> _edit(TerminalKeyAction action, KeyBinding? existing) async {
    final result = await showDialog<KeyBinding?>(
      context: context,
      builder: (_) => _RecordShortcutDialog(
        action: action,
        isMac: Platform.isMacOS,
      ),
    );
    if (result == null || !mounted) return;
    widget.onChanged(
        addBinding(widget.overrides, action, result, replace: existing));
  }

  void _remove(TerminalKeyAction action, KeyBinding binding) =>
      widget.onChanged(removeBinding(widget.overrides, action, binding));

  void _reset(TerminalKeyAction action) =>
      widget.onChanged(resetAction(widget.overrides, action));

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    // 与全局其余文案同一语言来源（UiText 认 L10n），别另起一套 localeOf
    final isZh = UiText.zh;
    final isMac = Platform.isMacOS;
    final map = _map;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final action in TerminalKeyAction.values)
          Padding(
            padding: const EdgeInsets.only(bottom: pSmall),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 116,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      action.label(isZh: isZh),
                      style: const TextStyle(fontSize: fSmall),
                    ),
                  ),
                ),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final b in map.bindingsFor(action))
                        _BindingChip(
                          label: b.label(isMac: isMac),
                          onEdit: () => _edit(action, b),
                          onRemove: () => _remove(action, b),
                        ),
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(Icons.add, size: 14),
                        label:
                            const Text('+', style: TextStyle(fontSize: fMicro)),
                        onPressed: () => _edit(action, null),
                      ),
                      if (widget.overrides.containsKey(action.id))
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(UiText.t('恢复默认', 'Reset'),
                              style: const TextStyle(fontSize: fMicro)),
                          onPressed: () => _reset(action),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Text(
          UiText.t(
            'Ctrl+A/C/D/H 这些 shell 自己的键不在列表里：抢过来只会让命令行少键。',
            'Keys the shell itself uses (Ctrl+A/C/D/H) are deliberately not '
                'rebindable — taking them would only cost you shell bindings.',
          ),
          style: TextStyle(color: tc.textMuted, fontSize: fMicro),
        ),
      ],
    );
  }
}

class _BindingChip extends StatelessWidget {
  const _BindingChip({
    required this.label,
    required this.onEdit,
    required this.onRemove,
  });

  final String label;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Tooltip(
      message: UiText.t('点击重新录入', 'Click to record a new combo'),
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(rSmall),
        child: Container(
          padding: const EdgeInsets.only(left: 8, right: 2, top: 2, bottom: 2),
          decoration: BoxDecoration(
            color: tc.cardElevated,
            borderRadius: BorderRadius.circular(rSmall),
            border: Border.all(color: tc.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: fMicro,
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: kMonoFontFallback,
                ),
              ),
              InkWell(
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4, right: 2),
                  child: Icon(Icons.close, size: 12, color: tc.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 录一键弹窗：按下组合即实时校验，被拦的理由直接写在下面。
class _RecordShortcutDialog extends StatefulWidget {
  const _RecordShortcutDialog({required this.action, required this.isMac});

  final TerminalKeyAction action;
  final bool isMac;

  @override
  State<_RecordShortcutDialog> createState() => _RecordShortcutDialogState();
}

class _RecordShortcutDialogState extends State<_RecordShortcutDialog> {
  final FocusNode _focusNode = FocusNode();
  KeyBinding? _captured;

  @override
  void initState() {
    super.initState();
    // 等一帧再抢焦点：弹窗自己的路由动画期间 requestFocus 会被吃掉
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    final hw = HardwareKeyboard.instance;
    // 光按修饰键还没法判定，等主键
    if (!hw.isControlPressed && !hw.isAltPressed && !hw.isMetaPressed) {
      return KeyEventResult.handled;
    }
    final keyName = bindableKeyName(event.logicalKey);
    if (keyName == null) {
      // 表外的键：清空上次录入，否则用户以为已经录上了
      if (_captured != null) setState(() => _captured = null);
      return KeyEventResult.handled;
    }
    final next = KeyBinding(
      keyName: keyName,
      ctrl: hw.isControlPressed,
      shift: hw.isShiftPressed,
      alt: hw.isAltPressed,
      meta: hw.isMetaPressed,
    );
    if (next != _captured) setState(() => _captured = next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final isMac = widget.isMac;
    final captured = _captured;
    final verdict = captured == null
        ? BindingVerdict.ok
        : validateKeyBinding(captured, isMac: isMac);
    final reason =
        captured == null ? '' : bindingVerdictLabel(verdict, isZh: isZh);
    final canAccept = captured != null && !verdict.isBlocking;
    return AlertDialog(
      backgroundColor: tc.cardElevated,
      title: Text(
        UiText.t('为「${widget.action.label(isZh: isZh)}」录入快捷键',
            'Record a shortcut for "${widget.action.label(isZh: isZh)}"'),
        style: TextStyle(color: tc.textMain, fontSize: fBody),
      ),
      content: SizedBox(
        width: 380,
        child: Focus(
          focusNode: _focusNode,
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: tc.bg,
                  borderRadius: BorderRadius.circular(rSmall),
                  border: Border.all(color: canAccept ? tc.brand : tc.border),
                ),
                child: Text(
                  captured?.label(isMac: isMac) ??
                      UiText.t('请按下组合键…', 'Press a key combo…'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: fBody,
                    fontFamily: 'JetBrainsMono',
                    fontFamilyFallback: kMonoFontFallback,
                    color: captured == null ? tc.textMuted : tc.textMain,
                  ),
                ),
              ),
              if (reason.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  reason,
                  style: TextStyle(
                    fontSize: fMicro,
                    color: verdict.isBlocking ? tc.error : tc.warn,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(UiText.t('取消', 'Cancel')),
        ),
        FilledButton(
          onPressed:
              canAccept ? () => Navigator.of(context).pop(captured) : null,
          child: Text(UiText.t('确定', 'Save')),
        ),
      ],
    );
  }
}
