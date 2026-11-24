import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ai_model_config.dart';
import '../models/conversation.dart';
import 'ai_service.dart';
import 'conversation_service.dart';

/// 会话 AI 自动命名服务
///
/// 首轮对话结束后，取「用户诉求 + AI 首轮结论」交给当前模型生成一个 50 字左右
/// 的中文标题，写回 [Conversation.title] 并把 titleSource 标记为 ai。
///
/// 设计要点（与 AGENTS.md R1/R2/R3 一致）：
/// - 只在 [Conversation.canAdoptAiTitle]（即占位标题）时改写；用户手动命名/已 AI 命名后不再覆盖。
/// - 用捕获的 conversationId 操作，不读 activeHostId（R3）。
/// - 生成失败/超时/空结果一律静默保留占位标题，不冒泡到 UI（纯副作用，任务本身已完成）。
/// - 每个会话最多生成一次：titleSource 从 auto → ai 后 gate 自然闭合，无需额外 in-flight 集合。
class ConversationTitleService {
  ConversationTitleService();

  static const int _kTimeoutSeconds = 15;

  /// 用户诉求 / AI 首轮结论送入标题提示词的最大字符数（R8：无界缓冲必须设上限）
  static const int _kInputMaxChars = 1500;

  /// 成对引号/书名号（中英文），清洗模型输出时按「首尾成对」剥离
  static const List<List<String>> _quotePairs = [
    ['“', '”'],
    ['「', '」'],
    ['《', '》'],
    ['"', '"'],
    ["'", "'"],
  ];

  /// 从会话存储读取首条 user / assistant 消息并生成标题。
  ///
  /// 不抛异常：任何失败都返回 false，调用方可以 fire-and-forget。
  /// 返回 true 表示成功写回。
  Future<bool> generateAndApply(
    String conversationId,
    AIModelConfig config,
  ) async {
    final service = ConversationService();
    final conv = service.lookup(conversationId);
    if (conv == null || !conv.canAdoptAiTitle) return false;

    final texts = selectFirstRoundTexts(conv);
    if (texts.userText.isEmpty) return false; // 没有可命名内容

    return generateAndApplyTexts(
      conversationId,
      config,
      userText: texts.userText,
      assistantText: texts.assistantText,
    );
  }

  /// 用调用方已持有的文本生成并应用标题（聊天模式直接传本轮 user/assistant 原文）。
  Future<bool> generateAndApplyTexts(
    String conversationId,
    AIModelConfig config, {
    required String userText,
    String assistantText = '',
  }) async {
    final service = ConversationService();
    final conv = service.lookup(conversationId);
    if (conv == null || !conv.canAdoptAiTitle) return false;
    if (userText.trim().isEmpty) return false;

    final raw = await _generateRaw(
      config: config,
      userText: _clampTail(userText, _kInputMaxChars),
      assistantText: _clampTail(assistantText, _kInputMaxChars),
    );
    if (raw == null) return false;

    final title = sanitizeTitle(raw);
    if (title.isEmpty) return false;

    // R1: await 期间会话可能已被手动改名 / 已有 AI 标题 / 被删除。
    // applyAiTitle 内部会重新校验 canAdoptAiTitle 并走 upsert 串行链，失败/跳过不抛。
    await service.applyAiTitle(conversationId, title);
    return service.lookup(conversationId)?.titleSource ==
        Conversation.titleSourceAi;
  }

  /// 从会话里挑出命名所用的「用户诉求 + AI 首轮结论」（纯函数，便于单测）。
  ///
  /// 用户诉求取第一条 user 消息；AI 结论取第一条**可用** assistant 消息——
  /// 首轮报错时引擎会把 `⚠️ 错误` 写进首条 assistant 消息（agent_provider 的
  /// onError），按"第一条"取就会拿错误文本当结论命名，因此跳过它继续找下一条，
  /// 让标题依据真正完成的那轮输出。找不到可用结论时 assistantText 为空，
  /// 提示词只带诉求（[ _buildPrompt] 本就这么分支）。
  static ({String userText, String assistantText}) selectFirstRoundTexts(
      Conversation conv) {
    var userText = '';
    var assistantText = '';
    for (final m in conv.messages) {
      if (m.role == 'system') continue;
      final text = m.effectiveContent;
      if (m.isUser && userText.isEmpty) {
        userText = _clampTail(text, _kInputMaxChars);
      } else if (m.isAssistant &&
          assistantText.isEmpty &&
          _isUsableAssistant(text)) {
        assistantText = _clampTail(text, _kInputMaxChars);
      }
      if (userText.isNotEmpty && assistantText.isNotEmpty) break;
    }
    return (userText: userText, assistantText: assistantText);
  }

  /// 该 assistant 消息能否作为「AI 首轮结论」送进命名提示词。
  ///
  /// 排除空串与 `⚠️ ` 错误占位（agent_provider.onError 写入），它们不含
  /// 任何可用于命名的信息，反而会把标题带偏成「某个报错」。
  static bool _isUsableAssistant(String text) {
    final t = text.trim();
    return t.isNotEmpty && !t.startsWith('⚠️');
  }

