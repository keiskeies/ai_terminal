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
    tools/registry.ts     (替换 agent_tool + 内置 tools)
    mcp/manager.ts        (@modelcontextprotocol/sdk 直连)
    llm/clients.ts        (@ai-sdk/openai|anthropic|ollama)
    pty/adapter.ts        (node-pty, 替换 local_terminal)
    file/ops.ts           (fs/promises, 替换 local_file_tools)
    web/tools.ts          (fetch + 搜索后端, 替换 web_tools)
    rpc/handlers.ts       (JSON-RPC method router)
```

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
agent_core/
  package.json
  tsconfig.json
  esbuild.config.js
  src/
    index.ts               # 入口, 启动 JSON-RPC server on stdio
    rpc/
      server.ts          # 父 -> 子 handler
      client.ts          # 子 -> 父 reverse handler (Dart 实现)
      schema.ts          # 类型 + 校验
    react/
      engine.ts          # 主循环 (对应 agent_engine.dart 4740 行)
      parser.ts          # 流式 ReAct 解析
      goal.ts            # 目标续跑 / 中断检测
      safety.ts          # 危险命令 confirm 流程
    tools/
      registry.ts
      builtin.ts         # exec / file / web / diff 等
      pty_adapter.ts     # node-pty 封装
    mcp/
      manager.ts         # @modelcontextprotocol/sdk
      oauth.ts           # 复用 mcp_oauth 逻辑
    llm/
      openai.ts          # @ai-sdk/openai
      anthropic.ts       # @ai-sdk/anthropic
      ollama.ts          # @ai-sdk/openai-compatible
      stream.ts          # chunk 合并 + reasoning_content
    utils/
      tail_buffer.ts     # 替换 TailTextBuffer
      stable_hash.ts     # FNV-1a 64-bit, 与 Dart 侧实现一致
      generation.ts      # generation check 工具
  test/
    e2e_parser.test.ts   # 对应 react_parse_e2e_test.dart
    e2e_cancel.test.ts
    e2e_multi_host.test.ts
  dist/                      # 编译产物 (tsc + esbuild bundle)
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
ai_terminal/lib/agent_bridge/
  agent_bridge_client.dart   # 子进程生命周期 + RPC 收发
  json_rpc_transport.dart    # JSONL stdio 传输
  frame_splitter.dart        # 大 payload 重组
  agent_event_codegen.dart   # 从 schema.json 生成
  process_manager.dart       # spawn / kill / 崩溃恢复
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
| R4 事件 dedup | `stableId` (FNV-1a 64-bit) | 移植 `stable_hash.ts`，单测覆盖 10 万样本与 Dart 实现一致 | 中 | 写 `stableHashDifferentialTest`，Dart 侧和 Node 侧跑同一批输入，比对 |
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

- [ ] D1：写 `docs/agent-bridge.schema.json`（所有 RPC method + event 的 JSON Schema）
- [x] D2：写 `agent_core/package.json` + `tsconfig` + `esbuild` 构建脚本 ✅ package.json + tsconfig.json + esbuild build script in place
- [x] D3：Dart 侧 `agent_bridge/json_rpc_transport.dart`（JSONL 收发）✅ 已移植（200 行，JSONL + 心跳 + 重连）
- [x] D4：Node 侧 `rpc/server.ts` + `rpc/client.ts` ✅ 已移植（rpc/server.ts + rpc/client.ts + rpc/transport.ts + rpc/schema.ts）
- [x] D5：E2E 冒烟：Dart spawn Node → 发 `rpc:ping` → 收到 `{ok:true}` → 杀进程 ✅ reverse_rpc.test.ts（spawn 冒烟 + invokeSsh/invokeSftp/queryKnowledge 全链路）
- [x] D6：CI job `agent-core-build`：npm install + tsc + esbuild → dist/ ✅ .github/workflows/agent-core-ci.yml（typecheck + test + e2e + build + fixture 7 步）
- [ ] D7：协议变更 checklist（任何 schema 改动要过 `npx check-schema-compat`）

**交付物**：可运行的空壳 Agent Core（无 ReAct 循环），Dart ↔ Node 通信打通。

### Phase 1 — LLM + 流式解析（第 2~3 周）

**目标**：把"用户输入 → AI 流式输出"这条最核心路径迁过去，UI 完全不动。

- [x] W2：`llm/clients.ts`（OpenAI / Anthropic / Ollama，用 `@ai-sdk/*`）✅ 已移植（streaming 三分支 + stream.ts chunk 合并）
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

- [ ] W6：NodeApp 捆绑脚本（`nodeapp build --platform=win/mac/linux`）
- [ ] W6：`process_manager.dart`（lazy spawn / 心跳 / 崩溃重启）
- [ ] W7：checkpoint 机制（每 30s 写 Hive `task_checkpoints`，崩溃后 `--resume`）
- [ ] W7：回滚预案：`kUseNodeAgent` 一键切回 Dart 实现
- [ ] W8：灰度 10% 用户 → 观察 7 天 → 100%
- [ ] W8：移动端（iOS/Android）继续用 Dart 实现，加 `platformIsDesktop` 分流

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
  r4_stable_id.test.ts             # R4 (10 万样本 Dart/Node 比对)
  r5_terminal_whitelist.test.ts    # R5 (5 种终态)
  r6_shell_fork.test.ts            # R6 (bash/cmd/powershell 3 平台)
  r9_stream_e2e.test.ts            # R9 (3 条历史 bug + 7 条新用例)
```

**CI 强制**：任何 PR 碰 `agent_core/src/react/` 或 `agent_core/src/tools/`，必须跑全量 e2e + 9 条回归。

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
| LLM SDK | `@ai-sdk/*` | 一等公民, 流式/工具/取消都管 | 裸 fetch + 自写（重复劳动，不选） |
| MCP | `@modelcontextprotocol/sdk` | 官方 | 保留 mcp_dart（生态差，不选） |
| 本地 PTY | node-pty | 主流 | 保留 flutter_pty（同进程收益，不选） |
| SSH | 保留 dartssh2 | 成熟度高于 ssh2 | 迁 ssh2（重复踩坑，不选） |
| SQLite | 保留 sqflite | 数据层不动 | 迁 better-sqlite3（数据迁移成本高，不选） |
| UI | 保留 Flutter + xterm.dart | 渲染质量 | xterm.js in WebView（卡顿回潮，不选） |

---

## 9. 开放问题（需产品/架构对齐）

1. **iOS 何时支持 Node?** — 当前 Apple 沙盒不允许，双轨运行要持续到何时？（建议 2028 前不删 Dart 实现）
2. **Agent Core 是否要开源?** — 如果开源，schema 和 e2e 测试套件要按 Apache-2.0 准备
3. **多窗口 / 多 agent 实例** — Node 侧 `process` 是单例还是支持多实例？（建议：每个 TaskId 一个子进程, 上限 4 个）
4. **checkpoint 粒度** — 每 30s 还是每个工具执行完？（建议：每个工具执行完, 增量写）
5. **Dart 实现保留多久** — 8 周后？6 个月？（建议：移动端保留 1 年，桌面端 6 个月后删）

---

## 10. 附录

### 10.1 文件清单（新建）

```
agent_core/
  package.json
  tsconfig.json
  esbuild.config.js
  src/
    index.ts
    rpc/{server,client,schema}.ts
    react/{engine,parser,goal,safety}.ts
    tools/{registry,builtin,pty_adapter}.ts
    mcp/{manager,oauth}.ts
    llm/{openai,anthropic,ollama,stream}.ts
    utils/{tail_buffer,stable_hash,generation}.ts
  test/e2e/{parser,cancel,multi_host,mcp,tool}.test.ts
  test/regression/r{1,2,3,4,5,6,9}_*.test.ts

ai_terminal/lib/agent_bridge/
  agent_bridge_client.dart
  json_rpc_transport.dart
  frame_splitter.dart
  agent_event_codegen.dart
  process_manager.dart
```

### 10.2 估算代码量

| 模块 | 预估行数 | 对应 Dart 原文 |
|---|---|---|
| Node: react/engine | 2500 | agent_engine.dart 4740 |
| Node: react/parser | 600 | react_stream_parser.dart 425 |
| Node: tools/* | 3000 | agent_tool.dart 2634 |
| Node: mcp/* | 500 | mcp_manager.dart 496 |
| Node: llm/* | 400 | ai_service.dart 609 |
| Node: rpc/* | 600 | 新 |
| Node: utils/* | 500 | 新 |
| Dart: agent_bridge/* | 800 | 新 |
| **合计** | **~9900** | — |

### 10.3 关键不变式（必须持续为真）

1. **stableId 一致性**：Dart 与 Node 的 `stable_hash` 输出在 10 万样本上 100% 一致（CI 强制）
2. **事件序列一致性**：同一任务输入，Dart 与 Node 产生的 `AgentEvent` 序列（类型 + stableId + 顺序）100% 一致
3. **终态白名单**：4 种终态 × 5 种触发路径 = 20 个测试矩阵全绿
4. **callback 清除顺序**：flush → null callbacks → cancelTask → reset reducer，4 条路径 100% 符合
5. **多主机隔离**：`activeHostId` 永不出现在 task 生命周期内的任何 RPC 参数里
