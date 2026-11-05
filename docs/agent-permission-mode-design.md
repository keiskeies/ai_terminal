# Agent 执行权限模式（只读 / 询问 / 自动 / 全自动）设计

状态：已实现并验证（2026-11-04，Windows Release 真机 + 全量测试）
适用范围：`ai_terminal/lib/services/agent_engine.dart`、`lib/models/agent_state.dart`、`lib/widgets/ai_prompt_input.dart`、`lib/pages/terminal_page.dart`
关联：`docs/agent-goal-mode-metrics-bar-design.md`（`/permission` 原为只读开关别名）

---

## 1. 问题

截图中的命令 `rm -f /etc/systemd/system/virt-edid.service` 被 `SafetyGuard` 判为 `blocked`，
引擎在确认流程之前直接拒绝（`_runCommandWithSafetyInner`），UI 只能显示“已拦截”。
这条规则把“删除 /etc 下任意单个文件”和“rm -rf /”放进了同一档，导致正常的清理/卸载
操作没有可执行入口。

用户要求：参考输入框旁的四档权限选择器，允许用户主动放开高危命令，而不是永久修改
安全规则。结论是不放宽 `SafetyGuard` 的判定，只增加“用户授权档位”。

---

## 2. 四档语义（用户已确认）

| 模式 | safe | info | warn | blocked | 破坏性工具 |
|---|---|---|---|---|---|
| 只读 readOnly | 执行 | 拒绝 | 拒绝 | 拒绝 | 拒绝 |
| 询问 ask（默认） | 执行 | 执行 | 确认 | 确认 | 确认 |
| 自动 auto | 执行 | 执行 | 自动执行 | 确认 | 确认 |
| 全自动 fullAuto | 执行 | 执行 | 自动执行 | 自动执行 | 自动执行 |

- `blocked` 在询问/自动下进入与 `warn` 相同的确认通道（内联“确认执行 / 取消”），
  超时仍为 10 分钟自动拒绝。
- 全自动是唯一跳过确认的档位，切换时弹一次警告；不提供“记住全自动”的默认。
- **不改变**：封网期（`ChangeWindowService`）、路径安全（`SafetyGuard.checkPath`）、
  敏感文件读取限制。权限模式只决定“命令/工具是否执行、是否先问用户”。
- 手动点击命令卡片上的播放按钮（`_executeLineDirectly`）仍是用户主动操作，不读权限模式；
  `blocked` 命令卡片不提供播放按钮。

## 3. 状态与归属

- 新增 `AgentPermissionMode` 枚举（`lib/models/agent_permission_mode.dart`）。
- `AgentState.isReadOnlyMode` 布尔字段改为 `permissionMode`（不再保留双份真相）。
- 模式按 **scope（标签页/会话）** 保存，与现有只读开关一致：
  - 新建会话（`/new`）重置为 `ask`；
  - 应用重启后 `_restoreFromPersistence` 默认 `ask`；
  - 同一标签页内切换会话保留当前模式；
  - 运行中允许切换，下一次命令检查立即生效（与 `setReadOnlyMode` 现状一致）。
- `/plan` 进入前记录完整模式（不是布尔），结束后只在用户没有手动改过时还原原模式。
  例如原本是“自动”，跑完 `/plan` 仍回到“自动”，而不是“询问”。

## 4. 引擎门控

新增纯函数（`lib/core/permission_policy.dart`），引擎和 UI 事件元数据共用：

```dart
enum CommandGateDecision { execute, confirm, reject }
CommandGateDecision decideCommand(SafetyLevel level, AgentPermissionMode mode);
bool destructiveToolNeedsConfirm(AgentPermissionMode mode);
```

`_runCommandWithSafetyInner`：

1. 审计日志（执行前）保持不变。
2. 封网期检查保持不变。
3. `decideCommand`：
   - `reject` → 原只读分支的拒绝行为，返回 `read_only_blocked` 观测；
   - `confirm` → 复用 warn 的 `_pendingConfirmCommand` / `_confirmCompleter` / 10 分钟超时；
     文案区分“高风险命令需要确认（当前模式：询问/自动）”；
   - `execute` → 进入执行。
4. `blocked` 的审计记录仍是 `safetyLevel=blocked, executed=false/true`，不因放行而丢失等级。

`_handleToolAction`：

- `tool.kind == destructive` 且 `destructiveToolNeedsConfirm(mode)` → 现有确认；
- 全自动下跳过确认，直接执行。

System prompt 增加【执行权限】段，明确当前档位下哪些命令会等待确认、哪些会直接执行，
避免模型在只读模式下反复重试或在全自动模式下仍声称“等待用户确认”。

## 5. UI

- `AIPromptInput` 底部工具行左侧新增权限胶囊：盾牌图标 + 当前档位 + 展开箭头，
  点开向上弹出四行菜单（标题 + 一行说明 + 当前项勾选）。窄屏只显示图标，避免挤压模型胶囊。
- 颜色：只读=中性灰，询问=品牌青，自动=警告橙，全自动=错误红；不整块铺色，
  使用 `alpha 0.10` 背景 + 边框，符合石墨青视觉规范。
- 选中全自动时先弹警告对话框，确认后才切换。
- 移除工具栏上的旧只读锁按钮，避免两个入口状态不一致；`/permission` 改为：
  - 不带参数：提示当前档位与用法；
  - `/permission 只读|询问|自动|全自动`（兼容 read/ask/auto/full）：切换档位，
    全自动同样走警告对话框。
