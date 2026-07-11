import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
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
    final l10n = AppLocalizations.of(context)!;
    final snippets = ref.watch(snippetsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.snippetTitle),
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
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.code, size: 64, color: tc.textSub),
          const SizedBox(height: 16),
          Text(
            l10n.snippetEmptyTitle,
            style: TextStyle(color: tc.textSub, fontSize: fBody),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.snippetEmptyHint,
            style: TextStyle(color: tc.textSub, fontSize: fSmall),
          ),
        ],
      ),
    );
  }

  Widget _buildSnippetCard(CommandSnippet snippet) {
    final tc = ThemeColors.of(context);
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
            color: tc.terminalGreen,
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
    final l10n = AppLocalizations.of(context)!;
    final variables = snippet.getAllVariables();
    final controllers = <String, TextEditingController>{};

    for (final v in variables) {
      controllers[v] = TextEditingController();
    }

    showDialog(
      context: context,
      builder: (context) {
        final tc = ThemeColors.of(context);
        return AlertDialog(
        title: Text(snippet.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snippet.description != null) ...[
              Text(snippet.description!, style: TextStyle(color: tc.textSub)),
              const SizedBox(height: 16),
            ],
            Text(
              l10n.snippetCommandLabel,
              style: TextStyle(color: tc.textSub, fontSize: fSmall),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: tc.terminalBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                snippet.command,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: fMono,
                  color: tc.terminalGreen,
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
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              final resolved = snippet.resolveCommand(
                controllers.map((k, c) => MapEntry(k, c.text)),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: SelectableText(l10n.snippetResolvedCommand(resolved)),
                  action: SnackBarAction(
                    label: l10n.copy,
                    onPressed: () {},
                  ),
                ),
              );
            },
            child: Text(l10n.snippetCopyCommand),
          ),
        ],
      );
      },
    );
  }

  void _showDeleteDialog(CommandSnippet snippet) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.snippetDeleteTitle),
        content: Text(l10n.snippetDeleteConfirm(snippet.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(snippetsProvider.notifier).deleteSnippet(snippet.id);
            },
            style: ElevatedButton.styleFrom(backgroundColor: cDanger),
            child: Text(l10n.delete),
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
    final tc = ThemeColors.of(context);
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.snippet != null ? l10n.snippetEditTitle : l10n.snippetNewTitle),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(labelText: l10n.commonName),
                validator: (v) => v?.isEmpty == true ? l10n.snippetNameRequired : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _commandController,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: l10n.commonCommand,
                  hintText: '例如: docker exec -it {{container}} /bin/bash',
                  hintStyle: TextStyle(color: tc.textSub, fontSize: fSmall),
                ),
                style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: fMono),
                validator: (v) => v?.isEmpty == true ? l10n.snippetCommandRequired : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descriptionController,
                decoration: InputDecoration(labelText: l10n.snippetFieldDescription),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        ElevatedButton(
          onPressed: _save,
          child: Text(l10n.save),
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
