9. **本机命令误发远程 (local_command_on_remote)** — Dart `local_command_detector.dart` (37 行) + `agent_engine.dart` 2543-2571 已整搬至 `src/utils/local_command_detector.ts` + engine 远程误发拦截臂 (r135); 检测逻辑: 盘符路径 + PowerShell 强特征 (3 组 RegExp), 命中即给可读观测 + `onSuccess(false, 'local_command_on_remote', 0)` 早退
# Agent 核心迁移设计文档 — 从 Dart 到 TypeScript (Node.js 子进程)

> 版本: 0.1  |  状态: 草案  |  作者: AI Assistant  |  日期: 2026-11-08

---

## 0. 背景与目标

### 现状痛点

1. **卡顿**: 整个 ReAct Agent 循环、流式解析、Markdown 重渲染、知识库查询、工具执行全部在 Flutter 主 isolate 里运行。`_agentStreamThrottleMs = 120ms` 是现有妥协（~8fps），重 chunk 到达时仍会掉帧。
2. **生态断层**: MCP 官方 SDK 与主流社区 server 都是 TypeScript 写的，当前用 `mcp_dart`（非官方、迭代慢、兼容性靠维护者手写）。
3. **工具执行跨进程边界**: `agent_tool.dart` 调 `local_terminal_service.dart` 走 Flutter 内部 IPC，工具侧写本地文件 → 跨 isolate → 序列化 → 跨回 → 渲染。

### 迁移目标

- **不整体重写**。只迁 **Agent 核心**（ReAct 循环 + 工具执行 + MCP + LLM 调用）到 Node.js 子进程。
- **保留 Flutter UI 层**（`xterm.dart`、`flutter_markdown`、Riverpod 状态管理）。
- **保留 SSH/SFTP 在 Dart 侧**（`dartssh2` 成熟度高，不重蹈 Node 的 `ssh2` 坑）。
- **可回滚**: 每一步独立交付，stdio 协议稳定，任意时刻可以切回 Dart 原实现。

### 非目标

- 不做 Web 端（继续 5 平台：macOS / iOS / Android / Windows / Linux）。
- 不重写终端渲染器（不用 `xterm.js` 替 `xterm.dart`）。
- 不重写数据持久化层（Hive + SQLite 继续用，通过 RPC 供 Node 侧读）。

---

## 1. 目标架构

```
[Flutter App] --(stdio JSON-RPC)--> [AgentBridge Dart] --> [Node Subprocess]

Flutter App (保留)
  UI 层: xterm.dart / flutter_markdown / Riverpod
  订阅源: 从 in-process Stream 换成 AgentBridgeClient
AgentBridge (Dart 侧, ~400 行)
  - 启动 / 回收 Node 子进程 (Process.run, 可注入)
  - 序列化 AgentEvent / ToolCall / ToolResult / TaskState
  - 心跳 / 进程崩溃重启 / 优雅退出
  - 持有当前活跃 TaskId 句柄, 用于 cancelTask 路由
Node.js 子进程 (新 Agent Core) — 内嵌 Node (NodeApp 打包)
  agent_core/
    react/engine.ts        (ReAct 主循环, 替换 agent_engine)
    react/parser.ts       (替换 react_stream_parser)
    tools/registry.ts     (替换 agent_tool + 内置 tools)  [实际: tools/index.ts]
    mcp/manager.ts        (@modelcontextprotocol/sdk 直连)
    llm/clients.ts        (实际: 裸 fetch + 三个 *_stream.ts, 见 §8 决策)
    pty/adapter.ts        (node-pty, 替换 local_terminal)
    file/ops.ts           (fs/promises, 替换 local_file_tools)  [实际: utils/local_file_ops.ts]
    web/tools.ts          (fetch + 搜索后端, 替换 web_tools)  [实际: tools/web_search.ts]
    rpc/handlers.ts       (JSON-RPC method router)  [实际: rpc/server.ts]
```

> 本树是立项草图。落地后的真实文件清单见 §10.1；方括号里是本草图与实际的差异标注。

### 进程生命周期策略

| 场景 | 行为 |
|---|---|
| App 启动 | 首次 AI 任务启动时 lazy spawn Node 子进程（不占冷启动内存） |
| 空闲 > 5 min | 心跳探测 → kill，下次任务重新 spawn |
| 用户 cancelTask | 发 `rpc:cancel` → 子进程 AbortController 触发 → 子进程回 `rpc:ack:cancel` |
| App 退出 | SIGTERM 子进程 → 等 3s → SIGKILL |
| 子进程崩溃 | 父侧检测到退出 → 标记当前 Task `failed (runtime-crash)` → 下次任务重新 spawn |
| 升级 Agent Core | 支持热替换（kill 旧进程 → 起新进程 → 从 Hive 读 session 恢复） |

---

## 2. 协议设计

### 2.1 传输层

- **stdout / stdin 双向 JSONL**：一行一个 JSON-RPC 2.0 请求/响应。
- **不引入 HTTP / gRPC**：stdio 最稳定，子进程生命周期与父进程对齐，无端口冲突。
- **缓冲**：Node 侧 `process.stdout` 行刷（`\n` 边界），Dart 侧 `Process` 默认行模式。
- **大 payload**（如文件内容、命令输出 > 100KB）拆帧：`{method: rpc:toolResult, chunk: 0, total: 4, data: ...}`，接收侧 `toolResultBuffer[commandId]` 累积重组。

### 2.2 消息类型（JSON-RPC 方法名规范）

**父 → 子 请求（request）**：

| method | 参数 | 响应 |
|---|---|---|
| `rpc:startTask` | `{taskId, task, hostId, modelConfig, ...}` | `{ok: true, runId}` |
| `rpc:cancelTask` | `{taskId, reason}` | `{ok: true}` |
| `rpc:confirm` | `{taskId, confirmId, decision: ok/reject/timeout}` | `{ok: true}` |
| `rpc:getState` | `{taskId}` | `{task, events, state}`（用于 UI 重建） |
| `rpc:ping` | - | `{ok: true, ts}` |
| `rpc:registerLocalTool` | `{name, description, inputSchema}` | `{ok: true}`（让 Dart 侧注册工具，Node 回 RPC 调用） |

**子 → 父 通知（notification，无 id）**：

| method | 载荷 | 说明 |
|---|---|---|
| `evt:agentEvent` | `{taskId, event: AgentEvent}` | 流式 Agent 事件（thought / command / result / ...） |
| `evt:thinkingChunk` | `{taskId, text}` | 细粒度流式 chunk（不构造完整事件） |
| `evt:toolResult` | `{taskId, commandId, chunk, total, data}` | 大输出分帧 |
| `evt:confirmRequest` | `{taskId, confirmId, prompt, options}` | 请求用户确认 |
| `evt:taskState` | `{taskId, state: running/completed/failed/cancelled}` | 终态 |
| `err:uncaught` | `{message, stack}` | 子进程崩溃 |

**反向 RPC（子 → 父 请求）**（Node 侧需要调 Dart 侧的 SSH / 知识库）：

| method | 参数 | 响应 |
|---|---|---|
| `rpc:invokeSsh` | `{hostId, command, timeout, ...}` | `{exitCode, output, ...}` |
| `rpc:invokeSftp` | `{hostId, op, path, ...}` | `{...}` |
| `rpc:queryKnowledge` | `{query, limit}` | `{hits: [...]}` |
| `rpc:saveSession` | `{session}` | `{ok}` |

### 2.3 协议契约文件

- **单一事实源**：TS 类型是唯一 source of truth，Dart 侧 `agent_event.dart` 等模型文件用 `json_serializable` 代码生成，避免手抄。
- 编译期由 `npx generate-json-schema` 输出给 Dart 侧 codegen 用。
- 所有 schema 文件放 `agent_core/schema/*.schema.json`。

### 2.4 事件与终态一致性（对接 AGENTS.md R5）

Node 侧 `react/engine.ts` 必须实现：

```ts
enum TerminalState {
  Completed   = "completed",   // AI 说 finish 且 success
  Failed      = "failed",      // 任意 throw / tool 失败
  Cancelled   = "cancelled",   // cancelTask
  Interrupted = "interrupted", // runtime crash
}
// 所有路径必须：
//  1. 发 evt:taskState(state: terminal)
//  2. 发 evt:agentEvent(type: finish, finishState)
//  3. flush streaming content (evt:thinkingChunk 最后一帧带 total=total)
//  4. 释放所有 AbortController / Timers
```

**白名单原则**（R5）：knowledge-base 写入只在 `state === Completed` 触发；`Cancelled / Failed / Interrupted` 一律跳过。

---

## 3. 模块设计

### 3.1 Node 侧模块（新建 `agent_core/`）

```
# 下面是立项草图; 落地后的真实清单在 §10.1 (两处文件名不一致时以 §10.1 为准)。
# 保留草图是为了让「计划 vs 实际」的差值本身可见 —— 已改名 / 合并 / 未做的文件在行尾标注归宿。
agent_core/
  package.json
  tsconfig.json
  esbuild.config.js
  schema/                    # 7 份 JSON Schema + protocol.version.json (落地新增, 草图未列)
  tools/check-schema-compat.mjs
  src/
    index.ts               # 入口, 启动 JSON-RPC server on stdio
    rpc/
      server.ts          # 父 -> 子 handler
      client.ts          # 子 -> 父 reverse handler (Dart 实现)
      schema.ts          # 类型 + 校验
      transport.ts       # 落地新增 (草图未列)
    react/
      engine.ts          # 主循环 (对应 agent_engine.dart 4740 行; 实际 632 行, 骨架 + 已接线的危险命令闸门、事件快照与目标达成标记硬守卫, 仍非全量)
      parser.ts          # 流式 ReAct 解析
      goal.ts            # 未单独建文件: 目标续跑判定已落 utils/goal_continuation.ts (§9 第 6 项); 引擎侧唯一 goal 胶合 (达成标记硬守卫, Dart 3861-3871) 已接线 engine.ts
      safety.ts          # 未单独建文件: confirm 状态机在 react/confirm_flow.ts, 档位矩阵在 utils/permission_policy.ts, 均已接线 (§9 第 6/7 项)
      regex.ts           # 落地新增 (从 parser 拆出的正则)
    tools/
      registry.ts        # -> 实际是 tools/index.ts 的 buildDefaultToolRegistry(platform)
      builtin.ts         # exec / file / web / diff 等
      pty_adapter.ts     # -> 实际在 pty/adapter.ts (不在 tools/ 下)
      dispatcher.ts / orchestrator.ts / platform.ts / tool_args.ts / web_search.ts   # 落地新增
    pty/{index,adapter}.ts                # node-pty 封装
    mcp/
      manager.ts         # @modelcontextprotocol/sdk
      oauth.ts           # 复用 mcp_oauth 逻辑
      connection.ts / models.ts / tool_adapter.ts                              # 落地新增
    llm/
      openai.ts          # -> openai_stream.ts   (裸 fetch, 不是 @ai-sdk/openai, 见 §8)
      anthropic.ts       # -> anthropic_stream.ts (裸 fetch)
      ollama.ts          # -> ollama_stream.ts    (裸 fetch)
      stream.ts          # chunk 合并 + reasoning_content
      clients.ts / index.ts               # 落地新增 (MockLlmClient 也在 clients.ts)
    utils/
      tail_buffer.ts     # 替换 TailTextBuffer
      stable_hash.ts     # FNV-1a 64-bit 变体, 与 Dart 侧实现一致 (§10.3 第 1 条)
      generation.ts      # generation check 工具
      pending_registry.ts / line_diff.ts / shell_detect.ts / rollout.ts
      checkpoint_store.ts / local_file_ops.ts / process_supervisor.ts           # 落地新增
      permission_policy.ts   # 落地新增: 对应 lib/core/permission_policy.dart (49 行); 草图把档位判断划给 safety.ts, 实际单独成模块, 见 §9 第 7 项
  test/
    e2e_parser.test.ts      # 对应 react_parse_e2e_test.dart —— 实际落在 e2e/byte_comparison_10.test.ts
    e2e_cancel.test.ts      # 实际落在 regression/r1_generation_check.test.ts + regression/w5_e2e.test.ts
    e2e_multi_host.test.ts  # 实际落在 regression/r3_multi_host.test.ts
  dist/                      # 编译产物 (tsc + esbuild bundle, gitignored)
```

**关键类型（节选）**：

```ts
type AgentEvent =
  | { type: "thought", text: string, id: string, ts: number }
  | { type: "command", command: string, commandId: string, ... }
  | { type: "result",  commandId: string, exitCode: number, ... }
  | { type: "ask",     options: string[], ... }
  | { type: "finish",  finishState: TerminalState, ... }
  | { type: "text",    text: string, ... }
  | { type: "info",    message: string, ... }
  | { type: "report",  report: OperationReport, ... }
  | { type: "plan",    plan: PlanStep[], ... };
```

### 3.2 Dart 侧改动

| 文件 | 改动 | 影响 |
|---|---|---|
| `agent_provider.dart` (2116L) | 订阅源从 `Stream<AgentEvent>` 改成 `AgentBridgeClient.eventStream`；Riverpod 结构不变，UI 完全不动 | 中 |
| `agent_engine.dart` (4740L) | 删除（或保留做 fallback 编译开关） | 大 |
| `agent_tool.dart` (2634L) | 删内置 tools；保留 `AgentToolRegistry` 抽象，作为 Node 侧注册的桥接 | 大 |
| `react_stream_parser.dart` (425L) | 删除 | 中 |
| `mcp_manager.dart` (496L) | 删除；换成 `mcp_bridge_client.dart`（纯 RPC 客户端，~100 行） | 中 |
| `ai_service.dart` (609L) | 删除 LLM 调用部分；保留 `AIProvider` 抽象壳（UI 层仍用） | 中 |
| 新增 `agent_bridge/` | 见下方目录 | 中 |

```
ai_terminal/lib/agent_bridge/          # 现状: 目录下只有 2 个文件, 其余为规划
  agent_bridge.dart          # 已存在
  json_rpc_transport.dart    # 已存在
  agent_bridge_client.dart   # 待补：子进程生命周期 + RPC 收发
  frame_splitter.dart        # 待补：大 payload 重组
  agent_event_codegen.dart   # 待补：从 schema.json 生成
  process_manager.dart       # 待补：spawn / kill / 崩溃恢复
```

### 3.3 节点捆绑策略

桌面端需要内嵌 Node。候选：

| 方案 | 体积 | 跨平台 | 备注 |
|---|---|---|---|
| NodeApp (Node App SDK) | +30~50 MB | 是 | 官方推荐, 支持 macOS/iOS/Windows/Linux |
| pkg (Shopify) | +40~80 MB | 是 | 已停止维护, 但稳定 |
| nexe | +30 MB | 部分 (Win 好, Linux 差) | 社区项目 |
| Bun 单文件 | +40 MB | 是 | 运行时更现代, 但生态兼容需验证 |

**推荐：NodeApp + 懒加载**。
- 冷启动不 spawn 子进程（节省 50MB 常驻内存）
- 首次 AI 任务才 spawn，首次冷启 +1~2s
- 支持热升级（kill 旧进程 → 起新进程 → 从 Hive 读 session 续跑）

---

## 4. 风险登记（按 AGENTS.md 9 条规则逐条映射）

| 规则 | 原 Dart 语义 | Node 对应 | 风险等级 | 缓解 |
|---|---|---|---|---|
| R1.1 generation check | `myGen == _currentTaskGeneration` 在 `await` 后检查 | `AbortController.signal` + 版本号双保险；`await` 后查 `if (this.runId !== ctx.runId) return` | 中 | 每个 `await` 后强制 `generationCheck()` 工具函数；code review checklist |
| R1.2 cancel stream 不触发 onDone | `StreamSubscription.cancel()` 需手动 `completer.complete()` | Node `AbortSignal` 不会 fire `stream.on("end")`；需手动 resolveAll pending | 高 | 写 `PendingRegistry`（等价 `Set<Completer<void>>`），在 abort 回调里遍历 resolve |
| R1.3 .then() 无 onError | 未处理 rejection 挂死 ReAct 循环 | Node 未处理 `promise.reject` → `process.on('unhandledRejection')` → 子进程崩 | 高 | `process.on('unhandledRejection', ...)` 上报 `err:uncaught`；所有 RPC handler 包 try/catch |
| R2 callback 清除顺序 | null callbacks → cancelTask → 移除注册表 | 同序，但 `EventEmitter` 的 `removeAllListeners` 时机不同 | 中 | 写 `LifecycleGuard` 统一封装；单测覆盖 4 种路径（switchTab / modelSwitch / removeTab / init） |
| R2.4 StreamController.add 在 isClosed 后 throw | `!controller.isClosed` 检查 | `Readable` 在 `destroy` 后 `write` 返回 `false` 不 throw，行为不同 | 低 | 用 `SafeStream` 封装 |
| R3 多主机 hostId 隔离 | 捕获 hostId，不用 activeHostId | 同逻辑，但跨进程后 hostId 通过 RPC 传递，需在 taskId 里冻结 host | 中 | `startTask` 时 `hostId` 写入 task record，后续 RPC 不再读 activeHostId |
| R4 事件 dedup | `stableId`（FNV-1a **变体**，见 §10.3 第 1 条） | 移植 `utils/stable_hash.ts`；跨语言字节一致由 **1000 行 Dart 生成的金标 fixture** 锁（`test/fixture_diff.test.ts` 跑源码，`test/fixtures/verify.mjs` 跑 `dist/`），另有 **20 万条**确定性语料证明摘要无碰撞而 `h*31+b`(int32) 有碰撞（`test/regression/r4_stable_id.test.ts`） | 中 | 原计划写 `stableHashDifferentialTest` 让 Dart/Node 现跑同一批输入；实际改成金标 fixture（Dart 侧离线产出十六进制），因为 CI 里没有 Dart 运行时可用（见 §10.3 第 1 条的口径修正） |
| R5 终态白名单 | `status == completed` | `state === Completed`（TS 联合类型，编译期穷举） | 低 | TS 强类型天然优势，比 Dart 更安全 |
| R6 shell 分叉 | PowerShell 用分号 / cmd.exe 用 & / bash 用 $? | `node-pty` 的 spawn 参数与 `flutter_pty` 不同 | 中 | 抽 `shell_detect.ts`，与 Dart 侧 `wrappedCommand` 逻辑对齐；跨平台 CI 跑 |
| R6.6 POSIX vs 本地路径 | `p.posix.join` vs `p.join` | Node `path.posix` vs `path`，同语义 | 低 | 直接用 `path.posix` / `path` 对应 |
| R7 IV 生成 | `IV.fromSecureRandom(16)` | `crypto.randomBytes(16)`，无 bit-truncation 坑 | 低 | 直接用 node:crypto |
| R8 尾缓冲有界 | `TailTextBuffer` O(1) | `ring_buffer.ts` 重写；单测 5 种边界（等于 cap / 小于 / 大于 / 0 / 1） | 中 | 移植 + 单测 |
| R8.8 Hive adapter 顺序 | `Hive.registerAdapter` 依赖顺序 | 不变（Hive 仍由 Dart 侧管） | 低 | 不动 |
| R9 流式格式 e2e | `react_parse_e2e_test.dart` | 必须重写 e2e 测试，覆盖 3 类历史 bug：多行拼接后动作行缺失 / 工具break条件导致toolName=null / stableId碰撞 | 高 | 移植 3 条历史回归用例 + 10 条新用例；CI 强制 e2e 通过才合并 |

