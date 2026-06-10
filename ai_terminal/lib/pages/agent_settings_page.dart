import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../core/hive_init.dart';
import '../core/prompts.dart';
import '../core/theme_colors.dart';
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
    final maxSteps = ref.watch(agentProvider.select((s) => s.maxSteps));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent 设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(pStandard),
        children: [
          // 最大执行步骤数
          _buildSectionTitle('执行控制'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(pStandard),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('最大执行步骤数', style: TextStyle(color: ThemeColors.of(context).textMain)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: cPrimary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(rSmall),
                        ),
                        child: Text(
                          maxSteps == 0 ? '无限制' : '$maxSteps',
                          style: TextStyle(
                            color: cPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Agent 自动模式下的最大执行步骤数。设为 0 表示无限制，复杂任务不会被中断。',
                    style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: fSmall),
                  ),
                  const SizedBox(height: 12),
                  Slider(
                    value: maxSteps.toDouble(),
                    min: 0,
                    max: 50,
                    divisions: 50,
                    label: maxSteps == 0 ? '无限制' : '$maxSteps',
                    onChanged: (value) {
                      ref.read(agentProvider.notifier).setMaxSteps(value.toInt());
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('无限制', style: TextStyle(color: ThemeColors.of(context).textMuted, fontSize: fMicro)),
                      Text('50步', style: TextStyle(color: ThemeColors.of(context).textMuted, fontSize: fMicro)),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // 提示词设置
          _buildSectionTitle('提示词设置'),

          // 内置系统提示词（折叠面板）
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              leading: Icon(Icons.description_outlined, color: cWarning),
              title: Text('内置系统提示词'),
              subtitle: Text('编辑 AI 的核心提示词', style: TextStyle(color: cTextSub, fontSize: fSmall)),
              children: [
                Padding(
                  padding: const EdgeInsets.all(pStandard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '这是 AI 的核心系统提示词，修改后立即生效。包含 {context} 占位符会被替换为服务器信息。',
                        style: TextStyle(color: cTextSub, fontSize: fSmall),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '⚠️ 修改需谨慎，不合适的提示词可能导致 AI 行为异常。可随时点击"重置"恢复默认。',
                        style: TextStyle(color: cWarning, fontSize: fMicro),
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
              leading: Icon(Icons.edit_note_rounded, color: cAgentGreen),
              title: Text('自定义提示词'),
              subtitle: Text('追加到内置提示词末尾的额外指令', style: TextStyle(color: cTextSub, fontSize: fSmall)),
              children: [
                Padding(
                  padding: const EdgeInsets.all(pStandard),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '追加到内置提示词末尾的额外指令，用于调整 AI 的行为风格、输出偏好等。留空则不追加。',
                        style: TextStyle(color: cTextSub, fontSize: fSmall),
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
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(
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
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton.icon(
              onPressed: () {
                setState(() => _controller.text = defaultSystemPrompt);
              },
              icon: Icon(Icons.restore, color: cWarning, size: 18),
              label: Text('重置默认', style: TextStyle(color: cWarning)),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () {
                saveSystemPrompt(_controller.text.trim());
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('内置提示词已保存'),
                    duration: Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.save, size: 18),
              label: const Text('保存'),
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
      savedPrompt = HiveInit.settingsBox.get('customSystemPrompt') as String?;
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
            hintText: '例如：回答使用英文、输出简洁格式、优先使用 Docker...',
            hintStyle: TextStyle(color: ThemeColors.of(context).textMuted, fontSize: fSmall),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: ThemeColors.of(context).border)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: cPrimary)),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () {
                try {
                  HiveInit.settingsBox.put('customSystemPrompt', _controller.text.trim());
                } catch (_) {}
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('自定义提示词已保存'),
                    duration: Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.save, size: 18),
              label: const Text('保存'),
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
