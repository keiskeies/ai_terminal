import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../models/ai_model_config.dart';
import '../models/chat_session.dart';
import '../models/token_usage.dart';
import '../core/prompts.dart';
import '../utils/tool_call_accumulator.dart';
import 'daos.dart';
import 'knowledge_service.dart';

abstract class AIProvider {
  /// 调用 AI 模型返回流式响应。
  ///
  /// [cancelToken] 可选取消令牌：
  /// - 传入后，调用方可通过 `cancelToken.cancel()` 立即取消底层 HTTP 请求和流监听
  /// - 不依赖 Dio 内置的 receiveTimeout 兜底，做到毫秒级响应
  /// - 取消后，stream 会以 onError(DioException.cancel) 结束
  ///
  /// [tools] 可选：P2-6 原生 Function Calling 工具 schema（OpenAI tools API 格式）。
  /// 传入后 OpenAIProvider 会将其附加到请求 body，并解析 delta.tool_calls。
  /// 当前实现：收到 tool_calls 时，转换为 ReAct 多行 key:value 格式
  /// （"动作: tool / 工具: X / 参数: /   key: value"）投递到 stream，
  /// 由 AgentEngine 的现有解析路径（ToolArgsParser）处理。其他 provider 忽略此参数。
  ///
  /// [onUsage] 可选：provider 在流里给出真实 token 用量时回调。
  /// 可能是累计式（每个 chunk 都带递增的 usage）也可能是末包式，因此**每次都回调**，
  /// 由消费方取最后一次——两种写法下结果都对。不提供 usage 的模型不会回调。
  ///
  /// [responseTimeout] 可选：本次请求的 HTTP 空闲超时（连续无数据），
  /// 覆盖 provider 的默认 receiveTimeout；null 表示沿用默认值。
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    Duration? responseTimeout,
    List<Map<String, dynamic>>? tools,
    void Function(TokenUsage usage)? onUsage,
    /// 模型原生推理增量（reasoning_content）；网关不给该字段时不会触发
    void Function(String delta)? onReasoning,
  });
}

/// 从一条流式 delta 里取「模型原生推理」增量。
///
/// 不同网关字段不同：DeepSeek 系用 `reasoning_content`，少数用 `reasoning`；
/// 也有的把推理塞成非字符串。非字符串/空串一律按"没有"处理，绝不影响正文。
String? reasoningDeltaOf(Object? delta) {
  if (delta is! Map) return null;
  final value = delta['reasoning_content'] ?? delta['reasoning'];
  return value is String && value.isNotEmpty ? value : null;
}

/// 是否该去掉 `stream_options` 再发一次请求。
///
/// 规则收紧到"这次确实带了该字段"且"网关回 400"两条同时成立：
/// - 401/429/500 与这个字段无关，重试只是再打一次配额并拖延真实错误；
/// - 降级那次本身不能再降级，否则会无限重试；
/// - 只有 400 值得猜"是不认识这个字段"——OpenAI 兼容网关拒绝未知字段就是 400。
bool shouldRetryWithoutStreamOptions({
  required bool sentStreamOptions,
  required int? statusCode,
}) =>
    sentStreamOptions && statusCode == 400;

/// 将 Dio 异常映射为用户友好的错误消息（OpenAI / Ernie 等 provider 共用）
String mapDioError(dynamic error) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，请检查网络';
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode;
        if (statusCode == 401) {
          return 'API Key 无效或已过期';
        } else if (statusCode == 429) {
          return '请求过于频繁，请稍后重试';
        } else if (statusCode == 400) {
          return '请求格式错误，请检查 API 配置';
        }
        return '服务器错误: $statusCode';
      case DioExceptionType.connectionError:
        return '无法连接到 AI 服务，请检查网络';
      default:
        return '连接失败: ${error.message}';
    }
  }
  return '发生未知错误: $error';
}

