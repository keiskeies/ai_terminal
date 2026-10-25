import '../models/operation_report.dart';

/// 确定性验证检测器
///
/// 只识别少量格式稳定的只读校验命令，生成"运行中/端口监听/配置通过"
/// 这类徽标。识别不到就不产出徽标，绝不让模型猜一个状态出来。
class VerificationDetector {
  static OperationBadge? detect({
    required String command,
    required String? output,
    required bool success,
  }) {
    final cmd = command.trim();
    final out = (output ?? '').trim();
    if (cmd.isEmpty) return null;

    final isActive = RegExp(r'systemctl\s+is-active\s+(\S+)').firstMatch(cmd);
    if (isActive != null) {
      final service = isActive.group(1) ?? '服务';
      final state = _firstLine(out).toLowerCase();
      if (state == 'active') {
        return OperationBadge(text: '$service 运行中', level: 'success');
      }
      if (state == 'inactive' || state == 'failed' || state == 'unknown') {
        return OperationBadge(text: '$service 未运行', level: 'warning');
      }
      return null;
    }

    final isEnabled = RegExp(r'systemctl\s+is-enabled\s+(\S+)').firstMatch(cmd);
    if (isEnabled != null) {
      final service = isEnabled.group(1) ?? '服务';
      final state = _firstLine(out).toLowerCase();
      if (state == 'enabled') {
        return OperationBadge(text: '$service 开机自启', level: 'success');
      }
      if (state == 'disabled') {
        return OperationBadge(text: '$service 未设置自启', level: 'info');
      }
      return null;
    }

    if (RegExp(r'^ss\s+.*-l').hasMatch(cmd) || RegExp(r'^netstat\s+.*-l').hasMatch(cmd)) {
      final ports = <String>{};
      for (final line in out.split('\n')) {
        if (!line.toUpperCase().contains('LISTEN')) continue;
        for (final match in RegExp(r':(\d{1,5})\s').allMatches(line)) {
          final port = int.tryParse(match.group(1) ?? '');
          if (port != null && port > 0 && port <= 65535) {
            ports.add(port.toString());
          }
        }
      }
      if (ports.isEmpty) return null;
      final sorted = ports.map(int.parse).toList()..sort();
      final shown = sorted.take(4).join('/');
      final suffix = sorted.length > 4 ? ' 等 ${sorted.length} 个端口' : '';
      return OperationBadge(text: '端口 $shown$suffix 监听', level: 'success');
    }

    if (cmd.contains('nginx -t')) {
      return success
          ? const OperationBadge(text: 'Nginx 配置检查通过', level: 'success')
          : const OperationBadge(text: 'Nginx 配置检查失败', level: 'warning');
    }

    if (cmd.contains('curl ')) {
      final match = RegExp(r'HTTP/\S+\s+(\d{3})').firstMatch(out);
      final status = match?.group(1);
      if (status != null) {
        final code = int.tryParse(status) ?? 0;
        return OperationBadge(
          text: 'HTTP $status',
          level: code >= 200 && code < 400 ? 'success' : 'warning',
        );
      }
      return null;
    }

    return null;
  }

  static String _firstLine(String text) {
    final idx = text.indexOf('\n');
    return (idx < 0 ? text : text.substring(0, idx)).trim();
  }
}
