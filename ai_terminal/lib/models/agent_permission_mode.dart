/// Agent 执行权限档位。
///
/// 与 [SafetyGuard] 的风险等级是两层概念：风险等级描述命令本身，
/// 权限档位描述用户愿意让 Agent 自动做到什么程度。
enum AgentPermissionMode {
  /// 只执行 safe 级命令；其余全部拒绝。
  readOnly,

  /// 修改类命令（warn）与高危命令（blocked）都需要用户确认。
  ask,

  /// 修改类命令自动执行；高危命令仍需确认。
  auto,

  /// 所有命令与破坏性工具都自动执行，不再询问。
  fullAuto,
}

extension AgentPermissionModeX on AgentPermissionMode {
  /// 稳定标识，用于 `/permission` 参数与持久化/日志。
  String get id {
    switch (this) {
      case AgentPermissionMode.readOnly:
        return 'readOnly';
      case AgentPermissionMode.ask:
        return 'ask';
      case AgentPermissionMode.auto:
        return 'auto';
      case AgentPermissionMode.fullAuto:
        return 'fullAuto';
    }
  }
}

/// 解析 `/permission` 的参数。返回 null 表示无法识别。
///
/// 接受中文名、英文名与常见别名；大小写不敏感。
AgentPermissionMode? parsePermissionMode(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  switch (value) {
    case '只读':
    case 'read':
    case 'readonly':
    case 'read-only':
      return AgentPermissionMode.readOnly;
    case '询问':
    case 'ask':
      return AgentPermissionMode.ask;
    case '自动':
    case 'auto':
      return AgentPermissionMode.auto;
    case '全自动':
    case 'full':
    case 'fullauto':
    case 'full-auto':
      return AgentPermissionMode.fullAuto;
    default:
      return null;
  }
}
