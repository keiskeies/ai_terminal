# SSH 断连韧性设计（等待期半开连接 / 超时断连）

> 状态：**C1–C7 已实施并通过测试**（见 §10 实施记录）；C9 未实施。
> 审计日期：2026-11-22；实施与二次核验同日完成。
> 基线：`flutter analyze` 81 issues / 0 errors；`flutter test` 1704 passed / 25 skipped / 0 failed
> 适用范围：`lib/services/ssh_service.dart`、`lib/services/ssh_keepalive_socket.dart`（新增）、
> `lib/services/ssh_connection_pool.dart`、`lib/providers/terminal_provider.dart`、
> `lib/services/agent_engine.dart`、`lib/models/host_config.dart`、`lib/services/health_check_service.dart`
> 关联：AGENTS.md R1（异步取消与世代检查）、R2（资源生命周期）、R3（多主机隔离）、
> R5（状态机一致性）、R6（跨平台）、R9（契约变更需 grep 全部调用方 + 端到端测试）
> 不在范围：`terminal_page.dart` / `agent_command_block.dart` / `agent_event_cards.dart` /
> `agent_process_timeline.dart`（本仓库同期他人 WIP，本方案刻意不改这四个文件）

---

## 1. 背景与问题

Agent 一次任务通常执行几十条命令，每条命令都要在 `SSHService.executeAndWait` 里"等"。
等待期最怕的不是命令失败，而是**链路静默失效**：NAT/负载均衡悄悄回收映射、服务器掉电、
`ClientAliveCountMax` 触发、`TMOUT` 自动登出。这几种情况下客户端收不到 FIN/RST，
什么事件都不触发，Agent 只能干等到 tier 超时（默认 60 s，apt/nmap 类 10 min）。

实测代码后的结论是：**当前对"半开连接"完全没有检测能力，且断线自愈在任务运行期被禁用**。
用户体感是"卡住不动、最后报一次超时"，而不是"秒级发现断线并自动重连续跑"。

本文给出分级修复：P0 让断线在秒级被发现并如实上报；P1 让断线后能自动重连、
且重连后的第一条观察明确告知状态已丢失；P2 记录"长命令分离执行"方案但不实施。

## 2. 已核实的契约事实

所有断言都来自实际读过的代码（含 dartssh2 3.3.1 源码），逐条给出行号。

