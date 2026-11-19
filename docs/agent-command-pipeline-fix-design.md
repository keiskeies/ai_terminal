# Agent 命令管线缺陷修复设计（提示词 → 生成 → 执行 → 观测 → 展示）

状态：**已实施（2026-11-19）**。F1-F3/H1-H2/M1-M5/P1-P2/D1/N1-N3 全部落地；全量 `flutter test --no-pub` **1703 passed / 25 skipped 全绿**，`flutter analyze` 无 error（仅 2 条 HEAD 基线自带 warning，与本次无关）。逐项结果见 §7，偏差与设计澄清见 §10。真机验收（Docker SSH / 本地 cmd+PS 双 shell）未在本环境执行，状态见 §7 末。
审计日期：2026-11-19（main 分支快照）。行号以本次快照为准，会随代码漂移——**定位请以符号名为准**。
适用范围：`ai_terminal/lib/services/agent_engine.dart`、`ssh_service.dart`、`local_terminal_service.dart`、`command_executor.dart`、`lib/models/agent_model.dart`、`lib/utils/ansi_stripper.dart`、`exit_marker_scanner.dart`、`output_processor.dart`、`react_stream_parser.dart`、`lib/core/prompts.dart`、`lib/pages/terminal_page.dart`、`lib/utils/conversation_export.dart`
关联：AGENTS.md R5/R6/R8/R9（终态一致、shell 分支、单次清洗、契约扇出）、`docs/terminal-capability-gap-design.md`（执行通道架构事实 A/B/C）

---

## 1. 背景与审计方法

用户要求检查「命令从提示词 → AI 生成 → 执行 → 获得结果」全链路，找出会导致**执行错乱**或**回答展示乱七八糟**的缺陷。审计方式：

1. 全链路逐文件通读（提示词、流式解析器、引擎 ReAct 循环、两个执行器、清洗工具、展示层）；
2. 执行层另派审计代理交叉验证，发现逐条回代码核对；
3. 三个关键疑点写成临时端到端探针测试**实跑证实**（`flutter test --no-pub`，3 例全部按预测失败），跑完已删除。

一句话结论：**解析与展示层的防护（R10 门控、commandScope、FC 分离、stableId 去重）是有效的；但「结果回传给 AI」这一步有致命契约断链（失败观测恒为「(无输出)」），输出清洗层有两处会真实损坏数据，执行层有退出码截断/陈旧值等边界缺陷。**

## 2. 已核实的契约事实（设计依据）

以下事实全部在当前代码中核实过，是后文所有修复方案的依据。

**事实 A：真实执行器的 `stderr` 恒为空，报错全在 `stdout`。**
SSH 远端 stderr 在会话层就并入 `outputController`（`ssh_service.dart` 会话建立处 `stderr.cast<List<int>>()` 监听），两个执行器的正常/超时/异常返回路径全部 `stderr: ''`。而 `AgentResult.fromCommand` 把 stdout→`output`、stderr→`error`，于是失败时 `error == null`。引擎组装失败观测只取 `errorText`（来自 `result.error`）→ **AI 看到的失败观测恒为「错误: (无输出)」**，真实报错只进了 UI 结果卡。探针实证：执行器返回 `stdout='-bash: foo: command not found', exitCode=127`，观测为「(无输出)」。

**事实 B：`failureReason` 全引擎无消费者。**
`CommandResult` 携带 `failureKind` + `failureReason`（注释明说「用于 AI 决策」），但 `AgentResult.fromCommand` 只接收 `failureKind`，`failureReason` 在 `_executeCommand` 返回时被丢弃。后果：超时原因、语法错误诊断、交互提示文本都到不了 AI；提示词规则 10 的 sudo `provide_password` 流程要求「观测里出现 interactivePrompt 与提示文本」，该路径实际不可达。

**事实 C：`success` 的两套口径目前等价但脆弱。**
`CommandResult.success = exitCode==0 && !timedOut && failureKind==none`；`AgentResult.fromCommand.success = exitCode==0`。当前所有异常路径都返回 `exitCode=-1`，故等价；但这是隐式约定，F1 改动时显式对齐。

**事实 D：清洗链有三层，违反 R8「只清一次」。**
执行器层：`indexOf(wrappedCommand)` 去回显 + 尾部单字符 `[\]\$#]`（本地多一个 `>`）删除 → 引擎层：`AnsiStripper.strip` + **第二次** `stripCommandEcho` + `stripInteractiveEcho` → 分级截断。探针证实两处损坏：
- `AnsiStripper` 的残留正则无条件生效：`[INFO] service started` → `NFO] service started`；`[1,2,3]`、`[2026-11-19] log line` 整行消失；`arr[0]; done` → `arr[0`。
- 二次 `stripCommandEcho` 情况 2：命令 `pwd`、真实输出 `/home/user/pwd\nx` → 只剩 `x`。

**事实 E：marker 完成判定无数字边界，完成后丢弃后续 chunk。**
`ExitMarkerScanner.donePattern = marker+\d+`，首个数字到达即 `complete()`，监听回调 `if (doneCompleter.isCompleted) return;` 丢弃后续数据。慢链路下退出码 `137` 分两片（`1` / `37`）到达 → 缓冲里只有 `1`，提取正则解析成 1（OOM-kill 误判为普通错误）。

