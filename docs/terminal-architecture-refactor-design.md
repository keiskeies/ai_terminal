# 终端与 Agent 架构治理设计文档

- 状态：Phase A 已实施并通过全量回归（Phase B/C 待排期）
- 日期：2026-11-20
- 基线提交：`5e3540e`（热点路径算法与内存优化已合入，本轮不重复）
- 范围：`ai_terminal/lib` 下终端连接、重连、状态管理与设置写入链路
- 关联规则：`AGENTS.md` R1（异步竞态）、R2（异步资源回收）、R3（多主机/多 tab 隔离）、R4（事件哈希）、R5（终态一致）

---

## 0. 执行摘要

上一轮算法优化解决了"跑得快"的问题；本轮解决"活得久、不出错"的问题。架构评审发现 **11 个真实问题**，其中 4 个会造成实际故障或资源泄漏：

| 编号 | 问题 | 级别 | 实际后果 | 本轮 |
|---|---|---|---|---|
| A1 | SSH 连接池空闲清理恒不触发 + `outputController` 不关闭 | P0 | 长会话累积 StreamController；5 分钟定时器完全无效 | ✅ |
| A2 | 自动重连定时器住在 Widget State | P0 | 导航到设置页后掉线不自愈，用户以为"自动重连坏了" | ✅ |
| A3 | `pause/resume` 与 `cancel` 取的引擎不一致 | P1 | 多 tab 快速切换后可能暂停到别的 tab 的任务（R3） | ✅ |
| A4 | 设置项写库两次 | P1 | 双写 IO，且滋生"只写库不通知"的补丁逻辑 | ✅ |
| B1 | 三重状态源（Riverpod state / registry / engine 内部） | P0 | R3 串台的结构性温床 | 方案已给，本轮不动 |
| B2 | 三个上帝文件（7780/5706/2215 行） | P0 | 改动扩散、清理遗漏 | 方案已给，本轮不动 |
| B3 | `TerminalTab` 可变对象直接入 state | P1 | `select` 到具体 tab 的消费者不会重建 | 方案已给，本轮不动 |
| C1 | 60 处空 catch | P2 | 故障静默，无从排查 | 部分 |
| C2 | `core/db_init.dart ↔ services/daos.dart` 循环依赖 | P2 | 分层 inversion | 本轮不动 |
| C3 | 77 处 `ForTesting` 后门 / 硬编码依赖 | P2 | 可测试性差 | 本轮按需新增测试钩子 |
| C4 | `agent_tool.dart` 2992 行 | — | **判定为可接受**：20 个工具类各有单一职责 + Registry | 不动 |

**实施原则**：先修会泄漏和会串台的（A1–A4），再统一状态源（B1），最后才允许拆上帝文件（B2）。顺序反了只会把混乱复制到新模块。

---

## 1. 背景与目标

### 1.1 背景

这是一个跨平台终端 App：AI assistant 通过 SSH / 本地 PTY 生成并执行 shell 命令。技术栈 Riverpod 2.4 + GoRouter + SQLite(sqflite) + dartssh2 + xterm.dart。

架构评审采用"证据优先"：每个结论必须有精确文件/行号与代码结构支撑，不把可接受的设计权衡当成问题。上一轮已确认 `react_stream_parser` FNV-1a 哈希、`streaming_markdown` 增量解析、`line_diff` 滚动数组 LCS、`ssh_connection_pool` 的 Map 用法都是正确设计，不重复动。

### 1.2 本轮目标

1. **消除资源泄漏**：连接池中每个 `SSHService` 的生命周期有且仅有一个终点。
2. **恢复后台自愈**：断线重连不依赖页面是否可见。
3. **收紧 R3 隔离**：所有"针对某个 tab 的操作"必须从 registry 按 scope 取引擎，禁止用缓存字段兜底。
4. **收敛写入口**：设置项只有一个写库入口。
5. **留下可执行的设计**：B/C 类问题给出足够详细的方案与迁移路径，后续可直接排期，不需要重新评审。

### 1.3 非目标（本轮明确不做）

- 不拆 `terminal_page.dart` / `agent_engine.dart` / `agent_provider.dart`（风险与工作量远超本轮）。
- 不改会话持久化结构（messages 单列 JSON 拆表属于架构改造，且已有写入合并 + isolate 缓解）。
- 不改 DAO 的 `cached` live List 语义（改 Map 破坏 API 且 `.values.toList()` 更慢）。
- 不重写 60 处空 catch（逐处判断"静默是否合理"需要业务上下文，按模块分批做）。

### 1.4 验收标准

- `flutter analyze`：**0 error**，且改动文件 0 新增告警（基线 81 条既有 info/warning）。
- `flutter test`：全部既有测试通过；新增连接池与重连调度单测通过。
- 手工：SSH tab 关闭 → 5 分钟后进程/流对象不累积；断线切换页面 → 自动重连仍发生；多 tab 切换 → 暂停/恢复作用于当前 tab。

---

## 2. 架构现状

### 2.1 分层

