import '../core/l10n_holder.dart';
import '../core/ui_text.dart';
import '../models/agent_event.dart';
import '../models/agent_permission_mode.dart';
import '../utils/tool_args_parser.dart';
import 'agent_tool.dart';

/// 工具调用层的**无状态**部分。
///
/// 从 `AgentEngine` 抽出的第 6 个叶子模块（Step 6）。这里只放不依赖引擎
/// 实例状态的逻辑：参数解包、幻觉别名路由、展示格式化、结果截断，
/// 以及工具执行前的三道门禁。
///
/// 为什么 `_handleToolAction` 主体没搬过来：它要写 `_currentTask.status`
/// （executing/thinking）、做破坏性工具的用户确认握手（`_confirmCompleter`
/// 与危险命令、`cancelTask` 三方共享）、累计 `_toolCalls`/`_noCommandRetryCount`
/// 并按重试上限收口终态、记录工具调用与文件变更台账。
/// 这些都是引擎生命周期状态，搬走会让取消路径只 complete 引擎侧 Completer，
/// 而编排器侧的 await 永久挂起（违反 R1）。因此编排状态机留在 `AgentEngine`，
/// 这里只做「判定」和「格式化」。
class ToolArgNormalizer {
  const ToolArgNormalizer._();

  /// 老模型的兼容：早期 schema 把参数包成 `{"args": {...}}`，照做的模型仍会
  /// 这样发。只在「唯一键且是 Map」时解包，正常平铺参数不会被误伤。
  static Map<String, dynamic> unwrapNestedArgs(Map<String, dynamic> raw) {
    final nested = raw['args'];
    if (nested is Map && raw.keys.length == 1) {
      return nested.map((k, v) => MapEntry(k.toString(), v));
    }
    return raw;
  }
}

/// 工具名与注册表无关的三种「幻觉别名」形态。
enum ToolAliasKind {
  /// 不在任何别名集合里，按注册工具处理
  notAlias,

  /// 思考别名（think/thinking/reason）：只带思考参数，没有命令语义
  think,

  /// 执行别名（execute/exec/run_command/shell/bash）：应带 command 参数
  execute,

  /// 通用占位名（function_name 等）：按参数形状路由到执行或思考
  placeholder,
}

/// 别名路由结果。字段都是原样取到的文本，是否需要 trim 由调用方决定
/// （原实现里 command 只判空、thought 判 `trim().isNotEmpty`，此处保持）。
class ToolAliasRoute {
  const ToolAliasRoute._({
    required this.kind,
    this.thought = '',
    this.command = '',
  });

  final ToolAliasKind kind;

  /// 思考文本（取第一个命中的字段）
  final String thought;

  /// 待执行命令（取第一个命中的字段）
  final String command;

  bool get hasThought => thought.trim().isNotEmpty;

  bool get hasCommand => command.isNotEmpty;
}

/// 兼容占位/幻觉工具名。
///
/// 部分模型受其它 agent 框架先验影响，会调用注册表里根本不存在的
/// think / execute / function_name（OpenAI 文档里的占位名）。直接报「未知工具」
/// 只会打断任务，还让同一条响应里宣布的命令全部悬空。这里只做**分类**，
/// 具体动作（发事件、写观测、计重试）仍归引擎。
class ToolAliasRouter {
  const ToolAliasRouter._();

  /// 模型幻觉出来的"思考"工具名
  static const Set<String> thinkAliasNames = {'think', 'thinking', 'reason'};

  /// 模型幻觉出来的"执行"工具名：应带 command 参数，走命令执行链路
  static const Set<String> executeAliasNames = {
    'execute',
    'exec',
    'run_command',
    'shell',
    'bash',
  };

  /// 通用占位工具名（OpenAI 文档示例里的 function_name 之类）
  static const Set<String> placeholderToolNames = {
    'function_name',
    'call_function',
    'tool_call',
  };

  /// 思考文本的候选字段，**顺序即优先级**
  static const List<String> thoughtFields = [
    'thought',
    'thinking',
    'reasoning',
    'note',
    'content',
    'message',
  ];

  /// 命令参数的候选字段，**顺序即优先级**
  static const List<String> commandFields = [
    'command',
    'cmd',
    'script',
    'shell',
    'shell_command',
  ];

