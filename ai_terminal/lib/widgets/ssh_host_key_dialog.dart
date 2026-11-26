import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/security/ssh_host_key_verifier.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';

Future<SshHostKeyPromptResponse> showSshHostKeyDialog(
  BuildContext context,
  SshHostKeyRequest request,
) async {
  final tc = ThemeColors.of(context);
  final changed = request.existing != null;

  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      SshHostKeyPromptService.bindCancellation(request.id, () {
        if (!ctx.mounted) return;
        final route = ModalRoute.of(ctx);
        if (route?.isCurrent == true) Navigator.of(ctx).pop();
      });
      return AlertDialog(
        backgroundColor: tc.cardElevated,
        title: Row(
          children: [
            Icon(changed ? Icons.warning_amber_rounded : Icons.verified_user,
                color: changed ? tc.warn : tc.brand, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                UiText.t('确认 SSH 主机身份', 'Verify SSH host identity'),
                style: TextStyle(color: tc.textMain, fontSize: fBody),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                changed
                    ? UiText.t(
                        '该主机的密钥已变化。这可能表示服务器重装了系统，也可能表示连接被冒充。请通过独立可信渠道核对新指纹。',
                        'The host key has changed. The server may have been reinstalled, or this connection may be impersonated. Verify the new fingerprint through an independent trusted channel.',
                      )
                    : UiText.t(
                        '首次连接需要确认主机身份。请通过独立可信渠道核对以下指纹；仅信任本次看到的指纹不能防止中间人攻击。',
                        'Verify the host before its first connection. Check this fingerprint through an independent trusted channel; trusting only what this connection shows cannot prevent a man-in-the-middle attack.',
                      ),
                style:
                    TextStyle(color: tc.textSub, fontSize: fSmall, height: 1.5),
              ),
              const SizedBox(height: 12),
              _detail(UiText.t('连接', 'Connection'), request.routeLabel, tc),
              _detail(UiText.t('地址', 'Address'), request.alias, tc),
              _detail(
                  UiText.t('跳板', 'Jump host'),
                  request.isJumpHost
                      ? UiText.t('是', 'Yes')
                      : UiText.t('否', 'No'),
                  tc),
              _detail(UiText.t('算法', 'Key type'), request.keyType, tc),
              _detail(UiText.t('新指纹', 'New fingerprint'),
                  request.fingerprintSha256, tc),
              if (request.existing != null) ...[
                _detail(UiText.t('已信任指纹', 'Trusted fingerprint'),
                    request.existing!.fingerprintSha256, tc),
                _detail(
                  UiText.t('最近成功验证', 'Last successful verification'),
                  request.existing!.lastSeenAt.toIso8601String(),
                  tc,
                ),
              ],
              const SizedBox(height: 12),
              Text(
                UiText.t(
                  '取消或超时会拒绝连接；撤销的密钥不会在此重新授权。',
                  'Cancellation or timeout rejects the connection. Revoked keys cannot be reauthorized here.',
                ),
                style: TextStyle(color: tc.warn, fontSize: fMicro, height: 1.4),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(UiText.t('取消', 'Cancel'),
                style: TextStyle(color: tc.textSub, fontSize: fSmall)),
          ),
          if (changed)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: tc.warn),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                UiText.t('我已核对，替换密钥', 'Verified, replace key'),
                style: const TextStyle(fontSize: fSmall),
              ),
            )
          else
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                UiText.t('我已核对，信任主机', 'Verified, trust host'),
                style: const TextStyle(fontSize: fSmall),
              ),
            ),
        ],
      );
    },
  );
  return accepted == true
      ? const SshHostKeyPromptResponse.accept(replaceExisting: true)
      : const SshHostKeyPromptResponse.reject();
}

Widget _detail(String label, String value, ThemeColors tc) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: tc.textSub, fontSize: fMicro)),
          const SizedBox(height: 2),
          SelectableText(value,
              style: TextStyle(
                  color: tc.textMain,
                  fontSize: fMicro,
                  fontFamily: 'monospace')),
        ],
      ),
    );
