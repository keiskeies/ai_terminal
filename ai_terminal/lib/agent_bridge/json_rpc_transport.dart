// agent_bridge/json_rpc_transport.dart
// Parent-side JSONL stdio transport for the agent-core Node subprocess.
// Mirrors agent_core/src/rpc/transport.ts (child side).

import "dart:async";
import "dart:convert";
import "dart:io";

/// A single JSON-RPC message envelope.
class JsonRpcMessage {
  final String jsonrpc; // always "2.0"
  final dynamic id; // String or num, null for notifications
  final String? method;
  final Map<String, dynamic>? params;
  final Map<String, dynamic>? result;
  final Map<String, dynamic>? error;

  const JsonRpcMessage.request({
    required this.id,
    required this.method,
    this.params,
  }) : jsonrpc = "2.0", result = null, error = null;

  const JsonRpcMessage.notification({
    required this.method,
    this.params,
  }) : jsonrpc = "2.0", id = null, result = null, error = null;

  const JsonRpcMessage.response({
    required this.id,
    this.result,
    this.error,
  }) : jsonrpc = "2.0", method = null, params = null;

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{"jsonrpc": jsonrpc};
    if (id != null) m["id"] = id;
    if (method != null) m["method"] = method;
    if (params != null) m["params"] = params;
    if (result != null) m["result"] = result;
    if (error != null) m["error"] = error;
    return m;
  }

  factory JsonRpcMessage.fromJson(Map<String, dynamic> j) {
    return JsonRpcMessage.raw(
      id: j["id"],
      method: j["method"] as String?,
      params: j["params"] as Map<String, dynamic>?,
      result: j["result"] as Map<String, dynamic>?,
      error: j["error"] as Map<String, dynamic>?,
    );
  }

  const JsonRpcMessage.raw({
    required this.id,
    required this.method,
    required this.params,
    required this.result,
    required this.error,
  }) : jsonrpc = "2.0";

  bool get isRequest => method != null && id != null;
  bool get isResponse => method == null && id != null && (result != null || error != null);
  bool get isNotification => method != null && id == null;
}

/// Parent-side stdio JSONL transport to the agent-core Node subprocess.
///
/// - [writeRequest] sends a request, returns the parsed result (waits for the response).
/// - [writeNotification] fire-and-forget notification.
/// - [onNotification] / [onRequest] subscribe to child->parent messages.
class StdioParentTransport {
  final Process _process;
  final _pending = <dynamic, Completer<Map<String, dynamic>>>{};
  int _reqId = 0;
  final _notifHandlers = <void Function(JsonRpcMessage)>[];
  final _reqHandlers = <void Function(JsonRpcMessage)>[];
  bool _closed = false;

  StdioParentTransport(this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: () => _close(), onError: (Object _) => _close());
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> msg;
    try {
      msg = json.decode(line) as Map<String, dynamic>;
    } on FormatException {
      stderr.writeln("[agent-bridge] malformed JSON line: $line");
      return;
    }
    final wrapped = JsonRpcMessage.fromJson(msg);
    if (wrapped.isResponse && wrapped.id != null) {
      final c = _pending.remove(wrapped.id);
      if (c != null && !c.isCompleted) {
        if (wrapped.error != null) {
          c.completeError(RpcTransportError(
              wrapped.error!["code"] as int,
              wrapped.error!["message"] as String));
        } else {
          c.complete(wrapped.result ?? const <String, dynamic>{});
        }
      }
    } else if (wrapped.isRequest) {
      for (final h in _reqHandlers) {
        try {
          h(wrapped);
        } catch (e) {
          stderr.writeln("[agent-bridge] request handler error: $e");
        }
      }
    } else {
      for (final h in _notifHandlers) {
        try {
          h(wrapped);
        } catch (e) {
          stderr.writeln("[agent-bridge] notification handler error: $e");
        }
      }
    }
  }

  /// Send a request, await the response. Completes with the result map.
  Future<Map<String, dynamic>> request(
    String method, {
    Map<String, dynamic>? params,
  }) async {
    if (_closed) throw const RpcTransportClosed();
    final id = "req-" + (++_reqId).toString();
    final msg = JsonRpcMessage.request(id: id, method: method, params: params);
    _writeLine(msg.toJson());
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      return await completer.future;
    } catch (_) {
      _pending.remove(id);
      rethrow;
    }
  }

  /// Send a notification (no response expected).
  void notify(String method, {Map<String, dynamic>? params}) {
    if (_closed) return;
    final msg = JsonRpcMessage.notification(method: method, params: params);
    _writeLine(msg.toJson());
  }

  /// Respond to an incoming request from the child (reverse RPC).
  void respond(dynamic id, {Map<String, dynamic>? result, Map<String, dynamic>? error}) {
    if (_closed) return;
    final msg = JsonRpcMessage.response(id: id, result: result, error: error);
    _writeLine(msg.toJson());
  }

  void _writeLine(Map<String, dynamic> payload) {
    _process.stdin.add(utf8.encode(json.encode(payload) + "\n"));
  }

  void onNotification(void Function(JsonRpcMessage) handler) => _notifHandlers.add(handler);
  void onRequest(void Function(JsonRpcMessage) handler) => _reqHandlers.add(handler);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const RpcTransportClosed());
    }
    _pending.clear();
    try {
      await _process.stdin.close();
    } catch (_) {}
    try {
      _process.kill();
    } catch (_) {}
  }

  bool get isClosed => _closed;
}

/// Error thrown when the transport is closed or the subprocess exited.
class RpcTransportClosed implements Exception {
  const RpcTransportClosed();
  @override
  String toString() => "RpcTransportClosed";
}

/// Carries an RPC-level error (non-2xx style) from the child.
class RpcTransportError implements Exception {
  final int code;
  final String message;
  const RpcTransportError(this.code, this.message);
  @override
  String toString() => "RpcTransportError($code): $message";
}