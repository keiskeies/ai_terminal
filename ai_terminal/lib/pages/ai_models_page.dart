import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../models/ai_model_config.dart';
import '../providers/app_providers.dart';
import '../services/provider_config_service.dart';

/// P1-6: AI 模型配置页面简化
/// - 模型卡片改为固定高度，操作按钮外露
/// - 添加/编辑对话框简化，高级参数折叠
/// - 测试连接按钮更醒目
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
            '还没有 AI 模型',
            style: TextStyle(color: cTextSub, fontSize: fBody),
          ),
          const SizedBox(height: 8),
          Text(
            '配置你的第一个 AI 模型，开启智能运维',
            style: TextStyle(color: cTextSub, fontSize: fSmall),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => _showModelDialog(),
            icon: const Icon(Icons.add),
            label: const Text('添加模型'),
          ),
        ],
      ),
    );
  }

  /// P1-6: 简化模型卡片 - 固定高度，操作按钮外露
  Widget _buildModelCard(AIModelConfig model) {
    final providerInfo = ProviderConfigService.getProviderById(model.provider);
    final displayName = providerInfo?.name ?? model.provider;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Container(
        height: 80,
        padding: const EdgeInsets.symmetric(horizontal: pStandard),
        child: Row(
          children: [
            // 头像
            CircleAvatar(
              backgroundColor: Color(model.providerColorValue),
              child: Text(
                model.name.isNotEmpty ? model.name.substring(0, 1).toUpperCase() : '?',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            const SizedBox(width: 12),
            // 信息
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          model.name,
                          style: TextStyle(
                            fontSize: fBody,
                            fontWeight: FontWeight.w600,
                            color: ThemeColors.of(context).textMain,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (model.isDefault) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.star, color: Colors.amber, size: 16),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$displayName / ${model.modelName}',
                    style: TextStyle(color: cTextSub, fontSize: fSmall),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // 操作按钮
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 设为默认
                if (!model.isDefault)
                  _ActionButton(
                    icon: Icons.star_border,
                    tooltip: '设为默认',
                    onTap: () => _setDefault(model),
                  ),
                const SizedBox(width: 4),
                // 编辑
                _ActionButton(
                  icon: Icons.edit,
                  tooltip: '编辑',
                  onTap: () => _showModelDialog(model),
                ),
                const SizedBox(width: 4),
                // 删除
                _ActionButton(
                  icon: Icons.delete,
                  tooltip: '删除',
                  color: cDanger,
                  onTap: () => _deleteModel(model),
                ),
              ],
            ),
          ],
        ),
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

/// 快捷操作按钮
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color? color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.tooltip,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rSmall),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: tc.surface,
            borderRadius: BorderRadius.circular(rSmall),
          ),
          child: Icon(icon, size: 16, color: color ?? tc.textSub),
        ),
      ),
    );
  }
}