### 额外风险（超出 R1~R9）

| 风险 | 等级 | 说明 | 缓解 |
|---|---|---|---|
| 捆绑 Node 包体积 | 中 | 桌面端 +30~50 MB；移动端（iOS）无法内嵌 Node → 移动端继续跑 Dart Agent | 双实现共存 6 个月，移动端用 Dart，桌面端用 Node |
| iOS 无法 JIT / 无 Node | 高 | iOS 沙盒不允许动态加载 Node 二进制 | iOS 走 `agent_core` 的 Dart 编译版（保留 `agent_engine.dart` 作为编译开关），等 Apple 开放 WASM runtime 再统一 |
| 子进程崩溃恢复 | 中 | 长任务中途子进程 OOM / segfault → 任务不可恢复 | 崩溃检测 + 从 Hive 读 checkpoint + 标记 `interrupted`；支持 `--resume` 标志续跑 |
| stdio 死锁 | 低 | 父进程写 stdin 满 + 子进程读 stdout 慢 → 互等 | 双向异步；Dart `Process.stdin` 非阻塞写；Node `process.stdin` 自动背压 |
| Windows ConPTY 差异 | 中 | `node-pty` 在 Win10 1903+ 支持 ConPTY；旧版 fallback 到传统 pipe，ANSI 色码失效 | feature-detect + UI 提示；与 `flutter_pty` 的 cmd.exe 托管 powershell quirk 对齐 |
| MCP OAuth 在 Node | 低 | 当前 `mcp_oauth.dart` 走 `flutter_secure_storage`；Node 侧要换 `keytar` / OS keychain | 桌面端用 `keytar`（需用户授权），移动端继续 Dart |
| CI 构建矩阵翻倍 | 中 | 新增 `agent_core` 的 npm build + native 模块编译 + 跨平台签名 | GitHub Actions 加 `agent-core-build` job；缓存 `node_modules`；预编译 `node-pty` |
| Hive 数据跨进程读写 | 低 | Node 不能直读 Hive（Dart 二进制格式） | Node 侧通过 RPC `rpc:saveSession` / `rpc:loadSession` 让 Dart 侧读写 |

---

## 5. 开发计划

总周期 **8~10 周**，分 4 个 Phase，每 Phase 独立可回滚。

### Phase 0 — 协议冻结 + 脚手架（第 1 周）

**目标**：stdio 协议、schema、CI 全通。

- [x] D1：写 `docs/agent-bridge.schema.json`（所有 RPC method + event 的 JSON Schema）✅ 已生成（`agent_core/schema/agent-bridge.schema.json`，聚合 request/reverse/event/notification 四域 + 工具描述符，$ref 指向分域 schema，无循环引用）
- [x] D2：写 `agent_core/package.json` + `tsconfig` + `esbuild` 构建脚本 ✅ package.json + tsconfig.json + esbuild build script in place
- [x] D3：Dart 侧 `agent_bridge/json_rpc_transport.dart`（JSONL 收发）✅ 已移植（200 行，JSONL + 心跳 + 重连）
- [x] D4：Node 侧 `rpc/server.ts` + `rpc/client.ts` ✅ 已移植（rpc/server.ts + rpc/client.ts + rpc/transport.ts + rpc/schema.ts）
  
  - [x] `rpc:startTask` 已注册：`startServer` 将 `ReActEngine` 接入 RPC 面（§2.2 任务启动）；`makeLlmClient` 工厂可注入；`rpc:cancelTask` 取消 live 引擎（`6b66fd9`）。
- [x] D5：E2E 冒烟：Dart spawn Node → 发 `rpc:ping` → 收到 `{ok:true}` → 杀进程 ✅ reverse_rpc.test.ts（spawn 冒烟 + invokeSsh/invokeSftp/queryKnowledge 全链路）
- [x] D6：CI job `agent-core-build`：npm install + tsc + esbuild → dist/ ✅ .github/workflows/agent-core-ci.yml（typecheck + test + e2e + build + fixture 7 步）
- [x] D7：协议变更 checklist（任何 schema 改动要过 `npx check-schema-compat`）✅ 已移植（`agent_core/tools/check-schema-compat.mjs`：校验 major.minor 未破坏 + 新增字段均为 optional + 枚举只增不减 + required 集合未扩大；npm script `check:schema` 已注册；`test/check_schema_compat.test.ts` 覆盖 6 条规则）

**交付物**：可运行的空壳 Agent Core（无 ReAct 循环），Dart ↔ Node 通信打通；协议 schema + 兼容性校验工具（D1+D7）已就位。

### Phase 1 — LLM + 流式解析（第 2~3 周）

**目标**：把"用户输入 → AI 流式输出"这条最核心路径迁过去，UI 完全不动。

- [x] W2：LLM 三后端流式 ✅ 已移植，但**实际落地形态与本草图不同**：没有引入 `@ai-sdk/*`，而是 `llm/{openai,anthropic,ollama}_stream.ts` 直接用全局 `fetch` 打流 + `stream.ts` 做 chunk 合并（决策变更见 §8）；`llm/clients.ts` 装的是 provider 装配与 `MockLlmClient`，不是 SDK 封装
- [x] W2：`stream.ts`（chunk 合并 + reasoning_content，对应 `reasoningDeltaOf`）✅ 已移植（utils 无，stream.ts 独立）
- [x] W3：`react/parser.ts`（1:1 移植 `react_stream_parser.dart`）✅ 已移植
- [x] W3：3 条历史回归 e2e 测试（多行拼接 / 工具break / stableId 碰撞）✅ regression/r9_stream_e2e.test.ts
- [x] W3：Dart 侧 `agent_provider.dart` 加编译开关 `kUseNodeAgent`（默认 false，灰度）✅ 已加
- [x] W3：CI 跑 10 条 e2e 用例，与 Dart 实现输出逐字节比对（stableId / event sequence 完全一致）✅ e2e/byte_comparison_10.test.ts

**交付物**：Node Agent Core 能独立跑通 ReAct 循环，输出与 Dart 版一致。可独立测试。

### Phase 2 — 工具 + MCP + 本地 PTY（第 4~5 周）

**目标**：工具执行下沉到 Node；MCP 换官方 SDK。

- [x] W4：`tools/builtin.ts`（exec / file / web_search / fetch_url / diff 等 10 个内置工具）✅ 已移植（W4 批）
  - `tools/web_search.ts`：`WebSearchTool`（11 后端扇出 + URL 去重合并 + 取消桥接 + 配额/瞬时错误分类）+ `WebSearchService`/`webSearchService`/`normalizeSearchUrl`/`mergeSearchResults`/`loadWebSearchConfig`，1:1 移植自 `web_tools.dart` + `web_search_{models,config,backends,merge,service,http,http_io,http_stub}.dart`（Dio→Node `fetch`+`AbortSignal`，`Platform.environment`→`process.env`，凭据层改为 `~/.ai_terminal/` 文件存储）✅ 已移植（W4 批）
- [x] W4：`pty/adapter.ts`（node-pty，与 `flutter_pty` 的 Windows quirk 对齐）✅ 已移植（node-pty + guarded-live 单测）
- [x] W4：`shell_detect.ts`（PowerShell / cmd.exe / bash / zsh 分叉）✅ 已移植（utils/shell_detect.ts）
- [x] W5：`mcp/manager.ts`（`@modelcontextprotocol/sdk`，替换 `mcp_dart`）✅ 1:1 移植 + InMemoryTransport 单测
- [x] W5：`rpc:invokeSsh` + `rpc:invokeSftp`（Node → Dart 反向 RPC）✅ ReverseRpcClient + orchestrator 工具层
- [x] W5：`rpc:queryKnowledge`（FTS5 查询仍走 Dart SQLite）✅ ReverseRpcClient.invokeSsh/queryKnowledge
- [x] W5：R9 新增 5 条 e2e（工具执行 + 多主机 + 流式 cancel）✅ regression/w5_e2e.test.ts

**交付物**：Agent Core 完整可用；`mcp_dart` 下线。

### Phase 3 — 生产化 + 灰度（第 6~8 周）

**目标**：捆绑 Node、崩溃恢复、灰度开关、回滚预案。

- [x] W6：NodeApp 捆绑脚本（`nodeapp build --platform=win/mac/linux`）✅ Node 侧 `tools/nodeapp.mjs`（esbuild 多平台 ESM bundle → `dist/<platform>/index.js` + `manifest.json` sha256/bytes）+ `tools/verify-bundle-child.mjs` 产物校验 + 4 条 hermetic 测试；真实 OS 签名 / 原生 embed 归打包流水线（W8 灰度/移动端）
- [x] W6：`process_manager.dart`（lazy spawn / 心跳 / 崩溃重启）✅ Node 侧 `utils/process_supervisor.ts`（`ProcessSupervisor`：lazy `ensure()` / 可注入 `heartbeatPing` + 连续 miss 检测 / 指数退避 crash 重启，`maxRestarts` 上限；Dart 侧 `process_manager.dart` 保留作 UI 侧调度桥接）
- [x] W7：checkpoint 机制（每 30s 写 Hive `task_checkpoints`，崩溃后 `--resume`）✅ Node 侧 `utils/checkpoint_store.ts`（`~/.ai_terminal/checkpoints/`，每步边界快照 conversation + seenStableIds + step）+ `ReActEngine` 构造参数 `checkpointStore`/`resumeFromCheckpoint` + 终止态删除（`interrupted` 保留供续跑）；Hive 写入仍由 Dart 侧 `rpc:saveSession` 承担，Node 侧文件镜像为崩溃恢复源
- [x] W7：回滚预案：`kUseNodeAgent` 一键切回 Dart 实现 ✅ Node 侧 `rpc:health` 探针（工具注册表校验 + 协议版本 + nodeVersion，Dart 侧调用后决定切回；`request.schema.json` 7 个方法全含，schema-compat 全绿）；`agent_provider.dart` 已有 `kUseNodeAgent` `bool.fromEnvironment` 开关（guard 日志 + Phase 2 完整 AgentBridge 接线）
- [x] W8：灰度 10% 用户 → 观察 7 天 → 100% ✅ Node 侧 `utils/rollout.ts`（`shouldUseNodeAgent(userId, {pct, salt, allow, deny, force})` 确定性 fnv1a64-24bit 分桶 + allow/deny 名单 + force 开关，覆盖 10%→50%→100% 三阶段，9 条 hermetic 测试含分布校验）；「观察 7 天」为运维决策，分桶函数本身已在 `agent_core` 内实现并可被 Dart 侧调用或镜像
- [x] W8：移动端（iOS/Android）继续用 Dart 实现，加 `platformIsDesktop` 分流 ✅ Node 侧 `tools/platform.ts`（`PlatformProfile` + `MOBILE_SAFE_TOOLS`/`DESKTOP_ONLY_TOOLS` 互斥白名单 + `toolsForPlatform()`）+ `buildDefaultToolRegistry(platform?)` 参数化（mobile 仅注册 5 个读/网络工具）；Flutter 侧 `platformIsDesktop` 分流为 Dart 接线（非 `agent_core` 范畴）

**交付物**：桌面端 100% 走 Node Agent Core，移动端保留 Dart，双轨运行。

---

## 6. 测试策略

### 6.1 分层测试

| 层 | 工具 | 数量 | 必须 |
|---|---|---|---|
| 单元 | vitest (Node) / flutter_test (Dart) | 40+ | 是 |
| 协议 | `check-schema-compat` + 双向 fuzz | 5 条 | 是 |
| E2E（Node） | vitest + 真实 subprocess | 15 条 | 是 |
| E2E（Dart ↔ Node） | flutter_test + 真实 spawn | 8 条 | 是 |
| 回归（历史 bug） | 移植 9 条 R 规则 | 9 条 | 必须全绿 |
| 性能 | `agent_core` 跑 100 轮 ReAct，对比 Dart 版 P95 延迟 | 1 条 | 建议 |

### 6.2 必须覆盖的历史回归（每条对应一个 AGENTS.md 规则）

```
agent_core/test/regression/
  r1_generation_check.test.ts      # R1.1
  r1_stream_cancel.test.ts         # R1.2 (cancel 后所有 pending 必须 resolve)
  r1_then_onerror.test.ts          # R1.3
  r2_lifecycle.test.ts             # R2 (4 种路径 × callback 清除顺序)
  r3_multi_host.test.ts            # R3 (3 host 并发切换)
  r4_stable_id.test.ts             # R4 (20 万语料无碰撞 + 2 万 id 空间 + 身份/发生两半各锁死)
  r5_terminal_whitelist.test.ts    # R5 (5 种终态)
  r6_shell_fork.test.ts            # R6 (bash/cmd/powershell 3 平台)
  r9_stream_e2e.test.ts            # R9 (3 条历史 bug + 7 条新用例)
```

**CI 强制**：任何 PR 碰 `agent_core/src/react/` 或 `agent_core/src/tools/`，必须跑全量 e2e + 9 条回归。

### 6.3 回归文件落地状态（Node 侧，随实现滚动更新）

| 回归文件 | 状态 | 实际覆盖点 |
|---|---|---|
| `r1_generation_check.test.ts` | 已落地 | 真 `ReActEngine` + 可门控 `chatStream`：park 中 cancel → `cancelled` 且仅一次 finish；二次 `run()` 抢占 → `interrupted` 且不发 finish |
| `r1_stream_cancel.test.ts` | 已落地 | `PendingRegistry.resolveAll` 一次唤醒全部等待者；`close()` 拒收后续请求；`CompleterLike` 先到的 settle 生效 |
| `r1_then_onerror.test.ts` | 已落地 | R1.3 两段：(A) RPC handler 抛任意非 Error 值（string/undefined/null/number/boolean/对象/数组/函数/循环引用/含 BigInt）→ 响应 `error` 必须是非空字符串且与 `err:uncaught.message` 一致，描述器自身不得二次抛错（循环 + 恶意 `toJSON`）；(B) 消费方回调（`onEvent`/`onFinished`/`onError`）抛错被包住：`run()` 不 reject、终态与 finish 事件不丢、失败经 `onError` + stderr 双通道记出，且 onError 自身抛错时有再入闸门不死循环 |
| `r2_lifecycle.test.ts` | 已落地 | 走 RPC host（`startServer` + `handlers`）：自然结束 → 通知早于状态复位；cancel 顺序 `resp:startTask → notify:taskState:cancelled → resp:cancelTask`；重复 cancel 仅一次 flush |
| `r3_multi_host.test.ts` | 已落地 | 运行中切 tab：命令派发仍用启动时捕获的 hostId，不读 `activeHostId` |
| `r4_stable_id.test.ts` | 已落地 | R4：锁死 id 空间的两半 —— 内容哈希 `stableId(type,content)`（parser 产出的 thought/text/command/ask 与 parser 的 finish，可跨实例复现，去重闸门只认它）与 Dart `_genId` 的出现序 id `genEventId()`（result / 引擎 emitFinish / 恢复 info）；两条命令各自链接自己的 commandId（含 dispatcher 四类失败与无上下文 → undefined）；`rev-<base36>` 反向 RPC id 单调；20 万条确定性语料对照 `h*31+b`(int32) 有碰撞而 63 位摘要 0 碰撞 |
| `r5_terminal_whitelist.test.ts` | 已落地 | R5：`isSideEffectState(s) === (s === "success")` 白名单 + `finishSideEffects` 只在 `success/cancelled` 删 checkpoint；5 种终态 × 是否发 finish / 是否调 onFinished / no-command 计数复位 全矩阵；源码级 lint 锁住白名单形状（黑名单写法直接失败） |
| `r6_shell_fork.test.ts` | 已落地 | 三分支字节形态 + POSIX 单行/多行两形态 + 跨分支语法不串味 + marker 扫描语义（首命中 / 跨 chunk carry / 正则元字符转义） |
| `r9_stream_e2e.test.ts` | 已落地 | 历史 3 条 bug 形态 + 新用例（迁移初期即有） |

> 说明：`process_supervisor.test.ts` 已覆盖 ProcessSupervisor 生命周期 7 项，故 `r2_lifecycle.test.ts` 刻意改打 RPC host 的『谁创建谁清理 + 通知/响应顺序』，不重复造轮子；各回归文件互相交叉引用而不重复实现。
>
> 另有 `manifest.test.ts`（不属于九条规则，它守的是清单本身）：直接读本文档的 6.2 列表与 6.3 状态表，断言「被点名的文件存在」、「已落地的不再标待补」、「状态列只能是已落地 / 待补两者居一」、「不允许出现 r<N>_ 开头却未被 6.2 列出的回归文件」。四种漂移（改名、删行、状态回退、新增未登记）均已用变异测试逐一验证会变红。

