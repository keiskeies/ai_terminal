import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/ai_model_config.dart';
import '../providers/app_providers.dart';
import '../services/provider_config_service.dart';

class AIModelsPage extends ConsumerStatefulWidget {
  const AIModelsPage({super.key});

  @override
  ConsumerState<AIModelsPage> createState() => _AIModelsPageState();
}

class _AIModelsPageState extends ConsumerState<AIModelsPage> {
  @override
  Widget build(BuildContext context) {
    final models = ref.watch(aiModelsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 模型配置'),
      ),
      body: models.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.all(pStandard),
              itemCount: models.length,
              itemBuilder: (context, index) {
                final model = models[index];
                return _buildModelCard(model);
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showModelDialog(),
        backgroundColor: cPrimary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.smart_toy, size: 64, color: cTextSub),
          const SizedBox(height: 16),
          Text(
            '暂无 AI 模型',
            style: TextStyle(color: cTextSub, fontSize: fBody),
          ),
          const SizedBox(height: 8),
          Text(
            '点击下方按钮添加模型',
            style: TextStyle(color: cTextSub, fontSize: fSmall),
          ),
        ],
      ),
    );
  }

  Widget _buildModelCard(AIModelConfig model) {
    final providerInfo = ProviderConfigService.getProviderById(model.provider);
    final displayName = providerInfo?.name ?? model.provider;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: Color(model.providerColorValue),
          child: Text(
            model.name.isNotEmpty ? model.name.substring(0, 1).toUpperCase() : '?',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
        title: Text(model.name),
        subtitle: Text(
          '$displayName / ${model.modelName}',
          style: TextStyle(color: cTextSub, fontSize: fSmall),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (model.isDefault)
              const Icon(Icons.star, color: Colors.amber, size: 20),
            const SizedBox(width: 8),
            const Icon(Icons.expand_more),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(pStandard),
            child: Column(
              children: [
                _buildInfoRow('API Key', model.apiKey.isEmpty ? '未设置' : '••••••••${model.apiKey.substring(model.apiKey.length > 4 ? model.apiKey.length - 4 : 0)}'),
                _buildInfoRow('Base URL', model.baseUrl),
                _buildInfoRow('模型', model.modelName),
                _buildInfoRow('温度', model.temperature.toString()),
                _buildInfoRow('最大 Token', model.maxTokens.toString()),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => _showModelDialog(model),
                      icon: const Icon(Icons.edit, size: 16),
                      label: const Text('编辑'),
                    ),
                    TextButton.icon(
                      onPressed: () => _deleteModel(model),
                      icon: Icon(Icons.delete, size: 16, color: cDanger),
                      label: Text('删除', style: TextStyle(color: cDanger)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: TextStyle(color: cTextSub, fontSize: fSmall)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: fSmall)),
          ),
        ],
      ),
    );
  }

  void _setDefault(AIModelConfig model) async {
    final updated = model.copyWith(isDefault: true);
    await ref.read(aiModelsProvider.notifier).updateModel(updated);
  }

  void _deleteModel(AIModelConfig model) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型'),
        content: Text('确定要删除 "${model.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(aiModelsProvider.notifier).deleteModel(model.id);
            },
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _showModelDialog([AIModelConfig? model]) {
    showDialog(
      context: context,
      builder: (context) => AIModelDialog(
        model: model,
        onSave: (newModel) {
          if (model != null) {
            ref.read(aiModelsProvider.notifier).updateModel(newModel);
          } else {
            ref.read(aiModelsProvider.notifier).addModel(newModel);
          }
        },
      ),
    );
  }
}

class AIModelDialog extends StatefulWidget {
  final AIModelConfig? model;
  final ValueChanged<AIModelConfig> onSave;

  const AIModelDialog({super.key, this.model, required this.onSave});

  @override
  State<AIModelDialog> createState() => _AIModelDialogState();
}

