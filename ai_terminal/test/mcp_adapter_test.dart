import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/mcp_manager.dart';
import 'package:ai_terminal/services/mcp_models.dart';
import 'package:ai_terminal/services/mcp_tool_adapter.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

void main() {
  group('MCP tool adapter', () {
    test('readOnly / destructive 映射到 ToolKind，其余为 network', () {
      final readOnly = _tool(
        name: 'read',
        readOnly: true,
        destructive: false,
      );
      final destructive = _tool(
        name: 'delete',
        readOnly: false,
        destructive: true,
      );
      final external = _tool(
        name: 'write',
        readOnly: false,
        destructive: false,
      );

      final caller = _FakeCaller();
      expect(_adapter(caller, readOnly).kind, ToolKind.read);
      expect(_adapter(caller, destructive).kind, ToolKind.destructive);
      expect(_adapter(caller, external).kind, ToolKind.network);
      expect(_adapter(caller, destructive).recordsChanges, isFalse);
    });

    test('json 参数透传给 MCP，并把返回内容包装成 ToolResult', () async {
      final caller = _FakeCaller();
      final adapter = _adapter(
        caller,
        _tool(name: 'echo', readOnly: true, destructive: false),
      );
      final result = await adapter.execute(
        executor: _MockExecutor(),
        args: const ToolArgs({'json': '{"message":"hi"}'}),
      );

      expect(caller.lastArguments, {'message': 'hi'});
      expect(result.success, isTrue);
      expect(result.output, contains('mcp://fake/echo'));
      expect(result.output, contains('echo:hi'));
    });

    test('Function Calling 的扁平参数也能透传', () async {
      final caller = _FakeCaller();
      final adapter = _adapter(
        caller,
        _tool(name: 'echo', readOnly: true, destructive: false),
      );
      await adapter.execute(
        executor: _MockExecutor(),
        args: const ToolArgs({'message': 'flat'}),
      );
      expect(caller.lastArguments, {'message': 'flat'});
    });

    test('非法 json 返回失败而不调用 MCP', () async {
      final caller = _FakeCaller();
      final adapter = _adapter(
        caller,
        _tool(name: 'echo', readOnly: true, destructive: false),
      );
      final result = await adapter.execute(
        executor: _MockExecutor(),
        args: const ToolArgs({'json': '{bad'}),
      );
      expect(result.success, isFalse);
      expect(caller.lastArguments, isNull);
    });

    test('资源列表工具读取 runtime 中的资源', () async {
      final caller = _FakeCaller()
        ..runtime = const McpServerRuntime(
          config: McpServerConfig(id: 'fake', name: 'Fake'),
          status: McpServerStatus.connected,
          resources: [
            McpResourceDescriptor(
              uri: 'test://doc',
              name: 'Doc',
              title: 'Doc',
              description: 'A doc',
              mimeType: 'text/plain',
            ),
          ],
        );
      final adapter = McpSideToolAdapter(
        caller: caller,
        serverId: 'fake',
        serverName: 'Fake',
        sideKind: McpSideToolKind.listResources,
      );
      final result = await adapter.execute(
        executor: _MockExecutor(),
        args: ToolArgs.empty,
      );
      expect(result.success, isTrue);
      expect(result.output, contains('test://doc'));
    });

    test('syncRegistry 注册/注销 MCP 工具并进入 prompt 与 FC schema', () {
      final manager = McpManager.instance;
      manager.loadConfigsForTesting([]);
      const config = McpServerConfig(
        id: 'fake',
        name: 'Fake',
        toolExposure: McpToolExposure.readOnly,
      );
      manager.setRuntimeForTesting(const McpServerRuntime(
        config: config,
        status: McpServerStatus.connected,
        tools: [
          McpToolDescriptor(
            name: 'echo',
            title: 'echo',
            description: 'echo',
            inputSchema: {
              'type': 'object',
              'properties': {
                'message': {'type': 'string'},
              },
            },
            readOnly: true,
            destructive: false,
            idempotent: true,
            openWorld: true,
          ),
          McpToolDescriptor(
            name: 'delete',
            title: 'delete',
            description: 'delete',
            inputSchema: {'type': 'object', 'properties': {}},
            readOnly: false,
            destructive: true,
            idempotent: false,
            openWorld: true,
          ),
        ],
      ));

      final registry = AgentToolRegistry();
      manager.syncRegistry(registry);
      expect(registry.has('mcp__fake__echo'), isTrue);
      expect(registry.has('mcp__fake__delete'), isFalse);
      expect(
        registry.buildToolsPrompt(isLocalSession: true),
        contains('mcp__fake__echo'),
      );
      expect(
        registry.buildOpenAIToolsSchema(isLocalSession: true).any(
              (s) => (s['function'] as Map)['name'] == 'mcp__fake__echo',
            ),
        isTrue,
      );

      manager.setRuntimeForTesting(const McpServerRuntime(
        config: McpServerConfig(
          id: 'fake',
          name: 'Fake',
          toolExposure: McpToolExposure.all,
        ),
        status: McpServerStatus.connected,
        tools: [
          McpToolDescriptor(
            name: 'delete',
            title: 'delete',
            description: 'delete',
            inputSchema: {'type': 'object', 'properties': {}},
            readOnly: false,
            destructive: true,
            idempotent: false,
            openWorld: true,
          ),
        ],
      ));
      manager.syncRegistry(registry);
      expect(registry.has('mcp__fake__delete'), isTrue);
      expect(
        registry.get('mcp__fake__delete')!.kind,
        ToolKind.destructive,
      );

      manager.loadConfigsForTesting([]);
      manager.syncRegistry(registry);
      expect(registry.has('mcp__fake__delete'), isFalse);
    });
  });
}

McpToolAdapter _adapter(McpToolCaller caller, McpToolDescriptor tool) =>
    McpToolAdapter(
      caller: caller,
      serverId: 'fake',
      serverName: 'Fake',
      descriptor: tool,
    );

McpToolDescriptor _tool({
  required String name,
  required bool readOnly,
  required bool destructive,
}) =>
    McpToolDescriptor(
      name: name,
      title: name,
      description: 'desc',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'message': {'type': 'string'},
        },
      },
      readOnly: readOnly,
      destructive: destructive,
      idempotent: true,
      openWorld: true,
    );

class _FakeCaller implements McpToolCaller {
  Map<String, dynamic>? lastArguments;
  McpServerRuntime? runtime;

  @override
  Future<McpCallResult> callMcpTool(
    String serverId,
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    lastArguments = arguments;
    return McpCallResult(
      isError: false,
      text: 'mcp://$serverId/$toolName echo:${arguments['message']}',
    );
  }

  @override
  Future<String> readMcpResource(String serverId, String uri) async =>
      'resource:$uri';

  @override
  Future<String> getMcpPrompt(
    String serverId,
    String name, {
    Map<String, String> arguments = const {},
  }) async =>
      'prompt:$name';

  @override
  McpServerRuntime? mcpRuntime(String serverId) => runtime;
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
