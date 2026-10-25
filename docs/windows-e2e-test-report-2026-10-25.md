# Windows 全量测试报告（2026-10-25）

## 1. 测试目标与范围

在当前 Windows 机器上对 ai_terminal 进行全量测试：

- 静态分析、单元/Widget 测试、Windows Release 构建
- 真实 UI 端到端测试（本地终端、SSH 终端、右键复制/粘贴、SFTP、Agent）
- SSH 测试服务器：本地 Docker 容器 `centos8-ssh`（root@127.0.0.1:1022）
- AI 测试模型：本机 AI Gateway `http://localhost:1994/v1`（模型 `agnes`）

## 2. 测试环境

| 项 | 值 |
|---|---|
| OS | Windows 11 专业版 21H2 (2009), x64 |
| Flutter / Dart | 3.47.8 / 3.13.7（最终验证）；3.44.9 / 3.12.2（兼容验证） |
| 构建工具链 | Visual Studio Build Tools 2022 17.7 + Windows 10 SDK 10.0.22621 + VC ATL 组件 |
| 测试服务器 | Docker `centos8-ssh`，CentOS Linux 8，`0.0.0.0:1022->22` |
| 应用产物 | `ai_terminal/build/windows/x64/runner/Release/ai_terminal.exe` |

### 环境准备记录

- Windows 构建首次失败：`flutter_secure_storage_windows` 依赖 ATL，缺少 `atlstr.h`。
  已安装 VS 组件 `Microsoft.VisualStudio.Component.VC.ATL` 后构建成功。
- `pub.dev` 在本机仅 HTTP/1.1 可用；`pub.flutter-io.cn` 的归档 CDN 返回 525。
  最终使用本机已有 pub cache + pub.dev 完成依赖解析。
- Flutter 3.47.8（Dart 3.13.7）下 `dartssh2 2.14.0` 编译失败：
  `sftp_client.dart:602: A value of type 'int?' can't be assigned to a variable of type 'num'`。
  已升级至 `dartssh2 3.3.1`，并在 Flutter 3.47.8 / Dart 3.13.7 下完成全量测试与 Release 构建。

## 3. 结果汇总

| 项目 | 结果 |
|---|---|
| `flutter analyze` | **通过**：0 error；33 条 info/warning（5 条 warning 均为既有代码风格/无效 `!`） |
| `flutter test` | **282 个测试全部通过**（Flutter 3.44.9 与 3.47.8 均通过） |
| `flutter build windows --release` | **成功**（Flutter 3.47.8 / Dart 3.13.7） |
| 本地终端（PowerShell） | 初始失败（进程立即退出）→ **已修复并复测通过** |
| SSH 连接 / 命令执行 | 通过（Docker 容器 hostname `46023b2fcc24`） |
| 键盘输入（普通字符、Shift） | 通过（物理按键路径） |
| 右键菜单 / 粘贴 / 复制 | 通过 |
| SFTP 连接与目录浏览 | 通过（`/root` 列表正确） |
| SFTP 写入（file_write） | **已修复并复测通过**（无 PTY 回退） |
| file_patch / 上传 / 下载 | 通过（真实 SFTP；UI 上传实测） |
| fetch_url / web_search | 通过（example.com / Bing 免 key 搜索） |
| 多主机广播执行 | 通过（双 SSH 会话并行返回一致结果） |
| AI 模型配置 / 连接测试 | 通过（界面显示“连接成功”） |
| Agent 自动执行（真实 LLM + SSH） | 通过（执行命令、读取退出码、`finish` 收尾） |
| Agent 取消 | 通过，取消卡片显示“任务已取消” |
| 删除命令二次确认 | 通过（`rm` 显示“需确认”与风险说明） |
| 多标签切换 / 重启持久化 | 通过（主机、模型、会话历史均保留） |

## 4. 关键 E2E 记录

### 4.1 本地终端

- 初始现象：新启动应用后本地终端立即显示 `[进程已退出]`，输入无响应；重连仍复现。
- 定位：`flutter_pty` 的 ConPTY 启动方式下，直接启动 `powershell.exe` 会静默退出（exit code 0），
  `cmd.exe` 不受影响。
- 修复：Windows 上改为由 `cmd.exe /K powershell.exe -NoLogo` 托管 PowerShell。
- 复测：显示 `PS C:\Users\Administrator>`，执行 `echo LOCALOK` 输出 `localok`。

### 4.2 SSH 与 Agent