| # | 事实 | 位置 | 后果 |
|---|---|---|---|
| F1 | `SSHClient(...)` 构造未传 `keepAliveInterval`，dartssh2 默认 10 s | `ssh_service.dart:148-158`；`dartssh2 ssh_client.dart:243` | keepalive **确实在发**，但不能据此认为"已保活" |
| F2 | `ping()` = `await _sendGlobalRequest(keepAlive:true)`，等待 `_globalRequestReplyQueue.next`，**无超时**；`SSHKeepAlive` 的 `_isPinging` 在这一次挂住后永久跳过后续 ping | `dartssh2 ssh_client.dart:763-766, 841-849`；`ssh_keepalive.dart` | 半开连接上 keepalive **自我永久关闭**（这是 F1 的关键限定） |
| F3 | `SSHSession.write` 返回 `void`，内部 `stdin.add` 即发即忘 | `dartssh2` | 向死连接写入**永不抛异常** |
| F4 | `_checkConnection` 的探活是 `_writeTextQuietly('\n')` + `catch` | `ssh_service.dart:293-318` | 由 F3，这个探测**永远检测不到**断线，纯装饰 |
| F5 | `_handleDrop` 只由输出流 `onDone` / `onError` 驱动 | `ssh_service.dart:442-479, 1128-1140` | 半开时既无 FIN 也无错误 → `onDisconnected` **永不触发** |
| F6 | `scheduleAutoReconnect` 开头 `if (isRunningFor(tabId)) return;` | `terminal_provider.dart:269` | 任务运行期不允许自动重连（设计如此，但见 F7） |
| F7 | `scheduleAutoReconnect` 只有两个调用点：`service.onDisconnected` 与手动重连失败后的续排 | `terminal_provider.dart:385, 515` | 链条本身是自我续排的（L515 在失败分支里再排下一档），但**首次触发只有一个入口**：由 F5，半开时压根不触发；干净断开时又被 F6 拒掉，于是连"下一次再排"的机会都没有。两条路自愈链都是死的 |
| F8 | 引擎侧 `setExecutor` 自愈只在 `executeAndWait` 抛异常时生效 | `agent_engine.dart:1590-1598, 4270-4295` | 半开不抛异常（F3）→ 自愈走不到；只有手动重连能救 |
| F9 | 连接初始化串含 `PAGER=cat …`，**没有** `TMOUT` | `ssh_service.dart:250-258` | 服务器 `export TMOUT=300`（常见等保基线，且多为 `readonly`）会让 shell 在空闲期登出 |
| F10 | `config.timeout`（默认 30 s，UI 滑杆 10–120 s）只有页面读取，建连路径无引用；真实建连超时硬编码 15 s / 30 s | `host_config.dart:57,115`；`host_edit_page.dart:103,469`；`ssh_service.dart:117-121,141-145`；`ssh_connection_pool.dart:97` | 用户设置"连接超时"完全无效 |
| F11 | dart:io 无公开 `Socket.soKeepAlive`；`RawSocketOption.fromInt` / `levelTcp` 可用；`SSHSocket.connect` 只暴露 host/port，无 socket 选项钩子 | `dart-sdk/lib/io/socket.dart:395-500`；`dartssh2 ssh_socket_io.dart` | 要设 TCP keepalive **必须自建 `SSHSocket` 适配器** |
| F12 | `HealthCheckService` 每 5 min 只读 `SSHConnectionPool.stats` 的 `isConnected` 并记日志 | `health_check_service.dart:36-105` | `isConnected` 只是本地标志位，死连接照样 `true`；既不探测也不修复 |
| F13 | `reconnectedTabIds` 的消费者是页面，只承担 UI 副作用 | `terminal_provider.dart:146-153`；`terminal_page.dart:466-477, 1549-1558` | "连接已恢复"只能通知到**活着的页面**（`_ensureTabTerminal` / tracker reset / 尺寸同步）；引擎层拿不到，所以 C4 需要独立的 provider→engine 桥 |
| F14 | `ReconnectPolicy` = 3 次，1 s / 2 s / 4 s | `reconnect_policy.dart` | 自愈窗口 7 s，网络抖动型断线够用；服务器重启（>7 s）赶不上 |
| F15 | 等待期由 `Future.any([doneCompleter, timeout, cancelToken])` 驱动，超时统一返回 `failureKind: timeout` | `ssh_service.dart:509-539` | 断线与真慢被压成同一个 `timeout`，AI 只会盲目加大超时（`agent_tool.dart:950-993` 的 kind 语义映射被绕过） |

## 3. 修复总表

| ID | 优先级 | 内容 | 主要文件 | 验收 |
|---|---|---|---|---|
| C1 | P0 | 等待期活性看门狗：连续静默达阈值 → `client.ping()`（自带超时）→ 失败立即以 `failureKind: disconnected` 结束等待 | `ssh_service.dart` | 单测：静默+ping 死 → 秒级 `disconnected`；静默+ping 活 → 继续等到原超时；输出持续 → 不探测 |
| C2 | P0 | TCP keepalive + `TCP_KEEPIDLE`/`_INTVL`/`_CNT`，通过自建 `SSHSocket` 适配器；直连与跳板机都覆盖 | `ssh_keepalive_socket.dart`（新增）、`ssh_service.dart` | 单测：选项被正确下发；平台不支持时静默降级不影响建连 |
| C3 | P0 | 看门狗区分"断连"与"真慢"，不再一律 `timeout`（F15） | `ssh_service.dart` | C1 用例即验收；`agent_tool.dart` 观测文本出现 `DISCONNECTED` |
| C4 | P1 | 任务运行期允许后台自愈：`scheduleAutoReconnect` 不因 `isRunningFor` 直接放弃，改走"静默自愈"分支；重连成功后重试轮加预算 | `terminal_provider.dart`、`agent_engine.dart` | 复用/扩展 `terminal_reconnect_scheduling_test.dart`；新增：任务运行中掉线 → 定时器仍排期 → 重连后 executor 换回池内新 service |
| C5 | P1 | 重连后首条观察加"新会话"标注（cwd/env/sudo 丢失，非幂等命令先核验） | `agent_engine.dart` | 单测：重连后首条 observation 前缀含标注；同一次重连只标注一次 |
| C6 | P1 | 连接初始化串补 `TMOUT=0` + `unset TMOUT`（POSIX 分支） | `ssh_service.dart` | 单测：POSIX init 串含两者；Windows/cmd 分支不含 |
| C7 | P1 | 让 `config.timeout` 真正生效（建连超时），下限 10 s、上限沿用滑杆 120 s | `ssh_service.dart`、`ssh_connection_pool.dart` | 单测：`timeout: 10` 时传下去的是 10 s；未设置仍是 15 s |
| C8 | P2（**不实施**） | 长命令 detach + 轮询（`setsid` + 状态文件），断线后可恢复 | — | 仅记录，见 §6 |
| C9 | P2（**不实施**） | 池级健康探针接入 `HealthCheckService`，把"死但还在池里"的连接主动检出；理由与回头条件见 §11 | `health_check_service.dart` | 见 §5.7（复用 `scheduleAutoReconnect`） |