```
pages/             TerminalPage(7780行)  HostListPage  AgentSettingsPage
widgets/           TerminalView  TerminalAppearancePanel  Agent*Cards ...
providers/         AgentProvider(2215)  TerminalProvider(458)  AppProviders
services/          AgentEngine(5706)  AgentTool(2992, 20 个工具类 + Registry)
                   SSHService(1163)  SSHConnectionPool(194)  LocalFileTools ...
core/              DbInit  CredentialsStore  L10nHolder
                        ▲                        │
                        └──── 循环依赖 ──────────┘ (C2)
```

### 2.2 关键链路

**建连**：`TerminalPage._connectToHost` → `TerminalNotifier.connectTab` → `_openSsh` → `SSHConnectionPool.acquire(tabId, config)` → `SSHService.connect`。池 key 是 **tabId 而非 hostId**（`:276` 注释：允许同一服务器多个连接）。

**掉线**：`SSHService._handleDrop` → `onDisconnected` → `TerminalNotifier._openSsh` 注册的回调（`:294`）标记 tab `lost` → `_publish()` → `TerminalPage._maybeAutoReconnect` 用 Widget 内的 Timer 退避重连。

**重连**：`TerminalPage._reconnectTab` → `terminalProvider.notifier.reconnect(tabId, host)` → `forceDisconnect` + `_openSsh` → 回到页面侧 `setExecutor` / `_ensureTabTerminal` / tracker reset。

**设置写入**：`TerminalAppearancePanel.save` → `SettingsDao.set` **+** `settingsProvider.notifier.setSetting`（内部再次 `SettingsDao.set`）→ `ref.listen` 把值拉回 TerminalPage 本地字号状态。

### 2.3 量化基线

| 指标 | 数值 | 来源 |
|---|---|---|
| `terminal_page.dart` | 7780 行 / 195 方法 / 88 import | `wc -l` + grep |
| `agent_engine.dart` | 5706 行 / 97 方法 / 40+ 可变字段 / 6 Completer | 同上 |
| `agent_provider.dart` | 2215 行 / 三重状态源 | 同上 |
| 空 catch | 60 处（sftp 11、local_pty 10、terminal_page 7…） | grep 统计 |
| ForTesting 后门 | 77 处 | grep 统计 |
| 既有 analyze 告警 | 81 条 info/warning，**0 error** | `flutter analyze` |

---

## 3. 问题详单

每个问题按 **症状 → 原因 → 证据 → 影响 → 解决方案 → 备选方案 → 风险 → 验证** 展开。行号均为基线提交行号。

---

### A1 — SSH 连接池空闲清理是死代码，且连接对象只断开不释放

**级别**：P0 ｜ **文件**：`lib/services/ssh_connection_pool.dart`、`lib/services/ssh_service.dart`、`lib/main.dart`

#### 症状

- App 启动 10 分钟后 `SSHConnectionPool.startIdleCleanup(Duration(minutes: 10))` 跑过若干轮，池内连接数**从不减少**。
- 长时间多 tab 使用后，进程内遗留大量已断开但未关闭的 `StreamController<String>`（每个 `SSHService` 一个），内存缓慢爬升。
- 重连时旧 service 的输出流仍然"活着"，只是没人监听。

#### 原因

两层独立缺陷叠加：

1. **清理条件永假**：`_PoolEntry.refCount` 初始为 `1`（`:8`），`release()` 减到 `≤0` 时立即 `_pool.remove(hostId)`（`:110-114`）。因此池内存活的条目 `refCount` 恒 ≥ 1，`_cleanup()` 的 `if (entry.refCount == 0 && ...)`（`:163`）永远不成立。
2. **释放调用链缺一环**：`release()` / `forceDisconnect()` / `_cleanup()` / `dispose()` 全部只调 `service.disconnect()`，只有 `acquire()` 发现连接已断时（`entry.service.dispose()`，`:43`）和 `_doAcquire()` 异常路径（`:95`）调用 `dispose()`。而 `SSHService.dispose()`（`:1159-1162`）才执行 `outputController.close()`。

#### 证据

```dart
// ssh_connection_pool.dart:6-15
class _PoolEntry {
  final SSHService service;
  int refCount = 1;              // ← 初始即 1
  ...
}

// ssh_connection_pool.dart:109-114
final entry = _pool[hostId]!;
entry.refCount--;
if (entry.refCount <= 0) {
  _pool.remove(hostId);          // ← 归零条目立刻离开池
  () async { await entry.service.disconnect(); }();   // ← 只 disconnect
}

// ssh_connection_pool.dart:162-167
_pool.forEach((hostId, entry) {
  if (entry.refCount == 0 && ... > timeout) {  // ← 永假
    entry.service.disconnect();               // ← 且 fire-and-forget
    toRemove.add(hostId);
  }
});

// ssh_service.dart:1158-1162
void dispose() {
  disconnect();
  outputController.close();      // ← 只有这里关闭流
}
```

#### 影响

- **功能**：空闲回收完全失效。但鉴于池 key 是 tabId，关闭 tab 后该 key 不会被再次 acquire，"空闲连接复用"本就不是主要收益 —— 真正的问题是泄漏。
- **资源**：每个被 `forceDisconnect`（重连）或 `release`（关 tab）的 `SSHService` 都遗留一个未关闭的 broadcast StreamController。dartssh2 的 session/socket 已关闭，但 Dart 对象与流资源常驻。
- **并发**：`_cleanup()` 的 `disconnect()` 未 await，回收后可能仍有回调写入已移除条目。