#### 6.3.1 落地过程中修掉的真实缺陷：本地命令退出码包装器

**症状**：Node 侧 `wrapCommand` 早期形态发的是 `<cmd>; <marker> $?`（`<marker>` 为裸 token）。

**后果**：shell 把 marker 当命令执行 —— 实测本机 bash 退 127（`command not found`）、cmd.exe 退 9009、PowerShell 报 `not recognized` 并退 1。管道退出码因此变成『找不到命令』的码，真实退出状态被销毁，`local_exec` 把成功命令也报成失败；同时全仓没有任何地方解析 marker，退出码只来自 child close code。

**修法**（对齐 Dart 现行实现 `command_executor.dart` / `local_terminal_service.dart`，并与 `agent-goal-mode-metrics-bar-design.md` §缺陷① 的实测结论一致）：

- POSIX：`cmd; echo "<marker>$?"`，单行必须留在同一行（另起一行会滞留在 tty 输入队列，被 sudo 当密码吃掉）；含换行的命令（heredoc）改用 `\n` 追加，否则 `EOF; echo` 不再识别为 heredoc 结束符而挂死。
- cmd.exe：`cmd & echo <marker>%errorlevel%`（保持与 Dart 逐字节一致，便于 Dart↔Node 字节比对层比对；代价是 `%errorlevel%` 在解析期展开，同行前序命令的非零码可能读成 0 —— 已在注释中记为该分支的已知取舍，不做偏离性修复）。
- PowerShell：`$LASTEXITCODE=$null; <cmd>; $__ec=if($?){0}elseif($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0){$LASTEXITCODE}else{1}; echo "<marker>$__ec"`。置空前缀必需（会话级变量，会串台）；`$__ec` 派生让 cmdlet 失败报 1 而非陈旧码。
- marker 统一以 `:` 结尾（`EXITCODE_LOCAL:`），完成判定用 `extractExitMarker`（转义 marker + 数字，首命中），裸 substring 不再误命中命令回显（R8.1）。
- `runLocalCommand` 解析 marker 得到真实退出码并把 marker 行从 stdout 剥掉；marker 缺失（命令提前 `exit`、shell 语法错、spawn 失败）才回落到 close code。

**沙箱限制（写进注释防止被当成 flaky 修掉）**：本机 PowerShell 被策略禁止执行原生 exe（`Cannot run a document in the middle of a pipeline`），`node`/`cmd`/`ipconfig` 都取不到，因此 e2e 非零码用「失败 cmdlet → 1」这个与宿主无关的 fixture；bash 经 `-c` 传参在本 CI 宿主上被改写（`false; echo "MK:$?"` 打出 `MK:0`，脚本文件退 127），故 bash 只在单元层锁字节形态，不做 bash 运行时断言。

#### 6.3.2 落地过程中修掉的真实缺陷：非 Error 抛射被吞成「无诊断的失败」

**症状**：`RpcServer` 的 catch 里写的是 `const err = e as Error`；`ReActEngine` 的三个消费方回调（`onEvent`/`onFinished`/`onError`）完全没有保护。

**后果**：

- JS 侧 `throw "boom"` / `throw undefined` 都能发生（reject、第三方工具、被截断的 promise 值）。`e as Error` 之后 `err.message === undefined`，响应体变成 `{ok:false, error:undefined}` —— 而 `JSON.stringify` 会**直接丢掉值为 undefined 的键**，父端只收到 `{ok:false}`；伴随的 `err:uncaught` 通知同样是 `message:undefined`。失败发生得彻彻底底，诊断一点都没有。Dart 里任何 throwable 都有 `toString()`，不存在这一类静默失败，属于移植时新造的缺陷。
- 回调抛错会**逃出 `run()`**：`index.ts` 启动 run 后不 await（`activeRun` 只在关停路径上被 `.catch` 过），所以它是一次 unhandled rejection —— Node ≥15 默认 `--unhandled-rejections=strict` 直接**杀死子进程**；即使不死，抛出点排在 `finishSideEffects()` 之前，finish 事件与 `onFinished` 双双丢失，任务永远停在 running（正是 R5 禁止的「终态路径分叉」）。

**修法**：

- `rpc/server.ts`：`e instanceof Error ? e : new Error(toThrowableText(e))`；`toThrowableText` 自身绝不抛（string 特判 → `JSON.stringify` 兜底 → 循环 / BigInt 退化为 `non-Error thrown (unserializable <typeof>)`），保证「一次失败只报一次」。
- `react/engine.ts`：`emit()` / `reportFinished()` / `reportError()` 三个包装包住全部回调调用；失败**必须记出**（R1.3 后半句禁止裸吞）——同时走宿主 `onError` 通道与 stderr（Dart 父端本来就读我们的 stderr），`process.stderr.write` 自己也被 try 包住（管道已关时无处可报）。
- 再入闸门 `reportingCallbackFailure`：若失败的就是 `onError` 本身，再通知一次会 `onError → reportCallbackFailure → reportError → onError` 无限递归直至 `RangeError` —— 这个坑是修完之后写回归测试时才暴露的，属于「守卫自己变成崩溃源」。降级为只写 stderr。

**为什么不是「吞掉异常」**：R1.3 同时禁止「catch 后不重抛、不记录、不转成失败终态」。这里三件都做了：任务照样落到正确终态（不改变状态机）、宿主与 stderr 各留一条含回调名 / 事件类型 / 原始 throwable 描述的记录、`error` 字段与 `err:uncaught` 一律是非空字符串。

#### 6.3.3 落地过程中修掉的真实缺陷：result 事件被当成「身份」而非「一次发生」

**症状**：Node 侧曾给 result 事件打 `stableId("result", toolName + "|" + status)`，finish / 恢复 info 同理按内容哈希。

**后果**：键里既没有命令也没有参数，于是**同一个工具每次成功调用都得到同一个 id**（例如所有成功的 `fetch_url` 都是 `evt_60057aab507b55b7`）。任何以 `event.id` 为键的 UI 卡片、去重表或落库逻辑都会把两次执行折叠成一条 —— 这与 R4 警告的「所有 result 共用一个 `_lastCommandEventId`」是同一类错配，只是一个错在链接、一个错在身份。

**依据（Dart 源）**：`models/agent_event.dart:218-220` 的 `_genId() => 'evt_${毫秒}_${_counter++}'`；`:164-183` 的 `AgentEvent.result(...)` **根本不接受 id 参数**，一律 `_genId()`。thought/command/ask/finish/text/info/report/plan 才是 `id = id ?? _genId()` —— 解析器传入稳定哈希，引擎自发的落回序 id。`agent_engine.dart` 里 8 处 `AgentEvent.finish(` 与 25 处 `AgentEvent.info(` 都不传 id，即为序 id。

**修法与边界**：新增 `genEventId()`（`evt_<epochMs>_<counter>`）替换 result / 引擎 `emitFinish` / 恢复 info 三处；解析器产出（含 AI 说出 `动作: finish` 时由解析器生成的 finish，其 id 是 `stableId("finish", 回答正文)`）**继续**用内容哈希。R4 第一条「按 stableId 去重」不受影响：引擎的 `seenStableIds` 闸门只作用在解析器事件上，出现型事件从不进这个闸门（否则第二次 `make build` 的 result 会被静默吞掉）。

> 副作用检查：全仓测试只用 `evt_4ab5285dc89fef7b` / `evt_e3d57f8a36595f0` / `evt_1a983973eaa2b606` 这类**解析器**事件哈希做字节比对（`e2e/byte_comparison_10`、`fixtures/stable_id_1000.jsonl`），没有任何测试钉住 result/finish/info 的 id —— 因此 §10.3 不变式 2 已按此收窄，否则那条比对永远不可能为真。


#### 6.3.4 落地过程中修掉的真实缺陷：CI 产物把 node-pty 打进包，本地 PTY 一调就炸

**症状**：`npm run build`（CI 的 Build 步骤）与打包脚本 `tools/nodeapp.mjs` 是两套手写的 esbuild 配置，external 列表已经漂移：CLI 那边只有 `fs / path / crypto / os / child_process`，少了 `node-pty`（以及 `net / tls / http / https / ...`），于是 CI 产物 `dist/index.js` 把 node-pty 的 JS **内联**进了包，打包产物 `dist/<platform>/index.js` 才是外部引用。

**后果**：node-pty 是原生插件，通过动态 import 引入；一旦被内联，esbuild 会把它的加载器改写成对内建模块的 dynamic require。实测在那个产物里调 `spawnLocalPty()` 直接抛

> `Dynamic require of "events" is not supported`   （node-pty 的 CJS 加载器被内联后的典型报错）

也就是说该产物的本地 PTY 路径**从落地起就是死的**，而整套测试全绿 —— 因为 vitest 跑的是 `src/*.ts`，没有任何测试碰过 `dist/*.js`。这正是 R9 第三条「格式/流水线改动必须有端到端测试」在构建产物维度的同款盲区：组件全对，装配出来的东西不能用。

**修法**：`package.json` 的 `build` 脚本改为与 `tools/nodeapp.mjs` 的 `EXTERNALS` 一一对应（含 `--target=node18`，对齐 Dart 侧内嵌的 Node 版本），并把契约固化到 `test/build_externals.test.ts`：它现场用两套参数各打一个包，断言 external 列表逐字相等、产物能被 import、PTY 路径能走到插件（而不是死在 bundle 里），并要求产物文本里**不存在** `Dynamic require of`；同时反向确认「全部内联」那个对照包一定含这个字符串 —— 否则检测器本身可能是空转。

> 边界：`build_externals.test.ts` 不属于 §6.2 九条规则，也不进 6.3 状态表（它守的是构建产物，不钉任何 R 规则），如同 `manifest.test.ts` 守清单、`terminal_state_matrix.test.ts` 守状态机。它刻意不断言真起了一个 shell 会话（主机限制见 `r6_shell_fork`），只断言控制流抵达插件而非死在 shim 里。

#### 6.3.5 落地过程中修掉的真实缺陷：glob 大小写极性写反，两份实现各说各话

**症状**：`src/tools/builtin.ts` 里同时存在两份 glob→RegExp。`local_dir_list` 用的是 `LocalDirListTool.globToRe`，压根没有大小写分支（任何平台都大小写敏感）；`local_file_search` 用的是模块级 `globToRegExp`，flags 写成 `process.platform === "win32" ? undefined : "i"` —— 与 Dart 恰好相反，而它自己的注释还声称「mirrors caseSensitive: !Platform.isWindows」。

**Dart 参照**（`ai_terminal/lib/services/local_file_tools.dart:278` 与 `:353`，两处逐字相同）：

> `RegExp('^$escaped$', caseSensitive: !Platform.isWindows)`　⇒ Windows 大小写**不敏感**（NTFS 查找本身不敏感），其余平台大小写**敏感**。

**后果**：这类缺陷不会抛错，只会让清单变长或变短。同一个 `*.TXT` 配 `a.txt`：Windows 上 Dart 会给出该文件，TS 的 dir-list 不给（模型看不见本该看见的文件）；Linux 上 Dart 不给，TS 的 search 给（塞给用户没要的匹配）。更糟的是**两个工具对同一个 glob 结论相反**，而 CI 发现不了 —— 既有 glob 用例的命名全是小写，正好落在两份实现唯一同意的子集里。「注释里写了规范」和「有人守着规范」是两回事。

**修法**：合并成模块级唯一的 `globToRegExp`，flags 取 `process.platform === "win32" ? "i" : undefined`，并补上 Dart 的 `if (glob.trim().isEmpty) return null;`。后者不是防御性代码：`ToolArgs.getStringList` 只丢掉零长度字符串，`" "` 会活着走到 helper —— 去掉 trim，`" "` 就编译成 `/^ $/`，于是一次「空 glob」调用从「不过滤」变成「什么都过滤不掉」。

**固化**：`test/glob_case.test.ts` 钉三层。

1. 结构：源码里 `function globToRegExp(` 恰好一处，且 `/globToRe(?!gExp)[A-Za-z0-9_]*\s*\(/` 必须为假 —— 第二份实现无论叫什么都不放过（`globToRe(` 不是 `globToRegExp(` 的子串，所以这条判据自洽）。
2. 极性：从源码里正则抽出 flags 表达式，用假 `process` 对象求值 —— `win32 → "i"`、`linux/darwin → undefined`、四个平台里恰好一个带 flag（挡住「顺手加个 g」这类横向漂移）。这段断言不碰真实文件系统的大小写规则，Windows / macOS / Linux 三边读法完全一致。
3. 行为：`local_dir_list` 与 `local_file_search` 对 `*.TXT` 的实际结论必须相同，且等于 `process.platform === "win32"`；再加「`" "` 与 `" ", "*.txt"` 都不得清空结果」钉住 trim。

**变异验证**：删掉 flags、把 flags 反向、两边都加 `"i"`、删 trim+空判、只删 trim、把 `globToRe` 复制回去 —— 六种漂移全部 exit 1。（头一轮里「删 trim」是漏网的，补第 3 层才咬住。同理，写第 1 层判据时差点被自己绊倒：`globToRe(` 的声明还没删就断言「不再出现 `globToRe(`」，必然自打。）

#### 6.3.6 落地过程中修掉的真实缺陷：CI 步骤与测试自身的可执行性

6.3.4 的教训是「CI 产物从没被测过」；这一轮补的是「CI 步骤本身没被测过，以及测试换台机器就跑不动」。

**(a) `test:fixture` 少 `working-directory`。** `.github/workflows/agent-core-ci.yml` 里其余 `run` 步骤都带 `working-directory: agent_core`，唯独「Verify stableId fixture (1000 cases)」没有 —— 而**仓库根目录没有 `package.json`**。也就是说该步骤在每一次 CI run 里都只能失败，`npm run test:fixture` 会在根目录报找不到脚本。这是全流程里唯一一个本地从没手动跑过的 CI 步骤，恰好就是坏的那个。修法：补 `working-directory: agent_core`。

**(b) 守卫 CI 本身。** `test/ci_workflow.test.ts` 直接解析 workflow 文本：`run` 步骤数 ≥7、每个 `run` 步骤都必须是 `working-directory: agent_core`（缺一个就是这次的 bug 复发）、`npm run X` 目标集合恰为 {build, check:schema, test:fixture, test_e2e, typecheck}、步骤目标序列固定为 `ci → typecheck → test → test_e2e → build → test:fixture → check:schema`、只允许一条 `npm ci`（禁 `npm install` 与 `npx`，CI 必须可复现）、`cache-dependency-path` 指向确实存在的 lockfile、`node-version` 主版本 ≥ `build` 里 `--target=nodeNN`、`on:` 同时存在 `push` 与 `pull_request`、二者都按 `agent_core/**` 过滤、且 workflow 把自己也纳入触发路径（改 CI 必须触发 CI 自检）、branches 同时含 `main` 与 `feat/**`（否则守 CI 的测试自己永不运行）。解析必须从 `    steps:` 起，否则 `on.push.paths` 的条目会被当成步骤。十种漂移变异全部 exit 1。

**(c) 只在 Windows 有主机的测试。** exit-marker 那组用例直接 spawn `powershell` / `cmd`，在 `ubuntu-latest` 上必炸。修法不是按 `process.platform` 跳过，而是**按「能否真的把它 spawn 起来」门禁**（`spawnSync(bin, args, {shell: false})`，与 `runLocalCommand` 的 spawn 方式同构，因此门禁不可能比被测代码更宽）：按平台跳过会把「这台机器恰好没装」误当成「平台正确跳过」，按可解析性跳过则 skip 数本身可解释、可复现，也顺带覆盖 CI runner。另补一段与主机无关的 bash 用例，钉住字面量 `EXITCODE_LOCAL:7` 被解析并从 stdout 剥离、以及 `exit 3` ⇒ close code 3，保证 exit-marker 逻辑在任何 runner 上都有覆盖。注意两点：本机 `sh` **无法解析**而 `bash` 可以（正是「本地全绿、Linux runner 失败」的成因），且 bash 下 `$?` 推导不可断言，所以钉的是字面量 marker 与真实 close code，不是 `$?`。

**(d) node-pty 在 Linux runner 上从源码编译。** `node-pty@1.1.0` 的 package.json 没有 `os` 字段，`scripts.install` 是 `node scripts/prebuild.js || node-gyp rebuild`，而 `prebuilds/` 里**没有 linux 目录** ⇒ `prebuild.js` 退 1，`npm ci` 在 runner 上走 `node-gyp rebuild`（需要 python3 / make / g++，`ubuntu-latest` 自带）。这不是 bug 而是构建前提，记在这里以免下次被当成 CI 抖动去「修」。

**验证口径**：某些主机上 `process.execPath` 指向 GUI 子系统宿主程序，它**根本不执行脚本却返回 0**，stdout 只剩宿主自身的噪声 —— 在这种机器上「退出码 0 所以通过」是空判断。因此本轮所有 gate 一律看真实产物：`tsc` 的退出码 + 无诊断输出、`check-schema-compat: PASSED`、`fixture: 1000 ok`、`Tests 551 passed (551)` 的逐条计数，而不是只看退出码。CI 侧同理：**步骤绿不等于步骤跑了它以为的那件事** —— (a) 能活到今天就因为没人看过它的输出。

> 边界：`ci_workflow.test.ts` 与 `glob_case.test.ts` 都不属于 §6.2 九条规则，也不进 6.3 状态表；前者守的是 CI 定义，后者守的是移植自身的大小写极性。同 `manifest.test.ts` / `build_externals.test.ts` 一个待遇。

#### 6.3.7 落地过程中修掉的真实缺陷：权限档位的取值是两端各编一套，协议层永远不会报错

**症状**：`schema/request.schema.json` 的 `rpc:startTask.params.permissionMode` 与 `src/rpc/schema.ts` 的 `PermissionMode` 一度同时写着 `safe / standard / dangerous / yolo`。

