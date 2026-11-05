import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/safety_guard.dart';
import '../core/permission_policy.dart';
import '../providers/terminal_provider.dart' as tp;
import '../utils/agent_ui_text.dart';
import '../utils/risk_explainer.dart';
import '../core/app_toast.dart';

/// 统一命令块：左侧 3px 安全色条 + 命令文本 + 顶部状态标签与操作
///
/// 由 `_TerminalPageState._buildCommandBlock` 系列方法提取而来，包含：
/// 复制按钮、执行按钮、危险命令内联确认按钮。
class AgentCommandBlock extends StatelessWidget {
  final String command;
  final ThemeColors tc;
  final tp.TerminalTab? tab;
  final bool showAutoExecute;
  final bool isLoading;

  /// 当前正在执行的命令（用于显示加载态 / 禁用其它按钮）
  final String? executingCommand;

  /// 当前等待内联确认的危险命令（与 [command] 相等时显示确认/取消按钮）
  final String? pendingConfirmCommand;

  /// 是否为工具调用（非 shell 命令）：不显示执行按钮，避免把工具参数当命令执行
  final bool isTool;

  /// 是否已有执行结果：用于区分"执行前确认"和"历史变更影响"
  final bool executed;

  /// 命令发出时的风险等级快照（safe/info/warn/blocked）
  final String? riskLevel;

  /// 命令发出时的权限处置快照（execute/confirm/reject）
  final String? permissionDecision;

  /// 执行命令回调（点击执行按钮时触发）
  final void Function(String command, bool dangerous, tp.TerminalTab tab)?
      onExecute;

  /// 确认执行危险命令回调（点击「确认执行」时触发，由调用方解析当前活动 tab）
  final void Function(String command)? onConfirm;

  /// 拒绝/取消执行危险命令回调（点击「取消」时触发）
  final VoidCallback? onReject;