#### 解决方案

采用 **"引用计数归零即释放"** 语义（与池 key=tabId 的现实一致），保留 idle cleanup 作为孤儿条目兜底：

1. `release()`：归零时 `_pool.remove` 后调用 `entry.service.dispose()`，去掉无意义的 fire-and-forget async 闭包（`disconnect()` 内部全为同步操作，签名 `async` 只是历史原因）。
2. `forceDisconnect()` / `dispose()`：同样改调 `service.dispose()`。
3. `_cleanup()`：判定改为 `entry.refCount <= 1 && now.difference(entry.lastActive) > timeout`。含义：**仅有创建者持有、且超过 idle 阈值未再被 acquire** 的条目才回收；有并发借用者（`>1`）时不动。改为同步 `dispose()`。
4. `SSHService` 增加幂等保护：
   - 新增 `bool _disposed = false`；
   - `dispose()` 首行 `if (_disposed) return; _disposed = true;`；
   - `disconnect()` 写输出前检查 `!outputController.isClosed`，避免重复断开向已关闭流 add 触发 `StateError`。
5. 可测试性：新增 `@visibleForTesting static SSHService Function(HostConfig)? serviceFactoryForTesting`，`_doAcquire` 优先使用它，测试注入 fake service（沿用项目 77 处 ForTesting 风格）。

#### 备选方案

- **方案 B（真正的空闲连接池）**：归零不释放，保留条目由 idle cleanup 超时回收。被否决：池 key 是 tabId，重连会新建 key，空闲条目不会被复用，只会把泄漏延后到超时。
- **方案 C**：直接删掉 `startIdleCleanup` 和 `_cleanup`。被否决：失去对异常路径残留条目的兜底，且 `main.dart` 调用点要一起改，收益不比保留大。

#### 风险与缓解

| 风险 | 缓解 |
|---|---|
| `dispose()` 关闭 outputController 后订阅者收到 done | `TerminalNotifier.reconnect` 已先 `cancelOutputSubscription()`；关 tab 路径 `tab.dispose()` 也关闭自己的 controller。二者顺序为先取消订阅再 dispose。 |
| 重复 dispose 抛错 | `SSHService._disposed` 幂等标志 + 写流前 `isClosed` 检查。 |
| 改判定后误回收活跃连接 | `refCount > 1` 不回收；`lastActive` 每次 acquire 命中都刷新。 |

#### 验证

- 新增 `test/ssh_connection_pool_test.dart`：acquire×2 → refCount=2；release×1 仍在池；release×2 移除并 dispose；forceDisconnect 后池空且 service disposed；idle cleanup 只回收过期且 refCount≤1 的条目；重复 dispose 不抛错。
- 手工：连续开关 SSH tab 10 次，观察 `stats['totalConnections']` 归零；用 Observatory 确认 `StreamController` 数量不累积。

---

### A2 — 自动重连定时器绑在 Widget State 上，页面销毁即失去自愈

**级别**：P0 ｜ **文件**：`lib/pages/terminal_page.dart`、`lib/providers/terminal_provider.dart`

#### 症状

用户打开 SSH tab → 切到设置页/主机列表页（TerminalPage 被 pop 或替换）→ 网络抖动掉线 → 右上角重连角标出现但**永远不会自动重连**；返回终端页才重新开始退避。

#### 原因

自动重连的两个状态 `_autoReconnectAttempts` / `_autoReconnectTimers`（`:209-210`）和调度函数 `_maybeAutoReconnect`（`:1537-1558`）都在 `TerminalPage` 的 State 中。定时器回调第一行就是 `if (!mounted) return`（`:1546`），页面销毁时 `dispose()` 还会主动 `cancel()` 全部定时器（`:1739-1743`）。这是**把后台生命周期职责放在了前台组件里**。

#### 证据

```dart
// terminal_page.dart:1537-1557
void _maybeAutoReconnect(tp.TerminalTab tab) {
  if (tab.isLocal || tab.status != tp.TabStatus.lost) return;
  if (ref.read(agentProvider.notifier).isRunningFor(tab.id)) return;
  ...
  _autoReconnectTimers[tab.id] = Timer(..., () {
    if (!mounted) return;                    // ← 页面不在，直接放弃
    final current = ref.read(tp.terminalProvider)...;
    if (current == null || current.status != tp.TabStatus.lost) return;
    if (ref.read(agentProvider.notifier).isRunningFor(tab.id)) return;
    _autoReconnectAttempts[tab.id] = attempts + 1;
    _reconnectTab(current);
  });
}

// terminal_page.dart:1739-1743  dispose 中主动清理
for (final timer in _autoReconnectTimers.values) { timer.cancel(); }
```

#### 影响

- 用户可感知的功能失效；重连策略 `ReconnectPolicy`（1s/2s/4s ×3）形同虚设。
- 页面销毁时若任务正在运行，`isRunningFor` 检查也一并消失。

#### 解决方案

**把"调度权"下沉到 `TerminalNotifier`，把"UI 副作用"留成事件订阅。**

