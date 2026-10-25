import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';

/// 重连期间的常驻状态横幅
class ReconnectingBanner extends StatelessWidget {
  final ThemeColors tc;
  final String hostLabel;

  const ReconnectingBanner({
    super.key,
    required this.tc,
    required this.hostLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: tc.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.warn.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: tc.warn,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '正在重连 $hostLabel · 连接恢复中',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tc.warn,
                fontSize: fSmall,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
