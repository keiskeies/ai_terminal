# 终端能力差距评估与补齐路线（以 AI 架构为约束）

状态：P0/P1/P2 已实现（P3 未开始）。逐项落地情况见 §6 各「实施注记」；未做项与已知边界也在其中注明。
适用范围：`ai_terminal/lib/widgets/terminal_view.dart`、`lib/pages/terminal_page.dart`、`lib/services/ssh_service.dart`、`lib/services/local_exec_tool.dart`、`lib/utils/terminal_charset.dart`（原 `terminal_encoder.dart` 已并入）
关联：`docs/agent-permission-mode-design.md`（权限档位）、`docs/agent-local-exec-design.md`（本地执行）、AGENTS.md R1/R3（异步与归属规则）

---

## 1. 背景与原则

对标 Windows Terminal / iTerm2 / Xshell / SecureCRT / Tabby / FinalShell / Termius 做了一轮功能盘点（2026-11-14）。结论：AI 执行安全链路、多机编排、Runbook、监控是差异化强项；终端本体是 xterm.dart 4.0.0 的最小参数封装，日常体验有系统性差距。

**本文不是照抄清单。** 本产品是「AI 运维优先」的终端，AI 与终端共享执行通道，传统功能直接搬进来会和 AI 架构打架（典型：分屏后 AI 的命令打到哪个屏？）。因此每个差距项先过一道筛子：

| 处置 | 含义 |
|---|---|
| **修** | 配置/代码已存在但不生效，bug 级 |
| **补** | 与 AI 架构无冲突，纯 app 层欠账，直接做 |
| **改** | 与 AI 架构有冲突，先定路由/归属/脱敏设计再做 |
| **替** | 传统形态与 AI 能力重复，用 AI 形态替代或不做 |

## 2. 决定设计的三个架构事实

以下事实已逐一在代码中核实，是后文所有路由设计的依据。

**事实 A：SSH 侧，AI 与用户终端共用同一个 shell 会话。**
`ssh_service.dart:143` 只打开一个 `_session = await _client!.shell(...)`；用户终端输入走 `execute()`（:510）写入它，AI 的 `executeAndWait()`（:225）也写入它，输出统一经 `outputController`（:158）进终端。所以 **AI 的命令回显和输出今天就出现在用户终端里**——这是有意设计（用户能看着 AI 干活，sudo 自动应答也走这个通道）。

**事实 B：本地侧，AI 走独立进程，与用户 PTY 天然隔离。**
`local_exec_tool.dart` → `runLocalCommand`（`local_shell.dart:180` `Process.start`），每条命令一个非交互进程，不碰用户的本地终端 PTY。工具描述明确「需要交互输入时请改用终端」。

**事实 C：Agent 按 host 绑定，一个 host 一个 executor。**
`agent_host_registry` 按 hostId 管理引擎；任务启动时捕获 host（AGENTS.md R3）。分屏若引入「同 host 多会话」，绑定粒度必须从 host 细化到会话。

推论：**分屏的路由问题只存在于 SSH 侧**（事实 A）；本地侧每 pane 各开 PTY 即可，AI 不受影响（事实 B）。任何「AI 输出独立通道」的方案都要动事实 A 的共享设计，代价最大。

## 3. 差距处置总表

