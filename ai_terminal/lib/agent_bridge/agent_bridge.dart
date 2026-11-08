// agent_bridge/agent_bridge.dart
// High-level Dart client for the agent-core Node subprocess.
// Phase 0: spawn + rpc:ping + rpc:getState + rpc:cancelTask.

import "dart:async";
import "dart:io";
import "json_rpc_transport.dart";

/// Spawns and manages the agent-core Node subprocess.
///
/// Usage:
///   final bridge = AgentBridge(nodePath: ".../dist/index.js");
///   await bridge.start();
///   final pong = await bridge.ping();
///   await bridge.dispose();
class AgentBridge {
  final String nodePath;       // path to node binary
  final String entryPath;      // path to dist/index.js
  final List<String> extraArgs; // extra CLI args to pass to node

  Process? _process;
  StdioParentTransport? _transport;

  AgentBridge({
    required this.nodePath,
    required this.entryPath,
    this.extraArgs = const [],
  });

  /// Spawn the Node subprocess and complete the rpc:ping handshake.
  Future<void> start() async {
    _process = await Process.start(
      nodePath,
      [entryPath, ...extraArgs],
      mode: ProcessStartMode.normal,
    );
    _transport = StdioParentTransport(_process);

    // Handshake: verify the child is alive and speaking our protocol.
    final pong = await _transport!.request("rpc:ping");
    if (pong["ok"] != true) {
      await dispose();
      throw StateError("agent-core handshake failed: $pong");
    }
  }

  Future<Map<String, dynamic>> ping() async {
    _ensureRunning();
    return _transport!.request("rpc:ping");
  }

  Future<Map<String, dynamic>> getState() async {
    _ensureRunning();
    return _transport!.request("rpc:getState");
  }

  Future<Map<String, dynamic>> cancelTask() async {
    _ensureRunning();
    return _transport!.request("rpc:cancelTask");
  }

  /// Subscribe to child->parent notifications (evt:*, err:uncaught, etc).
  void onNotification(void Function(JsonRpcMessage) handler) {
    _ensureRunning();
    _transport!.onNotification(handler);
  }

  /// Handle reverse-RPC requests from the child (rpc:invokeSsh, etc).
  /// The handler MUST call [respond] for each request.
  void onRequest(void Function(JsonRpcMessage) handler) {
    _ensureRunning();
    _transport!.onRequest(handler);
  }

  /// Send a notification to the child (no response expected).
  void notify(String method, {Map<String, dynamic>? params}) {
    _ensureRunning();
    _transport!.notify(method, params: params);
  }

  void _ensureRunning() {
    if (_transport == null || _process == null) {
      throw StateError("AgentBridge not started");
    }
  }

  /// Kill the subprocess and close the transport.
  Future<void> dispose() async {
    final t = _transport;
    _transport = null;
    _process = null;
    if (t != null) await t.close();
  }
}