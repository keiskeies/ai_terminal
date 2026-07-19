import 'dart:convert';

/// P2-6: 累积 OpenAI 流式响应中的 tool_calls
///
/// OpenAI function calling 在流式响应中以增量方式投递 tool_calls：
/// 首个 chunk 包含 id 和 function.name，后续 chunk 仅包含 function.arguments 的增量。
/// 同一个 tool_call 的 arguments 需要按 index 累积拼接。
///
/// 用法：
///   final acc = ToolCallAccumulator();
///   for (final delta in deltas) acc.addDelta(delta);
///   final calls = acc.finalize();  // 流结束时调用
///   if (calls.isNotEmpty) {
///     final reactText = ToolCallAccumulator.toReActText(calls);
///     // 投递到 stream
///   }
class ToolCallAccumulator {
  /// index -> {id, name, arguments}
  final Map<int, _PartialToolCall> _partials = {};

  /// 处理 delta.tool_calls（每个 chunk 的 delta 数组）
  void addDelta(List<dynamic>? toolCallsDelta) {
    if (toolCallsDelta == null) return;
    for (final raw in toolCallsDelta) {
      if (raw is! Map) continue;
      final index = raw['index'] as int?;
      if (index == null) continue;
      final partial = _partials.putIfAbsent(index, () => _PartialToolCall());
      final id = raw['id'] as String?;
      if (id != null && id.isNotEmpty) partial.id = id;
      final function = raw['function'] as Map?;
      if (function != null) {
        final name = function['name'] as String?;
        if (name != null && name.isNotEmpty) partial.name = name;
        final args = function['arguments'] as String?;
        if (args != null && args.isNotEmpty) {
          partial.arguments.write(args);
        }
      }
    }
  }

  /// 流结束时返回所有累积完成的 tool_calls。
  /// 只返回有 name 的（无 name 视为不完整，丢弃）。
  List<ToolCall> finalize() {
    final result = <ToolCall>[];
    final indices = _partials.keys.toList()..sort();
    for (final idx in indices) {
      final p = _partials[idx]!;
      if (p.name == null) continue;
      result.add(ToolCall(
        id: p.id ?? 'call_$idx',
        name: p.name!,
        arguments: _repairArguments(p.arguments.toString()),
      ));
    }
    // P2-6 修复：清理 _partials，防止 finish_reason='tool_calls' 和 [DONE]
    // 都到达时重复投递 ReAct 文本（finalize 被调用两次会返回相同结果）
    _partials.clear();
    return result;
  }

  /// 将 tool_calls 转换为 ReAct 文本格式（多个 tool_call 之间用空行分隔）
  /// AgentEngine 的 _parseReActResponse 会识别此格式并路由到 ActionType.tool
  static String toReActText(List<ToolCall> calls) {
    final buffer = StringBuffer();
    for (int i = 0; i < calls.length; i++) {
      final c = calls[i];
      if (i > 0) buffer.writeln();
      buffer.writeln('动作: tool');
      buffer.writeln('工具: ${c.name}');
      // arguments 应为 JSON 字符串；若为空则用 {}
      final args = c.arguments.trim().isEmpty ? '{}' : c.arguments.trim();
      buffer.writeln('参数: $args');
    }
    return buffer.toString().trimRight();
  }

  /// 工具调用 JSON 校验：若 arguments 不是合法 JSON，尝试修复
  /// （OpenAI 流式拼接有时会丢失尾部 } ）
  static String _repairArguments(String args) {
    if (args.isEmpty) return '{}';
    try {
      jsonDecode(args);
      return args;
    } catch (_) {
      // 简单修复：补全尾部 }
      final openCount = '{'.allMatches(args).length;
      final closeCount = '}'.allMatches(args).length;
      if (openCount > closeCount) {
        final repaired = '$args${'}' * (openCount - closeCount)}';
        try {
          jsonDecode(repaired);
          return repaired;
        } catch (_) {
          // 修复失败，返回原始（JsonRepair 会兜底）
        }
      }
      return args;
    }
  }

  bool get hasPendingCalls => _partials.isNotEmpty;
}

class _PartialToolCall {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}

class ToolCall {
  final String id;
  final String name;
  final String arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  @override
  String toString() => 'ToolCall(id=$id, name=$name, args=$arguments)';
}