## 4. P0 详细设计

### 4.1 C1 等待期活性看门狗

**位置**：`SSHService.executeAndWait`，与现有 `Future.any` 并列，不改动 marker 判定逻辑。

**为什么放在这里**：F5 决定了"没有任何上游事件会告诉我们掉线"，只有等待循环自己在主动读输出，
所以只有它能主动提问"你还活着吗"。放在引擎侧（`agent_engine.dart:4270`）只能等到
`executeAndWait` 返回之后，白等几十秒到十分钟。

**判定与动作**：

```
静默阈值 = max(15 s, min(45 s, 剩余 timeout / 3))
条件     = 距最后一次输出 ≥ 静默阈值
动作     = 先查本地标志位（廉价），再 client.ping() 带 3 s 超时
         · ping 正常返回  → 记录 probeOk，刷新静默基线，继续等（不打扰用户）
         · ping 抛异常/超时 → _handleDrop() 语义 + 以 failureKind: disconnected 结束等待
探测上限 = 同一命令最多 3 次（防抖），任一次成功即视为链路活着
```

- 静默基线：`_lastOutputAt` 在输出流监听器（`ssh_service.dart:442-479`）里逐 chunk 更新。
  长命令只要还在吐输出就**永不探测**——避免把"跑得慢"误判成断线。
- `ping()` 必须自己包超时：`await client.ping().timeout(Duration(seconds: 3))`。
  这同时修掉 F2 的一个副作用——我们不再依赖 dartssh2 内部那条无超时的 keepalive 路径来发现故障。
- 探测必须在世代/取消检查之后：若 `doneCompleter.isCompleted` 或已取消，直接放弃探测（R1）。
- **不动 marker 状态机**：探测失败走既有的 `_handleDrop()`（`ssh_service.dart:1128`），
  它会 complete 所有 pending completer 并只通知一次 `onDisconnected`。C1 只负责把
  这条命令以 `disconnected` 收尾，复用 `_finish` 的既有终态路径（R5：终态一致）。
- 探测产生的输出为零，不会污染 buffer；不写入 PTY，不会打断正在运行的命令。

**误判风险与对策**：`ping` 是 SSH 传输层 global request，需要一个 RTT。极弱网（卫星链路
RTT > 3 s）会误判断连。对策：`ping` 超时**连续 2 次**才判死；单次超时只记日志。

### 4.2 C3 失败kind 语义

`failureKind: disconnected` + `failureReason`（中文，含"已静默 Ns，ping 无响应"）。
`agent_tool.dart:950-993` 已把 kind 映射成 AI 行为指引（disconnected → 重连；timeout → 加大超时），
C3 让这条既有语义真正生效，AI 会改为核验状态而不是盲目重试大命令。

### 4.3 C2 TCP keepalive 适配器

`SSHSocket.connect` 无 socket 选项钩子（F11），因此新增一个极薄的适配器：

```dart
// lib/services/ssh_keepalive_socket.dart
class KeepaliveSSHSocket implements SSHSocket {
  // 自己 Socket.connect → setRawOption(keepalive) → SSHSocket.fromSocket(socket)
}
```

下发选项（`Platform.isWindows` 分支，失败一律 `catch` 后继续，绝不影响建连）：

| 语义 | Linux/macOS | Windows |
|---|---|---|
| 打开探测 | `TCP_KEEPIDLE` 未暴露 → 用 `SO_KEEPALIVE`(level=socket, opt=0x0008, on) | `SIO_KEEPALIVE_VALS`（`levelTcp`, `TCP_KEEPALIVE_OFF` 反义，即用 onoff=1 的 ioctl 型选项） |
| 首包空闲 | `TCP_KEEPIDLE` = 20 s | `tcp_keepalive.time` = 20000 ms |
| 探测间隔 | `TCP_KEEPINTVL` = 5 s | `tcp_keepalive.intvl` = 5000 ms |
| 失败次数 | `TCP_KEEPCNT` = 3 | 固定 10 次（Windows 不可调） |