| 功能 | 传统工具 | 与 AI 架构的关系 | 处置 | 优先级 |
|---|---|---|---|---|
| GBK/BIG5 编码 | Xshell/FinalShell | 显示侧无冲突；AI 执行链路（marker 扫描/UTF-8 假设）有冲突 | 修+改 | P0 显示 / P1 AI 链路 |
| 桌面中文 IME | 全部 | 无冲突 | 修 | P0 |
| bell 响应 | 全部 | 无冲突（BEL 目前还被 `ansi_stripper.dart:11` 剥掉） | 补 | P0 |
| 矩形/块选择 | iTerm2/Xshell | 无冲突，xterm `setSelectionMode(block)` 已有 API | 补 | P0 |
| 回滚行数可配 | 全部 | 无冲突（现固定 10000，`terminal_page.dart:701`） | 补 | P0 |
| Ctrl+点击开链接 | 全部 | 无冲突（现仅右键识别） | 补 | P0 |
| 字号缩放快捷键 | 全部 | 无冲突 | 补 | P0 |
| 终端内搜索 Ctrl+F | 全部 | 无冲突；scrollback 含 AI 输出，搜得到 AI 命令反而是优点 | 补 | P1 |
| keepalive + 自动重连 | 全部 | **有冲突**：重连换 `_session`，运行中 AI 任务会挂 | 改 | P1 |
| 端口转发 UI（本地/远程/SOCKS） | Xshell/Tabby/Termius | 无冲突；`forwardLocal` 已用于跳板（`ssh_service.dart:97`），缺用户入口 | 补 | P1 |
| SFTP 拖拽上传下载 | FinalShell | 无冲突 | 补 | P1 |
| 自动会话日志 | Xshell/SecureCRT | **有冲突**：全量录制可能把 sudo 应答写进日志，破坏现有脱敏保证 | 改 | P1 |
| 分屏 pane | 全部 | **核心冲突**：AI 绑定哪个 pane 的会话（见 §4） | 改 | P2 |
| 主题/字体/快捷键自定义 | Tabby/WT | 无冲突 | 补 | P2 |
| ~/.ssh/config 导入、主机导入导出 | Tabby/Termius | 无冲突，迁移门槛 | 补 | P2 |
| OSC 133 命令块 | Warp/Wave/iTerm2 | 共享会话下 AI 命令天然成块，是 AI 差异化放大器 | 补 | P2 |
| 广播输入（多会话同步敲命令） | Xshell/FinalShell | 与 `exec_batch` 重复，且裸广播没有安全语义 | 替 | 不做 |
| 命令历史 UI（持久化+搜索） | FinalShell | 与 AI 审计互补 | 补 | P2 |
| 定时任务（Runbook cron） | 部分 | 无冲突，但引入无人值守执行，需权限档位约束 | 改 | P3 |
| telnet/串口/mosh | Tabby/Termius | 无冲突，但偏离运维定位 | 替 | 不做（除非用户群要求） |
| X11 转发、Quake 模式 | Xshell/iTerm2 | 无冲突，价值低 | 替 | 不做 |
| 断点续传 | FinalShell 部分 | 无冲突；现临时文件全量+原子替换 | 补 | P2 |
| rz/sz Zmodem | Xshell/FinalShell | 与 SFTP 重复，国内肌肉记忆 | 替 | P3 观望 |

## 4. 重点设计：分屏 × AI 路由

### 4.1 问题

传统分屏假设「每个 pane 是独立终端，用户敲哪个屏命令就去哪」。本产品 SSH 侧 AI 与用户共享一个 shell 会话（事实 A），分屏后必须回答：

1. AI 的命令写入哪个 pane 的会话？输出显示在哪？
2. 用户在 pane 2 工作时，AI 在 pane 1 执行，视线来回跳，体验割裂。
3. 绑定 pane 被关闭/重连，运行中任务归属悬空。

### 4.2 三个方案

**方案 A：AI 固定打到第一屏。**
最简单，但「第一屏」是位置概念不是身份概念：用户关掉第一屏后绑定悬空；用户在第二屏排查问题时 AI 输出永远在视线外。不推荐作为最终形态，可作为过渡默认。

**方案 B（推荐）：AI 绑定「任务启动时的活动 pane」，显式徽标 + 可改绑。**

- 每个 pane 拥有独立 shell 通道（dartssh2 的 `SSHClient` 支持在同一连接上开多个 `shell()`，连接池复用，不需要多 TCP 连接）。
- 绑定粒度从 host 细化到 pane 会话（事实 C 的延伸）：任务启动时捕获 `paneSessionId`，**任务期间绑定不随用户切换 pane 漂移**——与 AGENTS.md R3「任务捕获启动时归属」同构。
- 默认初始绑定 = 第一个 pane（吸收方案 A 的简单性，回应用户「输入到第一个屏」的建议）；用户可在 pane 标题栏显式改绑。
- 绑定 pane 标题显示 AI 徽标（如 `● AI`），任务运行中徽标常亮；非绑定 pane 是纯用户终端，AI 绝不写入。
- 绑定 pane 关闭：运行中任务按现有取消路径终止（R1/R2），不静默迁移到别的 pane——迁移会让用户以为命令在 A 屏执行实际去了 B 屏，比取消更危险。
- 本地 pane 无需任何路由（事实 B），各开各的 PTY。