1. `TerminalNotifier` 构造函数接收 `Ref`（`terminalProvider` 用 `ref.keepAlive()` 保持存活，否则无人监听时 provider 会被 Riverpod 回收，定时器随之消失）。
2. `TerminalNotifier` 新增：
   - `Map<String, int> _reconnectAttempts` / `Map<String, Timer> _reconnectTimers`；
   - `void scheduleAutoReconnect(String tabId)`：校验 `status == lost`、`!isLocal`、`!agentProvider.notifier.isRunningFor(tabId)`、`ReconnectPolicy.shouldRetry`，设置 `Timer`；到点后**重新校验**（用户可能已手动重连/关闭 tab/启动任务），再调用现有 `reconnect()`；
   - `void cancelAutoReconnect(String tabId)`：手动重连、关闭 tab 时调用；
   - `StreamController<String> reconnectedTabIds`（broadcast）：provider 发起的重连成功后 emit tabId，供 UI 做副作用；
   - 在 `_openSsh` 的 `onDisconnected` 回调（`:294`）里，标记 lost 后调用 `scheduleAutoReconnect(tab.id)`；
   - `reconnect()` / `reconnectLocal()` 成功后统一走 `_finishReconnect`：清退避、**在 notifier 内重绑 executor**（页面不在时 AI 也不会拿旧 executor）、emit `reconnectedTabIds`；
   - 自动重连失败时保留已用次数，继续下一档退避（最多 3 次）；手动重连/关 tab 才清零；
   - `closeTab()` 取消定时器；`dispose()` 清理全部定时器与 StreamController。
3. `TerminalPage`：
   - 删除 `_autoReconnectTimers` / `_autoReconnectAttempts` / `_maybeAutoReconnect` / dispose 清理；
   - `_reconnectTab` 中的 UI 副作用抽出 `_onReconnected(TerminalTab tab)`：`setExecutor` → `_ensureTabTerminal` → tracker reset → `_scheduleSizeSync`；
   - 手动重连成功后直接调 `_onReconnected`；同时订阅 `reconnectedTabIds`，对 provider 发起的自动重连执行同一函数（用 tabId 查当前 tab，`mounted` 时执行；页面不在时跳过 UI 副作用但业务重连已完成）。

#### 备选方案

- **方案 B（独立 ReconnectService）**：职责更干净，但要处理 service 如何拿到 tab 列表、host 配置和 agent 运行状态，等于把 `TerminalNotifier` 的一半搬过去。否决：本轮最小改动优先。
- **方案 C（只把 Timer 换成 `Timer.run` + 页面重建时补调度）**：无法覆盖页面长期不存在的场景。否决。

#### 风险与缓解

| 风险 | 缓解 |
|---|---|
| `Ref` 依赖造成 provider 环 | 已核查 `agent_provider.dart` 不 import `terminal_provider.dart`，方向单一；`terminal_provider` → `agent_provider` 单向安全 |
| `ref.keepAlive()` 导致 provider 永不释放 | provider 的 `dispose()` 清理全部 timer/controller；App 退出时容器销毁 |
| 自动重连成功但 UI 未重绑 executor | `reconnectedTabIds` 事件 + 页面重建时 `build` 中已有 executor 绑定逻辑兜底；单测覆盖事件 emit |
| 退避计数跨页面残留 | 连接成功/手动重连/关 tab 三处清零 |

#### 验证

- 新增 `test/terminal_reconnect_scheduling_test.dart`（用 fake timer 或短延迟）：掉线后按 1s/2s/4s 调度；任务运行中跳过；用户手动重连后取消；重连成功清零计数；页面销毁（无监听者）后仍执行重连。
- 手工：SSH tab 掉线后立即切到设置页，等待 10s，返回终端页应已重连。

---

### A3 — `pause/resume` 用缓存引擎，`cancel` 用 registry 引擎

**级别**：P1 ｜ **文件**：`lib/providers/agent_provider.dart`

#### 症状

多 tab 快速切换时，对 A tab 点"暂停"但实际暂停了 B tab 的任务；或点"恢复"没反应。偶发、难复现。

#### 原因

代码自己承认 `_engine` 是滞后缓存（`:1441` 注释："`_engine` 只是缓存，切 tab/重建模型后可能滞后"）。但只有 `cancel()`（`:1440-1445`）和补充指令路径（`:1281`、`:1445`）按 registry 取引擎，`pause()` / `resume()` 仍直接用 `_engine`。同一份状态两套取法，正是 R3 隔离事故的结构性温床。

#### 证据

```dart
// :1440-1445  cancel —— 正确示范
void cancel() {
  final scopeId = _registry.activeScopeId ?? _engineScopeId;
  final engine = scopeId == null ? _engine : (_registry.getEngine(scopeId) ?? _engine);
  ...
}

// :1493-1506  pause / resume —— 滞后缓存
void pause() {
  if (_engine == null || !_engine!.isRunning) return;
  _engine!.pauseTask();
}
Future<void> resume() async {
  final engine = _engine;
  final scopeId = _engineScopeId;
  ...
}
```

#### 影响

R3 多 tab 隔离可能被破坏；任务暂停/恢复作用于错误的 scope，表现为"按钮失灵"或"别的 tab 卡住"。

#### 解决方案

统一为 `cancel()` 的取法，并抽出私有辅助方法避免再次分叉：