  const AgentCommandBlock({
    super.key,
    required this.command,
    required this.tc,
    this.tab,
    this.showAutoExecute = false,
    this.isLoading = false,
    this.executingCommand,
    this.pendingConfirmCommand,
    this.isTool = false,
    this.executed = false,
    this.riskLevel,
    this.permissionDecision,
    this.onExecute,
    this.onConfirm,
    this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return _buildCommandBlock(context);
  }

  /// 统一命令块：左侧 3px 安全色条 + 命令文本 + 顶部状态标签与操作
  Widget _buildCommandBlock(BuildContext context) {
    final ui = AgentUiText.of(context);
    final trimmed = command.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    // 用局部变量保证 tab 的空提升
    final tab = this.tab;
    final canExecute = tab != null &&
        tab.isConnected &&
        showAutoExecute &&
        !isTool &&
        !executed;
    // 优先使用事件里的快照：命令发出时的等级与处置，不能在渲染时按当前
    // 权限档位重算，否则切换档位会让历史命令改口。
    final safetyLevel = riskLevel == null
        ? SafetyGuard.check(trimmed)
        : SafetyLevel.values.firstWhere(
            (level) => level.name == riskLevel,
            orElse: () => SafetyGuard.check(trimmed),
          );
    final decision = permissionDecision;
    final isWaitingConfirm = !executed && pendingConfirmCommand == trimmed;
    final levelDangerous = !isTool &&
        (safetyLevel == SafetyLevel.warn ||
            safetyLevel == SafetyLevel.blocked);
    final dangerous = isTool ? isWaitingConfirm : levelDangerous;
    // 旧事件没有 permissionDecision：blocked 仍按硬拦截展示
    final hardBlocked = !isTool &&
        !executed &&
        !isWaitingConfirm &&
        (decision == kPermissionDecisionReject ||
            (decision == null && safetyLevel == SafetyLevel.blocked));
    final notExecuted = !isTool &&
        !executed &&
        decision == kPermissionDecisionConfirm &&
        !isWaitingConfirm;
    final allowed = !isTool &&
        !executed &&
        decision == kPermissionDecisionExecute &&
        levelDangerous;
    final requiresConfirm = isTool
        ? isWaitingConfirm
        : (decision == kPermissionDecisionConfirm ||
            (decision == null && levelDangerous));
    // 手动执行按钮只给非 blocked 级命令；等待确认的 blocked 命令不能绕开引擎确认
    final blockedLevel = !isTool && safetyLevel == SafetyLevel.blocked;

    final cmdColor = hardBlocked
        ? tc.error
        : dangerous
            ? tc.warn
            : isTool
                ? tc.textBody
                : tc.textMain;

    final accentColor = hardBlocked
        ? tc.error
        : (dangerous || notExecuted || allowed)
            ? tc.warn
            : isTool
                ? tc.brand
                : tc.ok;
    final headerBg = hardBlocked
        ? tc.error.withValues(alpha: 0.08)
        : (dangerous || notExecuted || allowed)
            ? tc.warn.withValues(alpha: 0.08)
            : isTool
                ? tc.brand.withValues(alpha: 0.06)
                : tc.ok.withValues(alpha: 0.08);

    final label = isTool
        ? ui.toolCall
        : hardBlocked
            ? ui.blocked
            : isWaitingConfirm
                ? ui.needsConfirm
                : notExecuted
                    ? ui.permissionNotExecuted
                    : allowed
                        ? ui.permissionAllowed
                        : executed
                            ? ui.executedLabel
                            : dangerous
                                ? ui.needsConfirm
                                : ui.executable;

    final block = Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: tc.terminalOutput,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.border, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧色条
          Container(
            width: 3,
            color: accentColor,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部栏
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: headerBg,
                    border: Border(
                        bottom: BorderSide(color: tc.border, width: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Icon(
                          isTool
                              ? Icons.build
                              : hardBlocked
                                  ? Icons.block
                                  : (dangerous || notExecuted || allowed)
                                      ? Icons.warning_amber
                                      : Icons.check,
                          size: 9,
                          color: accentColor,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: fMicro,
                          color: accentColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      // 复制按钮
                      _buildCopyButton(trimmed, tc, context),
                      const SizedBox(width: 4),
                      // 执行按钮（工具调用与已执行过的命令不给执行入口）
                      //
                      // 确认按钮不放在这里：见 _buildRiskPanel —— 它必须和影响
                      // 说明同屏，否则面板滚到底看到"删除本机文件…"时，批准
                      // 按钮还在卡片头部上方，用户得先往上滚才能点。
                      if (canExecute && !isLoading && !blockedLevel)
                        _buildExecuteButton(
                            trimmed, dangerous, blockedLevel, tc, tab)
                      else if (hardBlocked)
                        Container(
                          width: 26,
                          height: 26,
                          alignment: Alignment.center,
                          child: Icon(Icons.block, size: 13, color: tc.error),
                        ),
                    ],
                  ),
                ),
                // 命令内容
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // $ 提示符 / 工具调用前缀
                      Text(
                        isTool ? '› ' : '\$ ',
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                          fontSize: fMono,
                          color: accentColor,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                      // 命令文本（选区由 Agent 列表外层 SelectionArea 统一管理）
                      Expanded(
                        child: Text(
                          trimmed,
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                            fontSize: fMono,
                            color: cmdColor,
                            height: 1.45,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 变更类命令的影响说明（远程场景下比命令本身更重要）
                if (dangerous || RiskExplainer.isMutating(trimmed))
                  _buildRiskPanel(tc, ui, hardBlocked, trimmed,
                      requiresConfirm: requiresConfirm),
              ],
            ),
          ),
        ],
      ),
    );

