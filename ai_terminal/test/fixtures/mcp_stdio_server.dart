import 'package:mcp_dart/mcp_dart.dart';

Future<void> main() async {
  final server = McpServer(
    const Implementation(name: 'stdio-test-server', version: '1.0.0'),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(listChanged: false),
      ),
    ),
  );

  server.registerTool(
    'echo',
    description: 'Echo message over stdio',
    inputSchema: JsonSchema.object(
      properties: {'message': JsonSchema.string()},
      required: ['message'],
    ),
    annotations: const ToolAnnotations(
      readOnlyHint: true,
      destructiveHint: false,
    ),
    callback: (args, extra) async => CallToolResult(
      content: [TextContent(text: 'stdio:${args['message']}')],
    ),
  );

  await server.connect(StdioServerTransport());
}