```dart
({String? scopeId, AgentEngine? engine}) _activeEngine() {
  final scopeId = _registry.activeScopeId ?? _engineScopeId;
  return (scopeId: scopeId,
          engine: scopeId == null ? _engine : (_registry.getEngine(scopeId) ?? _engine));
}
```

`cancel()` / `pause()` / `resume()` 全部改用 `_activeEngine()`。`resume()` 的 executor 同时改为 `_registry.getScopeExecutor(scopeId) ?? _executor`。

补充指令路径（`:1281`）保持原有写法：它要求 `_registry.activeScopeId` 非空才允许发送，改用 `_activeEngine()` 会在空 scope 时回退 `_engineScopeId` 并放宽这一限制，属于行为变更，本轮不动。

#### 备选方案

彻底删掉 `_engine`（B1 的一部分）。否决：牵动 40+ 处引用，属于状态源统一工程，本轮先消除不一致。

#### 风险与缓解

- 若 registry 中引擎已被替换但 `_engine` 仍指向旧对象，行为改变正是期望的（按 registry 为准）；`cancel` 已是该语义，一致性提升。
- 单测需覆盖"registry 有引擎但 `_engine` 指向另一个"的场景（可通过 `AgentHostRegistry` 的 setter 构造）。

#### 验证

- 新增/扩展 `test/agent_provider_test.dart`：两个 scope 各自持有 engine，切换 scope 后 `pause()` 只影响活跃 scope。
- `flutter analyze` 无新增告警。

---

### A4 — 设置项双重写库，并滋生补偿补丁

**级别**：P1 ｜ **文件**：`lib/widgets/terminal_appearance_panel.dart`、`lib/providers/app_providers.dart`、`lib/pages/terminal_page.dart`

#### 症状

拖动终端字号滑块时产生两次 SQLite 写；`terminal_page.dart:1774-1782` 存在专门为此写的 `ref.listen` 补丁，注释直言"只写库不通知这边，滑块拖完终端不动"。

#### 原因

写入口分裂：UI 组件自己写一次库，再调 notifier，notifier 内部又写一次。部分历史调用点绕过 notifier 只写库，迫使终端页监听 provider 把值"拉回来"补偿。

#### 证据

```dart
// terminal_appearance_panel.dart:59-62
Future<void> save(String key, dynamic value) async {
  await SettingsDao.set(key, value);                              // ①
  ref.read(settingsProvider.notifier).setSetting(key, value);     // ②
}

// app_providers.dart:191-194
Future<void> setSetting(String key, dynamic value) async {
  await SettingsDao.set(key, value);                              // ③ 同样的写
  state = {...state, key: value};
}
```

#### 影响

- 每次设置变更两次 IO；双写之间若有异常，库与 state 可能不一致。
- 补偿逻辑扩散：`ref.listen` 把字号拉回 TerminalPage 本地状态，掩盖了写入口不统一。

#### 解决方案

1. 确立 **`SettingsNotifier.setSetting` 为设置面板的唯一写入口**；`TerminalAppearancePanel.save` 删掉直接的 `SettingsDao.set`，只调 notifier。
2. 全项目扫描了 40 处 `SettingsDao.set(`：其中绝大多数在底层 service（`ai_endpoint_migration` / `provider_config_service` / `local_file_policy` / `mcp_store` 等）与 Widget 本地方向盘状态（`terminal_page` 的面板位置/宽度），它们拿不到 ref 或不需要通知全局 provider，**本轮保留为已知例外**，不逐一改造（改造会扩散 ref 依赖并引入新风险）。真正造成双写的只有 `terminal_appearance_panel` 一处，已消除。
3. `terminal_page.dart` 的 `ref.listen` 补偿保留（它是"外部入口改字号 → 终端同步"的合法机制），但更新注释，去掉"只写库不通知"的历史表述。
4. `setSetting` 增加失败时不更新 state 的语义保持（现状已满足：`await` 在前）。

#### 备选方案

让 `SettingsDao.set` 内部通知 provider。否决：DAO 是底层，不能反向依赖 Riverpod（会加剧 C2 分层问题）。

#### 风险与缓解

- 某些调用点依赖"写库立即生效"但拿不到 ref → 保留直写并记录例外；本轮扫描后评估数量。
- `setSetting` 是异步，UI 连续快速点击可能乱序 → 现状已如此，不扩大改动范围。

#### 验证

- grep 全项目 `SettingsDao.set(`，列出剩余调用点并逐一说明。
- 新增 `test/settings_notifier_test.dart`：调用一次 `setSetting` 只触发一次 DAO 写、state 同步更新。
- 手工：拖动字号滑块，终端字号实时变化；重启 App 值保留。

---

### B1 — 三重状态源（方案已给，本轮不实施）

**症状**：切 tab 后引擎/执行器可能滞后；`cancel()` 不得不写注释解释"用 registry 不用缓存"。

**原因**：同一份逻辑状态存在三个载体 —— Riverpod `AgentState.chatItems/events`、`AgentHostRegistry` 的 per-scope 快照、`AgentEngine` 内部可变字段。三者靠 47 处注释和手工同步维持。

**证据**：`agent_provider.dart:49`（`_registry`）、`:1441`（滞后注释）、`:222-226`（切 tab 时从 registry 恢复三份数据）。

