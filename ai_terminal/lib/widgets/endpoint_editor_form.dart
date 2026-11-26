import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/app_toast.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../l10n/app_localizations.dart';
import '../models/ai_endpoint.dart';
import '../services/ai_endpoint_security.dart';
import '../services/daos.dart';
import '../services/provider_config_service.dart';
import 'inline_form.dart';
import 'provider_logo.dart';
import '../core/l10n_holder.dart';

/// 端点编辑器（抽屉内联版）。
///
/// 和 [InlineSheet] 一起用在设置抽屉里：字段、模型列表、模型子表单、拉取结果
/// 全部在同一块区域里换内容，不再叠 Dialog。以前这里是 Dialog 套 Dialog
/// （端点 → 模型 → 拉取列表三层浮层），改一个模型要关两层才回到设置。
class EndpointEditorForm extends StatefulWidget {
  const EndpointEditorForm({
    super.key,
    this.initial,
    required this.onSave,
    required this.onCancel,
  });

  final AIEndpoint? initial;
  final Future<void> Function(AIEndpoint endpoint) onSave;
  final VoidCallback onCancel;

  @override
  State<EndpointEditorForm> createState() => _EndpointEditorFormState();
}

class _EndpointEditorFormState extends State<EndpointEditorForm> {
  final _nameController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();

  String _providerId = 'custom';
  String _protocol = 'openai';
  List<AIEndpointModel> _models = [];
  bool _obscureKey = true;
  bool _fetching = false;
  bool _saving = false;
  bool _confirmRestore = false;
  String? _error;

  /// 正在编辑第几个模型；-1 表示新增。null 表示在端点主表单。
  int? _modelIndex;

