import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../models/ai_endpoint.dart';
import '../services/ai_model_selection_service.dart';

/// 输入框底部的模型/思考档位选择面板。
///
/// 用本地 state 维护当前选择：MenuAnchor 的 overlay 不会随父页面重建，
/// 所有选择立即回调给终端页（持久化 + 重建引擎），面板自身同步高亮。
class ModelPickerPanel extends StatefulWidget {
  final List<AIEndpoint> endpoints;
  final String? currentModelId;
  final String? currentTierLevel;
  final ThemeColors tc;
  final void Function(AIModelChoice choice, AIReasoningTier? tier)
      onModelSelected;
  final ValueChanged<AIReasoningTier> onTierSelected;
  final VoidCallback onManage;
  final VoidCallback onDone;

  const ModelPickerPanel({
    super.key,
    required this.endpoints,
    required this.currentModelId,
    required this.currentTierLevel,
    required this.tc,
    required this.onModelSelected,
    required this.onTierSelected,
    required this.onManage,
    required this.onDone,
  });

  @override
  State<ModelPickerPanel> createState() => _ModelPickerPanelState();
}

class _ModelPickerPanelState extends State<ModelPickerPanel> {
  String? _modelId;
  String? _tierLevel;

  @override
  void initState() {
    super.initState();
    _modelId = widget.currentModelId;
    _tierLevel = widget.currentTierLevel;
  }

  @override
  void didUpdateWidget(covariant ModelPickerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentModelId != oldWidget.currentModelId) {
      _modelId = widget.currentModelId;
      _tierLevel = widget.currentTierLevel;
    }
  }

  AIModelChoice? get _choice => _modelId == null
      ? null
      : AIModelSelectionService.findChoice(widget.endpoints, _modelId!);

  void _selectModel(AIModelChoice choice) {
    final tier = choice.model
        .resolveReasoningTier(AIModelSelectionService.tierFor(choice.modelId));
    setState(() {
      _modelId = choice.modelId;
      _tierLevel = tier?.level;
    });
    widget.onModelSelected(choice, tier);
  }

  void _selectTier(AIReasoningTier tier) {
    setState(() => _tierLevel = tier.level);
    widget.onTierSelected(tier);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tc = widget.tc;
    final height =
        (MediaQuery.of(context).size.height * 0.55).clamp(260.0, 420.0);
    final choice = _choice;
    final tiers = choice?.model.activeReasoningTiers ?? const [];

    return SizedBox(
      width: 330,
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Icon(Icons.psychology_outlined, size: 15, color: tc.brand),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.terminalModelAndReasoning,
                    style: TextStyle(
                      color: tc.textMain,
                      fontSize: fSmall,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: tc.border),
          Expanded(
            child: widget.endpoints.every((e) => e.models.isEmpty)
                ? Center(
                    child: Text(
                      l10n.aiModelEmptyTitle,
                      style: TextStyle(color: tc.textSub, fontSize: fSmall),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final endpoint in widget.endpoints)
                        if (endpoint.models.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    endpoint.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: tc.textSub,
                                      fontSize: fMicro,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  l10n.aiEndpointModelsCount(
                                      endpoint.models.length),
                                  style: TextStyle(
                                      color: tc.textMuted, fontSize: fMicro),
                                ),
                              ],
                            ),
                          ),
                          for (final model in endpoint.models)
                            _buildModelRow(
                              AIModelChoice(endpoint: endpoint, model: model),
                            ),
                        ],
                    ],
                  ),
          ),
          Divider(height: 1, color: tc.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.bolt_outlined, size: 13, color: tc.textMuted),
                    const SizedBox(width: 4),
                    Text(
                      l10n.terminalReasoning,
                      style: TextStyle(
                        color: tc.textSub,
                        fontSize: fMicro,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (choice == null || !choice.model.reasoningEnabled)
                  Text(
                    l10n.terminalReasoningNotEnabled,
                    style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tier in tiers) _buildTierChip(tier, l10n),
                    ],
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                TextButton(
                  onPressed: widget.onManage,
                  child: Text(
                    l10n.terminalManageModels,
                    style: TextStyle(fontSize: fMicro, color: tc.textSub),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: widget.onDone,
                  child: Text(
                    l10n.commonConfirm,
                    style: TextStyle(fontSize: fMicro, color: tc.brand),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelRow(AIModelChoice choice) {
    final tc = widget.tc;
    final selected = choice.modelId == _modelId;
    return InkWell(
      onTap: () => _selectModel(choice),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: selected ? tc.brand.withValues(alpha: 0.1) : Colors.transparent,
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              size: 14,
              color: selected ? tc.brand : tc.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    choice.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? tc.brand : tc.textMain,
                      fontSize: fSmall,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  Text(
                    choice.model.modelName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                  ),
                ],
              ),
            ),
            if (choice.model.reasoningEnabled)
              Icon(Icons.bolt_outlined, size: 12, color: tc.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildTierChip(AIReasoningTier tier, AppLocalizations l10n) {
    final tc = widget.tc;
    final selected = tier.level == _tierLevel;
    final label = tier.level == 'off' ? l10n.terminalReasoningOff : tier.label;
    return InkWell(
      onTap: () => _selectTier(tier),
      borderRadius: BorderRadius.circular(rSmall),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? tc.brand.withValues(alpha: 0.15) : tc.surface,
          borderRadius: BorderRadius.circular(rSmall),
          border: Border.all(
            color: selected ? tc.brand : tc.border.withValues(alpha: 0.5),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? tc.brand : tc.textSub,
            fontSize: fMicro,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
