import 'dart:async';
import 'package:dio/dio.dart';
import 'agent_tool.dart';
import 'command_executor.dart';
import 'web_search_config.dart';
import 'web_search_service.dart';
import '../utils/tool_args_parser.dart';

/// 联网搜索工具
///
/// 让 AI 在自身知识不足时主动发起网络搜索，获取最新信息。
/// 与 [FetchUrlTool] 配合形成"搜索 → 精读"闭环：本工具只返回标题/URL/摘要列表，
/// AI 觉得需要详细内容时再调 fetch_url 抓正文。
///
/// 不接受 [executor] 参数（不通过 SSH/PTY 执行）；executor 字段被忽略。
///
/// ReAct 循环冲突处理：
/// - [cancelToken] 桥接到 Dio.CancelToken，使 cancelTask 能立即中断网络请求
/// - 失败时返回 [ToolResult.failure] 并附明确原因（如配额耗尽、key 失效），
///   让 AI 知道何时该停止重试，避免与 _noCommandRetryCount 配合不当导致死循环
class WebSearchTool extends AgentTool {
  @override
  String get name => 'web_search';

  @override
  String get description => '联网搜索最新信息（当你的训练数据可能过时、'
      '或遇到不熟悉的概念/错误/版本号/软件包时使用）。返回标题+URL+摘要列表，'
      '若需详细内容请配合 fetch_url 工具。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  query: 搜索关键词（必填）\n'
      '  max_results: 返回结果数（可选，默认 5，上限 20）';

  @override
  Map<String, dynamic>? toJsonSchema() {
    return {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': '搜索关键词',
        },
        'max_results': {
          'type': 'integer',
          'description': '返回结果数（默认 5）',
        },
      },
      'required': ['query'],
    };
  }

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final query = ToolArgsParser.getString(args, 'query').trim();
    final maxResults = ToolArgsParser.getInt(args, 'max_results', defaultValue: 0);

    if (query.isEmpty) {
      return ToolResult.failure('参数缺失: query 为必填项');
    }

    onProgress?.call('正在搜索: $query');

    // 桥接 AgentTool.cancelToken (Completer<void>) → Dio.CancelToken
    // 设计意图：cancelTask 完成 Completer 时，立即取消进行中的网络请求，
    // 否则已取消的任务仍会等待 HTTP 响应，浪费资源且可能写入已 null 的回调。
    final dioCancel = CancelToken();
    StreamSubscription<void>? sub;
    final ct = cancelToken;
    // 如果任务在工具执行前已被取消，直接返回，不浪费 API 配额
    if (ct != null && ct.isCompleted) {
      return ToolResult.failure('搜索已被取消', output: '');
    }
    if (ct != null && !ct.isCompleted) {
      sub = ct.future.asStream().listen((_) {
        if (!dioCancel.isCancelled) {
          dioCancel.cancel('task cancelled');
        }
      });
    }

    try {
      final results = await WebSearchService.instance.search(
        query,
        maxResults: maxResults > 0 ? maxResults : null,
        dioCancelToken: dioCancel,
      );
      if (results.isEmpty) {
        return ToolResult.success('搜索完成，但未找到匹配结果。建议调整关键词后重试。');
      }
      final buffer = StringBuffer();
      buffer.writeln('共 ${results.length} 条结果：');
      buffer.writeln();
      for (var i = 0; i < results.length; i++) {
        buffer.writeln(results[i].toDisplayString(i));
        buffer.writeln();
      }
      buffer.writeln('提示：若需要某条结果的详细内容，可用 fetch_url 工具抓取其 URL。');
      return ToolResult.success(buffer.toString().trimRight());
    } on WebSearchCancelledError {
      // 用户取消：不当作失败（避免污染 _noCommandRetryCount；取消本身就是终态）
      return ToolResult.failure('搜索已被取消', output: '');
    } on WebSearchQuotaError catch (e) {
      // 配额/key 问题：明确告知 AI 不要再试本 provider
      final hint = e.permanent
          ? '（此错误为永久性，重试本 provider 不会成功，请改用你已有的知识回答，或提示用户检查配置）'
          : '（此错误可稍后重试，但建议先用已有知识继续任务）';
      return ToolResult.failure('${e.message}$hint');
    } on WebSearchTransientError catch (e) {
      return ToolResult.failure('${e.message}（瞬时错误，可重试一次）');
    } catch (e) {
      return ToolResult.failure('搜索失败: $e');
    } finally {
      await sub?.cancel();
    }
  }
}