  /// 拉取回来待勾选的模型 ID；null 表示没在选。
  List<String>? _fetchCandidates;
  final Set<String> _fetchPicked = {};

  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _providerId = initial.providerId;
      _protocol = initial.protocol;
      _nameController.text = initial.name;
      _baseUrlController.text = initial.baseUrl;
      _models = List<AIEndpointModel>.of(initial.models);
    } else {
      final preset = ProviderConfigService.providers.isNotEmpty
          ? ProviderConfigService.providers.first
          : null;
      _providerId = preset?.id ?? 'custom';
      _protocol = 'openai';
      if (preset != null && preset.id != 'custom') {
        _nameController.text = preset.name;
        _baseUrlController.text = preset.baseUrl;
        _models = _modelsFromPreset(preset);
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  List<AIEndpointModel> _modelsFromPreset(ProviderInfo preset) {
    return preset.models
        .map((m) => AIEndpointModel(
              id: const Uuid().v4(),
              name: m.name,
              modelName: m.name,
              contextWindow: m.contextWindow,
              maxTokens:
                  m.maxTokens > 0 ? m.maxTokens : kDefaultMaxOutputTokens,
              supportsFunctionCalling: m.supportsFunctionCalling,
            ))
        .toList();
  }

  void _onProviderChanged(String id) {
    final oldPreset = ProviderConfigService.getProviderById(_providerId);
    final preset = ProviderConfigService.getProviderById(id);
    setState(() {
      _providerId = id;
      if (!_isEditing && preset != null) {
        final nameWasPreset =
            oldPreset != null && _nameController.text.trim() == oldPreset.name;
        if (_nameController.text.trim().isEmpty || nameWasPreset) {
          _nameController.text = preset.id == 'custom' ? '' : preset.name;
        }
        if (preset.baseUrl.isNotEmpty) {
          _baseUrlController.text = preset.baseUrl;
        }
        if (_models.isEmpty && preset.id != 'custom') {
          _models = _modelsFromPreset(preset);
        }
      }
    });
  }

  List<FallbackChoice> _fallbackChoices({required String? excludeId}) {
    final choices = <FallbackChoice>[];
    final seen = <String>{};
    void add(String id, String label) {
      if (id == excludeId || !seen.add(id)) return;
      choices.add(FallbackChoice(id: id, label: label));
    }

    for (final m in _models) {
      add(m.id, m.name);
    }
    for (final e in AIEndpointsDao.cached) {
      for (final m in e.models) {
        add(m.id, '${e.name} / ${m.name}');
      }
    }
    return choices;
  }

  void _restoreDefaults() {
    final preset = ProviderConfigService.getProviderById(_providerId);
    if (preset == null || preset.models.isEmpty) {
      _snack(UiText.t('这套预设没有可恢复的模型', 'This preset has no models'),
          error: true);
      return;
    }
    final existingByModel = {for (final m in _models) m.modelName: m};
    setState(() {
      _models = preset.models.map((m) {
        final existing = existingByModel[m.name];
        return AIEndpointModel(
          id: existing?.id ?? const Uuid().v4(),
          name: m.name,
          modelName: m.name,
          contextWindow: m.contextWindow,
          maxTokens: m.maxTokens > 0 ? m.maxTokens : kDefaultMaxOutputTokens,
          supportsFunctionCalling: m.supportsFunctionCalling,
        );
      }).toList();
      _confirmRestore = false;
    });
  }

  Future<void> _fetchAvailableModels() async {
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      setState(
          () => _error = UiText.t('先填 Base URL', 'Fill in the base URL first'));
      return;
    }
    setState(() {
      _fetching = true;
      _error = null;
    });
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
    try {
      final key = _apiKeyController.text.trim().isNotEmpty
          ? _apiKeyController.text.trim()
          : (widget.initial?.apiKey ?? '');
      final response = await AiEndpointClient(dio).get<dynamic>(
        baseUrl,
        'models',
        apiKey: key,
        receiveTimeout: const Duration(seconds: 15),
      );
      final ids = _parseModelIds(response.data);
      final existing = _models.map((m) => m.modelName).toSet();
      final candidates = ids.where((id) => !existing.contains(id)).toList();
      if (!mounted) return;
      if (candidates.isEmpty) {
        _snack(UiText.t('没有新模型可加', 'No new models to add'));
        return;
      }
      setState(() {
        _fetchCandidates = candidates;
        _fetchPicked
          ..clear()
          ..addAll(candidates);
      });
    } on DioException catch (e) {
      if (mounted) _snack(_dioMessage(e), error: true);
    } catch (e) {
      if (mounted) _snack('$e', error: true);
    } finally {
      dio.close(force: true);
      if (mounted) setState(() => _fetching = false);
    }
  }

  List<String> _parseModelIds(dynamic raw) {
    dynamic data = raw;
    if (raw is String) {
      try {
        data = jsonDecode(raw);
      } catch (_) {
        return const [];
      }
    }
    if (data is Map) {
      final list = data['data'] ?? data['models'] ?? data['result'];
      if (list is List) return _idsFromList(list);
    }
    if (data is List) return _idsFromList(data);
    return const [];
  }

  List<String> _idsFromList(List<dynamic> list) {
    final ids = <String>{};
    for (final item in list) {
      if (item is String && item.trim().isNotEmpty) {
        ids.add(item.trim());
      } else if (item is Map && item['id'] is String) {
        final id = (item['id'] as String).trim();
        if (id.isNotEmpty) ids.add(id);
      } else if (item is Map && item['name'] is String) {
        final id = (item['name'] as String).trim();
        if (id.isNotEmpty) ids.add(id);
      }
    }
    final sorted = ids.toList()..sort();
    return sorted;
  }

  String _dioMessage(DioException e) {
    if (e.error is AiEndpointSecurityException) {
      return (e.error as AiEndpointSecurityException).message;
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return UiText.t('连接超时', 'Connection timed out');
      case DioExceptionType.badResponse:
        return 'HTTP ${e.response?.statusCode}';
      case DioExceptionType.connectionError:
        return UiText.t('无法连接', 'Cannot connect');
      default:
        return e.message ?? UiText.t('请求失败', 'Request failed');
    }
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    final tc = ThemeColors.of(context);
    showTopSnackBar(
      context,
      SnackBar(
        content: Text(message),
        backgroundColor: error ? tc.error : tc.ok,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = UiText.t('显示名称不能为空', 'Display name is required'));
      return;
    }
    if (_baseUrlController.text.trim().isEmpty) {
      setState(
          () => _error = UiText.t('Base URL 不能为空', 'Base URL is required'));
      return;
    }
    if (_models.isEmpty) {
      setState(() => _error = UiText.t('至少保留一个模型', 'Keep at least one model'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final initial = widget.initial;
    final endpoint = AIEndpoint(
      id: initial?.id ?? const Uuid().v4(),
      providerId: _providerId,
      name: name,
      baseUrl: _baseUrlController.text.trim(),
      protocol: _protocol,
      apiKey: _apiKeyController.text.trim().isNotEmpty
          ? _apiKeyController.text.trim()
          : (initial?.apiKey ?? ''),
      models: List<AIEndpointModel>.of(_models),
      createdAt: initial?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
    );
    try {
      await widget.onSave(endpoint);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = L10n.str.ut_5fe0b81932(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    if (_fetchCandidates != null) return _fetchPicker(tc);
    if (_modelIndex != null) return _modelForm(tc);
    return _mainForm(tc);
  }

  Widget _mainForm(ThemeColors tc) {
    final presets = ProviderConfigService.providers;
    final preset = ProviderConfigService.getProviderById(_providerId);
    final canRestore = preset != null && preset.models.isNotEmpty;
    return InlineSheet(
      title: _isEditing
          ? UiText.t('编辑端点', 'Edit endpoint')
          : UiText.t('添加端点', 'Add endpoint'),
      onBack: widget.onCancel,
      error: _error,
      actions: [
        InlineButton(label: UiText.t('取消', 'Cancel'), onTap: widget.onCancel),
        InlineButton(
          label: UiText.t('保存', 'Save'),
          primary: true,
          busy: _saving,
          onTap: _saving ? null : _save,
        ),
      ],
      children: [
        if (_isEditing)
          _readonly(
              UiText.t('服务商', 'Provider'), preset?.name ?? _providerId, tc)
        else
          InlineSelect<String>(
            label: UiText.t('服务商', 'Provider'),
            value: _providerId,
            items: [for (final p in presets) (p.id, p.name)],
            leadingBuilder: (id) => ProviderLogo(
              providerId: id,
              fallbackIcon:
                  ProviderConfigService.getProviderById(id)?.icon ?? '🔗',
              size: 14,
            ),
            onChanged: _onProviderChanged,
          ),
        const SizedBox(height: 10),
        InlineField(
          label: UiText.t('API Key', 'API Key'),
          controller: _apiKeyController,
          hint: _isEditing
              ? UiText.t('留空则沿用已保存的 Key', 'Blank keeps the saved key')
              : 'sk-…',
          obscure: _obscureKey,
          mono: true,
          trailing: GestureDetector(
            onTap: () => setState(() => _obscureKey = !_obscureKey),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                _obscureKey
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 14,
                color: tc.textMuted,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        InlineField(
          label: UiText.t('显示名称', 'Display name'),
          controller: _nameController,
        ),
        const SizedBox(height: 10),
        InlineField(
          label: 'Base URL',
          controller: _baseUrlController,
          mono: true,
          hint: 'https://api.example.com/v1',
        ),
        const SizedBox(height: 10),
        InlineSelect<String>(
          label: UiText.t('协议', 'Protocol'),
          value: _protocol,
          items: [
            ('openai', 'OpenAI 兼容'),
            ('ernie', UiText.t('文心一言', 'ERNIE')),
          ],
          onChanged: (v) => setState(() => _protocol = v),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                L10n.str.ut_5eda668d7a(_models.length),
                style: TextStyle(fontSize: fMicro, color: tc.textSub),
              ),
            ),
            _textAction(
                tc,
                UiText.t('恢复默认', 'Restore'),
                canRestore
                    ? () => setState(() => _confirmRestore = true)
                    : null),
            const SizedBox(width: 8),
            _textAction(
                tc,
                _fetching
                    ? UiText.t('拉取中…', 'Fetching…')
                    : UiText.t('从服务商拉取', 'Fetch models'),
                _fetching ? null : _fetchAvailableModels),
            const SizedBox(width: 8),
            _textAction(tc, UiText.t('添加', 'Add'), () {
              setState(() => _modelIndex = -1);
            }, brand: true),
          ],
        ),
        if (_confirmRestore)
          InlineConfirm(
            message: UiText.t(
                '用「${preset?.name ?? ''}」的默认模型覆盖当前 ${_models.length} 个模型？',
                'Replace the current ${_models.length} models with the preset list?'),
            confirmLabel: UiText.t('覆盖', 'Replace'),
            onCancel: () => setState(() => _confirmRestore = false),
            onConfirm: _restoreDefaults,
          ),
        const SizedBox(height: 4),
        if (_models.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              UiText.t('还没有模型，先添加一个。', 'No model yet — add one.'),
              style: TextStyle(fontSize: fMicro, color: tc.textMuted),
            ),
          )
        else
          for (int i = 0; i < _models.length; i++) _modelRow(tc, i),
      ],
    );
  }

  Widget _modelRow(ThemeColors tc, int index) {
    final m = _models[index];
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
      decoration: BoxDecoration(
        color: tc.card,
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: tc.hairline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: fMicro, color: tc.textMain),
                ),
                Text(
                  m.modelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fMicro,
                    color: tc.textMuted,
                    fontFamily: 'JetBrainsMono',
                    fontFamilyFallback: kMonoFontFallback,
                  ),
                ),
              ],
            ),
          ),
          _icon(tc, Icons.edit_outlined, () {
            setState(() => _modelIndex = index);
          }),
          _icon(tc, Icons.delete_outline, () {
            setState(() => _models.removeAt(index));
          }, danger: true),
        ],
      ),
    );
  }

  Widget _modelForm(ThemeColors tc) {
    final isNew = _modelIndex == -1;
    final initial = isNew ? null : _models[_modelIndex!];
    return _InlineModelForm(
      initial: initial,
      fallbackChoices:
          _fallbackChoices(excludeId: initial?.id).toList(growable: false),
      onCancel: () => setState(() => _modelIndex = null),
      onSaved: (model) {
        setState(() {
          if (isNew) {
            _models.add(model);
          } else {
            _models[_modelIndex!] = model;
          }
          _modelIndex = null;
        });
      },
    );
  }

  Widget _fetchPicker(ThemeColors tc) {
    final candidates = _fetchCandidates!;
    return InlineSheet(
      title: L10n.str.ut_c153205f28(candidates.length),
      onBack: () => setState(() => _fetchCandidates = null),
      actions: [
        InlineButton(
          label: UiText.t('取消', 'Cancel'),
          onTap: () => setState(() => _fetchCandidates = null),
        ),
        InlineButton(
          label: L10n.str.ut_9c3ca30909(_fetchPicked.length),
          primary: true,
          onTap: _fetchPicked.isEmpty
              ? null
              : () {
                  setState(() {
                    for (final id in _fetchPicked) {
                      _models.add(AIEndpointModel(
                        id: const Uuid().v4(),
                        name: id,
                        modelName: id,
                      ));
                    }
                    _fetchCandidates = null;
                  });
                },
        ),
      ],
      children: [
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          decoration: BoxDecoration(
            color: tc.card,
            borderRadius: BorderRadius.circular(rXSmall),
            border: Border.all(color: tc.hairline),
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (context, i) {
              final id = candidates[i];
              final picked = _fetchPicked.contains(id);
              return GestureDetector(
                onTap: () => setState(() {
                  if (!_fetchPicked.remove(id)) _fetchPicked.add(id);
                }),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        picked
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 14,
                        color: picked ? tc.brand : tc.textMuted,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: fMicro,
                            color: picked ? tc.textMain : tc.textSub,
                            fontFamily: 'JetBrainsMono',
                            fontFamilyFallback: kMonoFontFallback,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _readonly(String label, String value, ThemeColors tc) {
    return Row(
      children: [
        Text(label, style: TextStyle(fontSize: fMicro, color: tc.textSub)),
        const Spacer(),
        Text(value, style: TextStyle(fontSize: fSmall, color: tc.textMain)),
      ],
    );
  }

  Widget _textAction(ThemeColors tc, String label, VoidCallback? onTap,
      {bool brand = false}) {
    final enabled = onTap != null;
    final color = !enabled
        ? tc.textMuted
        : brand
            ? tc.brand
            : tc.textSub;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Text(label, style: TextStyle(fontSize: fMicro, color: color)),
    );
  }

  Widget _icon(ThemeColors tc, IconData icon, VoidCallback onTap,
      {bool danger = false}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: Icon(icon, size: 13, color: danger ? tc.error : tc.textSub),
      ),
    );
  }
}

/// 模型子表单：整个替换端点表单的内容，靠「返回」回上一级。
class _InlineModelForm extends StatefulWidget {
  const _InlineModelForm({
    required this.initial,
    required this.fallbackChoices,
    required this.onCancel,
    required this.onSaved,
  });

  final AIEndpointModel? initial;
  final List<FallbackChoice> fallbackChoices;
  final VoidCallback onCancel;
  final ValueChanged<AIEndpointModel> onSaved;

  @override
  State<_InlineModelForm> createState() => _InlineModelFormState();
}

class _InlineModelFormState extends State<_InlineModelForm> {
  final _name = TextEditingController();
  final _modelName = TextEditingController();
  final _context = TextEditingController();
  final _maxTokens = TextEditingController();

  bool _reasoning = false;
  bool _functionCalling = false;
  double _temperature = 0.3;
  String? _fallbackId;
  String? _error;
  final List<({TextEditingController level, TextEditingController value})>
      _tiers = [];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _name.text = initial.name;
      _modelName.text = initial.modelName;
      _context.text =
          initial.contextWindow > 0 ? '${initial.contextWindow}' : '';
      _maxTokens.text = initial.maxTokens > 0 ? '${initial.maxTokens}' : '';
      _reasoning = initial.reasoningEnabled;
      _functionCalling = initial.supportsFunctionCalling;
      _temperature = initial.temperature;
      _fallbackId = initial.fallbackModelId;
      for (final tier in initial.activeReasoningTiers) {
        _tiers.add((
          level: TextEditingController(text: tier.level),
          value: TextEditingController(text: tier.apiValue),
        ));
      }
    } else {
      _context.text = '$kDefaultContextWindow';
      _maxTokens.text = '$kDefaultMaxOutputTokens';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _modelName.dispose();
    _context.dispose();
    _maxTokens.dispose();
    for (final t in _tiers) {
      t.level.dispose();
      t.value.dispose();
    }
    super.dispose();
  }

  void _toggleReasoning(bool on) {
    setState(() {
      _reasoning = on;
      if (on && _tiers.isEmpty) {
        for (final t in kDefaultReasoningTiers) {
          _tiers.add((
            level: TextEditingController(text: t.level),
            value: TextEditingController(text: t.apiValue),
          ));
        }
      }
    });
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = UiText.t('显示名称不能为空', 'Display name is required'));
      return;
    }
    if (_modelName.text.trim().isEmpty) {
      setState(() => _error = UiText.t('模型 ID 不能为空', 'Model ID is required'));
      return;
    }
    final tiers = <AIReasoningTier>[];
    final seen = <String>{};
    for (final t in _tiers) {
      final level = t.level.text.trim();
      if (level.isEmpty) continue;
      if (!seen.add(level)) {
        setState(() => _error = UiText.t('档位名重复', 'Duplicate tier level'));
        return;
      }
      tiers.add(AIReasoningTier(level: level, apiValue: t.value.text.trim()));
    }
    if (_reasoning && tiers.isEmpty) {
      setState(
          () => _error = UiText.t('开启推理至少需要一个档位', 'Add at least one tier'));
      return;
    }
    final fallback = _fallbackId;
    final validFallback =
        fallback != null && widget.fallbackChoices.any((c) => c.id == fallback);
    widget.onSaved(AIEndpointModel(
      id: widget.initial?.id ?? const Uuid().v4(),
      name: _name.text.trim(),
      modelName: _modelName.text.trim(),
      contextWindow: int.tryParse(_context.text.trim()) ?? 0,
      maxTokens:
          int.tryParse(_maxTokens.text.trim()) ?? kDefaultMaxOutputTokens,
      temperature: _temperature,
      supportsFunctionCalling: _functionCalling,
      fallbackModelId: validFallback ? fallback : null,
      reasoningEnabled: _reasoning,
      reasoningTiers: tiers,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    final fallbackIds = widget.fallbackChoices.map((c) => c.id).toSet();
    final fallbackValue =
        _fallbackId != null && fallbackIds.contains(_fallbackId)
            ? _fallbackId
            : null;
    return InlineSheet(
      title: widget.initial == null
          ? l10n.aiEndpointAddModelTitle
          : l10n.aiEndpointEditModelTitle,
      onBack: widget.onCancel,
      error: _error,
      actions: [
        InlineButton(label: UiText.t('取消', 'Cancel'), onTap: widget.onCancel),
        InlineButton(
            label: UiText.t('确定', 'Done'), primary: true, onTap: _save),
      ],
      children: [
        InlineField(label: l10n.aiModelDisplayName, controller: _name),
        const SizedBox(height: 10),
        InlineField(
          label: l10n.aiModelId,
          controller: _modelName,
          mono: true,
          hint: 'gpt-4o-mini',
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: InlineField(
                  label: l10n.aiModelContextWindow, controller: _context),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InlineField(
                  label: l10n.aiModelMaxOutput, controller: _maxTokens),
            ),
          ],
        ),
        const SizedBox(height: 10),
        InlineSwitchRow(
          label: l10n.aiModelReasoning,
          subtitle: l10n.aiModelReasoningHint,
          value: _reasoning,
          onChanged: _toggleReasoning,
        ),
        if (_reasoning) ...[
          const SizedBox(height: 4),
          for (int i = 0; i < _tiers.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  Expanded(
                    child: InlineField(
                      label: l10n.aiModelTier,
                      controller: _tiers[i].level,
                      mono: true,
                      hint: 'medium',
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: InlineField(
                      label: l10n.aiModelApiValue,
                      controller: _tiers[i].value,
                      mono: true,
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      final removed = _tiers.removeAt(i);
                      removed.level.dispose();
                      removed.value.dispose();
                      setState(() {});
                    },
                    icon: Icon(Icons.remove_circle_outline,
                        size: 14, color: tc.error),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => setState(() => _tiers.add((
                    level: TextEditingController(),
                    value: TextEditingController(),
                  ))),
              behavior: HitTestBehavior.opaque,
              child: Text(l10n.aiModelAddTier,
                  style: TextStyle(fontSize: fMicro, color: tc.brand)),
            ),
          ),
        ],
        const SizedBox(height: 8),
        InlineSectionLabel(l10n.commonAdvancedSettings),
        InlineSwitchRow(
          label: l10n.aiModelFunctionCalling,
          subtitle: l10n.aiModelFunctionCallingHint,
          value: _functionCalling,
          onChanged: (v) => setState(() => _functionCalling = v),
        ),
        Row(
          children: [
            Text(l10n.aiModelTemperature,
                style: TextStyle(fontSize: fMicro, color: tc.textSub)),
            Expanded(
              child: Slider(
                value: _temperature,
                min: 0,
                max: 1,
                divisions: 10,
                onChanged: (v) => setState(() => _temperature = v),
              ),
            ),
            Text(_temperature.toStringAsFixed(1),
                style: TextStyle(fontSize: fMicro, color: tc.textMain)),
          ],
        ),
        if (widget.fallbackChoices.isNotEmpty) ...[
          const SizedBox(height: 4),
          InlineSelect<String?>(
            label: l10n.aiModelFallback,
            value: fallbackValue,
            items: [
              (null, UiText.t('不设置', 'None')),
              for (final c in widget.fallbackChoices) (c.id, c.label),
            ],
            onChanged: (v) => setState(() => _fallbackId = v),
          ),
        ],
      ],
    );
  }
}

/// 模型编辑的 fallback 候选（原 ai_models_page 里的公开小类型，抽屉也要用）。
class FallbackChoice {
  final String id;
  final String label;

  const FallbackChoice({required this.id, required this.label});
}