**诚实的局限（写进注释，不写进 UI 文案）**：Windows 下 Dart 不导出 `SIO_KEEPALIVE_VALS`
常量，需要以 `RawSocketOption.fromInt(levelTcp, <ioctl 编号>, …)` 试探，且 `value` 是单个
int32 而该 ioctl 要 3 个 int 的结构体——**这条路大概率不可用**。因此 C2 的交付口径是：
POSIX 三个参数尽力下发；Windows 只保证"尝试打开 SO_KEEPALIVE，失败即静默降级"。
**真正的跨平台主力是 C1 应用层探测**，C2 只负责"没人等待时也能感知链路死亡"。
不把 C2 描述成用户可见的可靠性保证（AGENTS.md 的对外表述必须真实）。

## 5. P1 详细设计

### 5.1 C4 任务运行期的静默自愈

`scheduleAutoReconnect`（`terminal_provider.dart:265-293`）现在有两处 `isRunningFor` 拦截
（L269 排期时、L279 触发时）。改为：

- 排期时：任务运行中**照样排定时器**。
- 触发时：任务运行中**照样重连**，但只做业务层动作——更新 `tab.service`、`setExecutor`、
  `_publish()`；**不动终端视图**（不重建 xterm、不清回滚缓冲）。这正是现有注释里
  "UI 不存活也不能失效"的同一诉求，只是把"任务占用"也纳入。
- **实现与初稿的偏差**：初稿设想加 `whenBusyDefer` 入参把"静默自愈"和"普通重连"分开，
  实施时判定这条分支不需要存在——`reconnect()` 走的是同一条 `_openSsh` 路径，
  本来就不重建 xterm（视图重建由页面在拿到 `_reconnectedTabIds` 后做），
  所以直接删掉两处 `isRunningFor` 拦截即可，不引入新参数、不加新状态。
  保留的只有解释为什么必须删的注释。
- 手动 `reconnect()`（L480-518）路径行为完全不变，含 `keepAttempts: true`。
- `ReconnectPolicy.maxAttempts` 从 3 提到 6（1+2+4+8+16+32 ≈ 63 s）。理由见 F14；
  `ReconnectPolicy` 是纯函数，`reconnect_policy_test.dart` 需同步断言。

**为什么不与任务互斥**：`switchTab`/手动切页会取消任务，所以那条互斥有意义；但这里重连
发生在同一个 tab 的任务等待期，重连本身不取消任务，只是把 executor 换掉。引擎下一次
取 executor 已经读 `_currentExecutor`（`agent_engine.dart:1590-1598`），天然衔接。

### 5.2 C4 重试轮预算

`_maxConnFailRetries = 3`（`agent_engine.dart:361`）。重连在 63 s 窗口内可能横跨多轮等待，
固定 3 次会先耗尽。改为**在任务运行期间发生过一次成功重连，则给 3 次额外预算**：

```dart
int _connFailBudget = _maxConnFailRetries;   // 3
// reconnect-notify 回调里：_connFailBudget = _maxConnFailRetries * 2;
```

不放宽无重连情形——没恢复连接的连续失败仍然 3 次终止（避免 F7 死循环复活）。

### 5.3 C4 的 provider→engine 桥

`terminal_provider` 已 import `agent_provider`，不新增方向性依赖。新增一个回调槽，
由 `_finishReconnect`（`terminal_provider.dart`）触发：

```dart
// terminal_provider.dart
static void Function(String tabId)? onTabReconnectedForTesting;   // 非 testing：静态回调槽
// agent_provider.dart（装配处）
TerminalNotifier.onTabReconnected = (tabId) =>
    ref.read(agentProvider.notifier).noteConnectionRestored(tabId);
```

不复用 `reconnectedTabIds`（F13：无消费者，且消费方若挂在页面上就又回到"页面活着才有自愈"的老问题）。

### 5.4 C5 新会话标注

`agent_engine` 记 `_needsStateNote`（重连置位、消费后清除）。命中时在该步请求前
以 `role: user` 写入一条消息——**写在 ReAct 循环的代际检查之后**，不在
`noteConnectionRestored()` 的调用栈里写：那里可能是旧任务的重连事件，
直接写历史会污染新任务（AGENTS.md R5）。
`_resetTransientState()` 刻意**不清**这个标志：断线终止后用户接着发的下一条任务，
第一条命令最容易被当成"重跑上一步"，危险恰恰在下一个任务。标注正文：

