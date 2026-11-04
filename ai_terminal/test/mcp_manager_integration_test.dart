import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/mcp_manager.dart';
import 'package:ai_terminal/services/mcp_models.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

void main() {
  group('McpManager + Streamable HTTP', () {
    late StreamableMcpServer server;
    late McpServer connectedServer;

    setUp(() async {
      server = StreamableMcpServer(
        serverFactory: (sessionId) {
          final instance = _buildServer();
          connectedServer = instance;
          return instance;
        },
        host: '127.0.0.1',
        port: 0,
        path: '/mcp',
        protocol: McpProtocol.legacy,
      );
      await server.start();
    });

    tearDown(() async {
      await McpManager.instance.disconnect('test');
      McpManager.instance.loadConfigsForTesting([]);
      await McpManager.instance.setGlobalEnabled(true);
      await server.stop();
    });

    McpServerConfig config() => McpServerConfig(
          id: 'test',
          name: 'Test Server',
          enabled: true,
          transport: McpTransportKind.streamableHttp,
          url: 'http://127.0.0.1:${server.boundPort}/mcp',
          timeoutMs: 15000,
          toolExposure: McpToolExposure.all,
        );

    test('连接、发现、调用工具、读取资源、获取提示词', () async {
      final manager = McpManager.instance;
      manager.loadConfigsForTesting([config()]);
      await manager.connect('test');

      final runtime = manager.mcpRuntime('test')!;
      expect(
        runtime.status,
        McpServerStatus.connected,
        reason: runtime.error,
      );
      expect(runtime.tools.any((t) => t.name == 'echo'), isTrue,
          reason: 'tools=${runtime.tools.map((t) => t.name)}');
      expect(runtime.resources.any((r) => r.uri == 'test://doc'), isTrue,
          reason: 'resources=${runtime.resources.map((r) => r.uri)}');
      expect(runtime.prompts.any((p) => p.name == 'review'), isTrue,
          reason: 'prompts=${runtime.prompts.map((p) => p.name)}');

      final tools = manager.buildAgentTools();
      final echo = tools.firstWhere((t) => t.name.endsWith('__echo'));
      final result = await echo.execute(
        executor: _MockExecutor(),
        args: const ToolArgs({'json': '{"message":"hi"}'}),
      );
      expect(result.success, isTrue, reason: result.error);
      expect(result.output, contains('echo:hi'));

      final resource = await manager.readMcpResource('test', 'test://doc');
      expect(resource, contains('hello resource'));

      final prompt = await manager.getMcpPrompt(
        'test',
        'review',
        arguments: const {'diff': 'abc'},
      );
      expect(prompt, contains('abc'));

      await manager.disconnect('test');
      expect(
        manager.mcpRuntime('test')!.status,
        McpServerStatus.disconnected,
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('全局开关关闭后断开并隐藏工具，重新打开恢复连接', () async {
      final manager = McpManager.instance;
      manager.loadConfigsForTesting([config()]);
      await manager.connect('test');
      expect(
        manager.mcpRuntime('test')!.status,
        McpServerStatus.connected,
        reason: manager.mcpRuntime('test')!.error,
      );
      expect(manager.buildAgentTools(), isNotEmpty);

      await manager.setGlobalEnabled(false);
      expect(manager.enabled, isFalse);
      expect(
        manager.mcpRuntime('test')!.status,
        McpServerStatus.disconnected,
      );
      expect(manager.buildAgentTools(), isEmpty);

      await manager.setGlobalEnabled(true);
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (manager.mcpRuntime('test')!.isConnected) break;
      }
      expect(
        manager.mcpRuntime('test')!.status,
        McpServerStatus.connected,
        reason: manager.mcpRuntime('test')!.error,
      );
      expect(manager.buildAgentTools(), isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('tools/list_changed 触发能力刷新', () async {      final manager = McpManager.instance;
      manager.loadConfigsForTesting([config()]);
      await manager.connect('test');
      expect(
        manager.mcpRuntime('test')!.status,
        McpServerStatus.connected,
        reason: manager.mcpRuntime('test')!.error,
      );

      connectedServer.registerTool(
        'late_tool',
        description: 'registered after connect',
        inputSchema: JsonSchema.object(properties: const {}),
        annotations: const ToolAnnotations(
          readOnlyHint: true,
          destructiveHint: false,
        ),
        callback: (args, extra) async => const CallToolResult(
          content: [TextContent(text: 'late')],
        ),
      );

      var found = false;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final runtime = manager.mcpRuntime('test');
        if (runtime?.tools.any((t) => t.name == 'late_tool') == true) {
          found = true;
          break;
        }
      }
      expect(found, isTrue, reason: 'list_changed 后没有发现 late_tool');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}

McpServer _buildServer() {
  final server = McpServer(
    const Implementation(name: 'test-server', version: '1.0.0'),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(listChanged: true),
        resources: ServerCapabilitiesResources(listChanged: true),
        prompts: ServerCapabilitiesPrompts(listChanged: true),
      ),
    ),
  );

  server.registerTool(
    'echo',
    description: 'Echo message',
    inputSchema: JsonSchema.object(
      properties: {'message': JsonSchema.string()},
      required: ['message'],
    ),
    annotations: const ToolAnnotations(
      readOnlyHint: true,
      destructiveHint: false,
    ),
    callback: (args, extra) async => CallToolResult(
      content: [TextContent(text: 'echo:${args['message']}')],
    ),
  );

  server.registerTool(
    'delete_everything',
    description: 'Destructive test tool',
    inputSchema: JsonSchema.object(properties: const {}),
    annotations: const ToolAnnotations(
      readOnlyHint: false,
      destructiveHint: true,
    ),
    callback: (args, extra) async => const CallToolResult(
      content: [TextContent(text: 'deleted')],
    ),
  );

  server.registerResource(
    'Doc',
    'test://doc',
    (description: 'A test document', mimeType: 'text/plain'),
    (uri, extra) async => ReadResourceResult(
      contents: [
        TextResourceContents(
          uri: uri.toString(),
          text: 'hello resource',
        ),
      ],
    ),
  );

  server.registerPrompt(
    'review',
    description: 'Review a diff',
    argsSchema: const {
      'diff': PromptArgumentDefinition(description: 'diff', required: true),
    },
    callback: (args, extra) async => GetPromptResult(
      messages: [
        PromptMessage(
          role: PromptMessageRole.user,
          content: TextContent(text: args?['diff'] ?? ''),
        ),
      ],
    ),
  );

  return server;
}

class _MockExecutor implements CommandExecutor {
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
