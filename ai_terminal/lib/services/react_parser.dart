import '../core/ui_text.dart';
import '../models/agent_event.dart';
import '../models/agent_model.dart';
import '../models/plan_step.dart';
import '../utils/command_heuristics.dart';
import '../utils/react_stream_parser.dart';
import '../utils/tool_args_parser.dart';
import 'agent_logger.dart';

/// ReAct 解析器 —— 从 AI 响应中提取结构化动作。
///
/// 从 `agent_engine.dart` 抽出的纯静态解析层：不持有任何引擎实例状态，
/// 只依赖入参与外部纯函数/静态工具。命令提取复用 [ReActStreamParser]，
/// 正确处理多行 heredoc。[AgentEngine] 保留同名转发壳以兼容既有测试调用点。
class ReActParser {
  ReActParser._();

  /// ═══════════════════════════════════════════════════════
  /// 协议行取值
  /// ═══════════════════════════════════════════════════════
  /// 协议行的字段值：分隔符取 ASCII ':' 与全角 '：' 中**先出现**者（混用行
  /// 「动作: finish（原因：磁盘满）」按全角优先会切到括号里的冒号），值取首个
  /// 空白/括号前的词以容忍尾随注解。动作/工具/参数的取值共用此口径，
  /// 避免多处漂移。需要完整值（参数多行缓冲）时用 includeRestOfLine。
  /// 无分隔符返回 null。
  static String? _protocolValue(String line, {bool includeRestOfLine = false}) {
    final sep = _firstColonIndex(line);
    if (sep < 0) return null;
    final rest = line.substring(sep + 1).trim();
    if (includeRestOfLine) return rest;
    return RegExp(r'^[^\s（(【\[]+').firstMatch(rest)?.group(0) ?? '';
  }

  /// 正文里声明的动作类型（`动作: xxx` 行首次出现即定型）。
  /// 供流结束路径判断「本轮是不是 finish/ask」以剔除围栏误解析出的命令。
  static ActionType? declaredTextAction(String content) {
    for (final line in content.split('\n')) {
      final trimmedLine = line.trim();
      if (!trimmedLine.startsWith('动作:') && !trimmedLine.startsWith('动作：')) {
        continue;
      }
      final actionValue = _protocolValue(trimmedLine);
      if (actionValue == null) continue;
      switch (actionValue.toLowerCase()) {
        case 'execute':
          return ActionType.execute;
        case 'finish':
          return ActionType.finish;
        case 'ask':
          return ActionType.ask;
        case 'tool':
          return ActionType.tool;
      }
      return null;
    }
    return null;
  }

