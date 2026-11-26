import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../core/ui_text.dart';
import '../models/agent_model.dart';
import '../models/agent_event.dart';
import '../models/agent_permission_mode.dart';
import '../models/operation_report.dart';
import '../models/plan_step.dart';
import '../models/change_record.dart';
import '../models/agent_memory.dart';
import '../models/chat_session.dart';
import '../models/ai_model_config.dart';
import '../models/token_usage.dart';
import '../services/ai_service.dart';
import '../services/ssh_service.dart';
import '../services/command_executor.dart';
import '../services/rules_injection.dart';
import 'agent_tool.dart';
import 'agent_host_registry.dart' as agent_host_registry;
import 'react_parser.dart';
import 'event_store.dart';
import 'history_policy.dart';
import 'prompt_builder.dart';
import 'command_runner.dart';
import 'tool_orchestrator.dart';
import 'termination_guard.dart';
import 'agent_logger.dart';
export 'agent_logger.dart';
import 'agent_tracer.dart';
import '../core/safety_guard.dart';
import '../core/permission_policy.dart';
import '../core/credentials_store.dart';
import '../core/l10n_holder.dart';
import 'daos.dart';
import 'web_search_service.dart';
import 'mcp_manager.dart';
import '../core/prompts.dart' as prompts;
import '../utils/ansi_stripper.dart';
import '../utils/command_heuristics.dart';
import '../utils/output_processor.dart';
import '../utils/tool_args_parser.dart';
import '../utils/goal_continuation.dart';
import '../utils/react_stream_parser.dart';
import '../utils/rollback_advisor.dart';
import '../utils/verification_detector.dart';
import '../utils/command_extractor.dart';
import '../utils/no_command_intent_detector.dart';
import '../utils/choice_request_detector.dart';
import '../utils/token_estimator.dart';
import '../utils/tool_call_accumulator.dart';
import '../utils/audit_logger.dart';
import '../utils/tail_text_buffer.dart';
import '../utils/shell_syntax.dart';
import 'change_record_service.dart';
import 'notification_service.dart';
import 'local_access.dart';

/// Agent 执行引擎 - 核心自动执行系统
class AgentEngine {
  final AIProvider _aiProvider;
  final AIModelConfig _modelConfig;
  final AgentMemory _memory;
  final Uuid _uuid = const Uuid();

  AgentTask? _currentTask;
  final TailTextBuffer _accumulatedMessageBuffer =
      TailTextBuffer(_maxAccumulatedChars);

  /// 跟踪累积的消息（只保留尾部，读写都走摊还 O(1) 的缓冲）
  String get _accumulatedMessage => _accumulatedMessageBuffer.tail();

  set _accumulatedMessage(String value) {
    _accumulatedMessageBuffer
      ..clear()
      ..write(value);
  }

  /// 最近一次 _callAI 结束时的解析结果，供紧随其后的 _parseReActResponse 复用，
  /// 避免同一段响应被全量解析两次。
  List<AgentEvent>? _lastParsedResponseEvents;

  /// O8 FC-first：最近一次 _callAI 收到的结构化 tool_calls。
  /// 非 FC 模型或纯文本响应时为空，主循环据此走文本解析兜底。
  List<ToolCall> _lastFcToolCalls = const [];

  /// 本轮 arguments 非法的结构化调用：不执行、不进入动作列表，只在成功收流后
  /// 回灌一条不含原始参数的观测，让模型修正后重试。
  List<ToolCall> _lastInvalidFcCalls = const [];

  /// 本条 AI 响应的解析结果里是否已带 ask 事件（主循环在解析后填入）
  bool _lastResponseHadAskEvent = false;

  /// 本条 AI 响应里宣布的、第一条之外的其余命令（主循环在解析后、清空事件
  /// 缓存前填入）。由 _executeRemainingAnnouncedCommands 消费并清空。
  List<({String eventId, String command})> _announcedFollowUps = const [];
  Completer<bool>? _confirmCompleter; // 等待用户确认危险命令的 Completer
  Timer? _confirmTimeoutTimer; // 确认超时定时器，cancelTask 时需 cancel
  /// 本轮确认是否因超时结束。超时和用户拒绝必须分开说：
  /// 把系统行为写成用户意图，用户会在历史里看到一件自己没做过的事。
  bool _confirmTimedOut = false;

  /// 本任务是否发生过确认超时。目标模式用它判断"没人看管"：
  /// 超时说明用户不在，自动续跑只会反复超时空转。
  bool _taskHadConfirmTimeout = false;

  /// 供 provider 在任务终局时读取（不重置，随任务结束一起清零）
  bool get hadConfirmTimeout => _taskHadConfirmTimeout;
  String? _pendingConfirmCommand; // 当前等待确认的命令

  /// O5: 运行中用户补充指令（steering）队列。
  /// addUserSteering 入队，主循环顶部在代际/暂停检查之后同步排空（无 await，
  /// 天然满足 R1）。等待确认/ask 期间循环阻塞在 await，补充自然留到下一轮。
  final Queue<String> _steeringQueue = Queue<String>();

  /// 单条补充指令长度上限（R8：保尾，最近的内容最重要）。
  /// provider 持久化补充消息时用同一上限，保证落库内容与注入内容一致。
  static const int maxSteeringChars = 4000;

  /// 队列条数上限（R8：防止用户连续点击导致无界增长），超出丢弃最早一条
  static const int _maxSteeringQueueLength = 20;

  /// 任务开始时间（用于计算 elapsedSeconds 进度）
  DateTime? _taskStartTime;

  /// 当前执行步数（_executeAutomatic 循环计数，供进度文本使用）
  int _currentStepCount = 0;

  // ── 本轮任务的计量（设计 §3.1.2：每个数字都必须有出处）────────────────
  // token 分两本账：provider 真给 usage 的记 real，没给的用 TokenEstimator 估。
  // 两本账必须分开——把估算混进实测数字是失准文案。
  int _tokReal = 0;
  int _tokEstimated = 0;
  int _cachedPromptReal = 0;

  /// 只有报告过 cached_tokens 的那些轮才进分母。
  /// 用「部分已知的命中」除以「全部 prompt」会得到一个偏低的假命中率，不如说未知。
  int _promptRealWithCached = 0;

  /// 本次 AI 调用是否拿到过真实 usage；末包式 provider 在流末才给，所以要按次判定
  bool _usageThisCall = false;

  /// AI 请求次数（含重试与备用模型切换）。只作为「步」的一部分，
  /// 不再直接当作「轮」显示——那会让轮看起来比步多，两个量纲被读反。
  int _aiRounds = 0;

  /// 会话累计轮次：由 provider 在启动任务时按会话算好后传入。
  /// 引擎不自行递增——续跑、用户提问都由 provider 那条统一路径计数。
  int _roundIndex = 0;

  /// 当前任务是否目标模式的续跑轮（含 /goal 首轮）。
  /// provider 的目标终局判定只认目标轮：用户提问轮收尾不触发自动续跑，
  /// 也不计入"无进展"，否则答完问题又咔咔续跑旧目标（反刍残留链路）。
  bool _currentTaskIsGoalRound = false;

  /// 当前任务是否目标续跑轮（供 provider 终局判定读取）
  bool get currentTaskIsGoalRound => _currentTaskIsGoalRound;

  /// 被拦截而未执行的命令数（安全策略 / 权限档位 / 用户拒绝 / 确认超时）
  int _blockedCount = 0;

  /// 工具调用次数（含未知工具与只读档拦截的调用）
  int _toolCalls = 0;

  /// 等待用户确认累计秒数（危险命令 + 破坏性工具两处）。tok/s 的分母要减掉它，
  /// 但耗时本身仍按墙钟显示 —— 人的反应时间不该算进引擎吞吐率。
  int _confirmWaitSeconds = 0;

  /// 最近一次发出去的 prompt 规模，用于上下文占用环
  int _contextTokens = 0;

  // 本轮内最后一次 usage 的值，供累计式 provider 覆盖重记
  int _lastRoundReal = 0;
  int? _lastRoundPrompt;
  int? _lastRoundCached;

  /// 缓存命中率 0-100。provider 从没给过 cached_tokens 时是未知（null），不是 0%
  int? get _cacheHitPercent {
    if (_promptRealWithCached <= 0) return null;
    final pct = (_cachedPromptReal * 100 / _promptRealWithCached).round();
    return pct < 0 ? 0 : (pct > 100 ? 100 : pct);
  }

  /// 暂停/恢复时的步数偏移：恢复后步数继续累计，不归零
  int _stepOffset = 0;

  /// 事件 id 分配与去重（R4：每引擎独立实例）。
  ///
  /// 序号跨 AI 轮次单调递增；轮内去重状态由 [EventScope] 隔离。
  /// 详见 event_store.dart 的注释（重复 id 会导致 Flutter 同层重复 key，
  /// 让整块提问步骤渲染失败）。
  final EventStore _eventStore = EventStore();

  /// 当前等待用户作答的 ask 事件（用于把用户的选择回写到事件上）
  AgentEvent? _pendingAskEvent;

  /// 稳定操作 id：startTask 生成，resumeTask 沿用
  String? _operationId;

  /// 每个 operation 只发一次 report
  bool _reportEmitted = false;

  /// 本操作产生的变更记录 id（按执行顺序，最多保留 100 条）
  final List<String> _operationChangeIds = [];

  /// 本操作成功的变更摘要（随 report 持久化，渲染时不再查库）
  final List<OperationChange> _operationChanges = [];

  /// 确定性验证徽标（最多 6 条）
  final List<OperationBadge> _operationBadges = [];

  /// 模型声明的执行计划（跨暂停/恢复保留）
  List<PlanStep> _currentPlan = const [];

  /// 任务代际 token：每次 startTask 递增，循环中检查此 token 是否仍为当前任务
  /// 防止取消+立即发送导致旧循环与新循环并发
  int _currentTaskGeneration = 0;

  /// 当前任务的本机能力授权；暂停、取消或完成后立即撤销。
  LocalAccessService? _localAccess;

  /// R5: 终态收口器（每引擎一个实例，严禁 static）。
  /// 延迟初始化以闭包读取当前代际；多 scope 各自独立，避免终态串台。
  late final TerminationGuard _terminationGuard = TerminationGuard(
    hostId: hostId,
    generation: () => _currentTaskGeneration,
    isTerminalAllowed: (status) =>
        status == AgentStatus.cancelled ||
        _currentTask?.status != AgentStatus.paused,
  );

  /// 等待用户选择选项的 Completer（ReAct ask 动作 / :::choose A|B|C:::）
  Completer<String>? _choiceCompleter;
  List<String> _pendingOptions = []; // 当前等待选择的选项

  /// 等待用户应答交互式确认提示（yes/no、[Y/n]、Press ENTER 等）的 Completer。
  /// 与 [_confirmCompleter] 同一套 10 分钟超时 / cancelTask 清理策略
  /// （R1：外部取消时必须手动 complete(null)，否则 await 永久挂起）。
  /// 答案是普通输入而非秘密，但同样不进对话历史/凭据库，只走事件时间线。
  Completer<String?>? _interactiveInputCompleter;
  Timer? _interactiveInputTimeoutTimer;

  /// 本轮命令里已应答的交互提示（提示文本 + 答案）。
  /// 终端会把 "提示行 + 用户输入" 回显到输出里，若不清掉，模型会把它当成
  /// 下一条命令执行（O3 真机验证：`Continue? y` 被当命令跑掉）。
  /// 只对本次命令有效：每次执行前清空，执行后用于清洗观测。
  final List<({String prompt, String answer})> _interactiveEchoes = [];

  /// 命令执行取消令牌：cancelTask 时 complete，_executeCommand 据此提前退出
  Completer<void>? _commandCancelToken;

  /// 会话级源码读取授权状态（R7 安全）
  /// 当 AI 需要读取项目源码文件（L3 级别）时，首次弹窗询问用户
  /// 用户确认后会话内有效，任务结束自动失效
  /// false = 未授权（默认），true = 已授权
  /// 当前由 system prompt 规则约束 AI 行为，未来可在 _executeCommand 中
  /// 对 cat/head/tail 等读取命令做路径校验时使用此字段
  // ignore: unused_field
  bool _sessionSourceCodeGranted = false;

  /// 编排任务的取消令牌：覆盖整个 ReAct 循环周期（比 _commandCancelToken 生命周期长）。
  /// 在 _executeAutomatic 开始时创建并注入到 MultiHostExecutor，cancelTask 时 complete。
  /// 编排工具的 executeAndWait 通过它响应取消，否则点停止后批量命令会跑到 timeout 才停。
  Completer<void>? _orchestratorCancelToken;

  /// 暴露当前编排取消令牌给调试/监控用。
  Completer<void>? get currentCancelToken =>
      _orchestratorCancelToken ?? _commandCancelToken;

  /// AI 流式订阅：cancelTask 时取消，立即停止消费旧任务流
  StreamSubscription<String>? _aiStreamSub;

  /// AI 流式超时看门狗（_callAI 内创建，cancelTask 中取消）
  Timer? _aiWatchdog;

  /// 本轮任务内「AI 流中途超时」已重试次数（上限 2，任务启动时清零）。
  /// 上限存在防抖：网络持续抖动时不能无限重试烧配额。
  int _aiStreamTimeoutRetries = 0;

  /// 丢弃半截流式响应的 UI 桥：ReAct 循环重试前调用，宿主须丢弃当前轮
  /// streamingContent（不并入 content），否则重试轮正文会接在半截 heredoc 后面。
  void Function()? onStreamDiscarded;

  /// AI 流式完成 Completer（cancelTask 可 complete 以解除 _callAI 挂起）
  Completer<void>? _aiDoneCompleter;

  /// AI HTTP 请求取消令牌（_callAI 内创建，cancelTask 中触发）
  /// 比 _aiStreamSub.cancel() 更彻底：直接关闭底层 Dio HTTP 连接
  /// 避免取消任务后 API 仍在流式输出消耗配额
  CancelToken? _aiCancelToken;

  /// 备用 AI Provider（主模型重试 maxRetries 次仍失败时切换）
  AIProvider? _fallbackProvider;
  AIModelConfig? _fallbackConfig;

  /// 持久化对话历史，跨 startTask() 调用保留上下文
  final List<ChatMessage> _conversationHistory = [];

  /// 连续无命令重试计数（防止 AI 只给解释不给命令时过早结束任务）
  int _noCommandRetryCount = 0;
  static const int _maxNoCommandRetries = 2;

  /// 本任务是否实际执行过命令/工具（防止 AI 幻觉：未执行任何命令就 finish）
  /// 在 _runCommandWithSafety 和 _handleToolAction 中置 true；
  /// finish 动作会检查此标志，未执行过则强制继续。
  bool _hasExecutedAnyCommand = false;

  /// 未执行命令就 finish 的重试计数（与 _noCommandRetryCount 分开，避免互相干扰）
  /// 场景：AI 在 ask 后声称"已检查无问题"但实际未运行任何命令
  /// 达到 _maxFinishWithoutExecRetries 后放行 finish（避免死循环）
  int _finishWithoutExecCount = 0;
  static const int _maxFinishWithoutExecRetries = 2;

  /// 预检连续拦截次数（未闭合 / 交互阻塞 / 退出码不可靠）。
  /// 前 [_maxSyntaxRejects] 次回灌修正提示，超限后改发终止性诊断。
  /// 真正通过预检的命令会归零。
  int _syntaxRejectCount = 0;
  static const int _maxSyntaxRejects = 2;

  /// 本轮是否有命令真正通过了全部守卫并进入执行器。
  /// 预检在 `_executeCommand` 内拦截，外层拿不到"是否执行过"，用这个标记补上。
  bool _commandPassedPrecheckThisTurn = false;

  /// 本轮是否有命令被预检、权限或用户拒绝（从未进入执行器）。
  bool _commandRejectedThisTurn = false;

  /// 本轮是否有命令真正执行且返回成功；只有它才能清零 blocked-turn streak。
  bool _commandSucceededThisTurn = false;

  /// 连续多少轮**没有任何命令成功推进**且至少一条命令被拒绝。maxSteps 默认 0
  /// （无限制），若只靠提示语不收尾，模型坚持提交被拦的命令会无限空烧配额。
  /// 达到 [_maxBlockedTurnsBeforeAbort] 轮直接失败收尾。
  int _blockedTurnsStreak = 0;
  static const int _maxBlockedTurnsBeforeAbort = 3;

  /// 纯问答显式声明标记：模型在 finish 的思考/正文里写明这句话，
  /// 表示本轮是基于已有上下文的问答，幻觉门控让路。
  /// 与 [_userForbadeCommands]（只由用户原文置位）不同，这是模型自声明，
  /// 提示词已把它限定在纯提问任务；操作类任务不带声明的幻觉 finish 仍被拦。
  static const String _pureQaDeclaration = '纯问答，无需执行命令';

  /// 用户是否显式要求本次任务不要执行命令（"严禁执行任何命令，只根据会话回答"）
  ///
  /// 命中时 [_finishWithoutExecCount] 门控让路：用户意图优先于反幻觉默认值，
  /// 否则纯问答任务要白烧完重试步数才能收尾。只由用户原文置位
  /// （goal / steering / ask 选项），模型自己的说法不算数。
  bool _userForbadeCommands = false;

  /// 只从用户原文吸收"禁止执行命令"约束；单向置位，同一任务内不撤销。
  /// ask 选项虽是模型写的文案，但点选动作出自用户，视为用户表态。
  void _absorbNoCommandConstraint(String userText, String source) {
    if (_userForbadeCommands) return;
    if (!NoCommandIntentDetector.detects(userText)) return;
    _userForbadeCommands = true;
    agentLogger.info(
        'ReAct',
        '检测到用户禁止执行命令（来源: $source），'
            'finish 幻觉门控让路');
  }

  /// O4/WP6: 计划含未完成项（[ ]/[>]）就 finish 的重试计数。
  /// R5: 独立计数器，与 _finishWithoutExecCount / _noCommandRetryCount 互不干扰；
  /// 达到 _maxPlanFinishRetries 后放行 finish（避免死循环），_resetTransientState 归零。
  /// 不做命令→计划项自动映射（语义匹配不可靠），模型自报 + 引擎形式校验。
  int _planFinishRetryCount = 0;
  static const int _maxPlanFinishRetries = 2;

  /// 当前任务使用的 executor 引用（startTask 时传入，可被 setExecutor 实时刷新）。
  /// 解决场景：sudo reboot / 网络抖动导致 SSH 断开后，用户手动重连 SSH 会创建
  /// 新的 SSHService 实例，但 ReAct 循环仍持有旧引用 → 连续 success=false。
  /// AgentNotifier.setExecutor 会同步刷新此字段，_executeAutomatic 循环每步取最新值。
  CommandExecutor? _currentExecutor;

  /// 当前会话是否本地终端 — 决定 local-only 工具（如 project_analyze）是否暴露给 AI
  ///
  /// 判据与 [_buildSystemPrompt] 里的本地部署分支保持一致：非 SSHService 即本地。
  bool get _isLocalSession {
    final ex = _currentExecutor;
    return ex != null && ex is! SSHService;
  }

  /// 连续连接失败计数（防止 AI 在 SSH 断开后反复尝试命令空转）
  /// 每次命令因"连接已断开"失败时递增，成功执行命令时重置
  /// 达到 [_connFailBudget] 时暂停任务并提示用户重连
  int _consecutiveConnFailures = 0;
  static const int _maxConnFailRetries = 3;

  /// 本轮允许的连续连接失败次数。默认 [_maxConnFailRetries]；
  /// 任务途中连接自愈成功一次后翻倍（见 [noteConnectionRestored]）——
  /// 自动重连已能在后台跑完 1+2+4+8+16+32s 的退避，3 次门限会在重连
  /// 还没到点前就把任务判死。没有发生过重连时维持原门限，不放宽纯离线场景。
  int _connFailBudget = _maxConnFailRetries;

  /// 重连成功后待注入的一次性提示：新会话的工作目录/环境变量/sudo 态全丢，
  /// 直接重跑上一步非幂等命令会二次生效。置位一次、消费一次。
  ///
  /// 故意不在 _resetTransientState 里清：任务因断线终止后，危险恰恰落在
  /// 用户接着发的下一条任务的第一条命令上——那条命令最容易被当成"重跑上一步"。
  bool _needsStateNote = false;

  /// _accumulatedMessage 最大字符数（防止长任务内存无界增长）
  static const int _maxAccumulatedChars = 20000;

  /// 单次模型响应上限。超限必须失败，不能截断后解析/执行半条 ReAct 或 heredoc。
  static const int _maxAiResponseChars = 256 * 1024;

  /// 本步模型推理累积上限：推理只是过程展示，超长只保留尾部
  static const int _maxReasoningChars = 4000;
  final StringBuffer _reasoningBuffer = StringBuffer();
  int _lastReasoningEmitAt = 0;

  void Function(String)? onThinking;

  /// 模型原生推理增量（reasoning_content / reasoning）；网关不给该字段时不会触发
  void Function(String text)? onReasoning;
  void Function(String)? onCommandGenerated;
  void Function(AgentResult)? onCommandExecuted;
  void Function(String)? onError;
  void Function(AgentTask)? onTaskUpdated;
  void Function(String)? onMessage;
  void Function(String)? onCompleted;

  /// 结构化事件回调（新增）：每个 ReAct 步骤的思考/命令/结果/询问/完成
  /// 通过此回调发出结构化事件，UI 可按事件类型分别渲染卡片。
  /// 保留 onMessage 用于兼容旧 UI 的纯文本流。
  void Function(AgentEvent)? onEvent;

  /// 向用户索取一个秘密（如 sudo 密码）的回调，由 AgentNotifier 注入 UI 弹窗。
  ///
  /// 返回用户输入的明文，或 null 表示取消。调用方（[requestSudoPassword]）
  /// 只把它写进安全存储与执行器，**绝不**返回给工具或写进对话历史 ——
  /// 秘密一旦进 observation 就永久留在模型上下文里（AGENTS.md R7）。
  Future<String?> Function(String title, String message)? onSecretRequest;

  /// 命令卡在**确认类**交互式提示（yes/no、[Y/n]、Press ENTER 等）时索取
  /// 自由文本输入的回调，由 AgentNotifier 注入 UI 弹窗。
  ///
  /// 返回答案字符串（空串 = 直接回车），或 null 表示取消/超时。
  /// 答案只写进终端 stdin 与事件时间线，**绝不**写进对话历史或凭据库；
  /// 密码类提示（Password:/Enter passphrase）不走此回调（AGENTS.md R7），
  /// 仍按 interactivePrompt 中断走 provide_password 流程。
  Future<String?> Function(String prompt)? onInteractiveInputRequest;

  /// 请求当前任务的本机目录权限，由 AgentNotifier 注入 UI 弹窗。
  /// 单次确认只签发任务级授权，不修改全局本地文件白名单。
  Future<bool> Function(
    String path,
    String reason,
    LocalAccessMode mode,
  )? onLocalDirRequest;

  int maxSteps = 0; // 0 = 无限制（运行时兜底为 _defaultMaxSteps）

  /// 当前引擎所属的 hostId（用于内部规范作用域匹配和多 host 隔离）
  String? hostId;

  /// 当前任务所属的会话 id（由 AgentNotifier 在任务开始/切换会话时设置）。
  /// 仅用于把日志路由到正确会话；同一服务器多 tab 并行时 hostId 会重复，
  /// 不能再用它判断日志归属。
  String? conversationId;

  /// 工具注册表 — 管理 AI 可调用的非 shell 工具（如 SFTP 上传）
  final AgentToolRegistry _tools = AgentToolRegistry();

  /// 多机编排模式开关
  bool _orchestratorMode = false;

  bool get isOrchestratorMode => _orchestratorMode;

  /// 执行权限档位：只读 / 询问 / 自动 / 全自动。
  /// 与命令自身的安全等级是两层概念，详见 docs/agent-permission-mode-design.md。
  AgentPermissionMode _permissionMode = AgentPermissionMode.ask;

  AgentPermissionMode get permissionMode => _permissionMode;

  /// 联网搜索会话级开关（与全局开关 OR 合并）
  ///
  /// 合并规则：enabled = _webSearchEnabled || WebSearchService.instance.isEnabled
  /// （后者 = 总开关打开且至少有一个可用后端）
  /// - 全局开 + 会话关 → 仍联网（全局默认）
  /// - 全局关 + 会话开 → 联网（会话临时启用）
  /// - 全局关 + 会话关 → 不联网
  ///
  /// 运行中切换不影响当前任务（system prompt 仅在 startTask 时构建一次，
  /// 符合 R3 精神：避免运行中修改 system prompt 导致上下文混乱）。
  /// 切换后下次 startTask 生效。
  bool _webSearchEnabled = false;

  /// sudo 密码：执行 sudo 命令时检测到密码提示后自动注入（不写入命令本身/审计日志）
  /// 由 AgentNotifier 从 CredentialsStore 加载并设置
  String? _sudoPassword;

  /// R2: 清理工具持有的资源（文件同步的 watcher/timer 等）
  /// 在 agent_provider dispose 时调用
  void disposeTools() {
    _tools.fileSyncService.dispose();
    // 同步重置编排标志，避免 _orchestratorMode 与 _tools.multiHostExecutor 不一致
    _orchestratorMode = false;
    _tools.disableOrchestrator();
  }

  /// 运行时刷新 executor 引用（用户重连 SSH 后由 AgentNotifier.setExecutor 调用）。
  /// 解决场景：sudo reboot / 网络抖动导致旧 SSHService 断开后，用户手动重连
  /// 创建新 SSHService 实例，但 ReAct 循环仍持有旧引用 → 连续 success=false。
  /// 此方法把新 executor 注入到 _currentExecutor，循环下一步会自动使用新引用。
  void setExecutor(CommandExecutor? executor) {
    if (executor == null) return;
    final old = _currentExecutor;
    _currentExecutor = executor;
    if (executor.isConnected) _consecutiveConnFailures = 0;
    if (old != executor) {
      agentLogger.info('AgentEngine',
          'executor 已刷新 (old.isConnected=${old?.isConnected}, new.isConnected=${executor.isConnected})');
    }
  }

  /// 连接自愈（自动/手动重连成功）后由 AgentNotifier 调用。
  ///
  /// 做两件事：把连续失败预算翻倍（重连已在后台跑完退避，此时 3 次门限会误杀
  /// 任务），并登记一条一次性的"新会话状态已丢失"提示。
  /// 只记标志不做别的事——写对话历史必须发生在 ReAct 循环的代际检查之后，
  /// 否则旧任务的重连事件会污染新任务历史（AGENTS.md R5）。
  void noteConnectionRestored() {
    _connFailBudget = _maxConnFailRetries * 2;
    _needsStateNote = true;
    agentLogger.info(
        'AgentEngine', '连接已自愈：连续失败预算放宽至 $_connFailBudget，待注入新会话提示');
  }

  /// 取走（并清除）重连后的一次性提示。命中时返回提示正文，否则返回 null。
  String? _takeStateNote() {
    if (!_needsStateNote) return null;
    _needsStateNote = false;
    return '[注意] 这是重连后的新会话：工作目录、环境变量、已导入的 sudo 状态全部丢失。'
        '不要直接重跑上一步命令——先核验它是否已生效（非幂等命令尤其危险）。';
  }

  /// 断线后该对 AI 说什么。到预算就要求停手改问用户，否则只引导。
  String _connFailGuidance() => _consecutiveConnFailures >= _connFailBudget
      ? '（已连续失败 $_consecutiveConnFailures 次，请立即使用 动作: ask 询问用户是否已重连，'
          '不要再尝试执行命令）'
      : '（请使用 动作: ask 询问用户是否已重连，或等待用户重连后继续）';

  /// 执行器自己判定断线（等待期看门狗、开工前预检）也要计入连续失败预算。
  ///
  /// 预算原本只在"执行前发现 isConnected==false"这条路上累加，而看门狗救的正是
  /// "isConnected 还写着 true 但链路已死"这一档——那条路上的断线原本不计数，
  /// 结果最常见的断线要跑到 maxSteps 才停，指引比预算晚整整一条命令。
  /// 返回带指引的诊断文本（无断线时原样返回）。
  String? _withConnGuidance(CommandResult result,
      {required bool countDisconnect}) {
    final reason = result.failureReason;
    if (result.failureKind != CommandFailureKind.disconnected) return reason;
    if (!countDisconnect) return reason;
    _consecutiveConnFailures++;
    agentLogger.warn('AgentEngine',
        '执行器判定断线 (连续 $_consecutiveConnFailures/$_connFailBudget)');
    return reason == null || reason.isEmpty
        ? _connFailGuidance()
        : '$reason${_connFailGuidance()}';
  }

  /// AI 流式响应超时：连续无数据超过该时长即判定超时（Agent 设置页可配置）
  Duration aiResponseTimeout;

  /// 凭据保存依赖注入点：默认走安全存储；测试用假实现验证保存失败/取消竞态。
  @visibleForTesting
  final Future<bool> Function({
    required String hostId,
    required String type,
    required String value,
  })? credentialSaver;

  AgentEngine({
    required AIProvider aiProvider,
    required AIModelConfig modelConfig,
    required AgentMemory memory,
    this.maxSteps = 0,
    this.aiResponseTimeout =
        const Duration(seconds: kDefaultAiResponseTimeoutSeconds),
    this.hostId,
    AIProvider? fallbackProvider,
    AIModelConfig? fallbackConfig,
    this.credentialSaver,
  })  : _aiProvider = aiProvider,
        _modelConfig = modelConfig,
        _memory = memory,
        _fallbackProvider = fallbackProvider,
        _fallbackConfig = fallbackConfig;

  /// 破坏性工具的用户确认通道
  ///
  /// 与危险命令的确认共用 [_confirmCompleter] 与 10 分钟超时策略：
  /// cancelTask / confirmChoice 已经知道怎么处理这个 Completer（R1：
  /// 从外部取消订阅时必须手动 complete，否则等待方永久挂起）。
  Future<bool> _confirmToolExecution(String toolName, String display,
      {required int myGeneration}) async {
    final generation = myGeneration;
    final taskId = _currentTask?.id;
    if (!_isTaskActive(generation, taskId)) return false;
    agentLogger.info('ReAct', '破坏性工具需要确认: $toolName');
    final completer = Completer<bool>();
    var timedOut = false;
    final timer = Timer(const Duration(minutes: 10), () {
      if (completer.isCompleted) return;
      timedOut = true;
      agentLogger.warn('ReAct', '工具确认超时(10min)，自动拒绝: $toolName');
      if (identical(_confirmCompleter, completer) &&
          _isTaskActive(generation, taskId)) {
        _confirmTimedOut = true;
        _taskHadConfirmTimeout = true;
      }
      completer.complete(false);
    });
    _pendingConfirmCommand = display;
    _confirmCompleter = completer;
    _confirmTimedOut = false;
    _confirmTimeoutTimer = timer;

    onEvent?.call(AgentEvent.info(L10n.str.ut_07c39ce9ce(display)));
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.waitingConfirm,
      phase: UiText.t('等待确认', 'Waiting for confirmation'),
      currentStep: L10n.str.ut_b306912acf(toolName),
    );
    _notifyTaskUpdate();