**事实 F：cmd 包装的 `%errorlevel%` 在解析期展开，取到上一条命令的陈旧值。**
`wrapCommandWithExitMarker` cmd 分支 `'$command & echo $marker%errorlevel%'`。候选修法已在本机实测（交互 cmd 与 `cmd /c` 两种上下文）：

| 候选 | 交互 cmd | `cmd /c` | 结论 |
|---|---|---|---|
| `call echo MARKER%%errorlevel%%` | ✅ MARKER5 | ❌ MARKER%0%（内层先被展开） | 弃用：上下文相关 |
| `setlocal EnableDelayedExpansion & echo MARKER!errorlevel!`（同行） | ❌ 字面输出 | ❌ 同左 | 弃用：整行先解析后执行，! 不展开 |
| **`call echo MARKER%^errorlevel^%`** | ✅ MARKER7 / MARKER0 | ✅ MARKER137 / MARKER0 | **采用** |

原理：第一遍 `%` 展开时 `%^errorlevel^%` 的变量名含 `^` 属未定义 → 原样保留；第二遍去 caret 得 `%errorlevel%`；`call` 触发第三遍展开，此时命令已执行完，取到新鲜值。

**事实 G：展示层结构化事件优先，raw fallback 只影响无事件的老会话与导出。**
`terminal_page._buildAIContent` 仅在 `!hasAIContentEvents && !isLoading` 时渲染原始 `content`（含 思考:/动作:/命令: 协议行）；`conversation_export.dart` 同样的 fallback。新会话不受影响。

**事实 H（M2 修正）：断线分类只有一半是坏的。**
`executeAndWait` 的 `onDone` 路径已正确归类 `disconnected`（reason 含「channel 已关闭」）；坏的是 `_handleDrop` 路径——它直接 `complete()` 所有挂起 completer 且不写 reason，异常分支落到「命令未完成」→ `unknown`，AI 得不到「该重连」的信号。

## 3. 修复总表

| ID | 严重度 | 阶段 | 缺陷 | 修复一句话 | 证据级别 |
|---|---|---|---|---|---|
| F1 | 🔴 致命 | P0 | 失败观测恒「(无输出)」，failureReason 全链路丢失 | 失败观测改用真实 stdout + 透传 failureKind/failureReason/exitCode | 探针实跑证实 |
| F2 | 🔴 致命 | P0 | AnsiStripper 残留正则吃掉 `[INFO]`/JSON/时间戳 | 残留清洗仅在输入含 ESC/BEL 时启用 + 收紧两条正则 | 探针实跑证实 |
| F3 | 🟠 高 | P0 | 引擎二次 stripCommandEcho 误删真实输出（R8） | 删除二次清洗；执行器层回显去除升级为绕排容忍 | 探针实跑证实 |
| H2 | 🟠 高 | P0 | 尾部单字符清洗吃掉合法 `]`/`$`/`#`/`>` | 删除单字符清洗，换精确提示符整行匹配 | 代码核实 |
| H1 | 🟠 高 | P1 | 退出码跨 chunk 被截半（137→1） | marker 判定要求数字后跟非数字边界 + onDone 兜底 | 代码核实 |
| M1 | 🟠 高 | P1 | cmd `%errorlevel%` 陈旧值 | `call echo marker%^errorlevel^%` | 本机双上下文实测 |
| P2 | 🟠 高 | P1 | AI 流超时但缓冲非空 → 半截响应当完整执行 | `_aiStreamTimedOut` 一律抛 TimeoutException 走重试 | 代码核实 |
| M3 | 🟡 中 | P1 | writeFileViaPty 把回显的文件内容当交互提示 | 内容发送阶段跳过 detect，仅留 marker 扫描 | 代码核实 |
| M2 | 🟡 中 | P1 | `_handleDrop` 断线归为 unknown | 服务级断线标记 → 异常分支归类 disconnected | 代码核实 |
| P1 | 🟡 中 | P2 | 行内关键词任意位置切分，heredoc 含协议词被截断 | 关键词前须为空白 + heredoc 内容期禁切分 | 代码核实 |
| M4 | 🟡 中 | P2 | SSH 恒 POSIX 包装，远端 Windows 每条命令干等超时 | 连接后探测远端 shell，复用 Windows 包装分支 | 代码核实 |
| M5 | 🟡 中 | P2 | runOnce 超时不杀进程/不关 channel | ssh 关 session；local 改 Process.start + kill | 代码核实 |
| D1 | ⚪ 低 | P2 | 无事件老会话/导出渲染原始协议文本 | fallback 走 ReActStreamParser 结构化渲染 | 代码核实 |
| N1-N3 | ⚪ 低 | P2 | 动作行混用冒号/带注解值；报告段收集不感知围栏；示例 9 重号 | 见 §6.5 | 代码核实 |

**做对的、不动的**：R10 无动作行不执行、commandScope 过滤、FC 正文围栏不执行、提前执行的 `_textFromDeclaredAction` 门控、stableId（FNV-1a 64）去重、代际检查、分级超时（含 sudo 解包与用户倍数）、PS `$LASTEXITCODE` 置空推导、sudo 密码执行器内应答（R7）、256KB 尾缓冲、分级截断边界。