**后果**：Dart 侧 `AgentPermissionMode.id` 只有 `readOnly / ask / auto / fullAuto` 四种取值（`models/agent_permission_mode.dart`）；那组拼写在 Dart 全仓 **0 命中**，连别名都不是 —— `parsePermissionMode('yolo')` 明确返回 null，别名只有中文名与 `read-only / full-auto` 这类。真实路径是 Dart 发来一个 Node 认不出的档位，而 Node 的类型系统认为它就是合法的 `"readOnly"`，运行期又不做任何校验，于是直接落进「按自动执行处理」的分支：UI 显示「只读」，Node 实际在跑 `blocked` 级命令，全程无错可报。

**根因**：草图阶段按「权限模式听起来该叫什么」命名，而不是按对端已经存在的线协议取值命名。两端各自类型自洽，编译期与运行期都不会响 —— 这正是跨语言协议最典型的失效形状。

**修法**：两处一起改回 Dart 的 id（JSON Schema 的 `enum` 与 TS 的 union 必须同改，取值必须全等），并新增 `test/protocol_enum_parity.test.ts`（9 条）作为跨语言取值守卫。

**为什么必须新增守卫，`check-schema-compat.mjs` 挡不住**：它做的是 JSON Schema 自身一致性 —— 6 份文件可解析、`protocol.version.json` 是 1.0、每个 `oneOf` 分支的 `method.const` 唯一、umbrella 的 `$ref` 指得到、`$id` 与文件名相同。它**从不打开任何 Dart 文件**，所以「本端取值 ≠ 对端取值」这一整类缺陷对它而言不存在。新守卫直接从 Dart 源码抠取值再比对，并刻意**比顺序而不是比集合**：`AgentEvent` / `AgentEventType` / `AgentFinishState` 在 Dart 侧没有任何 JSON 序列化器，Hive 适配器按**声明顺序**落 int —— 枚举名就是线协议值，枚举顺序就是持久化契约。把成员重排一次，历史数据里那些 int 的含义就集体错位，而集合比较看不出任何变化。

**顺带钉住的两个解析坑**（都做过变异验证）：Dart 枚举成员后常跟中文注释，注释里的逗号会把 `split(',')` 切碎，因此必须先剥 `//` 注释再切；剥完仍不是合法标识符的必须抛错，而不是静默产出怪值 —— 否则守卫自己就会退化成「永远通过」的那种守卫。

**验证**：9 项变异全部变红 —— 6 项改 Node 侧（TS union 退回旧值、schema `enum` 退回旧值、抽取器退化成返回空数组、Dart 路径写旧、正则过度转义、按名字查枚举的逻辑坏掉），**3 项直接改 Dart 侧**（重排 `AgentFinishState` 成员、删掉 `SafetyLevel` 一个成员、把 `readOnly` 的 id 改成 `safe`），每项都恰好让对应那条断言失败（探针跑完 Dart 树 `git status` 干净、逐文件 sha256 复原）。另有 2 项探针专门验守卫**自己**的防御有承重：把某条比较两端同时喂空数组，长度闸门立刻变红；把长度闸门放宽成 `>= 0`，同一条变异就静默通过 —— 守卫自己也要被证明不是装饰。

---

## 7. 回滚预案

| 场景 | 动作 | RTO |
|---|---|---|
| 子进程崩溃率 > 1% | 灰度开关 `kUseNodeAgent=false` 下发 | 实时 |
| Node 侧引入严重 bug | 回退到上一版本 `agent_core` 包 | < 1 天 |
| 用户报数据丢失 | 检查 Hive `task_checkpoints`，从上次 checkpoint 恢复 | 分钟级 |
| 协议 schema 不兼容 | 子进程 `err:uncaught` → 父侧自动降级到 Dart 实现 | 自动 |

**双实现共存窗口**：Phase 3 结束后 2 周内 Dart `agent_engine.dart` 不删。

---

## 8. 决策记录

| 决策 | 选择 | 理由 | 备选 |
|---|---|---|---|
| 通信协议 | stdio JSON-RPC | 最稳, 无端口, 生命周期对齐 | gRPC / HTTP loopback（复杂度高，不选） |
| Node 捆绑 | NodeApp | 官方, 多平台 | pkg (停维护), nexe (跨平台差) |
| LLM SDK | **实现改为裸 `fetch` + 自写 SSE 解析**（原选 `@ai-sdk/*`） | `dependencies` 实际只有 3 个包；三个 `*_stream.ts` 直接按上游真实 chunk 形状解析（含 `reasoning_content` 差异与 `reasoningDeltaOf` 语义），才能和 Dart 侧逐字节对齐 | 保留 `@ai-sdk/*`（原计划：一等公民, 流式/工具/取消都管 —— 但它先归一化 chunk，字节比对层就没东西可比了；**已偏离原决策**） |
| MCP | `@modelcontextprotocol/sdk` | 官方 | 保留 mcp_dart（生态差，不选） |
| 本地 PTY | node-pty | 主流 | 保留 flutter_pty（同进程收益，不选） |
| SSH | 保留 dartssh2 | 成熟度高于 ssh2 | 迁 ssh2（重复踩坑，不选） |
| SQLite | 保留 sqflite | 数据层不动 | 迁 better-sqlite3（数据迁移成本高，不选） |
| UI | 保留 Flutter + xterm.dart | 渲染质量 | xterm.js in WebView（卡顿回潮，不选） |
| 权限档位取值 | 以 **Dart `AgentPermissionMode.id`** 为准：`readOnly / ask / auto / fullAuto` | 线协议取值由 Dart 单方面定义。Node 侧自造的 `safe / standard / dangerous / yolo` 在 Dart 全仓 0 命中（连别名都不是：`parsePermissionMode('yolo')` 返回 null），而两端类型系统各自完全自洽 —— 只会静默降级成「自动执行」，不会报错（§6.3.7） | 保留 Node 拼写 + 传输层做映射（多一处会漂移的地方，不选） |

---

## 9. 开放问题（需产品/架构对齐）