```
[注意] 这是重连后的新会话：工作目录、环境变量、已导入的 sudo 状态全部丢失。
不要直接重跑上一步命令——先核验它是否已生效（非幂等命令尤其危险）。
```

理由：断线重连后最坏的不是失败，而是"看起来成功了但其实换了会话"，直接重跑
`rm -rf`/`apt install` 有真实破坏性。必须显式告知（R5 白名单思路：只有确认幂等才继续）。

### 5.5 C6 TMOUT

init 串追加，仅 POSIX 分支。**实施修正**：初稿写的 `TMOUT=0 2>/dev/null` 无效——
裸赋值的 `2>/dev/null` 只作用于命令自身的 stderr，而 "readonly variable" 是
shell 自己报的，bash/dash（含 `--posix`）实测照样打在用户终端上；
落地为 `export TMOUT=0 2>/dev/null;unset TMOUT 2>/dev/null;`，
readonly 主机静默、普通主机真正清掉 TMOUT。
Windows/cmd/PowerShell 分支不加（R6：按 shell 类型分支）。

### 5.6 C7 连接超时

`SSHService.connect`（含跳板机段各自 `connectTimeoutFor(该段配置)`，clamp 10–120）
替代硬编码 15 s；`ssh_connection_pool` 的整体 `.timeout(30)` 改为
"各段超时之和 + 15 s 余量"。**实施修正**：初稿的"主机超时 ×2"不成立——
调用方合成的跳板机 `HostConfig` 不带 `timeout`（恒默认 30 s），两段并不相等，
主机设 10 s 时按 ×2 只给 35 s，池会在 40 s 真实建连完成前先掐断；
`overallConnectTimeoutFor` 因此收 `jumpHostConfig` 按段计算。
这是 F10 的行为修复（用户设置从无效变有效），属于可交付修复而非回归，但要在 §8 风险里点名。

### 5.7 C9 池级探针

`HealthCheckService` 里标记池中 `isConnected==true` 但 `ping` 失败的条目：
记 WARN + 调 `scheduleAutoReconnect`。目的是覆盖"tab 已被释放但连接还挂在池里"的僵尸条目。
不引入新的重连机制，复用 C4 的调度入口，避免两套重连互相踩。

> 实施后判定为**不实施**：这条链路的两个前提经核都不成立，理由与回头条件见 §11。

## 6. P2：detach + 轮询（记录，不实施）

以上全部改动**不能救回一条已经跑在服务端的命令**——连接死了，前台命令随 shell 退出而终止
（除非 `nohup`/`disown`）。唯一真正的解法是把长命令与 SSH 会话解绑：

```sh
setsid sh -c 'your_cmd > /tmp/.ait_$TAG.out 2>&1; echo $? > /tmp/.ait_$TAG.rc' </dev/null >/dev/null 2>&1 &
# 之后轮询：test -f /tmp/.ait_$TAG.rc && cat .out .rc
```

不做的原因：需要新的工具契约（detach / poll 两个动作 + tag 生命周期）、AI 要改变
"一条命令一次结果"的心智模型、命令幂等性判定（重跑 apt 可，重跑 `rm`/`curl -T` 不可），
以及远端临时文件清理归属。收益与风险都明显高于 P0/P1，单独排期。

## 7. 测试与验收计划

| 层 | 用例 |
|---|---|
| 单测（新增 `ssh_liveness_watchdog_test.dart`） | ①静默且 ping 抛错 → `failureKind==disconnected` 且耗时 ≪ 原 timeout；②静默但 ping 正常 → 不提前结束，最终按 marker/timeout 收尾；③持续输出 → 一次都不 ping；④探测上限 3 次；⑤命令已完成/已取消时不探测 |
| 单测（`ssh_keepalive_socket_test.dart`） | 适配器对 loopback 监听（或注入的假 socket）下发预期选项集合；`setRawOption` 抛异常时 `connect` 仍成功 |
| 单测（扩展 `reconnect_policy_test.dart`） | `maxAttempts=6`、`delayForAttempt` 序列 1/2/4/8/16/32 |
| 单测（扩展 `terminal_reconnect_scheduling_test.dart`） | 任务运行中掉线仍排期；触发时 executor 换成新 service 且 tab 视图不重建；手动重连路径断言不变 |
| 单测（`agent_engine` 相关） | 重连后预算翻倍；首条 observation 含标注且只标注一次 |
| **端到端（R9 必须）** `ssh_disconnect_e2e_test.dart` | 真实 `SSHService` + 注入的假 `SSHClient`（`ping()` 可控挂起）→ 跑 `executeAndWait` → 断言：挂起时秒级返回 `disconnected`、观测文本经 `agent_tool` 格式化后含 `DISCONNECTED`、引擎收到后走 `ask` 指引而非加大超时。形态参照 `test/react_parse_e2e_test.dart` |
| 回归 | `flutter analyze`（0 errors）、`flutter test --no-pub` 不少于基线 |