## 4. P0 详细设计（观测与清洗契约修复）

### 4.1 F1：失败观测重建

**目标数据流**：

```
CommandResult(stdout=真实输出, stderr='', failureKind, failureReason, exitCode)
  → AgentResult(output=清洗后stdout, error=null, failureKind, failureReason[新增], exitCode)
    → ReActObservation(output=截断后真实输出, error=截断后stderr(可空),
                       exitCode/failureKind/failureReason[新增])
      → format():
        观测: 命令 `foo --version` 执行失败 (退出码: 127)
        失败类型: unknown · 诊断: <failureReason>      ← 仅在有值时输出
        输出:
        -bash: foo: command not found
        错误:                                          ← 仅当 stderr 非空
        …
```

**改动清单**（按依赖序）：

1. `AgentResult`（agent_model.dart）：新增 `final String? failureReason`；`fromCommand` 增加同名可选参数并透传；`success` 改为 `exitCode == 0 && failureKind == null`（对齐事实 C；timeout 路径 exitCode=-1 且 kind=timeout，被 kind 条件覆盖）。
2. `ReActObservation`（agent_model.dart）：新增可选 `exitCode` / `failureKind` / `failureReason`。`format()` 失败分支重写：标题带退出码（非 null 时）；failureKind/failureReason 非空时输出一行诊断；`output` 非空且非 '(无输出)' 时输出「输出:」段；`error` 非 null 时输出「错误:」段；两者皆无才输出 '(无输出)'。**成功分支不变**。
3. `_executeCommand`（agent_engine.dart）：`fromCommand` 调用透传 `result.failureReason`。
4. `_runCommandWithSafetyInner` 观测组装处：失败时 `output: outputText`（真实 stdout 截断值，回滚提示仍追加在此）、`error: result.error 非空 ? errorText : null`，并传 exitCode/failureKind/failureReason。成功分支不变。
5. 同处 `AgentEvent.result` 口径同步：失败时 `error` 在 `result.error` 为空时传 null（不再把 '(无输出)' 当错误展示）；`rawOutputLength`/`shownOutputLength` 失败时改按 `outputText` 计（当前按恒空的 error 计，截断徽标失真）。
5b. **同段 `outputTail` 计算（实施期发现的漏项）**：`final raw = result.success ? result.output : result.error;` 失败时读到恒空的 error，证据层 8000 字符 `outputTail` 永远缺失真实失败输出 → 失败时也取 `result.output`。验收加断言：失败事件的 `outputTail` 含真实报错尾部。

**扇出核对（R9）**：`fromCommand` 调用方仅 2 处（引擎 + operation_report_test.dart）；`ReActObservation` 构造 9 处全在引擎（安全拦截/工具结果等路径自带 error 文本），新增字段皆可选命名参数，不受影响。

**终态路径矩阵（R5，每条路径的观测内容）**：

| 路径 | exitCode | failureKind | 观测新增内容 |
|---|---|---|---|
| 正常成功 | 0 | null | 不变 |
| 命令失败（exit≠0） | 实际码 | null | 真实 stdout + 退出码 |
| 超时 | -1 | timeout | 已收输出 + 「命令执行超时 (Ns)」 |
| 交互提示中断 | -1 | interactivePrompt | 已收输出 + 提示文本（见下） |
| 断线（onDone/_handleDrop） | -1 | disconnected | 「连接断开」诊断（M2 修复后两路一致） |
| 语法错误 | -1 | syntaxError | shell 报错原文 |
| 用户取消 | — | cancelled | 引擎自构 AgentResult，不走 fromCommand，不变 |
| 安全/权限拦截 | — | — | 引擎自构观测，不变 |

**sudo 链路注意**：规则 10 的 `provide_password` 依赖观测里出现提示文本。实施时须核对 `PtyOutputDetector` 的 interactivePrompt `diag.reason` 是否含提示原文；若不含，把 `confirmationPromptText`/提示尾部拼进 `failureReason`。这是 F1 的验收项之一，不是假设。

**验收测试**：
- 新增真实契约 e2e：mock 执行器按真实契约返回（`stderr:''`、报错在 stdout、exitCode=127）→ 断言观测含 `-bash: foo: command not found` 与退出码。**此测试在修复前必须红**。
- 超时路径 e2e：断言「命令执行超时」诊断到达观测。
- 改造 `observation_truncation_e2e_test.dart` 的 mock 契约（当前把报错放 stderr，与真实执行器相反——这正是 F1 长期漏网的原因，R9 典型陷阱）。
- `ReActObservation.format()` 单测：成功/失败/双空/带诊断四形态。

### 4.2 F2：AnsiStripper 残留清洗收紧

**新契约**：

1. **门控**：残留 OSC/CSI 清洗仅当原始输入含 `\x1B` 或 `\x07` 时执行。合法文本（无 ESC）不再进入残留清洗。
2. **收紧正则**（门控通过时也保护混在彩色输出里的合法文本）：
   - `_residualOsc`：`\][0-9]+;[^\n\r]*` —— 要求至少一位数字，`]0;标题` 仍清，`arr[0]; done` 的 `];` 不再命中。
   - `_residualCsi`：`\[[\x21\x30-\x3F][\x20-\x3F]*[\x40-\x7E]` —— `[` 后首字符必须是 `!`(0x21) 或 0x30-0x3F（数字 `; : < = > ?`），覆盖 `[0m`/`[?2004h`/`[>0;10;1c` 等真实残留；`[INFO]`、`[1,2,3]`（`,`=0x2C 不在参数集）、`[2026-11-19]`（`-`=0x2D 断开）不再命中。
