import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../models/chat_session.dart';

Future<bool> showConfirmDialog(BuildContext context, CommandBlock cmd) async {
  if (cmd.safetyLevel == 'blocked') {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('此命令被安全策略拦截'),
        backgroundColor: cDanger,
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
    return AlertDialog(
      title: const Text('确认执行命令'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cmd.description != null) ...[
            Text(cmd.description!, style: TextStyle(color: cTextSub)),
            const SizedBox(height: 12),
          ],
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              cmd.command,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: fMono,
                color: cTerminalGreen,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('确认'),
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
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning, color: cWarning),
          const SizedBox(width: 8),
          const Text('危险操作确认'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('即将执行:', style: TextStyle(color: cTextSub)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              widget.cmd.command,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: fMono,
                color: cWarning,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cDanger.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: cDanger.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: cDanger, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '此操作可能造成系统不可用，请谨慎执行！',
                    style: TextStyle(color: cDanger, fontSize: fSmall),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '请输入 CONFIRM 继续:',
            style: TextStyle(color: cWarning, fontSize: fSmall),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmController,
            decoration: const InputDecoration(
              hintText: '输入 CONFIRM',
            ),
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _confirmController.text == 'CONFIRM'
              ? () => Navigator.pop(context, true)
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: cDanger,
          ),
          child: const Text('确认执行'),
        ),
      ],
    );
  }
}