## 8. 风险与回滚

1. **C1 误判**：弱网高 RTT 下 ping 超时可能被当成断连。缓解：连续 2 次超时才判死 + 先验输出静默。
2. **C7 改变既有行为**：`config.timeout` 之前无效，生效后有用户设 10 s 可能在慢速链路上建连失败。
   回滚只需把 `connect` 的 timeout 参数还原为常量；风险面在实现前需在 README 变更说明中点名。
3. **C2 在 Windows 上大概率无效**：已在 §4.3 明确口径，可靠性主张由 C1 承担，不对外宣称 TCP 层保活。
4. **C4 让任务运行期出现并发重连**：必须确认重连不触发 `switchTab` 语义（不取消任务）。
   若发现 `setExecutor` 与在途 `executeAndWait` 竞态，退让方案：只在 `executeAndWait` 返回后换 executor。
5. **C1 与端口转发共用 global request 应答队列（审计新增）**：dartssh2 的
   `_globalRequestReplyQueue` 是**按序出队、不校验内容**的（`ssh_client.dart:316/842/1129/1135`），
   而 `ping()` 只看"有没有应答"、`forwardRemote()` 却按类型判定
   （`:406-410` 拿到非 Success 就 `throw SSHStateError`）。看门狗探测若恰好插在
   用户添加远端转发的请求与应答之间，转发那条会收到 keepalive 的应答并报错。
   **这不是本次引入的**：dartssh2 内置 keepalive 本就每 10 s 走同一条队列，
   同一碰撞窗口一直存在，看门狗只是在"静默期"多压了几次。不为此加代码：
   我们在 dartssh2 外部拿不到队列，包一层要改它内部；风险面是"添加远端转发偶发失败重试一次"。
   未做真机验证，属 SUSPECTED。
6. **C4 放大既有的"重连窗口内按键丢弃"**：`reconnect()` 期间 `tab.service` 被置空
   （`terminal_provider.dart:509`），页面按键走 `tab.service?.writeToTerminal`
   （`terminal_page.dart:862`）→ 这段输入的 `_openSsh` 重绑之后不再补写，用户敲的字静默消失。
   **不是本次引入**（手动重连一直是这样），但退避从 7 s 拉到 ~63 s、且任务运行期也会自动重连，
   命中窗口明显变大。缓解是既有的：窗口内角标显示"连接中"warn spinner 且不可点
   （`terminal_page.dart:3184-3185`），不是完全无提示。刻意不做输入缓冲重放——
   重放半条命令在非幂等命令上比丢弃更危险（与 C5 同一判断）。
7. **回滚顺序**：C1/C3 同进退（改 `executeAndWait` 返回）；C2 独立可关（不调用适配器即可）；
   C4/C5 独立；C6/C7 各一行。任一出问题可单独摘除，互不牵连。
## 9. 验证附录（二次逻辑验证记录）

对 §2 每条断言与 §3 每处改动做了第二轮代码核对，方法：直读 `ssh_service.dart`
（1-99、100-190、200-275、280-640、1102-1170）、`ssh_connection_pool.dart`、`command_executor.dart`、
`terminal_provider.dart`（146-153、265-305、312-320、373-402、470-518）、`reconnect_policy.dart`、
`agent_engine.dart`（361、1584-1613、4262-4380）、`agent_tool.dart`（950-993）、
`host_edit_page.dart`（103、425-478）、`health_check_service.dart`（1-105）、
本地 Dart SDK `io/socket.dart`（395-500）、pub-cache 中 dartssh2 3.3.1 的
`ssh_client.dart` / `ssh_keepalive.dart` / `ssh_socket_io.dart` / `async_queue.dart`。

