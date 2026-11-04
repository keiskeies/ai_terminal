import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../models/ai_endpoint.dart';
import '../providers/app_providers.dart';
import '../services/daos.dart';
import '../services/provider_config_service.dart';

/// AI 模型配置：一个端点（Base URL + API Key + 协议）下挂多个模型。
///
/// 没有「默认模型」：当前使用哪个模型由 Agent 输入框底部的选择器决定。
class AIModelsPage extends ConsumerStatefulWidget {
  const AIModelsPage({super.key});

  @override
  ConsumerState<AIModelsPage> createState() => _AIModelsPageState();
}

class _AIModelsPageState extends ConsumerState<AIModelsPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    final endpoints = ref.watch(aiEndpointsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aiModelTitle)),
      body: endpoints.isEmpty
          ? _buildEmptyState(l10n, tc)
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                  pStandard, pStandard, pStandard, 80),
              itemCount: endpoints.length,
              itemBuilder: (context, index) =>
                  _buildEndpointCard(endpoints[index], tc, l10n),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEndpointDialog(),
        tooltip: l10n.aiEndpointAdd,
        backgroundColor: tc.brand,
        foregroundColor: tc.isLight ? Colors.white : cBg,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildEmptyState(AppLocalizations l10n, ThemeColors tc) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.hub_outlined, size: 64, color: tc.textSub),
          const SizedBox(height: 16),
          Text(l10n.aiModelEmptyTitle,
              style: TextStyle(color: tc.textSub, fontSize: fBody)),
          const SizedBox(height: 8),
          Text(l10n.aiModelEmptySubtitle,
              style: TextStyle(color: tc.textSub, fontSize: fSmall)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => _showEndpointDialog(),
            icon: const Icon(Icons.add),
            label: Text(l10n.aiEndpointAdd),
          ),
        ],
      ),
    );
  }

  Widget _buildEndpointCard(
      AIEndpoint endpoint, ThemeColors tc, AppLocalizations l10n) {
    final preset = ProviderConfigService.getProviderById(endpoint.providerId);
    final color = Color(preset?.colorValue ?? 0xFF8888A0);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(rCard),
        onTap: () => _showEndpointDialog(endpoint),
        child: Padding(
          padding: const EdgeInsets.all(pStandard),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.16),
                    child: Text(
                      preset?.icon ?? '🔗',
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                endpoint.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tc.textMain,
                                  fontSize: fBody,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _Badge(
                              text: preset?.name ?? l10n.aiEndpointNoProvider,
                              color: tc.textSub,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${l10n.aiEndpointModelsCount(endpoint.models.length)} · ${endpoint.baseUrl}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tc.textSub,
                            fontSize: fSmall,
                            fontFamily: 'JetBrainsMono',
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.edit,
                    onPressed: () => _showEndpointDialog(endpoint),
                    icon: Icon(Icons.edit_outlined,
                        size: 18, color: tc.textSub),
                  ),
                  IconButton(
                    tooltip: l10n.delete,
                    onPressed: () => _deleteEndpoint(endpoint),
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: cDanger),
                  ),
                ],
              ),
              if (endpoint.models.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final model in endpoint.models.take(6))
                      _ModelChip(model: model, tc: tc),
                    if (endpoint.models.length > 6)
                      _Badge(
                        text: '+${endpoint.models.length - 6}',
                        color: tc.textMuted,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showEndpointDialog([AIEndpoint? endpoint]) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => EndpointEditorDialog(
        initial: endpoint,
        onSave: (next) async {
          await ref.read(aiEndpointsProvider.notifier).saveEndpoint(next);
        },
      ),
    );
  }

  void _deleteEndpoint(AIEndpoint endpoint) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.aiEndpointDeleteTitle),
        content: Text(l10n.aiEndpointDeleteConfirm(
            endpoint.name, endpoint.models.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              ref.read(aiEndpointsProvider.notifier).deleteEndpoint(endpoint.id);
            },
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;

  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontSize: fMicro, height: 1.3)),
    );
  }
}

class _ModelChip extends StatelessWidget {
  final AIEndpointModel model;
  final ThemeColors tc;

