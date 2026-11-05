# 本机命令执行（local_exec）与本地目录授权设计

状态：设计已核对代码，进入实现
适用范围：`ai_terminal/lib/services/local_exec_tool.dart`、`lib/utils/local_shell.dart`、`lib/services/local_file_policy.dart`、`lib/services/agent_engine.dart`、`lib/pages/terminal_page.dart`
关联：`docs/agent-permission-mode-design.md`（四档权限）、本地文件工具与 `LocalFilePolicy`

---

## 1. 问题

截图中的会话是 SSH 远程 Linux（`cjm@i78750k:~$`），用户要导出本机 Docker 镜像到 `D:\docker\images`。
模型生成了 PowerShell（`mkdir $dst -Force`、`Select-Object`、`ForEach-Object`），但 `动作: execute`
被绑定到当前会话的 SSH 执行器，于是 PowerShell 被原样发给 bash，报 `mkdir: 无效的选项 -- F`、
`Select-Object: 未找到命令`，退出码 127。

两层原因：

1. **执行位置不可选**：应用只有 `local_file_*` 文件工具，没有“本机 shell”工具。远程会话里
   `execute` 只能是远程，模型无法在本机执行 Docker/Windows 路径相关命令。
2. **提示词没有把执行位置说死**：`【系统环境】`只打印远程 osInfo，没有明确“本机是 Windows、
   `execute` 在远程、本机命令必须换工具”，模型看到 `D:\` 仍按本机 PowerShell 生成。

本地目录权限是第三层：`LocalFilePolicy` 默认关闭且白名单为空，`D:\docker\images` 未授权时
即使有本地 shell 也会被拒；用户不应被强制绕到设置页。

## 2. 工具契约

新增 `local_exec`，**只在 SSH 远程会话暴露**（本地终端会话的 `execute` 已经在本机，不需要它）。

参数（多行 key:value）：

| 参数 | 必填 | 说明 |
|---|---|---|
| `command` | 是 | 本机命令原文 |
| `cwd` | 是 | 工作目录绝对路径，必须通过 `LocalFilePolicy` |
| `timeout` | 否 | 秒，默认 120，最大 600；大型 `docker save`/构建可设 300–600 |
| `shell` | 否 | `powershell` / `cmd`（Windows）或 `bash` / `sh`（Unix）；不填按平台默认 |

返回：退出码、耗时、cwd、stdout、stderr。输出保留尾部 20000 字符，超出标注截断。

工具元数据：

- `ToolKind.destructive`：任意本机 shell 都可能改文件/服务，询问与自动档一律确认，
  全自动档直接执行；只读档在引擎入口被拒绝。
- `recordsChanges = false`：本机命令无法逐文件回滚，不能记到远程变更台账（否则回滚会打到服务器）。
- 执行前后可选写 `AuditLogger`（hostId=`local`），只记录命令、退出码与截断输出。

## 3. 安全模型

### 3.1 权限档位

| 模式 | local_exec |
|---|---|
| 只读 | 拒绝（非只读工具） |
| 询问 | 确认后执行 |
| 自动 | 确认后执行 |
| 全自动 | 直接执行 |

确认卡片展示完整 `command` + `cwd`；这与 `docs/agent-permission-mode-design.md` 的
“确认卡片必须能让用户看清影响”一致。

### 3.2 目录白名单

- `cwd` 必须是绝对路径；不存在时允许判定（`LocalFilePolicy` 会解析已存在的最深祖先），
  授权后由工具创建。
- 判定复用 `LocalFilePolicy.decide`：白名单 + 敏感黑名单 + 符号链接解析。
  - `sensitive` / `reserved` / `escape`：直接拒绝，不提供授权入口（`~/.ssh`、`.env` 等永远不行）。
  - `notInAllowlist`：调用目录授权回调，弹窗确认后启用本地文件访问并追加该目录，再重试。
- 只强制校验 `cwd`。命令里的绝对路径无法可靠解析（PowerShell 变量、拼接、管道），
  最终防线是用户确认卡片里的完整命令；提示词要求优先使用 cwd 下的相对路径。
- 授权弹窗必须列出路径、原因和“允许后开启本地文件访问并授权该目录”，不能静默扩权。

### 3.3 远程误发拦截

`execute` 在 SSH 会话执行前做一次保守检测：命令同时命中“Windows 盘符路径”或
“PowerShell 语法”（`$var=`、`Select-Object`、`ForEach-Object`、`$env:` 等）时，
直接返回可读观测：

> 这看起来是本机命令（盘符/PowerShell 语法），当前 execute 运行在远程服务器；请改用 local_exec。

检测只用于“明显场景”，不替代提示词；对普通 Linux 命令不得误伤。

## 4. Shell 与进程

- Windows：默认 `powershell.exe -NoProfile -NonInteractive -Command <wrapped>`；
  `shell: cmd` 用 `cmd.exe /d /s /c`。
- macOS/Linux：默认 `bash -lc`，没有 bash 时退回 `sh -lc`。
- PowerShell 包装：
  - `[Console]::OutputEncoding = [Text.Encoding]::UTF8`，统一 UTF-8 输出；
  - `$ErrorActionPreference='Stop'`，异常写 stderr 并 `exit 1`；
  - 原生命令用 `$LASTEXITCODE` 透传退出码，cmdlet-only 命令退出 0。
- 超时：默认 60s，最大 600s；超时 kill 进程并返回明确失败。
- 取消：监听引擎注入的 `cancelToken`，取消时 kill 进程。
- 非交互：不分配 stdin；需要输入的命令（`docker login` 等）直接失败并提示改用终端。
- 输出编码：UTF-8，`allowMalformed` 防止单个坏字节导致工具异常。

已知边界：Windows 上 kill 只保证结束 shell，子进程可能继续；超时结果必须明确告知用户，
并建议检查残留进程/半成品文件。Unix 同理，不做进程组强杀。

## 5. 提示词与 UI

- `【执行位置】`段（每次任务构建）：
  - `execute` 运行在当前执行器：远程服务器（osInfo）或本机终端；
  - 本机 OS/主机名/主目录；
  - 本机 Docker、盘符路径、本机 GUI/服务必须用 `local_exec`，不要把 PowerShell 发给远程 shell。
- `local_exec` description 明确“运行 App 的这台电脑”，并说明服务器命令用 `execute`。
- `RiskExplainer` 增加 `local_exec`：影响=在本机执行任意命令；还原=无自动回滚，确认命令内容。
- 目录授权弹窗由页面实现，回调链：`LocalExecTool` → `AgentTool.localDirAuthorizationRequest`
  → `AgentEngine.onLocalDirRequest` → `AgentNotifier.localDirRequestHandler` → `TerminalPage` 弹窗。
  确认后写 `LocalFilePolicy(enabled=true, allowedDirs+=cwd)`；取消则工具返回失败，命令不执行。

## 6. 测试矩阵

纯函数/工具单测：

- `looksLikeLocalWindowsCommand`：截图命令为 true；`systemctl status nginx`、`ls -la` 为 false；
  盘符-only、PowerShell-only、bash 变量赋值的边界。
- `buildLocalShellInvocation`：Windows PowerShell/cmd、Unix bash/sh 的参数与包装；退出码透传。
- `LocalExecTool`：元数据（name/kind/recordsChanges）、必填参数、敏感路径拒绝且不调用授权、
  未授权 → 授权回调 true → 重试执行、授权 false → 不执行、超时/取消路径（用注入的 runner）。
- `AgentToolRegistry.visibleFor`：SSH 会话包含 `local_exec`，本地会话不包含。
- 权限门控：`ToolKind.destructive` 与 `destructiveToolNeedsConfirm` 的既有矩阵已覆盖。

门禁：`flutter analyze`、`flutter test`；Windows 真机验证本机 `docker`/`echo` 命令、目录授权弹窗、
远程 PowerShell 误发拦截。

---

## 7. 代码核对记录（实现前）

| 假设 | 结论 |
|---|---|
| 远程会话的 execute 固定走 SSH | 真：`_sendToAgent` 用 active tab 的 `service` 作为 executor |
| 本地文件工具已存在且作用域 all | 真：`registerLocalFileTools` 默认 scope all |
| `LocalFilePolicy` 默认关闭、白名单空 | 真：`enabled=false`、`allowedDirs=[]` |
| 工具确认通道可复用 | 真：`ToolKind.destructive` + `_confirmToolExecution`，10 分钟超时 |
| 目录授权回调可复用 secret 回调模式 | 真：`AgentNotifier.secretRequestHandler` → `engine.onSecretRequest` |
| PowerShell 退出码需要单独透传 | 真：`$LASTEXITCODE` 只由原生命令设置，项目里已有同类踩坑记录 |
| 本机文件变更不能进远程台账 | 真：`ChangeRecordService` 按 hostId 记录，回滚走远程命令 |
| 本地会话不需要 local_exec | 真：本地终端 `execute` 已在本机执行，重复暴露只会让模型犹豫 |

### 已知边界

- 任意命令的绝对路径无法完全白名单化，确认卡片是最终防线；不宣称“目录外绝对写不进去”。
- 超时/取消只 kill shell，不保证子进程树全部结束。
- 目录授权会顺带开启 `local_file_*` 工具的访问（同一个 `LocalFilePolicy`），弹窗文案必须写明。
- `local_exec` 不进远程变更台账；本机命令的审计单独按 `hostId=local` 记录，不与服务器审计混在一起。

---

## 8. 交付记录

实现状态（2026-11-05）：

- P0：`LocalExecTool`（`ToolScope.sshSession`、`ToolKind.destructive`、`recordsChanges=false`）、Shell 选择/包装、cwd 白名单、超时/取消/输出尾部截断、本机审计；`【执行位置】` prompt；远程 PowerShell 误发拦截（盘符 + PowerShell 特征，放在封网期检查之前）。
- P1：`AgentTool.localDirAuthorizationRequest` → `AgentEngine.onLocalDirRequest` → `AgentNotifier.localDirRequestHandler` → `TerminalPage` / `showLocalDirAuthDialog`；确认后启用本地文件访问并追加 cwd，工具重新判定后执行。
- UI：`RiskExplainer` 增加 local_exec；工具确认卡片对 local_exec 放开 8000 字符摘要（完整命令是批准依据）。

门禁：`flutter analyze` 33 issues / 0 errors（与既有基线一致）；`flutter test` 842 passed / 23 skipped（23 个为原有环境门控 E2E）。

取消边界：目录授权弹窗等待期间任务被取消时，页面不再保存授权，工具在执行前用 `isTaskActive` 再检查一次，不创建目录也不运行命令。

真机/进程验证：

- Windows 真机 `runLocalCommand`：PowerShell 中文输出正常；`cmd /c exit 7` 退出码为 7；cmd 分支可执行。
- 目录授权弹窗 widget 用例：路径、创建提示、敏感路径说明、允许/取消返回值。
- Windows Release 已重建并启动成功。

未验证：真实 SSH 会话 + 真实模型生成截图中的命令后的完整链路（需要用户的在线服务器与模型额度）。该链路由工具单测（授权/拒绝/敏感路径/超时）、可见性测试和 `looksLikeLocalWindowsCommand` 真机命令用例覆盖，但没有用真实模型跑一轮，不宣称“已肉眼确认”。

交互边界：询问/自动档下 local_exec 会先弹一次命令确认（标准破坏性工具确认），目录未授权时再弹一次目录授权；这是两个独立授权，不是重复弹窗。全自动档只有目录授权（如果尚未授权）。