- 命令卡片不自己重新猜安全等级：使用 command 事件里的快照字段
  `permissionDecision`（`execute`/`confirm`/`reject`）。这样：
  - 被拒绝 → “已拦截”；
  - 等待确认 → “需确认” + 确认/取消按钮；
  - 全自动/自动放行 → “已放行”，不会在长时间命令执行期间显示“需确认”或“已拦截”。
- 历史事件没有 `permissionDecision` 时回退到现有 `SafetyGuard.check` 行为。

## 6. 测试矩阵

纯函数测试（新增 `test/permission_mode_test.dart`）：

- 4 档 × 4 风险级 = 16 个 `decideCommand` 断言；
- 破坏性工具确认矩阵（只读/询问/自动=true，全自动=false）；
- `/permission` 参数解析（中英文、大小写、未知值）；
- `/plan` 还原规则：原模式非只读且未被用户改动才还原；原模式就是只读不重复设置；
  用户任务期间改成别的模块不覆盖。

回归更新：

- `agent_notifier_readonly_scope_test.dart`、`agent_tab_scope_test.dart` 改用
  `setPermissionModeForHost` / `permissionModeFor`；
- `agent_engine_resilience_test.dart`、`tool_contract_test.dart` 的
  `setReadOnlyMode(true)` 改为 `setPermissionMode(readOnly)`；
- `slash_command_test.dart` 的 `shouldRestoreReadOnly` 改为模式版本。

门禁：`flutter analyze`（与既有基线对比，不追零）、`flutter test` 全量。

---

## 7. 代码核对记录（实现前）

| 假设 | 结论 |
|---|---|
| blocked 无确认入口 | 真：`_runCommandWithSafetyInner` 在 warn 分支前直接返回 `safety_blocked` |
| warn 确认通道可复用 | 真：`_pendingConfirmCommand` + `_confirmCompleter`，10 分钟超时、取消路径齐全 |
| 工具只拦 destructive | 真：`_handleToolAction` 仅 `ToolKind.destructive` 挂起确认 |
| 事件已有 riskLevel/blocked 字段 | 真：`AgentEvent` 与 `_eventToJson` 已有，但 UI 未使用；新增 `permissionDecision` 并持久化 |
| `/plan` 只恢复布尔 | 真：`wasReadOnly` 只能表达两态，必须改为模式快照 |
| 模式是 scope 级 | 真：`isReadOnlyMode` 存在 `AgentState`，engine 由 `_syncOrchestratorMode` 同步 |
| 手动执行不受模式影响 | 真：`_executeLineDirectly` 不查 `SafetyGuard`；blocked 卡片不显示播放按钮，保持现状 |
| 封网期优先于权限模式 | 真：封网期检查在只读/blocked 分支之前，权限模式不绕过 |

### 已知边界

- `setPermissionModeForHost` 对“既非活跃、也未注册”的 host 仍是静默 no-op
  （继承自现有 `_updateHostState` 行为）；`/plan` 的 host 调用时必然活跃，不受影响。
- 全自动仍受封网期与路径安全限制；它不是“关闭所有安全策略”，文案不得这样承诺。
- 历史命令卡片没有新的 `permissionDecision` 字段，回退旧逻辑，不做数据回填。

---

## 8. 交付记录

实现状态（2026-11-04）：

- P0 模型与策略：`AgentPermissionMode`、`decideCommand`、`destructiveToolNeedsConfirm`、`parsePermissionMode`；`AgentState` 单一 `permissionMode` 字段。
- P1 引擎：只读拒绝、询问/自动确认、全自动放行；等待确认期间切到只读会重新校验并拒绝执行；破坏性工具仅全自动跳过确认；system prompt 按档位注入。
- P2 UI：输入框底部权限胶囊 + 向上菜单 + 全自动警告；移除工具栏旧锁按钮；`/permission [只读|询问|自动|全自动]`；`/plan` 恢复原档位；命令卡片按 `permissionDecision` 显示 已拦截 / 需确认 / 已放行 / 未执行。
- P3 测试：`permission_mode_test.dart`（16 格矩阵 + 工具确认 + 参数解析）、`permission_mode_selector_test.dart`（360px 窄屏 + 菜单回调）、`agent_command_block_permission_test.dart`（四种卡片状态）、引擎用例（询问确认、全自动直接执行、只读拒绝、等待期间切只读）。

门禁：`flutter analyze` 33 issues / 0 errors（与既有基线一致）；`flutter test` 816 passed / 23 skipped（23 个 skip 为原有环境门控 E2E）。

真机验证（Windows Release，本地终端）：

- 输入框左侧「询问」胶囊可见，菜单四档齐全、当前项带勾选；
- 选择「全自动」弹出范围警告，取消后仍为「询问」；
- `/permission 自动` 与 `/permission 询问` 均能切换，胶囊与提示条同步。

未在真机验证：让真实模型生成 blocked 命令后的确认卡片与批准执行。该路径由引擎用例（blocked → waitingConfirm → confirmDangerousCommand → 执行）和 `AgentCommandBlock` widget 用例覆盖，但没有用真实模型跑一轮，不宣称“已肉眼确认”。

运行中切换档位的边界：引擎门控立即生效；模型 system prompt 仍按任务开始时的档位构建（与联网搜索一致），下一次任务更新。已经挂起的确认会按新档位重新校验（切到只读则不执行），不会因确认框先弹出而绕过新边界。
