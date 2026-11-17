# Agent 能力优化计划

- 日期：2026-11-16（第一期完成：2026-11-17）
- 状态：三期全部完成（第一期 §4，第二期 §5，第三期 §6），未推送远端
- 范围：`ai_terminal/` 内置 AI agent（ReAct 引擎 + 工具集 + 提示词 + 执行层）

## 0. 现状架构速览

| 组件 | 位置 | 现状 |
|---|---|---|
| ReAct 主循环 | `lib/services/agent_engine.dart`（4739 行） | 文本行协议（思考/说明/动作/命令/工具/参数/计划/选项），FC schema 可选传入 |
| 安全分级 | `lib/core/safety_guard.dart` | `SafetyGuard.check()` 已按 `&& \|\| ; \|` 拆分子命令（引号感知，:258-289），取最高等级 |
| 权限门控 | `agent_engine.dart:2592` `decideCommand(safetyLevel, permissionMode)` | safe/info/warn/blocked × 权限模式 |
| 工具注册 | `lib/services/agent_tool.dart:2463-2524` | SSH 工具、本地文件工具、项目工具、web 工具、多机编排、MCP 适配 |
| 提示词 | `lib/core/prompts.dart`（431 行） | `commandFormatRule` + `agentAutoRule` + 行为边界/知识库安全/危险解释 |
| 观测回传 | `agent_engine.dart:2808-2965` | 查询尾 20000 字符；非查询尾 8 行/600 字符；失败同样截断 |
| 知识库 | `lib/services/knowledge_service.dart` | 任务开始一次性 FTS5 检索注入 system prompt；成功后 recordLearning |
| 上下文压缩 | `lib/providers/agent_provider.dart:35-39` | ≥20 轮或 ≥30000 字符触发；保留最近 6 轮；逐条 AI 摘要 |
| 命令执行 | `command_executor.dart` / `ssh_service.dart` / `pty_output_detector.dart` | exit-code marker 机制；交互提示（yes/no、密码）中断命令；sudo 有存密码自动应答 |

## 1. 问题清单（症状 / 原因 / 方案 / 验收）

### O1 每轮只许一条命令、禁管道 —— 效率瓶颈【P0】

**症状**
- `ps aux | grep nginx`、`grep err log | tail -50` 这类一行能完成的只读分析被拆成 3+ 轮 AI 往返。
- 每轮携带全量历史，token 与延迟随步数线性放大；日志分析/状态巡检类任务尤其慢。

**原因**
- 纯提示词限制：`prompts.dart:7`（commandFormatRule 规则 4）、`:74`（agentAutoRule 核心规则 2）、`:247`（禁止事项）。
- 安全层**早已支持**组合命令：`SafetyGuard._splitCommands`（safety_guard.dart:258-289）引号感知拆分，`check()` 取子命令最高等级。限制与安全能力不匹配。

**方案（WP1）**
1. 提示词放开**只读**管道/链式；修改类命令仍每轮一条、禁止链接（保证确认/回滚粒度）。替换文案：
   - commandFormatRule 规则 4 →
     `4. 只读命令可以用管道 | 或 && / ; 链接组合（如 ps aux | grep nginx、df -h && free -m）；包含修改类操作（安装/删除/改配置/重启等）的命令禁止链接，必须每轮单独执行一条`
   - agentAutoRule 核心规则 2 →
     `2. 修改类命令每次只执行一条；只读命令可用管道/链式一轮完成过滤统计（如 grep -n "error" app.log | tail -50）`
   - 禁止事项 :247 →
     `- 禁止用 &&、||、; 链接多条修改类命令（只读命令的管道/链式允许）`
   - agentAutoRule 增加示例：`命令: ps aux | grep nginx | grep -v grep`
2. 引擎硬保证（不依赖模型自觉）：`SafetyGuard` 暴露公开 `splitSubCommands()`；`_runCommandWithSafety` 在执行前检查——子命令数 > 1 且任一子命令等级 ≥ warn → 不执行，回传观测「链式命令包含修改类操作，请拆分为多轮逐条执行」。
3. `utils/command_heuristics.dart`：组合命令的 `isQueryCommand` = 所有子命令均为查询；超时分档 = 子命令最大值。
4. Windows 分支：PowerShell 5.1 不支持 `&&`，Windows 提示词只放开 `|` 与 `;`；引擎 guard 对 win-ps5 的 `&&` 回传观测提示改用 `;`。