**解决方案（迁移路径）**：
1. 确立 registry 为唯一真相源，Riverpod state 降级为**当前活跃 scope 的派生视图**；
2. 抽 `TabSessionController`（持有 engine + executor + 状态 + 取消令牌），registry 只存 controller 引用；
3. 引擎内部状态改为 controller 的私有字段，通过 `snapshot()` 暴露给 UI；
4. 逐条移除注释规约，替换为类型约束（引擎不允许直接写 provider state）。

**风险**：触及全部 40+ 引擎引用点，必须分 3–4 个 PR 做；本轮不动。

---

### B2 — 三个上帝文件（方案已给，本轮不实施）

**量化**：`terminal_page.dart` 7780 行 / 195 方法 / 88 import / 单 State 占 179–7160；44 个字段中约 35 个是 per-tab 平行 Map，`_removeTab` 手工清理 20+ 个 Map。

**解决方案（顺序不可反）**：
1. 先做 B1 统一状态源；
2. 抽 `TabSessionController` 收编 35 个 per-tab Map（每个 tab 一个对象）；
3. `TerminalPage` 拆为 `TerminalPage`（壳）+ `TerminalPaneHost`（渲染）+ `TabLifecycleCoordinator`（生命周期）+ `ConnectionActions`（连接/重连/端口转发）；
4. `agent_engine.dart` 按 prompt 构建 / ReAct 解析 / 工具编排 / 终态管理拆四个 mixin 或对象；
5. 每步用既有 855 项测试作安全网。

---

### B3 — `TerminalTab` 可变对象入 state（方案已给，本轮不实施）

**症状**：`ref.watch(terminalProvider.select((s) => s.tabs.firstWhere(...).status))` 的消费者在 `status` 变化时可能不重建。

**原因**：`TerminalTab` 的 `title/status/connectionError/service/localService` 都是可变字段，`_publish()`（`:232`）只做 `state.copyWith(tabs: [...state.tabs])` 浅拷贝列表，tab 对象引用不变，selector 比较相等。

**解决方案**：`TerminalTab` 改为不可变（`@immutable` + `copyWith`），service/subscription/controller 抽到 `TabRuntime` registry，state 只保留纯数据字段；`_publish()` 构造新的 tab 实例。

**前置条件**：B1 完成后做，否则 runtime 与 registry 双重来源会更乱。

---

### C1 — 60 处空 catch（部分治理）

**症状**：配置读取、SFTP 清理、PTY 退出等失败被静默，UI 与库状态不一致时无从排查。

**原因**：`catch (_) {}` 被当作"忽略无害异常"的快捷键，但没有统一日志级别。

**解决方案**：按模块分批替换为空 catch 加 `debugPrint('[Module] context: $e')`；对真正的"预期异常"（如 `close()` 已关闭）保留空 catch 但补 `// expected: ...` 注释说明。

**本轮范围**：只处理 A1–A4 改动触及文件内的空 catch（如 `ssh_connection_pool.dart` 相关），其余按模块另排。

---

### C2 — `core/db_init.dart ↔ services/daos.dart` 循环依赖（本轮不实施）

**证据**：`db_init.dart:8` `import '../services/daos.dart';`，`daos.dart:5` `import '../core/db_init.dart';`。

**解决方案**：把 `Database` 实例访问抽到 `core/database_provider.dart`（只暴露 `Database? get db`），`db_init` 负责初始化并写入该 holder，`daos` 只依赖 holder，不再 import `db_init`。

---

### C3 — 77 处 ForTesting 后门（本轮按需扩展）

**症状**：`AIService.create` 等硬编码构造无法注入 fake，测试依赖真实文件或网络。

**方案**：延续项目现有 `@visibleForTesting` 风格，在 A1 的 `SSHConnectionPool` 加 service factory 钩子，A2 的重连调度用短延迟注入测试；不全局改造。

---

### C4 — `agent_tool.dart` 2992 行：判定为可接受，不动

20 个工具类各有单一职责 + Registry 注册，文件大是"同类插件集中登记"的结果，不是职责混杂。拆分收益低于合并检索成本。

---

## 4. 实施计划

### Phase A（本轮实施，按依赖顺序）

| 序号 | 任务 | 文件 | 风险 |
|---|---|---|---|
| A1 | 连接池生命周期修复 + 幂等 | `ssh_connection_pool.dart`、`ssh_service.dart`、新增测试 | 低 |
| A4 | 设置写入口统一 | `terminal_appearance_panel.dart`、`app_providers.dart`、`terminal_page.dart` 注释 | 低 |
| A3 | 引擎选择统一 | `agent_provider.dart` | 低 |
| A2 | 自动重连下沉 | `terminal_provider.dart`、`terminal_page.dart`、新增测试 | 中 |
| V | analyze + 全量测试 + git diff 复查 | — | — |

A2 放最后：它依赖 A1 的 `forceDisconnect → dispose` 修复（重连路径会走这条链）。

### Phase B（后续排期，本轮只写方案）

B1 状态源统一 → B2 上帝文件拆分 → B3 TerminalTab 不可变化。顺序强制。

### Phase C（按需）

C2 解循环依赖、C1 按模块清空 catch、C3 可测试性改造。

---

## 5. Phase A 详细改造说明