| 项 | 结果 | 备注 |
|---|---|---|
| F1/F2/F3 | 证实 | dartssh2 源码逐行确认；`async_queue.closeWithError` 会终止**当前与将来**的 waiter，这是 `_isPinging` 永久卡死之外的另一条路径 |
| F4/F5 | 证实 | `_writeTextQuietly` 唯一 `catch` 的是 `_charsetWriter` 编码异常，socket 写异常类型上不可能到达 |
| F6/F7 | 证实 | grep `scheduleAutoReconnect` 全仓库仅 2 处：定义 + `onDisconnected`（`health_check_service` 未调用；C9 不实施，见 §11） |
| F8/F13 | 证实 | grep `reconnectedTabIds` 仅 provider 内部 add/stream，无 listen |
| F9 | 证实 | init 串逐字符确认无 `TMOUT` |
| F10 | 证实 | grep `\.timeout` 全仓库：除 `host_config.dart` 定义/复制、`host_edit_page.dart` 读回显外无任何使用点（`mcp_connection.dart` 的 `config.timeoutMs` 是 MCP 自己的字段，无关） |
| F11 | 证实（并修正初稿） | 初稿写"Windows 可用 `TCP_KEEPALIVE` 0x10 设置参数"——二次核对：该值是 Winsock 的 **onoff 型**选项，且 `SIO_KEEPALIVE_VALS` 需要 3 个 int 的结构体，Dart 只给 int32。**§4.3 已按此改写，Windows 只承诺尽力开 SO_KEEPALIVE** |
| F12/F14/F15 | 证实 | — |
| C4 触发时不动视图 | 代码层面证实 | 实施时确认：`reconnect()` → `_openSsh` 只换 `tab.service` 与状态，xterm 由页面另行重建，所以删掉 `isRunningFor` 拦截不会重建视图；调度侧由 `terminal_reconnect_scheduling_test.dart` 的"任务运行中照样调度"断言。视图侧无自动化覆盖（需 widget 测试或真机），见 §11 |
| C4 的 provider→engine 桥 | 证实可行 | `terminal_provider.dart` 顶部已 `import 'agent_provider.dart'`，新增回调不引入反向依赖 |
| 滑杆范围 | 证实 | `host_edit_page.dart:469` min 10 / max 120 → C7 的 `clamp(10, 120)` 与 UI 一致 |
| 原"待实施期确认"①：`_finishReconnect` 在 tab 已关闭时的空安全 | 已解决 | `_finishReconnect` 只接受调用方持有的 tab 实例，`cancelAutoReconnect` 先跑；`closeTab` 会撤销待执行定时器，因此不存在"tab 已关还收尾"的路径 |
| 原"待实施期确认"②：`ping()` 在 `_client == null` 时的行为 | 已解决 | `_probeLiveness` 本地判空并返回 `true`——探测失败必须是肯定证据，"没有 client"不能当断连；`ssh_liveness_watchdog_test.dart` 的"无探测能力时绝不判死"覆盖此路 |
| 原"待实施期确认"③：`client.ping()` 与 dartssh2 内置 keepalive 并发 | 未在设备上验证 | 两者共用 `_globalRequestReplyQueue`。看门狗只在"静默 ≥ 阈值"时探测，内置 keepalive 每 10 s 一次。**初稿"代码层面不会错配"的判断是错的**：`AsyncQueue` 不校验内容意味着按序出队即错配，只是 keepalive 之间互相错配无害（两者都不看应答内容）；一旦掺进 `forwardRemote` 就会错配到抛错，见 §8.5。真实弱网下的相互影响仍需接真机观察，**不作为已验证结论** |
| Windows 远端 init 串 | 遗留（不在本方案范围） | `initCommandsFor` 的 alias/`LS_COLORS` 两段仍是 POSIX 专属，`_remoteIsWindowsCmd` 分支只去掉了 `TMOUT`。改动前就这样，修它需要真实 Windows SSH 目标 |

## 10. 实施记录

实际落地顺序：C6 → C7 → C2 → C1+C3 → C4+C5。每步跑 analyze + 相关单测，最后跑全量。
C9 未实施（见 §11）。