- 新增 Docker 主机 `Docker CentOS8 root@127.0.0.1:1022`，密码认证连接成功。
- 普通命令：`echo E2E_OK && uname -a && whoami` 输出正确。
- Agent 任务：`Run echo AGENT_SSH_OK && hostname on the server, then report the output.`
  - 模型把 `&&` 拆为两条独立命令执行；
  - 终端输出 `AGENT_SSH_OK`、`EXITCODE_5: 0`、`46023b2fcc24`、`EXITCODE_6: 0`；
  - Agent 面板显示“任务完成”。
- 取消任务：`sleep 60` 执行过程中点击停止，命令被 `^C` 中断并返回提示符。

### 4.3 右键复制/粘贴

- 拖动选中终端文本 → 右键 → “复制”，系统剪贴板内容为选中文本（`[root@46023b2fc`）。
- 设置剪贴板为 `stty -a` → 右键 → “粘贴”，命令成功插入终端。

### 4.4 SFTP

- 打开 SFTP 面板，正确列出 `/root` 下文件及大小/时间。
- 修复后复测：SFTP 面板打开时，Agent 输入框的发送按钮与运行中的停止按钮均位于主内容区内，
  点击均生效（停止可中断 `sleep 60`，发送可启动任务）。

### 4.5 Agent 文件工具

- 任务：使用 `file_write` 创建 `/tmp/ai_fix_e2e.txt` 并 `cat` 验证。
- 修复后结果：SFTP 直接写入成功，无“SFTP 写入失败 / PTY 回退”提示；
  `cat` 输出 `hello`，Agent 正常 `finish`。

### 4.6 删除命令确认

- 任务：`Delete the file /tmp/ai_terminal_e2e_probe`。
- 修复后结果：命令卡片显示“需确认”，并提示“删除文件或目录，操作不可恢复，请确认目标路径”；
  点击“取消”后输出“用户拒绝执行此命令”，命令未执行。

### 4.7 取消任务文案

- 修复后结果：取消执行中的 `sleep 60` 后，事件卡片显示橙色“任务已取消”，不再显示“任务完成”。

### 4.8 补充工具与多主机验证

- **file_patch（真实 Docker SFTP）**：`file_write` 创建 `name: demo\nport: 80` →
  `file_patch` 将 `port: 80` 替换为 `port: 8080` → 读回内容一致；
  旧串出现 2 次时正确拒绝（唯一性校验生效）。
- **SFTP 上传/下载**：
  - 集成层：本地文件上传到 `/tmp` 后读回一致，再下载到本地字节级一致；
  - UI 上传：点击上传按钮正常打开 Windows 文件选择器，选择文件后 `/root/ui_upload_probe.txt`
    出现在远程列表且内容正确；
  - UI 下载入口为长按文件行，自动化难以触发；底层 `downloadFile` 已验证。
- **fetch_url**：抓取 `https://example.com`，返回正文包含 `Example Domain`。
- **web_search**：默认免 key 的 `bing_html` provider 返回 3 条结果（标题/URL/摘要正常）。
- **多主机编排**：两个独立 SSH 会话注册到 `AgentHostRegistry`，`MultiHostExecutor.executeBatch`
  并行广播 `echo MULTI_OK && hostname`，两台均成功返回 `MULTI_OK` 与容器 hostname；
  `executeOn` 单机执行正常；断开后 registry 自动清理陈旧 executor。

## 5. 缺陷清单

### 已修复（第一轮）

#### D1（高）Windows 本地终端启动即退出
- 位置：`lib/services/local_terminal_service.dart`
- 现象：PowerShell 进程立即退出（exit code 0），终端不可用。
- 原因：flutter_pty 的 ConPTY 下 PowerShell 无法获得有效控制台句柄。
- 修复：`cmd.exe /K powershell.exe -NoLogo` 托管。

#### D2（高）Agent 请求包含空 content 消息，严格 OpenAI 兼容服务返回 400
- 位置：`lib/services/ai_service.dart`
- 现象：Agent 任务失败，提示“请求格式错误，请检查 AI 模型配置”。
- 证据：代理捕获请求，`messages` 末尾存在 `{"role":"user","content":""}`；
  上游返回 `message content cannot be empty`。
- 原因：`_callAI` 以 `prompt: ''` 调用 `chatStream`，而 `OpenAIProvider` 无条件追加空 user 消息。
- 修复：新增 `OpenAIProvider.buildRequestMessages`，过滤空历史消息，`prompt` 为空时不再追加；
  新增 `test/openai_request_messages_test.dart` 覆盖 3 个场景。

