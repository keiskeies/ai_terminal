import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../models/ai_model_config.dart';

/// 补全回调类型：返回补全建议文本（null 表示无建议或失败）
typedef CompletionCallback = void Function(String? suggestion);

/// 智能补全服务 — 为输入框提供基于大模型的命令/描述补全
///
/// 设计要点（速度优先）：
/// 1. 流式调用，首 token 到达即返回（不等完整响应）
/// 2. max_tokens 限制在 50，避免长输出
/// 3. system prompt 极简，不带 ReAct 思考引导
/// 4. debounce 300ms，避免每次按键都调 API
/// 5. 用户继续输入时立即取消上次请求
class CompletionService {
  static final CompletionService _instance = CompletionService._internal();
  factory CompletionService() => _instance;
  CompletionService._internal();

  final Dio _dio = Dio();

  /// 当前请求的取消令牌（用户继续输入时取消上次）
  CancelToken? _cancelToken;

  /// 请求补全
  /// [input] 当前输入框文本
  /// [config] AI 模型配置
  /// [context] 上下文信息（当前主机、会话主题等，可为空）
  /// [onResult] 异步回调，返回补全建议
  Future<void> complete({
    required String input,
    required AIModelConfig config,
    String? context,
    required CompletionCallback onResult,
  }) async {
    // 输入太短不补全（避免无意义请求）
    if (input.trim().length < 3) {
      onResult(null);
      return;
    }

    // 输入以斜杠开头是斜杠命令，不补全（已有专门的浮层）
    if (input.trim().startsWith('/')) {
      onResult(null);
      return;
    }

    // 取消上一次请求
    _cancelToken?.cancel('用户继续输入');
    _cancelToken = CancelToken();

    try {
      final systemPrompt = _buildSystemPrompt(context);
      final userPrompt = _buildUserPrompt(input);

      final response = await _dio.post<ResponseBody>(
        '${config.baseUrl}/chat/completions',
        data: {
          'model': config.modelName,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userPrompt},
          ],
          'stream': true,
          'temperature': 0.3, // 低温度，更确定性
          'max_tokens': 50,   // 短输出，快返回
          // 禁用思考/推理模式（速度优先）：
          // - enable_thinking: Qwen 系列通过此参数关闭思考
          // - reasoning: 部分 OpenAI 兼容 API 通过此参数关闭推理
          // - chat_template_kwargs.enable_thinking: vLLM 部署的 Qwen 模型
          // 不支持的 API 会忽略这些额外字段，不影响兼容性
          'enable_thinking': false,
          'reasoning': false,
          'chat_template_kwargs': {'enable_thinking': false},
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.stream,
          // R8: 超时保护，避免 API 不返回 [DONE] 时永久阻塞
          receiveTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 5),
        ),
        cancelToken: _cancelToken,
      );

      // 流式读取，累积内容，有效即返回
      final accumulated = StringBuffer();
      bool callbackSent = false;

      // 用 Future.any 给整个流加超时（兜底，防止 receiveTimeout 未生效）
      await Future.any([
        _readStream(response.data!.stream, (content) {
          accumulated.write(content);
          // 每次有新内容都尝试清理并回调（首次成功后不再重复）
          if (!callbackSent) {
            final cleaned = _cleanSuggestion(accumulated.toString(), input);
            if (cleaned != null && cleaned.isNotEmpty) {
              callbackSent = true;
              onResult(cleaned);
            }
          }
        }),
        Future.delayed(const Duration(seconds: 8), () => null),
      ]);

      // 流结束：如果还没回调过，尝试用累积内容最后清理一次
      if (!callbackSent) {
        final cleaned = _cleanSuggestion(accumulated.toString(), input);
        if (cleaned != null && cleaned.isNotEmpty) {
          onResult(cleaned);
        } else {
          onResult(null);
        }
      }
    } on DioException catch (e) {
      // 取消不算错误
      if (e.type == DioExceptionType.cancel) return;
      // 其他错误静默处理（补全失败不影响主流程）
      return;
    } catch (_) {
      // 静默失败
      return;
    }
  }

  /// 取消当前补全请求
  void cancel() {
    _cancelToken?.cancel('手动取消');
    _cancelToken = null;
  }

  /// 读取 SSE 流，解析 data 行，每得到一段 content 就回调 [onContent]
  Future<void> _readStream(
    Stream<List<int>> stream,
    void Function(String content) onContent,
  ) async {
    String buffer = '';
    await for (final chunk in stream) {
      String text;
      try {
        text = utf8.decode(chunk);
      } catch (_) {
        text = chunk.toString();
      }
      buffer += text;
      final lines = buffer.split('\n');
      buffer = lines.last;
      for (int i = 0; i < lines.length - 1; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        if (line == 'data: [DONE]') return;
        if (line.startsWith('data: ')) {
          final data = line.substring(6);
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final choices = json['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final delta = choices[0]['delta'] as Map?;
              final content = delta?['content'] as String?;
              if (content != null && content.isNotEmpty) {
                onContent(content);
              }
            }
          } catch (_) {
            // JSON 解析失败，跳过
          }
        }
      }
    }
  }

  String _buildSystemPrompt(String? context) {
    final buffer = StringBuffer();
    buffer.writeln('你是命令补全助手。根据用户当前输入，补全剩余部分。');
    buffer.writeln('规则:');
    buffer.writeln('- 只返回补全文本，不要重复用户已输入的部分');
    buffer.writeln('- 不要加引号、注释、解释');
    buffer.writeln('- 如果是 shell 命令，补全命令参数');
    buffer.writeln('- 如果是自然语言描述，补全句子');
    buffer.writeln('- 不确定时返回空');
    if (context != null && context.isNotEmpty) {
      buffer.writeln('上下文: $context');
    }
    return buffer.toString();
  }

  String _buildUserPrompt(String input) {
    return '补全以下输入（只返回补全部分）:\n$input';
  }

  /// 清理补全结果
  /// - 去掉用户已输入的部分（如果模型重复了）
  /// - 去掉换行符（补全应该是单行）
  /// - 限制长度
  String? _cleanSuggestion(String suggestion, String userInput) {
    var s = suggestion.trim();
    // 去掉换行（补全应该是单行的）
    final newlineIdx = s.indexOf('\n');
    if (newlineIdx >= 0) {
      s = s.substring(0, newlineIdx);
    }
    // 如果模型重复了用户输入，去掉
    if (s.toLowerCase().startsWith(userInput.toLowerCase())) {
      s = s.substring(userInput.length);
    }
    // 限制长度
    if (s.length > 80) {
      s = s.substring(0, 80);
    }
    return s.isEmpty ? null : s;
  }
}
