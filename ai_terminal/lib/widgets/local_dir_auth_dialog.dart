import 'dart:io';
import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../services/local_access.dart';
import '../utils/agent_ui_text.dart';

/// 本机目录授权弹窗。
///
/// 返回 true 表示用户允许；只签发当前任务的短时授权，不写持久化白名单。
/// 路径、权限类型、原因、是否会被创建都必须在弹窗里说清楚，不能静默扩权。
Future<bool> showLocalDirAuthDialog(
  BuildContext context, {
  required String path,
  required String reason,
  required LocalAccessMode mode,
}) async {
  final ui = AgentUiText.of(context);
  final tc = ThemeColors.of(context);
  final willCreate = !Directory(path).existsSync();
  final modeLabel = switch (mode) {
    LocalAccessMode.read => UiText.t('读取', 'read'),
    LocalAccessMode.write => UiText.t('写入', 'write'),
    LocalAccessMode.execute => UiText.t('执行命令', 'execute commands'),
  };
  final approved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: tc.cardElevated,
      title: Row(
        children: [
          Icon(Icons.folder_open, color: tc.brand, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ui.localExecAuthTitle,
              style: TextStyle(color: tc.textMain, fontSize: fBody),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            UiText.t(
              'Agent 需要$modeLabel以下本机目录及其子目录：\n$path\n\n'
                  '原因：$reason\n\n'
                  '${willCreate ? '该目录不存在，允许后将创建。\n' : ''}'
                  '授权仅对当前任务生效，并会在短时间后过期；'
                  '任务暂停、取消或完成时立即撤销，不写入长期白名单。',
              'The agent needs to $modeLabel files in this local folder and its subfolders:\n$path\n\n'
                  'Reason: $reason\n\n'
                  '${willCreate ? 'The folder does not exist and will be created.\n' : ''}'
                  'This grant applies only to the current task and expires shortly. '
                  'Pausing, cancelling, or completing the task revokes it immediately. '
                  'It is not added to the persistent allowlist.',
            ),
            style: TextStyle(color: tc.textSub, fontSize: fSmall, height: 1.5),
          ),
          const SizedBox(height: 8),
          Text(
            mode == LocalAccessMode.execute
                ? UiText.t(
                    '敏感路径（~/.ssh、.env、密钥等）仍然禁止。执行授权不是操作系统沙箱，命令仍可能访问目录之外，请只允许可信命令。',
                    'Sensitive paths (~/.ssh, .env, keys) remain blocked. Execute access is not an OS sandbox; commands may still reach outside this folder. Allow only trusted commands.',
                  )
                : ui.localExecAuthNote,
            style: TextStyle(color: tc.warn, fontSize: fMicro),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(ui.cancel,
              style: TextStyle(color: tc.textSub, fontSize: fSmall)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ui.localExecAuthAllow,
              style: const TextStyle(fontSize: fSmall)),
        ),
      ],
    ),
  );
  return approved == true;
}
