import 'dart:io';
import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../utils/agent_ui_text.dart';

/// 本机目录授权弹窗。
///
/// 返回 true 表示用户允许；策略写回由调用方完成，弹窗本身不碰持久化。
/// 路径、原因、是否会被创建都必须在弹窗里说清楚，不能静默扩权。
Future<bool> showLocalDirAuthDialog(
  BuildContext context, {
  required String path,
  required String reason,
}) async {
  final ui = AgentUiText.of(context);
  final tc = ThemeColors.of(context);
  final willCreate = !Directory(path).existsSync();
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
            ui.localExecAuthBody(path, reason, willCreate),
            style: TextStyle(color: tc.textSub, fontSize: fSmall, height: 1.5),
          ),
          const SizedBox(height: 8),
          Text(
            ui.localExecAuthNote,
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