  static ToolAliasRoute resolve(String toolName, ToolArgs args) {
    final alias = toolName.toLowerCase();
    if (thinkAliasNames.contains(alias)) {
      return ToolAliasRoute._(
        kind: ToolAliasKind.think,
        thought: args.firstOf(thoughtFields),
      );
    }
    if (executeAliasNames.contains(alias)) {
      return ToolAliasRoute._(
        kind: ToolAliasKind.execute,
        command: args.firstOf(commandFields),
      );
    }
    if (placeholderToolNames.contains(alias)) {
      return ToolAliasRoute._(
        kind: ToolAliasKind.placeholder,
        command: args.firstOf(commandFields),
        thought: args.firstOf(thoughtFields),
      );
    }
    return const ToolAliasRoute._(kind: ToolAliasKind.notAlias);
  }
}

/// 把工具参数格式化为展示用文本（多行 key:value，与 ReAct 调用格式一致）。
///
/// 用于 `AgentEvent.result.command` 与 `ReActObservation.command`：避免 AI 从
/// 观测/事件里看到 JSON 格式而被"带偏"。
class ToolDisplayFormatter {
  const ToolDisplayFormatter._();

  static String describe(
    String toolName,
    ToolArgs args, {
    int maxValueChars = 0,
  }) {
    if (args.isEmpty) {
      return toolName;
    }
    final buffer = StringBuffer()..writeln(toolName);
    for (final entry in args.asMap.entries) {
      final v = entry.value;
      final raw = v is List ? v.join(',') : '$v';
      // UI 展示时截断大参数（如 file_write 的 base64 内容），避免证据层被塞爆
      final display = maxValueChars > 0 && raw.length > maxValueChars
          ? '${raw.substring(0, maxValueChars)}… (${raw.length} 字符)'
          : raw;
      buffer.writeln('  ${entry.key}: $display');
    }
    return buffer.toString().trimRight();
  }
}

/// 工具结果在事件里的呈现形态。
class ToolResultView {
  const ToolResultView({
    required this.text,
    required this.displayed,
    required this.truncated,
    required this.totalChars,
  });

  /// 未截断的原始文本（成功取 output，失败优先取 error）
  final String text;

  /// 实际写进事件 / 观测的文本（已截断并带提示）
  final String displayed;

  final bool truncated;
  final int totalChars;
}

/// 工具结果截断与字段派生。
///
/// 阈值与原实现一致（8000 字符）：证据层要有足够上下文，但不能让
/// file_write 的大内容把 UI 与历史撑爆。
class ToolResultPresenter {
  const ToolResultPresenter._();

  static const int maxEventChars = 8000;

  static ToolResultView fromResult(ToolResult result) {
    final text =
        result.success ? result.output : (result.error ?? result.output);
    final truncated = text.length > maxEventChars;
    final displayed =
        truncated ? '${text.substring(0, maxEventChars)}\n...(输出已截断)' : text;
    return ToolResultView(
      text: text,
      displayed: displayed,
      truncated: truncated,
      totalChars: text.length,
    );
  }

  /// 异常路径：异常文本不截断（原实现 `outputTruncated: false`）
  static ToolResultView fromError(Object error) {
    final text = error.toString();
    return ToolResultView(
      text: text,
      displayed: text,
      truncated: false,
      totalChars: text.length,
    );
  }
}

/// 工具门禁的三种拦截原因。
enum ToolGateReason {
  /// 工具名不在注册表里（含模型从历史里学到的旧工具名）
  unknownTool,

  /// 只读档拦截：会产生变更的工具一律不执行
  readOnlyBlocked,

  /// 作用域外：工具已注册，但当前会话不该看到它
  outOfScope,
}

/// 工具门禁拦截结果。
///
/// [notice] 是构造好的 UI 事件（多语言）；[observation] 是回传模型的规范中文串
/// —— 观测会原样进上下文，不随 UI 语言漂移。
class ToolBlock {
  const ToolBlock({
    required this.reason,
    required this.notice,
    required this.observation,
    required this.logMessage,
    required this.isWarning,
  });

  final ToolGateReason reason;
  final AgentEvent notice;
  final String observation;

