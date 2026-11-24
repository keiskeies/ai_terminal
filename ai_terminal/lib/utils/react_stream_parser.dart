import 'dart:convert';
import '../models/agent_event.dart';
import '../models/plan_step.dart';
import 'shell_syntax.dart';

/// ReAct 格式解析器，支持标准 ReAct 和 XML tool_call 两种格式
class ReActStreamParser {
  static const _keywords = [
    '思考:', '思考：',
    '计划:', '计划：',
    '说明:', '说明：',
    '动作:', '动作：',
    '命令:', '命令：',
    '选项:', '选项：',
    // 工具调用协议行与最终回答块必须被识别，否则会掉进"未知行 → text"分支，
    // 把协议原文当成正文再显示一遍
    '工具:', '工具：',
    '参数:', '参数：',
    '回答:', '回答：',
  ];

  static final RegExp _xmlFencedPattern = RegExp(
      r'---\s*\n<function=(\w+)>\s*\n<parameter=command>([\s\S]*?)</parameter>\s*\n</function>\s*\n---');
  static final RegExp _xmlBarePattern = RegExp(
      r'<function=(\w+)>\s*\n<parameter=command>([\s\S]*?)</parameter>\s*\n</function>');
  static final RegExp _residualSeparator = RegExp(r'^---\s*$', multiLine: true);
  static final RegExp _codeFencePrefix = RegExp(r'^```\w*\s*\n?');
  static final RegExp _codeFenceSuffix = RegExp(r'\n?```\s*$');
  static final RegExp _planBullet = RegExp(r'^(?:[-*•]|\d+[.)、])\s+');
  static final RegExp _planStatusBox =
      RegExp(r'^[\[【(（]\s*([^\]】)）]+)\s*[\]】)）]\s*');
  static final RegExp _planTitlePrefix = RegExp(r'^[-–—:：]\s*');
  static final RegExp _protocolExampleLine =
      RegExp(r'^(?:思考|计划|说明|动作|命令|选项|工具|参数|回答)\s*[:：]');

  static String stableId(AgentEventType type, String content) {
    final bytes = utf8.encode('${type.name}:$content');
    // FNV-1a 64-bit hash — collision resistance far superior to h*31+b (int32)
    int hash = 0xcbf29ce484222325;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return 'evt_${hash.toRadixString(16)}';
  }

  static List<AgentEvent> parse(String fullResponse) =>
      parseWithState(fullResponse).events;

