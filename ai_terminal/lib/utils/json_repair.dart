import 'dart:convert';

/// JSON 容错解析工具
///
/// AI 输出经常包含不规范 JSON：
/// - 包裹在 markdown 代码块 ```json ... ``` 中
/// - 前后带说明文字（"以下是命令：{...}"）
/// - 尾随逗号 `{"a": 1,}`
/// - 单引号 `{'a': 'b'}`
/// - 注释 `{"a": 1 // comment\n}`
/// - 未转义换行（多行字符串）
/// - 多个 JSON 对象并列
///
/// 本工具按优先级尝试多种修复策略，最大限度从 AI 输出中提取有效 JSON。
class JsonRepair {
  /// 从任意文本中提取并解析第一个有效 JSON 对象/数组
  ///
  /// [text] 原始文本（可能含 markdown、说明文字等）
  /// 返回解析后的 Map 或 List，失败返回 null
  static Object? extractAndDecode(String text) {
    if (text.isEmpty) return null;

    // 策略 1：直接解析（最理想情况）
    final direct = _tryDecode(text.trim());
    if (direct != null) return direct;

    // 策略 2：从 markdown 代码块提取
    final fromCodeBlock = _extractFromCodeBlock(text);
    if (fromCodeBlock != null) {
      final decoded = _tryDecode(fromCodeBlock.trim());
      if (decoded != null) return decoded;
      // 代码块内容可能仍有问题，进入策略 3
    }

    // 策略 3：提取第一个 {...} 或 [...] 块
    final candidate = fromCodeBlock ?? _extractFirstJsonBlock(text);
    if (candidate == null) return null;

    // 策略 4：修复常见格式问题后重试
    final repaired = _repair(candidate);
    final decoded = _tryDecode(repaired);
    if (decoded != null) return decoded;

    // 策略 5：逐字段修复尝试
    final fieldRepaired = _repairFields(repaired);
    final fieldDecoded = _tryDecode(fieldRepaired);
    if (fieldDecoded != null) return fieldDecoded;

    // 策略 6：补全未闭合的括号（流式截断场景）
    final closed = _closeBrackets(fieldRepaired);
    return _tryDecode(closed);
  }

  /// 补全未闭合的括号（用于流式截断场景）
  /// 统计字符串外未配对的 {/[ 和 "/'，自动补全
  static String _closeBrackets(String json) {
    int braceDepth = 0; // {}
    int bracketDepth = 0; // []
    bool inString = false;
    bool escape = false;
    bool inSingleQuote = false;

    for (int i = 0; i < json.length; i++) {
      final ch = json[i];

      if (escape) {
        escape = false;
        continue;
      }
      if (ch == '\\' && (inString || inSingleQuote)) {
        escape = true;
        continue;
      }

      if (inString) {
        if (ch == '"') inString = false;
        continue;
      }
      if (inSingleQuote) {
        if (ch == '\'') inSingleQuote = false;
        continue;
      }

      if (ch == '"') {
        inString = true;
      } else if (ch == '\'') {
        inSingleQuote = true;
      } else if (ch == '{') {
        braceDepth++;
      } else if (ch == '}') {
        braceDepth--;
      } else if (ch == '[') {
        bracketDepth++;
      } else if (ch == ']') {
        bracketDepth--;
      }
    }

    final buffer = StringBuffer(json);

    // 如果字符串未闭合，先补 "
    if (inString) {
      buffer.write('"');
    } else if (inSingleQuote) {
      // 单引号已在 _replaceSingleQuotes 中转双引号，此处兜底
      buffer.write('"');
    }

    // 补全 ]（数组优先）
    for (int i = 0; i < bracketDepth; i++) {
      buffer.write(']');
    }
    // 补全 }
    for (int i = 0; i < braceDepth; i++) {
      buffer.write('}');
    }

    return buffer.toString();
  }

