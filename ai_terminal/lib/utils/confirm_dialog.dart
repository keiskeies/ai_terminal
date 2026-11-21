import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/chat_session.dart';
import '../core/app_toast.dart';

Future<bool> showConfirmDialog(BuildContext context, CommandBlock cmd) async {
  if (cmd.safetyLevel == 'blocked') {
    showTopSnackBar(context, 
      SnackBar(
        content: Text(UiText.t('此命令被安全策略拦截', 'This command is blocked by the safety policy')),
        backgroundColor: ThemeColors.of(context).error,
      ),
    );
    return false;
  }

  if (cmd.safetyLevel == 'warn') {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => _WarnConfirmDialog(cmd: cmd),
    );
    return result ?? false;
  }

  // safe 或 info
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => _SimpleConfirmDialog(cmd: cmd),
  );
  return result ?? false;
}

class _SimpleConfirmDialog extends StatelessWidget {
  final CommandBlock cmd;

  const _SimpleConfirmDialog({required this.cmd});

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return AlertDialog(
      title: Text(UiText.t('确认执行命令', 'Confirm command execution')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cmd.description != null) ...[
            Text(cmd.description!, style: TextStyle(color: tc.textSub)),
            const SizedBox(height: 12),
          ],
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tc.terminalBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              cmd.command,
              style: TextStyle(
                fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                fontSize: fMono,
                color: tc.terminalGreen,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(UiText.t('取消', 'Cancel')),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(UiText.t('确认', 'Confirm')),
        ),
      ],
    );
  }
}

class _WarnConfirmDialog extends StatefulWidget {
  final CommandBlock cmd;

  const _WarnConfirmDialog({required this.cmd});

  @override
  State<_WarnConfirmDialog> createState() => _WarnConfirmDialogState();
}

class _WarnConfirmDialogState extends State<_WarnConfirmDialog> {
  final _confirmController = TextEditingController();

  @override
  void dispose() {
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning, color: tc.warn),
          const SizedBox(width: 8),
          Text(UiText.t('危险操作确认', 'Confirm dangerous operation')),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(UiText.t('即将执行:', 'About to run:'),
              style: TextStyle(color: tc.textSub)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tc.terminalBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              widget.cmd.command,
              style: TextStyle(
                fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                fontSize: fMono,
                color: tc.warn,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tc.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tc.error.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: tc.error, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    UiText.t('此操作可能造成系统不可用，请谨慎执行！',
                        'This operation can make the system unavailable. Proceed with caution!'),
                    style: TextStyle(color: tc.error, fontSize: fSmall),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            UiText.t('请输入 CONFIRM 继续:', 'Type CONFIRM to continue:'),
            style: TextStyle(color: tc.warn, fontSize: fSmall),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmController,
            decoration: InputDecoration(
              hintText: UiText.t('输入 CONFIRM', 'Type CONFIRM'),
            ),
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(UiText.t('取消', 'Cancel')),
        ),
        ElevatedButton(
          onPressed: _confirmController.text == 'CONFIRM'
              ? () => Navigator.pop(context, true)
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: tc.error,
          ),
          child: Text(UiText.t('确认执行', 'Run')),
        ),
      ],
    );
  }
}
