import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'daos.dart';

/// 推送通知配置
class NotificationConfig {
  /// 是否启用
  final bool enabled;

  /// Webhook URL（支持钉钉、飞书、企业微信群机器人，或自定义 HTTP endpoint）
  final String webhookUrl;

  /// 触发条件：always = 总是推送，failedOnly = 仅失败时推送
  final String trigger;

  /// 自定义签名（可选，用于鉴权）
  final String? secret;

  const NotificationConfig({
    this.enabled = false,
    this.webhookUrl = '',
    this.trigger = 'failedOnly',
    this.secret,
  });

  NotificationConfig copyWith({
    bool? enabled,
    String? webhookUrl,
    String? trigger,
    String? secret,
  }) {
    return NotificationConfig(
      enabled: enabled ?? this.enabled,
      webhookUrl: webhookUrl ?? this.webhookUrl,
      trigger: trigger ?? this.trigger,
      secret: secret ?? this.secret,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'webhookUrl': webhookUrl,
        'trigger': trigger,
        'secret': secret,
      };

  static NotificationConfig fromJson(Map<dynamic, dynamic> json) {
    return NotificationConfig(
      enabled: json['enabled'] as bool? ?? false,
      webhookUrl: json['webhookUrl'] as String? ?? '',
      trigger: json['trigger'] as String? ?? 'failedOnly',
      secret: json['secret'] as String?,
    );
  }
}

/// 任务完成通知服务
///
/// 支持向 webhook 推送任务完成/失败通知。
/// 自动适配钉钉、飞书、企业微信群机器人的消息格式。
class NotificationService {
  static const _key = 'notificationConfig';
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    sendTimeout: const Duration(seconds: 5),
  ));

  static NotificationConfig _cache = const NotificationConfig();
  static bool _loaded = false;

  /// 加载配置（启动时调用一次）
  static Future<void> load() async {
    try {
      final raw = SettingsDao.getCached(_key);
      if (raw is Map) {
        _cache = NotificationConfig.fromJson(Map<dynamic, dynamic>.from(raw));
      }
    } catch (e) {
      debugPrint('[Notification] 加载配置失败: $e');
    }
    _loaded = true;
  }

  static NotificationConfig get config {
    if (!_loaded) load();
    return _cache;
  }

  static Future<void> save(NotificationConfig cfg) async {
    _cache = cfg;
    try {
      await SettingsDao.set(_key, cfg.toJson());
    } catch (e) {
      debugPrint('[Notification] 保存配置失败: $e');
      rethrow;
    }
  }

  /// 判断是否需要推送通知
  static bool shouldNotify({required bool success}) {
    final cfg = config;
    if (!cfg.enabled || cfg.webhookUrl.isEmpty) return false;
    if (cfg.trigger == 'always') return true;
    if (cfg.trigger == 'failedOnly') return !success;
    return false;
  }

  /// 推送任务完成通知
  ///
  /// [goal] 任务目标，[success] 是否成功，[duration] 耗时，[error] 错误信息（失败时）
  /// 返回 true 表示推送成功
  static Future<bool> notifyTaskCompletion({
    required String goal,
    required bool success,
    Duration? duration,
    String? error,
    String? hostName,
  }) async {
    final cfg = config;
    if (!shouldNotify(success: success)) return false;
    // 二次校验 URL（防 SSRF：即使配置已被篡改也不会发出）
    if (validateWebhookUrl(cfg.webhookUrl) != null) {
      debugPrint('[Notification] webhook URL 校验失败，跳过推送');
      return false;
    }

    final title = success ? '✅ 任务完成' : '❌ 任务失败';
    final durStr = duration != null
        ? '${duration.inMinutes}分${duration.inSeconds % 60}秒'
        : '未知';
    final host = hostName ?? '未指定主机';

    final content = StringBuffer()
      ..writeln('$title - AI Terminal')
      ..writeln('主机: $host')
      ..writeln('任务: $goal')
      ..writeln('状态: ${success ? "成功" : "失败"}')
      ..writeln('耗时: $durStr');
    if (!success && error != null && error.isNotEmpty) {
      content.writeln('错误: ${error.length > 200 ? '${error.substring(0, 200)}...' : error}');
    }

    try {
      return await _sendWebhook(cfg.webhookUrl, content.toString());
    } catch (e) {
      debugPrint('[Notification] 推送失败: $e');
      return false;
    }
  }

  /// 发送测试通知
  static Future<bool> sendTest() async {
    final cfg = config;
    if (cfg.webhookUrl.isEmpty) return false;
    final content = '🔔 AI Terminal 通知测试\n时间: ${DateTime.now().toIso8601String()}\n如收到此消息，说明 webhook 配置正确。';
    try {
      return await _sendWebhook(cfg.webhookUrl, content);
    } catch (e) {
      debugPrint('[Notification] 测试推送失败: $e');
      return false;
    }
  }

  /// 校验 webhook URL：仅允许 http/https，禁止内网/元数据地址（防 SSRF）
  static String? validateWebhookUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return 'URL 不能为空';
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      return '仅支持 http/https 协议';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return 'URL 格式非法';
    final host = uri.host.toLowerCase();
    const blockedHosts = ['localhost', '127.0.0.1', '0.0.0.0', 'metadata.google.internal'];
    if (blockedHosts.contains(host)) return '禁止使用本地/元数据地址';
    // 屏蔽内网 IP（10.x、172.16-31.x、192.168.x、169.254.x）
    final ipMatch = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(host);
    if (ipMatch != null) {
      final a = int.parse(ipMatch.group(1)!);
      final b = int.parse(ipMatch.group(2)!);
      if (a == 10) return '禁止使用内网地址（10.x.x.x）';
      if (a == 172 && b >= 16 && b <= 31) return '禁止使用内网地址（172.16-31.x.x）';
      if (a == 192 && b == 168) return '禁止使用内网地址（192.168.x.x）';
      if (a == 169 && b == 254) return '禁止使用链路本地/元数据地址（169.254.x.x）';
    }
    return null; // 校验通过
  }

  /// 根据 webhook 类型发送消息
  static Future<bool> _sendWebhook(String url, String text) async {
    final body = _buildRequestBody(url, text);
    final response = await _dio.post<dynamic>(
      url,
      data: body,
      options: Options(
        headers: {'Content-Type': 'application/json'},
        validateStatus: (status) => status != null && status < 300,
        // 禁止跟随重定向，防止通过 3xx 绕过白名单
        followRedirects: false,
      ),
    );
    return response.statusCode != null && response.statusCode! < 300;
  }

  /// 根据 URL 推断 webhook 类型并构建对应请求体
  static Map<String, dynamic> _buildRequestBody(String url, String text) {
    // 钉钉: oapi.dingtalk.com
    if (url.contains('oapi.dingtalk.com')) {
      return {
        'msgtype': 'text',
        'text': {'content': text},
      };
    }
    // 飞书: open.feishu.cn
    if (url.contains('open.feishu.cn') || url.contains('open.larksuite.com')) {
      return {
        'msg_type': 'text',
        'content': {'text': text},
      };
    }
    // 企业微信: qyapi.weixin.qq.com
    if (url.contains('qyapi.weixin.qq.com')) {
      return {
        'msgtype': 'text',
        'text': {'content': text},
      };
    }
    // Slack: hooks.slack.com
    if (url.contains('hooks.slack.com')) {
      return {'text': text};
    }
    // 默认：发送通用 JSON
    return {'text': text, 'content': text, 'message': text};
  }
}