**方案 C：AI 独立隐藏通道，不占 pane。**
隔离最干净，但失去「看着 AI 在终端里干活」的现有体验，且要重构 `executeAndWait` 与终端输出的共享关系（事实 A），改动面最大。除非未来出现「AI 后台静默执行」的强需求，否则不做。

### 4.3 成本与排期理由

`terminal_page.dart` 5000+ 行按「一 tab 一终端」耦合：pane 级 session 生命周期、独立 resize（每 pane 自己的 PTY 尺寸）、监控 chips 归属、AI 绑定路由都要拆。这是它排 P2 而非 P1 的原因——**不是功能不该有，是路由设计和解耦成本要先付**。P0/P1 的单项都不依赖它，可先行。

落地时的实际成本远低于上面的估计：把「第一个 pane」定成**身份而非位置**（首屏 id 就是 tabId），25 个按 tab 键控的 map 与 10 处 `setExecutor` 就都不必重新键控，额外 pane 只做侧表。详见 §6「P2 实施注记：分屏」。

## 5. 其他冲突点的设计约束

**自动重连 × 运行中任务（P1）**
重连会替换 `_session`，运行中 `executeAndWait` 的 marker 等待者必须被 complete（现有 `onDone` 已做，:169-173）。规则：任务运行中不做静默自动重连；断线即任务 `failed`（R5），重连后由用户/引擎显式重试。keepalive 心跳独立于任务，可直接加。

**自动会话日志 × sudo 脱敏（P1）**
现有保证：sudo 密码自动应答不进日志/上下文（`agent_engine.dart:3906-3916`）。全量终端录制会把 stdin 应答和 PTY 回显一并录下。做日志前必须：录制点放在回显清洗之后，或对 sudo 应答段做掩码；验收用例必须包含「sudo 命令全程日志中无密码」。

**GBK × AI 执行链路（P0 显示 / P1 链路）**
`TerminalEncoder` 已实现 GBK/Big5 但全库零引用；SSH/PTY 输出硬编码 `Utf8Decoder`（`ssh_service.dart:155`）。注意不只是换 decoder：`executeAndWait` 的 EXITCODE marker 扫描、`posixWrapWithExitMarker`、SafetyGuard 正则都建立在 UTF-8 假设上。分两步：先接终端显示/输入编码（纯终端侧），AI 链路编码适配单独做，避免一次改动横跨两条流水线。

**广播输入 × exec_batch（不做）**
手动广播 = 同一条命令裸发 N 个会话，没有只读并行/写串行/stopOnFailure 语义。AI 的 `exec_batch`（`multi_host_executor.dart`）已是更安全的超集。做裸广播等于给用户一条绕过安全编排的旁路，与产品定位相悖。

## 6. 路线图

- **P0（修硬伤 + 低垂果实，互不依赖）**：GBK 显示侧接线、桌面 IME、bell、块选择、回滚可配、Ctrl+点击链接、字号缩放快捷键。
- **P1（无冲突标配 + 带约束的改造）**：终端搜索（内置高亮原语，见实施注记）、keepalive+自动重连（§5 规则）、端口转发 UI、SFTP 拖拽、自动会话日志（§5 脱敏）、GBK AI 链路。
- **P2（需设计/解耦）**：分屏（§4 方案 B）、主题/快捷键自定义、ssh-config 导入、OSC 133 命令块（接「一键让 AI 解释本块报错」）、命令历史 UI、断点续传。
- **不做**：裸广播、X11、Quake；telnet/串口/Zmodem/定时任务挂 P3 观望，等用户群信号。