**验收**
- `SafetyGuard.check('ps aux | grep nginx') == safe`；`'cat a && rm b'` ≥ warn 且被引擎 guard 拦截回传。
- 新增 e2e 测试（R9）：含管道的模型响应 → 解析 → 命令完整提取（不被 `|` 截断）。
- `flutter analyze` 0 issue，全量测试通过。

### O2 观测截断过狠 + 无远程读文件工具 —— 调试/改配置最弱【P0】

**症状**
- 编译/测试失败时 agent 只看到尾部 8 行/600 字符，真正的报错在头部被砍掉 → 瞎猜重试。
- 改远程配置时模型没看全文件：`file_patch` 要求精确匹配 old 串，但远程读只能 `cat`（受 20000 尾保留限制），大文件头部看不到。

**原因**
- `agent_engine.dart:2813-2816`：非查询输出尾 8 行/600 字符（`utils/output_processor.dart:3`），**失败输出走同一规则**。
- 工具集有 `file_write`/`file_patch` 却没有 `file_read`（agent_tool.dart:2463-2524）。

**方案（WP2）**
1. 观测分级截断（新常量，替换现有 600/8 行规则）：
   - 查询命令：尾 20000 字符（不变）。
   - 非查询成功：尾 **2000** 字符。
   - **失败**（exit ≠ 0 / 执行异常）：**头 2000 + 尾 6000**，中间标注 `…(中间省略 N 字符)…`。失败信息头部（报错原因）与尾部（stack/summary）都保留。
   - UI outputTail（8000）与审计（500）不变。
2. 新工具 `sftp_file_read`（SSH scope，只读免确认）：
   - 参数：`path`（必填）、`offset`（起始行，1-based，默认 1）、`limit`（行数，默认 200，上限 1000）。
   - 返回：总行数、本次范围、带行号内容（`L12: ...`）、`hasMore` 与下次 offset 提示。
   - 文件 > 2MB 拒绝整体读取，提示用 grep（O1 放开后可 `grep -n x file | head`）或 sftp_download。
   - UTF-8 解码，非法字节 lossy 替换；走 SFTP 直读不经 shell。
3. O1 落地后远程 grep 用 shell 管道即可，**不另建 grep 工具**。

**验收**
- 截断函数单测：失败输出头尾均保留、边界（恰好等于上限）正确（R8）。
- `sftp_file_read` 工具契约测试 + 分段读/大文件拒绝路径测试。
- 工具清单提示词自动包含新工具（registry 生成）。

### O3 交互式命令一律中断 —— 安装/部署卡死【P1，第二期】

**症状**：`apt install` 的 yes/no、无存密码的 sudo、`passwd`、mysql 客户端等一律中断；vim/top 等 TUI 不支持；agent 运行时用户敲终端直写 PTY 可能污染 marker。

**原因**：`pty_output_detector.dart:73-74,198-204` 检测到交互提示即中断；`ssh_service.dart:325-327` 仅 sudo 有存密码时自动应答；终端按键无 agent 运行锁（terminal_page.dart:779-797）。

**方案（WP5，第二期）**
1. 通用输入桥接：检测到交互提示 → 发 ask 类事件给用户（复用现有 `_choiceCompleter`/`onSecretRequest` 通道，自由文本输入）→ 答案写回 stdin → 继续等 marker。密码类提示仍走 provide_password，不进对话历史（R7）。
2. 可配置自动应答规则（如 `apt` 自动 `-y` 建议、`Continue? [Y/n]` → Y），设置页开关。
3. agent 运行期间终端输入锁定或显著提示「Agent 执行中，输入将进入补充指令」。

**验收**：模拟 yes/no 提示的执行器单测；密码不落历史；marker 不被用户输入污染。

### O4 计划只展示不跟踪 —— 长任务跑偏【P1，第二期】

**症状**：模型可跳步、漏验证然后 finish；计划与实际执行脱节。

**原因**：`_currentPlan` 仅解析替换与展示（agent_engine.dart:1414-1416），无执行跟踪。

**方案（WP6，第二期）**
1. 引擎维护计划状态机：每轮把「计划进度快照」注入上下文；命令成功/失败后提示模型更新对应项。
2. finish 门控：计划存在 `[ ]`/`[>]` 项时要求模型先标完成/跳过并说明（复用 `_finishWithoutExecCount` 式独立计数器，最多重试 2 次后放行，避免死循环）。
3. 不做命令→计划项的自动映射（语义匹配不可靠），由模型自报 + 引擎校验形式完整性。