/// P1-6: 简化版模型对话框
/// - 默认只显示核心字段
/// - 高级参数在折叠面板中
/// - 测试按钮紧邻 API Key 字段
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
  bool _showAdvanced = false;
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
            msg = 'API Key 无效';
          } else if (code == 429) {
            msg = '请求过于频繁';
          } else if (code == 400) {
            msg = '模型名称错误';
          } else if (code != null && code >= 500) {
            msg = '服务端错误 ($code)';
          } else {
            msg = '请求失败 ($code)';
          }
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          msg = '连接超时';
        case DioExceptionType.connectionError:
          msg = '无法连接';
        default:
          msg = '连接失败';
      }
      setState(() => _testResult = msg);
    } catch (e) {
      setState(() => _testResult = '测试失败');
    } finally {
      setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final providers = ProviderConfigService.providers;
    final currentProviderInfo = ProviderConfigService.getProviderById(_provider);

    return Dialog(
      backgroundColor: tc.cardElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLarge)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题
                Row(
                  children: [
                    Text(
                      widget.model != null ? '编辑模型' : '添加模型',
                      style: TextStyle(color: tc.textMain, fontSize: fTitle, fontWeight: FontWeight.w600),
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
                const SizedBox(height: 20),

                // 核心字段
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 提供商
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
                                message: '更新供应商列表',
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
                        const SizedBox(height: 16),

                        // 名称
                        TextFormField(
                          controller: _nameController,
                          decoration: InputDecoration(
                            labelText: '名称',
                            labelStyle: TextStyle(color: tc.textSub),
                          ),
                          style: TextStyle(color: tc.textMain),
                          validator: (v) => v?.isEmpty == true ? '请输入名称' : null,
                        ),
                        const SizedBox(height: 16),

                        // 模型名称 + 快捷芯片
                        if (currentProviderInfo != null && currentProviderInfo.models.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
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
                                  avatar: m.free ? Text('🆓', style: const TextStyle(fontSize: 10)) : null,
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
                        const SizedBox(height: 16),

                        // API Key + 测试按钮
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _apiKeyController,
                                obscureText: _obscureApiKey,
                                decoration: InputDecoration(
                                  labelText: 'API Key',
                                  labelStyle: TextStyle(color: tc.textSub),
                                  suffixIcon: IconButton(
                                    icon: Icon(_obscureApiKey ? Icons.visibility : Icons.visibility_off, color: tc.textSub, size: 20),
                                    onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
                                  ),
                                ),
                                style: TextStyle(color: tc.textMain, fontFamily: 'JetBrainsMono', fontSize: fSmall),
                                validator: (v) => v?.isEmpty == true ? '请输入 API Key' : null,
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              height: 56,
                              child: ElevatedButton.icon(
                                onPressed: _isFormComplete && !_testing ? _testConnection : null,
                                icon: _testing
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Icon(Icons.wifi_tethering, size: 16),
                                label: Text(_testing ? '...' : '测试'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _testResult == 'success' ? cSuccess : cPrimary,
                                  foregroundColor: Colors.white,
                                  disabledBackgroundColor: cPrimary.withOpacity(0.3),
                                ),
                              ),
                            ),
                          ],
                        ),
                        // 测试结果
                        if (_testResult != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, left: 12),
                            child: Row(
                              children: [
                                Icon(
                                  _testResult == 'success' ? Icons.check_circle : Icons.error,
                                  color: _testResult == 'success' ? cSuccess : cDanger,
                                  size: 14,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _testResult == 'success' ? '连接成功' : _testResult!,
                                  style: TextStyle(
                                    color: _testResult == 'success' ? cSuccess : cDanger,
                                    fontSize: fMicro,
                                  ),
                                ),
                              ],
                            ),
                          ),

                        const SizedBox(height: 16),

                        // 设为默认
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('设为默认模型', style: TextStyle(color: tc.textMain, fontSize: fBody)),
                          value: _isDefault,
                          onChanged: (v) => setState(() => _isDefault = v),
                        ),

                        const SizedBox(height: 8),

                        // 高级设置（折叠面板）
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text('高级设置', style: TextStyle(color: tc.textSub, fontSize: fBody)),
                          children: [
                            const SizedBox(height: 8),
                            // Base URL
                            TextFormField(
                              controller: _baseUrlController,
                              decoration: InputDecoration(
                                labelText: 'Base URL',
                                labelStyle: TextStyle(color: tc.textSub),
                              ),
                              style: TextStyle(color: tc.textMain, fontFamily: 'JetBrainsMono', fontSize: fSmall),
                              validator: (v) => v?.isEmpty == true ? '请输入 Base URL' : null,
                            ),
                            const SizedBox(height: 16),
                            // Temperature
                            Row(
                              children: [
                                SizedBox(
                                  width: 80,
                                  child: Text('温度', style: TextStyle(color: tc.textMain, fontSize: fSmall)),
                                ),
                                Expanded(
                                  child: Slider(
                                    value: _temperature,
                                    min: 0,
                                    max: 1,
                                    divisions: 10,
                                    label: _temperature.toStringAsFixed(1),
                                    onChanged: (v) => setState(() => _temperature = v),
                                  ),
                                ),
                                SizedBox(
                                  width: 40,
                                  child: Text(
                                    _temperature.toStringAsFixed(1),
                                    style: TextStyle(color: tc.textMain, fontSize: fSmall),
                                    textAlign: TextAlign.right,
                                  ),
                                ),
                              ],
                            ),
                            // Max Tokens
                            TextFormField(
                              controller: TextEditingController(text: _maxTokens.toString()),
                              decoration: InputDecoration(
                                labelText: '最大 Token',
                                labelStyle: TextStyle(color: tc.textSub),
                              ),
                              style: TextStyle(color: tc.textMain),
                              keyboardType: TextInputType.number,
                              onChanged: (v) => _maxTokens = int.tryParse(v) ?? 4096,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // 底部按钮
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text('取消', style: TextStyle(color: tc.textSub)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: cPrimary,
                        foregroundColor: Colors.white,
                      ),
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