/// 抓取指定 URL 的正文
///
/// 与 [WebSearchTool] 配合使用：搜索返回链接列表后，AI 可选择性地抓取
/// 某条结果的正文做精读。也可独立用于 AI 已知 URL 的场景（如文档链接）。
///
/// 输出：去除 HTML 标签后的纯文本（保留段落换行）。
/// 正文长度封顶 [maxChars]（默认 20000），保留**头部**。
///
/// 注意：与 AGENTS.md R8 的"retain TAIL"惯例不同——此处保留头部，
/// 因为 URL 正文阅读场景中头部通常是最重要的内容（标题/导言/正文开头），
/// 而尾部多为页脚/评论/广告。这是 R8 的明确边界例外。
class FetchUrlTool extends AgentTool {
  /// 默认正文字符上限（R8：无界缓冲必须有 cap）
  static const int _defaultMaxChars = 20000;

  /// 单次请求超时下限（秒）
  /// 网页抓取通常比搜索 API 慢，取全局配置与 20s 的较大值
  static const int _minTimeoutSeconds = 20;

  @override
  String get name => 'fetch_url';

  @override
  String get description => '抓取指定 URL 的网页正文（纯文本格式）。'
      '配合 web_search 工具使用：搜索得到 URL 后，可调本工具读取详细内容。'
      '也可独立用于已知 URL 的文档/页面抓取。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  url: 要抓取的 URL（必填，需以 http:// 或 https:// 开头）\n'
      '  max_chars: 正文最大字符数（可选，默认 20000）';