**验收**：计划未完成即 finish 的重试/放行路径单测；不影响无计划任务。

### O5 运行中无法插话（steering）—— 纠偏成本高【P1】

**症状**：任务运行中新消息被拒（agent_provider.dart:1068-1069），用户发现方向错了只能暂停/取消，丢失进度。

**原因**：引擎无运行中消息注入通道；UI 输入框运行态禁用。

**方案（WP3）**
1. 引擎：`Queue<String> _steeringQueue` + 公开 `addUserSteering(String)`；主循环顶部（代际/暂停检查之后、_callAI 之前）排空队列 → 逐条加 user 消息「用户补充: ...」+ 发 info 事件。drain 无 await，天然满足 R1。
2. Provider：`AgentNotifier.steer(text)` 运行中可调；消息立即按现有 user 消息持久化路径落库（失败必须 surface，R8）。
3. UI：AI 面板输入框运行态保持可用，placeholder 改「补充指令…」，发送走 steer 而非 startTask；时间线显示用户补充事件。
4. 限制（明确告知）：补充在**下一轮循环边界**生效；正在执行的命令与等待确认/ask 期间不立即注入。

**验收**：引擎单测（队列注入顺序、代际失效不注入、cancel 后队列清空）；steer 消息持久化往返；analyze 通过。UI 手感需人工冒烟。

### O6 知识库一次性注入 + 纯关键词 —— 经验复用率低【P1】

**症状**：任务中途才明确需要的知识查不到；中英文/同义词不命中即漏。

**原因**：任务开始一次性 FTS5 前缀 AND 检索并缓存（agent_engine.dart:821），无每步检索通道。

**方案（WP4）**
1. `KnowledgeService` 暴露公开 `searchKnowledge(query, {platform, hostId, limit})`（复用 buildKnowledgeInjection 内部检索逻辑，不改注入行为）。
2. 新工具 `knowledge_search`（全 scope，只读免确认）：参数 `query` 必填、`platform` 可选；返回 top 5 条目（标题/平台/mode/命令/备注），单条 ≤1500 字符、总量 ≤8000。
3. 提示词工具清单由 registry 自动生成；agentAutoRule 补一句「中途需要安装/配置指引时可调用 knowledge_search」。

**验收**：工具契约测试；检索结果截断边界测试；不影响现有任务开始注入。

### O7 压缩按字符数 —— 长会话上下文质量差【P2，第三期】

**症状**：中英文 token 密度差 2-3 倍，30000 字符阈值不准；逐条摘要 AI 开销大；早期关键事实（主机环境、用户约束）可能被摘要丢掉。

**原因**：agent_provider.dart:35-39 字符/轮次阈值；:2033-2048 逐条 summarizeMessages。

**方案（WP7，第三期）**：按模型 tokenizer 估算 token（无 tokenizer 时用 中文≈1字/token、英文≈4字符/token 加权）；改滚动式整体摘要 + pinned 关键事实段（主机信息、用户明确约束不压缩）。

### O8 文本协议脆弱 —— 结构性风险【P2，第三期】

**症状**：中文行协议 + 全角/半角冒号 + 大量 fallback 启发式；AGENTS.md R9 记录过多次解析死代码 bug；弱模型格式崩坏触发 noCommand 熔断。

**原因**：FC 已支持（agent_engine.dart:1658 传 tools schema）但文本协议仍是主路径。

**方案（WP8，第三期）**：`supportsFunctionCalling` 模型优先走原生 tool_calls（execute/finish/ask 也建模为 tool），文本协议降级为弱模型 fallback；分阶段删除解析兜底。需完整 e2e 回归（R9）。

## 2. 开发计划

### 2.1 分期

| 期 | 工作包 | 内容 | 规模 |
|---|---|---|---|
| **第一期（已完成，§4）** | WP1 | O1 只读组合命令放开 | M |
| | WP2 | O2 观测分级截断 + sftp_file_read | M |
| | WP3 | O5 steering 消息队列 | M |
| | WP4 | O6 knowledge_search 工具 | S |
| **第二期（已完成，§5）** | WP5 | O3 交互输入桥接 | L |
| | WP6 | O4 计划跟踪门控 | M |
| **第三期（已完成，§6）** | WP7 | O7 token 化压缩 | M |
| | WP8 | O8 FC-first 协议重构 | L |

### 2.2 文件归属与冲突矩阵（第一期）