  /// 解析为 Map，失败返回 null
  static Map<String, dynamic>? extractMap(String text) {
    final result = extractAndDecode(text);
    if (result is Map<String, dynamic>) return result;
    if (result is Map) {
      return result.cast<String, dynamic>();
    }
    return null;
  }

  /// 解析为 List，失败返回 null
  static List? extractList(String text) {
    final result = extractAndDecode(text);
    return result is List ? result : null;
  }

  /// 基础 jsonDecode，捕获异常
  static Object? _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  /// 从 ```json ... ``` 或 ``` ... ``` 代码块中提取内容
  static String? _extractFromCodeBlock(String text) {
    // 匹配 ```json / ```JSON / ``` 等开头的代码块
    final codeBlockRegex = RegExp(
      r'```(?:json|JSON)?\s*\n([\s\S]*?)\n\s*```',
    );
    final match = codeBlockRegex.firstMatch(text);
    if (match != null) {
      return match.group(1);
    }

    // 没有结束 ``` 的情况（流式截断）
    final startRegex = RegExp(r'```(?:json|JSON)?\s*\n([\s\S]*)$');
    final startMatch = startRegex.firstMatch(text);
    if (startMatch != null) {
      return startMatch.group(1);
    }

    return null;
  }

  /// 提取文本中第一个完整的 {...} 或 [...] 块（基于括号配对）
  static String? _extractFirstJsonBlock(String text) {
    int? startIdx;
    int depth = 0;
    bool inString = false;
    bool escape = false;

    for (int i = 0; i < text.length; i++) {
      final ch = text[i];

      if (inString) {
        if (escape) {
          escape = false;
        } else if (ch == '\\') {
          escape = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }

      if (ch == '"') {
        inString = true;
        continue;
      }

      if (ch == '{' || ch == '[') {
        if (startIdx == null) {
          startIdx = i;
        }
        depth++;
      } else if (ch == '}' || ch == ']') {
        if (depth > 0) {
          depth--;
          if (depth == 0 && startIdx != null) {
            return text.substring(startIdx, i + 1);
          }
        }
      }
    }

    // 括号未闭合（流式截断）：返回从开始到末尾的内容
    if (startIdx != null) {
      return text.substring(startIdx);
    }
    return null;
  }

  /// 修复常见 JSON 格式问题
  static String _repair(String json) {
    var result = json;

    // 1. 移除单行注释 // ...
    result = result.replaceAll(
      RegExp(r'//.*?$', multiLine: true),
      '',
    );

    // 2. 移除多行注释 /* ... */
    result = result.replaceAll(
      RegExp(r'/\*[\s\S]*?\*/'),
      '',
    );

    // 3. 修复尾随逗号：,] 或 ,}（允许中间空白）
    // 注意：Dart 的 replaceAll 把 $1 当字面量，必须用 replaceAllMapped
    result = result.replaceAllMapped(
      RegExp(r',\s*([}\]])'),
      (m) => m.group(1)!,
    );

    // 4. 将单引号字符串转为双引号
    // 仅在不是字符串内部时替换（简化实现：只处理 key 和 value 边界的单引号）
    result = _replaceSingleQuotes(result);

    // 5. 修复未引用的 key（{key: value} → {"key": value}）
    result = _quoteUnquotedKeys(result);

    // 6. 移除 BOM 和零宽字符
    result = result.replaceAll('\uFEFF', '').replaceAll('\u200B', '');

    return result;
  }

  /// 逐字段修复（更激进的策略）
  static String _repairFields(String json) {
    var result = json;

    // 1. 修复控制字符（换行、制表符等未转义）
    // 替换为转义形式 \n
    result = result.replaceAllMapped(
      RegExp(r'[\x00-\x1f]'),
      (_) => '\\n',
    );

    // 2. 修复重复的引号
    result = result.replaceAll('""', '"');

    // 3. 修复多余的逗号
    result = result.replaceAll(RegExp(r',+'), ',');

    // 注意：不在此处修复 HTML 实体（&quot; 等）
    // JSON 字符串值中 &quot; 是合法字符，不应转换为 "
    // 如果转换为 " 会破坏 JSON 结构

    return result;
  }

  /// 将 JSON 字符串中的单引号替换为双引号
  /// 仅在 key/value 边界替换，避免破坏字符串内部的单引号
  /// 简化策略：扫描字符串外部的单引号对，整对替换为双引号
  static String _replaceSingleQuotes(String json) {
    final buffer = StringBuffer();
    bool inDoubleQuote = false;
    bool escape = false;

    for (int i = 0; i < json.length; i++) {
      final ch = json[i];

      if (escape) {
        buffer.write(ch);
        escape = false;
        continue;
      }

      if (ch == '\\' && inDoubleQuote) {
        buffer.write(ch);
        escape = true;
        continue;
      }

      if (ch == '"') {
        inDoubleQuote = !inDoubleQuote;
        buffer.write(ch);
        continue;
      }

      // 双引号字符串内部原样输出
      if (inDoubleQuote) {
        buffer.write(ch);
        continue;
      }

      // 字符串外部遇到单引号：替换为双引号
      // 风险：会破坏字符串内部的转义单引号（如 O'Brien）
      // 但 JSON 标准要求双引号，这是合理的妥协
      if (ch == '\'') {
        buffer.write('"');
        continue;
      }

      buffer.write(ch);
    }

    return buffer.toString();
  }

  /// 给未引用的 key 加双引号
  /// 例如：{key: "value"} → {"key": "value"}
  static String _quoteUnquotedKeys(String json) {
    // 匹配 { 后面的 key: 模式（key 由字母数字下划线组成）
    // 不处理字符串内部的 key
    final result = StringBuffer();
    bool inString = false;
    bool escape = false;

    for (int i = 0; i < json.length; i++) {
      final ch = json[i];

      if (escape) {
        result.write(ch);
        escape = false;
        continue;
      }

      if (ch == '\\' && inString) {
        result.write(ch);
        escape = true;
        continue;
      }

      if (ch == '"') {
        inString = !inString;
        result.write(ch);
        continue;
      }

      // 字符串外部遇到 key 模式
      if (!inString && (ch == '{' || ch == ',')) {
        // 向前看，找到下一个 ':' 之前的内容
        result.write(ch);

        // 跳过空白
        int j = i + 1;
        while (j < json.length && json[j] == ' ') {
          result.write(' ');
          j++;
        }

        if (j >= json.length) break;

        // 如果已经是双引号或单引号开头，跳过
        if (json[j] == '"' || json[j] == '\'') continue;

        // 收集 key 名（字母数字下划线）
        final keyBuffer = StringBuffer();
        while (j < json.length) {
          final c = json[j];
          final isLetterOrDigit =
              (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) || // 0-9
                  (c.codeUnitAt(0) >= 0x41 && c.codeUnitAt(0) <= 0x5A) || // A-Z
                  (c.codeUnitAt(0) >= 0x61 && c.codeUnitAt(0) <= 0x7A); // a-z
          if (c == '_' || isLetterOrDigit || c == '-' || c == '.') {
            keyBuffer.write(c);
            j++;
          } else {
            break;
          }
        }

        // 跳过空白
        int k = j;
        while (k < json.length && json[k] == ' ') {
          k++;
        }

        if (k < json.length && json[k] == ':') {
          // 确认是 key
          if (keyBuffer.isNotEmpty) {
            result.write('"');
            result.write(keyBuffer.toString());
            result.write('"');
          }
          i = j - 1; // 让循环继续处理剩余部分
        } else {
          // 不是 key，原样输出
          if (keyBuffer.isNotEmpty) {
            result.write(keyBuffer.toString());
          }
          i = j - 1;
        }
        continue;
      }

      result.write(ch);
    }

    return result.toString();
  }
}