### P0 实施注记：Windows 引擎 TextInput 缺陷与原生绕路

真机实测 Flutter 3.47.8 Windows 引擎有三处 TextInput 缺陷，桌面 IME 最终采用「Windows 零客户端」架构：

1. `TextInput.setClient` 不携带 `viewId` 直接拒绝（`view ID is null`），xterm 自带 CustomTextEdit 路径因此收不到组字。
2. IME 组字模型损坏：后续 update 的组字串翻倍（comp+comp）、上屏也翻倍，TextField 同样受影响（引擎级回归，非 app 代码）。
3. attach 客户端后，IME 英文模式下引擎吞掉 Ctrl+C/V 等编辑键——终端中断键失效，不可接受。

绕路（`windows/runner/flutter_window.cpp` 子类化 Flutter 视图 HWND）：Windows 终端**不 attach TextInput**；拦截 `WM_IME_*` 取 `GCS_RESULTSTR` 经 MethodChannel `com.keiskei.aiterminal/ime` 上屏；转发孤儿 `WM_CHAR`（Unicode 注入；注意 SendInput 会伴随 VK_PACKET keydown，须排除以免误判为物理键）；`ImmSetCandidateWindow` 按 Dart 上报的光标矩形定位候选窗；焦点 gating 保证 AI 输入框聚焦时 IME/注入仍走引擎 TextField 路径。macOS/Linux 保留自 attach TextInputClient（引擎正常）。

### P1 实施注记：终端搜索用内置高亮原语，而非自绘 overlay

落地时发现 xterm.dart 4.0.0 **已有高亮原语** `TerminalController.highlight(p1, p2, color)`（`ui/controller.dart`），渲染器在 `_paintHighlights` 原生绘制，锚点（`BufferLine.createAnchor`）随 buffer 增删/重排自动跟随。因此搜索不必自绘 overlay：

- 匹配计算遍历 `terminal.buffer` 逐行文本（`utils/terminal_search.dart`），宽字符（CJK）按 cell 列映射，字面量搜索默认忽略大小写（用 RegExp 折叠避免 `toLowerCase` 下标漂移），命中封顶 5000。
- 高亮/当前命中用 `controller.highlight` 两色区分；上一个/下一个经外部 `ScrollController`（xterm `TerminalView.scrollController` 入参）`jumpTo` 到命中行。
- 快捷键 Ctrl+Shift+F（mac ⌘F），Esc 关闭；搜索框 `onEditingComplete: () {}` 阻止默认 `done` 动作 unfocus，保证 Enter 跳下一个后仍能继续输入。
- 已知限制：Windows 搜索框走引擎 TextField，中文 IME 组字受同一引擎缺陷影响（与 AI 输入框一致），英文/ASCII 搜索不受影响。

### P1 实施注记：keepalive 已由库默认提供，自动重连只做空闲路径

- **keepalive 无需新代码**：dartssh2 3.3.1 的 `SSHClient` 默认 `keepAliveInterval = 10s`（`SSHKeepAlive` 周期 ping，失败由 transport 处理断连），app 未禁用，即已生效。
- **断线检测**：`SSHService` 的 shell stdout `onDone/onError` 统一走 `_handleDrop()`——complete 所有 marker 等待者（R1），非主动断开时经 `onDisconnected` 回调一次（`_intentionalDisconnect`/`_dropNotified` 去重）。provider 收到回调把 tab 标为 `lost`（曾连接过，保留回滚内容）。主动 `disconnect()`、关闭标签、手动重连前都先清回调，避免误报。
- **自动重连**（`terminal_page._maybeAutoReconnect`）：仅 `connected→lost` 迁移且 `AgentNotifier.isRunningFor(tabId)` 为 false（含 paused/waitingConfirm）时触发；`ReconnectPolicy` 1s/2s/4s 退避最多 3 次，复用 `_reconnectTab`（保留 tabId/回滚/AI executor 重绑）。等待期与触发前双重检查 tab 仍在、仍 lost、仍无任务。重连成功清零计数；本地 PTY 退出是正常结束，不自动重启。
- **状态迁移检测**：`TerminalTab` 在 provider 里原地复用，prev/next state 是同一实例，页面用 `_lastTabStatus` 自记上一帧状态（`ref.listen` 内）。
- 任务运行中断线：不自动重连，任务按 R5 走 `failed`，重连后由用户/引擎显式重试（§5 规则不变）。