### 5.1 `ssh_connection_pool.dart`

```
- release():                 disconnect() → dispose()
- forceDisconnect():         disconnect() → dispose()
- dispose():                 disconnect() → dispose()
- _cleanup():                条件 refCount==0 → refCount<=1 && idle 超时；同步 dispose
- _doAcquire():              service 构造走 serviceFactoryForTesting ?? SSHService(config)
- 新增 @visibleForTesting serviceFactoryForTesting
```

保留 `refCount` 初始 1 与 `release` 归零移除的语义 —— 这与"池 key=tabId"一致，不改成通用对象池。

### 5.2 `ssh_service.dart`

```
+ bool _disposed = false
  disconnect():  输出前加 if (!outputController.isClosed)
  dispose():     幂等守卫；unawaited(outputController.close())
```

`disconnect()` 保持可重复调用（多个终态路径都会触发），`dispose()` 只执行一次。

### 5.3 `agent_provider.dart`

```
+ _activeEngine() 辅助方法
  cancel() / pause() / resume() / 补充指令路径全部改用它
  resume() 的 executor 用 registry 优先
```

### 5.4 设置链路

```
- terminal_appearance_panel.save(): 删除 SettingsDao.set
- app_providers.setSetting():       保持唯一写库入口
- terminal_page ref.listen:         保留机制，更新注释
```

### 5.5 `terminal_provider.dart`（A2）

```
- TerminalNotifier(Ref ref) + provider 内 ref.keepAlive()
+ _reconnectAttempts / _reconnectTimers / reconnectedTabIds
+ scheduleAutoReconnect(tabId) / cancelAutoReconnect(tabId)
  _openSsh.onDisconnected: 标记 lost 后 scheduleAutoReconnect
  reconnect(): 成功时 cancel + 清零 + emit
  closeTab()/dispose(): 取消定时器、关闭 controller
```

### 5.6 `terminal_page.dart`（A2）

```
- _autoReconnectAttempts / _autoReconnectTimers / _maybeAutoReconnect / dispose 清理
+ _onReconnected(Tab tab): 抽出原 _reconnectTab 的 UI 副作用
  订阅 notifier.reconnectedTabIds → _onReconnected
```

---

## 6. 测试与验收

### 6.1 新增测试

| 测试文件 | 覆盖 | 状态 |
|---|---|---|
| `test/ssh_connection_pool_test.dart` | 引用计数、release/forceDisconnect/dispose 均释放、idle cleanup 判定、dispose 幂等 | ✅ 4 项通过 |
| `test/terminal_reconnect_scheduling_test.dart` | 退避调度条件、重复调度去重、到点递增尝试、关 tab 撤销；不依赖真实 SSH（验证调度器本身） | ✅ 4 项通过 |
| 既有用例回归 | 全量 `flutter test` | 见 §9 实施记录 |

A4 的改动是"删掉一次重复调用"、A3 是"统一引擎解析来源"，都由全量回归 + `flutter analyze` 覆盖，不新增专项测试。A2 的完整业务重连链路（凭据 → 真实主机 → executor 重绑）保留手工验收，因为测试环境无法注入凭据存储。

### 6.2 回归

```
export PATH="/d/tools/flutter_sdk/flutter/bin:$PATH"
cd D:/item/ai_terminal/ai_terminal
flutter analyze                       # 期望 0 error，改动文件无新增告警
flutter test                          # 期望既有全部通过 + 新增通过
```

既有基线（历史文档记录过时）：上一轮算法优化后相关 89 项通过；本轮实测全量为 **1689 passed / 25 skipped**。

### 6.3 手工验收清单

- [ ] SSH tab 开关 10 次，`SSHConnectionPool.stats['totalConnections']` 归零
- [ ] tab 掉线后切到设置页，等待 >4s 后返回，已自动重连
- [ ] 任务运行中断线，不触发自动重连（保持既有策略）
- [ ] 多 tab 切换后 pause/resume 作用于当前 tab
- [ ] 拖动字号滑块一次，终端实时更新，SQLite 仅一次写
- [ ] App 退出时无 "Timer 未取消" / "向已关闭流 add 数据" 日志

---

## 7. 风险与回滚

| 风险场景 | 回滚方式 |
|---|---|
| A1 改 dispose 后订阅者收到 done 导致 UI 异常 | `git revert` 单个 commit；或在 pool 层临时回退为 disconnect（泄漏恢复但功能不受影响） |
| A2 自动重连在后台频繁触发 | 调大 `ReconnectPolicy.delayForAttempt`；或临时在 `scheduleAutoReconnect` 入口 return 保留手动重连 |
| A3 引擎选择改变后暂停行为异常 | 回退 `_activeEngine()`，恢复 `_engine` 直用（R3 风险重现但不影响主流程） |
| A4 写库次数减少后某些设置不生效 | 恢复对应调用点的直写，保留 notifier 调用 |

每个 Phase A 子项独立提交，便于单独 revert。

---

## 8. 附录

### 8.1 术语

- **scope**：AI 会话隔离单位，通常等于 tabId（R3）。
- **registry**：`AgentHostRegistry`，per-scope 的 engine/executor/state 容器。
- **池条目**：`SSHConnectionPool._pool` 中 key=tabId 的 `_PoolEntry`。
- **UI 副作用**：`setExecutor` / `_ensureTabTerminal` / tracker reset / size sync 等非业务状态操作。

