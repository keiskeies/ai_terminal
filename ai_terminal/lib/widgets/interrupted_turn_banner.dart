import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';

/// 历史回合未完成时的横幅：明确标记中断，并提供继续入口
class InterruptedTurnBanner extends StatelessWidget {
  final ThemeColors tc;
  final String? goal;
  final VoidCallback? onContinue;

  const InterruptedTurnBanner({
    super.key,
    required this.tc,
    this.goal,
    this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final goalText = (goal ?? '').trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tc.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.warn.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.pause_circle_outline, size: 16, color: tc.warn),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '任务已中断',
                  style: TextStyle(
                    color: tc.warn,
                    fontSize: fSmall,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  goalText.isEmpty ? '执行记录已保留，可以继续完成' : goalText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: tc.textSub, fontSize: fMicro),
                ),
              ],
            ),
          ),
          if (onContinue != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onContinue,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: tc.brand.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(rXSmall),
                  border: Border.all(color: tc.brand.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_circle_outline,
                        size: 12, color: tc.brand),
                    const SizedBox(width: 4),
                    Text(
                      '继续任务',
                      style: TextStyle(
                        color: tc.brand,
                        fontSize: fMicro,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