### P1 实施注记：自动会话日志的脱敏与录制点

- **默认关**（开放问题 2 的落地决定）：外观设置页「自动会话日志」开关，对新开标签生效；日志落 `getApplicationSupportDirectory()/session_logs/<主机>_<时间戳>.log`，单文件 20MB 封顶。
- **录制点**：tab 输出订阅处（`terminal_page._setupTerminalListener`，provider 转发之后、xterm 写入同层），录解码后的文本；去 ANSI 转义、规范化换行，500ms/64KB 批量刷盘。
- **sudo 脱敏**（`SecretMasker`）：两个执行器（SSH/本地 PTY）应答 sudo 前 `register(密码)`，`executeAndWait` 的全部退出路径（超时/catch/异常/正常）`unregister`。录制器双保险：chunk 到达即掩码（防命令快速结束先于刷盘注销）+ 记录到达时的秘密快照，刷盘时用快照掩码（防跨 chunk 回显在注销后才拼齐）；尾部 512 字符 holdback 兜跨包命中。验收测试 `test/session_log_test.dart`：sudo 全程日志无密码、跨 chunk、迟到回显、注销竞态。
- 已知边界：用户手动键入的密码（非执行器应答）无法识别，不在脱敏范围；sudo 本身关回显，注册期掩码是纵深防御。

### P1 实施注记：端口转发与 SFTP 拖拽

- **端口转发**（`services/port_forward_service.dart` + `widgets/port_forward_dialog.dart`）：终端页「更多 → 端口转发」，规则随 tab 生命周期（关标签 dispose 全部转发）。本地转发 = 本地 `ServerSocket` 监听（默认只绑 127.0.0.1，不暴露局域网）+ 每连接 `client.forwardLocal`；远程转发 = `client.forwardRemote` + 连接回落到本地目标。复用连接池里该 tab 的 `SSHService.client`，不另建连接。连接断开后转发失效、规则保留错误状态，重连后重新添加。
- **SFTP 拖拽上传**（desktop_drop ^0.8.4，仅桌面）：文件/目录拖入面板即上传当前目录，目录走已有 `uploadDirectory`（并发+进度）。两个必要防护：`DropTarget` 是全局监听，Offstage 保活的隐藏 tab 面板必须 `enable=false`（页面传 `dropEnabled: isActive`）；弹层/新页面盖住面板时经 `RouteAware.didPushNext` 临时禁用。下载方向 desktop_drop 不支持 drag-out，需原生 OLE（Windows）/NSFilePromise（macOS）实现，暂缓，下载仍走条目菜单/「下载到本地」。

### P1 实施注记：GBK AI 链路只缺输入侧

落地时确认，输出侧在 P0 接线时就已顺带解决：`executeAndWait`/`writeFileViaPty` 监听的是解码后的 `outputController`，marker 扫描、`PtyOutputDetector`、`SudoPromptResponder` 拿到的都是主机编码解码后的文本，无需再改；EXITCODE marker 是纯 ASCII，GBK/GB18030/Big5 下字节不变，完成判定不受影响。剩下的只有输入侧——`wrappedCommand` 与 `writeFileViaPty` 的每行文件内容原先硬编码 `utf8.encode`，AI 在 GBK 主机上写含中文的文件会落成一堆 UTF-8 字节。