class OpenAIProvider implements AIProvider {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(seconds: 30),
  ));

  /// 构建 OpenAI 兼容的 messages 数组。
  ///
  /// 严格实现（如 Agens/OpenAI/部分网关）会拒绝 content 为空的消息，
  /// 因此必须过滤空历史消息，并且 prompt 为空时不能追加空 user 消息
  /// （Agent 模式传 prompt: ''，历史里已包含用户任务）。
  static List<Map<String, dynamic>> buildRequestMessages({
    required List<ChatMessage> history,
    required String prompt,
    String? systemPrompt,
  }) {
    final messages = <Map<String, dynamic>>[];
    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }
    for (final m in history) {
      if (m.content.trim().isEmpty) continue;
      messages.add({'role': m.role, 'content': m.content});
    }
    if (prompt.trim().isNotEmpty) {
      messages.add({'role': 'user', 'content': prompt});
    }
    return messages;
  }

  /// 构建 OpenAI Chat Completions 请求体。
  ///
  /// reasoning_effort 只在模型配置了非空 API 参数值时发送；空值表示
  /// "不发送该字段"（off 档），由网关使用自己的默认行为。
  static Map<String, dynamic> buildChatRequestBody({
    required AIModelConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
  }) {
    final body = <String, dynamic>{
      'model': config.modelName,
      'messages': messages,
      'stream': true,
      'temperature': config.temperature,
      'max_tokens': config.maxTokens,
    };
    final effort = config.reasoningEffort?.trim();
    if (effort != null && effort.isNotEmpty) {
      body['reasoning_effort'] = effort;
    }
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      // 不强制 tool_choice：让模型自主决定是否调用工具
    }
    return body;
  }

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    Duration? responseTimeout,
    List<Map<String, dynamic>>? tools,
    void Function(TokenUsage usage)? onUsage,
    void Function(String delta)? onReasoning,
  }) async {
    final effectiveSystemPrompt = systemPrompt ?? buildContextPrompt();
    final messages = buildRequestMessages(
      history: history,
      prompt: prompt,
      systemPrompt: effectiveSystemPrompt,
    );

    // P2-6: 构建 request body；如果传入了 tools，附加到请求
    final requestBody = buildChatRequestBody(
      config: config,
      messages: messages,
      tools: tools,
    );

    try {
      late final Response<ResponseBody> response;
      try {
        response = await _postChatCompletions(
          config,
          requestBody,
          cancelToken,
          withStreamOptions: true,
          responseTimeout: responseTimeout,
        );
      } on DioException catch (e) {
        // 不支持 stream_options 的网关会回 400。一个统计字段不值得把用户的任务
        // 打死，所以去掉它重试一次；其余错误照原路径向上抛给既有错误处理。
        if (!shouldRetryWithoutStreamOptions(
          sentStreamOptions: true,
          statusCode: e.response?.statusCode,
        )) {
          rethrow;
        }
        response = await _postChatCompletions(
          config,
          requestBody,
          cancelToken,
          withStreamOptions: false,
          responseTimeout: responseTimeout,
        );
      }

      final streamController = StreamController<String>();
      String buffer = '';
      // P2-6: tool_calls 累积器（仅当传入 tools 时启用）
      final toolCallAcc =
          tools != null && tools.isNotEmpty ? ToolCallAccumulator() : null;

      if (cancelToken != null) {
        cancelToken.whenCancel.then((err) {
          if (!streamController.isClosed) {
            streamController.addError(err);
            streamController.close();
          }
        });
      }

      void processLine(String line) {
        if (line == 'data: [DONE]') {
          // P2-6: 流结束前若有累积的 tool_calls，转换为 ReAct 文本投递
          if (toolCallAcc != null && toolCallAcc.hasPendingCalls) {
            final calls = toolCallAcc.finalize();
            if (calls.isNotEmpty) {
              final reactText = ToolCallAccumulator.toReActText(calls);
              if (!streamController.isClosed) {
                streamController.add(reactText);
              }
            }
          }
          if (!streamController.isClosed) {
            streamController.close();
          }
          return;
        }
        if (line.startsWith('data: ')) {
          final data = line.substring(6);
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            // usage 一般随最后一个 chunk 到达，且那条的 choices 为空数组，
            // 所以先取 usage 再看 choices；既有 choices 分支不需要为此改动。
            final usage = TokenUsage.tryParse(json['usage']);
            if (usage != null) onUsage?.call(usage);
            final choices = json['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final delta = choices[0]['delta'] as Map?;
              if (delta != null) {
                // 原生推理增量：DeepSeek/部分网关用 reasoning_content，
                // 也有网关用 reasoning；两处都认，没给就静默跳过。
                final reasoning = reasoningDeltaOf(delta);
                if (reasoning != null) {
                  onReasoning?.call(reasoning);
                }
                // 普通文本内容
                final content = delta['content'];
                if (content != null && content.toString().isNotEmpty) {
                  if (!streamController.isClosed) {
                    streamController.add(content.toString());
                  }
                }
                // P2-6: tool_calls 增量累积
                if (toolCallAcc != null && delta['tool_calls'] != null) {
                  toolCallAcc.addDelta(delta['tool_calls'] as List);
                }
                // finish_reason='tool_calls' 时立即投递（部分 provider 不会发 [DONE]）
                final finishReason = choices[0]['finish_reason'];
                if (finishReason == 'tool_calls' && toolCallAcc != null) {
                  final calls = toolCallAcc.finalize();
                  if (calls.isNotEmpty) {
                    final reactText = ToolCallAccumulator.toReActText(calls);
                    if (!streamController.isClosed) {
                      streamController.add(reactText);
                    }
                  }
                }
              }
            }
          } catch (e) {
            // 忽略解析错误，继续处理下一行
          }
        }
      }

      response.data!.stream.listen(
        (chunk) {
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
            processLine(line);
          }
        },
        onError: (error) {
          if (!streamController.isClosed) {
            streamController.addError(_mapError(error));
            streamController.close();
          }
        },
        onDone: () {
          // 处理剩余 buffer
          if (buffer.isNotEmpty) {
            final line = buffer.trim();
            if (line.startsWith('data: ')) {
              processLine(line);
            }
          }
          // P2-6: 兜底 — 若 stream 关闭时仍有未投递的 tool_calls，在此投递
          if (toolCallAcc != null &&
              toolCallAcc.hasPendingCalls &&
              !streamController.isClosed) {
            final calls = toolCallAcc.finalize();
            if (calls.isNotEmpty) {
              streamController.add(ToolCallAccumulator.toReActText(calls));
            }
          }
          if (!streamController.isClosed) {
            streamController.close();
          }
        },
      );

      return streamController.stream;
    } catch (e) {
      rethrow;
    }
  }

  /// 发送流式 chat 请求。
  ///
  /// [withStreamOptions] 控制是否附加 `stream_options.include_usage`——这是从流里
  /// 拿到真实 token 用量的唯一途径，但严格或自建网关可能不认识这个字段，
  /// 所以调用方收到 400 时会以 false 重试一次，而不是让用户的任务失败。
  Future<Response<ResponseBody>> _postChatCompletions(
    AIModelConfig config,
    Map<String, dynamic> requestBody,
    CancelToken? cancelToken, {
    required bool withStreamOptions,
    Duration? responseTimeout,
  }) {
    final body = Map<String, dynamic>.of(requestBody);
    if (withStreamOptions) {
      body['stream_options'] = {'include_usage': true};
    }
    return _dio.post<ResponseBody>(
      '${config.baseUrl}/chat/completions',
      data: body,
      options: Options(
        headers: {
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.stream,
        receiveTimeout: responseTimeout,
      ),
      cancelToken: cancelToken,
    );
  }

  String _mapError(dynamic error) => mapDioError(error);
}