### 8.2 关键行号索引（基线 `5e3540e`）

```
ssh_connection_pool.dart:6-15    refCount 初始 1
ssh_connection_pool.dart:106-124 release
ssh_connection_pool.dart:137-142 forceDisconnect
ssh_connection_pool.dart:158-172 _cleanup（死代码）
ssh_connection_pool.dart:186-193 pool dispose
ssh_service.dart:1138-1162       disconnect / dispose
terminal_page.dart:209-210       重连状态字段
terminal_page.dart:1467-1558     _reconnect / _reconnectTab / _maybeAutoReconnect
terminal_page.dart:1739-1743     dispose 清理
terminal_page.dart:1774-1782     字号 ref.listen 补丁
terminal_provider.dart:36-96     TerminalTab（可变）
terminal_provider.dart:232       _publish 浅拷贝
terminal_provider.dart:292-298   掉线回调
terminal_provider.dart:390-418   reconnect
agent_provider.dart:1281         补充指令引擎选择
agent_provider.dart:1440-1445    cancel（正确示范）
agent_provider.dart:1493-1506    pause/resume（需修）
app_providers.dart:191-194       setSetting（唯一写入口）
terminal_appearance_panel.dart:59-62  save（双写）
main.dart:88                     startIdleCleanup
```

### 8.3 已确认不要重复动的地方

- `react_stream_parser.dart` FNV-1a 64 位哈希（R4 已达标）
- `streaming_markdown.dart` 增量解析
- `line_diff.dart` 滚动数组 LCS + 600 行上限
- DAO `cached` 返回 live List 的 API 语义
- 会话 messages 单列 JSON 持久化 + 写入合并 + 32KB isolate
- `agent_tool.dart` 的 20 个工具类结构

---

## 9. 实施记录

### 9.1 改动清单

| 文件 | 改动 |
|---|---|
| `lib/services/ssh_connection_pool.dart` | release/forceDisconnect/dispose 统一 `dispose()`；`_cleanup` 判定修正为 `refCount<=1 && idle 超时`；注入 `serviceFactoryForTesting` 与 `cleanupForTesting` |
| `lib/services/ssh_service.dart` | `dispose()` 幂等守卫；写断开提示前检查 `outputController.isClosed` |
| `lib/providers/terminal_provider.dart` | +`Ref` + `keepAlive()`；重连调度/退避/事件下沉；`_finishReconnect` 统一重绑 executor；关 tab/provider dispose 清理 |
| `lib/pages/terminal_page.dart` | 删除 Widget 内重连定时器与 `_maybeAutoReconnect`；`_reconnectTab` 只留失败提示；订阅 `reconnectedTabIds` 执行 `_onReconnected` |
| `lib/providers/agent_provider.dart` | +`_activeEngine()`，cancel/pause/resume 统一按 registry 解析；resume 的 executor 也按 registry 取 |
| `lib/widgets/terminal_appearance_panel.dart` | 删除直写 DAO，唯一写入口改为 `SettingsNotifier.setSetting` |
| `test/ssh_connection_pool_test.dart`（新增） | 4 项：引用计数、forceDisconnect/dispose 释放、idle 清理、幂等 |
| `test/terminal_reconnect_scheduling_test.dart`（新增） | 4 项：调度条件、去重、到点递增、关 tab 撤销 |

统计：6 个代码文件 +2 个测试文件，+215/−106（不含本文档）。

### 9.2 验证结果

- `flutter analyze`：**81 issues / 0 error**，与改动前基线持平；改动文件 0 新增告警。
- `flutter test`：**1689 passed / 25 skipped**，全部通过（含 8 项新增）。
- 分支测试：`ssh_connection_pool_test` 4/4、`terminal_reconnect_scheduling_test` 4/4。

### 9.3 与设计的偏差（均有意为之）

1. **补充指令路径（`:1281`）未改用 `_activeEngine()`**：该处要求 `activeScopeId` 非空才允许发指令，改用统一 helper 会回退 `_engineScopeId` 并放宽限制，属于行为变更。
2. **40 处 `SettingsDao.set` 单点直写保留**：绝大多数位于底层 service（无 ref）或 Widget 局部布局状态；本轮只消除真正的双写（`terminal_appearance_panel`）。
3. **A2 完整链路未做自动化测试**：测试环境无法注入 `FlutterSecureStorage` 凭据，新增单测只覆盖调度器本身；真实建连/executor 重绑走手工验收清单。
4. **`reconnect()` 中 tab 已被关闭的异常分支**（`:488` registerTab）不走 `_finishReconnect`：该分支是重连请求与关 tab 竞态的产物，新建 tab 的 executor 由首次连接流程负责。

### 9.4 后续排期建议

1. **Phase B1**：统一三重状态源（registry 为唯一真相） —— 必须先于 B2。
2. **Phase B2**：按 §3 B2 顺序拆三个上帝文件，每步以 1689 项测试为安全网。
3. **Phase C2**：`db_init ↔ daos` 解环（抽 `core/database_provider.dart`）。
4. **Phase C1**：按模块分批治理 60 处空 catch。