| 文件 | WP1 | WP2 | WP3 | WP4 |
|---|---|---|---|---|
| core/prompts.dart | ✏️ 主 | | | |
| core/safety_guard.dart | ✏️ 主 | | | |
| utils/command_heuristics.dart | ✏️ 主 | | | |
| services/agent_engine.dart | ✏️ guard 小改（~2523） | ✏️ 观测区（~2808-2965） | ✏️ 循环顶部（~1261）+ 新 API | |
| services/agent_tool.dart | | ✏️ 新工具+注册 | | ✏️ 新工具+注册 |
| services/knowledge_service.dart | | | | ✏️ 主 |
| providers/agent_provider.dart | | | ✏️ 主 | |
| pages/terminal_page.dart / AI 面板 UI | | | ✏️ 主 | |
| test/ | 各自新增 | 各自新增 | 各自新增 | 各自新增 |

已知冲突点：`agent_tool.dart` 注册列表（WP2/WP4，相邻行小冲突）；`agent_engine.dart` 不同区域（WP1/WP2/WP3，预期可自动合并）。

### 2.3 并行与合并策略

- 每个 WP 一个独立 git worktree 子 agent，互不干扰；各自 `flutter analyze` + `flutter test` 全量通过后在 worktree 分支提交。
- 合并顺序：**WP1 → WP4 → WP2 → WP3**（先无冲突的，再处理注册列表小冲突）。
- 合并后主线再跑一次全量 analyze + test；逐提交 `git show --stat` 复核影响面。
- GitNexus MCP 本工作区不可用，`impact()`/`detect_changes()` 无法执行；以 grep 调用方 + diff 复核替代，并在提交说明中明示。

### 2.4 通用工程约束（所有 WP 必须遵守）

- AGENTS.md R1–R9 全部适用，重点：await 后生成检查；回调清理顺序（flush → null → cancel）；终态一致性；缓冲有界保尾；流式/解析改动必须 e2e 测试。
- 不引入 codegen（项目无 Hive/build_runner 依赖，AGENTS.md 该条已过时）。
- 环境：`export PATH="/d/tools/flutter_sdk/flutter/bin:$PATH"`，从 `<worktree>/ai_terminal/` 运行 `flutter pub get` / `analyze` / `test`。
- 只改归属文件；越界需求写进报告而不是直接改。
- 注释/UI 文案中文；提交信息中文 conventional commit；不 push。

## 3. 风险与回滚

| 风险 | 缓解 |
|---|---|
| WP1 放开组合后模型滥用链接修改命令 | 引擎 guard 硬拦截（不依赖提示词）；权限门控不变 |
| WP2 观测变大推高 token | 失败 8000 字符上限仍远低于查询 20000；压缩阈值兜底 |
| WP3 steering 污染历史/持久化 | 走现有 user 消息路径；代际检查；cancel 清空队列 |
| WP4 检索结果注入过大 | 单条 1500 / 总 8000 硬上限 |
| 并行合并冲突 | 文件归属矩阵 + 固定合并顺序 + 合并后全量测试 |

回滚：各 WP 独立提交，`git revert` 单提交即可回退单项。

## 4. 第一期完成记录（2026-11-17）

四个 WP 由并行 worktree 子 agent 开发，按 WP1→WP4→WP2→WP3 顺序合并，零冲突。

| WP | 提交 | 新增测试 | 备注 |
|---|---|---|---|
| WP1 | fc51f10 | 37 | 偏离：原 `_splitCommands` 并非引号感知（文档描述有误），重写为引号/转义/heredoc 感知，否则 heredoc 内容行会被新 guard 误拦 |
| WP4 | 48b0cf7 | 27 | 注入路径改调公共检索核心，行为等价有回归测试 |
| WP2 | c9ba52f | 48 | 连带改 risk_explainer.dart +1 行（测试强制每个注册工具有影响文案，WP4 同） |
| WP3 | 68b850c | 13 | UI 未人工冒烟；已知边界：入队后未注入即暂停，恢复时队列清空（消息已落库） |

**合并后补全（领队）**：WP2 发现 `_trimMessages` 的 `_maxMessageChars=4000` 会把所有历史消息尾保留裁到 4000，失败观测头部进模型前仍被砍掉。修复：观测消息（`观测:` 前缀，含命令与工具观测）专用上限 `_maxObservationMessageChars=12000`——失败观测（≤8000+包装）完整保留，查询观测尾保留从 4000 提升到 12000；token-aware 总裁剪不变。新增 2 个回归测试。