  @override
  Map<String, dynamic>? toJsonSchema() {
    return {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description': '要抓取的 URL',
        },
        'max_chars': {
          'type': 'integer',
          'description': '正文最大字符数（默认 20000）',
        },
      },
      'required': ['url'],
    };
  }

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required Map<String, dynamic> args,
    void Function(String message)? onProgress,
  }) async {
    final url = ToolArgsParser.getString(args, 'url').trim();
    final maxChars = ToolArgsParser.getInt(args, 'max_chars', defaultValue: 0);

    if (url.isEmpty) {
      return ToolResult.failure('参数缺失: url 为必填项');
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return ToolResult.failure('参数错误: url 必须以 http:// 或 https:// 开头');
    }

    final cap = maxChars > 0 ? maxChars : _defaultMaxChars;

    onProgress?.call('正在抓取: $url');

    final dioCancel = CancelToken();
    StreamSubscription<void>? sub;
    final ct = cancelToken;
    // 如果任务在工具执行前已被取消，直接返回，不发起无意义的网络请求
    if (ct != null && ct.isCompleted) {
      return ToolResult.failure('抓取已被取消', output: '');
    }
    if (ct != null && !ct.isCompleted) {
      sub = ct.future.asStream().listen((_) {
        if (!dioCancel.isCancelled) {
          dioCancel.cancel('task cancelled');
        }
      });
    }

    // 超时：取全局配置与 _minTimeoutSeconds 的较大值
    final timeoutSec = WebSearchConfig.load().timeoutSeconds.clamp(_minTimeoutSeconds, 120);
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: timeoutSec),
      receiveTimeout: Duration(seconds: timeoutSec),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
    ));

    try {
      final resp = await dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
        cancelToken: dioCancel,
      );
      final html = resp.data ?? '';
      if (html.isEmpty) {
        return ToolResult.success('抓取成功，但页面内容为空。');
      }

      onProgress?.call('解析正文...');

      final title = _extractTitle(html);
      final text = _htmlToText(html);

      final buffer = StringBuffer();
      if (title.isNotEmpty) {
        buffer.writeln('标题: $title');
        buffer.writeln();
      }
      buffer.writeln('URL: $url');
      buffer.writeln();
      buffer.writeln('正文:');
      // R8: 应用 cap；保留头部（已在类文档说明偏离原因）
      if (text.length <= cap) {
        buffer.writeln(text);
      } else {
        buffer.writeln(text.substring(0, cap));
        buffer.writeln();
        buffer.writeln('...(正文已截断，共 ${text.length} 字符，仅显示前 $cap 字符)');
      }
      return ToolResult.success(buffer.toString().trimRight());
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return ToolResult.failure('抓取已被取消', output: '');
      }
      final code = e.response?.statusCode;
      if (code == 404) {
        return ToolResult.failure('URL 不存在 (HTTP 404)：请确认链接是否正确');
      }
      if (code == 403) {
        return ToolResult.failure('目标站点拒绝访问 (HTTP 403)：可能需要登录或有反爬机制');
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError) {
        return ToolResult.failure('网络错误：${e.message ?? e.type.name}');
      }
      return ToolResult.failure('抓取失败: ${e.message ?? e.toString()}');
    } catch (e) {
      return ToolResult.failure('抓取失败: $e');
    } finally {
      dio.close();
      await sub?.cancel();
    }
  }

  /// 提取 `<title>` 内容
  String _extractTitle(String html) {
    final m = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      multiLine: true,
      dotAll: true,
    ).firstMatch(html);
    if (m == null) return '';
    return _decodeEntities(m.group(1) ?? '').trim();
  }

  /// HTML → 纯文本
  ///
  /// 策略：
  /// 1. 删除非正文区块（script/style/nav/head/header/footer/noscript）
  /// 2. 块级元素闭合标签后插入换行，保留段落结构
  /// 3. 删除所有剩余标签
  /// 4. 解码 HTML 实体
  /// 5. 压缩多余空白
  ///
  /// 不依赖外部 html 解析库（pubspec 无 html 依赖），粗糙但够用：
  /// AI 能从中提取有用信息即可，不需要像素级 markdown 还原。
  String _htmlToText(String html) {
    var s = html;
    // 1. 去除非正文区块
    //    注意：head 必须删除，否则 <title> 文本会混入正文且与"标题:"行重复
    //    header 是 HTML5 语义标签（页面页眉），与 head 不同，两者都要删
    s = s.replaceAll(
      RegExp(
        r'<(script|style|nav|head|header|footer|noscript|svg|iframe)[^>]*>.*?</\1>',
        caseSensitive: false,
        multiLine: true,
        dotAll: true,
      ),
      '',
    );
    // 2. 块级闭合标签转换行
    s = s.replaceAll(
      RegExp(
        r'</(p|div|section|article|li|h[1-6]|tr|br|blockquote|pre)>',
        caseSensitive: false,
      ),
      '\n',
    );
    // <br> 单标签
    s = s.replaceAll(
      RegExp(r'<br\s*/?>', caseSensitive: false),
      '\n',
    );
    // 3. 去剩余标签
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    // 4. 解码实体
    s = _decodeEntities(s);
    // 5. 压缩 3+ 换行为 2 个，去行首尾空白
    final lines = s.split('\n').map((l) => l.trim()).toList();
    s = lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  String _decodeEntities(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final code = int.tryParse(m.group(1) ?? '');
          return code != null ? String.fromCharCode(code) : (m.group(0) ?? '');
        })
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
          final code = int.tryParse(m.group(1) ?? '', radix: 16);
          return code != null ? String.fromCharCode(code) : (m.group(0) ?? '');
        });
  }
}