  /// [openCommand] 为 true 表示最后一个 command 事件可能仍在流式增长
  /// （命令字段或代码围栏尚未遇到下一个协议行/闭合围栏），调用方不得提前执行。
  static ({List<AgentEvent> events, bool openCommand}) parseWithState(
      String fullResponse) {
    final events = <AgentEvent>[];
    var content = fullResponse;

    // 预处理：将 XML tool_call 格式转换为标准 ReAct 格式
    // 匹配 ---\n<function=...>\n<parameter=command>...</parameter>\n</function>\n--- 格式
    content = content.replaceAllMapped(
      _xmlFencedPattern,
      (match) {
        final funcName = match.group(1)!;
        final commandValue = match.group(2)!.trim();
        if (['terminal', 'execute', 'run_command'].contains(funcName)) {
          return '动作: execute\n命令: $commandValue';
        }
        return commandValue;
      },
    );

    // 处理没有 --- 分隔符的 XML tool_call 格式
    content = content.replaceAllMapped(
      _xmlBarePattern,
      (match) {
        final funcName = match.group(1)!;
        final commandValue = match.group(2)!.trim();
        if (['terminal', 'execute', 'run_command'].contains(funcName)) {
          return '动作: execute\n命令: $commandValue';
        }
        return commandValue;
      },
    );

    // 清理残留的 --- 分隔符（仅当其单独成行时）
    content = content.replaceAll(_residualSeparator, '');

    _FieldType? currentField;
    final buffer = StringBuffer();
    List<String>? pendingOptions;
    // 协议把提问文字写在"思考:"里（见 prompts.dart 的 ask 说明），"选项:"行只有按钮文字。
    // 记住最近一次 flush 的思考内容，作为紧随其后的 ask 事件的提问；
    // 正文(text)不候选，因为它已作为 Markdown 渲染在卡片上方，重复显示反而嘈杂。
    String? lastQuestion;
    // “说明:”是命令自带的解释，跟着下一条命令一起下发；命令消费后立即清空，
    // 避免在没有命令的步骤后串到下一条命令上。
    String? pendingDescription;

    void flush() {
      final value = buffer.toString().trim();
      buffer.clear();
      if (value.isEmpty && pendingOptions == null) {
        currentField = null;
        return;
      }
      switch (currentField) {
        case _FieldType.thought:
          final id = stableId(AgentEventType.thought, value);
          events.add(AgentEvent.thought(value, id: id));
          if (value.isNotEmpty) lastQuestion = value;
          pendingDescription = null;
          break;
        case _FieldType.description:
          if (value.isNotEmpty) pendingDescription = value;
          break;
        case _FieldType.command:
          final cleaned = _cleanCommand(value);
          if (cleaned.isNotEmpty) {
            final id = stableId(AgentEventType.command, cleaned);
            events.add(AgentEvent.command(cleaned,
                id: id, description: pendingDescription));
            pendingDescription = null;
          }
          break;
        case _FieldType.options:
          if (pendingOptions != null && pendingOptions!.isNotEmpty) {
            final optsStr = pendingOptions!.join('|');
            final id = stableId(AgentEventType.ask, optsStr);
            events.add(AgentEvent.ask(lastQuestion, pendingOptions, id: id));
          }
          pendingOptions = null;
          lastQuestion = null;
          pendingDescription = null;
          break;
        case _FieldType.plan:
          final steps = _parsePlanSteps(value);
          if (steps.isNotEmpty) {
            final key =
                steps.map((s) => '${s.status.name}:${s.title}').join('|');
            final id = stableId(AgentEventType.plan, key);
            events.add(AgentEvent.plan(steps, id: id));
          }
          break;
        case _FieldType.text:
          if (value.isNotEmpty) {
            final id = stableId(AgentEventType.text, value);
            events.add(AgentEvent.text(value, id: id));
          }
          pendingDescription = null;
          break;
        case _FieldType.toolProtocol:
          // 工具调用协议行由引擎的 command 事件表达，这里不产出可见事件
          pendingDescription = null;
          break;
        case _FieldType.answer:
          // 回答正文由引擎写进操作单结论层（OperationReport.answerBody），
          // 不再作为思考行进入过程时间线；紧随其后的四段字段由
          // AgentEngine.parseReportSections 单独解析，也不该混进思考。
          pendingDescription = null;
          break;
        case null:
          break;
      }
      currentField = null;
    }

    var fenceIsCommandContent = false;
    void emitFencedContent(String code) {
      if (code.isEmpty) return;
      final isExample = !fenceIsCommandContent &&
          (code
                  .split('\n')
                  .any((line) => _protocolExampleLine.hasMatch(line.trim())) ||
              code.contains('<function=') ||
              code.contains('</tool_call>'));
      if (isExample) {
        final id = stableId(AgentEventType.text, code);
        events.add(AgentEvent.text(code, id: id));
      } else {
        final id = stableId(AgentEventType.command, code);
        events.add(
            AgentEvent.command(code, id: id, description: pendingDescription));
      }
      pendingDescription = null;
    }

    final lines = content.split('\n');
    bool inCodeBlock = false;
    final codeBlockBuffer = StringBuffer();
    // heredoc 保护（设计 §6.1）：命令字段行含 <<定界符 后，直到某行精确等于
    // 定界符为止，所有行不做关键词切分、整行并入命令 buffer——
    // 防止 heredoc 正文里的 命令:/说明: 行被当协议行切走、截断命令。
    // 队列支持同一行多个 heredoc；起始识别复用 ShellSyntax 的词法层，
    // 引号/注释/算术移位里的伪 heredoc 不启动保护。
    final heredocQueue = <({String tag, bool stripTabs})>[];
    ShellHeredocScanner? heredocScanner;
    final commandQuotes = _CommandQuoteState();

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      if (heredocQueue.isNotEmpty) {
        // heredoc 内容期：整行（含定界符行本身）原样并入命令 buffer
        buffer.writeln(line);
        final current = heredocQueue.first;
        if (ShellSyntax.isHeredocTerminator(line, current.tag,
            stripTabs: current.stripTabs)) {
          heredocQueue.removeAt(0);
        }
        continue;
      }

      if (trimmed.startsWith('```')) {
        if (inCodeBlock) {
          inCodeBlock = false;
          final code = codeBlockBuffer.toString().trim();
          codeBlockBuffer.clear();
          if (code.isNotEmpty) {
            flush();
            emitFencedContent(code);
          }
        } else {
          fenceIsCommandContent = currentField == _FieldType.command;
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

      // 命令字段是 shell 原文：非行首关键词即使前面有空格或位于 # 注释里，
      // 也不能切出新协议字段。跨行引号未闭合时，行首协议词也仍是 shell 原文。
      final wasCommandField = currentField == _FieldType.command;
      final commandQuoted = commandQuotes.isQuoted;
      final commandCommented = commandQuotes.isCommentContinuation;
      if (wasCommandField && (commandQuoted || commandCommented)) {
        buffer.writeln(line);
        commandQuotes.appendLine(line);
        continue;
      }
      final segments = _splitLineByKeywords(
        line,
        commandField: wasCommandField && !commandQuoted,
      );
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
            case '计划':
              flush();
              currentField = _FieldType.plan;
              if (content.isNotEmpty) buffer.writeln(content);
              break;
            case '说明':
              flush();
              currentField = _FieldType.description;
              if (content.isNotEmpty) buffer.writeln(content);
              break;
            case '动作':
              flush();
              break;
            case '命令':
              flush();
              currentField = _FieldType.command;
              heredocScanner = ShellHeredocScanner();
              if (content.isNotEmpty) buffer.writeln(content);
              break;
            case '选项':
              flush();
              currentField = _FieldType.options;
              pendingOptions = content
                  .split('|')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList();
              break;
            case '回答':
              // 回答正文不是过程事件：引擎在 finish 时把它作为操作单正文展示。
              // 这里只吞掉 buffer，避免同一段正文在时间线里再出现一次。
              flush();
              currentField = _FieldType.answer;
              if (content.isNotEmpty) buffer.writeln(content);
              break;
            case '工具':
            case '参数':
              // 工具调用的协议行。引擎会为这次调用发一条带参数的 command 事件，
              // 所以这里必须吞掉，否则 "工具: x / 参数: / k: v" 会被当成正文再显示一遍。
              flush();
              currentField = _FieldType.toolProtocol;
              break;
          }
        } else if (currentField == _FieldType.toolProtocol) {
          final indented = seg.isNotEmpty && (seg[0] == ' ' || seg[0] == '\t');
          if (indented || seg.trim().isEmpty) {
            // 缩进行是参数值，吞掉
            buffer.writeln(seg);
          } else {
            // 顶格行说明协议块结束，后面按思考处理，
            // 保证紧跟其后的 结论:/现状:/变更:/建议: 仍能进 thought 供操作单解析
            flush();
            currentField = _FieldType.thought;
            buffer.writeln(seg);
          }
        } else {
          if (currentField == _FieldType.thought ||
              currentField == _FieldType.command ||
              currentField == _FieldType.description ||
              currentField == _FieldType.text ||
              currentField == _FieldType.answer ||
              currentField == _FieldType.plan) {
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

      final firstContentIndex = line.length - line.trimLeft().length;
      final logicalLine = firstContentIndex < line.length
          ? line.substring(firstContentIndex)
          : '';
      final startsCommand =
          logicalLine.startsWith('命令:') || logicalLine.startsWith('命令：');
      final startsProtocol = _keywords.any(logicalLine.startsWith);
      if (commandQuoted ||
          commandCommented ||
          startsCommand ||
          (wasCommandField && !startsProtocol)) {
        commandQuotes.appendLine(line);
      }

      // 处于命令字段时登记本行合法 heredoc 起始；多 heredoc 按 POSIX 顺序入队
      if (currentField == _FieldType.command) {
        heredocScanner ??= ShellHeredocScanner();
        final tags = ShellSyntax.heredocTagsOnLine(line, heredocScanner);
        if (tags.isNotEmpty) heredocQueue.addAll(tags);
      }
    }

    final openCodeBlockAtEnd = inCodeBlock;
    final commandFieldAtEnd = currentField == _FieldType.command;
    if (inCodeBlock) {
      final code = codeBlockBuffer.toString().trim();
      if (code.isNotEmpty) {
        flush();
        emitFencedContent(code);
      }
    }

    flush();
    final openCommand = events.isNotEmpty &&
        events.last.isCommand &&
        (openCodeBlockAtEnd || commandFieldAtEnd);
    return (events: events, openCommand: openCommand);
  }

  /// 将一行文本按 ReAct 关键词分割成多段。
  ///
  /// 普通协议行保留空白前缀的行内切分；命令字段只认行首字段边界，且从首个
  /// `命令:` 起右侧全部是 shell 原文，避免 `# 命令:` 注释被再次切段执行。
  static List<String> _splitLineByKeywords(
    String line, {
    required bool commandField,
  }) {
    final result = <String>[];
    int lastIdx = 0;
    final matches = <_KeywordMatch>[];
    final firstContentIndex = line.length - line.trimLeft().length;
    for (final kw in _keywords) {
      int idx = 0;
      while (true) {
        final pos = line.indexOf(kw, idx);
        if (pos < 0) break;
        // 行内（position>0）命中仅当前一字符为空白/Tab 才是字段边界：
        // echo "命令: x" 的引号前缀不是边界，思考: a 动作: execute 的空格前缀才是。
        // 行首命中不受限。
        if (pos == 0 || line[pos - 1] == ' ' || line[pos - 1] == '\t') {
          matches.add(_KeywordMatch(pos, kw));
        }
        idx = pos + kw.length;
      }
    }
    if (matches.isEmpty) {
      result.add(line);
      return result;
    }
    matches.sort((a, b) => a.position.compareTo(b.position));
    if (commandField) {
      final first = matches.first;
      if (first.position != firstContentIndex) return [line];
      matches.removeRange(1, matches.length);
    } else {
      final firstCommand =
          matches.indexWhere((m) => m.keyword == '命令:' || m.keyword == '命令：');
      if (firstCommand >= 0) {
        matches.removeRange(firstCommand + 1, matches.length);
      }
    }
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
    return stripXmlToolCallResidue(command)
        .replaceAll(_codeFencePrefix, '')
        .replaceAll(_codeFenceSuffix, '')
        .trim();
  }

  /// 剥离混入命令里的 XML 工具调用残留标签。
  ///
  /// 模型受其它 agent 框架先验影响时，会在文本协议里吐孤立的 `</parameter>`、
  /// `</function>`（没有配套的 `<function=`），上面的两个成对正则都匹配不到，
  /// 脏标签会漏进 `命令:` 被原样执行 —— PowerShell 报
  /// `'<' 不是可识别的 cmdlet`。它与 FC 路径的
  /// `ToolCallAccumulator._stripXmlToolCallResidue` 是同一类污染的两条入口。
  static final RegExp _xmlResidueTail = RegExp(
    r'\n\s*</\s*(?:parameter|function|antml:parameter|antml:invoke)\s*>',
    caseSensitive: false,
  );
  static final RegExp _xmlResidueAny = RegExp(
    r'</\s*(?:parameter|function|antml:parameter|antml:invoke)\s*>',
    caseSensitive: false,
  );

  static String stripXmlToolCallResidue(String command) {
    if (!command.contains('<')) return command;
    return command
        .replaceAll(_xmlResidueTail, '')
        .replaceAll(_xmlResidueAny, '');
  }

  /// 解析计划块：
  /// - [ ] 待处理 / [>] 进行中 / [x] 完成 / [!] 失败 / [-] 跳过
  /// 也接受【进行中】、[已完成] 等中文标记。只接受列表行，避免把散文当步骤。
  static List<PlanStep> _parsePlanSteps(String block) {
    final steps = <PlanStep>[];
    for (final rawLine in block.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('```')) continue;

      final bullet = _planBullet.firstMatch(line);
      var rest = bullet == null ? line : line.substring(bullet.end);
      PlanStepStatus status = PlanStepStatus.pending;
      String title = rest;

      final box = _planStatusBox.firstMatch(rest);
      if (box != null) {
        status = _parsePlanMarker(box.group(1)!);
        title = rest.substring(box.end).trim();
      } else if (bullet == null) {
        // 没有列表标记也没有状态框 → 视为说明文字，不当作步骤
        continue;
      }

      title = title.replaceFirst(_planTitlePrefix, '').trim();
      if (title.isEmpty) continue;
      steps.add(PlanStep(title: _clip(title, 160), status: status));
      if (steps.length >= 30) break;
    }
    return steps;
  }

