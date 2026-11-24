import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/host_execution_result.dart';
import '../core/l10n_holder.dart';

/// 多主机批量结果矩阵：按主机展示成功/失败、耗时、退出码与输出摘要
class HostResultMatrix extends StatefulWidget {
  final Map<String, HostExecutionResult> results;
  final ThemeColors tc;
  final void Function(List<String> failedHostIds)? onRetryFailedHosts;

  const HostResultMatrix({
    super.key,
    required this.results,
    required this.tc,
    this.onRetryFailedHosts,
  });

  @override
  State<HostResultMatrix> createState() => _HostResultMatrixState();
}

class _HostResultMatrixState extends State<HostResultMatrix> {
  final Set<String> _expandedHosts = {};

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final hostIds = widget.results.keys.toList()..sort();
    final success = widget.results.values.where((r) => r.success).length;
    final notRun = widget.results.values.where(_isNotRun).length;
    final failed = widget.results.length - success - notRun;
    final failedHostIds = hostIds.where((id) {
      final result = widget.results[id];
      return result != null && !result.success && !_isNotRun(result);
    }).toList(growable: false);
    final summaryParts = <String>[
      '${widget.results.length} 台主机',
      '$success 成功',
      if (failed > 0) '$failed 失败',
      if (notRun > 0) '$notRun 未执行',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.dns_outlined, size: 13, color: tc.textSub),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                UiText.t(
                    summaryParts.join(' · '),
                    '${widget.results.length} hosts · $success succeeded'
                    '${failed > 0 ? " · $failed failed" : ""}'
                    '${notRun > 0 ? " · $notRun not run" : ""}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: failed > 0 ? tc.error : tc.textSub,
                  fontSize: fMicro,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (failed > 0 && widget.onRetryFailedHosts != null) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => widget.onRetryFailedHosts!(failedHostIds),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: tc.brand.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(rXSmall),
                    border: Border.all(color: tc.brand.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh, size: 11, color: tc.brand),
                      const SizedBox(width: 3),
                      Text(
                        UiText.t('重试失败主机', 'Retry failed hosts'),
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
        const SizedBox(height: 4),
        ...hostIds.map((hostId) => _buildRow(hostId, widget.results[hostId]!)),
      ],
    );
  }

  static bool _isNotRun(HostExecutionResult result) =>
      !result.success &&
      (result.failureKind == 'skipped' || result.failureKind == 'cancelled');

  Widget _buildRow(String hostId, HostExecutionResult result) {
    final tc = widget.tc;
    final notRun = _isNotRun(result);
    final color = result.success ? tc.ok : (notRun ? tc.textMuted : tc.error);
    final expanded = _expandedHosts.contains(hostId);
    final detail =
        (result.success ? result.output : (result.error ?? result.output)) ??
            '';
    final preview = _firstLine(detail);
    final meta = <String>[
      if (result.durationMs != null) _formatDuration(result.durationMs!),
      if (result.exitCode != null) L10n.str.ut_00fefb12c8(result.exitCode ?? 0),
    ];
    final statusText = result.success
        ? UiText.t('成功', 'OK')
        : _failureLabel(result.failureKind);
    final icon = result.success
        ? Icons.check_circle
        : (result.failureKind == 'skipped'
            ? Icons.remove_circle_outline
            : (result.failureKind == 'cancelled'
                ? Icons.cancel_outlined
                : Icons.error_outline));

    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      decoration: BoxDecoration(
        color: result.success || notRun
            ? Colors.transparent
            : tc.error.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(rXSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: detail.isEmpty
                ? null
                : () => setState(() {
                      if (expanded) {
                        _expandedHosts.remove(hostId);
                      } else {
                        _expandedHosts.add(hostId);
                      }
                    }),
            borderRadius: BorderRadius.circular(rXSmall),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 13, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                hostId,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tc.textMain,
                                  fontSize: fSmall,
                                  fontFamily: 'JetBrainsMono',
                                  fontFamilyFallback: kMonoFontFallback,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              statusText,
                              style: TextStyle(
                                color: color,
                                fontSize: fMicro,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        if (meta.isNotEmpty || preview.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (meta.isNotEmpty) meta.join(' · '),
                              if (preview.isNotEmpty) preview,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: tc.textMuted,
                              fontSize: fMicro,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 14,
                      color: tc.textMuted,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (expanded)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(6, 0, 6, 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: tc.terminalBg,
                borderRadius: BorderRadius.circular(rXSmall),
                border: Border.all(color: tc.border),
              ),
              child: Text(
                detail,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontFamilyFallback: kMonoFontFallback,
                  fontSize: fMicro,
                  color: tc.textBody,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _firstLine(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final idx = trimmed.indexOf('\n');
    return idx < 0 ? trimmed : trimmed.substring(0, idx).trim();
  }

  String _failureLabel(String? failureKind) {
    switch (failureKind) {
      case 'disconnected':
        return UiText.t('连接断开', 'Disconnected');
      case 'timeout':
        return UiText.t('超时', 'Timed out');
      case 'permissionDenied':
        return UiText.t('权限不足', 'Permission denied');
      case 'interactivePrompt':
        return UiText.t('等待输入', 'Waiting for input');
      case 'syntaxError':
        return UiText.t('语法错误', 'Syntax error');
      case 'cancelled':
        return UiText.t('已取消', 'Cancelled');
      case 'skipped':
        return UiText.t('未执行', 'Skipped');
      default:
        return UiText.t('执行失败', 'Failed');
    }
  }

  String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    final seconds = ms / 1000;
    if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
    return '${seconds ~/ 60}m${(seconds % 60).round()}s';
  }
}
