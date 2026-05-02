import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../models/command_snippet.dart';
import '../providers/app_providers.dart';

const _uuid = Uuid();

class SnippetsPage extends ConsumerStatefulWidget {
  const SnippetsPage({super.key});

  @override
  ConsumerState<SnippetsPage> createState() => _SnippetsPageState();
}

class _SnippetsPageState extends ConsumerState<SnippetsPage> {
  @override
  Widget build(BuildContext context) {
    final snippets = ref.watch(snippetsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('快捷命令'),
      ),
      body: snippets.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.all(pStandard),
              itemCount: snippets.length,
              itemBuilder: (context, index) {
                final snippet = snippets[index];
                return _buildSnippetCard(snippet);
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showSnippetDialog(),
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
          Icon(Icons.code, size: 64, color: cTextSub),
          const SizedBox(height: 16),
          Text(
            '暂无快捷命令',
            style: TextStyle(color: cTextSub, fontSize: fBody),
          ),
          const SizedBox(height: 8),
          Text(
            '点击下方按钮添加',
            style: TextStyle(color: cTextSub, fontSize: fSmall),
          ),
        ],
      ),
    );
  }

  Widget _buildSnippetCard(CommandSnippet snippet) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text(snippet.name),
        subtitle: Text(
          snippet.command,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: fSmall,
            color: cTerminalGreen,
          ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.play_arrow),
          onPressed: () => _showExecuteDialog(snippet),
        ),
        onTap: () => _showSnippetDialog(snippet),
        onLongPress: () => _showDeleteDialog(snippet),
      ),
    );
  }

  void _showSnippetDialog([CommandSnippet? snippet]) {
    showDialog(
      context: context,
      builder: (context) => SnippetDialog(
        snippet: snippet,
        onSave: (newSnippet) {
          if (snippet != null) {
            ref.read(snippetsProvider.notifier).updateSnippet(newSnippet);
          } else {
            ref.read(snippetsProvider.notifier).addSnippet(newSnippet);
          }
        },
      ),
    );
  }

  void _showExecuteDialog(CommandSnippet snippet) {
    final variables = snippet.getAllVariables();
    final controllers = <String, TextEditingController>{};

    for (final v in variables) {
      controllers[v] = TextEditingController();
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(snippet.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snippet.description != null) ...[
              Text(snippet.description!, style: TextStyle(color: cTextSub)),
              const SizedBox(height: 16),
            ],
            Text(
              '命令:',
              style: TextStyle(color: cTextSub, fontSize: fSmall),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                snippet.command,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: fMono,
                  color: cTerminalGreen,
                ),
              ),
            ),
            if (variables.isNotEmpty) ...[
              const SizedBox(height: 16),
              ...variables.map((v) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: controllers[v],
                  decoration: InputDecoration(
                    labelText: '{{$v}}',
                  ),
                ),
              )),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              final resolved = snippet.resolveCommand(
                controllers.map((k, c) => MapEntry(k, c.text)),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: SelectableText('命令: $resolved'),
                  action: SnackBarAction(
                    label: '复制',
                    onPressed: () {},
                  ),
                ),
              );
            },
            child: const Text('复制命令'),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(CommandSnippet snippet) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除命令'),
        content: Text('确定要删除 "${snippet.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(snippetsProvider.notifier).deleteSnippet(snippet.id);
            },
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

class SnippetDialog extends StatefulWidget {
  final CommandSnippet? snippet;
  final ValueChanged<CommandSnippet> onSave;

  const SnippetDialog({super.key, this.snippet, required this.onSave});

  @override
  State<SnippetDialog> createState() => _SnippetDialogState();
}

class _SnippetDialogState extends State<SnippetDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _commandController = TextEditingController();
  final _descriptionController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.snippet != null) {
      _nameController.text = widget.snippet!.name;
      _commandController.text = widget.snippet!.command;
      _descriptionController.text = widget.snippet!.description ?? '';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.snippet != null ? '编辑命令' : '新建命令'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: '名称'),
                validator: (v) => v?.isEmpty == true ? '请输入名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _commandController,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: '命令',
                  hintText: '例如: docker exec -it {{container}} /bin/bash',
                  hintStyle: TextStyle(color: cTextSub, fontSize: fSmall),
                ),
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: fMono),
                validator: (v) => v?.isEmpty == true ? '请输入命令' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: '描述 (可选)'),
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

    final snippet = CommandSnippet.create(
      id: widget.snippet?.id ?? _uuid.v4(),
      name: _nameController.text.trim(),
      command: _commandController.text.trim(),
      description: _descriptionController.text.trim().isEmpty ? null : _descriptionController.text.trim(),
    );

    widget.onSave(snippet);
    Navigator.pop(context);
  }
}