  static PlanStepStatus _parsePlanMarker(String raw) {
    final marker = raw.trim().toLowerCase();
    switch (marker) {
      case 'x':
      case '✓':
      case '√':
      case '完成':
      case '已完成':
      case 'done':
      case 'completed':
        return PlanStepStatus.completed;
      case '>':
      case '→':
      case '进行中':
      case '当前':
      case 'doing':
      case 'current':
      case 'inprogress':
      case 'in progress':
        return PlanStepStatus.inProgress;
      case '!':
      case '失败':
      case 'failed':
        return PlanStepStatus.failed;
      case '-':
      case '跳过':
      case 'skipped':
        return PlanStepStatus.skipped;
      default:
        return PlanStepStatus.pending;
    }
  }

  static String _clip(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…';
  }
}

/// 命令字段的跨行引号/注释上下文，用于判断协议关键词是否仍处于 shell 原文内。
class _CommandQuoteState {
  bool single = false;
  bool double = false;
  bool backtick = false;
  bool _commentContinuation = false;

  bool get isQuoted => single || double || backtick;
  bool get isCommentContinuation => _commentContinuation;

  void appendLine(String line) {
    if (_commentContinuation) {
      _commentContinuation = _endsWithBackslash(line);
      return;
    }
    _commentContinuation = false;
    var escaped = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (single) {
        if (c == "'") single = false;
        continue;
      }
      if (backtick) {
        if (c == '\\') {
          escaped = true;
        } else if (c == '`') {
          backtick = false;
        }
        continue;
      }
      if (double) {
        if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          double = false;
        } else if (c == '`') {
          backtick = true;
        }
        continue;
      }
      if (c == '\\') {
        escaped = true;
      } else if (c == "'") {
        single = true;
      } else if (c == '"') {
        double = true;
      } else if (c == '`') {
        backtick = true;
      } else if (c == '#' && (i == 0 || ' \t;|&()'.contains(line[i - 1]))) {
        _commentContinuation = _endsWithBackslash(line);
        break;
      }
    }
    // POSIX 反斜杠换行会被移除，不转义下一物理行；局部 escaped 随行结束丢弃。
  }

  static bool _endsWithBackslash(String line) {
    var end = line.length;
    if (end > 0 && line[end - 1] == '\r') end--;
    return end > 0 && line[end - 1] == '\\';
  }
}

class _KeywordMatch {
  final int position;
  final String keyword;
  _KeywordMatch(this.position, this.keyword);
}

enum _FieldType {
  thought,
  description,
  command,
  options,
  text,
  plan,
  toolProtocol,
  answer,
}