    // 等确认的墙钟要单独记账：它是人的反应时间，不该进 tok/s 的分母。
    final waitStart = DateTime.now();
    final confirmed = await completer.future;
    timer.cancel();
    if (identical(_confirmCompleter, completer)) {
      _confirmTimeoutTimer = null;
      _confirmCompleter = null;
      _pendingConfirmCommand = null;
    }
    if (!_isSameTask(generation, taskId)) return false;
    if (_currentTask?.status == AgentStatus.cancelled ||
        _currentTask?.status == AgentStatus.paused ||
        isTerminalStatus(_currentTask!.status)) {
      return false;
    }
    _confirmWaitSeconds += DateTime.now().difference(waitStart).inSeconds;
    // 保留给调用方区分超时/拒绝；只有本等待仍是当前确认时才可读取。
    if (timedOut) _confirmTimedOut = true;
    return confirmed;
  }

  /// 让当前等待中的确认立即按"超时"收口。
  ///
  /// 真定时器要等 10 分钟，测试拿不到；把两个定时器共用的收口逻辑抽出来，
  /// 才能真的验"超时不等于用户拒绝"这条归因。
  @visibleForTesting
  void expireConfirmTimeoutForTesting(String label) {
    if (_confirmCompleter == null || _confirmCompleter!.isCompleted) return;
    agentLogger.warn('ReAct', '确认超时(10min)，自动拒绝: $label');
    _confirmTimedOut = true;
    _taskHadConfirmTimeout = true;
    _confirmTimeoutTimer?.cancel();
    _confirmTimeoutTimer = null;
    _confirmCompleter!.complete(false);
  }

  /// 确认类交互式提示的输入桥：所有确认都交回 UI 让人决定。
  ///
  /// 由执行器在命令卡在 yes/no、[Y/n]、Press ENTER 等提示时回调。
  /// 返回答案（空串 = 直接回车）；null = 取消/超时/未接 UI，执行器按
  /// interactivePrompt 中断命令。
  ///
  /// 答案只作为 info 事件进事件时间线，**不进 [_conversationHistory]**
  /// （它不是模型需要的观测，进历史会污染上下文）、**不进凭据库**。
  /// 密码类提示不会到达这里 —— 检测器对密码永远走中断路径（R7）。
  Future<String?> _requestInteractiveInput(
    String prompt, {
    int? myGeneration,
    String? taskId,
    List<({String prompt, String answer})>? interactiveEchoes,
    void Function(Completer<String?>)? onCompleter,
  }) async {
    final generation = myGeneration ?? _currentTaskGeneration;
    final ownerTaskId = taskId ?? _currentTask?.id;
    bool stillCurrent() => _isSameTask(generation, ownerTaskId);
    bool active() => _isTaskActive(generation, ownerTaskId);
    if (!stillCurrent() || !active()) return null;
    final echoes = interactiveEchoes ?? _interactiveEchoes;

    final request = onInteractiveInputRequest;
    if (request == null) {
      agentLogger.warn('ReAct', 'UI 未接入交互输入回调，按交互式提示中断命令');
      return null;
    }

    final completer = Completer<String?>();
    _interactiveInputCompleter = completer;
    onCompleter?.call(completer);
    final timer = Timer(const Duration(minutes: 10), () {
      if (completer.isCompleted) return;
      agentLogger.warn('ReAct', '交互输入超时(10min)，按取消处理');
      completer.complete(null);
    });
    _interactiveInputTimeoutTimer = timer;

    onEvent?.call(AgentEvent.info(UiText.t(
      '⌨️ 命令等待输入: $prompt',
      '⌨️ Command awaiting input: $prompt',
    )));
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.waitingConfirm,
      phase: '等待输入',
      currentStep: '等待输入: $prompt',
    );
    _notifyTaskUpdate();

    // UI 弹窗异步作答。cancelTask/超时会先 complete(null)，迟到的答案只完成
    // 本轮局部 future，不得写进已经中断（或已被新任务接管）的终端。
    request(prompt).then((answer) {
      if (!completer.isCompleted) completer.complete(answer);
    }).catchError((Object e) {
      agentLogger.warn('ReAct', '交互输入弹窗异常: $e');
      if (!completer.isCompleted) completer.complete(null);
    });

    // 等输入的墙钟单独记账：人的反应时间不进 tok/s 分母（与确认等待同口径）
    final waitStart = DateTime.now();
    final answer = await completer.future;
    timer.cancel();
    if (identical(_interactiveInputCompleter, completer)) {
      _interactiveInputTimeoutTimer = null;
      _interactiveInputCompleter = null;
    }
    if (!stillCurrent()) return null;
    if (!active()) {
      agentLogger.info('ReAct', '交互输入等待期间任务已终止或暂停');
      return null;
    }
    _confirmWaitSeconds += DateTime.now().difference(waitStart).inSeconds;

    if (answer != null) {
      // 答案只进事件时间线（UI 可见），不进对话历史/凭据库
      echoes.add((prompt: prompt, answer: answer));
      onEvent?.call(AgentEvent.info(UiText.t(
        '⌨️ 已输入: ${answer.isEmpty ? "(回车)" : answer}',
        '⌨️ Input sent: ${answer.isEmpty ? "(Enter)" : answer}',
      )));
    } else {
      onEvent?.call(AgentEvent.info(UiText.t(
        '⌨️ 交互输入已取消或超时，命令将被中断',
        '⌨️ Input cancelled or timed out; command will be interrupted',
      )));
    }
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.executing,
      phase: UiText.t('执行中', 'Running'),
      currentStep: _progressStepText(),
    );
    _notifyTaskUpdate();
    return answer;
  }

  /// R1 回归用：拿到"当前正在等交互输入"的 Completer 本体。
  @visibleForTesting
  Completer<String?>? get pendingInteractiveInputForTesting =>
      _interactiveInputCompleter;

  /// 让当前等待中的交互输入立即按"超时"收口（真定时器要等 10 分钟，测试拿不到）。
  @visibleForTesting
  void expireInteractiveInputTimeoutForTesting() {
    final c = _interactiveInputCompleter;
    if (c == null || c.isCompleted) return;
    agentLogger.warn('ReAct', '交互输入超时(10min)，按取消处理');
    _interactiveInputTimeoutTimer?.cancel();
    _interactiveInputTimeoutTimer = null;
    c.complete(null);
  }

  /// 设置/更新 fallback 模型（运行时切换备用模型用）
  void setFallbackModel(AIProvider? provider, AIModelConfig? config) {
    _fallbackProvider = provider;
    _fallbackConfig = config;
  }

  AgentTask? get currentTask => _currentTask;
  bool get isRunning =>
      _currentTask?.status == AgentStatus.thinking ||
      _currentTask?.status == AgentStatus.executing ||
      _currentTask?.status == AgentStatus.waitingConfirm;

  /// P2-7: 任务是否已暂停（可恢复）
  bool get isPaused => _currentTask?.status == AgentStatus.paused;

  /// 代际与任务 id 必须同时匹配；仅比较代际无法表达同一引擎内被替换的任务对象。
  bool _isSameTask(int generation, String? taskId) {
    if (generation != _currentTaskGeneration) return false;
    final task = _currentTask;
    return taskId == null ? task == null : task?.id == taskId;
  }

  /// 旧任务回调能否继续写 UI / 历史 / 共享瞬态状态。
  bool _isTaskActive(int generation, String? taskId) {
    if (!_isSameTask(generation, taskId)) return false;
    final status = _currentTask?.status;
    return status != AgentStatus.cancelled &&
        status != AgentStatus.paused &&
        (status == null || !isTerminalStatus(status));
  }

  bool get hasPendingConfirm =>
      _confirmCompleter != null && !_confirmCompleter!.isCompleted;

  /// R1 回归用：拿到"当前正在等用户确认"的那个 Completer 本体。
  ///
  /// 瞬态字段被重置时必须 complete 而不是直接置 null —— 只看 `hasPendingConfirm`
  /// 变 false 分辨不出"已唤醒"和"被丢弃"，而后者正是让 await 永久挂死的写法。
  @visibleForTesting
  Completer<bool>? get pendingConfirmForTesting => _confirmCompleter;
  @visibleForTesting
  Completer<String>? get pendingChoiceForTesting => _choiceCompleter;

  // ── token 计量的测试入口 ──
  // 累计式与末包式 provider 的差别只体现在这里，却决定界面上的数字是否虚高数倍，
  // 所以必须能脱离真实 HTTP 流验证。
  @visibleForTesting
  void beginRoundForTesting() {
    _aiRounds++;
    _usageThisCall = false;
  }

  @visibleForTesting
  void recordUsageForTesting(TokenUsage usage) => _recordUsage(usage);

  @visibleForTesting
  int get tokenTotalForTesting => _tokReal + _tokEstimated;

  @visibleForTesting
  int get aiCallsForTesting => _aiRounds;

  @visibleForTesting
  int get blockedCountForTesting => _blockedCount;

  @visibleForTesting
  int get toolCallsForTesting => _toolCalls;

  /// 等确认累计秒数的测试入口。两个 await 确认点（破坏性工具 / 危险命令）共用它，
  /// 计量口径要求"人的反应时间不进 tok/s 分母"，所以必须能从真实 await 验证。
  @visibleForTesting
  int get confirmWaitSecondsForTesting => _confirmWaitSeconds;

  @visibleForTesting
  int? get cacheHitForTesting => _cacheHitPercent;

  int get taskGeneration => _currentTaskGeneration;

  @visibleForTesting
  void setTaskStatusForTesting(AgentStatus status) {
    _currentTask = AgentTask(id: 'test-task', goal: 'test', status: status);
  }

  @visibleForTesting
  int get connFailBudgetForTesting => _connFailBudget;

  @visibleForTesting
  int get consecutiveConnFailuresForTesting => _consecutiveConnFailures;

  @visibleForTesting
  bool get hasPendingStateNoteForTesting => _needsStateNote;

  @visibleForTesting
  void seedHistoryForTesting(List<ChatMessage> messages) {
    _conversationHistory
      ..clear()
      ..addAll(messages);
  }

  @visibleForTesting
  bool get hasSystemMessageForTesting =>
      _conversationHistory.any((m) => m.role == 'system');

  String? get pendingConfirmCommand => _pendingConfirmCommand;
  bool get hasPendingChoice =>
      _choiceCompleter != null && !_choiceCompleter!.isCompleted;
  List<String> get pendingOptions => List.unmodifiable(_pendingOptions);

  /// 构建进度步骤文本：第 N 步 | ✅成功数 ❌失败数 | 已用秒数
  String _progressStepText() {
    final elapsed = _taskStartTime != null
        ? DateTime.now().difference(_taskStartTime!).inSeconds
        : 0;
    final s = _currentTask?.successCount ?? 0;
    final f = _currentTask?.failureCount ?? 0;
    return '第 $_currentStepCount 步 | ✅$s ❌$f | ${elapsed}s';
  }

  /// 按命令类型派生展示阶段（委托 CommandRunner，不参与状态机）
  String _phaseForCommand(String command, SafetyLevel level) =>
      CommandRunner.phaseForCommand(command, level);

  /// 记录 provider 给出的真实 token 用量。
  ///
  /// 累计式 provider 每个 chunk 都带递增的 usage，末包式只在最后带一条——两者都
  /// 直接相加会重复计。这里按"同一轮内取最后一次"处理：`_usageThisCall` 在每轮
  /// 请求开始时清零，本轮内后续回调覆盖本轮已记的值。
  void _recordUsage(TokenUsage usage) {
    final total = usage.totalTokens ??
        ((usage.promptTokens ?? 0) + (usage.completionTokens ?? 0));
    final prompt = usage.promptTokens;
    final cached = usage.cachedTokens;

    if (_usageThisCall) {
      // 累计式 provider 每个 chunk 都带递增的 usage：回退本轮上一次记录，
      // 再写入最新值，否则一轮 20 个 chunk 会把用量记成 20 倍
      _tokReal -= _lastRoundReal;
      final lastCached = _lastRoundCached;
      if (lastCached != null) {
        _cachedPromptReal -= lastCached;
        _promptRealWithCached -= _lastRoundPrompt ?? 0;
      }
    }
    _usageThisCall = true;
    _lastRoundReal = total;
    _lastRoundPrompt = prompt;
    _lastRoundCached = cached;

    _tokReal += total;
    // 上下文规模取最近一轮的真实 prompt 大小
    if (prompt != null) _contextTokens = prompt;
    if (cached != null) {
      _cachedPromptReal += cached;
      _promptRealWithCached += prompt ?? 0;
    }
  }

  /// 刷新 elapsedSeconds 并通知任务更新（在每次 onTaskUpdated 前调用）
  void _notifyTaskUpdate() {
    if (_currentTask == null) return;
    final cacheHit = _cacheHitPercent;
    if (_taskStartTime != null) {
      final elapsed = DateTime.now().difference(_taskStartTime!).inSeconds;
      _currentTask = _currentTask!.copyWith(
        elapsedSeconds: elapsed,
        stepIndex: _currentStepCount,
        rounds: _roundIndex,
        aiCalls: _aiRounds,
        blockedCount: _blockedCount,
        toolCalls: _toolCalls,
        tokenTotal: _tokReal + _tokEstimated,
        hasEstimatedTokens: _tokEstimated > 0,
        cacheHitPercent: cacheHit,
        contextTokens: _contextTokens,
        confirmWaitSeconds: _confirmWaitSeconds,
      );
    } else {
      _currentTask = _currentTask!.copyWith(
        stepIndex: _currentStepCount,
        rounds: _roundIndex,
        aiCalls: _aiRounds,
        blockedCount: _blockedCount,
        toolCalls: _toolCalls,
        tokenTotal: _tokReal + _tokEstimated,
        hasEstimatedTokens: _tokEstimated > 0,
        cacheHitPercent: cacheHit,
        contextTokens: _contextTokens,
        confirmWaitSeconds: _confirmWaitSeconds,
      );
    }
    final status = _currentTask!.status;
    if (status == AgentStatus.completed ||
        status == AgentStatus.failed ||
        status == AgentStatus.cancelled ||
        status == AgentStatus.paused) {
      _localAccess?.revokeAll();
      _localAccess = null;
    }
    final updateCb = onTaskUpdated;
    if (updateCb != null) updateCb(_currentTask!);
  }

  void clearHistory() {
    // 清理瞬态字段，避免旧任务残留污染新会话
    if (isRunning || hasPendingConfirm || hasPendingChoice) {
      cancelTask();
    }
    _resetTransientState();
    _conversationHistory.clear();
  }

  /// 从持久化消息恢复引擎对话历史（切换会话时调用）
  /// [messages] 已摘要索引之后的消息（含 user/assistant，不含 system）
  /// [summary] 对话摘要（如有）
  /// system 消息会在下次 startTask 时由 _buildSystemPrompt 重建
  void restoreHistory(List<ChatMessage> messages, {String? summary}) {
    // 清理瞬态字段，避免旧任务残留污染切换后的会话
    if (isRunning || hasPendingConfirm || hasPendingChoice) {
      cancelTask();
    }
    _resetTransientState();
    _conversationHistory.clear();
    _conversationHistory.addAll(messages);
    agentLogger.info('RestoreHistory',
        '恢复引擎历史: ${messages.length} 条消息, summary=${summary != null ? "有" : "无"}');
  }

  /// 重置所有任务相关瞬态字段（不清理 _conversationHistory）
  /// 用于 clearHistory / restoreHistory / startTask 开头
  /// R2: 确保旧任务残留的 Completer/Subscription/Timer/CancelToken 不污染新任务
  void _resetTransientState() {
    _localAccess?.revokeAll();
    _localAccess = null;
    _accumulatedMessage = '';
    _steeringQueue.clear(); // O5: 旧任务的补充指令不能带进新任务
    _currentTaskIsGoalRound = false;
    _noCommandRetryCount = 0;
    _lastFcToolCalls = const [];
    _lastInvalidFcCalls = const [];
    _hasExecutedAnyCommand = false;
    _finishWithoutExecCount = 0;
    _syntaxRejectCount = 0;
    _commandPassedPrecheckThisTurn = false;
    _commandRejectedThisTurn = false;
    _commandSucceededThisTurn = false;
    _blockedTurnsStreak = 0;
    _userForbadeCommands = false;
    _planFinishRetryCount = 0; // O4/WP6: 计划 finish 门控计数新任务归零（R5）
    _consecutiveConnFailures = 0;
    _connFailBudget = _maxConnFailRetries; // 放宽只针对"本次任务途中重连过"，新任务归零
    _currentExecutor = null;
    _lastCommandEventId = '';
    _currentTask = null;
    _taskStartTime = null;
    _currentStepCount = 0;
    _stepOffset = 0;
    _operationId = null;
    _reportEmitted = false;
    _operationChangeIds.clear();
    _operationChanges.clear();
    _operationBadges.clear();
    _currentPlan = const [];
    // 清理取消令牌（防御性，cancelTask 应该已处理过）
    _aiWatchdog?.cancel();
    _aiWatchdog = null;
    _aiStreamTimeoutRetries = 0;
    _aiStreamSub?.cancel();
    _aiStreamSub = null;
    // R1: 与 cancelTask/pauseTask 一致，等待中的 awaiter 必须先 complete 再置 null。
    // 只置 null 会丢掉 future 唯一出口，挂起的旧循环永远醒不过来（等确认时
    // 暂停→resumeTask 开头调本方法即可走到）。complete 幂等，已完成的不会报错。
    final dc = _aiDoneCompleter;
    if (dc != null && !dc.isCompleted) dc.complete();
    _aiDoneCompleter = null;
    _aiCancelToken?.cancel('引擎瞬态状态重置');
    _aiCancelToken = null;
    if (_commandCancelToken != null && !_commandCancelToken!.isCompleted) {
      _commandCancelToken!.complete();
    }
    _commandCancelToken = null;
    if (_orchestratorCancelToken != null &&
        !_orchestratorCancelToken!.isCompleted) {
      _orchestratorCancelToken!.complete();
    }
    _orchestratorCancelToken = null;
    // R1：等待中的 awaiter 必须"先 complete 再置 null"。
    // 只置 null 等于把 future 唯一的出口丢掉，旧循环里的那个 await 永远醒不过来，
    // 那一轮的 result/finish 事件也就永远不发。这条路是真能走到的：
    // pauseTask 接受 waitingConfirm 状态（不唤醒确认等待），随后 resumeTask 开头
    // 就调本方法 —— 于是"破坏性工具等确认时点暂停、再恢复"会把任务永久挂死。
    if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
      _confirmCompleter!.complete(false);
    }
    _confirmTimeoutTimer?.cancel();
    _confirmTimeoutTimer = null;
    _confirmCompleter = null;
    _pendingConfirmCommand = null;
    if (_choiceCompleter != null && !_choiceCompleter!.isCompleted) {
      _choiceCompleter!.complete('');
    }
    _choiceCompleter = null;
    _pendingOptions = [];
    if (_interactiveInputCompleter != null &&
        !_interactiveInputCompleter!.isCompleted) {
      _interactiveInputCompleter!.complete(null);
    }
    _interactiveInputTimeoutTimer?.cancel();
    _interactiveInputTimeoutTimer = null;
    _interactiveInputCompleter = null;
    // 注意：不递增 _currentTaskGeneration — 那是 startTask 的职责
    // 这里只清状态，不失效代际（cancelTask 已失效过的话不需要再失效）
  }

  /// 压缩后同步内存历史：移除已摘要的旧消息，保留最近 N 轮
  /// 使内存中的 _conversationHistory 与持久化层（Conversation.messages）保持一致
  void syncAfterCompact(int keepRecentRounds) {
    final systemMsgs =
        _conversationHistory.where((m) => m.role == 'system').toList();
    final nonSystemMsgs =
        _conversationHistory.where((m) => m.role != 'system').toList();
    final keepCount = keepRecentRounds * 2;
    if (nonSystemMsgs.length > keepCount) {
      final kept =
          nonSystemMsgs.skip(nonSystemMsgs.length - keepCount).toList();
      _conversationHistory
        ..clear()
        ..addAll(systemMsgs)
        ..addAll(kept);
      agentLogger.info('SyncCompact',
          '同步内存历史: ${nonSystemMsgs.length} → ${kept.length} 条非系统消息');
    }
  }

  /// 启动 Agent 任务
  /// [goal] 用户目标
  /// [executor] 命令执行器，支持 SSHService（远程）或 LocalTerminalService（本地）
  /// [roundIndex] 会话累计轮次（用户提问 + 目标续跑），由 provider 计算并持久化
  /// [isGoalRound] 是否目标模式的续跑轮（含 /goal 首轮）。用户提问/普通指令
  /// 不是目标轮：终局时不参与目标续跑判定，否则纯问答答完又自动续跑旧目标。
  Future<void> startTask(String goal, CommandExecutor? executor,
      {int roundIndex = 0, bool isGoalRound = false}) {
    return agentLogger.runWithConversation(
      conversationId,
      () => _startTask(goal, executor,
          roundIndex: roundIndex, isGoalRound: isGoalRound),
    );
  }

  Future<void> _startTask(String goal, CommandExecutor? executor,
      {int roundIndex = 0, bool isGoalRound = false}) async {
    agentLogger.info('AgentEngine', '=== 开始任务 ===');
    agentLogger.info('AgentEngine', '目标: $goal');
    agentLogger.info('AgentEngine', '模式: Agent (ReAct)');
    agentLogger.info('AgentEngine',
        '执行器: ${executor != null ? (executor.isConnected ? "已连接" : "未连接") : "无"}');

    if (isRunning) {
      agentLogger.warn('AgentEngine', 'Agent 正在执行任务，拒绝新任务');
      onError?.call(L10n.str.agentRunning);
      return;
    }

    // R2: startTask 开头彻底重置瞬态字段
    // 不依赖 cancelTask 清理（旧任务可能正常 completed 后未清理）
    // 保证新任务起点干净：无残留 Completer/Subscription/Timer/CancelToken
    _resetTransientState();
    _currentExecutor = executor; // 保存 executor 引用，支持运行时刷新
    _absorbNoCommandConstraint(goal, '任务目标');

    // 新任务代际，使任何残留的旧循环退出
    _currentTaskGeneration++;
    final myGeneration = _currentTaskGeneration;
    _taskStartTime = DateTime.now(); // 记录任务开始时间，用于进度计算
    _currentStepCount = 0;
    // 计量按任务归零（暂停/恢复不清：恢复后要继续显示累计值，与 _stepOffset 同理）
    _tokReal = 0;
    _tokEstimated = 0;
    _cachedPromptReal = 0;
    _promptRealWithCached = 0;
    _usageThisCall = false;
    _aiRounds = 0;
    _blockedCount = 0;
    _toolCalls = 0;
    _roundIndex = roundIndex;
    _currentTaskIsGoalRound = isGoalRound;
    _confirmWaitSeconds = 0;
    _contextTokens = 0;
    _lastRoundReal = 0;
    _lastRoundPrompt = null;
    _lastRoundCached = null;
    _taskHadConfirmTimeout = false;
    _operationId = _uuid.v4(); // 稳定操作 id：本轮任务及其暂停/恢复共用

    _currentTask = AgentTask(
      id: _uuid.v4(),
      operationId: _operationId,
      goal: goal,
      status: AgentStatus.thinking,
      phase: '理解需求',
      rounds: _roundIndex,
    );
    final accessTaskId = _currentTask!.id;
    _localAccess = LocalAccessService(
      taskId: accessTaskId,
      generation: myGeneration,
      isActive: () {
        final status = _currentTask?.status;
        return _currentTaskGeneration == myGeneration &&
            _currentTask?.id == accessTaskId &&
            (status == AgentStatus.thinking ||
                status == AgentStatus.executing ||
                status == AgentStatus.waitingConfirm);
      },
      authorizationRequest: (path, reason, mode) async {
        if (_currentTaskGeneration != myGeneration ||
            _currentTask?.id != accessTaskId) {
          return false;
        }
        final request = onLocalDirRequest;
        if (request == null) return false;
        return request(path, reason, mode);
      },
    );
    _notifyTaskUpdate();

    // P0-2: trace 任务开始
    AgentTracer.instance.startTask(_currentTask!.id, goal, hostId: hostId);

    try {
      agentLogger.info('AgentEngine', '执行 Agent 模式');
      // _executeAutomatic 要求非空 executor，此处显式检查避免调用方误传 null
      if (executor == null) {
        agentLogger.error('AgentEngine', '执行器为 null，无法启动任务');
        // R5: 经 TerminationGuard 收口；失败路径的 flush 走 onError（既有语义）
        _terminationGuard.terminate(
          status: AgentStatus.failed,
          finishState: AgentFinishState.failed,
          expectedGeneration: myGeneration,
          writeStatus: (status) {
            _currentTask = _currentTask!.copyWith(
              status: status,
              completedAt: DateTime.now(),
            );
            _notifyTaskUpdate();
          },
          emitReport: () => _emitOperationReport(
            finishState: AgentFinishState.failed,
            reason: L10n.str.terminalNotConnected,
          ),
          emitFinish: () => onEvent?.call(AgentEvent.finish(
            summary: L10n.str.terminalNotConnected,
            finishState: AgentFinishState.failed,
          )),
          flush: () => onError?.call(L10n.str.terminalNotConnected),
        );
        return;
      }
      await _executeAutomatic(goal, executor, myGeneration);
    } catch (e, stack) {
      agentLogger.error('AgentEngine', '执行异常: $e\n$stack');
      // R1: 代际检查 — 旧任务抛异常时不能覆盖新任务状态
      if (myGeneration != _currentTaskGeneration) {
        agentLogger.info('AgentEngine', '代际已变更，跳过失败状态写入');
        return;
      }
      final startTime = _currentTask?.createdAt;
      final errText = _friendlyErrorMessage(e);
      // R5: 经 TerminationGuard 收口；失败路径 flush 走 onError（既有语义）
      final emitted = _terminationGuard.terminate(
        status: AgentStatus.failed,
        finishState: AgentFinishState.failed,
        expectedGeneration: myGeneration,
        writeStatus: (status) {
          _currentTask = _currentTask?.copyWith(
            status: status,
            completedAt: DateTime.now(),
          );
          // 最后一条是 user 消息（无 assistant 响应）时补一条错误消息，保持历史完整
          if (_currentTask != null &&
              _conversationHistory.isNotEmpty &&
              _conversationHistory.last.role == 'user') {
            _conversationHistory.add(ChatMessage.create(
              role: 'assistant',
              content: '${L10n.str.taskExecutionError}: $errText',
            ));
          }
          _notifyTaskUpdate();
        },
        emitReport: () => _emitOperationReport(
          finishState: AgentFinishState.failed,
          reason: errText,
        ),
        emitFinish: () => onEvent?.call(AgentEvent.finish(
          summary: '⚠️ 任务异常终止: $errText',
          finishState: AgentFinishState.failed,
        )),
        flush: () => onError?.call(errText),
      );
      if (emitted) {
        // 任务失败通知（仅本次真正收口时发，避免 Guard 幂等拒绝后重复通知）
        _notifyTaskCompletion(
            success: false, startTime: startTime, error: e.toString());
      }
    }
  }

  void cancelTask() {
    _localAccess?.revokeAll();
    _localAccess = null;
    // 无论当前处于何种状态（thinking/executing/waitingConfirm），都标记为取消
    final wasActive = _currentTask != null &&
        _currentTask!.status != AgentStatus.cancelled &&
        _currentTask!.status != AgentStatus.completed &&
        _currentTask!.status != AgentStatus.failed;
    if (wasActive) {
      // R5: 经 TerminationGuard 收口。必须在下面递近代际之前调用 ——
      // Guard 按当前代际记录幂等，代际++ 后本代际即失效。
      final finishSummary =
          _accumulatedMessage.isNotEmpty ? _accumulatedMessage : '任务已取消';
      _terminationGuard.terminate(
        status: AgentStatus.cancelled,
        finishState: AgentFinishState.cancelled,
        writeStatus: (status) {
          _currentTask = _currentTask!.copyWith(
            status: status,
            phase: '已取消',
            completedAt: DateTime.now(),
          );
          _notifyTaskUpdate();
        },
        emitReport: () =>
            _emitOperationReport(finishState: AgentFinishState.cancelled),
        emitFinish: () => onEvent?.call(AgentEvent.finish(
          summary: finishSummary,
          finishState: AgentFinishState.cancelled,
        )),
        flush: _accumulatedMessage.isEmpty
            ? null
            : () => onCompleted?.call(_accumulatedMessage),
        endTracer: () => AgentTracer.instance.endTask(
          _currentTask!.id,
          status: 'cancelled',
          summary: '用户取消任务',
          hostId: hostId,
        ),
      );
    }
    // 递近代际，使任何残留的旧循环立即退出
    _currentTaskGeneration++;
    // O5: 取消即丢弃未注入的补充指令（已持久化的用户消息仍留在会话里）
    _steeringQueue.clear();
    // 同时取消等待确认
    if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
      _confirmCompleter!.complete(false);
    }
    _pendingConfirmCommand = null;
    // R2: cancel 确认超时定时器，避免 Timer 泄漏
    _confirmTimeoutTimer?.cancel();
    _confirmTimeoutTimer = null;
    // 同时取消等待选择
    if (_choiceCompleter != null && !_choiceCompleter!.isCompleted) {
      _choiceCompleter!.complete('');
    }
    _pendingOptions = [];
    // 同时取消等待交互输入（R1：先 complete(null) 唤醒 await，再清定时器）
    if (_interactiveInputCompleter != null &&
        !_interactiveInputCompleter!.isCompleted) {
      _interactiveInputCompleter!.complete(null);
    }
    _interactiveInputTimeoutTimer?.cancel();
    _interactiveInputTimeoutTimer = null;
    // 取消正在执行的命令
    if (_commandCancelToken != null && !_commandCancelToken!.isCompleted) {
      _commandCancelToken!.complete();
    }
    _commandCancelToken = null;
    // 取消编排任务（覆盖整个 ReAct 循环周期，批量命令通过它立即中断）
    if (_orchestratorCancelToken != null &&
        !_orchestratorCancelToken!.isCompleted) {
      _orchestratorCancelToken!.complete();
    }
    _orchestratorCancelToken = null;
    // 取消 AI 流式订阅，停止消费旧任务流
    // 注意: cancel() 不触发 onDone，需手动 complete doneCompleter
    final dc = _aiDoneCompleter;
    if (dc != null && !dc.isCompleted) dc.complete();
    // 取消底层 Dio HTTP 请求：比 _aiStreamSub.cancel() 更彻底
    // 直接关闭 TCP 连接，避免取消任务后 API 仍在流式输出消耗配额
    // 防御性 if 包裹：cancelToken 可能已 completed（Dio 二次 cancel 会触发 warning）
    if (_aiCancelToken != null && !_aiCancelToken!.isCancelled) {
      _aiCancelToken!.cancel('用户取消任务');
    }
    _aiCancelToken = null;
    _aiStreamSub?.cancel();
    _aiStreamSub = null;
    _aiWatchdog?.cancel();
    _aiWatchdog = null;
    _aiDoneCompleter = null;
    // R5: 终态动作（status/report/finish/flush/tracer）已由上方 Guard 在
    // 递近代际前收口；此处只保留资源清理。
  }

  /// P2-7: 暂停当前任务
  /// 行为：标记 status=paused，让 ReAct 循环在下一轮检查时退出。
  /// 与 cancelTask 的关键区别：
  ///   - 不递近代际（保留 myGeneration，resumeTask 时可继续）
  ///   - 不 emit finish 事件（任务未结束，UI 保持"已暂停"状态）
  ///   - 不清理 _conversationHistory（恢复后继续对话）
  ///   - 不调用 onCompleted（不 flush 流式内容到持久化）
  ///   - 但会取消正在执行的命令和 AI 流（让阻塞的 await 立即返回）
  void pauseTask() {
    if (_currentTask == null) return;
    final s = _currentTask!.status;
    // 只在 thinking/executing/waitingConfirm 时允许暂停
    if (s != AgentStatus.thinking &&
        s != AgentStatus.executing &&
        s != AgentStatus.waitingConfirm) {
      return;
    }
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.paused,
      phase: UiText.t('已暂停', 'Paused'),
    );
    _localAccess?.revokeAll();
    _localAccess = null;
    _notifyTaskUpdate();
    agentLogger.info('AgentEngine', '任务已暂停 (暂停前状态: $s)');

    // 取消正在执行的命令（不递近代际，恢复时由用户重新发起 startTask 或继续）
    if (_commandCancelToken != null && !_commandCancelToken!.isCompleted) {
      _commandCancelToken!.complete();
    }
    if (_orchestratorCancelToken != null &&
        !_orchestratorCancelToken!.isCompleted) {
      _orchestratorCancelToken!.complete();
    }
    // 取消 AI 流式订阅
    final dc = _aiDoneCompleter;
    if (dc != null && !dc.isCompleted) dc.complete();
    if (_aiCancelToken != null && !_aiCancelToken!.isCancelled) {
      _aiCancelToken!.cancel('用户暂停任务');
    }
    _aiStreamSub?.cancel();
    _aiStreamSub = null;
    _aiWatchdog?.cancel();
    _aiWatchdog = null;
    _aiDoneCompleter = null;
    _aiCancelToken = null;
    // 取消等待确认 / 选择（让 await 立即返回）
    if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
      _confirmCompleter!.complete(false);
    }
    if (_choiceCompleter != null && !_choiceCompleter!.isCompleted) {
      _choiceCompleter!.complete('');
    }
    // 取消等待交互输入（R1：同确认/选择，暂停不能让 await 挂死）
    if (_interactiveInputCompleter != null &&
        !_interactiveInputCompleter!.isCompleted) {
      _interactiveInputCompleter!.complete(null);
    }
    _interactiveInputTimeoutTimer?.cancel();
    _interactiveInputTimeoutTimer = null;
    // R2: 取消确认超时定时器，避免暂停后定时器仍占用资源
    // （恢复时 _resetTransientState 会再次清理，但暂停期间不该让定时器空转）
    _confirmTimeoutTimer?.cancel();
    _confirmTimeoutTimer = null;
    // 通知 UI 暂停（info 事件，不是 finish）
    onEvent?.call(AgentEvent.info(UiText.t(
        '⏸️ 任务已暂停，可点击恢复继续', '⏸️ Task paused. Click resume to continue.')));
  }

  /// P2-7: 恢复已暂停的任务
  /// 实现：清除 paused 状态，重新调用 _executeAutomatic 触发 ReAct 循环
  /// （会复用 _conversationHistory 中已累积的上下文）
  /// [executor] 当前命令执行器；若为 null 则无法恢复
  Future<void> resumeTask(CommandExecutor? executor) {
    return agentLogger.runWithConversation(
      conversationId,
      () => _resumeTask(executor),
    );
  }

  Future<void> _resumeTask(CommandExecutor? executor) async {
    if (_currentTask == null || _currentTask!.status != AgentStatus.paused) {
      return;
    }
    if (executor == null || !executor.isConnected) {
      onError?.call(L10n.str.terminalNotConnected);
      return;
    }
    // 在 _resetTransientState 之前捕获 goal 与 operationId（reset 会清空 _currentTask）
    final goal = _currentTask!.goal;
    final operationId = _currentTask!.operationId ?? _operationId;
    final plan = _currentPlan;
    final previousStepCount = _currentStepCount;
    final previousSuccessCount = _currentTask!.successCount;
    final previousFailureCount = _currentTask!.failureCount;
    final previousElapsed = _currentTask!.elapsedSeconds ?? 0;
    final previousStartedAt = _taskStartTime ?? _currentTask!.createdAt;
    final hadExecutedAnyCommand = _hasExecutedAnyCommand;
    final hadForbiddenCommands = _userForbadeCommands;
    final wasGoalRound = _currentTaskIsGoalRound;
    final previousChangeIds = List<String>.of(_operationChangeIds);
    final previousChanges = List<OperationChange>.of(_operationChanges);
    final previousBadges = List<OperationBadge>.of(_operationBadges);
    agentLogger.info('AgentEngine', '恢复已暂停的任务: $goal');
    // 清理瞬态字段但保留 _conversationHistory（恢复上下文）
    _resetTransientState();
    _currentExecutor = executor; // 保存 executor 引用，支持运行时刷新
    _currentTaskGeneration++;
    final myGeneration = _currentTaskGeneration;
    // 恢复后继续累计步数/耗时/成功失败数，不从零开始
    _taskStartTime = previousStartedAt;
    _currentStepCount = previousStepCount;
    _stepOffset = previousStepCount;
    _hasExecutedAnyCommand = hadExecutedAnyCommand;
    _userForbadeCommands = hadForbiddenCommands;
    _currentTaskIsGoalRound = wasGoalRound;
    _operationChangeIds.addAll(previousChangeIds);
    _operationChanges.addAll(previousChanges);
    _operationBadges.addAll(previousBadges);
    _operationId = operationId ?? _uuid.v4();
    _currentPlan = plan;
    _currentTask = AgentTask(
      id: _uuid.v4(),
      operationId: _operationId,
      goal: goal,
      status: AgentStatus.thinking,
      phase: '继续执行',
      createdAt: previousStartedAt,
      elapsedSeconds: previousElapsed,
      stepIndex: previousStepCount,
      successCount: previousSuccessCount,
      failureCount: previousFailureCount,
      // 暂停/恢复不重置计量：恢复后仍显示同一轮、同一批步数
      rounds: _roundIndex,
      aiCalls: _aiRounds,
      blockedCount: _blockedCount,
      toolCalls: _toolCalls,
    );
    final accessTaskId = _currentTask!.id;
    _localAccess = LocalAccessService(
      taskId: accessTaskId,
      generation: myGeneration,
      isActive: () {
        final status = _currentTask?.status;
        return _currentTaskGeneration == myGeneration &&
            _currentTask?.id == accessTaskId &&
            (status == AgentStatus.thinking ||
                status == AgentStatus.executing ||
                status == AgentStatus.waitingConfirm);
      },
      authorizationRequest: (path, reason, mode) async {
        if (_currentTaskGeneration != myGeneration ||
            _currentTask?.id != accessTaskId) {
          return false;
        }
        final request = onLocalDirRequest;
        if (request == null) return false;
        return request(path, reason, mode);
      },
    );
    _notifyTaskUpdate();
    AgentTracer.instance
        .startTask(_currentTask!.id, '恢复: $goal', hostId: hostId);
    onEvent?.call(AgentEvent.info(
        UiText.t('▶️ 任务已恢复，继续执行...', '▶️ Task resumed, continuing...')));
    try {
      await _executeAutomatic(goal, executor, myGeneration);
    } catch (e, stack) {
      agentLogger.error('AgentEngine', '恢复执行异常: $e\n$stack');
      if (myGeneration == _currentTaskGeneration && _currentTask != null) {
        final errText = _friendlyErrorMessage(e);
        // R5: 经 TerminationGuard 收口。恢复失败也要 flush 流式内容到持久化
        // （provider 侧只在 onError/onCompleted 回调里 flush），走 onError。
        _terminationGuard.terminate(
          status: AgentStatus.failed,
          finishState: AgentFinishState.failed,
          expectedGeneration: myGeneration,
          writeStatus: (status) {
            _currentTask = _currentTask!.copyWith(
              status: status,
              completedAt: DateTime.now(),
            );
            _notifyTaskUpdate();
          },
          emitReport: () => _emitOperationReport(
            finishState: AgentFinishState.failed,
            reason: errText,
          ),
          emitFinish: () => onEvent?.call(AgentEvent.finish(
            summary: '${L10n.str.taskFailed}: $errText',
            finishState: AgentFinishState.failed,
          )),
          flush: () => onError?.call(errText),
        );
      }
    }
  }

  /// 确认执行危险命令（由用户点击确认按钮触发）
  void confirmDangerousCommand() {
    if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
      _confirmCompleter!.complete(true);
    }
    _pendingConfirmCommand = null;
  }

  /// 拒绝执行危险命令（由用户点击拒绝按钮触发）
  void rejectDangerousCommand() {
    if (_confirmCompleter != null && !_confirmCompleter!.isCompleted) {
      _confirmCompleter!.complete(false);
    }
    _pendingConfirmCommand = null;
  }

  /// 用户选择了一个选项（:::choose 格式）
  void selectChoice(String choice) {
    if (_choiceCompleter != null && !_choiceCompleter!.isCompleted) {
      _choiceCompleter!.complete(choice);
    }
    _pendingOptions = [];
  }

  /// O5: 任务运行中用户补充指令（steering）。
  /// 只入队，不打断正在执行的命令，也不打断确认/ask 等待；
  /// 下一轮 ReAct 循环边界统一注入为 user 消息并发 info 事件。
  /// 空串/纯空白忽略；超长保尾截断（R8）。
  void addUserSteering(String text) {
    var t = text.trim();
    if (t.isEmpty) return;
    if (t.length > maxSteeringChars) {
      t = t.substring(t.length - maxSteeringChars);
    }
    while (_steeringQueue.length >= _maxSteeringQueueLength) {
      final dropped = _steeringQueue.removeFirst();
      agentLogger.warn('ReAct',
          '补充指令队列已满($_maxSteeringQueueLength)，丢弃最早一条(${dropped.length} 字符)');
    }
    _steeringQueue.add(t);
    agentLogger.info('ReAct', '收到用户补充指令(${t.length} 字符)，下一轮循环边界注入');
  }

  /// 待注入的补充指令条数（测试与 UI 提示用）
  int get pendingSteeringCount => _steeringQueue.length;

  Future<void> _executeAutomatic(
      String goal, CommandExecutor executor, int myGeneration) async {
    agentLogger.info('ReAct', '=== 开始 ReAct 自动执行 ===');

    // 代际失效：说明在 startTask 等待期间被新任务覆盖或取消了
    if (myGeneration != _currentTaskGeneration) {
      agentLogger.info('ReAct', '代际失效，放弃执行');
      return;
    }
    final myTaskId = _currentTask?.id;

    if (!executor.isConnected) {
      agentLogger.error('ReAct', '执行器未连接!');
      // R5: 经 TerminationGuard 收口；失败路径 flush 走 onError（既有语义）
      _terminationGuard.terminate(
        status: AgentStatus.failed,
        finishState: AgentFinishState.failed,
        expectedGeneration: myGeneration,
        writeStatus: (status) {
          _currentTask = _currentTask!.copyWith(
            status: status,
            completedAt: DateTime.now(),
          );
          _notifyTaskUpdate();
        },
        emitReport: () => _emitOperationReport(
          finishState: AgentFinishState.failed,
          reason: L10n.str.terminalNotConnected,
        ),
        emitFinish: () => onEvent?.call(AgentEvent.finish(
          summary: L10n.str.terminalNotConnected,
          finishState: AgentFinishState.failed,
        )),
        flush: () => onError?.call(L10n.str.terminalNotConnected),
      );
      return;
    }

    agentLogger.info('ReAct', '执行器连接状态: ${executor.isConnected}');

    // 创建编排取消令牌：覆盖整个 ReAct 循环周期，注入到 MultiHostExecutor。
    // cancelTask 会 complete 它，编排里的批量 executeAndWait 据此立即中断。
    // 旧任务残留的 token 先丢弃（理论上 cancelTask 已 complete 过）。
    _orchestratorCancelToken = Completer<void>();
    final mhe = _tools.multiHostExecutor;
    if (mhe != null) {
      mhe.cancelToken = _orchestratorCancelToken;
    }

    // maxSteps=0 表示无限制（用户在设置里拖到 0 即"无限制"）
    // 死循环防护由 _noCommandRetryCount（连续无命令 2 次即终止）承担
    final maxSteps = this.maxSteps;
    final isUnlimited = maxSteps == 0;
    // 恢复任务时从已执行步数继续，而不是从 0 重新计数
    var stepCount = _stepOffset;

    // 判断是否为新对话
    final isNewConversation = _conversationHistory.isEmpty;

    // 同步外部 MCP 工具（连接/断开/工具列表变化后，任务开始时刷新）
    McpManager.instance.syncRegistry(_tools);

    // 更新或创建系统提示（ReAct 模式专用）
    final systemPrompt = _buildSystemPrompt(executor);
    if (isNewConversation) {
      _conversationHistory
          .add(ChatMessage.create(role: 'system', content: systemPrompt));
    } else if (_conversationHistory.isNotEmpty &&
        _conversationHistory[0].role == 'system') {
      _conversationHistory[0] =
          ChatMessage.create(role: 'system', content: systemPrompt);
    } else {
      // 恢复历史后索引 0 不是 system 消息，需在开头插入
      _conversationHistory.insert(
          0, ChatMessage.create(role: 'system', content: systemPrompt));
    }

    // 添加用户消息。包装保持意图中性：纯提问（问原因/原理）不是操作任务，
    // 旧文案"请分析任务并开始执行"会把模型框进执行模式，见提示词【纯提问直接回答】。
    // 旧历史里追加的新问题必须标记为独立请求，否则模型把它当上一任务的续跑，
    // 重新执行命令并"反刍"上一任务的总结。
    // 目标续跑轮例外：它本来就是上一目标的继续，标成"独立新请求"会自相矛盾。
    final String userContent;
    if (isNewConversation) {
      userContent = '用户消息: $goal\n\n请先判断意图：操作请求→规划并执行；'
          '纯提问→直接基于上下文回答并 finish，无需执行命令。';
    } else if (goal.startsWith(kGoalContinuationPrefix)) {
      userContent = '$goal\n\n这是目标模式的自动续跑轮，请继续朝该目标推进，'
          '不要把它当成新的独立请求。';
    } else {
      userContent = '用户的新消息（独立的新请求，不是上一任务的继续）: $goal\n'
          '如果这是对上一任务的提问，直接基于已有上下文回答，'
          '不要重新执行命令，也不要重复之前的总结。';
    }
    _conversationHistory.add(ChatMessage.create(
      role: 'user',
      content: userContent,
    ));

    agentLogger.info('ReAct',
        '对话历史: ${_conversationHistory.length} 条消息 (新对话: $isNewConversation)');

    // 不再插入「🚀 开始自动执行任务...」这类启动提示：紧随其后的推理已经
    // 说明了在做什么，一条纯装饰的系统日志只会占掉过程流的第一行。
    _accumulatedMessage = '';

    agentLogger.info(
        'ReAct', '开始 ReAct 循环 (${isUnlimited ? "无限制" : "最多 $maxSteps 步"})');

    while (isUnlimited || stepCount < maxSteps) {
      stepCount++;
      agentLogger.info('ReAct', '--- 步骤 $stepCount ---');

      // 代际失效：新任务已启动或已取消，旧循环立即退出
      if (myGeneration != _currentTaskGeneration) {
        agentLogger.info('ReAct', '代际失效，旧循环退出');
        return;
      }

      // P2-7: 暂停检查 — pauseTask 设置 status=paused 后旧循环退出
      // resumeTask 会创建新代际+新任务壳，由新循环接管
      if (_currentTask?.status == AgentStatus.paused) {
        agentLogger.info('ReAct', '任务已暂停，循环退出');
        return;
      }

      // O5: 排空用户补充指令队列（steering）。
      // 同步执行、无 await：排空期间不可能被新任务/取消打断，天然满足 R1；
      // 且位于上方代际/暂停检查之后，旧循环不会把补充注入新会话历史。
      // 等待确认/ask 期间循环阻塞在各自的 await，补充自然留到下一轮边界。
      if (_steeringQueue.isNotEmpty) {
        final injected = _steeringQueue.length;
        while (_steeringQueue.isNotEmpty) {
          final steering = _steeringQueue.removeFirst();
          _absorbNoCommandConstraint(steering, '用户补充');
          _conversationHistory.add(ChatMessage.create(
            role: 'user',
            content: '用户补充: $steering',
          ));
          onEvent?.call(AgentEvent.info(L10n.str.ut_0968807bf1(steering)));
        }
        // 补充可能是提问而不是指令（"刚才为何用压缩"这类）。不引导的话
        // 模型会把它当任务指令，继续执行甚至反刍上一任务的总结。
        _conversationHistory.add(ChatMessage.create(
          role: 'user',
          content: '（以上为用户补充：若是提问而非指令，直接基于已有上下文简要回答，'
              '不要为回答它执行新命令，也不要重复之前的任务总结；若是指令则按补充调整任务。）',
        ));
        _trimMessages(_conversationHistory);
        agentLogger.info('ReAct', '已注入 $injected 条用户补充指令');
      }

      // 刷新 executor 引用：AgentNotifier.setExecutor 可能在用户重连后
      // 更新了 _currentExecutor（如 sudo reboot 后用户手动重连 SSH）。
      // 每步取最新值，避免循环持有已断开的旧 SSHService 引用。
      final refreshed = _currentExecutor;
      if (refreshed != null && refreshed != executor) {
        executor = refreshed;
        agentLogger.info('ReAct',
            '检测到 executor 已刷新，使用新引用 (isConnected=${executor.isConnected})');
      }

      // 重连后的一次性状态提示：放在代际检查之后、_callAI 之前，同步写入，
      // 旧任务的重连事件不会漏进新任务历史（R1/R5）。
      final stateNote = _takeStateNote();
      if (stateNote != null) {
        _conversationHistory
            .add(ChatMessage.create(role: 'user', content: stateNote));
        _trimMessages(_conversationHistory);
      }

      // O4/WP6: 把计划进度快照幂等注入 system 消息（每轮替换整段，不累积）。
      // 位于代际/暂停检查（与 steering 排空）之后、_callAI 之前：
      // 同步执行无 await，旧循环不会把快照写进新会话历史（R1/R3）。
      _syncPlanProgressToSystemMessage();

      // ═══════════════════════════════════════════
      // 阶段1: 思考 (Think) — 调用 AI 获取响应
      // ═══════════════════════════════════════════
      // 每轮命令状态独立记账；提前执行也发生在本轮 _callAI 内。
      _commandPassedPrecheckThisTurn = false;
      _commandRejectedThisTurn = false;
      _commandSucceededThisTurn = false;
      _currentStepCount = stepCount;
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.thinking,
        phase: UiText.t('思考中', 'Thinking'),
        currentStep: _progressStepText(),
      );
      _notifyTaskUpdate();
      onThinking?.call(L10n.str.thinkingNextStep);

      String fullResponse;
      _EarlyExecutionSlot? earlyExecution;
      try {
        fullResponse = await _callAI(
          myGeneration: myGeneration,
          onCommandDetected: (command, commandId) {
            // 提前执行槽属于本轮局部调用：旧任务的 then/onError 只能完成
            // 自己的 completer，绝不能通过共享字段完成新任务的等待。
            if (earlyExecution != null ||
                !_isTaskActive(myGeneration, myTaskId)) {
              return;
            }
            final slot = _EarlyExecutionSlot(command);
            earlyExecution = slot;
            _runCommandWithSafety(command, executor,
                    commandId: commandId, myGeneration: myGeneration)
                .then(
              (result) {
                if (!slot.completer.isCompleted) {
                  slot.completer.complete(result);
                }
              },
              onError: (Object e) {
                agentLogger.error('ReAct', '提前执行异常: $e');
                if (!slot.completer.isCompleted) {
                  slot.completer.complete(_EarlyExecutionResult(
                    shouldContinue: false,
                    command: command,
                  ));
                }
              },
            );
          },
        );
      } catch (e, stack) {
        // R1: 区分"取消/代际变更"和真正的 AI 调用异常
        // 前者是正常流程的一部分（用户点了取消或新任务覆盖），不应记 error 日志
        final isCancellation = e is StateError &&
            (e.message == '任务已取消' ||
                e.message == '任务已被新任务覆盖' ||
                e.message == '任务已暂停');
        if (isCancellation) {
          agentLogger.info('ReAct', 'AI 调用因取消/暂停/代际变更终止: ${e.message}');
        } else {
          agentLogger.error('ReAct', 'AI 调用异常: $e\n$stack');
        }
        // L1 修复：AI 异常应标记 failed 并退出，不应走到循环后的 completed 逻辑
        if (myGeneration == _currentTaskGeneration &&
            _isSameTask(myGeneration, myTaskId) &&
            _currentTask != null) {
          if (isCancellation) {
            // 取消场景：cancelTask 已设置 status=cancelled 并 emit finish，不重复处理
            return;
          }
          final friendlyMsg = _friendlyErrorMessage(e);
          // 将错误信息作为 assistant 消息加入历史，保持 user/assistant 交替完整性
          // 这样下次任务（如用户发"继续"）时 AI 能看到之前的上下文
          final errorMsg = '⚠️ AI 调用失败: $friendlyMsg';
          _accumulatedMessage = errorMsg;
          onMessage?.call(errorMsg);
          _conversationHistory.add(ChatMessage.create(
            role: 'assistant',
            content: errorMsg,
          ));
          final startTime = _currentTask!.createdAt;
          // R5: 经 TerminationGuard 收口；失败路径 flush 走 onError（既有语义）
          final emitted = _terminationGuard.terminate(
            status: AgentStatus.failed,
            finishState: AgentFinishState.failed,
            expectedGeneration: myGeneration,
            writeStatus: (status) {
              _currentTask = _currentTask!.copyWith(
                status: status,
                completedAt: DateTime.now(),
              );
              _notifyTaskUpdate();
            },
            emitReport: () => _emitOperationReport(
              finishState: AgentFinishState.failed,
              reason: friendlyMsg,
            ),
            emitFinish: () => onEvent?.call(AgentEvent.finish(
              summary: '${L10n.str.taskFailed}: $friendlyMsg',
              finishState: AgentFinishState.failed,
            )),
            flush: () => onError?.call(friendlyMsg),
          );
          if (emitted) {
            // 任务失败通知（与外层 catch 保持一致）
            _notifyTaskCompletion(
                success: false, startTime: startTime, error: e.toString());
          }
        }
        return;
      }

      // 代际失效：AI 流式期间被新任务覆盖，旧循环退出
      // L5 修复：先检查代际，再加入历史，避免旧响应污染新会话
      if (myGeneration != _currentTaskGeneration ||
          !_isSameTask(myGeneration, myTaskId)) {
        agentLogger.info('ReAct', 'AI 响应期间代际失效，旧循环退出');
        return;
      }

      // 用户在 AI 流式输出期间点了取消或暂停：缓冲的 finish 不得覆盖用户意图。
      final responseStatus = _currentTask?.status;
      if (responseStatus == AgentStatus.cancelled ||
          responseStatus == AgentStatus.paused) {
        agentLogger.info('ReAct', 'AI 响应期间任务被取消或暂停');
        return;
      }

      // 将 AI 响应加入对话历史（代际和取消检查通过后）
      // O8: FC 轮次把结构化动作按文本协议格式记进历史，保证模型（含 fallback
      // 到非 FC 模型时）能从历史读到自己上一轮做了什么；该文本不参与本轮解析。
      final fcCalls = _lastFcToolCalls;
      final invalidFcCalls = _lastInvalidFcCalls;
      final historyContent = fcCalls.isEmpty
          ? fullResponse
          : '$fullResponse${_fcCallsToHistoryText(fcCalls)}';
      _conversationHistory
          .add(ChatMessage.create(role: 'assistant', content: historyContent));
      if (invalidFcCalls.isNotEmpty) {
        _conversationHistory.add(ChatMessage.create(
          role: 'user',
          content: invalidFcCalls.map(_invalidFcObservation).join('\n'),
        ));
        _trimMessages(_conversationHistory);
      }

      // ═══════════════════════════════════════════
      // 阶段2: 解析 (Parse) — 从 AI 响应中提取结构化动作
      // O8: 有结构化 tool_calls 时直接构造动作，不再走「JSON→文本→再解析」往返；
      // FC 模型回纯文本（没发 tool_calls）时自动落回文本协议解析。
      // ═══════════════════════════════════════════
      final step = fcCalls.isNotEmpty
          ? _stepFromFcCalls(fcCalls, fullResponse)
          : invalidFcCalls.isNotEmpty
              ? ReActStep(
                  thought: fullResponse.trim(),
                  action: null,
                  rawResponse: fullResponse,
                )
              : _parseReActResponse(fullResponse,
                  parsedEvents: _lastParsedResponseEvents);
      // 第一条之外、同一条响应里宣布的其余命令：解析事件缓存马上要清空，
      // 先取出来留给 _executeRemainingAnnouncedCommands 按 id 关联结果
      final announcedFollowUps =
          _remainingAnnouncedCommands(_lastParsedResponseEvents);
      // 首条已由主流程消费；按文本再过滤会吞掉明确声明要重复执行的同一命令。
      _announcedFollowUps = announcedFollowUps;
      _lastParsedResponseEvents = null;
      // 解析结果是排查用的内部细节：thought 可能上千字，默认日志里只留动作与首行摘要
      agentLogger.debug(
          'ReAct',
          '步骤 $_currentStepCount 解析: action=${step.action}, '
              'command=${step.command == null ? '-' : _logCommand(step.command!)}, '
              'thought=${step.thought.length > 80 ? '${step.thought.substring(0, 80)}…' : step.thought}');
      // 计划是持久状态：每次模型输出完整计划时替换，不追加快照
      if (step.plan != null && step.plan!.isNotEmpty) {
        _currentPlan = List<PlanStep>.unmodifiable(step.plan!);
      }

      // ═══════════════════════════════════════════
      // 阶段3: 行动 (Act) — 根据动作类型执行
      // ═══════════════════════════════════════════
      switch (step.action) {
        case ActionType.finish:
          // 协议要求提问走 ask，但部分模型会把“请回复选择 A 还是 B”写进
          // finish 正文：结果 UI 没有按钮，任务却在用户做决定前收尾。
          // 这里兜底转成真正的 ask，等用户点选后继续循环。
          final finishChoice = _choiceRequestFromFinish(step);
          if (finishChoice != null) {
            agentLogger.warn('ReAct',
                'finish 正文包含选择请求，转为 ask 等待用户选择: ${finishChoice.options}');
            if (step.options == null || step.options!.isEmpty) {
              // 选项: 行由流式解析器发过 ask；正文里提取的选项需要补发事件
              final askEvent =
                  AgentEvent.ask(finishChoice.question, finishChoice.options);
              _pendingAskEvent = askEvent;
              onEvent?.call(askEvent);
            }
            final shouldContinue = await _handleAskAction(
              ReActStep(
                thought: finishChoice.question,
                action: ActionType.ask,
                options: finishChoice.options,
                rawResponse: step.rawResponse,
              ),
              myGeneration: myGeneration,
            );
            if (!shouldContinue) return;
            continue;
          }
          // 防止 AI 幻觉：未执行任何命令/工具就 finish
          // 典型场景：AI 在 ask 后声称"已检查...无问题"但实际未运行任何命令
          // R5: 用独立计数器 _finishWithoutExecCount 限制重试次数，避免与
          // _noCommandRetryCount（无动作重试）互相干扰导致提前放行
          // 用户明确禁止执行命令时让路：纯问答任务的交付物就是文本答案
          // 模型显式声明"纯问答，无需执行命令"时同样让路：纯提问的回答
          // 依据是已有上下文，门控逼它执行命令只会答非所问（提示词规则 13/11）
          final declaresPureQa = step.thought.contains(_pureQaDeclaration) ||
              (step.answer?.contains(_pureQaDeclaration) ?? false);
          if (!_hasExecutedAnyCommand &&
              !_userForbadeCommands &&
              !declaresPureQa &&
              _finishWithoutExecCount < _maxFinishWithoutExecRetries) {
            _finishWithoutExecCount++;
            agentLogger.warn('ReAct',
                'AI 未执行任何命令就 finish，强制继续 (重试 $_finishWithoutExecCount/$_maxFinishWithoutExecRetries)');
            onEvent?.call(AgentEvent.info(UiText.t('⚠️ AI 未实际执行命令就声称完成，要求实际验证',
                '⚠️ Model claimed completion without running any command; asking it to verify first')));
            _conversationHistory.add(ChatMessage.create(
              role: 'user',
              content: '你尚未执行任何命令就声称任务完成，这不被允许。'
                  '如果任务需要实际操作/检查，请立即通过 execute 动作实际执行命令验证你的判断，'
                  '所有结论必须有命令输出作为依据。'
                  '如果用户的消息只是提问（问原因/原理/差异），本任务确属纯问答、无需执行命令，'
                  '请在思考开头写明"$_pureQaDeclaration"，'
                  '直接基于已有上下文回答用户的问题，然后再次 finish。',
            ));
            _trimMessages(_conversationHistory);
            continue;
          }
          if (!_hasExecutedAnyCommand && declaresPureQa) {
            agentLogger.info('ReAct', '模型声明纯问答（无需执行命令），finish 幻觉门控让路');
          }
          // O4/WP6: 计划完整性门控 — 计划仍有待处理/进行中项时不允许直接 finish。
          // 放在 finishChoice 转换与幻觉门控之后：先保证"真的执行过"，再保证"计划对齐"。
          // R5: 独立计数器 _planFinishRetryCount，最多提醒 2 次后放行（避免死循环）；
          // 只作用于 finish 分支 — maxSteps 耗尽/failed/cancel/pause 路径不经过这里。
          // 白名单判据：仅 pending/inProgress 拦截，completed/failed/skipped 均放行。
          final unfinishedPlanSteps = _currentPlan
              .where((s) =>
                  s.status == PlanStepStatus.pending ||
                  s.status == PlanStepStatus.inProgress)
              .toList();
          if (unfinishedPlanSteps.isNotEmpty &&
              _planFinishRetryCount < _maxPlanFinishRetries) {
            _planFinishRetryCount++;
            agentLogger.warn(
                'ReAct',
                '计划仍有 ${unfinishedPlanSteps.length} 个未完成项，要求更新计划后再 finish '
                    '(重试 $_planFinishRetryCount/$_maxPlanFinishRetries)');
            onEvent?.call(AgentEvent.info(UiText.t(
                '⚠️ 计划还有 ${unfinishedPlanSteps.length} 个未完成项，要求逐项核对后再收尾 '
                    '($_planFinishRetryCount/$_maxPlanFinishRetries)',
                '⚠️ Plan still has ${unfinishedPlanSteps.length} unfinished item(s); '
                    'asking to review each one before finishing '
                    '($_planFinishRetryCount/$_maxPlanFinishRetries)')));
            final unfinishedTitles =
                unfinishedPlanSteps.map((s) => '- ${s.title}').join('\n');
            _conversationHistory.add(ChatMessage.create(
              role: 'user',
              content: '计划中还有以下未完成项，不能直接 finish：\n'
                  '$unfinishedTitles\n'
                  '请对照计划逐项核对实际执行情况，输出完整计划块：已做的标完成 [x]，'
                  '未做/不需要做的标跳过 [-] 并在思考中说明原因，实际失败的标失败 [!]。'
                  '计划状态必须以命令输出为依据，不得把未执行的步骤标为完成。'
                  '更新计划后再使用 finish 动作收尾。',
            ));
            _trimMessages(_conversationHistory);
            continue;
          }
          agentLogger.info('ReAct', '任务完成 (AI 返回 finish 动作)');
          // 「回答:」块是面向用户的完整正文，进操作单结论层（answerBody）；
          // 四段字段只供结论/变更/建议解析，不能混进思考或证据折叠层。
          final answerText = step.answer?.trim() ?? '';
          final sections = step.sections?.trim() ?? '';
          final finishThought = step.thought.trim();
          final reportSummary = sections.isNotEmpty
              ? sections
              : (finishThought.isNotEmpty ? finishThought : null);
          _finishTask(
            summary: reportSummary,
            answer: answerText.isNotEmpty ? answerText : null,
          );
          return;

        case ActionType.ask:
          // 解析没产出 ask 事件时补一条：ask 事件是"问过什么、用户选了什么"
          // 在时间线里的唯一凭据，缺了它用户答完就什么都不剩
          if (!_lastResponseHadAskEvent &&
              step.options != null &&
              step.options!.isNotEmpty) {
            final askEvent = AgentEvent.ask(
              step.thought.trim().isEmpty
                  ? UiText.t('请选择', 'Choose one')
                  : step.thought.trim(),
              step.options!,
            );
            _pendingAskEvent = askEvent;
            onEvent?.call(askEvent);
            _lastResponseHadAskEvent = true;
          }
          final shouldContinue =
              await _handleAskAction(step, myGeneration: myGeneration);
          if (!shouldContinue) return;
          continue;

        case ActionType.execute:
          if (step.command == null || step.command!.trim().isEmpty) {
            // R10: fallback 提取需要模型显式声明了「动作: execute」。
            // 未声明的轮次（纯分析/答复正文）绝不从正文里猜命令 ——
            // 历史上曾把「binlog 位置: … → appvg-applv (57%)」这类带
            // 低中文占比+ASCII 关键词的分析行捞出来当命令执行（真机 -bash 报错）。
            if (!_declaresExecuteAction(fullResponse)) {
              agentLogger.info('ReAct', '未声明动作: execute，跳过 fallback 命令提取');
              final shouldContinue = await _handleNoCommand();
              if (!shouldContinue) return;
              continue;
            }
            // ReAct 解析出了 execute 但无命令 → fallback 到旧方式提取
            final fallbackCommands = _extractCommands(fullResponse);
            if (fallbackCommands.isNotEmpty) {
              agentLogger.info(
                  'ReAct', 'ReAct 格式无命令，旧方式提取 ${fallbackCommands.length} 条');
              final shouldContinue = await _handleExecuteCommands(
                  fallbackCommands, executor,
                  myGeneration: myGeneration);
              if (!shouldContinue) return;
              break;
            }
            // 两种方式都未提取到命令，发送继续提示
            final shouldContinue = await _handleNoCommand();
            if (!shouldContinue) return;
            continue;
          }
          final shouldContinue = await _handleExecuteAction(step, executor,
              myGeneration: myGeneration, earlyExecution: earlyExecution);
          if (!shouldContinue) return;

        case ActionType.tool:
          final shouldContinue = await _handleToolAction(step, executor,
              myGeneration: myGeneration);
          if (!shouldContinue) return;

        case null:
          // 空响应或只有思考内容 → 发送继续提示
          agentLogger.info('ReAct', 'AI 未返回有效动作，发送继续提示');
          final shouldContinue = await _handleNoCommand();
          if (!shouldContinue) return;
          continue;
      }

      // 检查任务是否被取消
      if (_currentTask?.status == AgentStatus.cancelled) {
        agentLogger.info('ReAct', '任务被取消');
        return;
      }
    }

    // 循环结束：可能是步数耗尽，也可能是无限制模式下 AI 主动 finish / noCommand 熔断
    // L1 修复：代际失效时不覆盖新任务状态
    if (myGeneration != _currentTaskGeneration) return;
    // R5: 步数耗尽是异常终止，应标记 failed 而非 completed
    // 标 completed 会误导用户以为任务成功完成
    // 无限制模式下永远不会 hitMaxSteps（循环只会因 finish/noCommand/cancel 退出）
    final hitMaxSteps = !isUnlimited && stepCount >= maxSteps;
    agentLogger.info('ReAct',
        '=== 执行结束 (步数: $stepCount/${isUnlimited ? "∞" : maxSteps}) ===');
    if (hitMaxSteps) {
      agentLogger.warn('ReAct', '达到最大执行步数 $maxSteps');
      onEvent?.call(AgentEvent.info(L10n.str.ut_478eec6181(maxSteps)));
    }

    // R5: 经 TerminationGuard 收口。步数耗尽=failed/interrupted；
    // 兜底 completed 分支原先只有 flush 无 report/finish（不可达的防御路径），
    // 统一走 Guard 补齐 report/finish，避免 UI 卡 running。
    _terminationGuard.terminate(
      status: hitMaxSteps ? AgentStatus.failed : AgentStatus.completed,
      finishState:
          hitMaxSteps ? AgentFinishState.interrupted : AgentFinishState.success,
      expectedGeneration: myGeneration,
      writeStatus: (status) {
        _currentTask = _currentTask!.copyWith(
          status: status,
          completedAt: DateTime.now(),
        );
        _notifyTaskUpdate();
      },
      emitReport: () {
        if (hitMaxSteps) {
          _emitOperationReport(finishState: AgentFinishState.interrupted);
        }
      },
      emitFinish: () {
        if (hitMaxSteps) {
          onEvent?.call(AgentEvent.finish(
            summary: L10n.str.taskMaxSteps,
            finishState: AgentFinishState.interrupted,
          ));
        }
      },
      flush: _accumulatedMessage.isEmpty
          ? null
          : () => onCompleted?.call(_accumulatedMessage),
    );

    // 清理编排取消令牌（ReAct 循环结束）
    _orchestratorCancelToken = null;
    final mhe2 = _tools.multiHostExecutor;
    if (mhe2 != null) {
      mhe2.cancelToken = null;
    }
  }

  /// 调用 AI 模型，流式返回完整响应
  /// [onCommandDetected] 可选回调：流式过程中检测到完整命令时触发，可用于提前执行
  /// [myGeneration] 任务代际，用于退避期间识别"取消 + 立即新任务"竞态
  /// 对可重试错误（429/connectionError/timeout）做指数退避重试，最多 3 次
  Future<String> _callAI({
    void Function(String command, String commandId)? onCommandDetected,
    int? myGeneration,
  }) async {
    agentLogger.info('ReAct', '调用 AI 模型...');
    agentLogger.debug('ReAct', '消息历史: ${_conversationHistory.length} 条');
    final aiTaskId = _currentTask?.id;
    final aiGeneration = myGeneration ?? _currentTaskGeneration;
    var streamTimedOut = false;
    StateError? responseOverflowError;
    _resetReasoning();
    // 不沿用上一轮的流超时标志：流建立阶段的异常不得被循环层误判为「流中途超时」
    _lastParsedResponseEvents = null;
    _lastFcToolCalls = const [];
    _lastInvalidFcCalls = const [];
    _announcedFollowUps = const [];
    _lastResponseHadAskEvent = false;

    final fullResponseBuffer = StringBuffer();
    // O8: 本轮收到的结构化 tool_calls（onToolCalls 回调写入，流结束后消费）
    final fcCalls = <ToolCall>[];
    final invalidFcCalls = <ToolCall>[];
    // 本轮是否按 FC 模式发送了 tools schema：是则正文里的代码围栏只是思考示例，
    // 不能当命令提前执行（命令一律以 tool_calls 为准）。
    var fcToolsSent = false;
    // 重试仅对流建立阶段有效，一旦开始接收 chunk 就不再重试
    Stream<String> stream;
    const maxRetries = 3;
    final backoffDelays = [
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 4)
    ];

    // 事件 id 状态提前到重试循环之前声明：onToolCalls 回调（在 chatStream 调用处
    // 创建闭包）也要用 assignFinalId 做提前执行的事件去重。
    // R4: 去重状态按调用作用域隔离，序号由 _eventStore 跨轮共享。
    int chunkCount = 0;
    final eventScope = _eventStore.newScope();
    bool commandDetectedNotified = false; // 是否已通知过命令检测（一轮只通知一次）
    // 流式提前执行的命令文本：流末全量解析若产出不同命令，stableId 会自动去重，
    // 但 UI 展示的会是后者、与实际执行的前者不一致。记录实际下发文本，流末检测
    // 到漂移时发一条 info 说明，让用户知道真正执行的是哪条（纯增量，不动状态机）。
    String? earlyExecutedCommand;

    // P1-4: Fallback 模型 — 主模型 maxRetries 次重试仍失败时切换备用模型重试一次
    var activeProvider = _aiProvider;
    var activeConfig = _modelConfig;
    var fallbackAttempted = false;
    int attempt = 0;
    CancelToken? activeToken;
    StreamSubscription<String>? streamSub;
    bool Function()? isCallbackActive;
    while (true) {
      // R1: 循环顶部先检查代际/取消，避免 cancelTask 后又立刻进入新一轮 chatStream 调用
      // 之前只在退避后检查，但首轮重试前没有检查，导致取消的任务仍会发起新请求
      if (!_isSameTask(aiGeneration, aiTaskId)) {
        throw StateError('任务已被新任务覆盖');
      }
      if (_currentTask?.status == AgentStatus.cancelled) {
        throw StateError('任务已取消');
      }
      attempt++;
      // P0-2: trace AI 调用开始
      final taskId = _currentTask?.id;
      if (taskId != null) {
        AgentTracer.instance.emitSync(TraceEvent(
          taskId: taskId,
          hostId: hostId,
          type: TraceEventType.aiCallStart,
          generation: myGeneration,
          step: _currentStepCount,
          payload: {
            'attempt': attempt,
            'retry': attempt > 1,
            'fallback': fallbackAttempted,
            'model': activeConfig.modelName,
            'history_len': _conversationHistory.length,
          },
        ));
      }
      try {
        // 不在此处加 .timeout()：底层 Dio 已配置 connectTimeout=30s / receiveTimeout=120s，
        // 用 .timeout() 抛 TimeoutException 时不会取消 Dio 请求，会导致连接泄漏。
        // 改用 CancelToken 机制：cancelTask 触发后立即关闭底层 HTTP 连接，毫秒级响应。
        // 每轮重试都创建新 token（旧 token 可能已被 cancel）。
        final token = CancelToken();
        activeToken = token;
        _aiCancelToken = token;
        bool callbackActive() {
          return !streamTimedOut &&
              responseOverflowError == null &&
              !token.isCancelled &&
              identical(_aiCancelToken, token) &&
              _isTaskActive(aiGeneration, aiTaskId);
        }

        isCallbackActive = callbackActive;

        // 一次请求算一轮（重试也计），与 trace 的 ai_call_count 同语义；
        // usage 按次判定，因为末包式 provider 只在流末给那一条
        _aiRounds++;
        _usageThisCall = false;
        // P2-6: 模型支持 FC 时，构建 tools schema 传入
        List<Map<String, dynamic>>? toolsSchema;
        if (activeConfig.supportsFunctionCalling) {
          toolsSchema =
              _tools.buildOpenAIToolsSchema(isLocalSession: _isLocalSession);
          if (toolsSchema.isEmpty) toolsSchema = null;
        }
        fcToolsSent = toolsSchema != null;
        stream = await activeProvider.chatStream(
          history: _conversationHistory,
          prompt: '',
          config: activeConfig,
          systemPrompt: null,
          cancelToken: token,
          responseTimeout: aiResponseTimeout,
          tools: toolsSchema,
          onUsage: (usage) {
            if (callbackActive()) _recordUsage(usage);
          },
          onReasoning: (delta) {
            if (callbackActive()) _handleReasoningDelta(delta);
          },
          onToolCalls: (calls) {
            // R1: 超时/取消/代际失效/终态后的迟到 FC 一律丢弃。
            if (!callbackActive()) return;
            for (final c in calls) {
              try {
                _decodeFcArgs(c.arguments);
                fcCalls.add(c);
              } on FormatException {
                // 非法参数只记账；此时可能仍在流中，不能提前写历史，超时重试
                // 会丢弃本轮。成功收流后再统一回灌观测。
                invalidFcCalls.add(c);
              }
            }
            _lastFcToolCalls = List.unmodifiable(fcCalls);
            // 提前执行：只有首个 tool_call 是 execute 才触发，与 _stepFromFcCalls
            // 只消费 calls.first 的语义对齐。若首个调用是其它工具，后续 execute
            // 本轮不会被执行，提前跑会变成"命令已执行但步骤结果丢失"的幽灵执行。
            if (onCommandDetected != null && !commandDetectedNotified) {
              final early = earlyExecuteCandidate(fcCalls);
              if (early != null) {
                final args = _decodeFcArgs(early.arguments);
                final cmd = (args['command'] ?? '').toString().trim();
                // 未闭合命令不提前执行：交给流结束后的全量解析，由
                // _executeCommand 的闭合预检统一拦截并回灌修正。
                if (_commandIsShellBalanced(cmd)) {
                  commandDetectedNotified = true;
                  earlyExecutedCommand = cmd;
                  final e = AgentEvent.command(
                    cmd,
                    id: ReActStreamParser.stableId(AgentEventType.command, cmd),
                    description: args['description']?.toString(),
                  );
                  final stableId = e.id;
                  final finalId = eventScope.assignFinalId(e);
                  _lastCommandEventId = finalId;
                  if (eventScope.isNew(stableId)) {
                    eventScope.markEmitted(stableId);
                    e.isStreaming = false;
                    _enrichCommandEvent(e);
                    onEvent?.call(e);
                  }
                  onCommandDetected(cmd, finalId);
                }
              }
            }
          },
        );
        // R1: chatStream 返回时可能用户已经点过停止。尤其是 OpenAI-compatible
        // 实现不保证立刻响应 CancelToken：若这里直接订阅新流，_aiDoneCompleter
        // 是在 cancelTask 之后才创建的，取消逻辑根本拿不到它，UI 会一直停在
        // “运行中”直到该流自行结束/超时。这里补一次终态检查。
        if (!callbackActive()) {
          throw StateError('任务已取消');
        }
        if (!_isSameTask(aiGeneration, aiTaskId)) {
          throw StateError('任务已被新任务覆盖');
        }
        break; // 成功建立流
      } catch (e) {
        if (!_isSameTask(aiGeneration, aiTaskId)) {
          throw StateError('任务已被新任务覆盖');
        }
        // 取消导致的异常不重试（重试会消耗新 API 配额且违背用户意图）
        if (_isCancellationError(e) ||
            activeToken?.isCancelled == true ||
            _currentTask?.status == AgentStatus.paused ||
            _currentTask?.status == AgentStatus.cancelled) {
          rethrow;
        }
        if (attempt > maxRetries || !_isRetryableError(e)) {
          // P1-4: 主模型重试耗尽，切换到 fallback 模型重试一次
          if (!fallbackAttempted &&
              _fallbackProvider != null &&
              _fallbackConfig != null) {
            agentLogger.warn('ReAct',
                '主模型 ${activeConfig.modelName} 重试 $attempt 次仍失败，切换 fallback 模型 ${_fallbackConfig!.modelName}: $e');
            fallbackAttempted = true;
            attempt = 0;
            activeProvider = _fallbackProvider!;
            activeConfig = _fallbackConfig!;
            // 通知 UI：模型已切换
            onEvent?.call(AgentEvent.info(L10n.str.ut_fa2224f3f9(
                _modelConfig.modelName, activeConfig.modelName)));
            continue;
          }
          rethrow;
        }
        agentLogger.warn('ReAct',
            'AI 流建立失败（第 $attempt 次），${backoffDelays[attempt - 1].inSeconds}s 后重试: $e');
        await Future.delayed(backoffDelays[attempt - 1]);
        // R1: 退避期间任务可能被取消或被新任务覆盖
        // 旧实现只检查 status==cancelled，无法识别"cancel + 立即 startTask"场景
        // （新任务把 status 重置为 thinking，旧检查会通过，导致旧任务继续发起新 chatStream
        // 调用、消耗 API 配额、并把旧响应通过 onMessage 写到新任务的 UI 流）
        // 修复：同时检查代际和取消状态，任一失效都放弃重试
        if (!_isSameTask(aiGeneration, aiTaskId)) {
          agentLogger.info('ReAct', '退避期间代际已变更（新任务已启动），放弃重试');
          throw StateError('任务已被新任务覆盖');
        }
        if (_currentTask?.status == AgentStatus.cancelled) {
          agentLogger.info('ReAct', '退避期间任务被取消，放弃重试');
          throw StateError('任务已取消');
        }
      }
    }

    // 流式提前检测命令：全量解析很贵，限制在 150ms 一次，且只有出现
    // 「命令:」或围栏代码块迹象时才解析；纯推理流不再逐 chunk 重解析。
    // 另加增长门槛（至少新增 64 字符才重解析）和长度上限：最终回答含代码
    // 围栏但永远没有完整命令时，避免整轮对增长中的全文反复 parse+哈希（O(n²)）。
    // 超过上限只是放弃"提前执行"优化，流结束后的全量解析仍会正常执行命令。
    const earlyParseIntervalMs = 150;
    const earlyParseMinGrowth = 64;
    const earlyParseMaxChars = 16384;
    final earlyParseStopwatch = Stopwatch()..start();
    var lastEarlyParseAtMs = -earlyParseIntervalMs;
    var lastEarlyParseLen = 0;
    // watchdog 已改为实例字段 _aiWatchdog

    // 超时看门狗：用实例字段以便 cancelTask 取消
    final doneCompleter = Completer<void>();
    _aiDoneCompleter = doneCompleter;
    Timer? watchdog;
    void resetWatchdog() {
      watchdog?.cancel();
      final timer = Timer(aiResponseTimeout, () {
        if (isCallbackActive?.call() != true) return;
        streamTimedOut = true;
        agentLogger.error(
            'ReAct', 'AI 流式输出超时（${aiResponseTimeout.inSeconds}s 无数据），强制中断');
        // 必须同时取消 HTTP token；只 cancel stream subscription 无法终止 Dio
        // 上游连接，也无法保证 provider 不再投递迟到 tool_calls。
        activeToken?.cancel('AI 流式输出超时');
        streamSub?.cancel();
        if (!doneCompleter.isCompleted) doneCompleter.complete();
      });
      watchdog = timer;
      _aiWatchdog = timer;
    }

    resetWatchdog();

    streamSub = stream.listen(
      (chunk) {
        if (isCallbackActive?.call() != true) return;
        resetWatchdog();
        chunkCount++;
        if (fullResponseBuffer.length + chunk.length > _maxAiResponseChars) {
          responseOverflowError =
              StateError('AI 响应超过 $_maxAiResponseChars 字符上限，已丢弃，禁止执行截断内容');
          agentLogger.error('ReAct', responseOverflowError!.message);
          // 不静默保留尾部：截断可能破坏 ReAct/heredoc 协议。取消上游并让
          // 本轮以 failed 收口，任何已收到的半截响应都不进入历史。
          activeToken?.cancel('AI 响应超过字符上限');
          streamSub?.cancel();
          if (!doneCompleter.isCompleted) {
            doneCompleter.completeError(responseOverflowError!);
          }
          return;
        }
        fullResponseBuffer.write(chunk);
        // B5: 限制累积消息增长，超出上限只保留尾部
        _accumulatedMessageBuffer.write(chunk);
        onMessage?.call(chunk);

        // 流式过程中检测完整命令：立即发出 command 事件 + 触发提前执行。
        // FC 模式下跳过：正文围栏是思考示例，命令只认 tool_calls（onToolCalls 回调）。
        if (onCommandDetected != null &&
            !commandDetectedNotified &&
            !fcToolsSent) {
          final elapsed = earlyParseStopwatch.elapsedMilliseconds;
          final bufLen = fullResponseBuffer.length;
          // 短命令也可能要求提前执行；只要本 chunk 明确带命令标记，就不受
          // 64 字符增长门槛限制（否则 `echo hi` 这类短命令永远等流结束）。
          final hasCommandHint = chunk.contains('命令:') ||
              chunk.contains('命令：') ||
              chunk.contains('```');
          if (elapsed - lastEarlyParseAtMs >= earlyParseIntervalMs &&
              (hasCommandHint ||
                  bufLen - lastEarlyParseLen >= earlyParseMinGrowth) &&
              bufLen <= earlyParseMaxChars) {
            final responseText = fullResponseBuffer.toString();
            // 只解析 `动作:` 行之后的正文：解析器把任意围栏当成 command，
            // 思考里的示例围栏（或 ask/finish 轮的文件摘录）会抢在真正的
            // `命令:` 之前被送进执行器（真机验证：ask 轮把端口配置片段执行了）。
            // 未声明 execute 的流不提前执行，交给流结束后的全量解析。
            final tail = _textFromDeclaredAction(responseText);
            // 没有命令行/代码围栏时解析不可能产出 command 事件，直接跳过
            if (tail != null &&
                (tail.contains('命令:') ||
                    tail.contains('命令：') ||
                    tail.contains('```'))) {
              lastEarlyParseAtMs = elapsed;
              lastEarlyParseLen = bufLen;
              final parsed = ReActStreamParser.parseWithState(tail);
              final currentEvents = parsed.events;
              // 找第一个已确定完成的 command 事件（不是最后一个）。
              // 末条命令若仍处于未闭合的命令字段/围栏（openCommand），
              // 继续等后续 chunk，避免把半条命令提前下发。
              final settledCount =
                  currentEvents.length - (parsed.openCommand ? 1 : 0);
              for (int i = 0; i < settledCount; i++) {
                final e = currentEvents[i];
                if (e.isCommand) {
                  final cmd = e.command ?? '';
                  if (cmd.isNotEmpty && _commandIsShellBalanced(cmd)) {
                    commandDetectedNotified = true;
                    earlyExecutedCommand = cmd;
                    // A5 修复：先记录 stableId，再改写为 finalId
                    final stableId = e.id;
                    final finalId = eventScope.assignFinalId(e);
                    _lastCommandEventId = finalId;
                    // 立即发出 command 事件，让 UI 先显示命令块
                    if (eventScope.isNew(stableId)) {
                      eventScope.markEmitted(stableId);
                      e.id = finalId;
                      e.isStreaming = false;
                      _enrichCommandEvent(e);
                      onEvent?.call(e);
                    }
                    onCommandDetected(cmd, finalId);
                    break;
                  }
                }
              }
            }
          }
        }
      },
      onError: (e) {
        if (doneCompleter.isCompleted) return;
        if (isCallbackActive?.call() == true) {
          doneCompleter.completeError(e);
        } else {
          doneCompleter.complete();
        }
      },
      onDone: () {
        if (!doneCompleter.isCompleted) doneCompleter.complete();
      },
      cancelOnError: true,
    );
    _aiStreamSub = streamSub;

    // 超时也会 cancel token，但它是超时而非用户取消，必须走下方超时重试分支。
    try {
      await doneCompleter.future;
    } catch (e) {
      // 超时 token 的取消错误是超时信号的副产品，不能转成"用户取消"；
      // 吞掉本次 error 后由下方局部 streamTimedOut 分支统一重试/失败。
      if (responseOverflowError != null) {
        rethrow;
      } else if (streamTimedOut) {
        // 继续进入 finally，等待本轮 subscription 完全取消后再重试。
        agentLogger.debug('ReAct', 'AI 超时后收到取消错误，转入超时重试分支');
      } else if ((activeToken.isCancelled && !streamTimedOut) ||
          _isCancellationError(e)) {
        throw StateError('任务已取消');
      } else {
        rethrow;
      }
    } finally {
      watchdog?.cancel();
      if (identical(_aiWatchdog, watchdog)) _aiWatchdog = null;
      // 等待本轮局部 subscription，而不是可能已被 cancelTask 置空的实例引用。
      await streamSub.cancel();
      if (identical(_aiStreamSub, streamSub)) _aiStreamSub = null;
      if (_aiDoneCompleter == doneCompleter) _aiDoneCompleter = null;
      if (identical(_aiCancelToken, activeToken)) _aiCancelToken = null;
      isCallbackActive = null;
    }

    // cancel()/pause() 自身可跨异步边界；恢复后先确认仍是原任务，再发任何事件/改历史。
    if (!_isSameTask(aiGeneration, aiTaskId)) {
      throw StateError('任务已被新任务覆盖');
    }
    final wasCancelled = activeToken.isCancelled && !streamTimedOut;
    if (_currentTask?.status == AgentStatus.paused && !streamTimedOut) {
      throw StateError('任务已暂停');
    }

    // 取消导致的提前结束：抛 StateError 让外层 catch 走取消路径
    // 不抛 TimeoutException（那是超时场景）— 区分路径避免误报
    if (wasCancelled) {
      throw StateError('任务已取消');
    }

    // 流中途超时：一律丢弃半截响应重试，即使缓冲非空（§5.3）。
    // 半截响应当完整响应用会出事：流尾解析会把写了一半的 heredoc 命令 flush 成
    // command 事件发给执行器，远端 shell 干等 EOF 到命令超时。
    // 重试用尾递归（新栈帧=全新局部状态，半截 buffer/去重集不流入下一轮），
    // 上限 2 次防网络抖动烧配额；提前执行已触发时不可重试——命令已经发出去了，
    // 重试会二次执行，退回抛错走 failed 路径（与历史行为一致）。
    if (streamTimedOut) {
      final canRetry = !commandDetectedNotified && _aiStreamTimeoutRetries < 2;
      agentLogger.warn(
          'AI',
          'AI 流超时，丢弃已收 ${fullResponseBuffer.length} 字符'
              '（${canRetry ? '重试第 ${_aiStreamTimeoutRetries + 1}/2 次' : '不再重试'}）');
      if (!canRetry) {
        throw TimeoutException('AI 响应超时（${aiResponseTimeout.inSeconds}s 无数据）');
      }
      _aiStreamTimeoutRetries++;
      // 实例级残留清理：被丢弃的半截不得进入重试轮的观测/历史
      _accumulatedMessageBuffer.clear();
      _lastFcToolCalls = const [];
      _lastInvalidFcCalls = const [];
      // UI 桥：丢弃当前轮 streamingContent（不并入 content），重试正文从零开始
      onStreamDiscarded?.call();
      await Future.delayed(const Duration(seconds: 1));
      // R1: 退避期间取消/代际变更则放弃重试
      if (!_isSameTask(aiGeneration, aiTaskId)) {
        throw StateError('任务已被新任务覆盖');
      }
      if (_currentTask?.status == AgentStatus.cancelled) {
        throw StateError('任务已取消');
      }
      // 退避窗口内用户可能已暂停：暂停状态下不能再发下一轮 API 请求。
      if (_currentTask?.status == AgentStatus.paused) {
        throw StateError('任务已暂停');
      }
      return _callAI(
        onCommandDetected: onCommandDetected,
        myGeneration: myGeneration,
      );
    }

    _lastInvalidFcCalls = List.unmodifiable(invalidFcCalls);
    for (final call in invalidFcCalls) {
      onEvent?.call(AgentEvent.info(_invalidFcObservation(call)));
    }

    final fullResponse = fullResponseBuffer.toString();

    // 流式结束：一次性发出所有事件（e.id 此时是 stableId）
    final events = ReActParser.parseEvents(fullResponse);

    // 解析器把任意围栏都产出为 command 事件，但只有 `动作: execute` 之后的
    // 内容才是本轮真正要执行的命令：
    // - 动作行之前的围栏是思考示例
    // - finish/ask 轮正文里的围栏是文件摘录（真机验证曾把 sshd_config 的
    //   15 行内容逐行执行成 `-bash: L1: command not found`）
    final declaredAction = _declaredTextAction(fullResponse);
    final commandScope = _textFromDeclaredAction(fullResponse);
    if (declaredAction == ActionType.execute && commandScope != null) {
      final scopedCommands = ReActParser.parseEvents(commandScope)
          .where((e) => e.isCommand)
          .toList();
      final firstCmdIdx = events.indexWhere((e) => e.isCommand);
      events.removeWhere((e) => e.isCommand);
      if (scopedCommands.isNotEmpty) {
        events.insertAll(
            firstCmdIdx < 0 ? events.length : firstCmdIdx, scopedCommands);
      }
    } else if (declaredAction != null) {
      events.removeWhere((e) => e.isCommand);
    } else {
      // R10: 正文里没有任何 `动作:` 行 → 本轮没有执行意图，一律不执行命令。
      // 此前无动作行时围栏命令原样保留并被默认当成 execute，真机上把
      // 「binlog 位置: … → appvg-applv (/app, 57%)」这类贴回正文的分析
      // 文本逐行敲进了终端（-bash: command not found / syntax error）。
      // 模型想执行必须声明 动作: execute；缺失时交给 _handleNoCommand
      // 的格式提示重试，弱模型一轮即可回到协议。
      final dropped = events.where((e) => e.isCommand).length;
      if (dropped > 0) {
        agentLogger.info('ReAct', '未声明动作行，丢弃 $dropped 条围栏/命令事件不执行');
        events.removeWhere((e) => e.isCommand);
      }
    }

    // 非法 FC 参数且没有任何合法调用时，本轮不执行任何工具；正文即使含
    // ReAct 示例也不能退回文本协议执行。
    if (invalidFcCalls.isNotEmpty && fcCalls.isEmpty) {
      events.removeWhere((e) => e.isCommand || e.isAsk);
    }

    // O8 FC-first：结构化 tool_calls 合并进事件流。
    // FC 模式下正文是思考而非协议文本：纯文本解析出的 text 事件换成一条 thought，
    // 计划块事件保留（WP6 的计划跟踪/finish 门控依赖文本计划块约定）。
    if (fcCalls.isNotEmpty) {
      final body = fullResponse.trim();
      // 正文里的围栏/协议行只是思考示例或降级残留：命令与提问一律以
      // 结构化调用为准，文本解析出的 command/ask/text 事件全部丢弃，
      // 只保留计划块（WP6 约定）与思考。
      events.removeWhere(
          (e) => e.type == AgentEventType.text || e.isCommand || e.isAsk);
      if (body.isNotEmpty && !events.any((e) => e.isThought)) {
        events.insert(
            0,
            AgentEvent.thought(body,
                id: ReActStreamParser.stableId(AgentEventType.thought, body)));
      }
      for (var i = 0; i < fcCalls.length; i++) {
        final c = fcCalls[i];
        final args = _decodeFcArgs(c.arguments);
        if (c.name == 'execute') {
          final cmd = (args['command'] ?? '').toString().trim();
          if (cmd.isNotEmpty) {
            // stableId 与提前执行回调里一致：已发过的在这里被去重跳过
            events.add(AgentEvent.command(
              cmd,
              id: ReActStreamParser.stableId(AgentEventType.command, cmd),
              description: args['description']?.toString(),
            ));
          }
        } else if (c.name == 'ask') {
          final question = (args['question'] ?? '').toString().trim();
          final options = args['options'] is List
              ? (args['options'] as List).map((e) => e.toString()).toList()
              : <String>[];
          if (question.isNotEmpty && options.isNotEmpty) {
            events.add(AgentEvent.ask(
              question,
              options,
              id: ReActStreamParser.stableId(
                  AgentEventType.ask, '$question|${options.join('|')}'),
            ));
          }
        }
        // finish 事件由 _finishTask 统一发出；注册工具由 _handleToolAction
        // 自己发命令事件 —— 都不在这里预发。
        // 每轮只执行第一个动作：多余的 execute 走既有 _announcedFollowUps
        // 机制逐条执行，其余多余调用忽略并提示。
        if (i > 0 && c.name != 'execute') {
          events.add(AgentEvent.info(L10n.str.ut_971883a7fe(c.name)));
        }
      }
    }

    _lastParsedResponseEvents = events;
    // 本轮解析是否已产出 ask 事件：没有的话 _handleAskAction 开头要补一条，
    // 否则用户答完问题，时间线里连"问过什么、选了什么"都找不到
    _lastResponseHadAskEvent = events.any((e) => e.isAsk);

    // 流式结束：把累积的推理固化为持久的「思考」事件。
    // ReAct 响应本身已带「思考:」行时不再补：双语模型会在 reasoning_content 里
    // 用英文推理、又在协议行里用中文写一遍，两条都留就是同一步思考出现两次。
    // 流式期间顶部/时间线末尾的实时推理行已经让它被看到过，这里只留协议思考。
    if (_reasoningBuffer.isNotEmpty) {
      final reasoning = _reasoningBuffer.toString().trim();
      _reasoningBuffer.clear();
      final reactHasThought = events.any((e) => e.isThought);
      if (reasoning.isNotEmpty && !reactHasThought) {
        onEvent?.call(AgentEvent.thought(reasoning));
      }
    }
    // 收起顶部的瞬时推理块
    onReasoning?.call('');
    // L10 修复：只记录第一个 command 事件的 id（主流程只执行第一个命令）
    bool firstCommandIdSet = false;
    for (final e in events) {
      final stableId = e.id;
      if (eventScope.isNew(stableId)) {
        eventScope.markEmitted(stableId);
        eventScope.assignFinalId(e); // 此处会改写 e.id 为 finalId
        e.isStreaming = false;
        _enrichCommandEvent(e);
        // 记住本轮的提问事件：用户作答后要把选择回写上去，
        // 让"问过什么 + 选了什么"留在同一个事件里，不靠事后扫描推断。
        if (e.isAsk) _pendingAskEvent = e;
        onEvent?.call(e);
      } else {
        // 已发过，确保 _lastCommandEventId 用 finalId
        e.id = eventScope.finalIdFor(stableId);
      }
      if (e.isCommand && !firstCommandIdSet) {
        _lastCommandEventId = eventScope.finalIdFor(stableId);
        firstCommandIdSet = true;
      }
    }

    // 提前执行与最终首条命令必须完全一致；否则继续解析会执行 B，并把已执行的 A
    // 当 follow-up 再跑一次。漂移时停止本轮，绝不基于不确定的最终序列继续下发。
    if (earlyExecutedCommand != null) {
      final executed = earlyExecutedCommand!.trim();
      final finalCommands = events
          .where((e) => e.isCommand)
          .map((e) => (e.command ?? '').trim())
          .toList();
      if (finalCommands.isEmpty || finalCommands.first != executed) {
        agentLogger.warn('ReAct',
            '流式提前执行与流末首条命令不一致，停止后续执行: ${_logCommand(earlyExecutedCommand!)}');
        onEvent?.call(AgentEvent.info(UiText.t(
          '⚠️ 命令在流式生成过程中发生变化，已停止后续执行以避免误执行或重复执行。请以先下发的版本执行结果为准。',
          'The command changed during streaming. Further execution was stopped to avoid unintended or duplicate commands. Trust the earlier execution result.',
        )));
        throw StateError('流式提前执行与最终命令不一致，已停止后续执行');
      }
    }

    // 如果流式过程中没检测到命令（命令在最后），现在也通知一下。
    // O8: FC 模式下命令只认 tool_calls —— 正文围栏/引用块只是思考示例或
    // 文件内容摘录，绝不能当命令执行（真机验证曾把 sshd_config 的围栏内容
    // 直接写进远端 PTY）。
    if (!commandDetectedNotified && onCommandDetected != null && !fcToolsSent) {
      for (final e in events) {
        if (e.isCommand) {
          final cmd = e.command ?? '';
          if (cmd.isNotEmpty) {
            commandDetectedNotified = true;
            final finalId = eventScope.finalIdFor(e.id);
            _lastCommandEventId = finalId;
            onCommandDetected(cmd, finalId);
            break;
          }
        }
      }
    }

    agentLogger.info(
        'ReAct', 'AI 响应完成，共 $chunkCount 个数据块，${fullResponse.length} 字符');
    // P0-2 + P1-3: trace AI 调用结束，附 token 估算
    final endTaskId = _currentTask?.id;
    if (endTaskId != null) {
      // 估算 prompt tokens：system 消息 + 对话历史 + 当前 prompt
      // 注意：这里只能粗估，因为 system prompt 在 provider 层构建
      final promptTokens = TokenEstimator.estimateHistory(_conversationHistory);
      final completionTokens = TokenEstimator.estimateText(fullResponse);
      // 本轮拿到真实 usage 就不再记估算值，否则界面那个数字会把估算混进实测；
      // 没拿到的轮次仍要计入总量，否则长任务会显示比实际小得多的用量
      if (!_usageThisCall) {
        _tokEstimated += promptTokens + completionTokens;
        // 本轮没有真实 usage，就用本轮的估算描述上下文规模（最近一轮说了算）
        _contextTokens = promptTokens;
      }
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: endTaskId,
        hostId: hostId,
        type: TraceEventType.aiCallEnd,
        generation: myGeneration,
        step: _currentStepCount,
        payload: {
          'chunks': chunkCount,
          'chars': fullResponse.length,
          'attempt': attempt,
          'retry': attempt > 1,
          'fallback': fallbackAttempted,
          'model': activeConfig.modelName,
          'fc_calls': fcCalls.length,
          'prompt_tokens': promptTokens,
          'completion_tokens': completionTokens,
        },
      ));
    }
    return fullResponse;
  }

  /// ═══════════════════════════════════════════════════════
  /// O8 FC-first — 结构化 tool_calls → 动作
  /// ═══════════════════════════════════════════════════════

  /// 解码 FC arguments JSON。累积器只修复可安全补齐的尾括号；这里必须显式
  /// 拒绝非法 JSON/非 object，不能再静默退化成 `{}` 让工具带着空参数执行。
  static Map<String, dynamic> _decodeFcArgs(String arguments) {
    final Object? decoded;
    try {
      decoded = jsonDecode(arguments);
    } on FormatException catch (e) {
      throw FormatException('arguments 非法：必须是 JSON object（${e.message}）');
    }
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const FormatException('arguments 非法：必须是 JSON object');
  }

  static String _invalidFcObservation(ToolCall call) =>
      '观测: 工具 ${call.name} 的 arguments 非法（必须是 JSON object），未执行，请重新提交。';

  @visibleForTesting
  static Map<String, dynamic> decodeFcArgsForTesting(String arguments) =>
      _decodeFcArgs(arguments);

  /// 提前执行候选：仅当首个 tool_call 是 execute 且命令非空时返回。
  /// [_stepFromFcCalls] 只消费 calls.first；若首个调用是其它工具，后续
  /// execute 本轮不会被执行，提前下发会变成"执行了但结果丢失"的幽灵命令。
  @visibleForTesting
  static ToolCall? earlyExecuteCandidate(List<ToolCall> calls) {
    if (calls.isEmpty || calls.first.name != 'execute') return null;
    final args = _decodeFcArgs(calls.first.arguments);
    final cmd = (args['command'] ?? '').toString().trim();
    return cmd.isEmpty ? null : calls.first;
  }

  /// finish 工具的四段字段 → 操作单文本（与文本协议 parseReportSections 的输出同形）
  static String? _fcFinishSections(Map<String, dynamic> args) {
    final buffer = StringBuffer();
    void add(String label, String key) {
      final v = (args[key] ?? '').toString().trim();
      if (v.isNotEmpty) buffer.writeln('$label: $v');
    }

    add('结论', 'conclusion');
    add('现状', 'status');
    add('变更', 'changes');
    add('建议', 'suggestion');
    final s = buffer.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// 从结构化 tool_calls 构造 ReActStep：第一个调用决定本轮动作。
  /// thought 取正文全文；plan 取正文里解析出的计划块（保留 WP6 文本约定）。
  ReActStep _stepFromFcCalls(List<ToolCall> calls, String text) {
    final thought = text.trim();
    List<PlanStep>? plan;
    for (final e in _lastParsedResponseEvents ?? const <AgentEvent>[]) {
      if (e.isPlan && e.planSteps != null && e.planSteps!.isNotEmpty) {
        // 同一响应里出现多份计划时，最后一份是最新状态
        plan = e.planSteps;
      }
    }
    final first = calls.first;
    final args = _decodeFcArgs(first.arguments);
    switch (first.name) {
      case 'execute':
        final cmd = (args['command'] ?? '').toString().trim();
        return ReActStep(
          thought: thought,
          action: cmd.isEmpty ? null : ActionType.execute,
          command: cmd.isEmpty ? null : cmd,
          plan: plan,
          rawResponse: text,
        );
      case 'finish':
        final answer = (args['answer'] ?? '').toString().trim();
        return ReActStep(
          thought: thought,
          action: ActionType.finish,
          plan: plan,
          answer: answer.isEmpty ? null : answer,
          sections: _fcFinishSections(args),
          rawResponse: text,
        );
      case 'ask':
        final question = (args['question'] ?? '').toString().trim();
        final options = args['options'] is List
            ? (args['options'] as List).map((e) => e.toString()).toList()
            : <String>[];
        return ReActStep(
          thought: question.isEmpty ? thought : question,
          action: ActionType.ask,
          options: options,
          plan: plan,
          rawResponse: text,
        );
      default:
        // 注册工具（含 think/execute 等别名）：交给 _handleToolAction 路由。
        // 参数是原生 JSON 类型（bool/num/List），ToolArgs 类型化访问器统一收口（R9）。
        return ReActStep(
          thought: thought,
          action: ActionType.tool,
          toolName: first.name,
          toolArgs: args,
          plan: plan,
          rawResponse: text,
        );
    }
  }

  /// FC 动作按文本协议格式记入历史：模型（含 fallback 非 FC 模型）能读到
  /// 自己上一轮做了什么。这段文本只进历史，不参与本轮解析。
  static String _fcCallsToHistoryText(List<ToolCall> calls) {
    final buffer = StringBuffer();
    for (final c in calls) {
      final args = _decodeFcArgs(c.arguments);
      switch (c.name) {
        case 'execute':
          {
            buffer.writeln('\n动作: execute');
            final desc = (args['description'] ?? '').toString().trim();
            if (desc.isNotEmpty) buffer.writeln('说明: $desc');
            buffer.writeln('命令: ${(args['command'] ?? '').toString().trim()}');
          }
        case 'finish':
          {
            buffer.writeln('\n动作: finish');
            final answer = (args['answer'] ?? '').toString().trim();
            if (answer.isNotEmpty) buffer.writeln('回答: $answer');
            final sections = _fcFinishSections(args);
            if (sections != null) buffer.writeln(sections);
          }
        case 'ask':
          {
            buffer.writeln('\n动作: ask');
            final question = (args['question'] ?? '').toString().trim();
            if (question.isNotEmpty) buffer.writeln(question);
            final options = args['options'] is List
                ? (args['options'] as List).map((e) => e.toString()).join(' | ')
                : '';
            if (options.isNotEmpty) buffer.writeln('选项: $options');
          }
        default:
          buffer.write(ToolCallAccumulator.toReActText([c]));
      }
    }
    return buffer.toString();
  }

  /// ═══════════════════════════════════════════════════════
  /// ReAct 解析器 — 转发到 [ReActParser]
  ///
  /// 解析实现已抽到 lib/services/react_parser.dart（纯静态、零实例状态）。
  /// 这里保留同名转发壳，使引擎内部调用点与既有测试无需改动。
  /// ═══════════════════════════════════════════════════════
  static ActionType? _declaredTextAction(String content) =>
      ReActParser.declaredTextAction(content);

  static bool _declaresExecuteAction(String content) =>
      ReActParser.declaresExecuteAction(content);

  static String? _textFromDeclaredAction(String content) =>
      ReActParser.textFromDeclaredAction(content);

  ReActStep _parseReActResponse(String content,
          {List<AgentEvent>? parsedEvents}) =>
      ReActParser.parseReActResponse(content, parsedEvents: parsedEvents);

  static String? parseAnswerBlock(List<String> lines) =>
      ReActParser.parseAnswerBlock(lines);

  static String? parseReportSections(List<String> lines) =>
      ReActParser.parseReportSections(lines);

  /// 动作行识别三件套的测试入口（N1：混用冒号/带注解值的回归覆盖）。
  @visibleForTesting
  static ({
    ActionType? declared,
    bool executes,
    String? scopeText
  }) declaredActionForTest(String content) =>
      ReActParser.declaredActionForTest(content);

  /// 解析 "动作: tool" 行之后的 工具: 和 参数: 行。
  /// 返回 (toolName, toolArgs)，未找到时对应字段为 null。
  static (String?, Map<String, dynamic>?) parseToolAction(
          List<String> lines, int startIndex) =>
      ReActParser.parseToolAction(lines, startIndex);

  /// ═══════════════════════════════════════════════════════
  /// 处理 execute 动作 — 执行单条命令并返回观测
  /// ═══════════════════════════════════════════════════════
  /// 返回 true 表示继续循环，false 表示应退出
  Future<bool> _handleExecuteAction(ReActStep step, CommandExecutor executor,
      {required int myGeneration, _EarlyExecutionSlot? earlyExecution}) async {
    final command = step.command!.trim();
    final taskId = _currentTask?.id;

    // 提前执行槽由本轮 _callAI 局部持有；只消费命令文本与任务身份都匹配的槽。
    final slot = earlyExecution;
    if (slot != null && slot.command != command) {
      throw StateError('提前执行命令与最终命令不一致，拒绝继续执行');
    }
    if (slot != null) {
      final result = await slot.completer.future;
      if (!_isSameTask(myGeneration, taskId)) return false;
      if (!_isTaskActive(myGeneration, taskId) || !result.shouldContinue) {
        return false;
      }
      // 把观测加入对话历史
      if (result.observation != null) {
        _conversationHistory.add(
            ChatMessage.create(role: 'user', content: result.observation!));
        _trimMessages(_conversationHistory);
      }
      return _executeRemainingAnnouncedCommands(executor,
          myGeneration: myGeneration);
    }

    final result = await _runCommandWithSafety(command, executor,
        myGeneration: myGeneration);
    if (!_isTaskActive(myGeneration, taskId) || !result.shouldContinue) {
      return false;
    }
    if (result.observation != null) {
      _conversationHistory
          .add(ChatMessage.create(role: 'user', content: result.observation!));
      _trimMessages(_conversationHistory);
    }
    return _executeRemainingAnnouncedCommands(executor,
        myGeneration: myGeneration);
  }

  /// 执行本条 AI 响应里宣布的、第一条之外的其余命令。
  ///
  /// ReAct 协议是"一步一动作"，但模型经常一次列出多条诊断命令
  /// （journalctl / docker ps / systemctl status …）。解析器把每条 `命令:` 都
  /// 发成了 command 事件，而引擎只跑第一条——其余的在时间线上变成永远没有
  /// 结果的"可执行"悬空块，用户分不清它们到底跑没跑。这里按宣布顺序把剩余
  /// 命令也跑掉：逐条过 SafetyGuard（危险命令照常确认/拦截），结果挂到各自
  /// 已发出的 command 事件 id 上，观测一并进对话历史。
  Future<bool> _executeRemainingAnnouncedCommands(
    CommandExecutor executor, {
    required int myGeneration,
  }) async {
    const maxFollowUps = 10;
    final taskId = _currentTask?.id;
    bool active() => _isTaskActive(myGeneration, taskId);
    final followUps = _announcedFollowUps;
    _announcedFollowUps = const [];
    var ran = 0;
    // 超上限时不再静默丢弃：记录被跳过的命令，末尾发一条可见提示并写入观测，
    // 让 AI/用户知道还有命令没执行，避免时间线出现"声明了却没跑"的悬空块。
    final skipped = <String>[];
    for (final c in followUps) {
      // 取消检查放在最前：否则超过上限后的 continue 会绕过它，
      // 在用户已停止的轮次里仍然追加"还有 N 条未执行"的提示与历史。
      if (!active()) break;
      if (ran >= maxFollowUps) {
        skipped.add(c.command);
        continue;
      }
      ran++;
      final r = await _runCommandWithSafety(c.command, executor,
          commandId: c.eventId, myGeneration: myGeneration);
      if (!active()) return false;
      if (!r.shouldContinue) return false;
      if (r.observation != null) {
        _conversationHistory
            .add(ChatMessage.create(role: 'user', content: r.observation!));
        _trimMessages(_conversationHistory);
      }
    }
    if (skipped.isNotEmpty && active()) {
      agentLogger.warn('ReAct', '本轮命令数超过上限，${skipped.length} 条未执行');
      onEvent?.call(AgentEvent.info(UiText.t(
        '⚠️ 本轮声明了 ${skipped.length} 条额外命令，超过单次执行上限（$maxFollowUps），未执行。请分批提交。',
        '${skipped.length} additional commands exceeded the per-turn limit ($maxFollowUps) and were skipped. Submit them in smaller batches.',
      )));
      // 写入对话历史：让 AI 在下一轮知道哪些命令还没跑，避免重复声明或遗漏
      _conversationHistory.add(ChatMessage.create(
        role: 'user',
        content: '以下 ${skipped.length} 条命令因单轮上限未执行，需要时请在后续步骤中单独提交：\n'
            '${skipped.map((c) => '- $c').join('\n')}',
      ));
      _trimMessages(_conversationHistory);
    }
    // 轮次收敛：所有 execute 路径（普通、follow-up、工具别名）共用同一收尾。
    // 一轮内只要真正执行成功就清零；只有拒绝、没有成功才累计一次，避免同一轮
    // 多条被拦命令重复计数。执行失败不是"被拒绝"，不应凭空增加 blocked streak。
    final commandSucceeded = _commandSucceededThisTurn;
    if (!_finalizeCommandTurn()) return false;
    // R5：只有成功执行才重置无命令重试；仅进入执行器但失败不能清零。
    if (commandSucceeded) _noCommandRetryCount = 0;
    return true;
  }

  bool _finalizeCommandTurn() {
    final succeeded = _commandSucceededThisTurn;
    final rejected = _commandRejectedThisTurn;
    final started = _commandPassedPrecheckThisTurn;
    _commandPassedPrecheckThisTurn = false;
    _commandRejectedThisTurn = false;
    _commandSucceededThisTurn = false;
    if (succeeded) {
      _blockedTurnsStreak = 0;
    } else if (rejected) {
      _blockedTurnsStreak++;
      if (_blockedTurnsStreak >= _maxBlockedTurnsBeforeAbort) {
        agentLogger.warn(
            'ReAct', '连续 $_blockedTurnsStreak 轮命令被拦截且未成功执行，任务终止 (failed)');
        _finishTask(success: false, summary: '命令连续被拦截，未能推进任务');
        return false;
      }
    }
    // started 已在调用方捕获；保留局部变量用于明确"进入执行器但失败"不会
    // 被误判为拒绝，也不会重置 blocked streak。
    if (!succeeded && !rejected && started) {
      agentLogger.debug('ReAct', '本轮命令已执行但未成功，blocked streak 保持不变');
    }
    return true;
  }

  /// 当前响应中除第一条之外、已作为 command 事件发出的其余命令（委托 CommandRunner）
  List<({String eventId, String command})> _remainingAnnouncedCommands(
          List<AgentEvent>? events) =>
      CommandRunner.remainingAnnouncedCommands(events);

  /// 这些 reason 表示命令被策略/权限/用户拦下，从未真正执行（口径见 CommandRunner）
  static const Set<String> _blockedCommandReasons =
      CommandRunner.blockedCommandReasons;

  /// 执行命令（含安全检查、用户确认、执行、发 result 事件），返回执行结果和观测
  /// [commandId] 用于关联 result 事件与 command 事件（流式提前执行时由 _callAI 传入）
  Future<_EarlyExecutionResult> _runCommandWithSafety(
    String command,
    CommandExecutor executor, {
    String? commandId,
    int? myGeneration,
  }) async {
    // 命令本身会在执行结束时随结果行一起记录，这里只留 debug 细节
    agentLogger.debug(
        'ReAct', '执行命令: ${_logCommand(command)} (commandId=$commandId)');

    // P0-2: trace 命令执行开始
    final traceTaskId = _currentTask?.id;
    if (traceTaskId != null) {
      AgentTracer.instance.emitSync(TraceEvent(
        taskId: traceTaskId,
        hostId: hostId,
        type: TraceEventType.commandStart,
        generation: myGeneration,
        step: _currentStepCount,
        payload: {
          if (commandId != null) 'command_id': commandId,
          'command': command,
        },
      ));
    }
    // 局部状态追踪：finally 中统一 emit commandEnd
    var cmdSuccess = false;
    var cmdReason = 'unknown';
    var outputChars = 0;

    try {
      return await _runCommandWithSafetyInner(
        command,
        executor,
        commandId: commandId,
        myGeneration: myGeneration,
        traceTaskId: traceTaskId,
        onSuccess: (s, reason, chars) {
          cmdSuccess = s;
          cmdReason = reason;
          outputChars = chars;
          // 被策略拦下、从未执行的命令也计入「步」：用户视角是"AI 尝试过"。
          // 取消/代际失效/误发远程不是拦截，计进去会让步数随取消操作膨胀。
          if (_isSameTask(
                  myGeneration ?? _currentTaskGeneration, traceTaskId) &&
              _blockedCommandReasons.contains(reason)) {
            _blockedCount++;
          }
        },
      );
    } catch (e) {
      cmdReason = 'exception';
      rethrow;
    } finally {
      if (traceTaskId != null) {
        AgentTracer.instance.emitSync(TraceEvent(
          taskId: traceTaskId,
          hostId: hostId,
          type: TraceEventType.commandEnd,
          generation: myGeneration,
          step: _currentStepCount,
          payload: {
            if (commandId != null) 'command_id': commandId,
            'success': cmdSuccess,
            'reason': cmdReason,
            if (outputChars > 0) 'output_chars': outputChars,
          },
        ));
      }
    }
  }

  /// 日志里只放命令首行并限长（委托 CommandRunner）
  static String _logCommand(String command) =>
      CommandRunner.logCommand(command);

  /// 模型推理增量：累积 + 限长 + 节流（~150ms），避免每个 token 都重建一次 UI
  void _handleReasoningDelta(String delta) {
    if (delta.isEmpty) return;
    _reasoningBuffer.write(delta);
    if (_reasoningBuffer.length > _maxReasoningChars) {
      final text = _reasoningBuffer.toString();
      _reasoningBuffer
        ..clear()
        ..write(text.substring(text.length - _maxReasoningChars));
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastReasoningEmitAt < 150) return;
    _lastReasoningEmitAt = now;
    onReasoning?.call(_reasoningBuffer.toString());
  }

  /// 推理规范化用的空白折叠正则：提为 static final，避免每次调用/每行
  /// 重新编译（该方法在流式推理结束、每步 reset 时都会走到）。
  static final RegExp _reasoningWsRegExp = RegExp(r'\s+');

  static String _normalizeReasoning(String s) =>
      s.replaceAll(_reasoningWsRegExp, ' ').trim().toLowerCase();

  /// 原生推理是否与 ReAct 解析出的思考重复（忽略空白与大小写）。
  ///
  /// 有些网关把同一段推理既放在 reasoning_content、又放在「思考:」行里，
  /// 两条都留就是屏幕上同一段话出现两遍。内容不同则不判重：原生推理往往
  /// 比协议行更细，用户要看到的是「AI 当时到底在想什么」。
  bool _reasoningDuplicatesReactThought(
      String reasoning, List<AgentEvent>? events) {
    if (events == null || events.isEmpty) return false;
    final r = _normalizeReasoning(reasoning);
    if (r.isEmpty) return true;
    final thoughts = <String>[];
    for (final e in events) {
      if (!e.isThought) continue;
      final t = _normalizeReasoning(e.text ?? '');
      if (t.isNotEmpty) thoughts.add(t);
    }
    if (thoughts.isEmpty) return false;
    // 太短的推理多半是协议噪声：有协议思考时就不重复补一条
    if (r.length < 24) return true;
    for (final t in thoughts) {
      if (t.contains(r) || r.contains(t)) return true;
    }
    return false;
  }

  /// 每一步重新开始：把上一步残留的推理固化为思考事件（正常情况流式结束时已固化，
  /// 这里只在异常退出等 flush 被跳过时兜底），再清空并通知 UI 收起瞬时推理块
  void _resetReasoning() {
    if (_reasoningBuffer.isNotEmpty) {
      final reasoning = _reasoningBuffer.toString().trim();
      if (reasoning.isNotEmpty &&
          !_reasoningDuplicatesReactThought(
              reasoning, _lastParsedResponseEvents)) {
        onEvent?.call(AgentEvent.thought(reasoning));
      }
    }
    _reasoningBuffer.clear();
    _lastReasoningEmitAt = 0;
    onReasoning?.call('');
  }

  /// _runCommandWithSafety 的内部实现（不含 trace，由外层 wrapper 统一记录）
  Future<_EarlyExecutionResult> _runCommandWithSafetyInner(
    String command,
    CommandExecutor executor, {
    String? commandId,
    int? myGeneration,
    String? traceTaskId,
    required void Function(bool success, String reason, int outputChars)
        onSuccess,
  }) async {
    final taskId = _currentTask?.id;
    final generation = myGeneration ?? _currentTaskGeneration;
    bool stillCurrent() => _isSameTask(generation, taskId);
    bool active() => _isTaskActive(generation, taskId);
    // R5: 任务已终结（完成/失败/取消）后，流式提前执行的残余回调不能再把
    // 状态改回 executing —— 否则 UI 会永久停在「运行中」，且补充指令
    // 永远等不到下一轮循环边界（真机验证：finish 后提前执行复活任务）。
    final task = _currentTask;
    if (task != null && isTerminalStatus(task.status)) {
      onSuccess(false, 'task_already_terminal', 0);
      return _EarlyExecutionResult(shouldContinue: false, command: command);
    }

    // 安全检查
    final safetyLevel = SafetyGuard.check(command);
    agentLogger.debug('ReAct',
        '步骤 $_currentStepCount · 安全检查 $safetyLevel · ${_logCommand(command)}');

    var decision = decideCommand(safetyLevel, _permissionMode);
    var auditMetadata = AuditLogger.commandMetadata(
      command: command,
      permissionMode: _permissionMode,
      decision: decision,
    );

    // 审计日志（执行前写入）：即使执行中崩溃，也能追溯"曾发起过这条命令"
    // 所有命令都记录（含 safe 级），因为 cat /etc/shadow 等只读命令也可能泄露敏感信息
    if (hostId != null) {
      try {
        await AuditLogger.log(
          hostId: hostId!,
          command: command,
          safetyLevel: safetyLevel.name,
          output: null, // 执行前无输出，执行后会追加一条带结果的记录
          executed: false,
          metadata: auditMetadata,
        );
      } catch (e) {
        agentLogger.warn('Audit', '审计日志写入失败(执行前): $e');
      }
    }

    // 审计写入跨过 await：旧任务不得继续设置确认框或 executing 状态。
    if (!stillCurrent()) {
      return _EarlyExecutionResult(shouldContinue: false, command: command);
    }
    if (!active()) {
      onSuccess(false, 'task_already_terminal', 0);
      return _EarlyExecutionResult(shouldContinue: false, command: command);
    }
    decision = decideCommand(safetyLevel, _permissionMode);
    auditMetadata = AuditLogger.commandMetadata(
      command: command,
      permissionMode: _permissionMode,
      decision: decision,
    );
    agentLogger.debug('ReAct',
        '步骤 $_currentStepCount · 权限 ${_permissionMode.id} → ${decision.name}');

    // 执行前五道守卫（顺序敏感，语义见 CommandPreflight）。
    // 判定本身无状态；审计写入留在引擎侧——它要 hostId 且会 await。
    final block = CommandPreflight.evaluate(
      command: command,
      safetyLevel: safetyLevel,
      executor: executor,
      permissionMode: _permissionMode,
      decision: decision,
      emitInfo: (e) => onEvent?.call(e),
    );
    if (block != null) {
      _commandRejectedThisTurn = true;
      agentLogger.warn(
          'ReAct', '预检拦截(${block.reasonCode}): ${_logCommand(command)}');
      if (block.auditOutput != null && hostId != null) {
        try {
          await AuditLogger.log(
            hostId: hostId!,
            command: command,
            safetyLevel: safetyLevel.name,
            output: block.auditOutput!,
            executed: false,
            metadata: {...auditMetadata, 'policyReason': block.reasonCode},
          );
        } catch (e) {
          agentLogger.warn(
              'Audit', '审计日志写入失败(${block.auditTag ?? '拦截分支'}): $e');
        }
      }
      if (!stillCurrent()) {
        return _EarlyExecutionResult(shouldContinue: false, command: command);
      }
      onSuccess(false, block.reasonCode, 0);
      return _EarlyExecutionResult(
          shouldContinue: true,
          observation: block.observation,
          command: command);
    }

    // 需要用户确认：warn（询问档）与 blocked（询问/自动档）
    if (decision == CommandGateDecision.confirm) {
      agentLogger.warn('ReAct', '命令需要确认: $command (模式: ${_permissionMode.id})');
      final confirmCompleter = Completer<bool>();
      var confirmTimedOut = false;
      _pendingConfirmCommand = command;
      _confirmCompleter = confirmCompleter;
      // 每次开始等待都要清掉上一次的结论：残留的 true 会把下一次真实的
      // "用户拒绝"错标成超时。
      _confirmTimedOut = false;
      // 超时后必须完成本轮局部 future，即使任务已被替换；共享状态仅在
      // identity 与代际都仍匹配时更新，避免旧任务的定时器污染新任务。
      final confirmTimer = Timer(const Duration(minutes: 10), () {
        if (confirmCompleter.isCompleted) return;
        agentLogger.warn('ReAct', '确认超时(10min)，自动拒绝: $command');
        confirmTimedOut = true;
        if (identical(_confirmCompleter, confirmCompleter) && active()) {
          _confirmTimedOut = true;
          _taskHadConfirmTimeout = true;
        }
        confirmCompleter.complete(false);
      });
      _confirmTimeoutTimer = confirmTimer;

      // 显示具体的风险说明，而非泛泛的"危险操作"
      final reason =
          SafetyGuard.getReason(command) ?? SafetyGuard.getTip(safetyLevel);
      final highRisk = safetyLevel == SafetyLevel.blocked;
      final modeLabel = _permissionMode == AgentPermissionMode.ask
          ? UiText.t('询问', 'Ask')
          : UiText.t('自动', 'Auto');
      onEvent?.call(AgentEvent.info(UiText.t(
          '${highRisk ? '⛔' : '⚠️'} ${highRisk ? '高危命令' : '高风险命令'}'
              '需要确认（$modeLabel模式）: `$command`\n风险说明: $reason',
          '${highRisk ? '⛔' : '⚠️'} ${highRisk ? 'High-risk command' : 'Risky command'}'
              ' needs confirmation ($modeLabel mode): `$command`\nRisk: $reason')));

      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.waitingConfirm,
        phase: '等待确认',
        currentStep: '等待确认: $command',
      );
      _notifyTaskUpdate();

      final waitStart = DateTime.now();
      final confirmed = await confirmCompleter.future;
      confirmTimer.cancel();
      if (identical(_confirmCompleter, confirmCompleter)) {
        _confirmTimeoutTimer = null;
        _confirmCompleter = null;
        _pendingConfirmCommand = null;
      }
      if (!stillCurrent()) {
        onSuccess(false, 'task_replaced_during_confirm', 0);
        return _EarlyExecutionResult(shouldContinue: false, command: command);
      }
      if (!active()) {
        agentLogger.info('ReAct', '任务在等待确认期间已终止或暂停');
        onSuccess(false, 'cancelled_during_confirm', 0);
        return _EarlyExecutionResult(shouldContinue: false, command: command);
      }
      _confirmWaitSeconds += DateTime.now().difference(waitStart).inSeconds;

      if (!confirmed) {
        _commandRejectedThisTurn = true;
        // 超时不是用户拒绝：写成"用户拒绝"会在历史里留下一件用户没做过的事，
        // 也会让模型以为被否决而不再重试。
        final timedOut = confirmTimedOut;
        final reason = timedOut ? '确认超时（10 分钟无响应），已自动拒绝' : '用户拒绝执行此命令';
        agentLogger.info('ReAct', '$reason: $command');
        onEvent?.call(AgentEvent.info(timedOut
            ? '⏱ ${UiText.t(reason, 'Confirmation timed out (no response for 10 minutes); auto-rejected')}'
            : '❌ ${UiText.t(reason, 'User declined to run this command')}'));
        final observation = ReActObservation(
          command: command,
          output: reason,
          success: false,
          error: timedOut ? '确认超时' : '用户拒绝',
        ).format();
        onSuccess(false, timedOut ? 'confirm_timeout' : 'user_rejected', 0);
        return _EarlyExecutionResult(
            shouldContinue: true, observation: observation, command: command);
      }

      // 等待期间用户可能把档位切到只读：重新校验，不能让切换前弹出的确认框
      // 绕过新的安全边界（全自动则本来就无需确认，重新校验仍是 execute）。
      if (decideCommand(safetyLevel, _permissionMode) ==
          CommandGateDecision.reject) {
        _commandRejectedThisTurn = true;
        const reason = '等待确认期间权限档位已切换为只读，命令未执行';
        agentLogger.warn('ReAct', reason);
        onEvent?.call(AgentEvent.info(
            '🔒 ${UiText.t(reason, 'Permission mode switched to read-only while awaiting confirmation; command was not run')}'));
        final observation = ReActObservation(
          command: command,
          output: reason,
          success: false,
          error: '权限档位切换',
        ).format();
        onSuccess(false, 'permission_changed_during_confirm', 0);
        return _EarlyExecutionResult(
            shouldContinue: true, observation: observation, command: command);
      }

      agentLogger.info('ReAct', '用户确认执行危险命令: $command');
      onEvent?.call(AgentEvent.info(
          UiText.t('✅ 用户已确认，开始执行...', '✅ Confirmed, executing...')));
    }

    // 执行命令
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.executing,
      phase: _phaseForCommand(command, safetyLevel),
      currentStep: _progressStepText(),
    );
    _notifyTaskUpdate();
    onCommandGenerated?.call(command);

    if (safetyLevel == SafetyLevel.info) {
      agentLogger.info('ReAct', '低风险操作提示: $command');
    }

    // 失败回滚：修改类命令执行前做快照（只读，不影响原命令）
    PreSnapshot? snapshot;
    final modifyTarget = RollbackAdvisor.analyze(command);
    if (modifyTarget != null) {
      final snapshotCmd = RollbackAdvisor.buildSnapshotCommand(modifyTarget);
      if (snapshotCmd != null) {
        agentLogger.info('Rollback', '检测到修改类命令，执行预快照: ${modifyTarget.type}');
        try {
          final snapshotResult = await _executeCommand(executor, snapshotCmd,
              myGeneration: myGeneration, countDisconnect: false);
          // R1: 快照执行后检查 identity/代际/终态，避免旧任务继续下发主命令。
          if (!stillCurrent() || !active()) {
            onSuccess(false, 'task_invalid_after_snapshot', 0);
            return _EarlyExecutionResult(
                shouldContinue: false, command: command);
          }
          snapshot = PreSnapshot(
            target: modifyTarget,
            snapshotCommand: snapshotCmd,
            snapshotOutput:
                snapshotResult.success ? snapshotResult.output : null,
          );
          if (snapshotResult.success &&
              (snapshotResult.output?.isNotEmpty ?? false)) {
            agentLogger.info(
                'Rollback', '快照已记录: ${snapshotResult.output?.length ?? 0} 字符');
          }
        } catch (e) {
          agentLogger.warn('Rollback', '快照执行失败(忽略): $e');
        }
      }
    }

    var commandStarted = false;
    final result = await _executeCommand(executor, command,
        myGeneration: myGeneration, onStarted: () {
      commandStarted = true;
      // 只有到达 executeAndWait 前才算真正开始；预检、权限、确认拒绝
      // 都不能帮助 finish 绕过"未执行任何命令"验证。
      _hasExecutedAnyCommand = true;
      _commandPassedPrecheckThisTurn = true;
    });
    // 一条命令一行：安全/权限两条细节降到 DEBUG，正常看日志时只留这一行
    final parts = <String>[
      '步骤 $_currentStepCount',
      _logCommand(command),
      result.success ? '成功' : '失败',
      if (result.exitCode != null) 'exit ${result.exitCode}',
      if (result.duration != null) '${result.duration!.inMilliseconds}ms',
      '${result.output?.length ?? 0} 字符',
      if (!result.success && result.failureKind != null) result.failureKind!,
    ];
    agentLogger.info('ReAct', parts.join(' · '));

    // R1: 主命令执行后检查代际，避免旧任务结果污染新任务的统计/事件流
    // 若代际已变更（cancel + 立即新任务），不再更新 _currentTask 统计、不再 emit result 事件
    if (!stillCurrent() || !active()) {
      agentLogger.info('ReAct', '命令执行后任务失效，丢弃结果不污染新任务');
      onSuccess(result.success, 'task_invalid_after_exec', 0);
      return _EarlyExecutionResult(shouldContinue: false, command: command);
    }

    if (commandStarted && result.success) _commandSucceededThisTurn = true;

    // 更新命令成功/失败计数
    _currentTask = _currentTask!.copyWith(
      successCount: _currentTask!.successCount + (result.success ? 1 : 0),
      failureCount: _currentTask!.failureCount + (result.success ? 0 : 1),
    );

    _memory.rememberCommand(command);
    _memory.rememberResult(
      command,
      result.output ?? result.error ?? '',
      success: result.success,
    );

    // 格式化观测结果（分级截断，O2）
    // R8: 即使是查询命令也强制上限（20000 字符），防止 cat huge_file / journalctl 等输出撑爆 AI 上下文
    // 失败输出保留头（报错原因）+ 尾（stack/summary），不再一刀切只留尾部
    final isQuery = isQueryCommand(command);
    final String outputText;
    final String errorText;
    if (isQuery) {
      outputText = truncateQueryOutput(result.output);
      errorText = truncateQueryOutput(result.error);
    } else if (result.success) {
      outputText = truncateSuccessOutput(result.output);
      errorText = truncateSuccessOutput(result.error);
    } else {
      outputText = truncateFailureOutput(result.output);
      errorText = truncateFailureOutput(result.error);
    }

    // 保留原始输出尾部：事件里的 output 经过分级截断，证据层需要更多上下文
    // 失败时真实输出在 output（执行器恒 stderr=''，见设计文档事实 A），
    // 读 error 会让证据层永远缺失报错正文
    String? outputTail;
    if (!isQuery) {
      const maxTailChars = 8000;
      final raw = result.output;
      // 卡片正文（output 与失败 error 段）都是 outputText：只有它真被截断时
      // 尾部证据才有增量价值。按 errorText（失败时恒 '(无输出)' 的 stderr）比长度
      // 会让几乎每个失败卡都附带一份与正文重复的 outputTail + 失真徽标。
      final shown = outputText;
      if (raw != null && raw.isNotEmpty && raw.length > shown.length) {
        outputTail = raw.length <= maxTailChars
            ? raw
            : raw.substring(raw.length - maxTailChars);
      }
    }

    // 失败回滚：命令失败时，把快照+回滚建议注入观测，AI 会看到并建议回滚
    String? rollbackHint;
    if (!result.success && snapshot != null) {
      rollbackHint = RollbackAdvisor.buildRollbackSuggestion(
          snapshot.target, snapshot.snapshotOutput);
      if (rollbackHint != null) {
        agentLogger.info('Rollback', '命令失败，已生成回滚建议: $rollbackHint');
      }
    }

    // F1：失败的真实内容在 stdout（执行器恒 stderr=''），观测正文用 outputText；
    // errorText 只在执行器真的给了 stderr 时才非 '(无输出)'，此时作为独立「错误:」段
    final hasRealError = (result.error ?? '').trim().isNotEmpty;
    final failureBody = rollbackHint != null
        ? '$outputText\n\n【失败回滚提示】修改前已快照:\n${snapshot?.snapshotOutput ?? "(无快照)"}\n$rollbackHint'
        : outputText;

    final observation = ReActObservation(
      command: command,
      output: result.success ? outputText : failureBody,
      success: result.success,
      error: result.success ? null : (hasRealError ? errorText : null),
      exitCode: result.exitCode,
      failureKind: result.failureKind,
      failureReason: result.failureReason,
    );

    // 先发出结构化结果事件，再通知执行完成
    // 失败时长度按 outputText 计：真实输出在 output，按恒空的 error 计会让截断徽标失真
    final rawOutputLength = result.output?.length ?? 0;
    final shownOutputLength = outputText.length;
    onEvent?.call(AgentEvent.result(
      commandId: commandId ?? _lastCommandEventId,
      command: command,
      success: result.success,
      output: outputText,
      error: result.success
          ? null
          : (rollbackHint != null
              ? '$outputText\n\n$rollbackHint'
              : outputText),
      hostId: hostId,
      toolName: 'exec_command',
      durationMs: result.duration?.inMilliseconds,
      exitCode: result.exitCode,
      failureKind: result.failureKind,
      outputTotalChars: rawOutputLength,
      outputTruncated: rawOutputLength > shownOutputLength,
      outputTail: outputTail,
    ));

    onCommandExecuted?.call(result);

    // 确定性验证：只对格式稳定的只读校验命令产出徽标
    final badge = VerificationDetector.detect(
      command: command,
      output: result.success ? result.output : result.error,
      success: result.success,
    );
    if (badge != null &&
        _operationBadges.length < 6 &&
        !_operationBadges.any((b) => b.text == badge.text)) {
      _operationBadges.add(badge);
      _currentTask = _currentTask!.copyWith(phase: '验证结果');
      _notifyTaskUpdate();
    }

    // 变更台账：非 safe 级命令（即修改性命令）记录到台账，便于事后追溯和回滚
    // safe 级命令（ls/cat/grep 等只读命令）不记录，避免台账膨胀
    if (safetyLevel != SafetyLevel.safe && hostId != null) {
      // R1: await 期间用户可能 cancel + startTask 开启新任务。下面的台账写入
      // 是共享 list（_operationChanges/_operationChangeIds），捕获本任务代际，
      // await 回来后若代际已变，说明命令属于旧任务，不能污染新 operation 报告。
      final genAtRecord = _currentTaskGeneration;
      try {
        final record = await ChangeRecordService.record(
          hostId: hostId!,
          command: command,
          success: result.success,
          conversationId: _currentTask?.operationId ?? _operationId,
        );
        if (genAtRecord == generation &&
            stillCurrent() &&
            record.success &&
            _operationChanges.length < 100) {
          _operationChangeIds.add(record.id);
          _operationChanges.add(OperationChange(
            id: record.id,
            command: record.command,
            type: record.type.name,
            rollbackCommand: record.rollbackCommand,
            success: record.success,
          ));
        }
      } catch (e) {
        // R8: 持久化失败不可静默吞掉，需记录日志带上下文
        agentLogger.warn('ChangeRecord',
            '记录变更台账失败(忽略): hostId=$hostId, cmd=$command, err=$e');
      }
    }

    // 审计日志（执行后）：记录执行结果，与执行前的 executed=false 形成完整审计链
    // 所有命令都记录（含 safe 级），执行前已写 executed=false，这里写 executed=true + 结果
    if (hostId != null) {
      try {
        await AuditLogger.log(
          hostId: hostId!,
          command: command,
          safetyLevel: safetyLevel.name,
          output: result.success
              ? (result.output?.isNotEmpty == true
                  ? _truncateForAudit(result.output!)
                  : '(无输出)')
              : (result.error?.isNotEmpty == true
                  ? _truncateForAudit(result.error!)
                  : '(无错误信息)'),
          executed: true,
          metadata: auditMetadata,
        );
      } catch (e) {
        agentLogger.warn(
            'Audit', '审计日志写入失败(执行后): hostId=$hostId, cmd=$command, err=$e');
      }
    }

    // 台账/审计都可能跨任务边界；旧任务不得继续回灌观测或推进 ReAct。
    if (!stillCurrent() || !active()) {
      onSuccess(result.success, 'task_invalid_after_record', 0);
      return _EarlyExecutionResult(shouldContinue: false, command: command);
    }
    onSuccess(result.success, 'completed', outputText.length);
    return _EarlyExecutionResult(
      shouldContinue: true,
      observation: observation.format(),
      command: command,
      success: result.success,
    );
  }

  /// 审计日志输出截断（委托 CommandRunner）
  static String _truncateForAudit(String s) =>
      CommandRunner.truncateForAudit(s);

  /// 最近一次 command 事件 id（用于 result 关联）
  /// 由 _callAI 流式解析时更新，_handleExecuteAction 执行命令后用它关联 result
  String _lastCommandEventId = '';

  /// 为 shell command 事件补主机/工具/风险元数据（委托 CommandRunner）
  void _enrichCommandEvent(AgentEvent e) => CommandRunner.enrichCommandEvent(
        e,
        hostId: hostId,
        permissionMode: _permissionMode,
      );

  /// 处理多条命令执行（旧格式 fallback）
  Future<bool> _handleExecuteCommands(
      List<String> commands, CommandExecutor executor,
      {required int myGeneration}) async {
    final resultMessages = <String>[];
    var aborted = false;
    for (final command in commands) {
      if (_currentTask?.status == AgentStatus.cancelled) {
        aborted = true;
        break;
      }
      if (myGeneration != _currentTaskGeneration) {
        aborted = true;
        break;
      }
      // R4: 为每条 fallback 命令生成独立的 commandId，并先发 command 事件
      // 否则所有 result 会关联到同一个 _lastCommandEventId，导致 UI 错误地把每个结果卡片链接到最后一条命令
      final cmdId = 'evt_fallback_${_uuid.v4().substring(0, 8)}';
      final cmdEvent = AgentEvent.command(command, id: cmdId);
      // 旧格式 fallback 也要带风险/处置快照，否则 blocked 卡片会按旧逻辑
      // 在全自动执行期间显示成“已拦截”。
      _enrichCommandEvent(cmdEvent);
      onEvent?.call(cmdEvent);
      final result = await _runCommandWithSafety(command, executor,
          commandId: cmdId, myGeneration: myGeneration);
      // R1: 命令执行后再次检查代际（执行期间可能被取消/新任务覆盖）
      if (myGeneration != _currentTaskGeneration) {
        aborted = true;
        break;
      }
      if (result.observation != null) {
        resultMessages.add(result.observation!);
      }
      if (!result.shouldContinue) {
        aborted = true;
        break;
      }
    }
    // 即使中断也保留已收集的观测（用户能看到部分命令的执行结果）
    if (resultMessages.isNotEmpty) {
      _conversationHistory.add(ChatMessage.create(
          role: 'user', content: resultMessages.join('\n\n')));
      _trimMessages(_conversationHistory);
    }
    // 中断时返回 false 让上层退出循环；正常完成返回 true
    return !aborted;
  }

  /// finish 里的选择请求兜底：显式 选项: 行优先，其次从正文识别。
  ChoiceRequest? _choiceRequestFromFinish(ReActStep step) {
    final options = step.options;
    if (options != null && options.length >= 2) {
      final answer = step.answer?.trim() ?? '';
      final question = answer.isNotEmpty ? answer : step.thought.trim();
      return ChoiceRequest(question, options);
    }
    final answer = step.answer?.trim() ?? '';
    final text = answer.isNotEmpty
        ? answer
        : (step.thought.trim().isNotEmpty
            ? step.thought.trim()
            : step.rawResponse);
    return ChoiceRequestDetector.detect(text);
  }

  /// 处理 ask 动作 — 暂停等待用户选择
  /// 返回 true 表示继续循环，false 表示应退出
  Future<bool> _handleAskAction(ReActStep step,
      {required int myGeneration}) async {
    final options = step.options ?? [];
    if (options.isEmpty) {
      agentLogger.warn('ReAct', 'ask 动作但无选项，视为 finish');
      final thought = step.thought.trim();
      _finishTask(summary: thought.isNotEmpty ? thought : null);
      return false;
    }

    agentLogger.info('ReAct', '检测到选项，暂停等待用户选择: $options');

    final taskId = _currentTask?.id;
    final choiceCompleter = Completer<String>();
    _pendingOptions = options;
    _choiceCompleter = choiceCompleter;
    // 抓住本轮这一个 ask 事件：等待期间可能又有新事件进来，
    // 用变量固定住，回写答案时不会写到别的提问上。
    final pendingAsk = _pendingAskEvent;

    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.waitingConfirm,
      phase: '等待选择',
      currentStep: '等待选择',
    );
    _notifyTaskUpdate();

    // 暂停循环，等待用户选择
    final choice = await choiceCompleter.future;
    if (identical(_choiceCompleter, choiceCompleter)) {
      _choiceCompleter = null;
      _pendingOptions = [];
    }
    if (!_isSameTask(myGeneration, taskId)) return false;
    if (!_isTaskActive(myGeneration, taskId)) {
      agentLogger.info('ReAct', '任务在等待选择期间已终止或暂停');
      return false;
    }

    if (choice.isEmpty) {
      agentLogger.info('ReAct', '用户取消选择');
      // R5: 正常来源（cancelTask/pauseTask）会在 complete('') 前把状态设为
      // cancelled/paused，上面已分别 return。若走到这里状态仍是 waitingConfirm，
      // 说明是外部直接 selectChoice('') 等异常路径 —— 必须主动收口，否则任务
      // 永久悬在等待选择态、UI 卡住。用 _finishTask 一次完成 status/report/
      // finish/flush，与其他失败终态一致。
      if (_currentTask?.status == AgentStatus.waitingConfirm) {
        _finishTask(success: false, summary: L10n.str.taskCancelled);
      }
      return false;
    }

    // 将用户选择反馈给 AI
    agentLogger.info('ReAct', '用户选择了: $choice');
    _absorbNoCommandConstraint(choice, 'ask 选项');
    // 答案回写到 ask 事件本身：提问这一步要自带"问过什么 + 选了什么"，
    // 不能只靠后面那条 info 事件反推（跨轮/跨段就断了）。
    pendingAsk?.chosenAnswer = choice;
    onEvent?.call(AgentEvent.info(L10n.str.ut_a61b05ce9b(choice)));

    // 以 ReAct 观测格式反馈
    final observation = '观测: 用户选择了 "$choice"';
    _conversationHistory
        .add(ChatMessage.create(role: 'user', content: observation));
    _trimMessages(_conversationHistory);

    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.thinking,
      currentStep: '继续处理...',
    );
    _notifyTaskUpdate();

    return true; // 继续循环
  }

  /// ═══════════════════════════════════════════════════════
  /// 把工具参数格式化为展示用文本（多行 key:value 格式，与 ReAct 调用格式一致）
  /// 用于 AgentEvent.result.command 和 ReActObservation.command
  /// 避免 AI 从观测/事件里看到 JSON 格式而被"带偏"
  ///
  /// Step 6 已迁至 `ToolDisplayFormatter.describe`，这里保留薄转发壳
  /// （调用点零改动，测试仍可按原入口断言）。
  static String _formatToolCommandForDisplay(
    String toolName,
    ToolArgs args, {
    int maxValueChars = 0,
  }) =>
      ToolDisplayFormatter.describe(
        toolName,
        args,
        maxValueChars: maxValueChars,
      );

  /// 处理 tool 动作 — 调用非 shell 工具（如 SFTP 上传）
  /// ═══════════════════════════════════════════════════════
  /// 返回 true 表示继续循环，false 表示应退出
  /// 文件工具不在 shell 变更台账里，这里补一条变更 + 审计，保证“可追溯”覆盖文件编辑
  Future<void> _recordToolFileChange({
    required String toolName,
    required ToolArgs args,
    required ToolResult result,
  }) async {
    if (!_tools.isChangeRecordingTool(toolName)) return;
    final explicitHost = args.getString('hostId').trim();
    final targetHost =
        explicitHost.isNotEmpty ? explicitHost : (hostId ?? 'local');
    final description =
        ChangeRecordService.describeFileToolChange(toolName, args);

    // R1: 同 shell 命令台账，await 写库期间可能切到新任务；捕获代际后再决定
    // 是否写入共享 list，避免旧文件变更污染新 operation 报告。
    final genAtRecord = _currentTaskGeneration;
    try {
      final record = await ChangeRecordService.record(
        hostId: targetHost,
        command: description,
        success: result.success,
        conversationId: _currentTask?.operationId ?? _operationId,
        forceType: ChangeType.fileOperation,
        localRestoreFrom: result.restoreFrom,
        localRestoreTo: result.restoreTo,
      );
      if (genAtRecord == _currentTaskGeneration &&
          record.success &&
          _operationChanges.length < 100) {
        _operationChangeIds.add(record.id);
        _operationChanges.add(OperationChange(
          id: record.id,
          command: description,
          type: record.type.name,
          rollbackCommand: null,
          localRestore: record.isLocalFileRestore,
          success: true,
          additions: result.diffAdditions,
          deletions: result.diffDeletions,
        ));
      }
    } catch (e) {
      agentLogger.warn('ChangeRecord',
          '记录文件变更失败(忽略): host=$targetHost, op=$description, err=$e');
    }

    try {
      await AuditLogger.log(
        hostId: targetHost,
        command: description,
        safetyLevel: SafetyLevel.warn.name,
        output: result.success
            ? (result.output.isNotEmpty
                ? _truncateForAudit(result.output)
                : '(无输出)')
            : (result.error?.isNotEmpty == true
                ? _truncateForAudit(result.error!)
                : '(无错误信息)'),
        executed: true,
      );
    } catch (e) {
      agentLogger.warn(
          'Audit', '记录文件变更审计失败(忽略): host=$targetHost, op=$description, err=$e');
    }
  }

  Future<bool> _handleToolAction(ReActStep step, CommandExecutor executor,
      {required int myGeneration}) async {
    final toolName = step.toolName?.trim() ?? '';
    final toolTaskId = _currentTask?.id;
    bool stillCurrent() => _isSameTask(myGeneration, toolTaskId);
    bool active() => _isTaskActive(myGeneration, toolTaskId);
    if (!stillCurrent() || !active()) return false;
    // 每次工具调用都计一步，含未知工具与只读档拦截：口径是"尝试过"，
    // 不是"成功变更过"。放在参数校验之前，失败调用同样计入。
    _toolCalls++;
    // 老模型的兼容：早期 schema 把参数包成 {"args": {...}}，照做的模型仍会这样发。
    // 只在「唯一键且是 Map」时解包，正常平铺参数不会被误伤。
    var rawArgs = step.toolArgs ?? const <String, dynamic>{};
    rawArgs = ToolArgNormalizer.unwrapNestedArgs(rawArgs);
    // 裸 Map 在这里收口成 ToolArgs：此后所有取参都必须走类型化访问器
    final args = ToolArgs(rawArgs);

    if (toolName.isEmpty) {
      agentLogger.warn('ReAct', 'tool 动作但未指定工具名');
      onEvent?.call(AgentEvent.info(UiText.t('⚠️ AI 调用工具但未指定工具名',
          '⚠️ Model called a tool without specifying a tool name')));
      const observation = '观测: 工具调用失败 — 未指定工具名';
      _conversationHistory
          .add(ChatMessage.create(role: 'user', content: observation));
      _trimMessages(_conversationHistory);
      _noCommandRetryCount++;
      if (_noCommandRetryCount >= _maxNoCommandRetries) {
        agentLogger.warn('ReAct', '工具调用重试次数耗尽');
        // R5: 所有终态路径必须设终态 + emit finish + flush 流式内容
        _finishTask(success: false, summary: L10n.str.toolRetryExhausted);
        return false;
      }
      return true;
    }

    // 兼容占位/幻觉工具名：部分模型受其它 agent 框架先验影响，会调用注册表
    // 里根本不存在的 think / execute / function_name（OpenAI 文档里的占位名）。
    // 直接报「未知工具」只会打断任务，还让同一条响应里宣布的命令全部悬空。
    // 按名字与参数形状路由，不再报错（分类逻辑见 ToolAliasRouter）：
    // - 带命令类参数 → 当成执行命令
    // - 带思考类参数 / 名字是 think → 当成记录一步思考
    // - 都没有 → 把可用工具清单回给模型，让它自己纠正
    final aliasRoute = ToolAliasRouter.resolve(toolName, args);
    if (aliasRoute.kind == ToolAliasKind.think) {
      if (aliasRoute.hasThought) {
        onEvent?.call(AgentEvent.thought(aliasRoute.thought.trim()));
      }
      _conversationHistory.add(
          ChatMessage.create(role: 'user', content: '观测: 思考已记录，请给出下一步动作。'));
      _trimMessages(_conversationHistory);
      _noCommandRetryCount = 0;
      return true;
    }
    if (aliasRoute.kind == ToolAliasKind.execute ||
        aliasRoute.kind == ToolAliasKind.placeholder) {
      if (aliasRoute.hasCommand) {
        final command = aliasRoute.command;
        // 先补发 command 事件再执行：结果用同一 id 关联，UI 才有完整的
        // 命令块 + 状态，而不是一条挂在旧事件上的孤儿结果
        final cmdId = 'evt_alias_${_uuid.v4().substring(0, 8)}';
        final cmdEvent = AgentEvent.command(command, id: cmdId);
        _enrichCommandEvent(cmdEvent);
        _lastCommandEventId = cmdId;
        onEvent?.call(cmdEvent);
        final result = await _runCommandWithSafety(command, executor,
            commandId: cmdId, myGeneration: myGeneration);
        if (myGeneration != _currentTaskGeneration) return false;
        if (!result.shouldContinue) return false;
        if (result.observation != null) {
          _conversationHistory.add(
              ChatMessage.create(role: 'user', content: result.observation!));
          _trimMessages(_conversationHistory);
        }
        final commandSucceeded = _commandSucceededThisTurn;
        if (!_finalizeCommandTurn()) return false;
        if (commandSucceeded) _noCommandRetryCount = 0;
        return true;
      }
      // execute 别名但没给命令：告诉模型缺参数，不算致命失败
      if (aliasRoute.kind == ToolAliasKind.execute) {
        final alias = toolName.toLowerCase();
        agentLogger.warn('ReAct', '$alias 别名缺少 command 参数');
        onEvent?.call(AgentEvent.info(L10n.str.ut_386b3634c1(alias)));
        _conversationHistory.add(ChatMessage.create(
            role: 'user', content: '观测: $alias 调用缺少 command 参数（要执行的命令），请重试。'));
        _trimMessages(_conversationHistory);
        _noCommandRetryCount++;
        if (_noCommandRetryCount >= _maxNoCommandRetries) {
          _finishTask(success: false, summary: L10n.str.toolRetryExhausted);
          return false;
        }
        return true;
      }
      // 通用占位名且没有命令参数：按思考处理（模型多半是想"先想一下"）
      if (aliasRoute.hasThought) {
        onEvent?.call(AgentEvent.thought(aliasRoute.thought.trim()));
        _conversationHistory.add(
            ChatMessage.create(role: 'user', content: '观测: 思考已记录，请给出下一步动作。'));
        _trimMessages(_conversationHistory);
        _noCommandRetryCount = 0;
        return true;
      }
      // 既没有命令也没有思考内容：把可用工具清单回给模型
      final available = _tools.all.map((t) => t.name).join(', ');
      _conversationHistory.add(ChatMessage.create(
          role: 'user', content: '观测: 工具 $toolName 不存在。可用工具: $available'));
      _trimMessages(_conversationHistory);
      return true;
    }

    final tool = _tools.get(toolName);
    // 执行前三道门禁（未知 → 只读档 → 作用域）的判定与文案见 ToolGate；
    // 日志、重试计数与终态收口仍归引擎（要读写实例状态）。
    final block = ToolGate.evaluate(
      toolName: toolName,
      tool: tool,
      permissionMode: _permissionMode,
      allToolNames: () => _tools.all.map((t) => t.name).toList(),
      visibleToolNames: () => _tools
          .visibleFor(isLocalSession: _isLocalSession)
          .map((t) => t.name)
          .toList(),
      isLocalSession: _isLocalSession,
    );
    if (block != null) {
      if (block.isWarning) {
        agentLogger.warn('ReAct', block.logMessage);
      } else {
        agentLogger.info('ReAct', block.logMessage);
      }
      onEvent?.call(block.notice);
      _conversationHistory
          .add(ChatMessage.create(role: 'user', content: block.observation));
      _trimMessages(_conversationHistory);
      // 与 toolName.isEmpty 路径一致：累计重试次数，防止 AI 反复调用不存在的工具造成死循环
      _noCommandRetryCount++;
      if (_noCommandRetryCount >= _maxNoCommandRetries) {
        if (block.reason == ToolGateReason.unknownTool) {
          agentLogger.warn('ReAct', '未知工具调用重试次数耗尽');
        }
        _finishTask(success: false, summary: L10n.str.toolRetryExhausted);
        return false;
      }
      return true;
    }
    // 走到这里 ToolGate 已保证 tool 非空；显式判空只为满足流分析。
    if (tool == null) return false;

    agentLogger.info('ReAct', '调用工具: $toolName, 参数: ${args.describe()}');
    // R4: 工具调用必须有独立的 command 事件和 id，不能复用上一条 shell 命令的 id。
    // 本机 shell 与破坏性工具的完整参数是批准依据，任何后缀都不得被摘要隐藏；
    // 其余工具仍按摘要截断，避免 file_write 的大内容撑爆证据层。
    final requiresFullConfirmation = toolName == 'local_exec' ||
        (tool.kind == ToolKind.destructive &&
            destructiveToolNeedsConfirm(_permissionMode));
    final toolUiDisplay = _formatToolCommandForDisplay(
      toolName,
      args,
      maxValueChars: requiresFullConfirmation ? 0 : 160,
    );
    final toolCommandEvent = AgentEvent.command(
      toolUiDisplay,
      id: 'evt_tool_${_uuid.v4().substring(0, 8)}',
      hostId: hostId,
      toolName: toolName,
    );
    onEvent?.call(toolCommandEvent);

    // 破坏性工具（如 local_file_delete）默认必须用户确认后才执行。
    // 全自动档跳过确认；与危险命令共用 _confirmCompleter / 超时策略 / 取消路径，
    // 不另造一套等待机制。
    if (tool.kind == ToolKind.destructive &&
        destructiveToolNeedsConfirm(_permissionMode)) {
      final approved = await _confirmToolExecution(toolName, toolUiDisplay,
          myGeneration: myGeneration);
      // R1: await 之后先检查 identity + 代际 + 终态，再决定后续状态写入
      if (!stillCurrent() || !active()) return false;
      if (!approved) {
        // 同上：10 分钟没人点，不等于用户说了"不"
        final timedOut = _confirmTimedOut;
        final reason = ToolConfirmation.reason(timedOut);
        onEvent?.call(ToolConfirmation.notice(timedOut));
        // 必须补一条 result：否则 UI 里这条命令卡片永远停在"待执行"
        onEvent?.call(AgentEvent.result(
          commandId: toolCommandEvent.id,
          success: false,
          error: reason,
          command: toolUiDisplay,
          hostId: hostId,
          toolName: toolName,
        ));
        final observation = ToolConfirmation.observation(timedOut);
        _conversationHistory
            .add(ChatMessage.create(role: 'user', content: observation));
        _trimMessages(_conversationHistory);
        return true;
      }
    }

    // 设置执行状态
    _currentTask = _currentTask!.copyWith(
      status: AgentStatus.executing,
      phase: '执行工具',
      currentStep: '执行工具 $toolName',
    );
    _notifyTaskUpdate();

    // 标记本任务已实际执行过工具（防止 AI 幻觉 finish）
    _hasExecutedAnyCommand = true;

    final toolStopwatch = Stopwatch()..start();
    final taskLocalAccess = _localAccess;
    final taskPermissionMode = _permissionMode;
    try {
      // 注入当前任务的取消令牌给工具，让工具内部调用 executeAndWait / writeFileViaPty
      // 时能透传 cancelToken，cancelTask 时立即中断工具内的命令执行。
      tool.cancelToken = _orchestratorCancelToken ?? _commandCancelToken;
      // 密码类工具向用户索取秘密的通道。只回传"是否已收到"，明文由
      // requestSudoPassword 直接写进安全存储，不经过工具与 observation。
      tool.sudoPasswordRequest = (reason) async {
        if (!active()) return false;
        return requestSudoPassword(
            reason: reason, myGeneration: myGeneration, taskId: toolTaskId);
      };
      tool.localAccess = taskLocalAccess;
      // 授权弹窗可能在任务取消后才返回；工具在真正执行前用它再拦一次。
      tool.isTaskActive = active;
      tool.permissionMode = taskPermissionMode;
      final result = await tool.execute(
        executor: executor,
        args: args,
        onProgress: (msg) {
          if (!active()) return;
          agentLogger.info('Tool', '[$toolName] $msg');
          onEvent?.call(AgentEvent.info('  $msg'));
        },
      );

      // R1: await 后做 identity + 代际检查
      if (!stillCurrent()) return false;
      if (!active()) {
        agentLogger.info('ReAct', '工具执行期间任务已终止或暂停');
        return false;
      }

      agentLogger.info('ReAct', '工具 $toolName 执行结果: success=${result.success}');
      if (!result.success) {
        // 失败时把 error/output 也打到日志，避免 AI 看不到失败原因瞎试
        final detail = result.error?.isNotEmpty == true
            ? result.error
            : (result.output.isNotEmpty ? result.output : '(无错误详情)');
        agentLogger.warn('ReAct', '工具 $toolName 失败详情: $detail');
      }

      // 发 result 事件：关联本次工具自己的 command id，并带上耗时/主机/工具名
      toolStopwatch.stop();
      // 截断阈值与字段派生见 ToolResultPresenter（8000 字符）
      final view = ToolResultPresenter.fromResult(result);
      onEvent?.call(AgentEvent.result(
        commandId: toolCommandEvent.id,
        success: result.success,
        output: result.success ? view.displayed : null,
        error: result.success ? null : view.displayed,
        // UI 展示用：工具名 + 多行参数（大参数已截断，避免证据层膨胀）
        command: toolUiDisplay,
        hostId: hostId,
        toolName: toolName,
        durationMs: toolStopwatch.elapsedMilliseconds,
        outputTotalChars: view.totalChars,
        outputTruncated: view.truncated,
        diffAdditions: result.diffAdditions,
        diffDeletions: result.diffDeletions,
        hostResults: result.hostResults,
      ));

      // 文件类工具补变更台账 + 审计（shell 变更在 _handleExecuteAction 里记录）
      await _recordToolFileChange(
        toolName: toolName,
        args: args,
        result: result,
      );

      // R1: 台账/审计是 await；用户可能在这期间点了停止或暂停。
      // 若继续走下面的 status=thinking，会把 cancelled/paused 覆盖回运行态，
      // UI 就会永远停在“思考中”，点停止看起来完全没反应。
      if (!stillCurrent() || !active()) return false;

      // 构造观测反馈给 AI
      // 注意：观测里的 command 用多行格式展示参数，避免 AI 从观测里学到 JSON 格式
      final observation = ReActObservation(
        command: _formatToolCommandForDisplay(toolName, args),
        output: result.success
            ? result.output
            : (result.output.isNotEmpty ? result.output : '(无输出)'),
        success: result.success,
        error: result.success ? null : result.error,
      ).format();
      _conversationHistory
          .add(ChatMessage.create(role: 'user', content: observation));
      _trimMessages(_conversationHistory);

      // 工具执行成功视为有效进展，重置无命令重试计数
      if (result.success) {
        _noCommandRetryCount = 0;
      }

      // 恢复 thinking 状态
      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.thinking,
        currentStep: '思考中...',
      );
      _notifyTaskUpdate();

      return true;
    } catch (e) {
      toolStopwatch.stop();
      if (!stillCurrent() || !active()) return false;
      agentLogger.error('ReAct', '工具 $toolName 执行异常: $e');
      onEvent?.call(AgentEvent.info(L10n.str.ut_2bd0b4985d(toolName, e)));
      // 工具异常也要有 result 事件，避免证据层只有命令没有结果
      final errorView = ToolResultPresenter.fromError(e);
      onEvent?.call(AgentEvent.result(
        commandId: toolCommandEvent.id,
        success: false,
        error: errorView.displayed,
        command: toolUiDisplay,
        hostId: hostId,
        toolName: toolName,
        durationMs: toolStopwatch.elapsedMilliseconds,
        failureKind: CommandFailureKind.unknown.name,
        outputTotalChars: errorView.totalChars,
        outputTruncated: errorView.truncated,
      ));

      if (!stillCurrent() || !active()) return false;

      final observation = '观测: 工具 $toolName 执行异常 — $e';
      _conversationHistory
          .add(ChatMessage.create(role: 'user', content: observation));
      _trimMessages(_conversationHistory);

      _currentTask = _currentTask!.copyWith(
        status: AgentStatus.thinking,
        currentStep: '思考中...',
      );
      _notifyTaskUpdate();
      return true;
    } finally {
      if (identical(tool.localAccess, taskLocalAccess)) {
        tool.localAccess = null;
      }
      if (tool.permissionMode == taskPermissionMode) {
        tool.permissionMode = null;
      }
    }
  }

  /// 处理无命令情况 — 发送继续提示
  /// 返回 true 表示继续循环，false 表示任务结束
  Future<bool> _handleNoCommand() async {
    _noCommandRetryCount++;
    if (_noCommandRetryCount <= _maxNoCommandRetries) {
      agentLogger.info('ReAct',
          'AI 未生成命令，发送继续提示 (重试 $_noCommandRetryCount/$_maxNoCommandRetries)');
      // 用户禁止执行命令时不能再催"去执行命令"，否则提示词和用户约束对着干。
      const continuePrompt =
          '请继续执行任务。如果还有需要执行的步骤，请使用以下格式回复：\n\n思考: [你的推理]\n说明: [一句话说明这条命令做什么、有什么影响]\n动作: execute\n命令: [要执行的命令]\n\n如果任务已全部完成，请回复：\n\n思考: [总结]\n动作: finish';
      const noCommandPrompt = '请继续完成任务。用户已明确要求本次任务不要执行任何命令，'
          '请直接给出面向用户的文字回答，然后回复：\n\n'
          '思考: [总结]\n动作: finish\n回答: [给用户的完整回答]';
      onEvent?.call(AgentEvent.info(UiText.t('⏳ 继续执行...', '⏳ Continuing...')));
      _conversationHistory.add(ChatMessage.create(
        role: 'user',
        content: _userForbadeCommands ? noCommandPrompt : continuePrompt,
      ));
      _trimMessages(_conversationHistory);
      return true;
    }

    // 重试次数耗尽 — AI 连续多次未生成有效命令，说明它已经陷入解释循环或无能力继续
    // R5: 此为异常终止，必须标记 failed，不能默认 completed 误导用户以为任务成功
    agentLogger.warn(
        'ReAct', 'AI 连续 $_noCommandRetryCount 次未生成命令，任务终止 (failed)');
    _finishTask(success: false, summary: 'AI 连续未生成有效命令，任务终止');
    return false;
  }

  /// 生成并发出操作单报告（每个 operation 只发一次）
  ///
  /// 必须覆盖所有终态路径，且在 finish 事件之前调用。
  /// 成功路径的结论来自模型总结；取消/失败/中断使用确定性模板，绝不回退到
  /// `_accumulatedMessage`（那是完整 ReAct 文本，会给用户造成误导）。
  void _emitOperationReport({
    required AgentFinishState finishState,
    String? summary,
    String? reason,
    String? answer,
  }) {
    if (_reportEmitted) return;
    final task = _currentTask;
    if (task == null) return;

    final rawSummary = (summary ?? '').trim();
    final rawAnswer = (answer ?? '').trim();
    final reasonLine = (reason ?? rawSummary).trim().split('\n').first.trim();
    final isSuccess = finishState == AgentFinishState.success;
    final fallback = _defaultConclusion(finishState, reason: reasonLine);
    final conclusion = isSuccess
        ? OperationReport.extractConclusion(
            rawSummary,
            fallback: fallback,
            answerBody: rawAnswer,
          )
        : fallback;
    final details = isSuccess
        ? OperationReport.extractDetails(rawSummary, conclusion: conclusion)
        : null;

    final nowElapsed = _taskStartTime != null
        ? DateTime.now().difference(_taskStartTime!).inSeconds
        : 0;
    final report = OperationReport(
      operationId: task.operationId ?? _operationId ?? task.id,
      taskId: task.id,
      goal: task.goal,
      hostId: hostId,
      elapsedSeconds: nowElapsed > (task.elapsedSeconds ?? 0)
          ? nowElapsed
          : (task.elapsedSeconds ?? 0),
      stepIndex: task.stepIndex > 0 ? task.stepIndex : _currentStepCount,
      commandSuccessCount: task.successCount,
      commandFailureCount: task.failureCount,
      conclusion: conclusion,
      answerBody: isSuccess && rawAnswer.isNotEmpty ? rawAnswer : null,
      details: details,
      nextActions:
          isSuccess ? OperationReport.extractNextActions(rawSummary) : const [],
      changeRecordIds: List<String>.unmodifiable(_operationChangeIds),
      changes: List<OperationChange>.unmodifiable(_operationChanges),
      plan: List<PlanStep>.unmodifiable(_currentPlan),
      stateBadges: isSuccess
          ? List<OperationBadge>.unmodifiable(_operationBadges)
          : const [],
      verified: isSuccess && _operationBadges.any((b) => b.level == 'success'),
      aiGenerated: isSuccess && (rawSummary.isNotEmpty || rawAnswer.isNotEmpty),
      finishState: finishState.name,
    );

    _reportEmitted = true;
    onEvent?.call(AgentEvent.report(report, hostId: hostId));
  }

  String _defaultConclusion(AgentFinishState state, {String? reason}) {
    final step = _currentStepCount > 0 ? '第 $_currentStepCount 步' : '当前步骤';
    switch (state) {
      case AgentFinishState.success:
        final count = _currentTask?.successCount ?? 0;
        return count > 0 ? '任务已完成，共执行 $count 条命令。' : '任务已完成。';
      case AgentFinishState.cancelled:
        return '任务已取消于$step。';
      case AgentFinishState.failed:
        final r = (reason ?? '').trim();
        return r.isEmpty ? '任务执行失败。' : '任务执行失败：$r';
      case AgentFinishState.interrupted:
        return '任务在$step达到步数上限后中断。';
    }
  }

  /// finish 事件/日志用的收尾文本：四段字段 + 回答正文。
  ///
  /// 目标模式靠 finishSummary 里的完成标记判断目标是否达成，而提示词要求
  /// 标记写在 `回答:` 正文里；只拼 summary 会让标记永远检测不到。
  String _composeFinishSummary({String? summary, String? answer}) {
    final thought = (summary ?? '').trim();
    final body = (answer ?? '').trim();
    if (thought.isEmpty) {
      return body.isNotEmpty ? body : _accumulatedMessage;
    }
    if (body.isEmpty) return thought;
    return '$thought\n\n$body';
  }

  /// 标记任务为已完成（统一的结束逻辑）
  ///
  /// R5: 终态骨架由 [_terminationGuard] 编排（status→report→finish→flush→tracer，
  /// 清理放 finally）；本方法只负责裁剪历史、合成收尾文本、引擎私有资源清理
  /// 与完成通知。所有调用点保持不变。
  void _finishTask({bool success = true, String? summary, String? answer}) {
    final status = _currentTask?.status;
    if (status == AgentStatus.paused ||
        status == AgentStatus.cancelled ||
        status == AgentStatus.completed ||
        status == AgentStatus.failed) {
      return;
    }
    _trimMessages(_conversationHistory);
    final startTime = _currentTask?.createdAt;
    final finishState =
        success ? AgentFinishState.success : AgentFinishState.failed;
    final finishSummary =
        _composeFinishSummary(summary: summary, answer: answer);
    // onCompleted 仍传完整累积文本：持久化需要完整上下文，
    // 操作单结论只使用 step.thought 生成的 finishSummary。
    final completionMessage =
        _accumulatedMessage.isNotEmpty ? _accumulatedMessage : finishSummary;

    _terminationGuard.terminate(
      status: success ? AgentStatus.completed : AgentStatus.failed,
      finishState: finishState,
      writeStatus: (status) {
        _currentTask = _currentTask!.copyWith(
          status: status,
          phase: success
              ? UiText.t('整理结论', 'Summarizing')
              : UiText.t('执行失败', 'Failed'),
          completedAt: DateTime.now(),
        );
        _notifyTaskUpdate();
        agentLogger.info('AutoExec', '=== 任务${success ? "完成" : "终止"} ===');
      },
      // 报告结论只接受模型显式总结；summary 为空时用确定性模板，
      // 绝不把 _accumulatedMessage（完整 ReAct 文本）当结论。
      emitReport: () => _emitOperationReport(
        finishState: finishState,
        summary: success ? summary : null,
        reason: success ? null : summary,
        answer: success ? answer : null,
      ),
      // L6 修复：补发 finish 事件，让 UI 显示完成卡片并正确结束渲染状态
      emitFinish: () => onEvent?.call(AgentEvent.finish(
        summary: finishSummary,
        finishState: finishState,
      )),
      flush: completionMessage.isEmpty
          ? null
          : () => onCompleted?.call(completionMessage),
      endTracer: () {
        final taskId = _currentTask?.id;
        if (taskId != null) {
          AgentTracer.instance.endTask(
            taskId,
            status: success ? 'completed' : 'failed',
            summary: finishSummary,
            hostId: hostId,
          );
        }
      },
      cleanup: _cleanupAfterTermination,
    );

    // 任务完成通知（异步，不阻塞引擎）
    _notifyTaskCompletion(success: success, startTime: startTime);
    // 重置会话级源码读取授权状态（R2：资源生命周期 — 任务结束清理）
    _sessionSourceCodeGranted = false;
  }

  /// 终态后的瞬态资源清理（供 TerminationGuard 的 finally 调用）。
  ///
  /// R2: 不依赖下次 startTask 才清理；不清理 _currentTask /
  /// _accumulatedMessage / _conversationHistory（任务结果数据要保留）。
  void _cleanupAfterTermination() {
    _localAccess?.revokeAll();
    _localAccess = null;
    _aiWatchdog?.cancel();
    _aiWatchdog = null;
    _aiStreamSub?.cancel();
    _aiStreamSub = null;
    // R1: 与 _resetTransientState/cancelTask/pauseTask 一致，先 complete 再置 null。
    // 若走到这里 doneCompleter 尚未 complete（流未 onDone），说明仍有 awaiter
    // 挂在 future 上，直接置 null 会让它永久挂起；complete 幂等，已完成时是 no-op。
    final dc = _aiDoneCompleter;
    if (dc != null && !dc.isCompleted) dc.complete();
    _aiDoneCompleter = null;
    _aiCancelToken?.cancel('引擎瞬态状态重置');
    _aiCancelToken = null;
    if (_commandCancelToken != null && !_commandCancelToken!.isCompleted) {
      _commandCancelToken!.complete();
    }
    _commandCancelToken = null;
    if (_orchestratorCancelToken != null &&
        !_orchestratorCancelToken!.isCompleted) {
      _orchestratorCancelToken!.complete();
    }
    _orchestratorCancelToken = null;
    final mhe = _tools.multiHostExecutor;
    if (mhe != null) {
      mhe.cancelToken = null;
    }
    _confirmTimeoutTimer?.cancel();
    _confirmTimeoutTimer = null;
    _interactiveInputTimeoutTimer?.cancel();
    _interactiveInputTimeoutTimer = null;
    // 终态可能由 AI 失败/提前执行异常触发，未必已经退出所有等待。
    // 必须先 complete 再清空，确保局部 awaiter 都能收口（R1/R2）。
    final confirm = _confirmCompleter;
    if (confirm != null && !confirm.isCompleted) confirm.complete(false);
    _confirmCompleter = null;
    _pendingConfirmCommand = null;
    final choice = _choiceCompleter;
    if (choice != null && !choice.isCompleted) choice.complete('');
    _choiceCompleter = null;
    _pendingOptions = [];
    final input = _interactiveInputCompleter;
    if (input != null && !input.isCompleted) input.complete(null);
    _interactiveInputCompleter = null;
  }

  /// 推送任务完成通知（异步触发，不阻塞引擎主流程）
  void _notifyTaskCompletion(
      {required bool success, DateTime? startTime, String? error}) {
    final task = _currentTask;
    if (task == null) return;
    final duration =
        startTime != null ? DateTime.now().difference(startTime) : null;
    // 异步推送，不 await，避免阻塞 UI；用独立 async 块 + try/catch 避免 catchError 类型问题
    () async {
      try {
        await NotificationService.notifyTaskCompletion(
          goal: task.goal,
          success: success,
          duration: duration,
          error: error,
        );
      } catch (e) {
        agentLogger.warn('Notification', '推送通知失败: $e');
      }
    }();
  }

  /// 命令执行预检总开关（默认开）：未闭合命令、交互式阻塞命令、退出码不可靠的
  /// 管道/后台命令都在下发前静态拦截并回灌 AI 改写。
  /// 关闭后仅依赖执行器的 PS2 检测与超时兜底（兼容个别被误判的特殊命令）。
  bool get _commandClosureGuard =>
      SettingsDao.getCached('commandClosureGuard', defaultValue: true) != false;

  /// 命令是否可安全提前执行（流式阶段未闭合的命令不提前下发）。
  /// 与 [_executeCommand] 的预检同一口径，避免两处判断漂移。
  bool _commandIsShellBalanced(String command) {
    if (!_commandClosureGuard) return true;
    final ex = _currentExecutor;
    final isWindows = ex is SSHService
        ? ex.osInfo.toLowerCase().contains('window')
        : Platform.isWindows;
    return ShellSyntax.unclosedReason(command, isWindows: isWindows) == null;
  }

  /// 执行单条命令（支持 SSH 和本地 PTY）
  /// [myGeneration] 任务代际，用于 await 后识别"取消 + 立即新任务"竞态
  /// [countDisconnect] 断线是否计入连续失败预算。回滚预快照走同一条执行路径，
  /// 但它不产生 AI 可见的观测——若也计数，一条断链的主命令会记 2 次，
  /// 门限比宣称的提前一条命中。
  Future<AgentResult> _executeCommand(CommandExecutor executor, String command,
      {int? myGeneration,
      bool countDisconnect = true,
      void Function()? onStarted}) async {
    final stopwatch = Stopwatch()..start();
    final generation = myGeneration ?? _currentTaskGeneration;
    final taskId = _currentTask?.id;
    final interactiveEchoes = <({String prompt, String answer})>[];
    Completer<String?>? interactiveInputCompleter;
    bool stillCurrent() => _isSameTask(generation, taskId);
    bool active() => _isTaskActive(generation, taskId);

    // R1: 取消可能落在安全检查/快照与真正创建 _commandCancelToken 之间。
    // 若不在这里拦截，会新建一个没人取消的 token，静默把命令跑完，
    // 用户看到的就是“已点停止，Agent 还在执行”。
    if (!stillCurrent() || !active()) {
      return AgentResult(
        success: false,
        error: '用户取消了任务',
        duration: stopwatch.elapsed,
        failureKind: CommandFailureKind.cancelled.name,
      );
    }

    // 目标达成标记不是命令。真机复拍发现模型会把「目标已达成」写进 命令: 块，
    // 丢进 shell 只会得到一条 CommandNotFoundException；提示词只能降低概率，
    // 所以执行侧必须有这道硬守卫。
    if (isGoalMarkerOnlyCommand(command)) {
      agentLogger.info('ReAct', '忽略被当成命令的目标达成标记');
      return AgentResult(
        success: true,
        output: '这一行是结论标记，不需要执行。若目标确已达成，请在 回答: 正文里说明结果。',
        duration: stopwatch.elapsed,
      );
    }

    // 命令闭合预检（任务②）：未闭合命令进 PTY 会让 shell 停在 PS2 等待输入，
    // marker 永不出现 → 干等超时。这里在写入终端前静态拦截，返回 syntaxError
    // 并通过 failureReason 回灌给 AI，让它自行修正（比等 60s–10min 超时廉价得多）。
    // Windows 的 cmd/PowerShell 规则不同，直接放行交给执行器的 PS2/超时兜底。
    final isWindowsShell = executor is SSHService
        ? executor.osInfo.toLowerCase().contains('window')
        : Platform.isWindows;
    final unclosed = _commandClosureGuard
        ? ShellSyntax.unclosedReason(command, isWindows: isWindowsShell)
        : null;
    if (unclosed != null) {
      _commandRejectedThisTurn = true;
      _syntaxRejectCount++;
      agentLogger.warn('ReAct',
          '命令闭合预检拦截(${"$_syntaxRejectCount/$_maxSyntaxRejects"}): $unclosed — ${_logCommand(command)}');
      // 拦截计数只用 _syntaxRejectCount + 轮次硬停止收敛（见 _blockedTurnsStreak）；
      // 不再借 _noCommandRetryCount：那条计数每轮会被 follow-up 收尾清零，等于无效。
      final exhausted = _syntaxRejectCount >= _maxSyntaxRejects;
      return AgentResult(
        success: false,
        error: '命令未闭合：$unclosed',
        duration: stopwatch.elapsed,
        failureKind: CommandFailureKind.syntaxError.name,
        failureReason: exhausted
            ? '命令未闭合：$unclosed。已连续 $_syntaxRejectCount 次拦截同类错误。'
                '请勿再直接提交命令：先用 回答: 说明当前阻碍并请求人工介入，或改用不涉及引号/heredoc 的极简命令。'
            : '命令未闭合：$unclosed。命令未进入 shell，请补全后再提交（heredoc 必须有独立结束行；'
                '引号/圆括号必须成对）。',
      );
    }

    // 交互式阻塞命令预检：top/vim/tail -f/REPL 这类命令永不自行返回，
    // 进 PTY 只会卡到超时（且不在 PS2，闭合预检与续行兜底都覆盖不到）。
    // 与闭合预检共用拦截计数预算，回灌非交互等价命令建议让 AI 自行改写。
    if (_commandClosureGuard && isBlockingInteractiveCommand(command)) {
      _commandRejectedThisTurn = true;
      _syntaxRejectCount++;
      final exhausted = _syntaxRejectCount >= _maxSyntaxRejects;
      agentLogger.warn('ReAct',
          '交互阻塞命令拦截(${"$_syntaxRejectCount/$_maxSyntaxRejects"}): ${_logCommand(command)}');
      return AgentResult(
        success: false,
        error: '交互式命令会持续运行不返回',
        duration: stopwatch.elapsed,
        failureKind: CommandFailureKind.syntaxError.name,
        failureReason: exhausted
            ? '已连续 $_syntaxRejectCount 次提交交互式命令。请勿再提交：用 回答: 说明阻碍，'
                '或改用一次性命令（ps aux 代替 top、tail -n 50 代替 tail -f、sed 代替 vim）。'
            : '检测到交互式命令，它会持续运行不返回、导致超时。请改用一次性等价命令：'
                'ps aux --sort=-%cpu | head 代替 top；tail -n 50 代替 tail -f；'
                'grep/sed 代替 less/vim；python -c "..." 代替 python REPL。',
      );
    }

    // 退出码可靠性预检：wrapper 的 `$?` 取最后一段，后台/修改类管道会给出
    // 假成功观测——不卡死但结论错误，比卡死更隐蔽。纯查询管道（ps | head）
    // 已由 unreliableExitCodeReason 放行，避免与上面的非交互建议形成死循环。
    // Windows 跳过：cmd 的 `&` 是顺序执行、PowerShell 的 `&` 是调用运算符，
    // 都不是后台语义，套用 POSIX 规则会把 `& $env:APP\app.exe` 判成后台命令。
    final exitCodeIssue = _commandClosureGuard && !isWindowsShell
        ? unreliableExitCodeReason(command)
        : null;
    if (exitCodeIssue != null) {
      _commandRejectedThisTurn = true;
      _syntaxRejectCount++;
      final exhausted = _syntaxRejectCount >= _maxSyntaxRejects;
      agentLogger.warn('ReAct',
          '退出码不可靠拦截(${"$_syntaxRejectCount/$_maxSyntaxRejects"}): $exitCodeIssue — ${_logCommand(command)}');
      return AgentResult(
        success: false,
        error: exitCodeIssue,
        duration: stopwatch.elapsed,
        failureKind: CommandFailureKind.syntaxError.name,
        failureReason: exhausted
            ? '已连续 $_syntaxRejectCount 次提交退出码不可靠的命令。请勿再提交：用 回答: 说明阻碍，'
                '或改用拆分后的顺序命令。'
            : '$exitCodeIssue。请改为可确认完成状态的写法：后台任务用前台 + timeout；'
                '管道拆成顺序命令（先落盘到临时文件再处理），或显式检查 \${PIPESTATUS[0]} / \$!。',
      );
    }

    // 通过静态预检并不等于已执行；连接检查也通过后才标记 started。
    _syntaxRejectCount = 0;

    // 执行前检查连接状态
    // 自愈：若传入的 executor 已断开，但 _currentExecutor 已被 setExecutor 刷新（用户重连），
    // 改用新 executor。避免循环持有旧 SSHService 引用导致连续失败。
    if (!executor.isConnected) {
      final refreshed = _currentExecutor;
      if (refreshed != null && refreshed != executor && refreshed.isConnected) {
        agentLogger.info('AgentEngine', '检测到旧 executor 断开，自愈切换到新 executor');
        executor = refreshed;
      } else {
        if (countDisconnect) {
          _consecutiveConnFailures++;
          agentLogger.warn('AgentEngine',
              '连接已断开 (连续 $_consecutiveConnFailures/$_connFailBudget)');
        }
        // 连续多次断开 → 返回明确错误引导 AI 用 ask 动作等待用户重连
        final isSSH = executor is SSHService;
        final hint = countDisconnect ? _connFailGuidance() : '';
        return AgentResult(
          success: false,
          error: isSSH ? 'SSH 连接已断开，请重连后重试$hint' : '本地终端已退出，请重新打开终端$hint',
          duration: stopwatch.elapsed,
          failureKind: CommandFailureKind.disconnected.name,
        );
      }
    } else if (countDisconnect) {
      // 连接正常：重置连续失败计数。快照命令不参与，交给它自己的主命令记账，
      // 否则"主命令断线 + 下一条前快照正常"会把计数抹掉，门限永远打不满。
      _consecutiveConnFailures = 0;
    }

    if (!stillCurrent() || !active()) {
      return AgentResult(
        success: false,
        error: '用户取消了任务',
        duration: stopwatch.elapsed,
        failureKind: CommandFailureKind.cancelled.name,
      );
    }
    // 每条命令使用局部 token 与回显表；旧执行器返回时不能清掉新命令的 token。
    final commandCancelToken = Completer<void>();
    _commandCancelToken = commandCancelToken;

    // sudo 密码交给执行器应答：执行器在输出流上识别提示并写入 PTY stdin。
    // 密码不进命令串、不进审计日志、也不回传给模型（AGENTS.md R7）。
    //
    // 早先这里由引擎自己订阅 executor.output 做注入，和执行器内的
    // PtyOutputDetector 抢同一段输出：检测器 300ms 后先 complete() 并让调用方
    // 发 Ctrl+C，sudo 还没读到密码就被打断。现在两条职责合并到执行器一处。
    final sudoPassword = (_sudoPassword != null &&
            _sudoPassword!.isNotEmpty &&
            _isSudoCommand(command))
        ? _sudoPassword
        : null;

    try {
      onStarted?.call();
      final result = await executor.executeAndWait(
        command,
        timeout: getCommandTimeout(command),
        cancelToken: commandCancelToken,
        sudoPassword: sudoPassword,
        // 确认类交互提示桥接：统一交回 UI 弹窗（见方法注释）。
        // 密码类提示不走此桥，检测器仍按 interactivePrompt 中断（R7）。
        onInteractivePrompt: (prompt) => _requestInteractiveInput(
          prompt,
          myGeneration: generation,
          taskId: taskId,
          interactiveEchoes: interactiveEchoes,
          onCompleter: (completer) => interactiveInputCompleter = completer,
        ),
      );

      // 只收口本次执行创建的交互等待，不能 complete 新命令的弹窗。
      final pendingInput = interactiveInputCompleter;
      if (identical(_interactiveInputCompleter, pendingInput) &&
          pendingInput != null &&
          !pendingInput.isCompleted) {
        pendingInput.complete(null);
      }
      if (identical(_commandCancelToken, commandCancelToken)) {
        _commandCancelToken = null;
      }
      stopwatch.stop();

      // R1: 用户取消或任务被替换（cancelTask + 立即新任务）→ 返回已取消结果。
      if (!stillCurrent() || !active()) {
        return AgentResult(
          success: false,
          error: '用户取消了任务',
          duration: stopwatch.elapsed,
          failureKind: CommandFailureKind.cancelled.name,
        );
      }

      // 清理 ANSI 转义序列
      var cleanOutput = AnsiStripper.strip(result.stdout);
      // 命令回显已由执行器层去除（stripWrappedEcho），这里不再二次清洗——
      // 第二遍 stripCommandEcho 会把首行恰含命令词的真实输出删掉（R8 单点清洗）
      // 清理交互提示 + 用户答案的回显行（O3）：它不是命令输出，
      // 留在观测里模型会当成下一条命令执行
      cleanOutput = stripInteractiveEcho(cleanOutput, interactiveEchoes);

      return AgentResult.fromCommand(
        command: command,
        stdout: cleanOutput,
        stderr: result.stderr,
        exitCode: result.exitCode,
        duration: stopwatch.elapsed,
        failureKind: result.failureKind == CommandFailureKind.none
            ? null
            : result.failureKind.name,
        failureReason:
            _withConnGuidance(result, countDisconnect: countDisconnect),
      );
    } catch (e) {
      stopwatch.stop();
      if (identical(_commandCancelToken, commandCancelToken)) {
        _commandCancelToken = null;
      }
      final pendingInput = interactiveInputCompleter;
      if (identical(_interactiveInputCompleter, pendingInput) &&
          pendingInput != null &&
          !pendingInput.isCompleted) {
        pendingInput.complete(null);
      }
      if (!stillCurrent() || !active()) {
        return AgentResult(
          success: false,
          error: '用户取消了任务',
          duration: stopwatch.elapsed,
          failureKind: CommandFailureKind.cancelled.name,
        );
      }
      return AgentResult(
        success: false,
        error: e.toString(),
        duration: stopwatch.elapsed,
        failureKind: CommandFailureKind.unknown.name,
      );
    }
  }

  /// 滚动压缩（O7）：把早期消息整体并入会话级滚动摘要。
  ///
  /// 与逐条摘要不同：每次把「上一份摘要 + 本次新增消息」合并成一份整体摘要，
  /// 【关键事实】段（主机环境、用户明确约束）要求逐字保留，不随多次压缩丢失。
  /// 返回 null 表示压缩失败，调用方必须保持原状（不得留下半截标记）。
  Future<String?> summarizeRolling({
    String? previousSummary,
    required List<
            ({
              String role,
              String content,
              String? command,
              bool? commandSuccess
            })>
        messages,
  }) async {
    if (messages.isEmpty) return null;

    agentLogger.info('Compact',
        '开始滚动压缩 ${messages.length} 条消息（已有摘要: ${previousSummary != null && previousSummary.isNotEmpty}）');

    final buffer = StringBuffer();
    buffer.writeln('你是对话压缩助手。请把「已有摘要」与「新增对话」合并为一份滚动摘要。');
    buffer.writeln();
    buffer.writeln('输出格式（纯文本，两个段落，不要 markdown 代码块标记）：');
    buffer.writeln('【关键事实】');
    buffer.writeln('- 主机环境（操作系统/发行版/主机名/架构等）');
    buffer.writeln('- 用户明确约束与偏好（如「不要重启」「只用 nginx」）');
    buffer.writeln('- 重要路径、版本、账号等需要长期记住的事实');
    buffer.writeln('【对话进展】');
    buffer.writeln('- 用户目标、已执行命令及结果、当前系统状态、遗留问题、下一步计划');
    buffer.writeln();
    buffer.writeln('压缩规则：');
    buffer.writeln('- 已有摘要【关键事实】中的条目必须逐字保留，不得改写、合并或遗漏');
    buffer.writeln('- 新增对话中出现的新关键事实追加进【关键事实】');
    buffer.writeln('- 寒暄/重复表述压缩为一句话意图');
    buffer.writeln('- 查询类命令输出只保留关键结论，冗长输出直接丢弃');
    buffer.writeln('- 修改类命令只保留"执行成功"或"失败原因"');
    buffer.writeln('- AI 推理只保留关键决策和结论');
    buffer.writeln('- 不要编造未出现的信息');
    buffer.writeln('- 整份摘要控制在 1200 字以内');
    buffer.writeln();
    buffer.writeln('=== 已有摘要 ===');
    buffer.writeln(previousSummary == null || previousSummary.isEmpty
        ? '（无，首次压缩）'
        : previousSummary);
    buffer.writeln();
    buffer.writeln('=== 新增对话 ===');
    for (final m in messages) {
      final label = m.role == 'user' ? '用户' : 'AI';
      buffer.writeln('$label: ${m.content}');
      if (m.command != null) {
        buffer.writeln(
            '  [命令] ${m.command} → ${m.commandSuccess == true ? "成功" : m.commandSuccess == false ? "失败" : "未知"}');
      }
      buffer.writeln('---');
    }

    try {
      final history = [
        ChatMessage.create(role: 'system', content: '你是对话压缩助手，只输出滚动摘要纯文本，不要解释。')
      ];
      final stream = await _aiProvider.chatStream(
        history: history,
        prompt: buffer.toString(),
        config: _modelConfig,
        systemPrompt: null,
        responseTimeout: aiResponseTimeout,
      );

      final raw = StringBuffer();
      var truncated = false;
      // 压缩看门狗：防止 AI 流式卡住导致 compact 永久挂起
      await for (final chunk in stream.timeout(
        aiResponseTimeout,
        onTimeout: (sink) {
          agentLogger.warn(
              'Compact', '压缩流超时(${aiResponseTimeout.inSeconds}s)，终止并使用已收集内容');
          sink.close();
        },
      )) {
        final remaining = _maxRollingSummaryChars - raw.length;
        if (remaining <= 0) {
          truncated = true;
          break;
        }
        if (chunk.length <= remaining) {
          raw.write(chunk);
        } else {
          var end = remaining;
          if (end > 0 &&
              _isHighSurrogate(chunk.codeUnitAt(end - 1)) &&
              _isLowSurrogate(chunk.codeUnitAt(end))) {
            end--;
          }
          raw.write(chunk.substring(0, end));
          truncated = true;
          break;
        }
      }
      if (truncated) {
        agentLogger.warn('Compact', '滚动压缩结果超过上限，已截断并取消后续流');
      }

      var text = _stripCodeFence(raw.toString().trim());
      if (text.isEmpty) {
        agentLogger.warn('Compact', '滚动压缩结果为空');
        return null;
      }
      // 硬上限：摘要自身不能成为新的上下文负担。保头——【关键事实】段在开头
      if (text.length > _maxRollingSummaryChars) {
        var end = _maxRollingSummaryChars;
        if (end > 0 &&
            _isHighSurrogate(text.codeUnitAt(end - 1)) &&
            _isLowSurrogate(text.codeUnitAt(end))) {
          end--;
        }
        text = text.substring(0, end);
      }
      if (truncated &&
          text.isNotEmpty &&
          _isHighSurrogate(text.codeUnitAt(text.length - 1))) {
        text = text.substring(0, text.length - 1);
      }
      agentLogger.info('Compact', '滚动压缩完成: ${text.length} 字符');
      return text;
    } catch (e, stack) {
      agentLogger.error('Compact', '滚动压缩失败: $e\n$stack');
      return null;
    }
  }

  /// 滚动摘要硬上限（字符）：提示词要求 ≤1200 字，模型超发时兜底截断
  static const int _maxRollingSummaryChars = 4000;

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  /// 去掉模型可能包裹的 markdown 代码块标记
  String _stripCodeFence(String raw) {
    var text = raw;
    if (text.startsWith('```')) {
      final firstNewline = text.indexOf('\n');
      if (firstNewline > 0) text = text.substring(firstNewline + 1);
      if (text.endsWith('```')) {
        text = text.substring(0, text.length - 3);
      }
    }
    return text.trim();
  }

  /// 判断 AI 调用错误是否值得重试（429限流 / 连接错误 / 超时）
  /// 401/400/403 等不可重试
  bool _isRetryableError(dynamic error) {
    if (error is TimeoutException) return true;
    if (error is DioException) {
      return error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          (error.response?.statusCode == 429) ||
          (error.response != null && error.response!.statusCode! >= 500);
    }
    // 网络相关异常字符串兜底
    final msg = error.toString().toLowerCase();
    return msg.contains('connection') ||
        msg.contains('timeout') ||
        msg.contains('reset by peer');
  }

  /// 判断 AI 调用错误是否因取消（取消不可重试，重试违背用户意图）
  /// - DioExceptionType.cancel：Dio CancelToken.cancel() 触发的异常
  /// - StateError('任务已取消'/'任务已被新任务覆盖')：上层代际检查抛出
  bool _isCancellationError(dynamic error) {
    if (error is DioException && error.type == DioExceptionType.cancel) {
      return true;
    }
    if (error is StateError &&
        (error.message == '任务已取消' || error.message == '任务已被新任务覆盖')) {
      return true;
    }
    return false;
  }

  /// 将异常转为用户友好的错误消息
  String _friendlyErrorMessage(dynamic error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.badResponse:
          final statusCode = error.response?.statusCode;
          if (statusCode == 401) {
            return L10n.str.errApiKeyInvalid;
          } else if (statusCode == 429) {
            return L10n.str.errRateLimit;
          } else if (statusCode == 400) {
            return L10n.str.errBadRequest;
          } else if (statusCode != null && statusCode >= 500) {
            return L10n.str.errServerError(statusCode);
          }
          return L10n.str.errRequestFailed(statusCode ?? 0);
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return L10n.str.errConnectionTimeout;
        case DioExceptionType.connectionError:
          return L10n.str.errConnectionError;
        default:
          return L10n.str.errConnectionFailed(error.message ?? 'Unknown');
      }
    }
    return L10n.str.errExecutionError(error.toString());
  }

  /// 从 AI 响应中提取所有可执行命令（委托给 CommandExtractor）
  List<String> _extractCommands(String content) =>
      CommandExtractor.extractCommands(content);

  // ── O4/WP6: 计划进度注入（每轮幂等替换 system 消息中的标记段） ──

  /// 计划进度段起止标记（与 PromptBuilder 共享单一来源）
  static const String _planProgressStartMarker =
      PromptBuilder.planProgressStartMarker;
  static const String _planProgressEndMarker =
      PromptBuilder.planProgressEndMarker;

  /// 把计划进度快照幂等同步进 system 消息（_conversationHistory[0]）。
  ///
  /// 每轮 ReAct 循环顶部（代际/暂停检查之后、_callAI 之前）调用：
  /// - 有计划：先整段移除旧快照，再把最新快照追加到 system 消息末尾，
  ///   保证多轮始终只有一段且内容最新（system 消息每任务重建，跨轮不累积）；
  /// - 无计划：移除该段。
  /// system 消息缺失时不做任何事（防御性，循环内不应出现）。
  void _syncPlanProgressToSystemMessage() {
    if (_conversationHistory.isEmpty ||
        _conversationHistory[0].role != 'system') {
      return;
    }
    final systemMsg = _conversationHistory[0];
    var content = systemMsg.content;
    final startIdx = content.indexOf(_planProgressStartMarker);
    if (startIdx >= 0) {
      final endIdx = content.indexOf(_planProgressEndMarker, startIdx);
      // 连同注入时添加的 '\n\n' 分隔一起移除，还原原始 system 内容
      var cutStart = startIdx;
      if (cutStart >= 2 &&
          content.substring(cutStart - 2, cutStart) == '\n\n') {
        cutStart -= 2;
      }
      if (endIdx >= 0) {
        content = content.substring(0, cutStart) +
            content.substring(endIdx + _planProgressEndMarker.length);
      } else {
        // 防御：只有起标记没有止标记时，丢弃起标记之后的全部内容
        content = content.substring(0, cutStart);
      }
    }
    if (_currentPlan.isNotEmpty) {
      content = '${content.trimRight()}\n\n${_buildPlanProgressBlock()}';
    }
    if (content != systemMsg.content) {
      _conversationHistory[0] =
          ChatMessage.create(role: 'system', content: content);
    }
  }

  /// 生成计划进度段：计划各行 + finish 完整性指令（委托 PromptBuilder）
  String _buildPlanProgressBlock() =>
      PromptBuilder.buildPlanProgressBlock(_currentPlan);

  // ── O4/WP6 测试入口 ──
  @visibleForTesting
  List<ChatMessage> get conversationHistoryForTesting => _conversationHistory;

  @visibleForTesting
  void setPlanForTesting(List<PlanStep> plan) {
    _currentPlan = List<PlanStep>.unmodifiable(plan);
  }

  @visibleForTesting
  void syncPlanProgressForTesting() => _syncPlanProgressToSystemMessage();

  @visibleForTesting
  int get planFinishRetryCountForTesting => _planFinishRetryCount;

  @visibleForTesting
  int get finishWithoutExecCountForTesting => _finishWithoutExecCount;

  @visibleForTesting
  bool get hasExecutedAnyCommandForTesting => _hasExecutedAnyCommand;

  @visibleForTesting
  bool get userForbadeCommandsForTesting => _userForbadeCommands;

  String _buildSystemPrompt(CommandExecutor? executor) {
    final buffer = StringBuffer();

    buffer.writeln('你是 AI 助手，可以执行命令。');

    // 语言自适应：让 AI 根据用户使用的语言回复
    buffer.writeln('【语言要求】');
    buffer.writeln(
        "Always respond in the same language the user uses. If the user speaks Japanese, reply in Japanese; if French, reply in French; if Chinese, reply in Chinese; and so on. Your thinking, explanations, and summaries must all follow the user's language. Commands and technical terms remain as-is.");
    buffer.writeln();

    buffer.writeln('【ReAct 自动执行模式】');
    buffer.writeln('你正在使用 ReAct（推理-行动-观测）框架。');
    buffer.writeln();
    // O8 FC-first：支持原生 Function Calling 的模型用 FC 规则（动作走 tool_calls），
    // 其余模型维持文本协议。fallback 切换到不支持 FC 的模型时，
    // agentFcRule 里的降级兼容条款 + 引擎的文本解析兜底保证仍能工作。
    final fcMode = _modelConfig.supportsFunctionCalling;
    buffer.writeln(fcMode ? prompts.agentFcRule : prompts.agentAutoRule);

    buffer.writeln();
    buffer.writeln(prompts.behaviorBoundaryRule);
    buffer.writeln();
    buffer.writeln(prompts.commandClosureRule);
    buffer.writeln();
    buffer.writeln(prompts.installSafetyRule);
    buffer.writeln();
    buffer.writeln(prompts.dangerousCommandExplainRule);

    // 用户自定义提示词
    String? customPrompt;
    try {
      customPrompt = _getCustomPrompt();
    } catch (e) {
      debugPrint('[AgentEngine] 读取自定义提示词失败: $e');
    }
    if (customPrompt != null && customPrompt.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('【用户自定义指令】');
      buffer.writeln(customPrompt);
    }

    // 内部规范注入：同步读 DAO 缓存，无 await 故无需代际检查；
    // 每轮重建意味着用户中途改规范即时生效
    final rulesInjection = buildRulesInjection(hostId: hostId);
    if (rulesInjection != null) {
      buffer.writeln();
      buffer.writeln(rulesInjection);
    }

    // 工具能力注入（告诉 AI 有哪些非 shell 工具可用）
    // 同步联网工具注册状态：合并全局开关 + 会话级开关
    // 必须在 buildToolsPrompt 之前调用，保证 system prompt 与 _tools 状态一致
    _syncWebToolsRegistration();
    final toolsPrompt = _tools.buildToolsPrompt(
        isLocalSession: executor != null && executor is! SSHService,
        fcMode: fcMode);
    if (toolsPrompt.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(toolsPrompt);
    }

    // 联网搜索能力提示（仅当工具已注册时注入，引导 AI 主动使用）
    if (_tools.isWebToolsEnabled) {
      buffer.writeln();
      buffer.writeln('【联网搜索】');
      buffer.writeln('你已具备联网能力：可使用 web_search 工具搜索最新信息，用 fetch_url 抓取网页正文。');
      buffer.writeln('何时使用：');
      buffer.writeln('- 你的训练数据可能过时（如最新版本号、近期新闻、新发布的软件包）');
      buffer.writeln('- 遇到不熟悉的错误信息、概念、API');
      buffer.writeln('- 用户明确要求"查一下"或"搜索"');
      buffer.writeln('何时不使用：你已有把握的知识不要盲目搜索，避免浪费配额。优先用已有知识 + 命令执行解决任务。');
    }

    // 本地项目部署工作流提示（仅在本地终端会话时注入）
    if (executor != null && executor is! SSHService) {
      final deployPrompt = _buildLocalDeployPrompt();
      if (deployPrompt.isNotEmpty) {
        buffer.writeln();
        buffer.writeln(deployPrompt);
      }
    }

    // 多机编排模式注入
    if (_orchestratorMode && _tools.multiHostExecutor != null) {
      buffer.writeln();
      buffer.writeln(_buildOrchestratorPrompt());
    }

    // 执行权限档位注入
    buffer.writeln();
    buffer.writeln(_permissionModePrompt());

    // 注：早期对话摘要已改为逐条写入 ConvMessage.summary，不再在 system prompt 中注入

    // 执行位置：远程会话里 execute 与 local_exec 的边界必须写死
    buffer.writeln();
    buffer.writeln(_executionLocationPrompt(executor));

    if (executor != null) {
      buffer.writeln('\n【系统环境】');
      if (executor is SSHService && executor.osInfo.isNotEmpty) {
        buffer.writeln(executor.osInfo);
      } else {
        buffer.writeln('平台: ${Platform.operatingSystem}');
        buffer.writeln('主机: 本地 (${Platform.localHostname})');
        buffer.writeln(
            '用户: ${Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? 'unknown'}');
      }
    }

    final memory = _memory.buildContext();
    if (memory.isNotEmpty) buffer.writeln('\n$memory');

    return buffer.toString();
  }

  /// 构建多机编排模式 system prompt 段落
  String _buildOrchestratorPrompt() {
    final executor = _tools.multiHostExecutor!;
    final hostList = executor.buildHostListText();
    return '''【多机编排模式】
你正在多机编排模式下工作，需要跨多台主机调度操作。

【可用主机清单】
$hostList

【编排规则】
1. 跨主机执行命令必须用工具调用，不要用普通 execute：
   动作: tool
   工具: exec_on
   参数:
     hostId: web1
     command: systemctl status nginx
     timeout: 30

2. 批量执行同一命令到多机（如时间同步、日志清理）：
   动作: tool
   工具: exec_batch
   参数:
     hostIds: web1,web2,db1
     command: ntpdate ntp.aliyun.com
     stopOnFailure: false

3. 跨机连通性测试（部署前验证网络依赖）：
   动作: tool
   工具: check_connectivity
   参数:
     fromHostId: web1
     targetHost: 192.168.1.20
     port: 3306

4. 跨机上传文件/目录到指定主机（部署构建产物等）：
   动作: tool
   工具: upload_to
   参数:
     hostId: web1
     local: /path/to/dist
     remote: /var/www
     recursive: true

5. 高风险操作（restart/stop/修改配置/删除）必须先用 ask 询问用户确认
6. 一台主机失败时，用 ask 询问用户选择：中止/跳过该台继续/重试
7. 不要假设主机间网络互通，关键依赖（如 web→db）必须用 check_connectivity 验证
8. 普通 execute 命令仍可用，但只在当前活跃主机执行，不跨主机
9. 部署类任务建议分阶段：规划 → 用 ask 确认矩阵 → 执行 → 验证连通性''';
  }

  /// 构建本地项目部署工作流 system prompt 段落
  /// 当用户在本地终端会话中提到"部署本地项目""打包项目"等需求时，引导 AI 使用新工具
  ///
  /// 两个不变量（都是历史事故换来的）：
  /// - 只注入**当前已注册**的工具。早期版本手写了 project_analyze/build_project/package_project
  ///   三个从未注册的工具名，AI 照做必然撞"未知工具"，退避计数耗尽后任务被判死（设计稿 D1）。
  /// - 参数示例必须是多行 key:value。写成 JSON 会被 AI 学去，而 parser 明确拒绝 JSON（设计稿 D2）。
  String _buildLocalDeployPrompt() {
    final visible =
        _tools.visibleFor(isLocalSession: true).map((t) => t.name).toSet();
    final steps = <({String tool, String note, List<String> args})>[
      (
        tool: 'project_analyze',
        note: '分析项目（必选第一步）：读取 package.json/pubspec.yaml/Cargo.toml 等元数据，'
            '识别项目类型和构建命令。不读源码。',
        args: const ['  path: /Users/用户名/项目路径'],
      ),
      (
        tool: 'build_project',
        note: '构建项目：command 可省略，工具会根据项目类型自动推断。在项目目录本地执行。',
        args: const ['  path: /Users/用户名/项目路径', '  command: npm run build'],
      ),
      (
        tool: 'package_project',
        note: '打包构建产物：artifact_dir 用 project_analyze 返回的"构建产物目录"。输出到 /tmp/ 下。',
        args: const [
          '  path: /Users/用户名/项目路径',
          '  artifact_dir: build/web',
          '  format: tar.gz',
        ],
      ),
      (
        tool: 'sftp_upload',
        note: '上传到服务器（需要切换到 SSH 远程会话，或用多机编排 upload_to 工具）。',
        args: const [
          '  local: /tmp/项目名-时间戳.tar.gz',
          '  remote: /var/www',
          '  recursive: false',
        ],
      ),
    ].where((s) => visible.contains(s.tool)).toList();

    if (steps.isEmpty) return '';

    final buffer = StringBuffer()
      ..writeln('【本地项目部署工作流】')
      ..writeln('当前为本地终端会话。当用户要求"部署本地项目到服务器""打包项目""构建项目"等场景时，'
          '按以下工作流执行：')
      ..writeln()
      ..writeln('【标准部署流程】');
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      buffer.writeln('${i + 1}. ${s.note}');
      buffer.writeln('   动作: tool');
      buffer.writeln('   工具: ${s.tool}');
      buffer.writeln('   参数:');
      for (final a in s.args) {
        buffer.writeln(a);
      }
      buffer.writeln();
    }
    buffer.write('''【关键规则】
1. 必须先 project_analyze 再 build_project，不要跳过分析直接构建
2. 构建失败时，用 ask 动作询问用户："构建失败，错误如下，要我尝试修复吗？还是停下来等您处理？"
3. 不要自行重试构建超过 2 次，避免越改越乱
4. 构建产物目录由 project_analyze 返回的"构建产物目录"字段决定，不要凭猜测
5. 敏感文件（.env.production / id_rsa / *.key / .ssh/ 等）被安全策略禁止访问，不要尝试读取
6. 项目外路径需用户确认，不要随意 cd 到项目外目录
7. 同一时刻只允许一个构建任务运行，构建锁会自动串行化
8. 用户路径可能含空格，工具已自动处理双引号转义，不要手动拼接路径''');
    return buffer.toString();
  }

  /// 启用多机编排模式
  /// [registry] 来自 AgentNotifier，提供对所有 host executor 的访问
  void enableOrchestrator(agent_host_registry.AgentHostRegistry registry) {
    if (_orchestratorMode) return;
    _orchestratorMode = true;
    // 编排命令的权限必须以本引擎为准：并行 tab 的 activeScopeId 会漂移。
    _tools.permissionModeProvider = () => _permissionMode;
    _tools.enableOrchestrator(registry);
    // 强制下次 startTask 重建 system prompt
    _invalidateSystemPromptCache();
  }

  /// 禁用多机编排模式
  void disableOrchestrator() {
    if (!_orchestratorMode) return;
    _orchestratorMode = false;
    _tools.disableOrchestrator();
    _invalidateSystemPromptCache();
  }

  /// 执行位置段落：把“execute 在远程 / local_exec 在本机”说死。
  ///
  /// 截图故障：远程 Linux 会话里模型生成了 PowerShell，execute 原样发给 bash，
  /// 报 `mkdir: 无效的选项 -- F` / `Select-Object: 未找到命令`。工具描述与
  /// 远程误发拦截是第一道，这里是模型每轮都能看到的长期约束。
  String _executionLocationPrompt(CommandExecutor? executor) =>
      PromptBuilder.executionLocationPrompt(executor);

  /// 当前权限档位对应的 system prompt 段落。
  ///
  /// 必须和 [decideCommand] 的实际行为一致：模型知道哪些命令会等待确认，
  /// 才不会在只读档反复重试，或在全自动档仍声称"等你确认"。
  String _permissionModePrompt() =>
      PromptBuilder.permissionModePrompt(_permissionMode);

  /// 设置执行权限档位（只读 / 询问 / 自动 / 全自动）
  void setPermissionMode(AgentPermissionMode mode) {
    if (_permissionMode == mode) return;
    _permissionMode = mode;
    _invalidateSystemPromptCache();
  }

  /// 联网搜索会话级开关是否启用
  bool get isWebSearchEnabled => _webSearchEnabled;

  /// 开启/关闭联网搜索（会话级，覆盖全局开关）
  ///
  /// 运行中切换不影响当前任务（system prompt 仅在 startTask 时构建），
  /// 下次 startTask 时 [_syncWebToolsRegistration] 会根据新值同步工具注册状态。
  void setWebSearchEnabled(bool enabled) {
    if (_webSearchEnabled == enabled) return;
    _webSearchEnabled = enabled;
    _invalidateSystemPromptCache();
  }

  /// 同步联网工具注册状态到当前合并开关
  ///
  /// 在 [_buildSystemPrompt] 内、调用 `_tools.buildToolsPrompt()` 之前调用，
  /// 保证 system prompt 与工具注册状态一致。
  /// 合并规则：会话级开关 OR 全局开关。
  void _syncWebToolsRegistration() {
    // 总开关 + 至少一个可用后端；会话级开关仍可强制开启
    final globalEnabled = WebSearchService.instance.isEnabled;
    final shouldEnable = _webSearchEnabled || globalEnabled;
    if (shouldEnable && !_tools.isWebToolsEnabled) {
      _tools.enableWebTools();
    } else if (!shouldEnable && _tools.isWebToolsEnabled) {
      _tools.disableWebTools();
    }
  }

  /// 设置 sudo 密码（由 AgentNotifier 从安全存储加载后调用）
  /// 传 null/空字符串则关闭 sudo 自动注入
  void setSudoPassword(String? password) {
    _sudoPassword = (password != null && password.isNotEmpty) ? password : null;
  }

  /// 请用户输入本机/远程的 sudo 密码，保存进安全存储并立即启用自动应答。
  ///
  /// 供 provide_password 工具调用：命令因"等待 sudo 密码"失败、而该主机还没配
  /// 密码时，AI 走这条路把密码收进来，而不是让用户去设置页绕一圈。
  ///
  /// 返回 true = 已保存并注入；false = 用户取消或保存失败。
  /// 明文只在本方法内流转到 CredentialsStore 和 [_sudoPassword]，
  /// 不进返回值、不进日志、不进对话历史（AGENTS.md R7）。
  Future<bool> requestSudoPassword({
    String reason = '',
    Duration timeout = const Duration(minutes: 10),
    int? myGeneration,
    String? taskId,
  }) async {
    final request = onSecretRequest;
    if (request == null) {
      agentLogger.warn('Sudo', 'UI 未接入密码输入回调，无法收集 sudo 密码');
      return false;
    }
    final requestGeneration = myGeneration ?? _currentTaskGeneration;
    final requestTaskId = taskId ?? _currentTask?.id;
    bool requestActive() => _isTaskActive(requestGeneration, requestTaskId);

    if (!requestActive()) return false;
    const title = '输入 sudo 密码';
    final message = reason.trim().isEmpty
        ? '命令需要特权密码才能继续。密码只写入本机凭据库与终端 stdin。'
        : '${reason.trim()}\n\n密码只写入本机凭据库与终端 stdin。';
    final String? password;
    try {
      password = await request(title, message).timeout(timeout);
    } on TimeoutException {
      agentLogger.warn('Sudo', '密码输入等待超时，未保存凭据');
      return false;
    } catch (e) {
      // UI 回调异常不能冒泡成工具执行异常；日志只记异常，不记任何密码内容。
      agentLogger.warn('Sudo', '密码输入回调异常，未保存凭据: $e');
      return false;
    }
    if (password == null || password.isEmpty || !requestActive()) return false;

    // 保存前再次检查 identity/代际/状态：取消或暂停后返回的密码既不落盘，
    // 也不进缓存。保存调用一旦开始无法真正撤回，因此取消只能阻止后续注入。
    final targetHostId = hostId ?? 'local';
    final bool saved;
    try {
      saved = await (credentialSaver ?? CredentialsStore.save)(
        hostId: targetHostId,
        type: 'sudoPassword',
        value: password,
      );
    } catch (e) {
      agentLogger.warn('Sudo', '凭据保存失败: hostId=$targetHostId, err=$e');
      return false;
    }
    if (!requestActive()) return false;
    if (!saved) {
      agentLogger.warn('Sudo', '凭据保存失败: hostId=$targetHostId');
      return false;
    }
    _sudoPassword = password;
    // 只记"存没存上"，不记内容
    agentLogger.info('Sudo', '用户已提供 sudo 密码，凭据保存成功');
    return true;
  }

  /// 判断命令是否调用了 sudo（委托 PromptBuilder）
  bool _isSudoCommand(String command) => PromptBuilder.isSudoCommand(command);

  /// 使 system prompt 缓存失效（下次 startTask 重建）
  void _invalidateSystemPromptCache() {
    // 运行中绝不能从 _conversationHistory 里删 system 消息：
    // 下一次 _callAI 会带着没有协议/工具说明的历史请求模型，常见结果是
    // 模型不再输出合法的 动作: 行，连续无命令重试后任务被判失败——
    // 用户看到的就是"点一下联网搜索/只读开关，Agent 就停了"。
    // 下次 startTask 本来就会重建 system prompt，运行中保留旧缓存即可。
    if (isRunning || isPaused) return;
    _conversationHistory.removeWhere((m) => m.role == 'system');
  }

  String? _getCustomPrompt() {
    try {
      return SettingsDao.getCached('customSystemPrompt') as String?;
    } catch (e) {
      debugPrint('[AgentEngine] 读取自定义提示词失败: $e');
      return null;
    }
  }

  /// 裁剪对话历史：委托 HistoryPolicy（上限常量与三层策略都在那里）
  @visibleForTesting
  void trimMessagesForTesting(List<ChatMessage> messages) =>
      _trimMessages(messages);

  @visibleForTesting
  String buildSystemPromptForTesting(CommandExecutor? executor) =>
      _buildSystemPrompt(executor);

  @visibleForTesting
  AgentToolRegistry get toolsForTesting => _tools;

  void _trimMessages(List<ChatMessage> messages) =>
      HistoryPolicy.trimMessages(messages,
          contextWindow: _modelConfig.effectiveContextWindow);

  Future<void> collectSystemInfo(CommandExecutor executor) async {
    try {
      // 平台分支：Unix 用 Unix 命令，Windows 用 wmic/systeminfo
      final isWindowsLocal = executor is! SSHService && Platform.isWindows;
      final commands = isWindowsLocal
          ? [
              // N8: 用 PowerShell + Select-String 兼容中英文系统
              (
                'powershell -Command "systeminfo | Select-String "OS Name|OS Version""',
                'os'
              ),
              (
                'powershell -Command "Get-CimInstance Win32_Processor | Select-Object -ExpandProperty Name"',
                'cpu'
              ),
              (
                'powershell -Command "Get-CimInstance Win32_OperatingSystem | Select-Object TotalVisibleMemorySize,FreePhysicalMemory"',
                'memory'
              ),
              (
                'powershell -Command "Get-CimInstance Win32_LogicalDisk | Select-Object Size,FreeSpace,Caption"',
                'disk'
              ),
            ]
          : [
              ('cat /etc/os-release 2>/dev/null || uname -a', 'os'),
              ('cat /proc/cpuinfo | grep "model name" | head -1', 'cpu'),
              ('free -h', 'memory'),
              ('df -h | head -5', 'disk'),
            ];

      for (final (cmd, cat) in commands) {
        try {
          // 走独立通道/进程：系统信息探测不应回显到用户的交互终端
          // N8: systeminfo 等命令较慢，给 15s 超时
          final out = await executor.runOnce(
            cmd,
            timeout: const Duration(seconds: 15),
          );
          final clean = AnsiStripper.strip(out);
          if (clean.trim().isNotEmpty) {
            _memory.rememberSystemInfo('$cat: ${clean.trim()}', category: cat);
          }
        } catch (e) {
          agentLogger.warn('AgentEngine', '收集 $cat 失败: $e');
        }
      }
    } catch (e) {
      debugPrint('[AgentEngine] 收集系统信息失败: $e');
    }
  }
}

/// 单轮 AI 流式响应的提前执行槽，绝不复用跨任务/跨轮。
class _EarlyExecutionSlot {
  _EarlyExecutionSlot(this.command);
  final String command;
  final Completer<_EarlyExecutionResult> completer =
      Completer<_EarlyExecutionResult>();
}

/// 提前执行结果
class _EarlyExecutionResult {
  final bool shouldContinue;
  final String? observation;
  final String command;
  final bool success;

  _EarlyExecutionResult({
    required this.shouldContinue,
    required this.command,
    this.observation,
    this.success = false,
  });
}