- **改法**：`OrderedCharsetWriter`（`utils/terminal_charset.dart`）把非 UTF-8 的写入串成一条 future 队列。编码是异步平台通道，不排队的话「命令 → 内容 → Ctrl+D」的字节顺序取决于谁先编完，内容会插队到命令前面。UTF-8 走同步分支，零开销零回归；用户按键与 AI 链路共用同一队列，避免两条链交叉。
- **控制序列**（`q`、Ctrl+C、Ctrl+D、`\n` 探活、sudo 应答）字节上与编码无关，但仍一并入队，防止越过尚未编完的内容写入。
- **开放问题 3 的落地决定**：不禁用 AI 执行。写入侧已按主机编码，读侧仍 UTF-8（见下），禁用一整类主机的代价远大于收益。
- **已知边界**：`runOnce` 走 exec channel + UTF-8 解码，输出不经 PTY 解码链路；SFTP 字节级读写与主机编码无关，但文本预览/编辑器（`readFileContent`）只接受严格 UTF-8，GBK 文件会明确报错而非乱码打开——这是有意的，编辑器整文件覆盖保存，乱码解码后保存会永久损坏原文件。

### P2 实施注记：ssh-config 导入、下载断点续传、命令历史

- **ssh-config 导入**（`utils/ssh_config_parser.dart` 纯解析 + `services/ssh_config_import_service.dart` IO + `widgets/ssh_config_import_dialog.dart`）：主机列表页右上角入口。解析按 OpenSSH 真实语义——同一指令**先出现者生效**，所以排在前面的 `Host *` 会遮蔽后文具体主机自己写的 `User`/`IdentityFile`。这不是 bug 但和用户肉眼看到的配置不一致，解析器把每处遮蔽写进 warnings，对话框原样展示。只导入 `HostName/Port/User/IdentityFile/ProxyJump`；`Match` 块之后的条件指令整段忽略并告警；通配别名不出条目。**凭据不导入**（私钥内容要用户选文件、密码拿不到），对话框与完成提示都写明需到编辑页补填。`Include` 支持目录与 glob，深度上限 3。
- **断点续传**（`sftp_service.downloadFile`）：临时文件名从随机 token 改成远程指纹 `<localPath>.ai-download-<sha1(path|size|mtime)前16>.part`。失败时保留 `.part`（原先直接删），重下时若指纹一致就从 `read(offset: 已下长度)` 续传；远程文件被改（size 或 mtime 变）→ 指纹变 → 旧 `.part` 判陈旧删除重下，因此不会拼出「半新半旧」的文件；字节数已满但没改名的残留直接落位。批量下载热路径不扫目录，只在确实存在自己的残留时才清理。上传方向原本就是「远程临时文件 + 原子 rename」，未改动。
- **命令历史**（`utils/command_tracker.dart` 捕获 + `utils/terminal_input_line.dart` 读屏 + `CommandHistoryDao` + `widgets/command_history_panel.dart`）：入口是终端右键菜单与「更多」菜单，快捷键 `Ctrl+Shift+H`（mac 也接受 `⌘⇧H`；`Ctrl+H` 是 readline 退格、`⌘H` 是隐藏窗口，都要留给原语义）。
  - **捕获点选在「回车瞬间读屏幕输入行」，不记按键**。密码提示下 shell 关掉回显，用户敲的密码同样是按键，把它抄进一个明文列表等于违反 §5 对会话日志的同一禁令；而按键序列本身也靠不住（方向键送 `ESC [ A`，↑ 调出的历史更不在按键里）。三道闸门：① `stripPromptPrefix` 必须真的剥掉前缀（挡掉 vim/less 正文里的回车）② 剥完必须有内容（关回显的密码提示后是空的 → 什么都不记，这条与 locale 无关）③ `looksLikeCommand`（与右键菜单同一口径）。另有一道输出侧的密码提示锁（`[sudo]`/`Password`/`密码`/`口令`，只认缓冲尾部，R8 不用裸子串）作纵深：锁住期间丢弃输入，最坏漏记一条，不会多记一个密码。已知降级：提示符正则认不出的 shell（如 cmd.exe 裸盘符）不记历史——历史只是便利功能，shell 自身的不受影响。
  - 读屏必须处理**折行**：命令比终端宽时 buffer 里是好几行，靠 `BufferLine.isWrapped` 往回并（上限 64 行，防异常 buffer 吞掉回滚区），段落一律裁尾部控制字符再拼，否则 `\r\n` 留在中间，粘贴出去等于多执行一次。回车时刚敲的字符其回显可能还躺在 16ms 批处理缓冲里，所以读之前先 `_flushTermWrite` —— 放在惰性闭包里，只在回车时付这个代价。
  - 存储：`command_history` 表（v7 迁移），同命令合并只推进 `usedAt`/`useCount`，整表进内存（上限 500 条）供面板即开即搜。填入走 `writeToTerminal`（与用户按键同一条编码队列，非 UTF-8 主机不错位）且不带回车，停在命令行等用户确认。

