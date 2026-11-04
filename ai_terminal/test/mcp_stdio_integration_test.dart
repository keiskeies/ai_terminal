import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/mcp_manager.dart';
import 'package:ai_terminal/services/mcp_models.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

void main() {
  test('stdio MCP：启动子进程、发现工具、调用、断开', () async {
    final dartExe = _findDartExecutable();
    if (dartExe == null) {
      // 测试机没有可用的 Dart 可执行文件时跳过；HTTP 路径已覆盖主链路
      markTestSkipped('未找到 FLUTTER_ROOT 下的 dart 可执行文件');
      return;
    }
    final fixture = p.absolute('test/fixtures/mcp_stdio_server.dart');
    final manager = McpManager.instance;
    manager.loadConfigsForTesting([
      McpServerConfig(
        id: 'stdio',
        name: 'Stdio Test',
        enabled: true,
        transport: McpTransportKind.stdio,
        command: dartExe,
        args: ['run', fixture],
        workingDirectory: Directory.current.path,
        timeoutMs: 30000,
        toolExposure: McpToolExposure.all,
      ),
    ]);

    await manager.connect('stdio');
    final runtime = manager.mcpRuntime('stdio')!;
    expect(
      runtime.status,
      McpServerStatus.connected,
      reason: runtime.error,
    );
    expect(runtime.tools.any((t) => t.name == 'echo'), isTrue);

    final echo = manager
        .buildAgentTools()
        .firstWhere((tool) => tool.name.endsWith('__echo'));
    final result = await echo.execute(
      executor: _NoopExecutor(),
      args: const ToolArgs({'json': '{"message":"hi"}'}),
    );
    expect(result.success, isTrue, reason: result.error);
    expect(result.output, contains('stdio:hi'));

    await manager.disconnect('stdio');
    expect(
      manager.mcpRuntime('stdio')!.status,
      McpServerStatus.disconnected,
    );
    manager.loadConfigsForTesting([]);
  }, timeout: const Timeout(Duration(seconds: 90)));
}

String? _findDartExecutable() {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final exe = p.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );
    if (File(exe).existsSync()) return exe;
  }
  return null;
}

class _NoopExecutor implements CommandExecutor {
  @override
  bool get isConnected => true;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  void execute(String command) {}
  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
    String? sudoPassword,
  }) async =>
      CommandResult(
        stdout: '',
        stderr: '',
        exitCode: 0,
        duration: Duration.zero,
      );
  @override
  Future<String> runOnce(
    String command, {
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      '';
  @override
  Future<CommandResult> writeFileViaPty({
    required String path,
    required Uint8List content,
    bool useSudo = false,
    Duration timeout = const Duration(seconds: 30),
    Completer<void>? cancelToken,
  }) async =>
      CommandResult(
        stdout: '',
        stderr: '',
        exitCode: 0,
        duration: Duration.zero,
      );
  @override
  void writeToTerminal(String data) {}
}
