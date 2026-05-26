import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';

const String _boxName = 'provider_config';
const String _providersKey = 'providers_json';
const String _versionKey = 'providers_version';
const String _remoteConfigUrl = 'https://ai-terminal.keiskei.top/config/ai_providers.json';

class ModelInfo {
  final String name;
  final String label;
  final bool free;

  const ModelInfo({
    required this.name,
    required this.label,
    this.free = false,
  });

  factory ModelInfo.fromJson(Map<String, dynamic> json) {
    return ModelInfo(
      name: json['name'] as String? ?? '',
      label: json['label'] as String? ?? '',
      free: json['free'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'label': label,
        if (free) 'free': free,
      };
}

class ProviderInfo {
  final String id;
  final String name;
  final String provider;
  final String baseUrl;
  final String region;
  final String description;
  final String? apiKeyUrl;
  final String? tokenPlanUrl;
  final String? codingPlanUrl;
  final String? websiteUrl;
  final String icon;
  final int colorValue;
  final List<ModelInfo> models;

  const ProviderInfo({
    required this.id,
    required this.name,
    this.provider = 'OPENAI',
    required this.baseUrl,
    this.region = 'GLOBAL',
    this.description = '',
    this.apiKeyUrl,
    this.tokenPlanUrl,
    this.codingPlanUrl,
    this.websiteUrl,
    required this.icon,
    required this.colorValue,
    this.models = const [],
  });

  factory ProviderInfo.fromJson(Map<String, dynamic> json) {
    final modelsList = json['models'] as List<dynamic>? ?? [];
    return ProviderInfo(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      provider: json['provider'] as String? ?? 'OPENAI',
      baseUrl: json['baseUrl'] as String? ?? '',
      region: json['region'] as String? ?? 'GLOBAL',
      description: json['description'] as String? ?? '',
      apiKeyUrl: json['apiKeyUrl'] as String?,
      tokenPlanUrl: json['tokenPlanUrl'] as String?,
      codingPlanUrl: json['codingPlanUrl'] as String?,
      websiteUrl: json['websiteUrl'] as String?,
      icon: json['icon'] as String? ?? '💬',
      colorValue: _parseColor(json['color']),
      models: modelsList.map((e) => ModelInfo.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'provider': provider,
        'baseUrl': baseUrl,
        'region': region,
        'description': description,
        if (apiKeyUrl != null) 'apiKeyUrl': apiKeyUrl,
        if (tokenPlanUrl != null) 'tokenPlanUrl': tokenPlanUrl,
        if (codingPlanUrl != null) 'codingPlanUrl': codingPlanUrl,
        if (websiteUrl != null) 'websiteUrl': websiteUrl,
        'icon': icon,
        'color': '0x${colorValue.toRadixString(16).padLeft(8, '0').toUpperCase()}',
        'models': models.map((m) => m.toJson()).toList(),
      };

  static int _parseColor(dynamic color) {
    if (color is int) return color;
    if (color is String) {
      final hex = color.replaceFirst('0x', '').replaceFirst('0X', '');
      return int.tryParse(hex, radix: 16) ?? 0xFF002FA7;
    }
    return 0xFF002FA7;
  }
}

class ProviderConfigService {
  static Box? _box;
  static List<ProviderInfo> _providers = [];
  static bool _initialized = false;

  static List<ProviderInfo> get providers => _providers;

  static Future<void> init() async {
    if (_initialized) return;
    _box = await Hive.openBox(_boxName);

    final cached = _box?.get(_providersKey) as String?;
    if (cached != null && cached.isNotEmpty) {
      try {
        _providers = _parseProvidersJson(cached);
      } catch (_) {
        _providers = await _loadEmbedded();
      }
    } else {
      _providers = await _loadEmbedded();
      await _saveProviders(_providers);
    }

    _initialized = true;
  }

  static Future<List<ProviderInfo>> _loadEmbedded() async {
    try {
      final jsonStr = await rootBundle.loadString('assets/config/ai_providers.json');
      return _parseProvidersJson(jsonStr);
    } catch (_) {
      return [
        const ProviderInfo(
          id: 'openai',
          name: 'OpenAI',
          baseUrl: 'https://api.openai.com/v1',
          icon: '🤖',
          colorValue: 0xFF6ECC54,
        ),
        const ProviderInfo(
          id: 'qwen',
          name: '通义千问 Qwen',
          baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
          icon: '🐯',
          colorValue: 0xFF002FA7,
        ),
        const ProviderInfo(
          id: 'deepseek',
          name: 'DeepSeek 深度求索',
          baseUrl: 'https://api.deepseek.com/v1',
          icon: '🐋',
          colorValue: 0xFF4D6BFE,
        ),
        const ProviderInfo(
          id: 'ollama',
          name: 'Ollama (本地)',
          baseUrl: 'http://localhost:11434/v1',
          icon: '🦙',
          colorValue: 0xFF6366F1,
        ),
        const ProviderInfo(
          id: 'custom',
          name: '自定义',
          baseUrl: '',
          icon: '🔧',
          colorValue: 0xFF8888A0,
        ),
      ];
    }
  }

  static Future<RefreshResult> refreshFromRemote() async {
    try {
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 10);
      dio.options.receiveTimeout = const Duration(seconds: 15);

      final response = await dio.get(_remoteConfigUrl);
      if (response.statusCode == 200 && response.data != null) {
        String jsonStr;
        if (response.data is String) {
          jsonStr = response.data as String;
        } else {
          jsonStr = jsonEncode(response.data);
        }

        final newProviders = _parseProvidersJson(jsonStr);
        if (newProviders.isNotEmpty) {
          _providers = newProviders;
          await _saveProviders(_providers);
          final version = response.headers.value('etag') ?? DateTime.now().millisecondsSinceEpoch.toString();
          await _box?.put(_versionKey, version);
          return RefreshResult.success(newProviders.length);
        }
        return RefreshResult.empty();
      }
      return RefreshResult.failed('HTTP ${response.statusCode}');
    } on DioException catch (e) {
      String msg;
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          msg = '连接超时';
        case DioExceptionType.connectionError:
          msg = '网络连接失败';
        default:
          msg = '请求失败: ${e.message ?? "未知错误"}';
      }
      return RefreshResult.failed(msg);
    } catch (e) {
      return RefreshResult.failed('刷新失败: $e');
    }
  }

  static Future<void> _saveProviders(List<ProviderInfo> providers) async {
    final jsonList = providers.map((p) => p.toJson()).toList();
    await _box?.put(_providersKey, jsonEncode({'providers': jsonList}));
  }

  static List<ProviderInfo> _parseProvidersJson(String jsonStr) {
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final list = data['providers'] as List<dynamic>? ?? [];
    return list.map((e) => ProviderInfo.fromJson(e as Map<String, dynamic>)).toList();
  }

  static ProviderInfo? getProviderById(String id) {
    try {
      return _providers.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }
}

class RefreshResult {
  final bool isSuccess;
  final bool isEmpty;
  final String? errorMessage;
  final int? count;

  const RefreshResult._({
    this.isSuccess = false,
    this.isEmpty = false,
    this.errorMessage,
    this.count,
  });

  factory RefreshResult.success(int count) => RefreshResult._(isSuccess: true, count: count);
  factory RefreshResult.empty() => const RefreshResult._(isEmpty: true);
  factory RefreshResult.failed(String msg) => RefreshResult._(errorMessage: msg);
}