| 项 | 产物 | 验收 |
|---|---|---|
| C1/C3 | `ssh_service.dart` 的 `silenceLimitFor` / `_probeLiveness` / `_lastConfirmedAliveAt`；`CommandFailureKind.disconnected` | `ssh_liveness_watchdog_test.dart`（11 例） |
| C2 | 新增 `ssh_keepalive_socket.dart`（`KeepaliveSSHSocket` + `applyTcpKeepAlive`），直连与跳板机两条建连路径都换用适配器 | `ssh_keepalive_socket_test.dart`（6 例，真实 loopback socket） |
| C4 | `ReconnectPolicy.maxAttempts` 3→6；删除 `scheduleAutoReconnect` 的两处 `isRunningFor` 拦截；`_finishReconnect` → `AgentNotifier.noteConnectionRestored(tabId)` → `AgentEngine.noteConnectionRestored()`（预算 3→6） | `reconnect_policy_test.dart`、`terminal_reconnect_scheduling_test.dart`、`ssh_reconnect_agent_test.dart` |
| C5 | `AgentEngine._needsStateNote` + `_takeStateNote()`，写在循环代际检查之后 | `ssh_reconnect_agent_test.dart`（含"下一个任务仍保留提示"） |
| C5 附带修复 | 执行器自己判定断线（看门狗）原先**不进**连续失败计数：计数只在"执行前 `isConnected==false`"这条路上累加，而看门狗救的正是"`isConnected` 仍为 true 但链路已死"那一档。结果是门限比宣称的晚整整一条命令，最常见的断线要跑到 `maxSteps` 才停。改为主命令路径统一计数，回滚预快照用 `countDisconnect: false` 排除（否则一条断链主命令记 2 次） | `ssh_disconnect_e2e_test.dart` 第 2 例（门限处才升级为"请停手"）——这条用例是发现该缺陷的地方 |
| C6 | 初始化串抽成 `SSHService.initCommandsFor({required bool remoteIsWindowsCmd})`，POSIX 分支加 `export TMOUT=0` + `unset TMOUT`（两段各带 `2>/dev/null`；裸赋值的写法抑不住 readonly 报错，见 §5.5 实施修正） | `ssh_init_commands_test.dart`（3 例） |
| C7 | `SSHService.connectTimeoutFor`（clamp 10–120，主机与跳板机各按自己的配置）与 `SSHConnectionPool.overallConnectTimeoutFor`（各段之和 + 15 s 余量，收 `jumpHostConfig`） | `ssh_connect_timeout_test.dart`（5 例） |

回归：`flutter analyze` 69 issues / 0 errors / 0 warnings（基线 81）；
`flutter test --no-pub` 1855 passed / 25 skipped / 0 failed（基线 1704 / 25 / 0）。
新增/扩展用例：看门狗 11、TCP keepalive 适配器 6、连接超时 5、init 串 3、
重连与预算 7、端到端断线 3、重连调度 5、退避策略 4。

## 11. 未实施

- **C9 池级探针**：不实施。`HealthCheckService` 仍只读 `SSHConnectionPool.stats` 打日志
  （`health_check_service.dart:71-87`），本节说明为什么这样是可以的，以及什么条件下要回头补。
  - **有 tab 引用的池条目已被 C1 覆盖**：看门狗探测失败 → `_handleDrop()`
    （`ssh_service.dart:342-344` 开工前预检、`:572-589` 等待期）→ `onDisconnected?.call()`
    （`:1290`/`:1299`）→ `scheduleAutoReconnect`（`terminal_provider.dart:386`）。
    这条链就是 §5.7 想复用的那个入口，C9 再走一遍只是重复触发。
  - **无 tab 引用的池条目 C9 也修不了**：`onDisconnected` 只在 `_isOpen(tab.id)` 时挂上
    （`terminal_provider.dart:386`，关 tab 时置 `null`：`:435`/`:505`）。tab 一关，池里的
    service 就没有回调消费者，探针要么"只记 WARN"（与现状等值），要么新增一套池自建重连
    ——正是 §5.7 明令禁止的第二套机制。而这条连接下次被复用（`_doAcquire`）时，C1 的
    开工前预检（`:342-344`）会先把它问死并丢弃重建，僵尸条目活不过一次 acquire。
  - **代价对比**：`isConnected` 是本地标志位（F12），要真检出必须每 5 min 对每条池连接
    发一次传输层 ping——纯为观测引入周期性网络流量与配额消耗，收益只有日志。
  - **何时回头做**：若引入"tab 关闭后仍常驻的后台执行器"（任务生命周期不再等于 tab 生命周期），
    上述"回调消费者一定活着"的前提就破了，届时按 §5.7 做，并复用 `scheduleAutoReconnect`。
- **C8 detach + 轮询**：见 §6，单独排期。
- **真机验证**：半开连接的秒级发现、重连后续跑、Windows 远端 init 串，都需要接真实
  服务器/Windows SSH 目标复核；本文的"已实施"仅指代码与自动化测试层面。