### P2 实施注记：配色预设、快捷键自定义、OSC 133 命令块

- **配色预设**（`core/terminal_themes.dart` + 外观页）：只做预设不做自由取色——16 色 ANSI 与前背景/光标/选区之间的对比度平衡很难调对，用户逐个改的结果通常是不能看。亮色变体允许缺省（One Dark / Dracula / Gruvbox 本就没有可靠亮色版），缺省即回落内置亮色，比硬造一套低对比度假亮色好。设置存 id，未知 id 静默回落到内置默认。
- **快捷键自定义**（`core/terminal_keybindings.dart` + `widgets/keybinding_editor.dart`）：动作是枚举、默认键表集中一处，设置里存「动作 id → 组合」的覆盖项，`TerminalKeymap.fromSettings` 每次读表构建。`actionFor` 拒绝无修饰的裸键（否则任何录入都可能吞掉普通输入）；录入 UI 拦下与既有动作的冲突并显示占用方。终端内所有加速键（含分屏、搜索、命令历史）都过这张表，且「当前动作不可用」时一律放行给 shell。
- **OSC 133 命令块**（`utils/terminal_blocks.dart`）：接 `Terminal.onPrivateOSC`，A/B/C/D 四个标记切成块，位置记 `CellAnchor` 而非行号——回滚裁剪与折行重排会让行号漂移，锚点保证相对位置不变；锚点被裁则该块作废，宁可不给「解释本块」也不把相邻两条命令的输出拼在一起喂给 AI。没装 shell integration 的会话恒 0 块，所有入口安静返回空、菜单不出该项。额外分屏 pane 各自挂自己的 tracker（paneId 与 tabId 共用同一张表）。

### P2 实施注记：分屏（§4 方案 B 落地）

落地时把方案 B 的「AI 绑定任务启动时的活动 pane」再收一格成**「首屏就是标签本身」**，路由问题因此从「绑定粒度细化」降为「不存在」：