3. 完整序列正则、prompt 前缀、控制字符、空行折叠各步不变。

**行为对照**：

| 输入 | 旧输出 | 新输出 |
|---|---|---|
| `[INFO] service started` | `NFO] service started` | 原样 |
| `[1,2,3]` | （空） | 原样 |
| `[2026-11-19] log line` | ` log line` | 原样 |
| `arr[0]; done` | `arr[0` | 原样 |
| `\x1b[1;32mActive\x1b[0m` | `Active` | `Active`（不变） |
| `\x1b]0;root@host:~\x07…` | 清标题 | 清标题（不变） |

**旧测试契约变更（必须同步改写，属契约变更不是回归）**：
- `ansi_stripper_test.dart` 「无 ESC 的 OSC 残留」例（`]0;root@host:~\nresult` → `result`）：新契约下无 ESC 不清理 → 改为带 ESC 上下文或删除，补「无 ESC 的 `]0;…` 原样保留」例。
- 同文件「无 ESC 的 CSI 残留」例（`[?2004h[Koutput[>0;10;1c` → `output`）：新契约下无 ESC 不清理；且裸 `[K`（无参数字节）即使在有 ESC 时也不再清。改写为带 ESC 的 `[?2004h`/`[>0;10;1c` 例。
- 新增回归例：上表四行合法文本 + 「彩色输出混 JSON」（`\x1b[32m[1,2,3]\x1b[0m` → `[1,2,3]`）。

**代价声明**：ESC 字节在传输中丢失的极端场景下，半截序列会作为噪声进入观测（噪声，非损坏）；裸 `[K` 残留不再清。两者都远轻于当前「每条输出都可能被毁」的现状。

### 4.3 F3：清洗只留一层（R8）

1. **删除**引擎 `_executeCommand` 里的第二次 `stripCommandEcho` 调用。`stripInteractiveEcho` 保留（按「记录的提示+答案」整行逐字匹配，安全）。
2. `stripCommandEcho` 函除此外无 lib 调用方（已 grep 核实）→ **删除函数**及 `output_truncation_test.dart` 中对应 group。
3. **执行器层回显去除升级为绕排容忍**：长命令在 PTY 80 列处被回显折行（插入 `\r\n`），精确 `indexOf(wrappedCommand)` 会 miss。两个执行器改为：用 `RegExp.escape(wrappedCommand)` 逐字符以 `\r?\n?` 连接构造正则，首次匹配处截断。命令长度 ≤500 字符（looksLikeCommand 上限），正则成本可接受。

**代价声明**：执行器去回显失败时（如终端对回显做了不可逆变换），命令回显可能残留在观测里——噪声，AI 通常能识别；优于现状「误删真实输出」。

### 4.4 H2：尾部提示符清洗精确化

1. **删除** ssh 的 `replaceAll(RegExp(r'[\]\$#]\s*$'), '')` 与 local 的 `[\]\$#>]` 版本。
2. 换为共享工具函数（放 `output_processor.dart`）`stripTrailingPromptLine`：**仅当最后一行整体匹配**下列形态之一时删除该行：
   - bash：`^[\w.-]+@[\w.-]+:[^\n]*[#$]\s*$`
   - cmd：`^[A-Za-z]:\\[^\n]*>\s*$`
   - PowerShell：`^PS [^\n]*>\s*$`
3. 与 H1 的协同：边界判定使完成发生在 marker 行的 `\r\n` 处，提示符通常根本进不了缓冲（完成后丢 chunk）；本函数只兜底同 chunk 到达的提示符。

**验收**：`cat data.json` 输出 `[1,2,3]` 尾字符保留；`[root@host ~]#` 尾行被删；JSON 末行 `]` 不被删。

## 5. P1 详细设计（执行层边界）

### 5.1 H1：marker 数字边界

1. `ExitMarkerScanner.donePattern` 改为 `marker\d+[^\d]`：数字后必须出现非数字字符（正常是 `\r\n`）才算完成；数字恰在缓冲末尾时等待下一 chunk。carry 逻辑不变（`marker.length+16` 足够覆盖边界字符）。
2. **兜底**：scanner 增加静态判定 `matchesAtEnd(String bufferTail)`（`marker\d+$`）。两个执行器的 `onDone` 路径：`markerSeen==false` 但缓冲尾部命中 → 按完成处理（提取退出码），避免「marker 刚输出完 channel 就关」被误判断线。
3. 退出码提取正则（ssh `RegExp('$marker(\\d+)')` 及 local 对应处）同步为边界形态，与 scanner 同一口径。
4. `PtyOutputDetector.detect` 的 `donePattern` 参数只用于「已完成则抑制异常检测」（已核实），边界形态兼容且更精确。