### 已修复（第二轮）

#### D3（中）SFTP 侧面板打开时，Agent 发送/停止按钮不可点击
- 现象：SFTP 打开后，点击输入框右侧发送/停止按钮无响应；按 Enter 仍可发送。
  关闭 SFTP 后按钮恢复正常。
- 影响：用户无法在 SFTP 打开时停止正在执行的任务。
- 复测结果：重建后在 SFTP 打开状态下分别点击发送、停止均生效（`SEND_BUTTON_OK` 与
  中断 `sleep 60`）。按钮位于主内容区约束范围内（x≈905），此前记录的 x≈1233 落在 SFTP 面板区域，
  未能复现按钮越界；本轮以实际坐标复测通过，无需额外布局改动。

#### D4（中）取消任务后 UI 显示“任务完成”
- 现象：点击停止后命令被中断，但 Agent 事件卡片标题仍为“任务完成”（绿色成功样式）。
- 位置：`lib/widgets/agent_event_cards.dart` `_buildFinishCard` 硬编码标题。
- 修复：`AgentEvent` 新增 `finishState`（success/cancelled/failed/interrupted），引擎在所有终态路径
  写入对应状态并持久化；卡片按状态显示“任务完成 / 任务已取消 / 任务失败 / 任务已中断”及对应颜色。
- 复测：取消 `sleep 60` 后卡片显示橙色“任务已取消”。

#### D5（中）单文件 `rm` 自动执行，无二次确认
- 现象：任务 “Delete the file /tmp/ai_terminal_e2e_probe” 生成 `rm /tmp/...` 后直接执行。
- 原因：`SafetyGuard` 的 warn 规则只覆盖 `rm -rf /` 等系统路径，普通 `rm <file>` 被判为 safe。
- 影响：Agent 可在无确认情况下删除任意文件（本次文件不存在，命令失败）。
- 修复：`SafetyGuard` 新增 `rm`、`unlink`/`shred`、`find -delete`、`truncate -s 0` 的 warn 规则；
  `rm -rf /` 等仍由 block 规则优先拦截。新增 9 个单元测试。
- 复测：删除任务显示“需确认”与风险说明，点击“取消”后命令未执行。

#### D6（低）连接初始化与监控探测污染交互终端
- 现象：SSH 连接后终端出现大段 `LS_COLORS`/别名初始化行，以及
  `cat /proc/cpuinfo`、`free -h`、`df -h` 和 `EXITCODE_n` 标记输出；容器缺少 `clear` 时出现
  `-bash: clear: command not found`。
- 影响：终端首屏被内部命令污染，用户难以分辨自己的输出。
- 修复：
  - `CommandExecutor` 增加 `runOnce`（SSH 走独立 exec channel，本地走独立进程），
    `AgentEngine.collectSystemInfo` 改用 `runOnce`，不再向交互 PTY 写探测命令；
  - SSH 连接初始化改用 ANSI `printf '\033[2J\033[H'` 清屏，缺少 `clear` 时不再报错/残留。
- 复测：连接后终端仅显示干净提示符，无 LS_COLORS、探测命令或 `clear: command not found`。

#### D7（低）Flutter 3.47 / Dart 3.13 下 dartssh2 2.14.0 无法编译
- 现象：4 个测试套件编译失败（sftp_client.dart 可空提升错误）。
- 影响：使用最新 stable 的开发者无法构建；当前项目 lock 声明 Flutter >=3.44.0。
- 修复：`dartssh2` 升级至 `^3.3.1`（保留旧算法可用性，未采用移除默认旧算法的 4.x）；
  `encrypt 5.0.3` 与 dartssh2 3.x 的 pointycastle 版本冲突通过 `dependency_overrides: pointycastle ^4.0.0`
  统一，并新增 `test/encrypt_compat_test.dart` 验证 AES 往返。
- 验证：Flutter 3.47.8 / Dart 3.13.7 下 **282 个测试全部通过**，Windows Release 构建成功。

#### D8（高）file_write 工具：SFTP 写入失败，PTY 回退误报失败并卡住步骤
- 复现任务：`Use file_write to create /tmp/ai_e2e.txt with content hello, then run cat ...`
- 现象：
  - Agent 调用 `file_write`，日志显示 `SFTP 写入失败，尝试 PTY stdin 模式 (cat > file)...`；
  - 文件实际写入成功（`cat /tmp/ai_e2e.txt` 输出 `hello`）；
  - 工具仍返回失败，Agent 最终结论为“file_write 工具失败了，提示 SFTP 和 PTY 写入都遇到问题”；
  - 执行期间步骤状态长时间停留在“执行工具 file_write”（约 20s+）。
