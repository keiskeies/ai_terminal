import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../services/daos.dart';
import '../core/prompts.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../providers/agent_provider.dart';

/// P1-5: Agent 设置页面
/// 整合最大执行步骤数、内置提示词、自定义提示词
class AgentSettingsPage extends ConsumerStatefulWidget {
  const AgentSettingsPage({super.key});

  @override
  ConsumerState<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends ConsumerState<AgentSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    final maxSteps = ref.watch(agentProvider.select((s) => s.maxSteps));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.agentSettingTitle),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.all(pStandard),
            children: [
              // 最大执行步骤数
              _buildSectionTitle(l10n.agentSettingAutoExecSection),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(pStandard),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(l10n.agentSettingMaxStepsLabel, style: TextStyle(color: ThemeColors.of(context).textMain)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: cPrimary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(rSmall),
                        ),
                        child: Text(
                          maxSteps == 0 ? l10n.commonUnlimited : '$maxSteps',
                          style: const TextStyle(
                            color: cPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.agentSettingMaxStepsDesc,
                    style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: fSmall),
                  ),
                  const SizedBox(height: 12),
                  Slider(
                    value: maxSteps.clamp(0, 100).toDouble(),
                    min: 0,
                    max: 100,
                    divisions: 100,
                    label: maxSteps == 0 ? l10n.commonUnlimited : '$maxSteps',
                    onChanged: (value) {
                      ref.read(agentProvider.notifier).setMaxSteps(value.toInt());
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(l10n.commonUnlimited, style: TextStyle(color: ThemeColors.of(context).textMuted, fontSize: fMicro)),
                      Text(l10n.agentSettingHundredSteps, style: TextStyle(color: ThemeColors.of(context).textMuted, fontSize: fMicro)),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // 提示词设置
          _buildSectionTitle(l10n.agentSettingPromptSection),

          // 内置系统提示词（折叠面板）
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              leading: const Icon(Icons.description_outlined, color: cWarning),
              title: Text(l10n.agentSettingBuiltInPrompt),
              subtitle: Text(l10n.agentSettingBuiltInPromptSubtitle, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
              children: [
                Padding(
                  padding: const EdgeInsets.all(pStandard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.agentSettingBuiltInPromptDesc,
                        style: TextStyle(color: tc.textSub, fontSize: fSmall),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.agentSettingPromptWarning,
                        style: const TextStyle(color: cWarning, fontSize: fMicro),
                      ),
                      const SizedBox(height: 12),
                      _BuiltInPromptEditor(),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 自定义提示词（折叠面板）
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              leading: Icon(Icons.edit_note_rounded, color: tc.agentGreen),
              title: Text(l10n.agentSettingExtraPrompt),
              subtitle: Text(l10n.agentSettingExtraPromptSubtitle, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
              children: [
                Padding(
                  padding: const EdgeInsets.all(pStandard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.agentSettingExtraPromptDesc,
                        style: TextStyle(color: tc.textSub, fontSize: fSmall),
                      ),
                      const SizedBox(height: 12),
                      _CustomPromptEditor(),
                    ],
                  ),
                ),
              ],
            ),
          ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: fTitle,
          fontWeight: FontWeight.w600,
          color: cPrimary,
        ),
      ),
    );
  }
}

/// 内置提示词编辑器
class _BuiltInPromptEditor extends StatefulWidget {
  @override
  State<_BuiltInPromptEditor> createState() => _BuiltInPromptEditorState();
}

class _BuiltInPromptEditorState extends State<_BuiltInPromptEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: getSystemPrompt());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        TextField(
          controller: _controller,
          maxLines: 8,
          minLines: 4,
          style: TextStyle(
            color: ThemeColors.of(context).textMain,
            fontSize: fSmall,
            fontFamily: 'JetBrainsMono',
          ),
          decoration: InputDecoration(
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: ThemeColors.of(context).border)),
            focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton.icon(
              onPressed: () {
                setState(() => _controller.text = defaultSystemPrompt);
              },
              icon: const Icon(Icons.restore, color: cWarning, size: 18),
              label: Text(l10n.commonResetDefault, style: const TextStyle(color: cWarning)),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () {
                saveSystemPrompt(_controller.text.trim());
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.agentSettingBuiltInSaved),
                    duration: const Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.save, size: 18),
              label: Text(l10n.save),
              style: ElevatedButton.styleFrom(
                backgroundColor: cPrimary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 自定义提示词编辑器
class _CustomPromptEditor extends StatefulWidget {
  @override
  State<_CustomPromptEditor> createState() => _CustomPromptEditorState();
}

class _CustomPromptEditorState extends State<_CustomPromptEditor> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    String? savedPrompt;
    try {
      savedPrompt = SettingsDao.getCached('customSystemPrompt') as String?;
    } catch (_) {}
    _controller = TextEditingController(text: savedPrompt ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        TextField(
          controller: _controller,
          maxLines: 6,
          minLines: 3,
          style: TextStyle(
            color: ThemeColors.of(context).textMain,
            fontSize: fBody,
          ),
          decoration: InputDecoration(
            hintText: l10n.agentSettingCustomPromptHint,
            hintStyle: TextStyle(color: ThemeColors.of(context).textMuted, fontSize: fSmall),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: ThemeColors.of(context).border)),
            focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () {
                try {
                  SettingsDao.set('customSystemPrompt', _controller.text.trim());
                } catch (_) {}
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.agentSettingExtraPromptSaved),
                    duration: const Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.save, size: 18),
              label: Text(l10n.save),
              style: ElevatedButton.styleFrom(
                backgroundColor: cPrimary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
