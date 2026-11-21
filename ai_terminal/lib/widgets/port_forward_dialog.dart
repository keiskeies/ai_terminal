import 'dart:math' as math;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../services/port_forward_service.dart';

/// 端口转发管理弹窗：规则列表 + 添加表单。
/// [client] 用 getter 传入，重连后能拿到新连接（旧转发已失效，需重新添加）。
class PortForwardDialog extends StatefulWidget {
  const PortForwardDialog({
    super.key,
    required this.service,
    required this.client,
  });

  final PortForwardService service;
  final SSHClient? Function() client;

  @override
  State<PortForwardDialog> createState() => _PortForwardDialogState();
}

class _PortForwardDialogState extends State<PortForwardDialog> {
  ForwardDirection _direction = ForwardDirection.local;
  final _bindPortController = TextEditingController();
  final _targetHostController = TextEditingController(text: '127.0.0.1');
  final _targetPortController = TextEditingController();
  bool _busy = false;
  String? _formError;

  @override
  void dispose() {
    _bindPortController.dispose();
    _targetHostController.dispose();
    _targetPortController.dispose();
    super.dispose();
  }

  Future<void> _addRule() async {
    final client = widget.client();
    if (client == null) {
      setState(() => _formError =
          UiText.t('当前标签未连接，无法建立转发', 'Tab is not connected'));
      return;
    }
    final bindPort = int.tryParse(_bindPortController.text.trim());
    final targetPort = int.tryParse(_targetPortController.text.trim());
    final targetHost = _targetHostController.text.trim();
    if (bindPort == null || bindPort <= 0 || bindPort > 65535 ||
        targetPort == null || targetPort <= 0 || targetPort > 65535 ||
        targetHost.isEmpty) {
      setState(() => _formError =
          UiText.t('请填写有效的端口（1-65535）和目标主机', 'Enter valid ports (1-65535) and target host'));
      return;
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    final rule = _direction == ForwardDirection.local
        ? await widget.service.addLocal(client,
            bindPort: bindPort, targetHost: targetHost, targetPort: targetPort)
        : await widget.service.addRemote(client,
            bindPort: bindPort, targetHost: targetHost, targetPort: targetPort);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _formError = rule.error;
      if (rule.error == null) {
        _bindPortController.clear();
        _targetPortController.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      child: ConstrainedBox(
        // 小屏按视口 92% 缩放，大屏保持 560 上限；高度加 85% 视口保护
        constraints: BoxConstraints(
          maxWidth: math.min(560, size.width * 0.92),
          maxHeight: math.min(560, size.height * 0.85),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      UiText.t('端口转发', 'Port forwarding'),
                      style: TextStyle(
                          fontSize: fTitle,
                          fontWeight: FontWeight.w600,
                          color: tc.textMain),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListenableBuilder(
                  listenable: widget.service,
                  builder: (context, _) {
                    final rules = widget.service.rules;
                    if (rules.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          UiText.t('暂无转发规则', 'No forwarding rules'),
                          style: TextStyle(color: tc.textMuted, fontSize: fBody),
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: rules.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: tc.hairline),
                      itemBuilder: (context, i) {
                        final rule = rules[i];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            rule.direction == ForwardDirection.local
                                ? Icons.arrow_forward
                                : Icons.arrow_back,
                            size: 16,
                            color: rule.active ? tc.brand : tc.textMuted,
                          ),
                          title: Text(rule.label,
                              style: TextStyle(
                                  fontSize: fBody,
                                  color: tc.textMain,
                                  fontFamily: 'JetBrainsMono')),
                          subtitle: Text(
                            rule.error ??
                                UiText.t(
                                    '${rule.direction == ForwardDirection.local ? "本地" : "远程"}转发 · 已转发 ${rule.connections} 个连接',
                                    '${rule.direction == ForwardDirection.local ? "Local" : "Remote"} · ${rule.connections} connections'),
                            style: TextStyle(
                                fontSize: fMicro,
                                color: rule.error != null
                                    ? tc.error
                                    : tc.textSub),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            tooltip: UiText.t('停止并删除', 'Stop and remove'),
                            onPressed: () => widget.service.remove(rule.id),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Divider(height: 1, color: tc.hairline),
              const SizedBox(height: 12),
              SegmentedButton<ForwardDirection>(
                segments: [
                  ButtonSegment(
                    value: ForwardDirection.local,
                    label: Text(UiText.t('本地 → 远端', 'Local → Remote')),
                  ),
                  ButtonSegment(
                    value: ForwardDirection.remote,
                    label: Text(UiText.t('远端 → 本地', 'Remote → Local')),
                  ),
                ],
                selected: {_direction},
                onSelectionChanged: (s) =>
                    setState(() => _direction = s.first),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _bindPortController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: UiText.t('监听端口', 'Listen port'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _targetHostController,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: UiText.t('目标主机', 'Target host'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _targetPortController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: UiText.t('目标端口', 'Target port'),
                      ),
                    ),
                  ),
                ],
              ),
              if (_formError != null) ...[
                const SizedBox(height: 8),
                Text(_formError!,
                    style: TextStyle(fontSize: fSmall, color: tc.error)),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _addRule,
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add, size: 16),
                  label: Text(UiText.t('添加转发', 'Add forward')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}