**验证**：主线 `flutter analyze` 43 issue 全为基线既有（0 error，改动文件 0 新增）；`flutter test` 1502 通过 / 25 跳过 / 1 失败——失败项 `server_monitor_windows_e2e_test.dart` 已在基线 commit 91a1d5b 的 detached worktree 复现，属既有失败，与本期无关（根因见 §5：63073da 监控栏图标化改版后断言过期，已修）。GitNexus 不可用，以 grep 调用方 + diff 复核替代。

**待办**：WP3 UI 需人工冒烟；第二/三期按 §2.1 启动。

## 5. 第二期完成记录（2026-11-17）

WP5/WP6 由两个并行 worktree 子 agent 开发，按 WP6→WP5 顺序合并，零冲突。

| WP | 提交 | 新增测试 | 备注 |
|---|---|---|---|
| WP6 | db9c80a | 14 | 计划进度快照每轮幂等注入 system 消息（【当前计划进度】整段替换不累积）；finish 门控只拦 pending/inProgress 项，≤2 次重试后放行，failed/skipped 不拦；叠加 `_hasExecutedAnyCommand` 幻觉门控 |
| WP5 | 90ea236 | 30 | 检测器拆分密码类（保持中断→provide_password，R7 密码不进历史/日志）与确认类（[Y/n]/Continue?/Press ENTER，尾锚定）；`ConfirmationPromptResponder` 起始下标去重镜像 sudo 应答器；ssh/local 双执行器桥接 `onInteractivePrompt`；自动应答开关默认关（[Y/n]→Y、Press ENTER→空）；自由文本应答不落凭据库/历史 |

**偏离与复核（领队）**：
- WP5 放宽 SSH `executeAndWait` 入口守卫为 `!_isConnected`（原 `|| _session == null`）并加 `isConnectedForTesting` 测试缝。不变量复核：`_isConnected=true` 仅在 shell session 获取成功后置位；所有断开路径先置 false 再 null session——生产安全。
- WP5 扩展 pauseTask/_finishTask 清理路径，所有出口（reset/cancel/pause/finish）均 complete `_interactiveInputCompleter`（R1，防桥接 await 永久挂起）。
- 两个 worktree 基线为 2eaa5b9（早于主线 f513f44），三方合并只取各自增量，干净落地；WP6 注入点合并后复核位于 steering 排空之后、`_callAI` 之前（循环顶顺序：暂停检查→steering 排空→executor 刷新→计划快照注入→_callAI）。
- **跨期合并缝隙**：WP5 改了 `executeAndWait` 签名，但一期/WP3/WP6 的 6 个测试 fake 基于旧基线未带 `onInteractivePrompt` 参数，合并后 analyze 报 6 个 invalid_override——领队补齐（8ffe2cc，R9 契约变更需 grep 全部实现方）。

**monitor e2e 失败根因更正**：一期记录为"疑似负载型 flaky"有误。实为 63073da（监控面板精简标签）把所有指标 chip 改为 `showLabel:false`，"CPU" 文字移入 hover 浮层，测试 `find.textContaining('CPU')` 成为确定性过期断言。二期分支基于改版前的 2eaa5b9 故通过，造成 flaky 假象。已改用 CPU 数值断言修复（8ffe2cc）。

**验证**：主线 `flutter analyze` 43 issue 全为基线既有（0 error）；`flutter test` **1547 通过 / 25 跳过 / 0 失败**。GitNexus 不可用，以 grep 调用方 + diff 复核 + 不变量检查替代 impact/detect_changes。

**待办**：WP3/WP5 UI（运行中补充输入、交互应答弹窗、终端按键门控、自动应答开关）需人工冒烟；第三期（WP7 token 压缩 / WP8 FC-first）按 §2.1 启动；未推送远端。

## 6. 第三期完成记录（2026-11-17）

按用户要求改为**主工作区直接顺序实现**（不派 worktree 子 agent）：先 WP7 后 WP8，各自独立提交。

