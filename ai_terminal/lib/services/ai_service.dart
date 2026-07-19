import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../models/ai_model_config.dart';
import '../models/chat_session.dart';
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
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    List<Map<String, dynamic>>? tools,
  });
}

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

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    List<Map<String, dynamic>>? tools,
  }) async {
    final effectiveSystemPrompt = systemPrompt ?? buildContextPrompt();
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': effectiveSystemPrompt},
      ...history.map((m) => {'role': m.role, 'content': m.content}),
      {'role': 'user', 'content': prompt},
    ];

    // P2-6: 构建 request body；如果传入了 tools，附加到请求
    final requestBody = <String, dynamic>{
      'model': config.modelName,
      'messages': messages,
      'stream': true,
      'temperature': config.temperature,
      'max_tokens': config.maxTokens,
    };
    if (tools != null && tools.isNotEmpty) {
      requestBody['tools'] = tools;
      // 不强制 tool_choice：让模型自主决定是否调用工具
      // 默认 'auto' 即可，避免无谓的工具调用
    }

    try {
      final Response<ResponseBody> response = await _dio.post<ResponseBody>(
        '${config.baseUrl}/chat/completions',
        data: requestBody,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.stream,
        ),
        cancelToken: cancelToken,
      );

      final streamController = StreamController<String>();
      String buffer = '';
      // P2-6: tool_calls 累积器（仅当传入 tools 时启用）
      final toolCallAcc = tools != null && tools.isNotEmpty
          ? ToolCallAccumulator()
          : null;

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
            final choices = json['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final delta = choices[0]['delta'] as Map?;
              if (delta != null) {
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
          if (toolCallAcc != null && toolCallAcc.hasPendingCalls && !streamController.isClosed) {
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
    List<Map<String, dynamic>>? tools,
  }) async {
    // 通义千问兼容 OpenAI API 格式
    final provider = OpenAIProvider();
    return provider.chatStream(
      history: history,
      prompt: prompt,
      config: config,
      systemPrompt: systemPrompt,
      cancelToken: cancelToken,
      tools: tools,
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
    List<Map<String, dynamic>>? tools,
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
          messages.add({'role': 'user', 'content': '$pendingSystem\n\n${m.content}'});
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
        ? (pendingSystem != null ? '$systemPrompt\n\n$pendingSystem' : systemPrompt)
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
                final choices = json['choices'] as List?;
                if (choices != null && choices.isNotEmpty) {
                  final delta = choices[0]['delta'] as Map?;
                  if (delta != null) {
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
      final customPrompt = SettingsDao.getCached('customSystemPrompt') as String?;
      if (customPrompt != null && customPrompt.isNotEmpty) {
        systemPrompt = '$systemPrompt\n\n【用户自定义指令】\n$customPrompt';
      }
    } catch (_) {}

    return provider.chatStream(
      history: history,
      prompt: prompt,
      config: config,
      systemPrompt: systemPrompt,
      cancelToken: cancelToken,
    );
  }
}
