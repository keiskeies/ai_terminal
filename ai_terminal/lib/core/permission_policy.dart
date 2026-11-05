import '../models/agent_permission_mode.dart';
import 'safety_guard.dart';

/// 引擎对一条命令的最终处置。
enum CommandGateDecision {
  execute,
  confirm,
  reject,
}

/// 写入 `AgentEvent.permissionDecision` 的稳定字符串。
///
/// 事件会落盘并在历史里回放，不能用随枚举改名的裸值。
const String kPermissionDecisionExecute = 'execute';
const String kPermissionDecisionConfirm = 'confirm';
const String kPermissionDecisionReject = 'reject';

/// 按当前权限档位决定一条命令该怎么处理。
///
/// 这是引擎门控与 UI 事件快照共用的唯一实现，避免两边各写一份矩阵后漂移。
CommandGateDecision decideCommand(
  SafetyLevel level,
  AgentPermissionMode mode,
) {
  if (mode == AgentPermissionMode.readOnly) {
    return level == SafetyLevel.safe
        ? CommandGateDecision.execute
        : CommandGateDecision.reject;
  }
  if (level == SafetyLevel.blocked) {
    return mode == AgentPermissionMode.fullAuto
        ? CommandGateDecision.execute
        : CommandGateDecision.confirm;
  }
  if (level == SafetyLevel.warn) {
    return mode == AgentPermissionMode.ask
        ? CommandGateDecision.confirm
        : CommandGateDecision.execute;
  }
  return CommandGateDecision.execute;
}

/// 破坏性工具（local_file_delete 等）是否需要用户确认。
///
/// 只读模式下工具在更早的“工具自身是否只读”门控就被拒绝，
/// 这里只区分“全自动放行”与“其余档位先问”。
bool destructiveToolNeedsConfirm(AgentPermissionMode mode) =>
    mode != AgentPermissionMode.fullAuto;
