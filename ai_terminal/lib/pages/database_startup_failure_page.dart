import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 数据库无法解锁时的阻塞界面。
///
/// 这里不能初始化正常 Provider/Router：DbInit 尚未完成，任何 DAO 读取都会
/// 触发未初始化断言。界面只提供诊断和退出，避免把“空库”当成正常状态继续跑。
class DatabaseStartupFailureApp extends StatelessWidget {
  const DatabaseStartupFailureApp({
    super.key,
    required this.error,
    this.stackTrace,
  });

  final Object error;
  final StackTrace? stackTrace;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: DatabaseStartupFailurePage(error: error, stackTrace: stackTrace),
    );
  }
}

class DatabaseStartupFailurePage extends StatelessWidget {
  const DatabaseStartupFailurePage({
    super.key,
    required this.error,
    this.stackTrace,
  });

  final Object error;
  final StackTrace? stackTrace;

  String get _diagnostics {
    final buffer = StringBuffer()
      ..writeln('AiTerminal 数据库启动失败')
      ..writeln('时间: ${DateTime.now().toIso8601String()}')
      ..writeln('错误: $error');
    if (stackTrace != null) {
      buffer
        ..writeln()
        ..writeln('调用栈:')
        ..writeln(stackTrace);
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFF9AA4B2);
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_outline, size: 40, color: Color(0xFFFFB020)),
                const SizedBox(height: 16),
                const Text(
                  '无法解锁本地数据库',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text(
                  '为避免覆盖或丢弃已有数据，应用已停止进入主界面，也不会自动创建空库。'
                  '请确认系统安全存储中的数据库密钥可用，或恢复应用私有目录中的迁移备份后重启。',
                  style: TextStyle(color: muted, height: 1.5),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF151821),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF2A2F3A)),
                  ),
                  child: SelectableText(
                    error.toString(),
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: Color(0xFFFF8A80),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: _diagnostics),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('诊断信息已复制')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_all_outlined, size: 18),
                      label: const Text('复制诊断信息'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => SystemNavigator.pop(),
                      icon: const Icon(Icons.exit_to_app, size: 18),
                      label: const Text('退出应用'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}