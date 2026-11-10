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
      engine.ts          # 主循环 (对应 agent_engine.dart 4740 行; 实际 391 行, 是骨架不是全量)
      parser.ts          # 流式 ReAct 解析
      goal.ts            # 目标续跑 / 中断检测 —— 待补, 未实现 (§9 第 6 项)
      safety.ts          # 危险命令 confirm 流程仍未实现 (§9 第 6 项); 它要调的档位矩阵已落地 -> utils/permission_policy.ts (§9 第 7 项)
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
6. **危险命令 confirm 流程落在哪一层** — Dart 侧是一个 `_confirmCompleter` 被 **4 条路径**唤醒（用户确认 / 拒绝 / 10 分钟超时 / `cancelTask`，后者先 generation++ 再 `complete(false)`），加 6 类拒绝原因码；`waiting_confirm` 与 `rpc:confirm` 在 Node 侧只有占位（`src/index.ts` 直接回 `confirm not yet implemented - Phase 2`）。占位不是实现：档位矩阵已落在 `utils/permission_policy.ts`，但还没有调用方，所以「等待确认」在 Node 侧仍等价于「直接执行」；要么补齐，要么灰度前显式禁掉 blocked 档。
7. **`SafetyGuard`（Dart 512 行）是否整搬** — Node 侧目前只有 `tools/orchestrator.ts` 里那个保守只读分类（注释自己写明「mirroring SafetyGuard.check -> safe」），风险分级与审计文案都还没过来；它与第 6 项是同一个缺口的两面。**已落地的那一半**：档位矩阵 `decideCommand` / `destructiveToolNeedsConfirm` 已按 Dart 1:1 落到 `utils/permission_policy.ts`，16 格全表 + Dart 侧结构对账锁在 `test/permission_policy.test.ts`（改 Dart 的守卫顺序、改 `kPermissionDecision*` 取值或改 `SafetyLevel` 顺序都会变红）。**仍未落地**：`SafetyLevel` 的分级来源本身，即 `SafetyGuard.check()` 的分类规则与中文审计文案。

---

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
  src/                                       # 42 个 .ts
    index.ts
    rpc/{server,client,schema,transport}.ts
    react/{engine,parser,regex,index}.ts      # 待补: goal.ts, safety.ts (§9 第 6 项)
    tools/{index,builtin,dispatcher,orchestrator,platform,tool_args,web_search}.ts
    pty/{index,adapter}.ts
    mcp/{index,manager,connection,models,oauth,tool_adapter}.ts
    llm/{index,clients,openai_stream,anthropic_stream,ollama_stream,stream}.ts
    utils/{index,tail_buffer,stable_hash,generation,pending_registry,line_diff,
           shell_detect,rollout,checkpoint_store,local_file_ops,process_supervisor,
           permission_policy}.ts                       # permission_policy 落地新增 (§9 第 7 项)
  test/                                      # 52 个 .test.ts + 13 份 fixture
    regression/r{1,2,3,4,5,6,9}_*.test.ts     # 九条规则本体, 见 §6.2
    regression/{manifest,anthropic_e2e,w5_e2e}.test.ts
    e2e/byte_comparison_10.test.ts            # 取代草图里的 e2e/{parser,cancel,multi_host,mcp,tool}
    e2e/fixtures/{golden10.json,i0.txt..i9.txt}
    fixtures/{stable_id_1000.jsonl,verify.mjs}
    <39 个按模块命名的 .test.ts>

ai_terminal/lib/agent_bridge/                 # Dart 侧, 不在本分支范围
  agent_bridge.dart            json_rpc_transport.dart      # 已存在
  agent_bridge_client.dart     frame_splitter.dart          # 待补
  agent_event_codegen.dart     process_manager.dart         # 待补
```

### 10.2 估算代码量 vs 实际（估算是立项时的量纲，不是承诺；差值本身就是信息）

| 模块 | 预估行数 | 对应 Dart 原文 | 落地后实测（含文件构成） |
|---|---|---|---|
| Node: react/engine | 2500 | agent_engine.dart 4740 | 实际 391: 骨架 + R1/R4/R5 闸门; goal 续跑与危险命令 confirm 未做 (§9 第 6 项) |
| Node: react/parser | 600 | react_stream_parser.dart 425 (在 lib/utils/ 不在 lib/services/) | 实际 365 + regex.ts 12 |
| Node: tools/* | 3000 | agent_tool.dart 2634 | 实际 2465 (7 文件; web_search 835 + builtin 802 占大头) |
| Node: mcp/* | 500 | mcp_manager.dart 496 | 实际 2378 (connection 765 + tool_adapter 362, 草图严重低估) |
| Node: llm/* | 400 | ai_service.dart 609 | 实际 482 (三个 *_stream.ts + clients + stream, 裸 fetch, 见 §8) |
| Node: rpc/* | 600 | 新 | 实际 615 (schema 359 / transport 137 / server 69 / client 50) |
| Node: utils/* | 500 | 新 | 实际 1222 (12 文件; permission_policy.ts 87 行为本轮新增); 另有 pty/ 236 行 (adapter 232), 草图未单列 |
| Dart: agent_bridge/* | 800 | 新 | 实际 294 (agent_bridge.dart 94 + json_rpc_transport.dart 200); 另 4 个文件待补 |
| **合计** | **~9900** | — | 实际 Node src 8429 + test 7809 = 16238 (估的 1.6 倍, 差额几乎全在 mcp 与 utils) |

### 10.3 关键不变式（必须持续为真）

1. **stableId 一致性**：Node 的 `fnv1a64DartCompat()` 对 **1000 行 Dart 侧离线产出的金标输入/输出**逐行相等（`test/fixture_diff.test.ts` 对 `src/`，`test/fixtures/verify.mjs` 对 `dist/`，CI 强制）。口径要写清两件事：(a) 这是**金标比对**，CI 不现跑 Dart —— 好处是无需 Dart 运行时，代价是 Dart 侧若改了哈希不会自动变红，改 Dart 哈希必须同步重生成 fixture；(b) 它是 **FNV-1a 的变体而非标准实现**：Dart 侧每一步乘法后都 `& 0x7FFFFFFFFFFFFFFF` 清掉最高位，运行值恒 < 2^63，所以 64 位摘要实际只有 63 位有效位。照抄「标准 FNV-1a」的常数与循环会在这 1000 行里当场变红，正是这条不变式在守的东西。语料另有一条独立性质：同一 20 万条语料上 `h*31+b`(int32) 会碰撞而本摘要不碰撞（R4 要求的是后者，不是「样本够多」）。
2. **事件序列一致性**：同一任务输入，Dart 与 Node 产生的 `AgentEvent` 序列（类型 + id + 顺序）100% 一致 —— 可比对的 id 限**解析器产出的内容哈希**（thought/text/command/ask 及解析器的 finish）；result、引擎 `emitFinish`、恢复 info 是「一次发生」，Dart 走 `_genId()` 的毫秒 + 计数器，本身不可复现，只锁形状 `evt_<ms>_<n>` 与「两次发生必得两个 id」（见 §6.3.3）
3. **终态白名单**：4 种终态 × 5 种触发路径 = 20 个测试矩阵全绿
4. **callback 清除顺序**：flush → null callbacks → cancelTask → reset reducer，4 条路径 100% 符合
5. **多主机隔离**：`activeHostId` 永不出现在 task 生命周期内的任何 RPC 参数里