**测试更新**：`output_buffer_utils_test.dart` 现有 4 例中 3 例以裸数字结尾（`:123`/`:1`/`:0`）→ 按新契约补 `\n`；新增：`137` 拆 `1`/`37\n` 两片 → 第二片才完成且提取 137；数字在尾不完成；`matchesAtEnd` 兜底。
**影响面**：scanner 4 个使用点（ssh executeAndWait / writeFileViaPty，local executeAndWait / 另一处写文件路径），语义一致变更。

### 5.2 M1：cmd 退出码新鲜值

`wrapCommandWithExitMarker` cmd 分支改为：

```dart
if (!isPowerShell) return '$command & call echo $marker%^errorlevel^%';
```

实测证据见事实 F。更新 `local_shell_wrapper_test.dart` cmd 用例的期望串；真机验收：本地 cmd 会话先跑失败命令再跑成功命令，断言退出码分别为实际非零值与 0（修复前会串值）。

### 5.3 P2：AI 流超时统一走重试

`_callAI` 中 `if (_aiStreamTimedOut && fullResponseBuffer.isEmpty)` 改为 `if (_aiStreamTimedOut)`，一律抛 `TimeoutException` 走既有重试/备用模型路径，日志记录已收长度。

**决策理由**：半截响应可能含写了一半的 heredoc——执行它会让远端 shell 干等 EOF 直到命令超时，比丢弃重试更糟；抛错路径不写 `_conversationHistory`，重试天然干净。展示侧损失本轮已收思考文本，可接受（重试会重新生成）。
**验收**：单测模拟 watchdog 触发且缓冲非空 → 断言抛 TimeoutException、无命令事件发出。

### 5.4 M3：writeFileViaPty 阶段门控

`ssh_service.writeFileViaPty` 增加阶段标志：
- **阶段 1**（发出 `cat >`/`sudo tee` 后、发送内容前）：保留 `PtyOutputDetector.detect`——sudo 密码提示只出现在这个窗口；
- **阶段 2**（逐行发送文件内容期间）：**跳过 detect**，仅保留 marker 扫描与总超时。文件内容里的 `Password:`/`[Y/n]` 行不再触发误判。
- 卡死兜底：既有 timeout 覆盖（cat 挂起时超时返回）。

**验收**：写入含 `Password:` 与 `[Y/n]` 行的文件 → 不中断、远端文件字节数与内容一致（真机 Docker SSH）。

### 5.5 M2：_handleDrop 断线归类

`SSHService` 增加服务级标志（如 `_droppedWhileWaiting`）：`_handleDrop` 置位；`executeAndWait` 入口清除；异常完成分支 `abnormalReason` 为空且标志置位 → reason 记「SSH channel 已关闭（连接断开）」→ 既有推断逻辑归类 `disconnected`。与 F1 叠加后 AI 收到明确的重连引导。

## 6. P2 详细设计（解析边界与体验）

### 6.1 P1：行内关键词切分约束

`_splitLineByKeywords` 两条新规则：
1. **空白前缀**：行内（非行首）关键词仅当前一字符为空白（空格/Tab）时才作为切分点。`echo "命令: x"` 的 `"` 前缀不再触发；弱模型单行 `思考: xxx 动作: execute` 仍正常切分。
2. **heredoc 保护**：解析主循环维护 heredoc 状态——命令行含 `<<(\w+)` 时记录定界符，其后各行**不做关键词切分**，直到出现等于定界符的行。保护含协议词的文件内容。

**残留风险（记录不修）**：命令内无引号且空格前缀的协议词（`echo 说明: x`）仍会被切——罕见，且 R10/commandScope 已保证不会执行截断后的危险片段。
**验收（R9 e2e）**：真实形状输入 → 流式拼接 → 解析：heredoc 含 `命令:`/`说明:` 行 → 命令事件内容完整；单行多字段仍切分正确。

### 6.2 M4：远端 Windows SSH 探测

**实施期修正（比设计更便宜）**：connect() 已经在建连时执行 `uname -s -m` 并存入 `_osInfo`（获取系统信息处）。探测复用该结果，零新增开销——`_osInfo` 为空/`Unknown`（Windows OpenSSH 没有 uname）时补一次 `ver` 执行（`_client.execute`，不走 executeAndWait 包装链），输出含 `Windows` → 置服务级 `_remoteIsWindowsCmd`；否则维持现状（POSIX）。`executeAndWait` 的包装选择处（现恒 `posixWrapWithExitMarker`）按该标志分支到 `wrapCommandWithExitMarker` 的 Windows 分支（从 LocalTerminalService 提取为共享函数，R6 分支逻辑单点维护）。`writeFileViaPty` 在 Windows 远端直接返回不支持（stty/cat heredoc 语义不存在）。远端 PowerShell 识别留作后续版本。

### 6.3 M5：runOnce 超时资源回收

- ssh：持有 `execute()` 返回的 session 引用，超时/异常时 `session.close()`，防止远端进程继续跑、channel 泄漏（R2）。
- local：`Process.run(...).timeout()` 超时不杀进程 → 改 `Process.start` + stdout 收集 + 超时 `process.kill()`。

### 6.4 D1：raw fallback 结构化渲染