    return block;
  }

  Widget _buildRiskPanel(
    ThemeColors tc,
    AgentUiText ui,
    bool isBlocked,
    String command, {
    required bool requiresConfirm,
  }) {
    // 工具展示串（`local_file_delete\n  path: x`）不是 shell 命令，交给 explain
    // 会按 shell 语义猜类型并说成"修改服务器状态"——本机工具改的是这台机器。
    final explanation = isTool
        ? RiskExplainer.explainTool(command.split('\n').first.trim())
        : RiskExplainer.explain(command);
    // 批准入口跟着影响说明走：两者必须在同一屏，用户是看着这段话按批准的
    final isWaitingConfirm = !executed && pendingConfirmCommand == command;
    final color = isBlocked ? tc.error : tc.warn;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(rXSmall),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isBlocked ? Icons.block : Icons.warning_amber,
                  size: 13, color: color),
              const SizedBox(width: 5),
              Text(
                isBlocked
                    ? ui.riskBlocked
                    : executed
                        ? ui.changeImpact
                        : isWaitingConfirm
                            ? ui.confirmImpact
                            : ui.changeImpact,
                style: TextStyle(
                  color: color,
                  fontSize: fMicro,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            explanation.impact,
            style: TextStyle(
              color: tc.textBody,
              fontSize: fMicro,
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (explanation.reason != null &&
              explanation.reason!.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              ui.riskPrefix(explanation.reason!),
              style: TextStyle(color: tc.textSub, fontSize: fMicro),
            ),
          ],
          const SizedBox(height: 2),
          Text(
            explanation.restoreHint ??
                (explanation.canRollback
                    ? ui.rollbackPrefix(explanation.rollbackCommand ?? '')
                    : ui.noRollbackSnapshot),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color:
                  explanation.canRollback || explanation.restoreHint != null
                      ? tc.textSub
                      : color,
              fontSize: fMicro,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (requiresConfirm && isWaitingConfirm) ...[
            const SizedBox(height: 7),
            _buildInlineConfirmButtons(command, tc, ui),
          ],
        ],
      ),
    );
  }

  /// 复制按钮
  Widget _buildCopyButton(String text, ThemeColors tc, BuildContext context) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: text));
        clearTopToast();
        showTopSnackBar(context, 
          const SnackBar(
            content: Text('已复制', style: TextStyle(fontSize: fSmall)),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.all(16),
          ),
        );
      },
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        child: Icon(Icons.copy, size: 13, color: tc.textSub),
      ),
    );
  }

  /// 命令执行按钮（带背景色的三角形按钮）
  Widget _buildExecuteButton(
      String command, bool dangerous, bool isBlocked, ThemeColors tc, tp.TerminalTab tab) {
    final isExecuting = executingCommand == command;
    final hasAnyExecuting = executingCommand != null;
    final isDisabled = isBlocked || (hasAnyExecuting && !isExecuting);

    final color = isBlocked
        ? tc.error
        : dangerous
            ? tc.warn
            : tc.brand;

    return GestureDetector(
      onTap: isDisabled ? null : () => onExecute?.call(command, dangerous, tab),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isDisabled ? Colors.transparent : color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(rSmall),
          border: isDisabled ? null : Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: isExecuting
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
              )
            : isBlocked
                ? Icon(Icons.block, size: 14, color: tc.error)
                : Icon(Icons.play_arrow, size: 18, color: color),
      ),
    );
  }

  /// 危险命令内联确认/取消按钮（替代弹窗）
  Widget _buildInlineConfirmButtons(
      String command, ThemeColors tc, AgentUiText ui) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 取消按钮
        GestureDetector(
          onTap: onReject,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tc.surface,
              borderRadius: BorderRadius.circular(rSmall),
              border: Border.all(color: tc.border),
            ),
            child: Text(ui.cancel,
                style: TextStyle(
                    fontSize: fSmall,
                    color: tc.textSub,
                    fontWeight: FontWeight.w500)),
          ),
        ),
        const SizedBox(width: 4),
        // 确认执行按钮
        GestureDetector(
          onTap: () => onConfirm?.call(command),
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tc.warn.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(rSmall),
              border: Border.all(color: tc.warn.withValues(alpha: 0.4)),
            ),
            child: Text(ui.confirmExecute,
                style: TextStyle(
                    fontSize: fSmall,
                    color: tc.warn,
                    fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }
}

/// 带执行按钮的代码块 — 每条命令独立成块，复用统一命令块样式
Widget buildCodeBlockWithExecuteButton(
  String codeBlock,
  ThemeColors tc,
  tp.TerminalTab? tab,
  bool showAutoExecute,
  bool isLoading, {
  String? executingCommand,
  String? pendingConfirmCommand,
  void Function(String command, bool dangerous, tp.TerminalTab tab)? onExecute,
  void Function(String command)? onConfirm,
  VoidCallback? onReject,
}) {
  final lines = codeBlock.trimRight().split('\n');
  final children = <Widget>[];

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    children.add(AgentCommandBlock(
      command: trimmed,
      tc: tc,
      tab: tab,
      showAutoExecute: showAutoExecute,
      isLoading: isLoading,
      executingCommand: executingCommand,
      pendingConfirmCommand: pendingConfirmCommand,
      onExecute: onExecute,
      onConfirm: onConfirm,
      onReject: onReject,
    ));
  }

  if (children.isEmpty) return const SizedBox.shrink();

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
}

/// 纯代码块（非 shell）
Widget buildPlainCodeBlock(String codeBlock, ThemeColors tc) {
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 4),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: tc.terminalBg,
      borderRadius: BorderRadius.circular(rSmall),
      border: Border.all(color: tc.border),
    ),
    child: Text(
      codeBlock.trimRight(),
      style: TextStyle(
        fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
        fontSize: fMono,
        color: tc.textSub,
        height: 1.4,
      ),
    ),
  );
}