  /// 调用模型生成标题原文。失败/超时/空 返回 null。
  Future<String?> _generateRaw({
    required AIModelConfig config,
    required String userText,
    required String assistantText,
  }) async {
    final provider = AIService.create(config);
    // 轻量配置：小输出上限、低温度、关闭推理档位，避免为起个名字烧 token / 等待思考
    final titleConfig = config.copyWith(
      temperature: 0.2,
      maxTokens: 200,
      reasoningEffort: '',
      reasoningLabel: '',
    );
    final prompt = _buildPrompt(userText, assistantText);
    const systemPrompt = '你是会话命名助手，只输出标题文本本身，不要解释、不要引号、不要换行。';
    try {
      final stream = await provider.chatStream(
        history: const [],
        prompt: prompt,
        config: titleConfig,
        systemPrompt: systemPrompt,
        responseTimeout: const Duration(seconds: _kTimeoutSeconds),
      );
      final buffer = StringBuffer();
      await for (final chunk in stream.timeout(
        const Duration(seconds: _kTimeoutSeconds),
        onTimeout: (sink) {
          sink.close();
        },
      )) {
        buffer.write(chunk);
      }
      return buffer.toString();
    } catch (e) {
      debugPrint('[TitleService] 生成标题失败 (conv=${config.id}): $e');
      return null;
    }
  }

  static String _buildPrompt(String userText, String assistantText) {
    final buf = StringBuffer();
    buf.writeln('请为下面这段运维/开发会话生成一个简短的中文标题。');
    buf.writeln('要求：');
    buf.writeln('- 控制在 30~50 字，一句话概括「在哪个对象上做了什么/要做什么」');
    buf.writeln('- 保留关键名词（服务名、路径、主机名、命令、版本等），不要泛化成「处理问题」');
    buf.writeln('- 使用与用户输入相同的语言；用户输入是英文时标题也用英文');
    buf.writeln('- 只输出标题本身：不要引号、书名号、句号、前缀、换行或任何解释');
    buf.writeln('- 不要编造对话中没有的信息');
    buf.writeln('');
    buf.writeln('=== 用户诉求 ===');
    buf.writeln(userText);
    if (assistantText.isNotEmpty) {
      buf.writeln('');
      buf.writeln('=== AI 首轮结论 ===');
      buf.writeln(assistantText);
    }
    return buf.toString();
  }

  /// 清洗模型输出的纯函数：剥 markdown 代码块、收敛成单行、去首尾引号/书名号、
  /// 去「标题：」类前缀、去结尾标点、按 [Conversation.listTitleMaxChars] 截断。
  /// 顺序有讲究：代码块要先剥掉再取首行，否则首行会变成 ```。便于单测。
  static String sanitizeTitle(String raw) {
    var text = raw.trim();
    // 1) 剥 markdown 代码块包裹
    if (text.startsWith('```')) {
      final firstNewline = text.indexOf('\n');
      if (firstNewline > 0) text = text.substring(firstNewline + 1);
      if (text.endsWith('```')) {
        text = text.substring(0, text.length - 3);
      }
      text = text.trim();
    }
    // 2) 取首行并折叠空白（标题应为单行）
    final firstLine = text.split(RegExp(r'\r?\n')).first;
    text = firstLine.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '';
    // 3) 去成对引号/书名号（中英文）
    for (final pair in _quotePairs) {
      final open = pair[0];
      final close = pair[1];
      if (text.length >= open.length + close.length &&
          text.startsWith(open) &&
          text.endsWith(close)) {
        text = text.substring(open.length, text.length - close.length).trim();
      }
    }
    // 4) 去「标题：」类前缀
    text = _stripTitlePrefix(text);
    // 5) 去掉结尾标点（句号/逗号/感叹号/问号/冒号 + 常见全角/半角）
    while (text.isNotEmpty) {
      final last = text.codeUnitAt(text.length - 1);
      const stop = {
        0x3002, // 。
        0xFF0C, // ，
        0xFF01, // ！
        0xFF1F, // ？
        0xFF1A, // ：
        0x2026, // …
        46, // .
        44, // ,
        33, // !
        63, // ?
        58, // :
      };
      if (stop.contains(last)) {
        text = text.substring(0, text.length - 1);
      } else {
        break;
      }
    }
    text = text.trim();
    if (text.isEmpty) return '';
    // 6) 按 rune 截断（避免劈开 emoji），补省略号
    return Conversation.clampToRunes(
      text,
      maxChars: Conversation.listTitleMaxChars,
    );
  }

  /// 去掉模型偶尔加的「标题：」「Title:」类前缀
  static String _stripTitlePrefix(String text) {
    const prefixes = ['标题：', '标题:', 'Title:', 'Title：'];
    for (final p in prefixes) {
      if (text.startsWith(p)) {
        return text.substring(p.length).trim();
      }
    }
    return text;
  }

  /// 保留尾部（最接近当前内容的部分）——诉求/结论被截断时保留结尾更有信息量。
  static String _clampTail(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return text.substring(text.length - maxChars);
  }
}
