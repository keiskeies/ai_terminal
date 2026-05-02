import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../models/chat_session.dart';
import '../utils/ai_parser.dart';

class CommandBlockWidget extends StatelessWidget {
  final CommandBlock data;
  final VoidCallback? onExecute;
  final VoidCallback? onCopy;

  const CommandBlockWidget({
    super.key,
    required this.data,
    this.onExecute,
    this.onCopy,
  });

  /// 是否包含链式操作符
  bool get _hasChainOperator => hasChainOperator(data.command);

  Color get _safetyColor {
    switch (data.safetyLevel) {
      case 'blocked':
        return cTextSub;
      case 'warn':
        return cWarning;
      case 'info':
        return cPrimary;
      default:
        return cSuccess;
    }
  }

  IconData get _safetyIcon {
    switch (data.safetyLevel) {
      case 'blocked':
        return Icons.block;
      case 'warn':
        return Icons.warning;
      default:
        return Icons.check_circle;
    }
  }

  String get _safetyLabel {
    if (_hasChainOperator) {
      return '链式命令';
    }
    switch (data.safetyLevel) {
      case 'blocked':
        return '高危操作已拦截';
      case 'warn':
        return '需确认';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    // 链式命令特殊处理：显示警告，禁用直接执行
    if (_hasChainOperator) {
      return _buildChainCommandCard();
    }

    return _buildNormalCard();
  }

  /// 链式命令卡片 - 强制显示警告
  Widget _buildChainCommandCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cDanger, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部警告栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: cDanger.withOpacity(0.2),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
                topRight: Radius.circular(6),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber, color: cDanger, size: 18),
                const SizedBox(width: 8),
                Text(
                  '⚠️ 复杂命令，请手动复制到终端执行',
                  style: TextStyle(
                    fontSize: fSmall,
                    color: cDanger,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // 命令文本
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              data.command,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: fMono,
                color: cTerminalGreen,
              ),
            ),
          ),

          // 底部按钮 - 只能复制
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: data.command));
                    onCopy?.call();
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cPrimary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(rButton),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 普通命令卡片
  Widget _buildNormalCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部栏
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Text(
                  '命令',
                  style: TextStyle(fontSize: fSmall, color: cTextSub),
                ),
                const Spacer(),
                if (data.safetyLevel != 'safe')
                  Row(
                    children: [
                      Icon(_safetyIcon, color: _safetyColor, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        _safetyLabel,
                        style: TextStyle(fontSize: fSmall, color: _safetyColor),
                      ),
                    ],
                  ),
              ],
            ),
          ),

          // 命令文本
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SelectableText(
              data.command,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: fMono,
                color: cTerminalGreen,
              ),
            ),
          ),

          // 描述
          if (data.description != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                data.description!,
                style: TextStyle(fontSize: fSmall, color: cTextSub),
              ),
            ),

          // 执行结果
          if (data.hasOutput)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '执行结果:',
                    style: TextStyle(fontSize: fSmall, color: cTextSub),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    data.output!,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: fMono,
                      color: cTextMain,
                    ),
                    maxLines: 10,
                  ),
                ],
              ),
            ),

          // 底部按钮
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: data.command));
                    onCopy?.call();
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: cTextSub,
                    side: const BorderSide(color: cBorder),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: data.isBlocked ? null : onExecute,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('执行'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _safetyColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(rButton),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