- 影响：远程文件编辑是核心 Agent 能力之一；当前会误报失败、可能阻塞任务。
- 根因与修复：
  1. `SftpService.createDirectory` 对已存在的父目录（如 `/tmp`）直接 `mkdir`，抛错后误触发 PTY 回退。
     新增幂等递归 `ensureDirectory`，file_write / upload / file_sync 改用它；面板“新建文件夹”仍保持严格报错。
  2. PTY 回退在内容无尾换行时只发一次 Ctrl+D：canonical 模式下第一次只提交当前行，`cat` 继续等待，
     导致 30s 超时并误判失败。改为无尾换行时延迟补发第二次 Ctrl+D（SSH 与本地 PTY 同步修复）。
- 验证：临时集成测试（真实 Docker SFTP）：`ensureDirectory('/tmp')` 不报错、递归建目录、
  SFTP 写入/读取一致、无尾换行 PTY 写入成功；E2E `file_write` 直接走 SFTP 成功，无回退提示。

### 未验证 / 受自动化限制

- **Ctrl+C / Ctrl+A 等修饰键**：通过自动化注入时出现修饰键未生效并插入字面字符（`c`/`u`/`a`）
  的现象，无法区分是自动化注入还是应用处理问题。物理按键路径的普通字符与 Shift 输入正常。
  建议人工键盘复测 Ctrl+C、Ctrl+A、Ctrl+L。
- **SFTP 下载的 UI 入口**：下载动作绑定在文件行长按；自动化未触发长按，底层下载已通过集成测试验证。
- **多主机 UI 编排模式**：`MultiHostExecutor` 已在服务层双会话验证；Orchestrator 的 UI 交互链路未做端到端覆盖。

## 6. 代码变更

| 文件 | 变更 |
|---|---|
| `lib/services/local_terminal_service.dart` | Windows 下由 cmd 托管 PowerShell；PTY 写入补发第二次 Ctrl+D；退出码日志 |
| `lib/services/ai_service.dart` | 新增 `buildRequestMessages`，过滤空消息/空 prompt |
| `lib/models/agent_event.dart` | 新增 `AgentFinishState` 与 `finishState` |
| `lib/services/agent_engine.dart` | 所有终态写入 finishState；系统信息探测改走 `runOnce` |
| `lib/services/daos.dart` | 事件持久化增加 `finishState` |
| `lib/widgets/agent_event_cards.dart` | 终态卡片支持完成/取消/失败/中断 |
| `lib/core/safety_guard.dart` | 删除类命令纳入二次确认 |
| `lib/services/command_executor.dart` | `CommandExecutor` 增加 `runOnce` |
| `lib/services/ssh_service.dart` | `runOnce` 注解；ANSI 清屏；PTY EOF 修复 |
| `lib/services/sftp_service.dart` | 新增幂等递归 `ensureDirectory` |
| `lib/services/agent_tool.dart` / `file_sync_service.dart` | 父目录创建改用 `ensureDirectory` |
| `pubspec.yaml` / `pubspec.lock` | dartssh2 ^3.3.1；pointycastle 4 override |
| `test/openai_request_messages_test.dart` | 新增 3 个回归测试 |
| `test/safety_guard_test.dart` | 新增 9 个删除确认测试 |
| `test/encrypt_compat_test.dart` | pointycastle 4 + encrypt 兼容性测试 |

## 7. 复现与验证命令

```bash
# 在 ai_terminal/ 下（Flutter 3.47.8 / Dart 3.13.7，或 3.44.9 / Dart 3.12.2）
export PATH="/d/tools/flutter_sdk/flutter/bin:$PATH"
flutter pub get
flutter analyze          # 0 error
flutter test             # 282 passed
flutter build windows --release
```

构建前置条件：Visual Studio Build Tools 需包含
`Microsoft.VisualStudio.Component.VC.ATL`（否则 flutter_secure_storage_windows 编译失败）。

测试服务器：

```bash
docker ps | grep centos8-ssh   # 0.0.0.0:1022->22/tcp
```

AI 服务（测试时）：

```bash
curl http://localhost:1994/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <REDACTED>" \
  -d '{"model":"agnes","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'
```
