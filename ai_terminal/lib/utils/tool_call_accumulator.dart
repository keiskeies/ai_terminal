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
  ///
  /// 关键：arguments 必须从 JSON 转换为多行 key:value 格式，
  /// 因为 ToolArgsParser 已弃用 JSON（以 { 开头会被拒绝）。
  /// 如果 JSON 解析失败，回退到 raw arguments 作为单行（向后兼容）。
  ///
  /// 开头自带换行：OpenAI FC 协议允许 delta.content 和 delta.tool_calls 同时存在，
  /// 若 AI 先输出一段 thought 文本（如 "好的，我来执行工具"），再触发 tool_calls，
  /// 不加换行会拼成 "好的，我来执行工具动作: tool\n..."，
  /// _parseReActResponse 找不到独立的 "动作:" 行，工具调用会被忽略。
  static String toReActText(List<ToolCall> calls) {
    final buffer = StringBuffer();
    // 开头换行，保证 "动作: tool" 总是独立成行
    buffer.writeln();
    for (int i = 0; i < calls.length; i++) {
      final c = calls[i];
      if (i > 0) buffer.writeln();
      buffer.writeln('动作: tool');
      buffer.writeln('工具: ${c.name}');
      final argsText = _jsonToKeyValue(c.arguments);
      if (argsText.isEmpty) {
        // 无参数 — 写一行空的 参数: 即可
        buffer.writeln('参数:');
      } else {
        buffer.writeln('参数:');
        buffer.write(argsText);
      }
    }
    return buffer.toString().trimRight();
  }

  /// 把 JSON arguments 字符串转换为多行 key:value 格式
  /// 输入示例：'{"local":"/path","recursive":true}'
  /// 输出示例：'  local: /path\n  recursive: true\n'
  /// 解析失败时返回空字符串
  static String _jsonToKeyValue(String jsonArgs) {
    final trimmed = jsonArgs.trim();
    if (trimmed.isEmpty || trimmed == '{}') return '';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return '';
      final buffer = StringBuffer();
      for (final entry in decoded.entries) {
        final value = entry.value;
        // List 输出为逗号分隔（与 ToolArgsParser 的列表字段约定一致）
        if (value is List) {
          buffer.writeln('  ${entry.key}: ${value.join(',')}');
        } else {
          buffer.writeln('  ${entry.key}: $value');
        }
      }
      return buffer.toString();
    } catch (_) {
      // JSON 解析失败 — 尝试按 key:value 直接解析（罕见情况）
      return '';
    }
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
          // 修复失败，返回原始（由 ToolArgsParser 走多行格式）
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