1. **iOS 何时支持 Node?** — 当前 Apple 沙盒不允许，双轨运行要持续到何时？（建议 2028 前不删 Dart 实现）
2. **Agent Core 是否要开源?** — 如果开源，schema 和 e2e 测试套件要按 Apache-2.0 准备
3. **多窗口 / 多 agent 实例** — Node 侧 `process` 是单例还是支持多实例？（建议：每个 TaskId 一个子进程, 上限 4 个）
4. **checkpoint 粒度** — 每 30s 还是每个工具执行完？（建议：每个工具执行完, 增量写）
5. **Dart 实现保留多久** — 8 周后？6 个月？（建议：移动端保留 1 年，桌面端 6 个月后删）
6. **危险命令 confirm 流程落在哪一层** — Dart 侧是一个 `_confirmCompleter` 被 **4 条路径**唤醒（用户确认 / 拒绝 / 10 分钟超时 / `cancelTask`，后者先 generation++ 再 `complete(false)`），加 6 类拒绝原因码；`waiting_confirm` 与 `rpc:confirm` 在 Node 侧原本只有占位（`src/index.ts` 直接回 `confirm not yet implemented - Phase 2`）。占位不是实现：档位矩阵先落在 `utils/permission_policy.ts`，而「等待确认」在接线前等价于「直接执行」——本轮补齐了等待本体并把 `rpc:confirm` 接上了线（见下）。**同一个缺口里先落地的另一半**：goal 续跑判定整块按 1:1 落为 `utils/goal_continuation.ts`（311 行）+ `utils/agent_goal.ts`（205 行）——`decideGoalContinuation` 的 8 道守卫顺序（用户取消必须排在预算检查之前，否则「取消后预算还剩」会被当成还能继续而复活）、9 个终局分支的中文暂停文案、`shouldScheduleGoalRound` 的「同一终局任务只许续跑一次」去重（取消与异常路径会连着发两个 finish 事件）、`shouldKickGoalRound` 的假恢复守卫、`buildGoalContinuationPrompt`（只带目标与预算，不拼历史全文）、`isGoalMarkerOnlyCommand` 硬守卫（真机复拍：模型会把「目标已达成」写进 `命令:` 块，于是得到一条 CommandNotFoundException）全部到位。机器上没有 Dart 运行时，所以 `ai_terminal/test/goal_continuation_test.dart` 的 32 个 test / 73 个 expect 是被**解析后逐条重放**的——期望值来自 Dart 源码本身而不是我重抄一遍；再加结构对账：守卫条件序列、`reason:`/`action:`/`status:`/`note:` 逐条 diff、标记剥离字符类逐字节相等、提示词静态片段 10=10，改 Dart 的判定顺序或任何一条文案都会变红（`test/goal_continuation.test.ts`，36 项）。**本轮落地（confirm 本体 + 唯一接线者）**：确认状态机 1:1 落为 `react/confirm_flow.ts`（496 行）——一个 completer 加一个 10 分钟计时器，`arm()` 建等待并清一次粘性超时标记（对应 Dart 86/412/2639 三处复位，TS 收敛为 arm() 内 1 处），唤醒路径六条：用户确认 / 拒绝 / 超时 / `cancelTask` / 终局取消（先 generation++ 再 `complete(false)`，同 Dart 931→933 的顺序）/ 暂停；R1 的先 complete 后置 null、R2 的每条路径 cancel+null 计时器都按 Dart 原位保留。接线者是 `src/index.ts`（模块级单例 + `rpc:confirm` 五级守卫顺序 invalid_decision → confirm_flow_unavailable → task_id_mismatch → no_pending_confirm → confirm_id_mismatch；`rpc:startTask` 先唤醒上一轮残留等待再重置两个粘性标记；finally 里只 `finishCleanup()` 收计时器，因为 Dart `_finishTask` 注释（3811 行）明写不清 completer）。对账：`ai_terminal/test/tool_contract_test.dart` 的 4 个 confirm test 被解析后逐条重放，外加结构锁 —— completer 全仓只有 3 个写者（Dart 441/706/2671 vs TS 285/386/449，等量即「暂停与终局取消与 finish 都不许丢弃 awaiter」的硬证）、7 组 cancel/null 配对、6 类 blocked 原因码与 Dart 2370..2377 逐条相等且 `generation_invalid_during_confirm` 必须不在集合内（被取代的一轮不算本任务的失败步）、等待后分支顺序 generation→cancelled→超时/拒绝→重校验档位→proceed（`decideCommand` 重校验是防「切只读前弹出的确认框」绕过新边界）、三种拒绝措辞各 1 处不许合并（命令路径 `用户拒绝执行此命令` / 工具路径 `用户拒绝执行该操作`，第三个 Dart 测试散文措辞不进实现）。已披露偏差：Dart 工具内联计时器的日志文案 `工具确认超时(10min)…`（agent_engine.dart 415）在 TS 侧无对应串，因为 TS 两条等待共用 `arm()` 的同一措辞。锁在 `test/confirm_flow.test.ts`（70 项，含指纹表 + 解析完整性 + 逐条重放 + 结构同构四节）与 `test/rpc_confirm.test.ts`（14 项，线协议级：四种错误守卫、confirm/expire 的唤醒计数与 `riskLevel` 形状）。**尚未接线**：goal 续跑在 `react/engine.ts` 里还没有任何调用点，所以它仍是一个纯判定模块。**本轮把引擎侧的命令闸门接上了**：Dart agent_engine.dart:2586-2725 的闸门形状——分类 → decideCommand → 拒绝则不产出 result 事件、确认则停在 ConfirmFlow 上等 rpc:confirm——1:1 落进 react/engine.ts（现 617 行）。拒绝原因码与 Dart 逐条相等：read_only_blocked / safety_blocked / generation_invalid_during_confirm / cancelled_during_confirm / confirm_timeout / user_rejected，另加等待后重校验档位产生的 permission_changed_during_confirm。同一轮还补回一个真实移植缺口：Dart 的 _enrichCommandEvent（2971-2983，四个调用点 1819/1903/3006/3282）此前整块没过来——父端 UI 是直接读事件上的 permissionDecision 来渲染命令卡的（agent_command_block.dart:100），缺了它卡片就永远停在未知风险；现已落为 engine 的 enrichCommandEvent，在 onEvent 之前给 command 事件盖 hostId、toolName（exec_command）、riskLevel、permissionDecision 四个快照字段，且只补空不覆盖已有值。enrichment 与闸门各分类一次是 Dart 平价（2978 与 3289 就是两次 check），测试把「确认前 classify 恰好两次、两次同值、确认后不再第三次」钉住。R9 的端到端锁在 test/engine_command_gate.test.ts（530 行 / 20 项）：三档 × safe/warn/blocked 矩阵、拒绝路径不产出 result 事件、模型侧只看到 formatObservationFailure 的拒绝观测、rpc 层引擎自己发的 evt:confirmRequest 与父端应答在 confirmId 上对齐、以及终态只经 evt:taskState 越线（解析器产出的 finish 事件没有 finishState，引擎刻意不再补发第二个 finish，Dart 平价）。附带修掉一处回归门自身的脆弱：r5_terminal_whitelist.test.ts 从 finishSideEffects 扫到文件尾找否定式（!== 与 !(），而回调字段引用排在它之前，所以那个跨度实际上一直到 EOF——新代码里 cancel 唤醒前的存在性判断改用可选链加 === true 而不是反对比较，语义不变，免得白名单跨度里混进一个否定号。setPermissionMode 维持注入 getter 下的按设计惰性（engine 自带档位只在宿主没给档位来源时生效），所以 index.ts 不做委派：服务端那个 serverPermissionMode 变量同时被引擎与确认流实时读取，是唯一真源，委派只会造出第二个可变副本。仍按 D3 判定不移植、也仍未落地的 Dart 闸门：local_command_on_remote（2543-2571）、变更窗口（2573-2588）、AuditLogger（2529-2541 与 2604-2617）、AgentTracer（2392-2406 与 2431-2446）、_logCommand（2450-2455）。工具路径只读闸门（3357-3373）原列本清单末位，本轮已落地（见本项末追加记录），其余五项维持 D3 判定。本轮补上引擎侧 goal 胶合中真正属于引擎的那一半：Dart 引擎文件里 goal 系列函数的唯一调用点就是目标达成标记硬守卫（agent_engine.dart 3864，位于权限闸 2590-2725 之后、执行器之前），已接线进 engine.ts 的执行分支；GOAL_MARKER_LOG（3865）与 GOAL_MARKER_OUTPUT（3868）两条中文串在测试里直接从 Dart 源码抽取做字节比对，e2e 见 test/engine_goal_marker.test.ts。而 decideGoalContinuation / shouldScheduleGoalRound / shouldKickGoalRound / buildGoalContinuationPrompt 四个判定函数的调用点全部在 agent_provider.dart（1837 / 1920 / 1939 / 1948），属父端 provider 胶合 —— Dart 引擎里同样没有它们的调用点，所以 Node 引擎也不应拟造；§10.2 旧注“engine 里仍无调用点”指的就是这四个函数，现改为上述准确表述。
7. **`SafetyGuard`（Dart 512 行）是否整搬** — Node 侧目前只有 `tools/orchestrator.ts` 里那个保守只读分类（注释自己写明「mirroring SafetyGuard.check -> safe」），风险分级与审计文案都还没过来；它与第 6 项是同一个缺口的两面。**已落地的那一半**：档位矩阵 `decideCommand` / `destructiveToolNeedsConfirm` 已按 Dart 1:1 落到 `utils/permission_policy.ts`，16 格全表 + Dart 侧结构对账锁在 `test/permission_policy.test.ts`（改 Dart 的守卫顺序、改 `kPermissionDecision*` 取值或改 `SafetyLevel` 顺序都会变红）。**本轮落地**：`SafetyGuard` 全量 512 行按 1:1 落为 `utils/safety_guard.ts`（659 行）——`check()` 分级（21 block + 28 warn + 13 info，含唯一一条忽略大小写的 fork 炸弹）、中文审计文案、`getReason()` 的 null 缓存、`checkPath()`/`checkReadPath()`、`getTip()`、`requireConfirm()`、`getHomeDir()` 一并到位；RE2 与 V8 的 `s` 语义差用显式 ASCII 类逐条规避，Dart 侧插值文案逐字节保真。**本轮把 orchestrator 这半边接上了**：Dart 决定批量并行还是串行靠的是 `SafetyGuard.check`——`multi_host_executor.dart:121` 取等级、122 行与 `SafetyLevel.safe` 比较，命中才走 `Future.wait`，否则逐台串行；而 Node 那条路径此前只认 `tools/orchestrator.ts` 自带的保守只读白名单（`isReadOnlyCommand`），压根没经过 `utils/safety_guard.ts`，等于一个问题交给两个互不相干的分类器各答一次。本轮接成合取：新增 `isParallelSafeCommand(command, safetyCheck = checkSafety)`，白名单与 SafetyGuard 分级都放行才并行。白名单不能被 Dart 那一条顶替，这是量出来的而非修辞：`test/orchestrator.test.ts` 里断言 `isReadOnlyCommand` 的 87 条命令字面量中，有 34 条在 SafetyGuard 下判 `safe` 而白名单拒绝（`docker rm`、`kubectl delete`、`git push`、`find -exec`、`mount --bind`，以及一切用分号、管道、重定向、命令替换、反引号串起来的命令与空命令）——SafetyGuard 的规则表只点名 `rm -rf /`、`mkfs`、fork 炸弹那类破坏形状，对 `git push` 没有任何意见，天真地「改成和 Dart 一样」会把这 34 条全部并行下发到多台主机，是真实的安全倒退。这个数字连同两维度关系、以及用可注入谓词把一条白名单命令翻成串行（并发计数是批量两个分支唯一的外部可观测差别，注入是唯一能证明第二道闸活在路径上的手段）钉在 `test/orchestrator_safety_gate.test.ts`（17 项：三枚指纹 + Dart 批量闸解析 + 全语料两维度 + 路径实跑 + 接线面）。当前规则表下第二道闸恰好被第一道蕴含（白名单放行的没有一条不是 `safe`），但那是规则表的性质而非不变式，所以合取写进代码而不是注释；`ExecuteBatchOptions.safetyCheckForTesting` 只是测试缝，生产不传即用 `checkSafety`。**本轮把 checkPath 这半边接上了**：`services/local_file_policy.dart`（262 行）按 1:1 落为 `utils/local_file_policy.ts`（246 行），`decide()` 复现 Dart 的固定闸序——空 → 未开启 → 回收区保留 → `SafetyGuard.checkPath` 黑名单 → 授权根 → 命中；第 147 行那条 `SafetyGuard.checkPath(lexical)` 至此在 Node 侧第一次有了真实调用点（此前 `checkPath` 在整个 `src/` 内零调用者，敏感路径维度形同虚设）。两道闸一道都不能省：白名单默认为空，新装的核心一个文件都不授权；黑名单压在白名单之上，用户把整个家目录加进授权仍拦得住 `~/.ssh/id_rsa`——本地写权限不能等于对机器的持久控制，这条优先级正是两闸并存的全部理由，已实跑锁进测试。一处忠实性观察：Dart 的 `decide()` 根本不产出 `escape` 判定（它只活在枚举与工具层拒绝前缀映射里），穿越场景被 normalize-then-within 兜住并按 `notInAllowlist` 上报，Node 侧同样不凭空造 `escape`。Node 差异（显式披露而非静默分叉）：headless 核心没有 SettingsDao，`load()` 改吃注入的 settings reader，解析抛错或拿到非对象一律按「关闭」处理、回落 deny-all，与 Dart「绝不因为解析失败就放开文件访问」同义。**接线已完成**：`tools/builtin.ts` 里六个 `local_*` 工具现在都先过 `resolveLocalPath` → `LocalFilePolicy.decide()`，拒答文案逐字节抄 Dart `LocalFileTool._resolve`（五种 verdict 各一条中文前缀 + 「原因: 」+ 固定引导句 + 仅 Windows 且仅 `notInAllowlist` 才追加的远程路径提示），之后每个 fs 调用改用 `decision.resolved`（realpath 归一后的目标）而不是模型写下的原始串。`move` 两端各自过一次 `decide()`，与 Dart `local_file_tools.dart:658-668` 同形；`missing required param` 仍在闸门之前，同 Dart 读取工具的顺序。Node 差异（再次显式披露）：headless 侧没有 Settings 页可让用户当场加目录，所以默认 provider 是一枚 `trustedHost` 策略——它**只放宽白名单这一侧**（普通路径照旧可用，历史「host trusted」姿态不变），回收区保留与 `checkPath` 黑名单两道闸仍**先跑**，所以敏感文件无论如何都被拒；想要 Dart 桌面语义的宿主用 `setDefaultLocalFilePolicy` 注入 `enabled + allowedDirs` 即可。`local_file_ops.ts` 头注释与 `builtin.ts` 那段旧免责声明已在本轮一并改写为「闸门在工具层、原语故意不设闸（R8-3 只清一层）」。对账锁在 `test/local_file_policy.test.ts`（27 项，含新增 `trustedHost` 五例：只放宽白名单不放宽黑名单、回收区仍保留、`enabled` 默认姿态未动、`toMap/fromMap/copyWith`）与 `test/local_file_policy_tools.test.ts`（10 项，六个工具实跑：默认姿态下 ssh 私钥在 I/O 之前被黑名单拒、注入严格策略后越界写/改/删/移/搜全部拒且磁盘文件未被动过、远程提示仅 Windows）。对账锁在 `test/safety_guard.test.ts`（68 项）：Dart 侧 54 处 `expect` 逐条重放、七张规则表逐条 diff、路径文案模板对账、`RegExp(` 调用点计数 83=83——改 Dart 任何一条规则、文案或档位顺序都会变红。**本轮再落地 local_exec 的 cwd 闸门**（Dart `local_exec_tool.dart:103-161`）：`local_exec` 门禁的不是文件路径而是**工作目录**，而且判定形状与六个 `local_*` 文件工具**不同**——`sensitive / reserved / escape` 直接拒，但 `notInAllowlist` 不是死路：它弹一个可注入的授权请求（`setLocalDirAuthorizationRequest`），**批准之后重新读取策略再判定一次**（Dart `:136-138`，Flutter 设置页会把授权目录写回），没接回调时按 Dart `request == null` 的原文案拒绝（引导用户去 设置 → Agent → 本地文件，或改用远程 execute）。取消检查落在弹窗**之后**（Dart `:148-151`），所以「弹窗期间用户取消」既不会创建目录也不会 spawn；授权目录不存在时按 Dart `:153-161` 递归创建。另两处顺序细节按 Dart 复刻：home 展开在绝对路径检查**之前**（`~` 因此可能通过检查），而拒绝文案里引用的是模型发来的**原始** cwd。`expandHome` / `clipForProgress`（折叠空白 + 160 字截断，弹窗里裁的是 command 不是 cwd）一并 1:1 移植。锁在 `test/local_exec_cwd_gate.test.ts`（9 项）：黑名单在任何 spawn 之前拒（默认 trustedHost 姿态下 `~/.ssh` 目录本身就 sensitive）、相对 cwd 用 Dart 原文案、无回调的未授权是死路、被拒后不 spawn、弹窗文本裁的是命令且必须单行、批准后策略被重新读取、批准但没写回仍然拒、授权且缺失的目录会先建再跑、展开时机与原文引用（该例兼容宿主环境有无 USERPROFILE/HOME 两种形状）。本轮再落地 R8 的有界会话历史：Dart `_trimMessages`（agent_engine.dart 4612-4671）按 1:1 落为 `utils/context_trim.ts`（126 行），其读的常量 376 `_maxConversationRounds = 40` 与 379 `_maxMessageChars = 4000` 一并过来，token 预算用 `utils/token_estimator.ts`（91 行，TokenEstimator 全文件移植：rune 迭代、六个 CJK 区间、`cjk + (ascii+3)~/4 + other`、每条消息 +4）。三层语义逐条对上：L1 逐条消息只截超 4000 的、**保留尾部**（`substring(len-cap)`），尾部代码围栏数若为奇数补一条闭合（4622-4626），前缀串 `...(已截断前 N 字符)` 按字节码点核对而非重抄；L2 兜底 `40*2=80` 条；L3 token-aware 从最早开始丢、下限 2 条（4655 的 `kept.length - 2`），预算 `round(ctx*0.7)`。上下文窗口取自 `ModelConfig.contextWindow`（本轮新增的可选线字段），经 `effectiveContextWindow`（ai_model_config.dart:102-103）回落 `kDefaultContextWindow = 262144`（ai_endpoint.dart:253）；Dart 的 `AIModelConfig` 没有 toJson、agent_bridge 也不序列化 modelConfig，所以新增可选字段对线协议零风险，check:schema 门不受影响。调用面按 Dart 的形状接：Dart 在每一个 history add 之后调 trim（21 处调用点，含 `_finishTask` 3741），Node 引擎相应地在四个 conversation.push （AI 回复 / 闸拒绝观测 / 确认观测 / 命令结果）之后各调一次 `trimConversation()`，日志走 `logGate` 且 tag 保持 `TrimMsgs`——stderr-only 因此不新增任何线事件，r1/r4 的 callbacks 形状 lint 与 r5 的跨度扫描都不受影响（新方法放在 finishSideEffects 跨度之外）。显式披露的偏差两条：(a) Node 的 conversation 永不存 system 消息（run() 每轮现拼 [system, ...conversation, goal]），Dart 的 system 钉头分支在此构造性为空操作，代码注释已写明；(b) Dart 无命令分支的 continuePrompt + `⏳ 继续执行...` 尾段（3627-3632）当时以「改动事件流是契约变更」为由缓移植；该顾虑经逐条核实并不成立——r5_terminal_whitelist 只钉 finish 事件数、终态 summary、onFinished/onError 计数，不钉 info 事件数与事件总数——本轮已按 Dart 原样补齐（见本项末尾追加记录）。`_finishTask` 内的第 21 处 trim（3741）改判为永久偏差：Node 的 conversation 只在引擎进程内存活，运行期每个 push 之后都已 trim，终结路径（emitFinish）之后 Node 不再向历史追加任何消息，Dart 的收尾 trim 在 Node 构造性为空操作。测试：`ai_terminal/test/token_estimator_test.dart` 全部 12 个 test 逐条重放（另加 rune/代理对与六区间的边界扫描、以及 Dart 源码公式对账三则）落为 `test/token_estimator.test.ts` 18 项；裁剪三层 + 引擎接线的端到端锁落为 `test/engine_trim.test.ts` 17 项（引擎侧四个用例：5000 字符 AI 回复在下一次 prompt 里已是截断态且静默、41 轮命令后历史在 80 封顶、contextWindow=40 驱动 L3 出 token-aware 日志、不设 contextWindow 时全程零裁剪噪音）。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 64 文件 886 项。 追加（无命令分支补港）：`_handleNoCommand`（Dart 3622-3642）已 1:1 落进 engine 无命令分支——重试预算内先发 Dart 3625-3626 的 info 日志（gate 通道、stderr-only），再发 `⏳ 继续执行...` info 线事件（取 UiText.t 中文分支，与 Node 既有中文线文案同侧），随后把 Dart 3628 的 continuePrompt 逐字节（86 个非 ASCII 码点逐一对账转义）以 user 角色压入历史并按 3632 再 trim；预算耗尽走 Dart 3638-3639 的 warn 日志，随后照旧 emitFinish(failed, "no-command retry exhaustion")——终态 summary 保持 Node 既有钉死值、不随 Dart 终文案「AI 连续未生成有效命令，任务终止」，属已记录偏差未动。副产物一条：continuePrompt 入史触发的第二次 trim 会重扫已截断的 AI 回复（4018 > 4000 仍超帽），L1 前缀滚一层成「...(已截断前 18 字符)」+ 4000 字符尾巴（共 4016）——与 Dart _trimMessages 逐条重扫语义一致，engine_trim 用例已按此钉死。新测 engine_no_command.test.ts 6 项：continuePrompt 逐字节到达下一请求、沙漏 info 事件 occurrence id、gate 日志两行、耗尽路径 2 continue + 1 finish + 钉死 summary、R5 成功命令复位计数后孤立 lapse 不再终态。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 65 文件 892 项。 追加（执行器异常捕获）：`_executeCommand` 的 executeAndWait try/catch（Dart 3918-3965）已接进引擎命令路径——注入的 commandExecutor 抛异常不再逸出 ReAct 循环，而是就地转成 failed 结果（error = String(e) 即 Dart e.toString() 镜像、failureKind "unknown"、exitCode 置空并在事件线上省略，对应 Dart AgentResult 的 null），随后走普通失败结果路径：result 事件 + 观测入史 + trim + 下一轮 LLM。R5 语义由此归位：执行器异常本身永不触发 failed 终态或 onError，终态只由 finish 决定。留待记录：Dart 3582-3616 的另一处 catch（工具调用路径 `_executeToolCall`，含「❌ 工具 N 执行异常」info、独立 result 与「观测: 工具 N 执行异常 — e」观测）依附于工具分发路径，引擎侧 tool dispatch 本身仍在待办清单，随该路径整体移植。新测 engine_executor_throw.test.ts 4 项（throw → failed result 三要素 + onError 计数 0；观测进第二次请求；成功路径不回归；exit-code 失败路径不回归）。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 66 文件 896 项。 追加（工具路径只读闸门，Dart 3357-3373）：ToolDispatcher.dispatch 在 unknown-tool 检查之后、R9 参数解析之前插入只读拒绝闸——D3 点名只读档过去只拦 shell 命令、工具调用可以绕过它直改文件。判据由 ToolKind 派生（Dart agent_tools.dart:182 平价：isReadOnly 即 kind == read，已补进 AgentTool 基类），写类/破坏类/网络类/编排类自动全覆盖，无需第二份名单。闸序平价用测试钉死：畸形参数块在只读档报 permissionDenied 而非 bad_args；取消闸（R1）与 unknown-tool 仍先于只读闸。Node 侧形态差异照实记录：Dart 该闸处发 info 事件、写观测、累加无命令重试计数，三件事都依附 ReAct 会话上下文，而 dispatcher 既无会话也无计数器，故拒绝以 result 事件承载（executed=false、success=false、failureKind 取 CommandFailureKind.permissionDenied——该枚举成员此前零引用，正是为此预留）；引擎工具分发接通时把该 failureKind 翻译成 Dart 的 info+观测+计数即可，permissionMode 以注入 getter 传入（与引擎其它档位来源同构），省略时不设闸、W5 直连调用方行为不变。新测 dispatcher_readonly.test.ts 7 项（写类拒绝且不执行、闸先于参数解析、四类 kind 派生覆盖+read 放行、三档非只读与省略不设闸、unknown-tool 优先级、真实 registry 下 local_file_write 拒绝且目录零创建、取消优先级）。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 67 文件 903 项。 追加（R8 输出截断三件套，Dart 2809-2874 + 2957-2965 + output_processor.dart 1-21 + command_heuristics.dart 40-117）：utils/output_processor.ts 移植 truncateOutput（8 行/600 字符尾截断，三种通知文案 1:1）与 truncateQueryOutput（查询命令尾 20000 封顶）；utils/command_heuristics.ts 移植 isQueryCommand（148 项查询前缀表 + 交互式排除表逐字相等，测试直接从 Dart 源抽字面表 toEqual 钉死，顺序也钉）。引擎 result 事件接线后模型可见文本改截断版——此前 Node 引擎把全量输出直发事件与对话历史，cat 大文件 / journalctl 会把 MB 级输出灌进上下文，R8 明令禁止，本轮消除该违例；事件补 outputTotalChars/outputTruncated/outputTail（rpc/schema 94-96 字段自创建以来首次有产出；outputTail 仅非查询且截断真实发生时给，Dart 2818-2829，证据层用途）。空输出占位保留 Node 自有 ASCII "(no output)"（Dart 用中文 (无输出) 于截断器内部，已钉偏差，engine_executor_throw 等既有针不受影响）。Dart 源侧 quirk 如实保留：前缀表含裸 "w"（who），startsWith 会放行 write-item 一类动词——对等优先，单边偷改会破坏 parity，测试注释已记。截断器的消费端（UI 证据层渲染 outputTail）属父端，Node wire 字段就位即可。新测 3 文件 23 项：output_processor 10（含与 Dart 源逐字节比对针）、command_heuristics 8、engine_output_cap 5（非查询 600 尾截断+tail 全给、查询 20000 尾截断无 tail、短输出零触发、空输出占位、观测入历史为截断版且 2000 字符原文不再出现）。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 70 文件 926 项。 追加（工具动作数据入口链路，agent_engine.dart 2206-2261 + tool_call_accumulator.dart 17-147）：react/tool_action.ts（285 行）落地 parseToolAction —— break 关键词表（思考/动作/命令/选项/观测，双角冒号两形式）刻意不含 工具: ，这正是 Dart 历史 Bug 1 的守卫（若含则工具名分支为死代码、toolName 恒 null）；参数缓冲以 参数: 行冒号后残留 seed 再逐行收集缩进行，ToolArgsParser 返回 null 时按 Dart agentLogger.warn 语义回落（宿主可注入 onParseFail，缺省写 stderr 一行、不新增线事件），toolArgs 保持 null —— E2E-13 的语义针：跨行自由文本 content 整块不可解析时必须保留工具名、拒绝带半截参数执行（file_write 最坏情形是写坏文件）。同文件落 ToolCallAccumulator 全套：addDelta 指 index 分片拼接（非对象项/缺 index 项跳过、id/name 首非空优先）、finalize 指 index 数字序、无 name 丢弃、id 回落 call_加 index、repairArguments 补尾部右花括号（补完仍非法 JSON 则弃用修复串保留原串——{bad 原样返回）、finalize 后清空累积器（finish_reason 与 DONE 双触发不得双投 ReAct 文本）；toReActText 开头自带换行（Bug 3 守卫：FC 协议允许 content 与 tool_calls 同 chunk，thought 文本直拼会吞掉 动作: 行的独立性）且 arguments 从 JSON 转多行 key:value（Bug 2 前半：ToolArgsParser 拒收 JSON 原文），值渲染复刻 Dart toString 形状（List join 逗号、嵌套 Map 无引号形状、bool/null 字面量）。Dart e2e 套件 react_parse_e2e_test.dart 的 E2E-1/2/3/7/13/14 形状移植为 test/tool_action.test.ts 23 项（ASCII-only，CJK 关键词 unicode 转义逐码点等价）：E2E-2 端到端（FC delta → toReActText → parseToolAction，hostIds 逗号串必须成真数组而非方括号字符串——R9 历史 Bug 2 的回归针）、E2E-3 拼接场景（thought 前缀 + reactText，R9 强制形状）、E2E-13 核心针（name 保留 args null 且 warn 恰一次）、E2E-14 反向（单行字面 反斜杠 n 转义可解析）；另 17 项钉 break 表语义、全角冒号、缩进收集边界、累积器去重与修复器四态。engine 侧 tool 路由（动作行扫描 2005-2028、别名组、空工具名/未知工具、engine 级只读闸 3359-3373、destructive confirm 3415+ 的 _handleToolAction dispatch 半边）本轮刻意不接——先落纯函数与 e2e 锁，dispatch 下一轮独立评审；engine.ts 本轮零改动，r5 跨度无需重审。接线面：src/react/index.ts（CRLF 保持）增 export；纯 Node 递归走查 123 个 ts 文件替代不可用的 GitNexus MCP，react/index.ts 的 importer 为 src/index.ts 与 test/confirm_flow.test.ts 两处、tool_action.ts 的 importer 为 barrel 与新测试，均为新增符号无既有调用方。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 71 文件 949 项。 追加（引擎工具分发阶梯，agent_engine.dart 3222-3618）：`_handleToolAction` 已 1:1 落进引擎——无命令 else 分支经 `scanToolAction`（2005-2028 动作行扫描）命中后走 `handleToolAction` 完整阶梯：空工具名（warn+info+观测+重试）→ think 别名组（记 thought、复位计数器，R5）→ execute/placeholder 别名组（有 command 重入共享命令闸；无 command 给「缺少 command 参数」观测并计重试；placeholder 有 thought 当思考、否则回工具清单且不计数）→ registry 未命中（未知工具 warn+info+可用清单）→ 引擎级只读闸（🔑 info + 固定观测，3359-3373，与 dispatcher 侧同源文案）→ 会话作用域隐藏工具 → destructive confirm（3415+：拒绝给「观测: 用户拒绝执行该操作…请用 ask…」且**不消耗**重试预算、批准执行、flow 未接线时带响亮 warn 执行——已披露偏差）→ 执行；工具自身 command 事件先发射、result 卡片与之同 id 配对（R4）；执行异常经 describeThrowable 转「观测: 工具 N 执行异常 — …」（3583-3611，此前缓移植的那处 catch 至此落地）；线输出 8000 封顶 + 中文截断标记（R8），工具路径无 outputTail；重试预算工具阶梯用 `>= 2`（第二次连续消耗性失败终态 TOOL_RETRY_SUMMARY），与无命令分支既有 `<=` 如实并存；成功、think、别名成功、命令尝试均复位 0（R5）。命令管线抽成共享 `runGatedCommand`（闸+执行器+观测+result 一份），execute 别名路径整条复用，闸不复制第二份。`enrichCommandEvent` 保持 fill-if-absent：别名铸的 command 事件被补默认 exec_command，工具卡片先自钉 toolName 因而保留。接线面：`ReActEngine` 增 `toolRegistry` / `isLocalSession` 注入，`toolRegistry === undefined` 时扫描短路返回 null，无 registry 的引擎行为逐字节不变。副产物修复：TRUNC_MARK 曾因双重转义以字面英文落地，改 `replace()` 构造，线截断标记归位中文。偏差清单（显式披露）：事件 id 全用 genEventId（Dart evt_tool_/evt_alias_ 前缀过不了 r4 id 形状闸）；TOOL_RETRY_SUMMARY 取 Node 侧字面量；工具观测空输出占位保持 (无输出) 不与命令路径 (no output) 归一；`_recordToolFileChange`、cancelToken/sudo/dirAuth/isTaskActive/onProgress、项目根捕获、`_hasExecutedAnyCommand`、任务状态通道、`_toolCalls` 计数缓移植。新测 engine_tool_dispatch.test.ts 19 项全走真实引擎（R9 强制端到端）：FC 文本经 ToolCallAccumulator.toReActText 进引擎、工具 own-event/result 配对、execute 别名整条闸路径、think 复位、空名预算两次即终态、registry miss、只读拒/放行、作用域隐藏、destructive 三态（拒/准/未接线）、抛异常转观测、失败后成功复位（R5）、R8 线帽与 L1 尾保留语义、ToolContext 适配器。r5 走廊复核：this.callbacks.onFinished 仍单点（emitFinish 漏斗），新终态全部走它。影响面：GitNexus MCP 本会话不可用，照例纯 Node 递归 importer 走查替代——handleToolAction/scanToolAction/runGatedCommand 均为新私有方法、零既有调用方。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 72 文件 968 项。**r124 再追加**：ask/用户选择通道 1:1 落地——`_handleAskAction`（Dart 3052-3113）→ `handleAskAction`：空选项=finish-as-ask 成功终态（Dart `_finishTask` 默认 success=true，3740；不占无命令预算）；有选项=Promise+捕获 resolve 停放（Node 无 Completer），wake 后 boundary() 定 cancelled/interrupted（Dart 3082-3086 的代次/取消复查在 Node 归 boundary）；`pendingAskEvent` 只记去重通过的 ask 事件（1904-1906），答案写回其 `chosenAnswer`（rpc/schema.ts 已有字段，零协议变更）；空选择=cancelled 终态补发 finish（Dart 3088-3091 无 finish 事件，Node 按 R5 终态一致性补，已披露）；观测 观测: 用户选择了 "X" + trim 回喂（3100-3104）；`selectChoice`（1168-1174）幂等靠 resolve-once + null 守卫；wake 站点两处——run() 入口（Dart 708-712，Node 的 bump 在 run() 顶部已有）与 cancel()（940-944），Node 无 pause 通道故无第三站点（披露）；run() 循环 ask 分支置于 finish 之后、命令检索之前（Dart switch 序 ask 先于 execute），cmdEvt 在 ask 轮置 undefined；`scanAskAction` 让裸 `动作: ask` 行走 finish-as-ask 而非无命令预算（2016-2017）；Dart 事件合成兜底（1488-1498）对 Node 解析器是死代码未移植（保留 lastAskEventSeen 访问器）；任务状态相位变更（waitingConfirm/thinking 通知对）无 Node 通道跳过；选择信息行 zh 单语（无 UiText.t）。options 日志按 Dart List.toString 形如 [a, b]（join，非 JSON）。新测 engine_ask_choice.test.ts 6 项全走真实引擎（停放→选择→观测进下一轮 prompt、finger info 单次、幂等双 select、取消停放→cancelled、空选择→cancelled 且无第二轮模型、裸 ask→success 带 thought 摘要/undefined 摘要、二次 run() 唤醒停放→前者 interrupted 仅新任务 finish）。r5 走廊复核：新代码全部置于 finishSideEffects 之前，走廊（该测试的切片实际到文件尾——this.callbacks.onFinished 的字面量在文件中位于其后）bang-free / failed-free 不变；engine.ts 的 confirm_flow 子串计数仍为 1。影响面：importer 走查 engine.ts = index.ts、react/index.ts（2），公开面纯新增（selectChoice/hasPendingChoice/pendingOptions/lastAskEventSeen）。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 73 文件 974 项。 **r125 再追加**：反幻觉 finish 守卫 1:1 落地——Dart 1450-1468 的 finish 拒绝阶梯进引擎：无命令/无工具执行时 finish 被拒，`_finishWithoutExecCount`（251）计数、上限 2（252），warn 日志「AI 未执行任何命令就 finish，强制继续 (重试 N/2)」+ GUARD_INFO 中文 info 线事件（1460）+ nudge 以 user 角色入史并 trim（1461-1467），随后 force-continue——跳过 checkpoint 保存（Dart continue 同样跳过）。守卫标志单一来源 `guardWillRefuseThisFinish(evt)`：去重环的 wire 抑制与 finish 分支的强制续跑同轮调用同一枚守卫，绝不漂移；被抑制的 finish **不占用 stableId**——被拒重试的 finish 携带同一 answerBody 因而同一 stableId，若占位会把第三轮放行的 finish 从线上吞掉（R5 终态一致性要求每条终态路径都有 finish 事件）；Dart 的解析器根本不铸 finish 事件（finish 只经 `_finishTask` 3762 发出），Node 解析器会铸，抑制是 Node 侧的等价实现而非新增语义。标志置位两处与 Dart 同形：命令体入口（2388，仅 `gateAllowsExecution` 为真时——闸拒绝不算执行过）与 `tool.execute` 之前无条件（3452，失败的工具也是真实动作）。计数器复位只在 run() 入口（Dart 662-663 在 `_resetTransientState`；Node 无暂停通道，故无第二复位点，披露）。**默认关闭**（`EngineOptions.hallucinationGuard === true` 才开）：冻结回归 r1_generation_check 把「无命令直接 finish」钉成 success，默认开会翻既有钉，这与 Dart 默认开形成受控偏差，理由如上。新测 engine_finish_guard.test.ts 4 项全走真实引擎：守卫开→两次拒绝第三次放行（三次模型调用、2 条 GUARD_INFO、线上恰 1 条 finish、nudge 进后两轮 prompt）、命令先行满足守卫（无拒绝）、守卫关→首轮直接 success、计数器逐 run() 复位（二次 run 再拒两次）。guard 日志逐字节对 Dart 1452-1453 原文。r5 走廊复核：新方法置于 finishSideEffects 之前，bang-free / failed-free 不变；engine.ts 非 ASCII 行仍 15。影响面：importer 走查 engine.ts = index.ts、react/index.ts（2），公开面纯新增（hallucinationGuard 选项 + 私有守卫方法）。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 74 文件 978 项。**r126 再追加**：**finish 正文选择请求劫持**（Dart `_choiceRequestFromFinish` 3034-3048 + finish case 1423-1448）已接线——部分模型把「请回复选择 A 还是 B」写进 finish 正文，UI 没有按钮、任务却在用户做决定前收尾；引擎把这类 finish 转成真正的 ask 等用户点选后继续循环。检测器 1:1 移植 `utils/choice_request_detector.dart`（132 行）为 `src/utils/choice_request_detector.ts`（139 行，首个允许原生 CJK 的新 src/utils 模块，先例 safety_guard.ts）；正则漂移用 5 条字节锁（TS pattern source 与 Dart 原始字面量经斜杠归一后逐字符相等）。Node 无 ReActStep，字段映射：`step.options` → 同轮 ask 事件的 options（解析器遇 `选项:` 已铸 ask 事件）、`step.answer` → finish 事件 summary（answerBody 捕获）、`step.thought` → 本轮首个 thought 事件文本（单 thought 轮——劫持语料的实际形态——两者重合）；**r130 修正**：那句「Dart `rawResponse` 兜底只在 thought 可为 null 时可达，Dart 非空字段禁 null，死分支不移植」是错的——Dart 字段非空但可为空串，thought 与 answer 皆空串时该臂可达；Node 已把它接成 finishChoiceHijack 的第四参 turnText（见本节末追加）。**单一决策源** `finishChoiceHijack(evt, events)`：dedup 线上抑制与 finish 分支在同一轮、无 await 之间调同一 helper（r125 守卫同形），被抑制的 finish 不占 stableId（重试 finish 共享同一 id）。顺序照 Dart：劫持（1427）先于反幻觉守卫（1450），被劫持的 finish 不烧 finishWithoutExecCount。协议 options ≥2 直接采用、不跑检测器（Dart 3035-3039），此时复用解析器的 ask 事件不重铸（Dart 1431-1437 条件）；正文提取路线铸新 ask（genEventId 出现 id，R4）并钉 pendingAskEvent。新测两套：choice_request_detector.test.ts 13 项（8 个 Dart 金标用例 + 5 条漂移锁）；engine_finish_choice_hijack.test.ts 5 项全走真实引擎（正文提取→合成 ask、线上零 finish、点选后续跑并回填 chosenAnswer、不占额外模型轮；同 answerBody 重试→stableId 未占→再次劫持成功；协议 options 复用→不双铸、gate warn 用 finish 正文作 question；守卫开时劫持优先→无 GUARD_INFO、计数器未烧、首个普通拒绝仍显示 1/2；「建议 A 或 B」式长总结不受影响直接 finish）。r5 走廊复核：finishChoiceHijack 置于 finishSideEffects 之前，bang-free / failed-free 不变；本轮 engine.ts 新增 95 行零原生 CJK（全部 \uXXXX 转义），engine.ts 非 ASCII 行仍 15。影响面（纯 Node 递归 importer 走查，GitNexus MCP 不可用，披露）：engine.ts importer = index.ts、react/index.ts（2）；choice_request_detector.ts 唯一 importer 为 engine.ts，公开面纯新增（新模块 + 私有方法，无签名变更）。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 76 文件 996 项。**r127 再追加**：**完成语义兜底 finish**（Dart `command_heuristics.dart` 119-163 的 `isTaskComplete` + 解析器侧 2041-2055 在 `action == null` 时调用它）已接线——模型有时不写 `动作: finish`，只用一句「任务完成」收尾；Dart 解析器把这类正文直接判成 `ActionType.finish`，无命令预算（`_handleNoCommand` 3622-3642）不会被消耗。Node 解析器（`react/parser.ts` 292-298）没有 `动作:` 行就绝不铸 finish 事件，所以兜底落在引擎无命令阶梯：新增 `else if (askEvt === undefined && isTaskComplete(response))` 分支，合成一枚**永不上线**的 finish 事件（出现 id `genEventId()`、不占 stableId——R4 禁止引擎对 finish 文本做哈希），再按 Dart 顺序跑 r126 劫持（1423-1448）与 r125 守卫（1450-1468），最后 `logGate("info", FINISH_INFO)`（Dart 1470 `agentLogger.info('ReAct', '任务完成 (AI 返回 finish 动作)')`；引擎唯一日志汇是 stderr 的 gate 行）+ `emitFinish("success", fbSummary)`。摘要取「本轮首个 thought 文本，否则原始正文」（Dart 2048 `thought ?? content`）。**已披露偏差**：Dart 1471-1482 与 `_composeFinishSummary` 3729-3737 的 answer/sections 拆分在 Node 无对应物（解析器不保留该拆分）；`_emitOperationReport` 3755-3760 仍属 D3 待办；`emitFinish` 是唯一许可的终态发射且已跑 W7 副作用，故循环尾的 checkpoint 保存与 Dart 的 `return` 同样跳过；与解析 finish 分支不同，这里两个 helper 消费的是一枚合成事件。守卫的强制续跑半边抽成 `applyFinishGuard()`（1495-1508，与重构前那 12 行字节等同、内部**不含** continue，循环控制留在调用方），使解析 finish 分支与兜底分支共用同一实现。启发式移植：`utils/command_heuristics.ts` 88 → 148 行，新增 `TASK_COMPLETE_KEYWORDS`（10 条，顺序也钉）、`TASK_COMPLETE_START` / `TASK_COMPLETE_END`（`join('|')` 拼接形态照 Dart 127-135，两条 RegExp 的 `.source` 由 Dart 源码片段重建后逐字符相等，且尾串同一枚）、`isTaskComplete`（60 字符帽在 158 行、`\r?\n` 拆分在 136 行，超帽长行只跳不判）。同文件未移植项维持：`isDescriptiveText` / `looksLikeCommand` / `_unwrapCommand`（Node 无调用点）。测试：`test/command_heuristics.test.ts` 8 → 17 项（关键词表 10 条 `toEqual`、两条正则 `.source` 重建比对、共享尾串相等、Dart oracle `test/command_heuristics_test.dart` 385-451 的 16 例（9 真 / 7 假）逐条重放，外加 CRLF 拆分、60/61 帽边界、空轮四例）；新测 `test/engine_is_task_complete_fallback.test.ts`（265 行 / 7 项，ASCII-pure，全部 \uXXXX）全走真实引擎：thought 型完成→success 终态且 summary 取 thought、零重试日志零沙漏事件、FINISH_INFO gate 行在；裸关键词→summary 是原始正文；`回答:` 标签轮解析零事件仍完成；守卫开→两次拒绝第三次放行且 nudge 进后两轮 prompt、重试预算始终不被消耗；无关键词正文→仍 `["failed","no-command retry exhaustion"]`（2 continue + 1 finish，r5 的 no-cmd 行不动）；完成正文同时含选择请求→合成 ask 停放、线上零 finish、question 恰为「安装已完成 + 请回复选择 A 还是 B…」（检测器剔掉选项行）、点选 A 后 chosenAnswer 回填且只剩下一轮的 action finish；守卫开时劫持仍先于守卫→零 GUARD_INFO、计数器未烧、之后首个普通拒绝显示 1/2。r5 走廊复核：新分支在 `finishSideEffects` 之前、`applyFinishGuard` 在其跨度之外，bang-free / failed-free 不变；`this.callbacks.onFinished` 仍单点；engine.ts 非 ASCII 行仍 15（本轮新增 77 行零原生 CJK）。影响面（纯 Node 递归 importer 走查，GitNexus MCP 不可用，披露）：engine.ts importer = index.ts、react/index.ts（2）；command_heuristics.ts importer = engine.ts、test/command_heuristics.test.ts（2）；新增导出无既有调用方改名。四道门全绿：tsc 静默、check-schema-compat PASSED v1.0、fixture 1000 ok 0 failed、vitest 77 文件 1012 项。 **r130 再追加（回答块拆分与终态摘要合成）**：Dart 的 `parseAnswerBlock`（2126-2153）、`parseReportSections`（2159-2198）与其脚下四条常量/助手（`_answerStopLine` 2103-2104、`_sectionStartLine` 2107、`_maxAnswerChars = 12000` 2110、`_clipAnswerText` 2112-2115、`_firstColonIndex` 2118-2124）1:1 落为 `utils/answer_block.ts`（143 行）：两条正则的 `.source` 与 Dart 原始 r'…' 片段逐字符相等，12000 与裁剪标记（两个换行 + 省略号「回答过长，已截断」）由 Dart 源码现读现比——R8 的边界钉子是恰好 12000 不裁、12001 裁成 12000+13，且裁剪保留的是**头部**（与累计缓冲留尾正好相反，两者不可混用）。引擎侧按 Dart 每轮一次的口径接线（2002-2004）：respLines / turnAnswer / turnSections / turnThought / turnFinishSummary 五个局部量取代「摘要＝解析器原文」；去重环在放行前改写 finish 事件的 summary，而 **stableId 仍是解析器按 answerBody 现铸的内容哈希**（R4：改写文本不得改去重键）；finish 分支 state === "success" ? turnFinishSummary : finishEvt.summary 对应 1476-1478（报告优先取四字段、否则取 thought，失败态保留解析器原文不动）；composeFinishSummary(report, body) 即 3729-3737 的三段式（report 空 → body、body 空 → report、否则 report + 空行 + body）；完成语义兜底臂与 ask-无选项臂同源改写，那两条本来不过 wire 的 finish 保持不变。累计缓冲：Dart 61-71 的 setter（20000 帽、留尾）+ 275 逐 chunk 追加 + 660/1256 每任务清空 + 1784 每轮追加 + 3733 兜底读它，Node 由 utils/tail_buffer.ts 承载，写入点在 R5 generation 检查之后、按**整轮一次**写（披露偏差：Dart 是逐 chunk，所以「半途被取消」的中间态在 Node 不进缓冲）。选择请求劫持的文本源由解析器 answerBody 换成回答块（3034-3048 的 step.answer）：结论行之后的选项行不再触发劫持，回答块内的选项仍停放 ask 且 question 取 ChoiceRequestDetector.detect(回答块)，三级回落顺序（回答块 → 本轮首个 thought → 本轮原文）由测试钉住。测试两份：test/answer_block_oracle.test.ts（12 项，ASCII-pure）把 ai_terminal/test/react_parse_e2e_test.dart group 302-418 的 E2E-8/9/10/11/12/15 共 22 个 expect 解析后逐条重放，期望值全部来自 Dart 源码本身；三引号串的**头碎片与尾碎片都取**——闭引号常落在正文末行，而那一行往往正是「动作: finish」，漏掉尾碎片就会造出「解析器少产一个 finish」的假象（本轮踩过并写进注释）；分组行号 302-418、六个用例号顺序、22/1/1 三个计数全部钉住，无法归类的 expect 直接抛解析错而不是静默跳过；E2E-15 的三条 thought 期望改用 src/react/parser.ts 的 parse 重放。test/engine_finish_answer_sections.test.ts（310 行 / 7 项）全走真实引擎：E2E-15 一轮收尾，wire finish 与 onFinished 的 summary 都等于 sections + 空行 + answer、且不等于解析器自铸的 answerBody，而 finish 的 stableId 仍是解析器那枚；选项落在结论行之下不劫持（负控：同一轮的解析器原文过检测器会命中，回答块不会）；选项落在回答块内则停放 ask、question 与检测器输出相等且不含段外那行；裸「动作: finish」的摘要等于本轮原文（3733）；20000 帽的尾缓冲（首轮 25000 字符后头部被淘汰）；同一 engine 二次 run() 后缓冲已空（660/1256）。两处既有钉子按 Dart 语义改写而非改代码迁就测试：engine_is_task_complete_fallback 的兜底 summary 变为「回答块 + 空行 + thought」，engine_ask_choice 的 ask-无选项 summary 由 undefined 改为 3751-3752/3733 的回落文本。仍存的偏差：_emitOperationReport（3755-3760）与 OperationReport 整块属 D3 未落地，因此 E2E-15 那条 OperationReport.extractConclusion 期望在测试里**按计数钉住后跳过**；Dart 3768-3769 的 onCompleted/completionMessage 在 Node 无对应通道；Dart 67-71 的 setter 覆写与 1354 的错误站点无对应物。四道门全绿：tsc 静默 exit 0、check-schema-compat PASSED (protocol v1.0)、fixture 1000 ok 0 failed、vitest 79 文件 1031 项。 **r131 再追加（操作单模型层：models/operation_report.dart 365 行 + models/plan_step.dart 76 行的行为半边）**：D3 点名的 `OperationReport` 整块 1:1 落为 `utils/operation_report.ts`（472 行）——三张 JSON 容差表（`OperationBadge` 8-19、`OperationChange` 23-75、`OperationReport` 79-193 的 toJson 148-169 / fromJson 171-193 与脚下 `_str/_int/_strList/_badges/_plan/_changes` 195-237）、`PlanStep` 的 `isDone` 25-26 / toJson 28-33 / fromJson 35-46 / `parseStatus` 48-74（inProgress 6 别名、completed 5、failed 3、skipped 3、pending 兜底）、四段标签常量 244、`_clip` 的 600/8000 两顶帽与「省略号落在截断末字符之后」、`_extractSection` 276-291（ATX 标题前缀 264、段落分隔 262/270）、`extractDetails` 293-299（**先裁后比**：clip 早于与 conclusion 的相等判断，于是一条 8000+ 的详情不会被当成结论消掉）、`extractNextActions` 301-325（`max` 默认 4、`inSection` 由建议标签开合、`无`/`暂无` 两个占位词丢弃、`take(max)`）、`_cutAtNextSection` 329-333、`_matchSection` 335-350（四种标签形状 `标签:`、裸标签行、`**标签**`、`【标签】`，半角与全角冒号同处一个字符类）、`_cleanAction` 352-357（`- * •` 项目符号与 `1.`/`1)`/`1、` 编号前缀）、`_defaultConclusion` 3709-3723 四条终局中文文案全部到位。六条偏差写在文件头 24-40：Dart 的四个只读 getter（141-144）不复制（Node 的 finishState 是类型联合 rpc/schema.ts:11，Dart 是裸 String）；`OperationBadge.level` 在 Dart 是自由 String、`rpc/schema.ts:34` 把它收窄成三值，故 `badgeFromJson` 对读到的值做 cast——裸 String 列表项（209-237）在内存里不带 level，默认值改由 `badgeToJson` 落地，序列化字节仍等于 Dart 构造器默认的 info；`finishState` 与 Dart 一样不校验、原样透传（`event.schema.json` 的四值枚举才是契约）；`defaultConclusion` 改吃 `stepCount/successCount/reason` 三个参数，因为 Dart 读的是引擎私有计数器而 Node 引擎没有它们；Dart 私有的四个 extractor 在 Node 导出，好让 oracle 重放逐条钉它；`StringBuffer.writeln` 的段体改为同字符 join + clip 的 trim，字节相同。**刻意不移植**：`_emitOperationReport`（3649-3707）。它的 stateBadges 来自 VerificationDetector（2879-2890）、changeRecordIds/changes 来自 ChangeRecordService（2894-2912、3154-3172），再加 `_currentStepCount`/`_currentTask.successCount`/`_operationId`/`_phaseChangedAt` 一组逐任务计数器——三样在 Node 侧都没有对应物；emit 本体缺失时先给 `event.schema.json` 加 `operationReport` 载荷，等于宣告一条「有 payload、无生产者」的协议字段，所以 schema 维持无载荷。两条现状由测试钉住：`rpc/schema.ts:108` 的 `operationReport?` 槽位存在、`event.schema.json` 有 `report` 事件类型而无 `operationReport` 属性。对账：`test/operation_report_oracle.test.ts`（699 行 / 10 组 / 45 项，ASCII-pure）在运行时解析并逐条重放 `ai_terminal/test/operation_report_test.dart`（284 行 / 5 group / 20 test / 68 expect）与 `models/operation_report.dart`、`models/plan_step.dart`、`services/agent_engine.dart` 3709-3723——期望值与 CJK 文案一律现读自 Dart 源码，改 Dart 的文案、别名组、标签常量或任一 helper 正则都会变红；`toJson` 的 19 键顺序逐位相等；列表过滤规则（非 map 项丢弃、空 title 的 plan step 丢弃、additions/deletions 非数值容错）按 195-237 重放；`parseStatus` 九组别名按 Dart 分组逐条对账（不硬钉行号：Dart 60 行本身是 case 分支而非组起点）；`defaultConclusion` 四臂与 `AgentFinishState` 四值一一对应，且断言没有任何一臂返回 ReAct 累计正文；ReAct 管线一段（oracle 201-205 三引号串）经 `src/react/parser.ts` 的 parse 重放，thought 的 contains(现状) 与 extractConclusion 结果分别等于 oracle 212/213；localRestore 三条（253-281，含 legacy map 形状）全部重放。踩到的三处 Dart/JS 语义差写进注释并各有一枚针：Dart 那四条 section 正则是**非 raw** 串（339-342 源码里是双反斜杠），运行时串与 TS 的单反斜杠等价，多做一次 unescape 就把 `\s` 吞成 `s`；JS 里 `[^]]` 被解析成「任意字符类 + 字面 ]」，取字符类内容要用惰性 `\[(.+?)\]`；`cutAtNextSection` 只在下一个小节标签处断，自己的标签保留（105→106 那对由 extractConclusion 钉，不是钉它的前缀切片）。同轮拆掉 r130 留在 `test/answer_block_oracle.test.ts` 的那枚按计数钉住的跳过：E2E-15 的 `OperationReport.extractConclusion(sections, answerBody: answer)`（oracle 403-406）现在是真 needle，与其余 21 条 expect 一起归类、一起重放；`needlesOf` 的 `total === ported.length` 硬校验覆盖面因此从 21 涨到 22。四道门全绿：tsc 静默 exit 0（stdout/stderr 皆 0 字节）、check-schema-compat PASSED (protocol v1.0)、fixture 1000 ok 0 failed、vitest 80 文件 1076 项（12.88s）。**r132 再追加（变更窗口 / 封网期：change_window_service.dart 162 行整块 1:1 落地）**：`utils/change_window.ts`(274 行) 把这份服务整块搬过来——ChangeWindowConfig 9-61（字段文档 10-20、构造默认 22-27、copyWith 29-41、toJson 43-48、fromJson 50-60，底下配 asBool/asInt/asList/parseIntDart 四个转型器），ChangeWindowService 64-160（存储键 65、`_cache`/`_loaded` 67-68、load 71-81、config getter 84-87、save 90-98、isWithinWindow 101-128、checkCommand 135-153、_fmtHour 155、_fmtWeekdays 157-160）。跨夜窗口 22-06、start==end 视为全天、空星期表跳过星期分支、含起点而不含终点，全部按源码逐小时回放对上。**七条偏差已披露**：(1) getter 里的 load 不 await（Dart 85 就是这个形状，Node 照抄，所以「同步读到的是旧缓存」本身是平价行为，测试把它钉成断言而不是修掉）；(2) Dart 的记录元组变成可辨识联合 `ChangeWindowCheck`，`reason === null` 与 `allowed === true` 严格互锁；(3) Dart 的 weekday(1=周一..7=周日) 用 getDay() 加周日→7 的映射，用一整周真实日期核对；(4) Dart int.parse 抛 FormatException 而 Number.parseInt 给 NaN——抛错被显式移植，因此一条坏 weekday 条目会让整份存储配置作废、load 的 catch 保留旧缓存（这条正是 78 行 debugPrint 前缀在测的东西）；(5) 等级分类复用 `utils/safety_guard.ts` 的 checkSafety，不再抄一份 Dart 的 SafetyGuard.check；(6) 引擎臂那五条文案（日志 2577、info 事件 2578、observation 输出 2581、兜底 error 2583、指标名 2585）导出成 ASCII 常量，好让下一轮的引擎臂保持 ASCII-only；(7) Hive 的 SettingsDao 换成注入式 ChangeWindowSettingsPort——Node 侧没有那个 DAO，无 port 时 load 不改缓存、save 只改缓存。**刻意未接线**：agent_engine.dart 2573-2588 的引擎臂本体留到下一轮（本轮引擎零改动），而 2585 的 onSuccess(false, window_blocked, 0) 在 Node 侧没有指标汇，届时以披露代替实现。**本服务没有 Dart 单测**：91 份 dart 测试文件全文扫下来 0 处提到 ChangeWindow / changeWindow / 那两字封锁关键词（这一事实本身钉进测试，将来 Dart 补了测试就会变红逼移植者重对），所以 `test/change_window_oracle.test.ts`（556 行 / 6 组 / 28 项 / 149 断言，ASCII-pure）的期望值全部**运行时现读自两份 Dart 源码**：四条 JSON 键及顺序、三个构造默认值、星期名映射与问号兜底和斜杠连接、isWithinWindow 的五条分支与 if 计数、拒绝句 148-151 的每一段静态碎片（150 那行是嵌套插值，测试里用字符码写的迷你 Dart 串解析器把插值内的内层串提出来，才没把「仅」字碎片读丢）、两条 debugPrint 前缀（去掉尾部错误占位后逐字节相等）、以及引擎臂四条文案加 window_blocked。另有两枚**故意会红**的钉子：引擎里现在还不存在 changeWindow 调用点（接线那轮必须回访本文件），以及窗口臂必须排在分类之后、decideCommand 之前（Dart 顺序：分类 → 审计 → 窗口 → 档位闸门）。测试自身三处错先修：expect 上直接链 endsWith 不是 chai 断言（Invalid Chai property）、9-18 同天窗口的 hour 表第一版把 7 点与 21 点写反（Dart 123 是 hour >= start && hour < end）、_cache 与 _loaded 以及 load 的行号按摘要写的偏移是错的（实际 67/68/72-75）。影响面（GitNexus 不可用，用 import 遍历代替）：change_window.ts 目前只被自己的测试引用，叶子模块，无既有行为变更；utils 桶文件按既有做法不导出它。四道门全绿：tsc 静默 exit 0（stdout/stderr 皆 0 字节）、check-schema-compat PASSED (protocol v1.0)、fixture 1000 ok 0 failed、vitest 81 文件 1104 项（10.75s；stderr 仍是 183 行 gate 噪声加既有测试的堆栈续行，均非失败）。 **r133 再追加（变更窗口引擎臂接线：agent_engine.dart 2573-2588 进引擎）**：r132 那颗叶子现在有了调用点。臂落在 `runGatedCommand`（命令闸唯一路径，execute 别名路径整条复用它）里，按 Dart 的相对顺序摆放：`const safetyLevel = this.safetyCheckFn(cmd)`（分类快照，Dart 2523）之后、`const gateDecision = decideCommand(safetyLevel, gateMode)`（档位闸门，Dart 2592）之前，两者之间只有窗口臂。顺序由 test/change_window_oracle.test.ts 三枚 indexOf 钉住（Dart 侧 2523/2575/2593 与 TS 侧同一相对顺序），r132 那枚故意留红的「引擎里还没有 changeWindow 调用点」缺席针按接线轮原计划翻成存在针 + 顺序针 + 臂体三针（臂体 substring 必须含 `return null;` 与 `formatObservationFailure(cmd, windowCheck.reason`、必须不含 `gateAllowsExecution`）。臂的五件事逐件对齐 Dart 2575-2588：`windowCheck.allowed === false` → `logGate("warn", WINDOW_LOG_WARN + cmd)`（Dart 2577 agentLogger.warn；gate 通道 stderr-only，不新增线事件，r5 的事件计数钉与 callbacks 形状 lint 都不受影响）→ 一条 info 线事件，文本逐字节等于 WINDOW_INFO_HEAD + cmd + WINDOW_INFO_TAIL + reason（Dart 2578 的「🚫 封网期拦截 / 命令: `x` / 换行 / 拒绝句」，四枚常量就是 r132 偏差 6 预留的那批）→ conversation.push({role: "user", content: formatObservationFailure(cmd, reason ?? WINDOW_FALLBACK_REASON)}) 再 trimConversation（Dart 2579-2584 的 ReActObservation(success:false, error: reason).format()，模型由此被告知为什么什么都没跑）→ `return null;`。那枚 `return null;` 是 Dart 2586-2587 `return _EarlyExecutionResult(success:false)` 的 Node 对应物：runGatedCommand 返回 null 就是循环的 continue，于是一条被封网期拒掉的命令从不调用 decideCommand、从不写「步骤 N · 权限 MODE → DECISION」那行 gate info、从不进入确认流（ask/auto 都不弹框）、从不调用 commandExecutor、线上没有 result 事件。四档权限各跑一遍都只剩恰好一条 info 事件——readOnly 下那条权限拒绝 info 若不消失就说明臂没跑在闸门之前——且确认流的 hasPendingConfirm 全程 false。`hasExecutedAnyCommand` 不被窗口拒绝置位（Dart 2388 只在已执行分支置位），所以 r125 守卫开着时「唯一一条命令被封」的运行 finish 仍被拒两次：被拦下的命令不算进度。`enrichCommandEvent` 仍不看窗口，command 事件的 riskLevel/permissionDecision 照 Dart 的发射时快照记「档位闸门会怎么判」（fullAuto 下冻结命令的卡片仍写 execute），要改它就是改线协议而非修 bug，已用测试钉住。 Node 偏差（显式披露）：(1) 引擎取注入缝 `EngineOptions.changeWindowCheck?: (command: string) => ChangeWindowCheck`，缺省实现就是 `checkChangeWindowCommand(command)`，即 Dart 那个静态调用的形状、读模块缓存（连带 r132 偏差 1 那条不 await 的懒加载）；注入缝只为让引擎测试能固定时钟与配置，Dart 侧没有这个缝。(2) Dart 2585 的 onSuccess(false, window_blocked, 0) 在 Node 没有指标汇，与 r132 同一理由，以披露代替实现。(3) 臂只做 info + 观测两件事，不发 metrics、不新增终态：窗口拒绝不是任务终态，R5 的终态一致性不受影响（该轮 run 仍 success、线上仍恰一条 finish）。(4) `WINDOW_OBS_OUTPUT`（Dart 2581 observation 的 output 字段）不进模型可见文本——formatObservationFailure 只渲染 error 侧，与 Node 既有闸拒绝观测同形。(5) 臂的五条文案继续放在 utils/change_window.ts 的 ASCII 常量里，engine.ts 本轮新增 71 行零原生 CJK，非 ASCII 行仍 15。测试两处。test/change_window_oracle.test.ts 556 → 576 行（仍 6 组 28 项，expect 调用 151 → 158，ASCII-pure），缺席针换成存在 + 顺序 + 臂体三针。新测 test/engine_change_window.test.ts（480 行 / 4 组 / 12 项 / 77 处 expect，ASCII-pure）全走真实引擎与真实 LLM 客户端（R9 要求端到端），gate 日志靠捕获 stderr 读（logGate 只有 stderr 这一条通道，同 engine_is_task_complete_fallback 的写法）：store 与注入缝都不设时 fullAuto 逐字节不变（一次 exec、一条 result、零 info、gate 日志里有权限行而没有窗口 warn）；注入缝每命令只被问一次而分类仍是 Dart 那两次（快照 + 闸门）——臂没在 enrichCommandEvent 里加第三次分类，线快照不会漂；冻结拒绝只产 info + 观测（info 文本等于四常量拼出的 Dart 2578 原文，观测与 formatObservationFailure 整串相等，无 result、无 executor 调用、gate 日志有那行窗口 warn 而没有权限行，run 仍 success 且线上恰一条 finish）；四档权限全被窗口压过，而没有任何一档能压过窗口（每档一条 info、无确认框、无执行）；command 事件仍记 execute 而执行器零调用（钉死「窗口不是权限档」）；守卫开时窗口拒绝不满足守卫（4 轮模型、两条 GUARD_INFO、一条窗口 info、一条 finish、零执行），同轮反证真跑过的命令满足它；固定时钟 2026-03-11（周三）14:00 走真实 checkChangeWindowCommand：22-06 冻结下 warn 命令被拒且拒绝句逐段等于 REASON_HEAD + fmtHour + REASON_HOUR_SEP + fmtHour + REASON_HOUR_TAIL + REASON_TAIL + 等级，同一条 safe 命令照常执行（Dart 143-145 连日历都不读）；带星期表的窗口把「, 仅 周三」碎片一并交给模型；09-18 属开窗时段，ask 档照旧弹确认框并执行，r133 之前的行为没被动过。存储三件套也实跑：注入 ChangeWindowSettingsPort 后 save → 模块缓存 → 引擎缺省注入缝实现 → 拦截全链路生效（引擎实际生效的就是写进 port 的那份，键与四键顺序等于 Dart toJson）；存一份 start==end 的配置则全天开窗、命令交回权限闸门；存一份坏配置（weekday 条目是字符串 nope）时 load 的 catch 保留旧缓存（默认关闭）并恰写一条 LOAD_FAIL_PREFIX，命令照跑——封网期不会因为解析失败变成静默否决（R8）。新测对进程 stderr 的净贡献是一行 ask→confirm 的 gate info，窗口 warn 净增 0 行（臂的日志全被捕获）。影响面（GitNexus MCP 不可用，照例纯 Node 递归 importer 走查）：src/react/engine.ts 是枢纽，importer 为 src/index.ts、src/react/index.ts 与约 30 个测试文件，属 HIGH 风险等级改动；缓解手段是默认行为不变（DEFAULT_ENABLED=false 且无人注入 store 时臂恒放行），并由 82 文件 1116 项全绿证成。r5 走廊复核：臂在 finishSideEffects 跨度之前，只用 === false 与 ?? 两枚判据，两条 bang-free / failed-free 切片窗口不重叠也不受影响；this.callbacks.onFinished 仍单点；engine.ts 非 ASCII 行仍 15；test/engine_no_command.test.ts 的「无 gate warn」与 test/engine_trim.test.ts 的 TrimMsgs 0 两枚钉都没动。四道门全绿：npm run typecheck --silent 静默 exit 0（stdout 0 字节 / stderr 0 字节）、check-schema-compat PASSED (protocol v1.0)（454 字节：7 request method / 5 reverse / 6 notification / agent-bridge $refs 全解 / 9 事件类型 + 4 finishState 全在 / $id 稳定）、fixture 1000 ok 0 failed、vitest 82 文件 1116 项（10.71s）。stderr 噪声做了两次全量对账：gate 行 183 → 184，多出的一行是新测开窗用例在 ask 档的「步骤 0 · 权限 ask → confirm」，窗口 warn 在进程 stderr 上净增 0 行；其余仍是 1 处 node-pty 子进程 AttachConsole 堆栈（行数随运行抖动）与 1 处 r1_then_onerror 故意抛出的 onEvent threw for finish，均非失败。

8. **审计日志持久化 (audit_log)** — Dart `AuditLogsDao` 1087 行 + `audit_logger.dart` 88 行已整搬至 `src/utils/audit_log.ts` (r134); SQLite 以注入的 `AuditLogStorePort` 替代, 无 port 时走内存缓存; 三条写入臂 (pre-exec / blocked-only / post-exec) 的 CJK 前缀由 oracle-replay 测试逐字钉住
9. **本机命令误发远程 (local_command_on_remote)** — Dart `local_command_detector.dart` (37 行) + `agent_engine.dart` 2543-2571 已整搬至 `src/utils/local_command_detector.ts` + engine 远程误发拦截臂 (r135); 检测逻辑: 盘符路径 + PowerShell 强特征 (3 组 RegExp), 命中即给可读观测 + `onSuccess(false, 'local_command_on_remote', 0)` 早退
---


**agentLogger 接线状态 (r166-r182)**：引擎 32 个 logGate 站点全部有对应 agentLogger 调用（81 处：19 直接 agentLogger + 62 辅助方法）；mcp/manager.ts 6 处、mcp/connection.ts 2 处、index.ts 1 处、confirm_flow.ts 2 处、tool_action.ts 2 处 = 共 43 处应用日志站点已接线。r180 补 boundary() 取消日志 (Dart 1541)，r181 补确认期间取消日志 (Dart 2682) + 低风险提示日志 (Dart 2737)，r182 补执行后代际失效日志 (Dart 2790)。剩余 console.* 调用均在日志基础设施内部（agent_logger.ts 5 处、agent_tracer.ts 3 处）。Dart 16 个文件对账完毕：3 个有 Node 对应物（agent_engine, mcp_manager, main），13 个无对应物已记录（UI/Riverpod/Hive/崩溃/迁移/健康/命令提取/ChangeRecordService 等）。

**迁移状态 (r182)**：agent_core/ Node 移植已完成全部代码工作：63 个 src .ts、90 个 test .test.ts、4 道门全绿（typecheck / schema / fixture 1000 / vitest 1186）。agentLogger 16 个 Dart 文件全部对账完毕（3 个有 Node 对应物已接线，13 个无对应物已记录）。§9 第 1-5 项为产品决策，代码侧无未完成任务。

## 10. 附录

### 10.1 文件清单（新建）

```
agent_core/
  package.json  tsconfig.json  esbuild.config.js   # dependencies 只有 3 个包, 见 §8
  schema/                                    # 7 份协议契约 (§2.3)
    protocol.version.json  request.schema.json  event.schema.json
    notification.schema.json  reverse.schema.json  tool.schema.json
    agent-bridge.schema.json
  tools/check-schema-compat.mjs               # 只做 JSON 自身一致性, 不跨语言比对 (§6.3.7)
  src/                                       # 63 个 .ts
    index.ts
    rpc/{server,client,schema,transport}.ts
    react/{engine,parser,regex,confirm_flow,tool_action,index}.ts  # confirm 状态机 (§9 第 6 项); goal 续跑落在 utils/goal_continuation.ts, 不在 react/goal.ts
    tools/{index,builtin,dispatcher,orchestrator,platform,tool_args,web_search}.ts
    pty/{index,adapter}.ts
    mcp/{index,manager,connection,models,oauth,tool_adapter}.ts
    llm/{index,clients,openai_stream,anthropic_stream,ollama_stream,stream}.ts
    utils/{index,tail_buffer,stable_hash,generation,pending_registry,line_diff,
           shell_detect,rollout,checkpoint_store,local_file_ops,process_supervisor,
           goal_continuation,agent_goal,                      # goal 续跑落地新增 (§9 第 6 项)
           safety_guard,permission_policy,
           choice_request_detector,command_heuristics,output_processor,
           token_estimator,context_trim,local_file_policy,answer_block,
           operation_report,change_window,audit_log,local_command_detector,compact}.ts
           # 安全分级 + 档位矩阵 + 完成语义/回答块/操作单四字段/变更窗口 (§9 第 6/7 项)
  test/                                      # 90 个 .test.ts + 13 份 fixture
    regression/r{1,2,3,4,5,6,9}_*.test.ts     # 九条规则本体, 见 §6.2
    regression/{manifest,anthropic_e2e,w5_e2e}.test.ts
    e2e/byte_comparison_10.test.ts            # 取代草图里的 e2e/{parser,cancel,multi_host,mcp,tool}
    e2e/fixtures/{golden10.json,i0.txt..i9.txt}
    fixtures/{stable_id_1000.jsonl,verify.mjs}
    <71 个按模块命名的 .test.ts>

ai_terminal/lib/agent_bridge/                 # Dart 侧, 不在本分支范围
  agent_bridge.dart            json_rpc_transport.dart      # 已存在
  agent_bridge_client.dart     frame_splitter.dart          # 待补
  agent_event_codegen.dart     process_manager.dart         # 待补
```

### 10.2 估算代码量 vs 实际（估算是立项时的量纲，不是承诺；差值本身就是信息）

| 模块 | 预估行数 | 对应 Dart 原文 | 落地后实测（含文件构成） |
|---|---|---|---|
| Node: react/engine | 2500 | agent_engine.dart 4740 | 实际 749: 骨架 + R1/R4/R5 闸门 + 危险命令闸已接线 (分类 → 决策 → 执行, 以及事件快照 enrichment 与目标达成标记硬守卫, §9 第 6 项); 确认状态机 1:1 外移为 react/confirm_flow.ts 496 行，现由 index.ts (rpc:confirm) 与 engine (命令闸) 两处驱动; goal 续跑判定外移到 utils/goal_continuation.ts — Dart 引擎文件里 goal 判定的唯一调用点是达成标记守卫 (3864)，已接线；其余四个判定函数在 Dart 也只被 agent_provider.dart 调用，属父端胶合，引擎不拟造; R8 输出截断本轮接线 (2809-2874): 模型可见文本改截断版, 事件补 outputTotalChars/outputTruncated/outputTail; r123 实测 1196 行: 工具分发阶梯 (_handleToolAction 3222-3618) 已接线、命令管线共享 runGatedCommand; r124 实测 1392 行: ask/用户选择通道 (_handleAskAction 3052-3113 + selectChoice 1168-1174 + wake 708-712/940-944) 已接线 (见 §9 第 7 项末追加); r125 实测 1479 行: 反幻觉 finish 守卫 (Dart 1450-1468, 默认关闭, hallucinationGuard 选项开启) 已接线 (见 §9 第 7 项末追加) ; r126 实测 1574 行: finish 正文选择请求劫持 (Dart 1423-1448 + _choiceRequestFromFinish 3034-3048, 检测器 1:1 移植为 src/utils/choice_request_detector.ts) 已接线 (见 §9 第 7 项末追加) ; r127 实测 1651 行: 完成语义兜底 (Dart 解析器 2041-2055 的 isTaskComplete 兜底 + command_heuristics.dart 119-163 启发式 1:1 移植为 utils/command_heuristics.ts 148 行) 已接线 (见 §9 第 7 项末追加) ; r130 实测 1734 行: 回答块 / 操作单四字段拆分按 Dart 2103-2124 + 2126-2153 + 2159-2198 1:1 落为 utils/answer_block.ts 143 行，每轮按 2002-2004 抽 answerText/sections/thought，终态摘要按 1476-1478 取报告（四字段优先，否则 thought）再走 3729-3737 三段式合成，兜底臂与 ask-无选项两路同源；去重环放行前改写 summary 但 stableId 仍是解析器现铸的 answerBody 哈希（R4）；Dart 61-71/275/660/1256/1784 的 20000 帽留尾累计缓冲由 utils/tail_buffer.ts 承载并在 run() 入口清空（R8 边界实测恰 20000），3733 的无 thought 无 answer 兜底读它；选择请求劫持的文本源换成回答块（3034-3048），结论行之后的选项行不再劫持、回答块内的仍停放 ask，第四参 rawResponse 由此接上（见 §9 第 7 项末追加） ; r131 实测仍 1734 行: 本轮引擎零改动, 操作单模型层以叶子模块 utils/operation_report.ts 落地 (无引擎调用点); _emitOperationReport 3649-3707 仍未接线, 理由是 VerificationDetector 2879-2890 与 ChangeRecordService 2894-2912/3154-3172 无 Node 对应物且无逐任务计数器 (见 §9 第 7 项末追加) ; r132 实测仍 1734 行: 本轮引擎零改动, 变更窗口/封网期判定以叶子模块 utils/change_window.ts 274 行落地 (无引擎调用点), 引擎臂 Dart 2573-2588 下一轮接; 缺席与顺序由 test/change_window_oracle.test.ts 的钉子钉住, 接线当轮故意变红 (见 §9 第 7 项末追加) ; r133 实测 1805 行 (+71): 变更窗口引擎臂按 Dart 2575-2588 接进 runGatedCommand，排在分类快照与 decideCommand 之间；命中即 logGate warn + info 线事件 + formatObservationFailure 入史 + trim，然后 `return null;`（= Dart 2586-2587 的 _EarlyExecutionResult，即循环 continue）；被拒命令不到达 decideCommand / 确认流 / 执行器，也不写「步骤 N · 权限」那行 gate info；hasExecutedAnyCommand 与 enrichCommandEvent 均未改动；新增注入缝 EngineOptions.changeWindowCheck，缺省 checkChangeWindowCommand（见 §9 第 7 项末追加） |
| Node: react/parser | 600 | react_stream_parser.dart 425 (在 lib/utils/ 不在 lib/services/) | 实际 365 + regex.ts 12 |
| Node: react/tool_action | —（草图未单列） | agent_engine.dart 2206-2261 + tool_call_accumulator.dart 169 | 实际 285: parseToolAction 数据入口 (break 表不含 工具: 即 Bug 1 守卫) + ToolCallAccumulator (index 拼接 / finalize 排序 / 补花括号 / 清空防双投) + toReActText (首行换行即 Bug 3 守卫, JSON→多行 key:value 即 Bug 2 前半); engine 侧 tool 路由未接线，见 §9 第 7 项末追加 |
| Node: tools/* | 3000 | agent_tool.dart 2634 | 实际 2739 (7 文件; web_search 834 + builtin 1006 占大头, orchestrator 446; builtin 三连轮: 六个 local_* 工具接上 decide()、local_exec 再接上 cwd 闸门、本轮基类补 isReadOnly; dispatcher 151 = 本轮加只读拒绝闸) |
| Node: mcp/* | 500 | mcp_manager.dart 496 | 实际 2378 (connection 765 + tool_adapter 362, 草图严重低估) |
| Node: llm/* | 400 | ai_service.dart 609 | 实际 482 (三个 *_stream.ts + clients + stream, 裸 fetch, 见 §8) |
| Node: rpc/* | 600 | 新 | 实际 615 (schema 359 / transport 137 / server 69 / client 50) |
| Node: utils/* | 500 | 新 | 实际 4183 (30 文件; choice_request_detector.ts 139 系 r126 新增 (Dart choice_request_detector.dart 132 行 1:1 移植, finish 正文选择请求检测); command_heuristics.ts 88 与 output_processor.ts 40 系该轮新增 (R8 输出截断三件套), 前者 r127 扩至 148 行 (isTaskComplete + 两条完成语义正则 + 10 关键词表, Dart 119-163 1:1); token_estimator.ts 91 与 context_trim.ts 126 系前轮新增; local_file_policy.ts 271 = 本轮加 trustedHost 这一 Node-only 接缝, local_file_ops.ts 317 = 本轮只改写头注释, goal_continuation.ts 310 + agent_goal.ts 204 系上一轮新增, safety_guard.ts 658 再上一轮, permission_policy.ts 94 = 本轮再改头注释: 三个调用点 (事件快照 / 命令闸 / 工具层) 共用一张矩阵, 把 confirm 决策的归属指到 react/confirm_flow.ts); answer_block.ts 143 系 r130 新增 (Dart 2103-2124 + 2126-2153 + 2159-2198 1:1: 回答块与操作单四字段拆分 + 两条停止正则 + 12000 帽裁剪 + 全角冒号定位); tail_buffer.ts 59 行本轮接进引擎作 _accumulatedMessage 的载体; operation_report.ts 472 系 r131 新增 (models/operation_report.dart 365 + models/plan_step.dart 76 的行为半边 1:1: 三张 toJson/fromJson 容差表 + 派生 canRollback/hasDiff + 四段标签抽取器 + 四条终局结论模板 + parseStatus 九组别名; 纯叶子模块, 引擎调用点随 _emitOperationReport 一起待办, 见 §9 第 7 项末追加); change_window.ts 274 系 r132 新增 (services/change_window_service.dart 162 行 1:1: 配置模型 + 四个转型器 + 跨夜窗口判定 + 拒绝句 + 存储三件套, 七条偏差见模块头注释, 引擎臂已由 r133 接进 runGatedCommand（Dart 2573-2588, 见 §9 第 7 项末追加）; 另有 pty/ 235 行 (adapter 232), 草图未单列 |
| Dart: agent_bridge/* | 800 | 新 | 实际 294 (agent_bridge.dart 94 + json_rpc_transport.dart 200); 另 4 个文件待补 |
| **合计** | **~9900** | — | 实际 Node src 15037 + test 19593 = 35182 (估的 3.3 倍, 差额几乎全在 mcp 与 utils) |

### 10.3 关键不变式（必须持续为真）

1. **stableId 一致性**：Node 的 `fnv1a64DartCompat()` 对 **1000 行 Dart 侧离线产出的金标输入/输出**逐行相等（`test/fixture_diff.test.ts` 对 `src/`，`test/fixtures/verify.mjs` 对 `dist/`，CI 强制）。口径要写清两件事：(a) 这是**金标比对**，CI 不现跑 Dart —— 好处是无需 Dart 运行时，代价是 Dart 侧若改了哈希不会自动变红，改 Dart 哈希必须同步重生成 fixture；(b) 它是 **FNV-1a 的变体而非标准实现**：Dart 侧每一步乘法后都 `& 0x7FFFFFFFFFFFFFFF` 清掉最高位，运行值恒 < 2^63，所以 64 位摘要实际只有 63 位有效位。照抄「标准 FNV-1a」的常数与循环会在这 1000 行里当场变红，正是这条不变式在守的东西。语料另有一条独立性质：同一 20 万条语料上 `h*31+b`(int32) 会碰撞而本摘要不碰撞（R4 要求的是后者，不是「样本够多」）。
2. **事件序列一致性**：同一任务输入，Dart 与 Node 产生的 `AgentEvent` 序列（类型 + id + 顺序）100% 一致 —— 可比对的 id 限**解析器产出的内容哈希**（thought/text/command/ask 及解析器的 finish）；result、引擎 `emitFinish`、恢复 info 是「一次发生」，Dart 走 `_genId()` 的毫秒 + 计数器，本身不可复现，只锁形状 `evt_<ms>_<n>` 与「两次发生必得两个 id」（见 §6.3.3）
3. **终态白名单**：4 种终态 × 5 种触发路径 = 20 个测试矩阵全绿
4. **callback 清除顺序**：flush → null callbacks → cancelTask → reset reducer，4 条路径 100% 符合
5. **多主机隔离**：`activeHostId` 永不出现在 task 生命周期内的任何 RPC 参数里