  /// 引擎按 'ReAct' tag 落日志用的文案
  final String logMessage;

  /// 原实现对未知/作用域用 warn、对只读档用 info
  final bool isWarning;
}

/// 工具执行前的三道门禁，**顺序不可变**。
///
/// 顺序即语义：未注册必须先判（否则拿不到 tool 对象就无从判断只读）；
/// 只读档早于作用域，保证只读会话里不会因为作用域差异先给出"不可用"
/// 这种误导性观测。
class ToolGate {
  const ToolGate._();

  static const String readOnlyObservation = '观测: 当前为只读模式，禁止调用会产生变更的工具。'
      '请改用只读工具/命令收集信息，或用 finish 告知用户"当前为只读模式，请关闭后重试"。';

  /// 返回 null 表示放行。
  ///
  /// 可用工具名单用惰性 getter 传入：原实现在未知/作用域两个分支才遍历注册表，
  /// 正常工具调用一步都不构建这两个列表（工具数 × 步数的无谓开销）。
  static ToolBlock? evaluate({
    required String toolName,
    required AgentTool? tool,
    required AgentPermissionMode permissionMode,
    required List<String> Function() allToolNames,
    required List<String> Function() visibleToolNames,
    required bool isLocalSession,
  }) {
    if (tool == null) {
      final available = allToolNames().join(', ');
      return ToolBlock(
        reason: ToolGateReason.unknownTool,
        notice: AgentEvent.info(L10n.str.ut_0eed0d18c7(toolName)),
        observation: '观测: 工具 $toolName 不存在。可用工具: $available',
        logMessage: '未知工具: $toolName',
        isWarning: true,
      );
    }

    // 只读档过去只拦 shell 命令，工具路径可以绕过它改文件（设计稿 D3）。
    // 判据由 ToolKind 派生，新增写类工具自动受管，不需要再维护第二份名单。
    if (permissionMode == AgentPermissionMode.readOnly && !tool.isReadOnly) {
      return ToolBlock(
        reason: ToolGateReason.readOnlyBlocked,
        notice: AgentEvent.info(L10n.str.ut_21239ba62c(toolName)),
        observation: readOnlyObservation,
        logMessage: '只读模式拦截工具: $toolName',
        isWarning: false,
      );
    }

    // 作用域守卫：工具已注册但当前会话不该看到它（如 SSH 会话里调 project_analyze）。
    // 提示词已按作用域过滤，这里是兜底 —— AI 可能从历史对话里学到上一会话的工具名。
    final visible = visibleToolNames();
    if (!visible.contains(toolName)) {
      return ToolBlock(
        reason: ToolGateReason.outOfScope,
        notice: AgentEvent.info(L10n.str.ut_339abc33a7(toolName)),
        observation: '观测: 工具 $toolName 在当前会话不可用。当前可用工具: '
            '${visible.join(', ')}',
        logMessage: '工具在当前会话不可用: $toolName (local=$isLocalSession)',
        isWarning: true,
      );
    }

    return null;
  }
}

/// 破坏性工具被拒绝（或确认超时）时的统一文案。
///
/// 拒绝与超时必须区分：10 分钟没人点不等于用户说了"不"，超时时模型可以
/// 重申一次，明确拒绝时则不该重复尝试。
class ToolConfirmation {
  const ToolConfirmation._();

  static String reason(bool timedOut) =>
      timedOut ? '确认超时（10 分钟无响应），已自动拒绝' : '用户拒绝执行该操作';

  static AgentEvent notice(bool timedOut) => AgentEvent.info(timedOut
      ? '⏱ ${UiText.t('确认超时（10 分钟无响应），已自动拒绝', 'Confirmation timed out (no response for 10 minutes); auto-rejected')}'
      : '❌ ${UiText.t('用户拒绝执行该操作', 'User declined to run this operation')}');

  static String observation(bool timedOut) {
    final reasonText = reason(timedOut);
    final hint = timedOut
        ? '用户可能只是暂时离开，可以重申一次或改用更保守的方案。'
        : '请用 ask 询问用户希望如何进行，或用 finish 结束任务，不要重复尝试。';
    return '观测: $reasonText。$hint';
  }
}