class QwenProvider implements AIProvider {
  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    Duration? responseTimeout,
    List<Map<String, dynamic>>? tools,
    void Function(TokenUsage usage)? onUsage,
    void Function(String delta)? onReasoning,
  }) async {
    // 通义千问兼容 OpenAI API 格式
    final provider = OpenAIProvider();
    return provider.chatStream(
      history: history,
      prompt: prompt,
      config: config,
      systemPrompt: systemPrompt,
      cancelToken: cancelToken,
      responseTimeout: responseTimeout,
      tools: tools,
      onUsage: onUsage,
      onReasoning: onReasoning,
    );
  }
}

class ErnieProvider implements AIProvider {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(seconds: 30),
  ));

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    Duration? responseTimeout,
    List<Map<String, dynamic>>? tools,
    void Function(TokenUsage usage)? onUsage,
    void Function(String delta)? onReasoning,
  }) async {
    // 百度文心 API 格式（不支持 system 角色）
    // 将 system prompt 合并到第一条 user 消息中
    final messages = <Map<String, dynamic>>[];

    // 构建带 system 上下文的历史消息
    // 遍历 history，遇到 system 消息时缓存，遇到第一条 user 时合并注入
    String? pendingSystem;
    for (final m in history) {
      if (m.role == 'system') {
        // 多条 system 消息时累加（后一条覆盖前一条，保留最新）
        pendingSystem = m.content;
      } else {
        if (m.role == 'user' && pendingSystem != null && messages.isEmpty) {
          // 第一条 user 消息前注入缓存的 system prompt
          messages.add(
              {'role': 'user', 'content': '$pendingSystem\n\n${m.content}'});
          pendingSystem = null;
        } else {
          messages.add({'role': m.role, 'content': m.content});
        }
      }
    }

    // 当前 prompt 注入 system prompt
    // 优先用参数 systemPrompt；若 history 中有未被消费的 system（如 history 首条非 user），则合并两者
    String effectivePrompt = prompt;
    final effectiveSystem = systemPrompt != null && systemPrompt.isNotEmpty
        ? (pendingSystem != null
            ? '$systemPrompt\n\n$pendingSystem'
            : systemPrompt)
        : pendingSystem;
    if (effectiveSystem != null && effectiveSystem.isNotEmpty) {
      effectivePrompt = '$effectiveSystem\n\n$prompt';
    }
    messages.add({'role': 'user', 'content': effectivePrompt});

    try {
      final Response<ResponseBody> response = await _dio.post<ResponseBody>(
        '${config.baseUrl}/chat/completions',
        data: {
          'model': config.modelName,
          'messages': messages,
          'stream': true,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.stream,
          receiveTimeout: responseTimeout,
        ),
        cancelToken: cancelToken,
      );

      final streamController = StreamController<String>();
      String buffer = '';

      // 与 OpenAIProvider 一致：cancelToken 触发时主动关闭 streamController
      if (cancelToken != null) {
        cancelToken.whenCancel.then((err) {
          if (!streamController.isClosed) {
            streamController.addError(err);
            streamController.close();
          }
        });
      }

      response.data!.stream.listen(
        (chunk) {
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

            if (line == 'data: [DONE]') {
              streamController.close();
              return;
            }

            if (line.startsWith('data: ')) {
              final data = line.substring(6);
              try {
                final json = jsonDecode(data) as Map<String, dynamic>;
                // 文心在末包给 usage（部分版本不给）；不给就不回调，UI 回落到估算值
                final usage = TokenUsage.tryParse(json['usage']);
                if (usage != null) onUsage?.call(usage);
                final choices = json['choices'] as List?;
                if (choices != null && choices.isNotEmpty) {
                  final delta = choices[0]['delta'] as Map?;
                  if (delta != null) {
                    final reasoning = reasoningDeltaOf(delta);
                    if (reasoning != null) {
                      onReasoning?.call(reasoning);
                    }
                    final content = delta['content'];
                    if (content != null && content.toString().isNotEmpty) {
                      streamController.add(content.toString());
                    }
                  }
                }
              } catch (_) {}
            }
          }
        },
        onError: (error) {
          // 与 OpenAIProvider 保持一致：映射为友好消息
          streamController.addError(mapDioError(error));
          streamController.close();
        },
        onDone: () {
          if (!streamController.isClosed) {
            streamController.close();
          }
        },
      );

      return streamController.stream;
    } catch (e) {
      rethrow;
    }
  }
}