- **首屏 id == tabId**。它的 Terminal、输出订阅、`SSHService`/`LocalTerminalService`、executor 绑定、AI 面板全部沿用原路径（`_tabTerminals` 等），一行没动 —— 10 处 `setExecutor` 与 25 个按 tab 键控的 map 都不必重新键控。额外 pane 的 id 是 `<tabId>#p1`，各装进一组以 **paneId** 为键的侧表（`_paneTerminals` / `_paneOutputSubscriptions` / `_paneTermWriteBuffers` / `_paneTermWriteTimers` / `_paneSessions`），永不注册 executor，AI 从结构上就写不进去。写缓冲助手用 `_isPaneId(id) => id.contains('#p')` 分流两套表。
- **会话通道**（`services/pane_session_service.dart`）：`LocalPaneSession` 各开一条 PTY（事实 B），`SshPaneSession` 用 `SSHService.client` 的 `client.shell()` 在同一条 TCP 连接上再开 shell（保住事实 A 的连接池语义，不额外建连）。非 UTF-8 主机的写入走同一个 `OrderedCharsetWriter`，否则「命令 → 内容」的字节顺序取决于谁先编完。
- **绑定不可漂移、不可迁移**：焦点在哪一屏只影响 Windows 原生 IME 的投递目标和「新 pane 插在哪」，不影响 AI（AGENTS.md R3 同源）。首屏在有其它屏时拒绝单独关闭并直接说明「这一屏绑定了 AI，请直接关闭标签」——关标签那条路径已有 `removeTab` → 取消运行中任务，符合 §4「宁可取消也不静默迁移」。
- **生命周期**：谁创建谁释放（R2）。建会话是异步的，`await` 后重新校验 `mounted` 与 pane 是否还在布局里（R1），否则关掉的分屏会留下孤儿 PTY。SSH 还要在 `await` 后比一次 **client 身份**：掉线→重连会换 client，挂在旧连接上的那条 shell 一旦登记，就是「看着在、敲键没反应」的一屏，且掉线清理根本看不见还没登记的它。主连接掉线 → 额外 pane 的 shell 随 client 一起作废，但**布局保留**（滚动内容不丢），重连后自动补开；还没首连成功就分屏的，同样在重连回调里补开。页面 `dispose` 遍历关闭全部 pane 会话。
- **断流约定（评审补的硬约束）**：`PaneSession` 自己死掉时必须自行 `close()` —— 页面只靠 `output` 的 onDone 判定「这一屏断了」，而 `close()` 是关流的唯一入口（`cancel()` 不触发 onDone）。据此 SSH 侧把 stdout 的 onDone 接到 `close()`（原先是空回调，shell 退出后那一屏永久卡在假活状态，重开条也不出现）；本地侧 `LocalTerminalService` 有意不关输出流（主标签断了还要能读回滚区），所以补了 `onExit` 事件供 pane 侧监听。页面 onDone 里把死会话从表里摘掉，重开条的判据（表里没有会话）才成立。
- **上限 4 屏**，超出时入口禁用并给出原因（每屏都是一个真实 shell）。分隔条用 `Expanded(flex:)` 而非按占比算宽度：flex 由布局引擎保证「分完且不重叠」，且 flex 最小 1 = 任何一屏都不会被拖成 0 宽再也点不回来；每侧另有 15% 下限。不做嵌套树——换方向时整体重排。
- **入口**：右键菜单「左右分屏／上下分屏／关掉此分屏」+ 可自定义快捷键（`ctrl+shift+d` / `ctrl+shift+s` / `ctrl+shift+w` / `ctrl+shift+.` / `ctrl+shift+,`，mac 侧 `⌘D` `⌘⇧D` `⌘⇧W` `⌘]` `⌘[`）。Ctrl 侧一律 `ctrl+shift+字母`：`ctrl+alt` 在 Windows 上就是 AltGr，会劫持 `@`、`€` 的输入。分屏键在「已达上限／未分屏／不参与分屏」时不吞键，交回 shell —— 抢键比少个功能更糟。
- **已知边界**：额外 pane 只有 shell，不接 AI 面板与监控 chips（那些仍按 tab 归属）；分屏布局不跨启动持久化（tab 本身就不跨启动恢复，只存布局没有落点）。

## 7. 依赖与天花板
xterm.dart 4.0.0 无完整搜索 UI、无 OSC 8、无 sixel，但**有高亮原语** `controller.highlight`（见 P1 注记），搜索据此实现、不必换渲染库。OSC 133 **也不需要 fork**：未识别的私有 OSC 会原样转交给公开回调 `Terminal.onPrivateOSC`，命令块据此在外层实现（见 P2 注记）。分屏、自定义、重连、转发不受库限制，纯 app 层工作。

## 8. 开放问题（评审时定）

1. ~~分屏方案 B 的改绑交互：pane 标题栏点击切换，还是命令（如 `/bind`）？~~ 已定：不提供改绑。首屏就是标签本身，AI 恒绑首屏并在屏角常亮「AI 会话」徽标，额外屏标「本地 shell」；改绑会让「命令在 A 屏执行实际去了 B 屏」重新变成可能（§4 明令禁止的那种危险），收益不值。
2. ~~自动会话日志默认开还是关？~~ 已定：默认关，外观设置页开关（见 P1 实施注记）。
3. ~~GBK 主机上 AI 链路适配前，是否在主机编辑页对「编码 ≠ UTF-8」的主机禁用 AI 执行并提示？~~ 已定：不禁用，输入侧按主机编码写入（见 P1 实施注记）。