  const _ModelChip({required this.model, required this.tc});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tc.surface,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            model.name,
            style: TextStyle(color: tc.textBody, fontSize: fMicro),
          ),
          if (model.reasoningEnabled) ...[
            const SizedBox(width: 4),
            Icon(Icons.bolt_outlined, size: 11, color: tc.brand),
          ],
        ],
      ),
    );
  }
}

/// 端点编辑：API 密钥、显示名称、地址、协议、模型目录。
class EndpointEditorDialog extends StatefulWidget {
  final AIEndpoint? initial;
  final Future<void> Function(AIEndpoint endpoint) onSave;

  const EndpointEditorDialog({
    super.key,
    this.initial,
    required this.onSave,
  });

  @override
  State<EndpointEditorDialog> createState() => _EndpointEditorDialogState();
}

class _EndpointEditorDialogState extends State<EndpointEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();

  String _providerId = 'custom';
  String _protocol = 'openai';
  List<AIEndpointModel> _models = [];
  bool _obscureKey = true;
  bool _fetching = false;
  bool _saving = false;
  String? _error;

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
    _nameController.addListener(() => setState(() {}));
    _baseUrlController.addListener(() => setState(() {}));
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
        final nameWasPreset = oldPreset != null &&
            _nameController.text.trim() == oldPreset.name;
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

  Future<void> _addModel() async {
    final result = await showDialog<AIEndpointModel>(
      context: context,
      builder: (_) => ModelEditorDialog(
        fallbackChoices: _fallbackChoices(excludeId: null),
      ),
    );
    if (result != null && mounted) {
      setState(() => _models.add(result));
    }
  }

  Future<void> _editModel(int index) async {
    final current = _models[index];
    final result = await showDialog<AIEndpointModel>(
      context: context,
      builder: (_) => ModelEditorDialog(
        initial: current,
        fallbackChoices: _fallbackChoices(excludeId: current.id),
      ),
    );
    if (result != null && mounted) {
      setState(() => _models[index] = result);
    }
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

  Future<void> _restoreDefaults() async {
    final l10n = AppLocalizations.of(context)!;
    final preset = ProviderConfigService.getProviderById(_providerId);
    if (preset == null || preset.models.isEmpty) {
      _showSnack(l10n.aiEndpointRestoreUnavailable, isError: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.aiEndpointRestoreDefaults),
        content: Text(l10n.aiEndpointRestoreConfirm(preset.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final existingByModel = {
      for (final m in _models) m.modelName: m,
    };
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
    });
  }

  Future<void> _fetchAvailableModels() async {
    final l10n = AppLocalizations.of(context)!;
    final baseUrl = _baseUrlController.text.trim();
    if (baseUrl.isEmpty) {
      setState(() => _error = l10n.aiModelValidationBaseUrl);
      return;
    }
    setState(() {
      _fetching = true;
      _error = null;
    });
    try {
      final key = _apiKeyController.text.trim().isNotEmpty
          ? _apiKeyController.text.trim()
          : (widget.initial?.apiKey ?? '');
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ));
      final normalizedBase =
          baseUrl.replaceAll(RegExp(r'/+$'), '');
      final response = await dio.get<dynamic>(
        '$normalizedBase/models',
        options: Options(
          headers: {
            if (key.isNotEmpty) 'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          },
        ),
      );
      final ids = _parseModelIds(response.data);
      final existing = _models.map((m) => m.modelName).toSet();
      final candidates = ids.where((id) => !existing.contains(id)).toList();
      if (!mounted) return;
      if (candidates.isEmpty) {
        _showSnack(l10n.aiEndpointFetchNone);
        return;
      }
      final selected = await showDialog<List<String>>(
        context: context,
        builder: (_) => _ModelFetchDialog(modelIds: candidates),
      );
      if (selected == null || selected.isEmpty || !mounted) return;
      setState(() {
        for (final id in selected) {
          _models.add(AIEndpointModel(
            id: const Uuid().v4(),
            name: id,
            modelName: id,
          ));
        }
      });
      _showSnack(l10n.aiEndpointFetchSuccess(selected.length));
    } on DioException catch (e) {
      if (!mounted) return;
      _showSnack(l10n.aiEndpointFetchFailed(_dioMessage(e)), isError: true);
    } catch (e) {
      if (!mounted) return;
      _showSnack(l10n.aiEndpointFetchFailed('$e'), isError: true);
    } finally {
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
      if (list is List) {
        return _idsFromList(list);
      }
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
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时';
      case DioExceptionType.badResponse:
        return 'HTTP ${e.response?.statusCode}';
      case DioExceptionType.connectionError:
        return '无法连接';
      default:
        return e.message ?? '请求失败';
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? cDanger : cSuccess,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_models.isEmpty) {
      setState(() => _error = l10n.aiModelValidationModels);
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
      name: _nameController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      protocol: _protocol,
      apiKey: _apiKeyController.text.trim().isNotEmpty
          ? _apiKeyController.text.trim()
          : (initial?.apiKey ?? ''),
      models: List<AIEndpointModel>.of(_models),
      createdAt:
          initial?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
    );
    try {
      await widget.onSave(endpoint);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    final presets = ProviderConfigService.providers;
    final preset =
        ProviderConfigService.getProviderById(_providerId);
    final canRestore = preset != null && preset.models.isNotEmpty;

    return Dialog(
      backgroundColor: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.all(pLarge),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _isEditing
                          ? l10n.aiEndpointEditTitle
                          : l10n.aiEndpointAdd,
                      style: TextStyle(
                        color: tc.textMain,
                        fontSize: fTitle,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      icon: Icon(Icons.close, color: tc.textSub, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DropdownButtonFormField<String>(
                          key: ValueKey('provider-$_providerId-$_isEditing'),
                          initialValue: presets.any((p) => p.id == _providerId)
                              ? _providerId
                              : null,
                          decoration: InputDecoration(
                            labelText: l10n.aiModelProvider,
                            labelStyle: TextStyle(color: tc.textSub),
                          ),
                          dropdownColor: tc.cardElevated,
                          items: presets
                              .map((p) => DropdownMenuItem(
                                    value: p.id,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(p.icon,
                                            style:
                                                const TextStyle(fontSize: 16)),
                                        const SizedBox(width: 8),
                                        Flexible(
                                            child: Text(p.name,
                                                overflow:
                                                    TextOverflow.ellipsis)),
                                      ],
                                    ),
                                  ))
                              .toList(),
                          onChanged: _isEditing
                              ? null
                              : (value) {
                                  if (value != null) _onProviderChanged(value);
                                },
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _apiKeyController,
                          obscureText: _obscureKey,
                          decoration: InputDecoration(
                            labelText: l10n.aiEndpointApiKey,
                            labelStyle: TextStyle(color: tc.textSub),
                            helperText: _isEditing
                                ? l10n.aiEndpointApiKeyHint
                                : null,
                            helperStyle:
                                TextStyle(color: tc.textMuted, fontSize: fMicro),
                            suffixIcon: IconButton(
                              onPressed: () => setState(
                                  () => _obscureKey = !_obscureKey),
                              icon: Icon(
                                _obscureKey
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                color: tc.textSub,
                                size: 18,
                              ),
                            ),
                          ),
                          style: TextStyle(
                            color: tc.textMain,
                            fontFamily: 'JetBrainsMono',
                            fontSize: fSmall,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          initiallyExpanded: true,
                          title: Text(l10n.aiEndpointCustomSettings,
                              style:
                                  TextStyle(color: tc.textSub, fontSize: fBody)),
                          children: [
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _nameController,
                              decoration: InputDecoration(
                                labelText: l10n.aiModelDisplayName,
                                labelStyle: TextStyle(color: tc.textSub),
                              ),
                              style: TextStyle(color: tc.textMain),
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? l10n.aiModelValidationName
                                  : null,
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _baseUrlController,
                              decoration: InputDecoration(
                                labelText: l10n.aiEndpointBaseUrl,
                                labelStyle: TextStyle(color: tc.textSub),
                              ),
                              style: TextStyle(
                                color: tc.textMain,
                                fontFamily: 'JetBrainsMono',
                                fontSize: fSmall,
                              ),
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? l10n.aiModelValidationBaseUrl
                                  : null,
                            ),
                            const SizedBox(height: 14),
                            DropdownButtonFormField<String>(
                              initialValue: _protocol,
                              decoration: InputDecoration(
                                labelText: l10n.aiEndpointProtocol,
                                labelStyle: TextStyle(color: tc.textSub),
                              ),
                              dropdownColor: tc.cardElevated,
                              items: [
                                DropdownMenuItem(
                                  value: 'openai',
                                  child:
                                      Text(l10n.aiEndpointProtocolOpenai),
                                ),
                                DropdownMenuItem(
                                  value: 'ernie',
                                  child:
                                      Text(l10n.aiEndpointProtocolErnie),
                                ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() => _protocol = value);
                                }
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Divider(height: 1, color: tc.border),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Text(
                              l10n.aiEndpointModels,
                              style: TextStyle(
                                color: tc.textMain,
                                fontSize: fBody,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              l10n.aiEndpointModelsCount(_models.length),
                              style: TextStyle(
                                  color: tc.textMuted, fontSize: fMicro),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            TextButton.icon(
                              onPressed:
                                  canRestore ? _restoreDefaults : null,
                              icon: const Icon(Icons.restart_alt, size: 15),
                              label: Text(l10n.aiEndpointRestoreDefaults),
                              style: TextButton.styleFrom(
                                  foregroundColor: tc.textSub,
                                  textStyle:
                                      const TextStyle(fontSize: fSmall)),
                            ),
                            TextButton.icon(
                              onPressed: _fetching
                                  ? null
                                  : _fetchAvailableModels,
                              icon: _fetching
                                  ? const SizedBox(
                                      width: 13,
                                      height: 13,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(
                                      Icons.cloud_download_outlined,
                                      size: 15),
                              label: Text(l10n.aiEndpointFetchModels),
                              style: TextButton.styleFrom(
                                  foregroundColor: tc.textSub,
                                  textStyle:
                                      const TextStyle(fontSize: fSmall)),
                            ),
                            TextButton.icon(
                              onPressed: _addModel,
                              icon: const Icon(Icons.add, size: 15),
                              label: Text(l10n.aiEndpointAddModel),
                              style: TextButton.styleFrom(
                                  foregroundColor: tc.brand,
                                  textStyle:
                                      const TextStyle(fontSize: fSmall)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (_models.isEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(pCompact),
                            decoration: BoxDecoration(
                              color: tc.surface,
                              borderRadius: BorderRadius.circular(rSmall),
                              border: Border.all(
                                  color: tc.border.withValues(alpha: 0.5)),
                            ),
                            child: Text(
                              l10n.aiEndpointNoModels,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: tc.textMuted, fontSize: fSmall),
                            ),
                          )
                        else
                          for (int i = 0; i < _models.length; i++)
                            _buildModelRow(i, tc, l10n),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: const TextStyle(color: cDanger, fontSize: fSmall)),
                ],
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: Text(l10n.commonCancel,
                          style: TextStyle(color: tc.textSub)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: tc.brand,
                        foregroundColor: tc.isLight ? Colors.white : cBg,
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Text(l10n.save),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModelRow(int index, ThemeColors tc, AppLocalizations l10n) {
    final model = _models[index];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tc.surface,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        model.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tc.textMain,
                          fontSize: fSmall,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (model.reasoningEnabled) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.bolt_outlined, size: 12, color: tc.brand),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  model.modelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tc.textSub,
                    fontSize: fMicro,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${_formatTokens(model.contextWindow)} / ${_formatTokens(model.maxTokens)}',
            style: TextStyle(color: tc.textMuted, fontSize: fMicro),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: l10n.edit,
            onPressed: () => _editModel(index),
            icon: Icon(Icons.edit_outlined, size: 16, color: tc.textSub),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            tooltip: l10n.delete,
            onPressed: () => setState(() => _models.removeAt(index)),
            icon: const Icon(Icons.delete_outline, size: 16, color: cDanger),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

String _formatTokens(int value) {
  if (value <= 0) return '—';
  if (value >= 1048576 && value % 1048576 == 0) {
    return '${value ~/ 1048576}M';
  }
  if (value >= 1000) return '${(value / 1000).round()}K';
  return '$value';
}

class FallbackChoice {
  final String id;
  final String label;

  const FallbackChoice({required this.id, required this.label});
}

/// 单个模型编辑：显示名/模型 ID/上下文/最大输出/推理档位/高级参数。
class ModelEditorDialog extends StatefulWidget {
  final AIEndpointModel? initial;
  final List<FallbackChoice> fallbackChoices;

  const ModelEditorDialog({
    super.key,
    this.initial,
    this.fallbackChoices = const [],
  });

  @override
  State<ModelEditorDialog> createState() => _ModelEditorDialogState();
}

class _TierControllers {
  final TextEditingController level;
  final TextEditingController apiValue;

  _TierControllers({String level = '', String apiValue = ''})
      : level = TextEditingController(text: level),
        apiValue = TextEditingController(text: apiValue);

  void dispose() {
    level.dispose();
    apiValue.dispose();
  }
}

class _ModelEditorDialogState extends State<ModelEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _modelNameController = TextEditingController();
  final _contextController = TextEditingController();
  final _maxTokensController = TextEditingController();

  bool _reasoningEnabled = false;
  bool _supportsFunctionCalling = false;
  double _temperature = 0.3;
  String? _fallbackModelId;
  String? _error;
  final List<_TierControllers> _tiers = [];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _nameController.text = initial.name;
      _modelNameController.text = initial.modelName;
      _contextController.text =
          initial.contextWindow > 0 ? '${initial.contextWindow}' : '';
      _maxTokensController.text =
          initial.maxTokens > 0 ? '${initial.maxTokens}' : '';
      _reasoningEnabled = initial.reasoningEnabled;
      _supportsFunctionCalling = initial.supportsFunctionCalling;
      _temperature = initial.temperature;
      _fallbackModelId = initial.fallbackModelId;
      for (final tier in initial.activeReasoningTiers) {
        _tiers.add(
            _TierControllers(level: tier.level, apiValue: tier.apiValue));
      }
    } else {
      // 新模型显式给出默认值：256K 上下文 / 32K 最大输出
      _contextController.text = '$kDefaultContextWindow';
      _maxTokensController.text = '$kDefaultMaxOutputTokens';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _modelNameController.dispose();
    _contextController.dispose();
    _maxTokensController.dispose();
    for (final t in _tiers) {
      t.dispose();
    }
    super.dispose();
  }

  void _toggleReasoning(bool enabled) {
    setState(() {
      _reasoningEnabled = enabled;
      if (enabled && _tiers.isEmpty) {
        for (final t in kDefaultReasoningTiers) {
          _tiers.add(
              _TierControllers(level: t.level, apiValue: t.apiValue));
        }
      }
    });
  }

  void _addTier() {
    setState(() => _tiers.add(_TierControllers()));
  }

  void _removeTier(int index) {
    setState(() {
      _tiers.removeAt(index).dispose();
    });
  }

  void _save() {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final tiers = <AIReasoningTier>[];
    final seen = <String>{};
    for (final t in _tiers) {
      final level = t.level.text.trim();
      if (level.isEmpty) {
        if (_reasoningEnabled) {
          setState(() => _error = l10n.aiModelTierLevelRequired);
          return;
        }
        continue;
      }
      if (!seen.add(level)) {
        setState(() => _error = l10n.aiModelTierDuplicate);
        return;
      }
      tiers.add(AIReasoningTier(
          level: level, apiValue: t.apiValue.text.trim()));
    }
    if (_reasoningEnabled && tiers.isEmpty) {
      setState(() => _error = l10n.aiModelTierRequired);
      return;
    }

    final fallback = _fallbackModelId;
    final validFallback = fallback != null &&
        widget.fallbackChoices.any((c) => c.id == fallback);

    final model = AIEndpointModel(
      id: widget.initial?.id ?? const Uuid().v4(),
      name: _nameController.text.trim(),
      modelName: _modelNameController.text.trim(),
      contextWindow: int.tryParse(_contextController.text.trim()) ?? 0,
      maxTokens:
          int.tryParse(_maxTokensController.text.trim()) ??
              kDefaultMaxOutputTokens,
      temperature: _temperature,
      supportsFunctionCalling: _supportsFunctionCalling,
      fallbackModelId: validFallback ? fallback : null,
      reasoningEnabled: _reasoningEnabled,
      reasoningTiers: tiers,
    );
    Navigator.pop(context, model);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    final fallbackIds = widget.fallbackChoices.map((c) => c.id).toSet();
    final fallbackValue = _fallbackModelId != null &&
            fallbackIds.contains(_fallbackModelId)
        ? _fallbackModelId
        : null;

    return Dialog(
      backgroundColor: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.all(pLarge),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      widget.initial == null
                          ? l10n.aiEndpointAddModelTitle
                          : l10n.aiEndpointEditModelTitle,
                      style: TextStyle(
                        color: tc.textMain,
                        fontSize: fTitle,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close, color: tc.textSub, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _nameController,
                                decoration: InputDecoration(
                                  labelText: l10n.aiModelDisplayName,
                                  labelStyle: TextStyle(color: tc.textSub),
                                ),
                                style: TextStyle(color: tc.textMain),
                                validator: (v) =>
                                    (v == null || v.trim().isEmpty)
                                        ? l10n.aiModelValidationName
                                        : null,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextFormField(
                                controller: _modelNameController,
                                decoration: InputDecoration(
                                  labelText: l10n.aiModelId,
                                  labelStyle: TextStyle(color: tc.textSub),
                                ),
                                style: TextStyle(
                                  color: tc.textMain,
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: fSmall,
                                ),
                                validator: (v) =>
                                    (v == null || v.trim().isEmpty)
                                        ? l10n.aiModelValidationModelId
                                        : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _contextController,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: l10n.aiModelContextWindow,
                                  labelStyle: TextStyle(color: tc.textSub),
                                  helperText:
                                      l10n.aiModelContextWindowHint,
                                  helperStyle: TextStyle(
                                      color: tc.textMuted,
                                      fontSize: fMicro),
                                ),
                                style: TextStyle(color: tc.textMain),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextFormField(
                                controller: _maxTokensController,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: l10n.aiModelMaxOutput,
                                  labelStyle: TextStyle(color: tc.textSub),
                                ),
                                style: TextStyle(color: tc.textMain),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.aiModelReasoning,
                              style: TextStyle(
                                  color: tc.textMain, fontSize: fBody)),
                          subtitle: Text(l10n.aiModelReasoningHint,
                              style: TextStyle(
                                  color: tc.textSub, fontSize: fMicro)),
                          value: _reasoningEnabled,
                          onChanged: _toggleReasoning,
                        ),
                        if (_reasoningEnabled) ...[
                          Row(
                            children: [
                              Expanded(
                                child: Text(l10n.aiModelTier,
                                    style: TextStyle(
                                        color: tc.textMuted,
                                        fontSize: fMicro)),
                              ),
                              SizedBox(
                                width: 200,
                                child: Text(l10n.aiModelApiValue,
                                    style: TextStyle(
                                        color: tc.textMuted,
                                        fontSize: fMicro)),
                              ),
                              const SizedBox(width: 32),
                            ],
                          ),
                          const SizedBox(height: 4),
                          for (int i = 0; i < _tiers.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _tiers[i].level,
                                      decoration: InputDecoration(
                                        hintText: 'off / low / medium / high',
                                        hintStyle: TextStyle(
                                            color: tc.textMuted,
                                            fontSize: fMicro),
                                        isDense: true,
                                      ),
                                      style: TextStyle(
                                        color: tc.textMain,
                                        fontSize: fSmall,
                                        fontFamily: 'JetBrainsMono',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 200,
                                    child: TextField(
                                      controller: _tiers[i].apiValue,
                                      decoration: InputDecoration(
                                        hintText: l10n.aiModelApiValueHint,
                                        hintStyle: TextStyle(
                                            color: tc.textMuted,
                                            fontSize: fMicro),
                                        isDense: true,
                                      ),
                                      style: TextStyle(
                                        color: tc.textMain,
                                        fontSize: fSmall,
                                        fontFamily: 'JetBrainsMono',
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () => _removeTier(i),
                                    icon: const Icon(Icons.delete_outline,
                                        size: 16, color: cDanger),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                            ),
                          TextButton.icon(
                            onPressed: _addTier,
                            icon: const Icon(Icons.add, size: 15),
                            label: Text(l10n.aiModelAddTier),
                            style: TextButton.styleFrom(
                                foregroundColor: tc.brand,
                                textStyle:
                                    const TextStyle(fontSize: fSmall)),
                          ),
                        ],
                        const SizedBox(height: 4),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text(l10n.commonAdvancedSettings,
                              style: TextStyle(
                                  color: tc.textSub, fontSize: fBody)),
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(l10n.aiModelFunctionCalling,
                                  style: TextStyle(
                                      color: tc.textMain, fontSize: fBody)),
                              subtitle: Text(
                                l10n.aiModelFunctionCallingHint,
                                style: TextStyle(
                                    color: tc.textSub, fontSize: fMicro),
                              ),
                              value: _supportsFunctionCalling,
                              onChanged: (v) =>
                                  setState(() => _supportsFunctionCalling = v),
                            ),
                            Row(
                              children: [
                                SizedBox(
                                  width: 80,
                                  child: Text(l10n.aiModelTemperature,
                                      style: TextStyle(
                                          color: tc.textMain,
                                          fontSize: fSmall)),
                                ),
                                Expanded(
                                  child: Slider(
                                    value: _temperature,
                                    min: 0,
                                    max: 1,
                                    divisions: 10,
                                    label: _temperature.toStringAsFixed(1),
                                    onChanged: (v) =>
                                        setState(() => _temperature = v),
                                  ),
                                ),
                                SizedBox(
                                  width: 36,
                                  child: Text(
                                    _temperature.toStringAsFixed(1),
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                        color: tc.textMain,
                                        fontSize: fSmall),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            DropdownButtonFormField<String?>(
                              key: ValueKey('fallback-$fallbackValue'),
                              initialValue: fallbackValue,
                              decoration: InputDecoration(
                                labelText: l10n.aiModelFallback,
                                labelStyle: TextStyle(color: tc.textSub),
                              ),
                              dropdownColor: tc.cardElevated,
                              items: [
                                DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text(l10n.aiModelNoFallback,
                                      style:
                                          TextStyle(color: tc.textMuted)),
                                ),
                                ...widget.fallbackChoices.map((c) =>
                                    DropdownMenuItem<String?>(
                                      value: c.id,
                                      child: Text(c.label,
                                          overflow: TextOverflow.ellipsis),
                                    )),
                              ],
                              onChanged: (v) =>
                                  setState(() => _fallbackModelId = v),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: const TextStyle(color: cDanger, fontSize: fSmall)),
                ],
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l10n.commonCancel,
                          style: TextStyle(color: tc.textSub)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: tc.brand,
                        foregroundColor: tc.isLight ? Colors.white : cBg,
                      ),
                      child: Text(l10n.save),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 获取可用模型后的多选对话框。
class _ModelFetchDialog extends StatefulWidget {
  final List<String> modelIds;

  const _ModelFetchDialog({required this.modelIds});

  @override
  State<_ModelFetchDialog> createState() => _ModelFetchDialogState();
}

class _ModelFetchDialogState extends State<_ModelFetchDialog> {
  late final Set<String> _selected = {...widget.modelIds};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    final allSelected = _selected.length == widget.modelIds.length;
    return AlertDialog(
      title: Text(l10n.aiEndpointSelectModels),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(allSelected ? l10n.commonAll : l10n.commonAll,
                  style: TextStyle(fontSize: fSmall, color: tc.textSub)),
              value: allSelected,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selected.addAll(widget.modelIds);
                  } else {
                    _selected.clear();
                  }
                });
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: widget.modelIds.length,
                itemBuilder: (context, index) {
                  final id = widget.modelIds[index];
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(id,
                        style: TextStyle(
                          color: tc.textMain,
                          fontSize: fSmall,
                          fontFamily: 'JetBrainsMono',
                        )),
                    value: _selected.contains(id),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(id);
                        } else {
                          _selected.remove(id);
                        }
                      });
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        ElevatedButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected.toList()),
          child: Text(l10n.commonConfirm),
        ),
      ],
    );
  }
}