/// AI 服务工厂
class AIService {
  static AIProvider create(AIModelConfig config) {
    switch (config.provider) {
      case 'openai':
      case 'ollama':
        return OpenAIProvider();
      case 'qwen':
        return QwenProvider();
      case 'ernie':
        return ErnieProvider();
      default:
        return OpenAIProvider();
    }
  }

  /// 发送聊天消息并返回流
  static Future<Stream<String>> sendMessage({
    required AIModelConfig config,
    required List<ChatMessage> history,
    required String prompt,
    String? context,
    String? hostName,
    String? hostAddress,
    CancelToken? cancelToken,
  }) async {
    final provider = create(config);
    // 构建带主机信息的系统提示词
    var systemPrompt = buildContextPrompt(
      recentOutput: context,
      hostName: hostName,
      hostAddress: hostAddress,
    );

    // 追加知识库安全规则
    systemPrompt = '$systemPrompt\n\n$knowledgeSafetyRule';

    // 查询知识库并注入
    try {
      final knowledge = KnowledgeService();
      await knowledge.ensureInitialized();
      if (knowledge.isInitialized && prompt.isNotEmpty) {
        final injection = await knowledge.buildKnowledgeInjection(prompt);
        if (injection != null) {
          systemPrompt = '$systemPrompt\n\n$injection';
        }
      }
    } catch (_) {}

    // 追加用户自定义提示词
    try {
      final customPrompt =
          SettingsDao.getCached('customSystemPrompt') as String?;
      if (customPrompt != null && customPrompt.isNotEmpty) {
        systemPrompt = '$systemPrompt\n\n【用户自定义指令】\n$customPrompt';
      }
    } catch (_) {}

    final timeoutSeconds =
        ((SettingsDao.getCached('agentAiTimeoutSeconds') as num?)?.toInt() ??
                kDefaultAiResponseTimeoutSeconds)
            .clamp(kMinAiResponseTimeoutSeconds, kMaxAiResponseTimeoutSeconds);

    return provider.chatStream(
      history: history,
      prompt: prompt,
      config: config,
      systemPrompt: systemPrompt,
      cancelToken: cancelToken,
      responseTimeout: Duration(seconds: timeoutSeconds),
    );
  }
}
