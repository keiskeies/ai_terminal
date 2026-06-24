import 'dart:convert';
import '../models/agent_event.dart';

/// ReAct 格式解析器，支持标准 ReAct 和 XML tool_call 两种格式
class ReActStreamParser {
  static const _keywords = ['思考:', '思考：', '动作:', '动作：', '命令:', '命令：', '选项:', '选项：'];

  static String _stableId(AgentEventType type, String content) {
    final bytes = utf8.encode('${type.name}:$content');
    final hash = bytes.fold<int>(0, (h, b) => h * 31 + b);
    return 'evt_${hash.toRadixString(16)}';
  }

  static List<AgentEvent> parse(String fullResponse) {
    final events = <AgentEvent>[];
    _FieldType? currentField;
    final buffer = StringBuffer();
    List<String>? pendingOptions;

    void flush() {
      final value = buffer.toString().trim();
      buffer.clear();
      if (value.isEmpty && pendingOptions == null) {
        currentField = null;
        return;
      }
      switch (currentField) {
        case _FieldType.thought:
          final id = _stableId(AgentEventType.thought, value);
          events.add(AgentEvent.thought(value, id: id));
          break;
        case _FieldType.command:
          final cleaned = _cleanCommand(value);
          if (cleaned.isNotEmpty) {
            final id = _stableId(AgentEventType.command, cleaned);
            events.add(AgentEvent.command(cleaned, id: id));
          }
          break;
        case _FieldType.options:
          if (pendingOptions != null && pendingOptions!.isNotEmpty) {
            final optsStr = pendingOptions!.join('|');
            final id = _stableId(AgentEventType.ask, optsStr);
            events.add(AgentEvent.ask(null, pendingOptions, id: id));
          }
          pendingOptions = null;
          break;
        case _FieldType.text:
          if (value.isNotEmpty) {
            final id = _stableId(AgentEventType.text, value);
            events.add(AgentEvent.text(value, id: id));
          }
          break;
        case null:
          break;
      }
      currentField = null;
    }

    // 预处理：将 XML tool_call 转换为标准 ReAct 格式
    final processed = _convertXmlToolCalls(fullResponse);

    final lines = processed.split('\n');
    bool inCodeBlock = false;
    final codeBlockBuffer = StringBuffer();

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.startsWith('```')) {
        if (inCodeBlock) {
          inCodeBlock = false;
          final code = codeBlockBuffer.toString().trim();
          codeBlockBuffer.clear();
          if (code.isNotEmpty) {
            flush();
            final id = _stableId(AgentEventType.command, code);
            events.add(AgentEvent.command(code, id: id));
          }
        } else {
          flush();
          inCodeBlock = true;
          codeBlockBuffer.clear();
        }
        continue;
      }

      if (inCodeBlock) {
        codeBlockBuffer.writeln(line);
        continue;
      }

      final segments = _splitLineByKeywords(line);
      for (final seg in segments) {
        final segTrimmed = seg.trim();
        if (segTrimmed.isEmpty) continue;

        String? matchedKeyword;
        for (final kw in _keywords) {
          if (segTrimmed.startsWith(kw)) {
            matchedKeyword = kw;
            break;
          }
        }

        if (matchedKeyword != null) {
          final content = segTrimmed.substring(matchedKeyword.length).trim();
          final kwType = matchedKeyword.substring(0, matchedKeyword.length - 1);
          switch (kwType) {
            case '思考':
              flush();
              currentField = _FieldType.thought;
              if (content.isNotEmpty) buffer.writeln(content);
              break;
            case '动作':
              flush();
              break;
            case '命令':
              flush();
              currentField = _FieldType.command;
              if (content.isNotEmpty) buffer.writeln(content);
              break;
            case '选项':
              flush();
              currentField = _FieldType.options;
              pendingOptions = content.split('|').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
              break;
          }
        } else {
          if (currentField == _FieldType.thought || currentField == _FieldType.command || currentField == _FieldType.text) {
            buffer.writeln(seg);
          } else if (currentField == _FieldType.options) {
            flush();
            currentField = _FieldType.text;
            buffer.writeln(seg);
          } else {
            currentField = _FieldType.text;
            buffer.writeln(seg);
          }
        }
      }
    }

    if (inCodeBlock) {
      final code = codeBlockBuffer.toString().trim();
      if (code.isNotEmpty) {
        flush();
        final id = _stableId(AgentEventType.command, code);
        events.add(AgentEvent.command(code, id: id));
      }
    }

    flush();
    return events;
  }

  /// 将 XML tool_call 格式转换为标准 ReAct 格式
  static String _convertXmlToolCalls(String input) {
    // 匹配 <tool_call>...</tool_call> 块
    final toolCallRegex = RegExp(r'<tool_call>\s*([\s\S]*?)\s*</tool_call>', multiLine: true);
    return input.replaceAllMapped(toolCallRegex, (match) {
      final inner = match.group(1) ?? '';
      final functionMatch = RegExp(r'<function=([^>]+)>').firstMatch(inner);
      final funcName = functionMatch?.group(1) ?? '';
      
      // 提取所有参数
      final paramRegex = RegExp(r'<parameter=([^>]+)>([\s\S]*?)
        final name = m.group(1) ?? '';
        final value = m.group(2) ?? '';
        params[name] = value;
      }

      // terminal 类型的工具调用转换为命令
      if (funcName == 'terminal' || funcName == 'execute' || funcName == 'run_command') {
        final cmd = params['command'] ?? params['cmd'] ?? '';
        if (cmd.isNotEmpty) {
          return '\n动作: execute\n命令: $cmd\n';
        }
      }
      
      // 其他类型的工具调用，原样返回（作为文本显示）
      return match.group(0) ?? '';
    });
  }

  /// 将一行文本按 ReAct 关键词分割成多段
  static List<String> _splitLineByKeywords(String line) {
    final result = <String>[];
    int lastIdx = 0;
    final matches = <_KeywordMatch>[];
    for (final kw in _keywords) {
      int idx = 0;
      while (true) {
        final pos = line.indexOf(kw, idx);
        if (pos < 0) break;
        matches.add(_KeywordMatch(pos, kw));
        idx = pos + kw.length;
      }
    }
    if (matches.isEmpty) {
      result.add(line);
      return result;
    }
    matches.sort((a, b) => a.position.compareTo(b.position));
    for (final m in matches) {
      if (m.position > lastIdx) {
        result.add(line.substring(lastIdx, m.position));
      }
      lastIdx = m.position;
    }
    if (lastIdx < line.length) {
      result.add(line.substring(lastIdx));
    }
    return result;
  }

  static String _cleanCommand(String command) {
    return command
        .replaceAll(RegExp(r'^```\w*\s*\n?'), '')
        .replaceAll(RegExp(r'\n?```\s*$'), '')
        .trim();
  }
}

class _KeywordMatch {
  final int position;
  final String keyword;
  _KeywordMatch(this.position, this.keyword);
}

enum _FieldType { thought, command, options, text }