`terminal_page._buildAIContent` 的 raw fallback 与 `conversation_export` 对应处：先 `ReActStreamParser.parse(content)`，有事件则按结构化渲染/导出；解析为空才保留原文。老会话的协议行不再当正文显示。

### 6.5 小项（N1-N3）

- **N1** 混用冒号取值缺陷全库共 **5 处拷贝**（实施期 grep `contains('：')` 核实）：`_declaredTextAction`、`_declaresExecuteAction`、`_textFromDeclaredAction`（commandScope 门控路径——漏修则混用冒号行 declaredAction 可识别但 scope 返回 null，R10 丢整轮命令）、`parseToolAction` 内 2 处（`工具:`/`参数:` 值解析）。当前 `contains('：')` 优先全角，`动作: execute（执行）` 类混用行取错分隔符；且动作值不容忍尾随注解。要求：冒号取 ASCII 与全角中**先出现**者、值取首个词，抽单一 helper 五处共用；完成后 grep 该模式在 agent_engine.dart 归零。`_parseReActResponse` 里的 `动作:` 行扫描仅判前缀不取值，不受影响。
- **N2** `parseReportSections` 收集循环加围栏感知，与 `parseAnswerBlock` 同口径（报告段内的 ``` 块不被当段边界）。
- **N3** `prompts.dart` 重复的「✅ 示例9」重编号。

## 7. 测试与验收计划

**原则（R9）**：每个契约变更配「修复前红 → 修复后绿」的测试；凡涉流式/解析/观测格式，必须有真实形状输入的 e2e；mock 执行器契约必须与真实执行器一致（stderr 恒空）。

| 阶段 | 测试文件（新增/改造） | 关键用例 | 结果 |
|---|---|---|---|
| P0 | 新增 `test/failure_observation_e2e_test.dart` | 真实契约 127 失败 → 观测含报错；超时诊断到达；sudo 提示文本到达 | ✅ 8 例绿（修复前红过：观测恒「(无输出)」）；含 format() 四形态单测 |
| P0 | 改造 `observation_truncation_e2e_test.dart` | mock 契约改为 stderr 空 | ✅ 失败用例 mock 改 `stdout=报错` 后绿 |
| P0 | 改造 `ansi_stripper_test.dart` | §4.2 契约变更 2 例 + 回归 5 例 | ✅ 10 例绿 |
| P0 | 改造 `output_truncation_test.dart` | 删 stripCommandEcho group；新增 stripTrailingPromptLine 组 | ✅ 27 例绿 |
| P0 | 新增执行器回显绕排单测 | 80 列折行回显被去除 | ✅ `output_truncation_test.dart` stripWrappedEcho 组 |
| P1 | 改造 `output_buffer_utils_test.dart` | §5.1 边界 4+3 例 | ✅ 8 例绿（137 跨 chunk / matchesAtEnd 兜底） |
| P1 | 改造 `local_shell_wrapper_test.dart` | cmd 期望串更新 | ✅ 绿（期望 `dir & call echo EXITCODE_3:%^errorlevel^%`） |
| P1 | 新增 AI 流超时单测 | 缓冲非空仍抛 TimeoutException | ✅ `test/ai_stream_timeout_test.dart` 绿（见 §10.6 测试基建坑） |
| P1 | 新增 writeFileViaPty 单测（可 mock 流） | 内容含 Password: 不中断 | ⬆ 以代码走查+全量回归覆盖（阶段门控标志），专项 mock 流单测未单独建 |
| P2 | 新增 react_parse heredoc e2e | §6.1 两形态 | ✅ `test/react_parse_keyword_split_test.dart` 13 例绿 |
| P2 | 新增 _declaredTextAction 单测 | 混用冒号/注解值 | ✅ `test/declared_action_test.dart` 10 例绿（经 `declaredActionForTest` 测试入口） |
| P2 | 新增 raw fallback 渲染测试（D1） | 协议正文不再露出「动作:」行、导出分节 | ✅ `test/raw_fallback_render_test.dart` 9 例绿（纯函数 4 + 导出 4 + widget 1） |

**真机验收**（green tests ≠ proof，按设备验证规则复拍）：
- 本地 cmd + PowerShell：失败→成功命令序列退出码正确（M1）；`type data.json` 尾 `]` 保留（H2/F2）。**状态：未执行（blocked，本轮无设备复拍条件），实施时 M1 包装串已在本机交互 cmd 与 `cmd /c` 双上下文实测（事实 F），但 app 内端到端序列未拍。**
- Docker SSH（见本地 E2E 资源）：`foo --version` 失败 → 观测/回答引用真实报错（F1）；写含 `Password:` 的文件完整（M3）；`cat` 彩色+JSON 混合输出无损（F2）。**状态：未执行（blocked）。**
- 每次真机验证前按 trace 末事件确认无运行中任务再重启 app。

**基线**：实施前重跑 `flutter analyze` / `flutter test --no-pub` 记录当前基线（2026-11-06 快照为 33 issues / 938 passed，已过期仅作量级参考），收尾对比。
**收尾实测（2026-11-19）**：`flutter analyze --no-pub` 82 issues、0 error（warning 中 model_picker_panel_test / pty_output_detector_test 两条属 HEAD 基线自带，git diff 为空可证，与本次及并发会话均无关）；`flutter test --no-pub` **1703 passed / 25 skipped / 0 failed**。

## 8. 风险与回滚

- 每阶段独立 commit（P0 内 F1 / F2+F3+H2 可再拆两个），任一阶段观测回归可单独 revert。
- F2/H2/H1 改变输出契约：若线上出现「观测噪声变多」，属预期代价（§4.2/§4.3 代价声明），不回滚；若出现「命令卡死/误判完成」，优先回滚 H1。
- 共享 worktree：其他会话并行改动，stage 只加本任务文件；不 stash。
- M4 探测增加连接后 ~1s 开销，失败回退现状，无阻塞风险。

## 9. 验证附录（二次逻辑验证记录）

设计定稿前对代码与候选方案做的第二轮核实，修正了以下认知：

1. **M1 候选实测淘汰**：`call echo %%errorlevel%%` 在 `cmd /c` 上下文输出 `MARKER%0%`（内层变量第一遍就被展开），仅交互模式可用；`setlocal EnableDelayedExpansion` 同行式 `!errorlevel!` 不展开（整行先解析）。最终 `%^errorlevel^%` 形态在两种上下文均取到新鲜值（MARKER7/MARKER0/MARKER137）。
2. **M2 范围修正**：审计初稿称「断线一律 unknown」不准确——`onDone` 路径已归类 disconnected，仅 `_handleDrop` 路径落 unknown。修复范围收窄到后者。
3. **success 口径**：`fromCommand` 与 `CommandResult.success` 当前等价（异常路径皆 exitCode=-1），F1 仍显式对齐，消除隐式约定。
4. **三个现有测试编码了缺陷行为**（ansi 无 ESC 残留 2 例、scanner 裸数字尾 3 例）——修复必须同步改写，这是契约变更；「测试红」不等于回归，评审时按 §4.2/§5.1 对照。
5. **stripCommandEcho 扇出**：lib 内仅引擎 1 处调用，可安全删除；测试 group 同步删。
6. **donePattern 在检测器中的用途**：仅用于「已完成则抑制异常检测」，边界形态兼容。
7. **sudo 提示文本是否进入 failureReason 未核实**——列为 F1 实施时的强制核对项（§4.1），不做假设。
8. **AnsiStripper 门控的原始动机**（ESC 丢失后的残留）与门控条件互斥——这是有意的取舍：无 ESC 时残留是噪声而非损坏，现状的无条件清洗才是损坏源。已在 §4.2 代价声明中记录。

## 10. 实施注记（2026-11-19，与设计的全部偏差与澄清）

实施过程中的实际落地与设计的差异，全部经代码核实。定位以符号名为准。

1. **F1 §4.1 sudo 强制核对项已闭环（非假设）**：`PtyOutputDetector` 的 interactivePrompt `diag.reason` 是**固定文案**（「命令进入交互式密码提示…」等），不含提示原文。不采用「把提示尾部拼进 failureReason」方案——F1 后观测的「输出:」段携带已收 stdout 原文（含 `[sudo] password for root:`），`failure_observation_e2e_test` 以 `contains('password for root')` 实测通过。规则 10 provide_password 链路可达性由输出段满足。
2. **N1 取值 helper 比设计多容忍一类形态**：`AgentEngine._protocolValue` 在「先出现的 ASCII/全角冒号 + 首个空白前的词」之外，额外把 `（(【[` 也作为值的结束符——`动作: finish（原因：磁盘已清理）` 这类**注解紧贴值**（无空格）的形态在真实模型输出里高频。5 处调用点全替换；`@visibleForTesting declaredActionForTest` 为新增测试入口。
3. **N3 处理方式**：不是改写示例 9，而是把其后 4 个示例（原 10-13，prompts.dart 4 处标题）整体重编号为 10-13，使「示例9」全库唯一。
4. **M3 超出设计范围**：设计只写 ssh，本地 `local_terminal_service.writeFileViaPty` 同样有「文件内容被 detect 误判为交互提示」问题，`contentSending` 阶段门控在两处同时落地。
5. **F2 `_residualCsi` 最终正则与设计不同（自纠）**：设计稿 `\[[\x21\x30-\x3F][\x20-\x3F]*[\x40-\x7E]` 经探针证伪——终止字节 0x40-0x7E 含 `,`(0x2C 不在内但 `-`=0x2D 会先截参数段) 且 `[2026-11` 前缀仍可能部分命中。最终形态 `\[[\x30-\x3F]+[A-Za-z@]`：参数段≥1 个 ECMA-48 参数字节、终止字节限字母/@，裸 `[K` 不再清（设计已声明的代价），`[1,2,3]`/`[2026-11-19]` 实测原样保留。
6. **P2 测试基建坑（R9 e2e 复现形态）**：mock 流用 `async*` generator 挂起时，引擎 `await _aiStreamSub?.cancel()` 会被 generator 的 await 点拖住永不收口——`ai_stream_timeout_test` 改用 `StreamController`（add 后不 close）模拟挂起，第二轮返回 finish 使任务收口。写同类测试必须照此形态。
7. **M4 落地细节**：`windowsWrapWithExitMarker(command, marker, {required isPowerShell})` 提取到 `command_executor.dart`（R6 单点维护），本地与远端 Windows SSH 共用；连接后探测在 `uname` 结果为空/Unknown 时补 `ver`（5s 双超时），命中则 `_remoteIsWindowsCmd=true` **且 `_osInfo='Windows'`**——后者让引擎平台推断（`KnowledgeService.detectPlatformFromOsInfo`→'windows'）自动正确，属设计外的联动收益。`writeFileViaPty` 在 Windows 远端直接返回失败并给出 SFTP/`echo`/PowerShell `Set-Content` 建议。
8. **H1 使用点为 4 处 + 2 处兜底**：donePattern 边界形态在 scanner 单点改；`matchesAtEnd` 兜底在 ssh executeAndWait / ssh writeFileViaPty / local executeAndWait / local writeFileViaPty 的 onDone 与异常前路径全部接入；退出码提取统一为 `marker(\d+)(?:[^\d]|$)` 边界形态并以 `replaceRange` 就地移除 marker。
9. **D1 两处防误伤门控**：`hasVisibleReactEvents`（思考/命令/正文/询问/完成任一）——plan-only 事件流不产出正文，解析结果无可见事件时必须继续原文兜底，否则正文变空白；`terminal_page` 的解析结果按正文字符串在 State 上缓存（build 期每帧重 parse 是白费）。`events.isEmpty` 的消息维持基线行为（raw fallback 历来只在有事件段内生效），与事实 G 一致。
10. **`AgentResult.fromCommand.success` 显式对齐**：`exitCode == 0 && failureKind == null`（事实 C 的约定固化），消除对「异常必返 -1」的隐式依赖。
11. **真机验收未执行**：见 §7 末两项 blocked；本机 cmd 双上下文的 M1 包装串实测（事实 F）不能替代 app 内端到端复拍。

### 10b. 回归自审（实施后复审发现并已修复的 3 个实施缺陷）

实施完成后对全量 diff 做回归审查，发现 3 个**由本次实施引入**的缺陷，均已修复并复测（1704 全绿）：

- **P2 重试是假的**（最重）。`throw TimeoutException` 落在流建立重试循环（`while(true)` 只包住 `chatStream` 建流段）之外的消费段末尾，异常直接落 ReAct 循环层 catch → 任务 `failed`，探针实测 `chatStream calls=1`、无任何重试。**原测试 vacuous pass**（mock 第二轮 finish 从未被消费，三条断言在直接 failed 时也全绿）。修复：`_aiStreamTimedOut` 处置移入 `_callAI` 尾部，以尾递归重试（新栈帧丢弃全部半截局部状态；`commandDetectedNotified` 已置位时禁重试防二次执行；任务级上限 2 次）；新增 `onStreamDiscarded` UI 桥丢弃当前轮 streamingContent（不 flush，防半截 heredoc 并入正文）；测试补 `calls>1` 硬断言。
- **失败结果卡输出双份**。`outputTail` 的 `shown` 在失败分支取了恒 `'(无输出)'` 的 errorText 比长度 → 几乎每个失败卡附带一份与正文重复的 ≤8000 字符尾部 + 失真徽标。修复：`shown` 统一取 `outputText`（卡片正文实际渲染的内容），仅真截断时给尾部证据。
- **拦截观测正文重复**。`format()` 新失败分支对拦截类观测（同一原因同时放 output 与 error 的历史契约）输出两遍相同文本。修复：error 被 output 包含时跳过「错误:」段；9 处构造点不改。
- 附带修复 D1 过度解析：raw fallback 现先做协议行探测（行首 思考:/动作:/… 正则），无协议行的普通 Markdown 不再进解析器——否则围栏会变带执行按钮的命令卡（对旧会话回答里代码示例产生**可点击执行**的 UI 操作风险）。

### 10c. 已知残留风险（评估后不修，理由如下）

- M4 探测以 `ver` 输出含 Windows 判 cmd；远端默认 shell 为 PowerShell 且 banner 含「Windows PowerShell」时会误按 cmd 包装挂到超时。设计 §6.2 已声明「远端 PowerShell 识别留作后续版本」，维持现状。
- M3 `contentSending` 后跳过 detect：`sudo -n` 预检覆盖常见场景，剩余「预检→写人间 sudo 时间戳过期」的窗口内文件行会打进密码提示（延迟失败非挂死）；换取内容期不再误判，维持。
- F2 门控只保护「无 ESC」输入；含 ESC 的彩色输出里 `foo[1b]`/`[45m]` 类合法文本仍会被残留规则吃掉。设计 §4.2 代价声明覆盖此残余（噪声），完全无损需状态机级 ANSI 解析，不在本期。
- 超时/异常路径的 CommandResult.stdout 未去回显（成功路径才 stripWrappedEcho）：F1 后这类观测首次携带真实输出（此前恒「(无输出)」），回显属新增噪声、非损坏，与 §4.3 代价声明一致。
- M5 local runOnce 由 systemEncoding 改 utf8 解码：Dart 3 在 Windows 上 systemEncoding 本身即按系统码页/UTF-8 处理，且监控脚本强制英文输出，影响面≈0；超时分支 stdout 尾收集（2s）在极端竞态下可弃全部部分输出，runOnce 调用方（监控/探测）对部分输出本就不依赖。