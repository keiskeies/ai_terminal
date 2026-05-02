import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../models/ai_model_config.dart';
import '../providers/app_providers.dart';

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
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: Color(model.providerColorValue),
          child: Text(
            model.providerIcon,
            style: const TextStyle(fontSize: 18),
          ),
        ),
        title: Text(model.name),
        subtitle: Text(
          '${model.provider} / ${model.modelName}',
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
        content: Text('确定要删除 \"${model.name}\" 吗？'),
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
  }

  @override
  void dispose() {
    _nameController.dispose();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.model != null ? '编辑模型' : '添加模型'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: _provider,
                decoration: const InputDecoration(labelText: '提供商'),
                items: const [
                  DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                  DropdownMenuItem(value: 'qwen', child: Text('通义千问')),
                  DropdownMenuItem(value: 'ernie', child: Text('文心一言')),
                ],
                onChanged: (value) {
                  setState(() {
                    _provider = value!;
                    if (value == 'openai') {
                      _baseUrlController.text = 'https://api.openai.com/v1';
                    } else if (value == 'qwen') {
                      _baseUrlController.text = 'https://dashscope.aliyuncs.com/api/v1';
                    } else if (value == 'ernie') {
                      _baseUrlController.text = 'https://aip.baidubce.com/rpc/2.0/ai_custom/v1';
                    }
                  });
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: '名称'),
                validator: (v) => v?.isEmpty == true ? '请输入名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _apiKeyController,
                obscureText: _obscureApiKey,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  suffixIcon: IconButton(
                    icon: Icon(_obscureApiKey ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
                  ),
                ),
                validator: (v) => v?.isEmpty == true ? '请输入 API Key' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _baseUrlController,
                decoration: const InputDecoration(labelText: 'Base URL'),
                validator: (v) => v?.isEmpty == true ? '请输入 Base URL' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _modelNameController,
                decoration: const InputDecoration(labelText: '模型名称'),
                validator: (v) => v?.isEmpty == true ? '请输入模型名称' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text('温度: ${_temperature.toStringAsFixed(1)}'),
                  ),
                  Expanded(
                    flex: 2,
                    child: Slider(
                      value: _temperature,
                      min: 0,
                      max: 1,
                      divisions: 10,
                      onChanged: (v) => setState(() => _temperature = v),
                    ),
                  ),
                ],
              ),
              TextFormField(
                controller: TextEditingController(text: _maxTokens.toString()),
                decoration: const InputDecoration(labelText: '最大 Token'),
                keyboardType: TextInputType.number,
                onChanged: (v) => _maxTokens = int.tryParse(v) ?? 4096,
              ),
              SwitchListTile(
                title: const Text('设为默认'),
                value: _isDefault,
                onChanged: (v) => setState(() => _isDefault = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
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
