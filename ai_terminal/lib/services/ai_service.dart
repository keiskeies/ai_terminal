import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../models/ai_model_config.dart';
import '../models/chat_session.dart';
import '../core/hive_init.dart';
import '../core/prompts.dart';

abstract class AIProvider {
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
  });
}

class OpenAIProvider implements AIProvider {
  final Dio _dio = Dio();

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
  }) async {
    final effectiveSystemPrompt = systemPrompt ?? buildContextPrompt();
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': effectiveSystemPrompt},
      ...history.map((m) => {'role': m.role, 'content': m.content}),
      {'role': 'user', 'content': prompt},
    ];

    try {
      final Response<ResponseBody> response = await _dio.post<ResponseBody>(
        '${config.baseUrl}/chat/completions',
        data: {
          'model': config.modelName,
          'messages': messages,
          'stream': true,
          'temperature': config.temperature,
          'max_tokens': config.maxTokens,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer ${config.apiKey}',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.stream,
        ),
      );

      final streamController = StreamController<String>();
      String buffer = '';

      response.data!.stream.listen(
        (chunk) {
          // 关键修复：使用 utf8 解码，而不是 toString()
          String text;
          try {
            text = utf8.decode(chunk);
          } catch (_) {
            text = chunk.toString();
          }
          
          buffer += text;
          
          // 处理 buffer 中的所有完整行
          final lines = buffer.split('\n');
          buffer = lines.last; // 保留不完整的最后一行
          
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
              } catch (e) {
                // 忽略解析错误，继续处理下一行
              }
            }
          }
        },
        onError: (error) {
          streamController.addError(_mapError(error));
          streamController.close();
        },
        onDone: () {
          // 处理可能剩余的 buffer 内容
          if (buffer.isNotEmpty) {
            final line = buffer.trim();
            if (line.startsWith('data: ') && line != 'data: [DONE]') {
              final data = line.substring(6);
              try {
                final json = jsonDecode(data) as Map<String, dynamic>;
                final content = json['choices']?[0]?['delta']?['content'];
                if (content != null && content.toString().isNotEmpty) {
                  streamController.add(content.toString());
                }
              } catch (_) {}
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

  String _mapError(dynamic error) {
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
}

class QwenProvider implements AIProvider {
  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
  }) async {
    // 通义千问兼容 OpenAI API 格式
    final provider = OpenAIProvider();
    return provider.chatStream(
      history: history,
      prompt: prompt,
      config: config,
      systemPrompt: systemPrompt,
    );
  }
}

class ErnieProvider implements AIProvider {
  final Dio _dio = Dio();

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
  }) async {
    // 百度文心 API 格式（不支持 system 消息）
    final messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': prompt},
    ];

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
      );

      final streamController = StreamController<String>();
      String buffer = '';

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
          streamController.addError(error.toString());
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
  }) async {
    final provider = create(config);
    // 构建带主机信息的系统提示词
    var systemPrompt = buildContextPrompt(
      recentOutput: context,
      hostName: hostName,
      hostAddress: hostAddress,
    );

    // 追加用户自定义提示词
    try {
      final customPrompt = HiveInit.settingsBox.get('customSystemPrompt') as String?;
      if (customPrompt != null && customPrompt.isNotEmpty) {
        systemPrompt = '$systemPrompt\n\n【用户自定义指令】\n$customPrompt';
      }
    } catch (_) {}

    return provider.chatStream(
      history: history,
      prompt: prompt,
      config: config,
      systemPrompt: systemPrompt,
    );
  }
}