class _AIModelDialogState extends State<AIModelDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController(text: 'https://api.openai.com/v1');
  final _modelNameController = TextEditingController();

  String _provider = 'openai';
  double _temperature = 0.3;
  int _maxTokens = 4096;
  bool _isDefault = false;
  bool _obscureApiKey = true;
  bool _testing = false;
  String? _testResult;
  bool _refreshing = false;

  bool get _isFormComplete =>
      _nameController.text.trim().isNotEmpty &&
      _apiKeyController.text.trim().isNotEmpty &&
      _baseUrlController.text.trim().isNotEmpty &&
      _modelNameController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (widget.model != null) {
      _nameController.text = widget.model!.name;
      _apiKeyController.text = widget.model!.apiKey;
      _baseUrlController.text = widget.model!.baseUrl;
      _modelNameController.text = widget.model!.modelName;
      _provider = widget.model!.provider;
      _temperature = widget.model!.temperature;
      _maxTokens = widget.model!.maxTokens;
      _isDefault = widget.model!.isDefault;
    }
    _nameController.addListener(() => setState(() {}));
    _apiKeyController.addListener(() => setState(() { _testResult = null; }));
    _baseUrlController.addListener(() => setState(() { _testResult = null; }));
    _modelNameController.addListener(() => setState(() { _testResult = null; }));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelNameController.dispose();
    super.dispose();
  }

  Future<void> _refreshProviders() async {
    setState(() => _refreshing = true);
    final result = await ProviderConfigService.refreshFromRemote();
    setState(() => _refreshing = false);

    if (!mounted) return;

    if (result.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('供应商列表已更新（${result.count} 个供应商）'),
          backgroundColor: cSuccess,
          duration: const Duration(seconds: 2),
        ),
      );
      setState(() {});
    } else if (result.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('远程配置为空'),
          backgroundColor: cWarning,
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('更新失败：${result.errorMessage}'),
          backgroundColor: cDanger,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _testConnection() async {
    if (!_isFormComplete) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });

    try {
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 10);
      dio.options.receiveTimeout = const Duration(seconds: 15);

      final response = await dio.post<List<int>>(
        '${_baseUrlController.text.trim()}/chat/completions',
        data: {
          'model': _modelNameController.text.trim(),
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
          'max_tokens': 5,
          'stream': false,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer ${_apiKeyController.text.trim()}',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.bytes,
        ),
      );

      if (response.statusCode == 200) {
        setState(() => _testResult = 'success');
      } else {
        setState(() => _testResult = 'HTTP ${response.statusCode}');
      }
    } on DioException catch (e) {
      String msg;
      switch (e.type) {
        case DioExceptionType.badResponse:
          final code = e.response?.statusCode;
          if (code == 401) {
            msg = 'API Key 无效或已过期';
          } else if (code == 429) {
            msg = '请求过于频繁，请稍后重试';
          } else if (code == 400) {
            msg = '请求格式错误，请检查模型名称';
          } else if (code != null && code >= 500) {
            msg = '服务端错误 ($code)';
          } else {
            msg = '请求失败 ($code)';
          }
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          msg = '连接超时，请检查网络';
        case DioExceptionType.connectionError:
          msg = '无法连接，请检查 Base URL';
        default:
          msg = '连接失败: ${e.message ?? "未知错误"}';
      }
      setState(() => _testResult = msg);
    } catch (e) {
      setState(() => _testResult = '测试失败: $e');
    } finally {
      setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= 600;
    final dialogWidth = isWide ? 640.0 : screenWidth * 0.9;

    final providers = ProviderConfigService.providers;
    final currentProviderInfo = ProviderConfigService.getProviderById(_provider);

    final providerDropdown = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: providers.any((p) => p.id == _provider) ? _provider : null,
                decoration: InputDecoration(
                  labelText: '提供商',
                  labelStyle: TextStyle(color: tc.textSub),
                ),
                dropdownColor: tc.cardElevated,
                items: providers.map((p) => DropdownMenuItem(
                  value: p.id,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(p.icon, style: const TextStyle(fontSize: 16)),
                      const SizedBox(width: 8),
                      Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                )).toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _provider = value;
                    _testResult = null;
                    final info = ProviderConfigService.getProviderById(value);
                    if (info != null && info.baseUrl.isNotEmpty) {
                      _baseUrlController.text = info.baseUrl;
                    }
                  });
                },
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 56,
              child: Tooltip(
                message: '从服务器更新供应商列表',
                child: IconButton.outlined(
                  onPressed: _refreshing ? null : _refreshProviders,
                  icon: _refreshing
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: tc.textSub),
                        )
                      : Icon(Icons.refresh, color: tc.textSub, size: 20),
                ),
              ),
            ),
          ],
        ),
        if (currentProviderInfo != null && currentProviderInfo.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              currentProviderInfo.description,
              style: TextStyle(color: tc.textMuted, fontSize: fMicro),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );

    final nameField = TextFormField(
      controller: _nameController,
      decoration: InputDecoration(
        labelText: '名称',
        labelStyle: TextStyle(color: tc.textSub),
      ),
      style: TextStyle(color: tc.textMain),
      validator: (v) => v?.isEmpty == true ? '请输入名称' : null,
    );

    final baseUrlField = TextFormField(
      controller: _baseUrlController,
      decoration: InputDecoration(
        labelText: 'Base URL',
        labelStyle: TextStyle(color: tc.textSub),
      ),
      style: TextStyle(color: tc.textMain, fontFamily: 'JetBrainsMono', fontSize: fSmall),
      validator: (v) => v?.isEmpty == true ? '请输入 Base URL' : null,
    );

    final apiKeyField = TextFormField(
      controller: _apiKeyController,
      obscureText: _obscureApiKey,
      decoration: InputDecoration(
        labelText: 'API Key',
        labelStyle: TextStyle(color: tc.textSub),
        suffixIcon: IconButton(
          icon: Icon(_obscureApiKey ? Icons.visibility : Icons.visibility_off, color: tc.textSub),
          onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
        ),
      ),
      style: TextStyle(color: tc.textMain, fontFamily: 'JetBrainsMono'),
      validator: (v) => v?.isEmpty == true ? '请输入 API Key' : null,
    );

    final modelNameField = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (currentProviderInfo != null && currentProviderInfo.models.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: currentProviderInfo.models.map((m) {
                final isSelected = _modelNameController.text.trim() == m.name;
                return ActionChip(
                  label: Text(
                    m.label,
                    style: TextStyle(
                      fontSize: fMicro,
                      color: isSelected ? Colors.white : tc.textMain,
                    ),
                  ),
                  avatar: m.free
                      ? Text('🆓', style: const TextStyle(fontSize: 10))
                      : null,
                  backgroundColor: isSelected ? cPrimary : tc.surface,
                  side: BorderSide(color: isSelected ? cPrimary : tc.border),
                  onPressed: () {
                    setState(() {
                      _modelNameController.text = m.name;
                      _testResult = null;
                    });
                  },
                );
              }).toList(),
            ),
          ),
        TextFormField(
          controller: _modelNameController,
          decoration: InputDecoration(
            labelText: '模型名称',
            labelStyle: TextStyle(color: tc.textSub),
          ),
          style: TextStyle(color: tc.textMain, fontFamily: 'JetBrainsMono', fontSize: fSmall),
          validator: (v) => v?.isEmpty == true ? '请输入模型名称' : null,
        ),
      ],
    );

    final temperatureRow = Row(
      children: [
        SizedBox(
          width: 80,
          child: Text('温度: ${_temperature.toStringAsFixed(1)}', style: TextStyle(color: tc.textMain, fontSize: fSmall)),
        ),
        Expanded(
          child: Slider(
            value: _temperature,
            min: 0,
            max: 1,
            divisions: 10,
            onChanged: (v) => setState(() => _temperature = v),
          ),
        ),
      ],
    );

    final maxTokensField = TextFormField(
      controller: TextEditingController(text: _maxTokens.toString()),
      decoration: InputDecoration(
        labelText: '最大 Token',
        labelStyle: TextStyle(color: tc.textSub),
      ),
      style: TextStyle(color: tc.textMain),
      keyboardType: TextInputType.number,
      onChanged: (v) => _maxTokens = int.tryParse(v) ?? 4096,
    );

    final defaultSwitch = SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('设为默认', style: TextStyle(color: tc.textMain)),
      value: _isDefault,
      onChanged: (v) => setState(() => _isDefault = v),
    );

    Widget formContent;
    if (isWide) {
      formContent = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          providerDropdown,
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: nameField),
              const SizedBox(width: 16),
              Expanded(child: modelNameField),
            ],
          ),
          const SizedBox(height: 12),
          baseUrlField,
          const SizedBox(height: 12),
          apiKeyField,
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: temperatureRow),
              const SizedBox(width: 16),
              Expanded(child: maxTokensField),
            ],
          ),
          defaultSwitch,
        ],
      );
    } else {
      formContent = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          providerDropdown,
          const SizedBox(height: 12),
          nameField,
          const SizedBox(height: 12),
          modelNameField,
          const SizedBox(height: 12),
          baseUrlField,
          const SizedBox(height: 12),
          apiKeyField,
          const SizedBox(height: 12),
          temperatureRow,
          maxTokensField,
          defaultSwitch,
        ],
      );
    }

    return Dialog(
      backgroundColor: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      widget.model != null ? '编辑模型' : '添加模型',
                      style: TextStyle(color: tc.textMain, fontSize: fBody, fontWeight: FontWeight.w600),
                    ),
                    if (currentProviderInfo != null) ...[
                      const SizedBox(width: 8),
                      Text(currentProviderInfo.icon, style: const TextStyle(fontSize: 18)),
                    ],
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close, color: tc.textSub, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(
                    child: formContent,
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _isFormComplete && !_testing ? _testConnection : null,
                          icon: _testing
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.wifi_tethering, size: 16),
                          label: Text(_testing ? '测试中...' : '测试'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: cPrimary,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: cPrimary.withOpacity(0.3),
                            disabledForegroundColor: Colors.white.withOpacity(0.5),
                          ),
                        ),
                        if (_testResult != null) ...[
                          const SizedBox(width: 8),
                          Icon(
                            _testResult == 'success' ? Icons.check_circle : Icons.error,
                            color: _testResult == 'success' ? cSuccess : cDanger,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              _testResult == 'success' ? '连接成功' : _testResult!,
                              style: TextStyle(
                                color: _testResult == 'success' ? cSuccess : cDanger,
                                fontSize: fSmall,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text('取消', style: TextStyle(color: tc.textSub)),
                    ),
                    ElevatedButton(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(backgroundColor: cPrimary, foregroundColor: Colors.white),
                      child: const Text('保存'),
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

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final model = AIModelConfig.create(
      id: widget.model?.id ?? const Uuid().v4(),
      provider: _provider,
      name: _nameController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      modelName: _modelNameController.text.trim(),
      temperature: _temperature,
      maxTokens: _maxTokens,
      isDefault: _isDefault,
    );

    widget.onSave(model);
    Navigator.pop(context);
  }
}