  /// 正文里是否显式声明了「动作: execute」。
  ///
  /// 只在显式声明时允许 fallback 命令提取（见 execute 分支的 R10 注释）。
  /// 与 textFromDeclaredAction 共用同一套动作行识别，避免两处口径漂移。
  static bool declaresExecuteAction(String content) {
    if (content.isEmpty) return false;
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final trimmedLine = lines[i].trim();
      if (!trimmedLine.startsWith('动作:') && !trimmedLine.startsWith('动作：')) {
        continue;
      }
      final actionValue = _protocolValue(trimmedLine);
      if (actionValue == null) continue;
      return actionValue.toLowerCase() == 'execute';
    }
    return false;
  }

  /// `动作: execute` 行之后的正文（含动作行）。
  ///
  /// 只有这一段里出现的围栏/`命令:` 才可能是本轮真正要执行的命令；
  /// 动作行之前的思考里贴的示例围栏、finish/ask 轮的文件摘录都要排除。
  /// 返回 null 表示正文里没有声明 execute 的动作行。
  static String? textFromDeclaredAction(String content) {
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final trimmedLine = lines[i].trim();
      if (!trimmedLine.startsWith('动作:') && !trimmedLine.startsWith('动作：')) {
        continue;
      }
      final actionValue = _protocolValue(trimmedLine);
      if (actionValue == null) return null;
      if (actionValue.toLowerCase() != 'execute') return null;
      return lines.sublist(i).join('\n');
    }
    return null;
  }

  /// 解析完整 ReAct 响应，提取思考/动作/命令/选项/计划/工具等结构化字段。
  static ReActStep parseReActResponse(String content,
      {List<AgentEvent>? parsedEvents}) {
    String? thought;
    ActionType? action;
    String? command;
    List<String>? options;
    List<PlanStep>? plan;

    // 使用 ReActStreamParser 统一提取命令（正确处理多行 heredoc 和代码块）。
    // 流结束路径已经解析过一次，直接复用结果；其它调用方仍走完整解析。
    final events = parsedEvents ?? ReActStreamParser.parse(content);
    for (final e in events) {
      if (e.isCommand && command == null) {
        command = e.command;
      } else if (e.type == AgentEventType.thought && thought == null) {
        thought = e.text;
      } else if (e.type == AgentEventType.ask && options == null) {
        options = e.options;
      } else if (e.isPlan && e.planSteps != null && e.planSteps!.isNotEmpty) {
        // 同一响应里出现多份计划时，最后一份是最新状态
        plan = e.planSteps;
      }
    }

    // 解析动作行（ReActStreamParser 不提取动作类型，需单独解析）
    String? toolName;
    Map<String, dynamic>? toolArgs;
    final lines = content.split('\n');
    final answer = parseAnswerBlock(lines);
    final sections = parseReportSections(lines);
    action = declaredTextAction(content);
    // 工具动作需要顺序扫描后续 `工具:` / `参数:` 行（遇到首个动作行即停）
    if (action == ActionType.tool) {
      for (var i = 0; i < lines.length; i++) {
        final trimmedLine = lines[i].trim();
        if (trimmedLine.startsWith('动作:') || trimmedLine.startsWith('动作：')) {
          final toolResult = parseToolAction(lines, i + 1);
          toolName = toolResult.$1;
          toolArgs = toolResult.$2;
          break;
        }
      }
    }

    // 有选项但忘了写动作: 说明模型想提问，按 ask 处理，别当 finish 收尾
    if (action == null && options != null && options.isNotEmpty) {
      action = ActionType.ask;
    }

    // 如果有命令但没有指定动作，默认为 execute
    if (command != null && action == null) {
      action = ActionType.execute;
    }

    // Fallback：AI 未遵循格式
    if (action == null) {
      // 空响应 → 视为 AI 还在思考，不结束任务
      if (content.trim().isEmpty) {
        return ReActStep(thought: '', action: null, rawResponse: content);
      }
      if (isTaskComplete(content)) {
        return ReActStep(
          thought: thought ?? content,
          action: ActionType.finish,
          plan: plan,
          answer: answer,
          sections: sections,
          rawResponse: content,
        );
      }
      if (command != null) {
        return ReActStep(
          thought: thought ?? '',
          action: ActionType.execute,
          command: command,
          plan: plan,
          rawResponse: content,
        );
      }
      // 有思考内容但没有命令 → 继续执行，不要结束
      if (thought != null && thought.isNotEmpty) {
        return ReActStep(
          thought: thought,
          action: null,
          plan: plan,
          rawResponse: content,
        );
      }
      // 无法识别格式 → 不结束任务，交给 _handleNoCommand 重试
      return ReActStep(
        thought: thought ?? content,
        action: null,
        plan: plan,
        rawResponse: content,
      );
    }

    return ReActStep(
      thought: thought ?? '',
      action: action,
      command: command,
      options: options,
      toolName: toolName,
      toolArgs: toolArgs,
      plan: plan,
      answer: answer,
      sections: sections,
      rawResponse: content,
    );
  }

  /// ═══════════════════════════════════════════════════════
  /// 回答块 / 操作单解析
  /// ═══════════════════════════════════════════════════════
  /// 解析 "回答:" 块 —— 面向用户的最终 Markdown 正文。
  ///
  /// 从 `回答:` 行之后收集到内容结束；遇到结构性关键词行停止。两条防误切规则：
  /// - 只认行首的协议关键词（动作/思考/计划/工具/参数 + 操作单四字段），
  ///   正文里的 `**结论**:` 这类带前缀的写法不受影响
  /// - ``` 围栏内的关键词行不触发停止，否则"回答里示范一段 ReAct 格式"会把正文截断
  static final RegExp _answerStopLine =
      RegExp(r'^(动作|思考|说明|计划|工具|参数|结论|现状|变更|建议)\s*[:：]');

  /// 操作单四段字段的行首标记（`**结论**:` 这类正文写法不算）
  static final RegExp _sectionStartLine = RegExp(r'^(结论|现状|变更|建议)\s*[:：]');

  /// 回答正文上限（R8：落库文本必须有界；超出保留头部并标注截断）
  static const _maxAnswerChars = 12000;

  static String _clipAnswerText(String text) {
    if (text.length <= _maxAnswerChars) return text;
    return '${text.substring(0, _maxAnswerChars)}\n\n${UiText.t('…（回答过长，已截断）', '…(answer truncated because it was too long)')}';
  }

  /// 首个半角/全角冒号的位置（避免为一个 indexOf 编译正则）
  static int _firstColonIndex(String text) {
    final ascii = text.indexOf(':');
    final fullWidth = text.indexOf('：');
    if (ascii < 0) return fullWidth;
    if (fullWidth < 0) return ascii;
    return ascii < fullWidth ? ascii : fullWidth;
  }

  static String? parseAnswerBlock(List<String> lines) {
    final startIdx = lines.indexWhere((l) {
      final t = l.trim();
      return t.startsWith('回答:') || t.startsWith('回答：');
    });
    if (startIdx < 0) return null;

    final first = lines[startIdx].trim();
    final sep = _firstColonIndex(first);
    final buffer = StringBuffer();
    final inline = first.substring(sep + 1).trim();
    if (inline.isNotEmpty) buffer.writeln(inline);

    var inFence = false;
    for (var i = startIdx + 1; i < lines.length; i++) {
      final raw = lines[i];
      final t = raw.trim();
      if (t.startsWith('```')) {
        inFence = !inFence;
      } else if (!inFence && _answerStopLine.hasMatch(t)) {
        break;
      }
      buffer.writeln(raw);
    }

    final text = buffer.toString().trimRight();
    return text.trim().isEmpty ? null : _clipAnswerText(text.trimRight());
  }

  /// 解析 `回答:` 之后的操作单四字段块（结论/现状/变更/建议）。
  ///
  /// 只从 `回答:` 之后找，避免把正文里恰好以这些词开头的行当成字段；
  /// ``` 围栏内的行不触发。返回 null 表示模型没写四段。
  static String? parseReportSections(List<String> lines) {
    final answerIdx = lines.indexWhere((l) {
      final t = l.trim();
      return t.startsWith('回答:') || t.startsWith('回答：');
    });
    if (answerIdx < 0) return null;

    var inFence = false;
    var start = -1;
    for (var i = answerIdx + 1; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (!inFence && _sectionStartLine.hasMatch(t)) {
        start = i;
        break;
      }
    }
    if (start < 0) return null;

    final buffer = StringBuffer();
    // inFence 在 start 处必为 false（段起点要求 !inFence），这里继续跟踪：
    // 与 parseAnswerBlock 同口径，报告段内 ``` 围栏里的协议词行不触发段边界。
    for (var i = start; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.startsWith('```')) {
        inFence = !inFence;
        buffer.writeln(lines[i]);
        continue;
      }
      if (!inFence &&
          (t.startsWith('动作:') ||
              t.startsWith('动作：') ||
              t.startsWith('思考:') ||
              t.startsWith('思考：') ||
              t.startsWith('说明:') ||
              t.startsWith('说明：') ||
              t.startsWith('回答:') ||
              t.startsWith('回答：'))) {
        break;
      }
      buffer.writeln(lines[i]);
    }
    final text = buffer.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// 动作行识别三件套的聚合入口（N1：混用冒号/带注解值的回归覆盖）。
  ///
  /// 由 AgentEngine 的同名转发壳（@visibleForTesting）暴露给测试；这里保持
  /// 普通 public，避免跨库调用 visibleForTesting 成员产生 lint。
  static ({ActionType? declared, bool executes, String? scopeText})
      declaredActionForTest(String content) => (
            declared: declaredTextAction(content),
            executes: declaresExecuteAction(content),
            scopeText: textFromDeclaredAction(content),
          );

  /// 解析 "动作: tool" 行之后的 工具: 和 参数: 行。
  /// 返回 (toolName, toolArgs)，未找到时对应字段为 null。
  static (String?, Map<String, dynamic>?) parseToolAction(
      List<String> lines, int startIndex) {
    String? toolName;
    Map<String, dynamic>? toolArgs;

    for (var j = startIndex; j < lines.length; j++) {
      final tl = lines[j];
      final tlTrim = tl.trim();
      // 遇到新的 ReAct 关键词行 → 停止收集
      // （'工具:' 不在此列，因为它是 tool 动作的必填字段）
      if (tlTrim.startsWith('思考:') ||
          tlTrim.startsWith('思考：') ||
          tlTrim.startsWith('动作:') ||
          tlTrim.startsWith('动作：') ||
          tlTrim.startsWith('命令:') ||
          tlTrim.startsWith('命令：') ||
          tlTrim.startsWith('选项:') ||
          tlTrim.startsWith('选项：') ||
          tlTrim.startsWith('观测:') ||
          tlTrim.startsWith('观测：')) {
        break;
      }
      if (tlTrim.startsWith('工具:') || tlTrim.startsWith('工具：')) {
        toolName = _protocolValue(tlTrim);
      } else if (tlTrim.startsWith('参数:') || tlTrim.startsWith('参数：')) {
        // 收集参数：参数: 行本身 + 后续所有缩进行（多行 key:value 格式）
        final argsBuffer =
            StringBuffer()..writeln(_protocolValue(tlTrim, includeRestOfLine: true) ?? '');
        // 收集后续缩进行（2 空格或 Tab 开头）
        for (var k = j + 1; k < lines.length; k++) {
          final pl = lines[k];
          if (pl.isEmpty) continue;
          // 缩进行：以空格或 Tab 开头且非空
          if (pl.startsWith(' ') || pl.startsWith('\t')) {
            argsBuffer.writeln(pl);
          } else {
            break;
          }
        }
        final parsed = ToolArgsParser.parse(
            ReActStreamParser.stripXmlToolCallResidue(argsBuffer.toString()));
        if (parsed != null) {
          toolArgs = parsed;
        } else {
          agentLogger.warn('ReAct', '工具参数解析失败, raw=$argsBuffer');
        }
        break; // 参数解析完成后停止扫描后续行
      } else if (tlTrim.isEmpty) {
        continue;
      } else {
        // 遇到非工具/参数行，停止
        break;
      }
    }
    return (toolName, toolArgs);
  }
}