| WP | 提交 | 新增测试 | 备注 |
|---|---|---|---|
| WP7 | 60fc7ca | 20 | 压缩阈值 token 化（16000 token 取代 30000 字符，轮次 20 / 保留 6 轮不变）；逐条 JSON 摘要改为**滚动整体摘要**（纯文本【关键事实】+【对话进展】两段，≤1200 字、4000 字硬上限，主机环境/用户约束/路径逐字保留）；`ConvMessage.rolledUp` + `Conversation.rollingSummary`（与聊天模式 summary 分离），schema v9 迁移；`buildAiHistory()` 统一 restore/compact 两路；兼容旧逐条摘要；await 后 R1 身份校验（`identical`）；无 DB 时持久化失败按 R8 暴露到 state.error |
| WP8 | d48f5a0 | 14 | `chatStream` 新增 `onToolCalls` 结构化回调（三处 finalize 兜底共用投递入口，不重复；Qwen 透传、Ernie 仅满足契约）；schema 增加 execute（含 description）/finish（含四段操作单字段）/ask（选项必填）动作工具；`agentFcRule` + `buildToolsPrompt(fcMode)`：正文只写思考与计划块（保留 WP6 文本计划约定），含降级兼容条款；引擎 FC 事件合并走 stableId 去重（`_stableId` 公开），第一个 execute 定型即提前执行，FC 模式禁用文本流提前命令检测、丢弃正文围栏解析出的 command/ask（思考示例不执行）；`_stepFromFcCalls` 直接构造动作，动作按文本协议记入历史；纯文本响应自动落回文本解析，非 FC 模型行为不变 |

**偏离与决策**：
- O8 原方案"分阶段删除解析兜底"**未执行删除**：文本协议解析保留为弱模型 / fallback 模型的正式降级路径（FC 模型回纯文本、主模型故障切非 FC 备用模型都依赖它），只消除了 FC 路径上的「JSON→文本→再解析」往返。
- ask 的 options 在 schema 中设为必填：引擎 ask 流程是按钮选择制（空选项会被 `_handleAskAction` 视为 finish），开放式问题也要求给出回答方向选项，避免引入新的自由文本问答 UX。
- finish 工具用 conclusion/status/changes/suggestion 四字段对齐文本协议操作单，而非单一 summary，保证 report 解析链路不变。
- 门控注入文案（幻觉门控/计划门控）去掉 `动作: execute` 等协议行引用，FC/文本两种模式通用。
- R9 契约变更同步：`AIProvider` 全部 17 个实现者（3 生产 + 14 测试 fake）签名补齐；`fc_first_e2e_test` 覆盖组装后链路——引擎层 11 例 + provider 层真实 loopback SSE 3 例（跨包 arguments 拼接、旧文本投递回归、无 [DONE] 不重复投递；测试内临时恢复真实 HttpClient 绕过 binding 的 400 mock）。

**验证**：主线 `flutter analyze` 43 issue 全为基线既有（0 error）；`flutter test` **1581 通过 / 25 跳过 / 0 失败**（二期 1547 → WP7 +20 → WP8 +14）。GitNexus 不可用，以调用方全量 grep + diff 审查替代 impact/detect_changes。

**待办**：WP3/WP5 UI 冒烟仍未做。

**真机联调**：WP1–WP8 在本地 Windows dev 包 + Demo Server（FC 模型）逐项验收通过。WP7 走 `/compact` 手动压缩：滚动摘要两轮 604→974 字符（第二轮 `已有摘要: true` 为滚动合并），引擎历史 38→15 条，首轮原文仍在聊天列表，跨两次压缩后 pinned 事实（中文回复约束 / 主机环境 / 容器 IP / 会话 id / 文件内容）逐条可复述且能诚实说明"保留的是摘要非原文"；11 轮 / 9% 上下文未误触发自动压缩。WP8 在 trace 中确认 execute / ask / finish 三类动作均 `fc_calls=1`，正文围栏里的示例命令未被执行（直接 shell 校验 `RC=2`、文件不存在），finish 四段操作单落在 `taskEnd.summary`，ask 按钮可点且能续跑，纯文本轮次自动 `fc_calls=0` 落回文本协议，提前执行的 execute 事件无重复命令卡片。

**真机发现并修复**：finish 幻觉门控（`_hasExecutedAnyCommand`）不认识"严禁执行任何命令，只根据会话内容回答"这类用户约束，纯问答任务要白烧完 2 次重试、最后靠 ask 才能收尾。新增 `NoCommandIntentDetector`（只喂用户原文：goal / steering / ask 选项，模型自述不算豁免依据），命中后 `_userForbadeCommands` 单向置位、在 `_resetTransientState` 归零并跨 pause/resume 保留，幻觉门控让路，`_handleNoCommand` 的继续提示也改成"直接给文字回答"而不再催促执行命令。判据要求否定词直接修饰无限定的"命令/指令"，"禁止执行安装命令"这类只禁一类的说法不豁免。