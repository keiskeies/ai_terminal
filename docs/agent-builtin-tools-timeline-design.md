# Agent 内置工具集与过程时间线设计

> 状态：P0 已落地（2026-11-01，见 §5 交付记录）；P1/P2 待实施
> 适用范围：Agent 自动执行模式（ReAct）的工具能力面与安全边界、回答过程层的呈现方式
> 不改变：ReAct 决策循环主干、SSH/SFTP 执行链路、操作单（Operation Sheet）的结论层语义
> 现状核对：2026-11-01 当前工作区（main @ 31b7945）
> 关联：[agent-operation-sheet-design.md](./agent-operation-sheet-design.md)、[AGENTS.md](../AGENTS.md) 工程规则 R1–R9

---

## 0. 一句话

给 Agent 补一组**内置本地文件工具**（读/列/搜/写/改/删/移），把工具契约对齐 MCP 的 `name + description + inputSchema + annotations` 形状；同时把回答的过程层从"平铺事件流"改成**可折叠的时间线**（思考行 / 工具调用行 / 命令行 + 总耗时头部），最终回答仍是操作单的结论层。

---

## 1. 为什么要改

### 1.1 诉求

用户诉求："希望 agent 做成类似 claude-code 的方式，需要内置一些 mcp 工具，比如本地文件的增删改查，然后回答需要有过程——有工具调用、有回答。"

拆成三件可执行的事：

| # | 诉求 | 现状 | 结论 |
|---|---|---|---|
| A | 内置本地文件工具 | 只有 `file_write`/`file_patch` 带本地分支，且**仅当会话执行器是本地终端时可用**；无读/列/搜/删/移 | 真缺口 |
| B | 工具契约可扩展（MCP 形状） | `AgentTool` 已有 `name/description/paramSpec/toJsonSchema()`，但没有读写属性、没有来源标记、参数是裸 `Map<String,dynamic>` | 差最后一步 |
| C | 回答有过程 | 事件已结构化（thought/command/result/plan/report），但渲染是平铺：思考被吞进 Markdown 串，一次工具调用 = 一个重命令块 + 一个重结果卡 | 渲染层问题，不是数据层问题 |

### 1.2 与"操作单"的关系（为什么不冲突）

`agent-operation-sheet-design.md` §2.3 定的边界是"思考过程默认折叠，不占主视觉"，反对的是**把编程 Agent 的推理直播当主视觉**。本设计不推翻这条，而是把它落到两层：

- **过程层（新时间线）**：思考与工具调用各占一行、单行截断、默认折叠、点开看参数与输出。它回答"你刚才到底做了什么"。
- **结论层（操作单，不动）**：结论/现状/变更/建议 + 变更台账 + 回滚。它回答"做成了没有、能不能退"。

时间线是操作单证据层的**换皮与升格**（从"折叠后的一串卡片"变成"可读的分组时间线"），不是新增第三种结构。运维场景仍然优先读结论。

---

## 2. 现状核对（代码事实）

| # | 事实 | 位置 | 影响 |
|---|---|---|---|
| F1 | 默认注册 6 个工具：`sftp_upload`/`sftp_download`/`file_sync`/`cert_check`/`file_write`/`file_patch` | [agent_tool.dart:2164](../ai_terminal/lib/services/agent_tool.dart) | 全部面向远程；无本地文件工具 |
| F2 | `project_analyze`/`build_project`/`package_project` 三个类**从未被 register()** | [project_tools.dart:70](../ai_terminal/lib/services/project_tools.dart)、`:433`、`:618`；注册表 [agent_tool.dart:2164-2222](../ai_terminal/lib/services/agent_tool.dart) 无引用 | 见 D1 |
| F3 | 本地终端会话仍注入"本地项目部署工作流"提示词，教 AI 调 `project_analyze`/`build_project`/`package_project` | [agent_engine.dart:3008-3011](../ai_terminal/lib/services/agent_engine.dart)、`:3101` | **D1（高危）** |
| F4 | 未知工具 → `_noCommandRetryCount++`，`_maxNoCommandRetries = 2` → 第 3 次直接 `_finishTask(success:false)` | [agent_engine.dart:142](../ai_terminal/lib/services/agent_engine.dart)、`:2277-2292` | AI 照提示词走必失败，任务被判死 |
| F5 | `_buildLocalDeployPrompt()` 里的示例参数写成 JSON（`参数: {"path":"..."}`），而协议要求多行 `key: value` | [agent_engine.dart:3101-3118](../ai_terminal/lib/services/agent_engine.dart) vs [prompts.dart:54-63](../ai_terminal/lib/core/prompts.dart) | **D2**：自相矛盾的格式示范，AI 会学坏 |
| F6 | `file_write`/`file_patch` 的本地分支只在 `executor is LocalTerminalService` 时进入 | [agent_tool.dart:1597](../ai_terminal/lib/services/agent_tool.dart)、`:1953` | SSH 会话下 AI 无法读写用户本机文件（部署前要改本地配置就卡住） |
| F7 | 类型化取参 helper **已存在**（`ToolArgsParser.getString/getStringList/getBool/getInt`，[tool_args_parser.dart:107-157](../ai_terminal/lib/utils/tool_args_parser.dart)），`agent_tool.dart`/`web_tools.dart` 全部 62 处调用已走 helper；仍有裸 `args['k']` 的是 [project_tools.dart](../ai_terminal/lib/services/project_tools.dart)（8 处）、[change_record_service.dart](../ai_terminal/lib/services/change_record_service.dart)（4 处）、[agent_engine.dart](../ai_terminal/lib/services/agent_engine.dart)（2 处） | 违反 R9-2 的是这三个文件，不是全量 |
| F8 | 文件类工具集合是**硬编码工具名白名单** | [change_record_service.dart:23-32](../ai_terminal/lib/services/change_record_service.dart) `_fileChangeTools` | 新增写类工具必须记得改这里，否则不进台账（R5-4 黑名单反例） |
| F9 | 只读模式（Dry-run）只拦 shell 命令 | [agent_engine.dart:1747](../ai_terminal/lib/services/agent_engine.dart) `_readOnlyMode && safetyLevel != safe`；工具路径无此判断（`:2257+`） | 开 Dry-run 仍能通过工具改文件 |
| F10 | 渲染：`thought`/`text`/`info` 合并进一个 `StringBuffer` 后一次性出 Markdown；`command` 出 `AgentCommandBlock`，`result` 出结果卡 | [agent_event_cards.dart:110-166](../ai_terminal/lib/widgets/agent_event_cards.dart) | 思考与正文糊在一起；10 步任务 ≈ 20 条标题栏 |
| F11 | 已有折叠壳子 `CollapsibleEventStream`（"更早 N 个事件已折叠 / 完整过程"） | [operation_sheet.dart:847-946](../ai_terminal/lib/widgets/operation_sheet.dart) | 时间线可替换它，不动调用方 |
| F12 | `AgentTask.phase / elapsedSeconds` 已存在，且**已渲染**：操作单元数据行用 `_formatElapsed(report.elapsedSeconds)`，运行中由 `LiveOperationBar` 计时 | [agent_model.dart:178,188](../ai_terminal/lib/models/agent_model.dart)、[operation_sheet.dart:446](../ai_terminal/lib/widgets/operation_sheet.dart) | "用时 X"头部无需新增，P2 直接复用 |
| F13 | 事件持久化走 `Daos._eventToJson`（JSON，非 Hive adapter） | [daos.dart:480-501](../ai_terminal/lib/services/daos.dart) | 给 `AgentEvent` 加字段必须同步改 `_eventToJson`/`_eventFromJson`，否则重启后字段静默丢失（R8-7） |
| F14 | FC 已接通：`buildOpenAIToolsSchema()` → `tools:`，`delta.tool_calls` 累积后转成 ReAct 文本 | [agent_engine.dart:1181-1190](../ai_terminal/lib/services/agent_engine.dart)、[ai_service.dart:184-190](../ai_terminal/lib/services/ai_service.dart) | 新工具自动进 FC，无需额外接线 |

**已确认缺陷（本轮一并修）**

- **D1（F2+F3+F4）**：提示词宣传了三个未注册的工具。任何本地终端会话里，AI 只要按提示词第一步调 `project_analyze`，就会连续吃"未知工具"，两轮后被判定 `toolRetryExhausted` 失败。修法二选一：注册它们，或删掉提示词。**选择：注册**（本地项目部署是既有产品能力，`_buildLocalDeployPrompt` 的意图是对的），并补一条守卫：**提示词只注入已注册的工具**（见 §3.1.4）。
  - **实施时发现的第二处同类缺陷**：[prompts.dart:174-181](../ai_terminal/lib/core/prompts.dart) 的 ReAct 示例里硬编码了 `工具: exec_batch`，而 `exec_batch` 只在编排模式开启后才注册 —— 未开启编排的普通 SSH 会话里，AI 照示例学来的调用同样必失败。已删除该示例，改为"具体工具以【可用工具】清单为准"。
  - 回归守卫：`test/tool_contract_test.dart` 用正则抽出 system prompt 里所有 `工具: <name>`，逐个断言已注册且对当前会话可见。这条测试同时覆盖两处缺陷，未来再往提示词里手写工具名会直接红。
- **D2（F5）**：把部署提示词里的 JSON 参数示例改成多行 `key: value`，与 [prompts.dart:54-63](../ai_terminal/lib/core/prompts.dart) 一致。
- **D3（F9）**：只读模式对写类工具同样失效。修法：把"是否可写"做成工具元数据，引擎在 `_handleToolAction` 统一拦（见 §3.1.3、§3.3.4）。

---

## 3. 设计

> **P0/P1/P2 已落地。本节是最初的方案；实施中与代码现实冲突的地方以 §5.1–§5.3 的交付记录为准**
> （主要差异：不新增 `AgentEvent.intent`、不抽 `EventDetailPanel`、写入不用 tmp+rename、
> `file_write` 本地分支不整体转调、`CollapsibleEventStream` 已删除）。

### 3.1 工具契约：对齐 MCP，但不引入 MCP 运行时

MCP 的一个 tool 在协议里是 `{name, description, inputSchema}` + `annotations{readOnlyHint, destructiveHint, idempotentHint, openWorldHint}`，调用返回 `content[] + isError`。当前 `AgentTool` 已经覆盖前三个，缺后两类语义。本轮把契约补齐，**不实现 MCP 客户端**（列为非目标 §6），但保证下一轮接 stdio/SSE server 时只是加一个 provider，不改契约。

#### 3.1.1 `ToolArgs` 收口取参入口（R9-2）

类型兼容逻辑**已存在**于 `ToolArgsParser` 的四个静态 helper（F7），本轮不重写一份，而是加一层值对象把"裸 Map"从 `execute` 签名里拿掉：

```dart
class ToolArgs {
  const ToolArgs(this._raw);
  String getString(String key, {String defaultValue = ''});   // 委托 ToolArgsParser
  String requireString(String key);                           // 缺失 → ToolArgException
  String firstOf(List<String> keyNames, {String defaultValue = ''});  // remote|remoteDir
  List<String> getStringList(String key, {List<String> defaultValue});
  bool getBool(String key, {bool defaultValue = false});
  int getInt(String key, {int defaultValue = 0});
  bool has(String key);            // 存在且非空
  bool containsKey(String key);    // 存在即可（file_write 用它区分"没写"与"写了空值"）
  Map<String, dynamic> get asMap;  // 仅供台账/日志
  String describe({int maxValueChars = 80});  // 日志用，长值截断
}
```

- `AgentTool.execute` 签名改为 `execute({required CommandExecutor executor, required ToolArgs args, ...})`。
- 引擎在 `_handleToolAction` 一处把 `step.toolArgs`（裸 Map）包成 `ToolArgs` —— 这是唯一的收口点，工具内部再拿不到 Map。
- 迁移面实测：`agent_tool.dart` 14 个 + `project_tools.dart` 3 个 + `web_tools.dart` 2 个共 62 处 helper 调用改为实例语法；`project_tools.dart` 的 8 处裸 `args['k']` 与 `excludeRaw is List || is String` 手工分支删除。
- `getStringList` 补两处兼容：剥掉 AI 写成 JSON 数组字面量的方括号（`'[a, b]'` → `['a','b']`），以及中文逗号分隔（`'a，b'`）。`exec_batch` 的历史事故正是方括号那一条。
- 单测：`test/tool_contract_test.dart` 的「ToolArgs 类型化访问」组覆盖 List/逗号/方括号/中文逗号/布尔字符串/`has` 与 `containsKey` 的差异/`describe` 截断。

#### 3.1.2 MCP 描述符出口

```dart
abstract class AgentTool {
  // 既有：name / description / paramSpec / toJsonSchema()
  ToolKind get kind;                 // read | write | destructive | network | orchestration
  ToolSource get source;             // builtin（本轮唯一）| mcpServer（预留）
  Map<String, dynamic> get mcpDescriptor => {
    'name': name, 'description': description, 'inputSchema': toJsonSchema(),
    'annotations': {
      'readOnlyHint': kind == ToolKind.read,
      'destructiveHint': kind == ToolKind.destructive,
      'openWorldHint': kind == ToolKind.network,
    },
  };
}
```

**实施时的两处修正**（§5.7.2 复核补）：

- `idempotentHint` **不发**。上面草案里那个 `...` 位置本来想按 `kind` 派生，但同为 `ToolKind.write`，`file_write` 幂等而 `file_patch` 不幂等（第二次替换就找不到 `old` 了）—— 按 kind 猜等于对外部 client 撒谎。真要提供得加每工具可覆写的 getter，留到 MCP 客户端落地时做。
- `toJsonSchema()` 返回 null 的语义是"不参与 OpenAI FC"，但 MCP 要求 `inputSchema` 必须是 schema 对象。描述符里对 null 做了回落（`type: object` + `additionalProperties: true` + 把 `paramSpec` 放进 `description`），否则这类工具一导出就是非法描述符。

`buildOpenAIToolsSchema()` 保持不动（FC 线格式不变，F14 的链路零风险）。`mcpDescriptor` 只在注册表里用于 §3.1.3 的派生，不做序列化下发。

#### 3.1.3 用 `kind` 派生安全语义，删掉硬编码名单

- `ChangeRecordService._fileChangeTools`（F8）→ 改为 `AgentToolRegistry.isChangeRecordingTool(name)`，内部判断 `kind == write || kind == destructive`。新增写类工具**自动**进台账与审计，不需要再改第二处（R5-4：白名单派生自元数据，而不是枚举名字）。
- 引擎在 `_handleToolAction` 拿到 tool 后统一前置判断：
  - `_readOnlyMode && tool.kind != read` → 直接失败并回观测"只读模式拒绝"，不执行（修 D3）；
  - `tool.kind == destructive` → 走既有确认通道（§3.3.3）。

#### 3.1.4 注册表按作用域装配 + 提示词与注册集一致

```dart
enum ToolScope { all, sshSession, localSession, orchestrator }
class AgentToolRegistry {
  void register(AgentTool tool, {ToolScope scope = ToolScope.all});
  List<AgentTool> visibleFor({required bool isLocalSession});
  String buildToolsPrompt({required bool isLocalSession});   // 只列 visibleFor
  List<Map<String,dynamic>> buildOpenAIToolsSchema({...});   // 同一过滤
}
```

守卫（防 D1 复发）：`_buildSystemPrompt` 拼接前，对提示词里出现的工具名做断言；未注册的工具名**不注入**。实现方式：把部署工作流提示词改成从注册表生成（列 `kind != read && scope == localSession` 的工具），而不是手写工具名。

### 3.2 本地文件工具集

新文件 `lib/services/local_file_tools.dart`。作用域 `ToolScope.all`（SSH 会话也能操作本机文件——这是"本地"的定义），但受 §3.3 白名单约束。

| 工具 | kind | 参数 | 行为要点 |
|---|---|---|---|
| `local_file_read` | read | `path`, `start_line?`, `max_lines?`(默认 400), `encoding?` | 带行号输出 `  12\|...`；超限行数时尾部标注"共 N 行，已显示 12-412"；二进制/超 2MB 拒绝并提示改用 `sftp`/本地编辑器 |
| `local_dir_list` | read | `path`, `depth?`(默认 1，上限 3), `glob?`, `sort?` | 目录优先；跳过 `.git`/`node_modules`/`build`（可 `include_hidden: true` 关闭）；输出 `dir/` 与 `file 1.2K` |
| `local_file_search` | read | `path`, `query`, `glob?`, `ignore_case?`, `max_matches?`(默认 100), `fixed?` | Dart 侧遍历，不走 shell（避免 R6 的 findstr/grep 平台与语言差异）；输出 `path:line: 内容`，命中数超限即停 |
| `local_file_write` | write | `path`, `content` \| `content_b64`, `mode=write\|append`, `backup?=true` | 复用 `file_write` 已验证的本地实现：`\n` 反转义、base64 通道、`_backupLocalFile`、原子写（同目录 tmp + rename）；>8KB 分块约束沿用 |
| `local_file_patch` | write | `path`, `old`/`new` \| `old_b64`/`new_b64` | 复用 `file_patch` 算法：出现次数 ≠ 1 报错要更长上下文；写前校验 `(size, mtime)` 防覆盖外部修改 |
| `local_file_move` | write | `src`, `dst`, `overwrite?=false` | 同盘 rename；`dst` 已存在且未 overwrite → 失败 |
| `local_file_delete` | destructive | `path`, `recursive?=false` | **默认移入回收目录** `<工作区>/.ai_terminal_trash/<时间戳>/<原相对路径>`，`hard: true` 才真删；移入即写台账，回滚 = 移回原位 |

与既有工具的分工（写进工具 description，避免 AI 选错）：

- 远程路径 → `file_write`/`file_patch`（走 SFTP）；本机路径 → `local_*`。
- `local_file_write` 与 `file_write` 的本地分支**合并**：`file_write` 保留（向后兼容历史会话），但把本地实现抽成 `LocalFileOps` 共用，`file_write` 的本地分支改为转调；不在两处各写一遍备份/原子逻辑（R2-1：谁创建谁清理；也避免 R8-3 双重清洗那类"两层各清一次"的错误）。

### 3.3 目录白名单与安全门槛

#### 3.3.1 配置

新服务 `lib/services/local_file_policy.dart`（配置读写形态照 [web_search_config.dart:183](../ai_terminal/lib/services/web_search_config.dart) 的 `WebSearchConfig.load()`，落 `SettingsDao`）：

```dart
class LocalFilePolicy {
  bool enabled;              // 总开关，默认 false（首次使用需显式打开）
  List<String> allowedDirs;  // 白名单根目录
  int maxReadBytes;          // 默认 2MB
}
```

设置项落在"设置 → Agent"（[agent_settings_page.dart](../ai_terminal/lib/pages/agent_settings_page.dart)）：开关 + 目录列表（增删，复用现有目录选择器）+ 一行说明"Agent 只能读写以下目录中的本地文件"。

#### 3.3.2 路径判定（防逃逸）

```
resolve(path):
  1. 展开 ~ / 环境变量占位（只展开 AI 写的字面量，不执行 shell）
  2. p.normalize + p.canonicalize（Windows 走 GetFinalPathNameByHandle 等价：File.resolveSymbolicLinks）
  3. 逐级 parent 解析符号链接 → 任一环节跳出白名单即拒绝
  4. 命中黑名单前缀 → 无条件拒绝
```

黑名单（硬编码，不可被用户加进白名单）：`~/.ssh`、`~/.aws`、`~/.config/gcloud`、`/etc/sudoers`、`/etc/passwd`、`/etc/shadow`、`C:\Windows\System32\config`、App 自身数据目录（Hive/SQLite 所在目录）、任何 `.env*` 文件。

理由：这是运维工具，AI 拿到的本机写权限一旦能碰 `~/.ssh/authorized_keys` 或 App 自己的会话库，就等于能持久化控制用户机器和篡改审计链。

#### 3.3.3 确认与回滚

| 操作 | 确认 | 台账 | 回滚 |
|---|---|---|---|
| read / list / search | 否 | 否 | — |
| write / patch / move | 否（有备份即视为可退） | 是 | 备份文件还原 / `move` 反向 rename |
| delete | **是**（复用引擎既有确认通道 `_confirmCompleter`，UI 走现有内联确认卡片） | 是 | 从回收目录移回 |

写类不进确认的前提是"备份成功"：备份失败 → 拒绝写入（`file_write` 现有行为，[agent_tool.dart:1618-1624](../ai_terminal/lib/services/agent_tool.dart)），新工具照抄这条不变量。

#### 3.3.4 与只读模式的关系

`_readOnlyMode == true` 时，`kind != read` 的本地工具一律拒绝，并在观测里写明"当前为只读模式"。同时 system prompt 的只读段落补一句"工具同样受限"（否则 AI 会以为换个工具就能绕过，反复试）。

### 3.4 过程时间线

#### 3.4.1 视觉结构

```
┌ 已完成 · 用时 1 分 34 秒 · 12 步 · 8 工具 · 4 命令            ⌄
│ ▸ 已调用工具 (8)                                              ← 折叠整组
│   ◌ 思考   用户问的是配置有没有生效，先读一下 nginx.conf
│   ✦ 工具   local_file_read · /etc/nginx/nginx.conf        312ms
│   ✦ 工具   local_file_patch · listen 80 → listen 8080     1.2s   ✓
│   ›  命令  nginx -t                                        840ms  ✓
│   ◌ 思考   语法通过，重载服务
│   ›  命令  systemctl reload nginx                          1.1s  ✓
├──────────────────────────────────────────────────────────────
│ 结论：Nginx 已在 8080 端口生效，已验证 …                      ← 操作单（不动）
```

规则：

- **一行一件事**。`thought` 不再和正文糊在一起（修 F10）；`result` 不再独立成卡，而是**并进它所属 command 行的尾部**（状态 + 耗时），点开才展开输出。
- 工具行文案 = `工具名 · 意图`。意图取该步 `思考` 的首句（≤40 字），不新增协议字段给 AI 填。
- 头部耗时：运行中用 `AgentTask.elapsedSeconds`；历史回放用该轮首末事件 `timestamp` 差（F12）。
- 默认折叠阈值沿用 `CollapsibleEventStream.maxVisible = 8`，超出时显示"更早 N 步已折叠"。
- 输出行内截断：折叠态 0 行，展开态最多 200 行 + "查看完整输出"（复用 [output_viewer_sheet.dart](../ai_terminal/lib/widgets/output_viewer_sheet.dart)）。

#### 3.4.2 实现落点

| 改动 | 位置 | 说明 |
|---|---|---|
| 新组件 `AgentProcessTimeline` | 新建 `lib/widgets/agent_process_timeline.dart` | 输入仍是 `List<AgentEvent>`，内部做分组：`thought` → 行；`command` → 行 + 关联 `result`；`ask`/`plan` 保持现有卡片 |
| 事件配对 | 复用 `AgentEventContent` 里的 `resultMap`（[agent_event_cards.dart:91-97](../ai_terminal/lib/widgets/agent_event_cards.dart)）提到共用工具函数，避免两处各写一遍 | |
| 行内详情 | 从 `_buildResultCard` 抽出 `EventDetailPanel`（[agent_event_cards.dart:184+](../ai_terminal/lib/widgets/agent_event_cards.dart)） | 时间线展开态与操作单证据层共用一份，不复制渲染逻辑 |
| 接入点 | [terminal_page.dart:2348](../ai_terminal/lib/pages/terminal_page.dart) `buildEventContent` | 只换这一个回调；`OperationSheet`（`:2407`）与 `PlanPanel`（`:2456`）不动 |
| 事件模型 | `AgentEvent` 加 `String? intent`；`Daos._eventToJson/_eventFromJson` 同步（F13） | 不新增 `AgentEventType` 枚举值——`values.byName` 对未知值会抛，旧库数据要能读 |
| 文案 | [agent_ui_text.dart](../ai_terminal/lib/utils/agent_ui_text.dart) 补 zh/en 标签（思考/工具调用/命令/用时/已调用工具 N 次） | 其余语言按既有约定回落英文 |

### 3.5 最终回答：放开富文本

现在的约束让"像 Claude Code 的回答正文"不可能出现：[prompts.dart:103-109](../ai_terminal/lib/core/prompts.dart) 要求 `动作: finish` 的"思考:"**必须且只包含**结论/现状/变更/建议四段。

改法（保留操作单语义，放开正文）：

1. 新增可选协议块 `回答:`，位于 `动作: finish` 那一步，承载面向用户的完整 Markdown 正文（标题、列表、代码块）。**表格不在本轮范围**：`flutter_markdown` 只在 `blockSyntaxes` 里显式给了 `TableSyntax` 才解析表格，而 `markdown` 目前只是传递依赖，要支持得先把它提为直接依赖并重做表格样式 —— 为一个括号里的观感拉一条新依赖不值得，记为已知边界。
2. 四段式仍保留，但降级为**操作单字段**（供结论条/变更/建议解析），不再是回答正文的全部。
3. 渲染：`回答:` → 操作单结论卡片下方的 Markdown 正文（默认可见，**不能**折进"过程与证据"，否则用户要展开才知道回答了什么）；`结论:` → 操作单结论行。二者缺失任一时回退现状（`回答:` 为空则用四段式正文，行为不变）。
4. **R9-3 强制项**：这是"流式文本格式 → 解析 → 事件"的改动，必须扩 [test/react_parse_e2e_test.dart](../ai_terminal/test/react_parse_e2e_test.dart)：真实分块流 → 拼接 → `_parseReActResponse` → 断言 `answer` 字段与四段字段各自正确，且 `回答:` 内含 `动作:`/`结论:` 字样时不被误切。

### 3.6 数据契约变更清单

| 变更 | 兼容策略 | 需同步的调用方（R9-1 grep 范围） |
|---|---|---|
| `AgentTool.execute(args: Map)` → `ToolArgs` | 编译期强制，无运行期兼容 | 26 个工具类 + `agent_engine._handleToolAction` + `test/file_edit_tools_test.dart`、`test/tool_args_parser_test.dart` |
| ~~`AgentEvent.intent` 新字段~~ | **未采纳**（§5.3 偏离 1）：工具行的第二段改取最能定位的参数，不新增字段 | 因此 DAO 的 `_eventToJson/_eventFromJson` 无需改动 |
| `ChangeRecordService._fileChangeTools` 删除 | 由 registry 按 `kind` 派生 | `change_record_service.isFileChangeTool` 调用点（引擎 `_recordToolFileChange`）+ `test/change_record_service_test.dart` |
| ReAct 新增 `回答:` 块 | 缺省即旧行为 | `_parseReActResponse`、`ReActStep`、`_finishTask`、操作单结论取值处、`react_parse_e2e_test` |
| 注册表按 scope 过滤 | 默认 `ToolScope.all`，既有注册不改 | `AgentToolRegistry()` 构造、`enableOrchestrator`、`enableWebTools`、`_buildSystemPrompt` |

---

## 4. 二次逻辑验证（对照代码的挑战）

| 假设 | 挑战 | 结论 |
|---|---|---|
| "加本地文件工具 = 新写一套" | `file_write`/`file_patch` 已有本地分支（F6） | 改为抽公共 `LocalFileOps`，避免备份/原子写逻辑两处漂移 |
| "AI 会自己区分本地和远程路径" | 两套工具名相近，AI 极易拿 `local_file_write` 去写 `/var/www/...` | 双向都拦：远程 `file_write`/`file_patch` 在 SSH 会话里收到 `D:\…` 形态的路径直接失败并指路 `local_file_*`（否则 SFTP 会把整串当成服务器上的文件名写下去还报成功）；本机工具在 Windows 上收到 `/etc/…` 形态的拒绝理由里附一句"这看起来是远程主机的路径"。见 §5.7 |
| "时间线只是渲染层，不动数据" | 工具行需要"意图"文本 | 需要 `AgentEvent.intent`（引擎从当步思考截取），属数据契约变更 → 必须同步 DAO（F13），已列入 §3.6 |
| "耗时用 AgentTask.elapsedSeconds 即可" | 历史轮次不存 `AgentTask` | 改用事件时间戳差；运行态才用 task 字段 |
| "只读模式已覆盖工具" | 只拦 shell（F9） | 新增 `kind` 门禁，列为 P0 |
| "注册 project 工具即可修 D1" | 它们要求 `executor is LocalTerminalService`（[project_tools.dart:470,663](../ai_terminal/lib/services/project_tools.dart)），SSH 会话注册了也只会失败 | 用 `ToolScope.localSession` 注册，SSH 会话不暴露 |
| "delete 移入回收目录就算安全" | 回收目录本身在白名单内，AI 可用 `local_file_write` 覆盖其中文件 | 回收目录加入黑名单（只允许工具自身写入） |
| "白名单默认关闭最安全" | 默认关闭 = 用户装完就抱怨"agent 不会读文件" | 默认关闭 + **每次**被拒都在观测里点名"设置 → Agent → 本地文件"（不做"一次性"：一次性状态要么落盘要么内存态，前者多一份脏数据来源，后者重启就失效；而引导语本身一行字，重复出现不扰人）。没做可点击跳设置页 —— 观测文本是发给模型的，不是给用户的按钮，跳转入口放在拒绝卡片的时间线行里才合理，留作后续 |

### 规则映射（AGENTS.md）

- **R1**：`local_file_*` 内部 `await` 后不碰引擎状态，无需 generation 检查；但 `delete` 的确认等待复用 `_confirmCompleter`，该路径已有 generation 守卫，新工具不得自建等待。
- **R2**：~~`LocalFileOps` 的 tmp 文件在 `finally` 删除~~ 实施时改掉了：本机写入不用 tmp+rename（丢 inode/ACL，且 Windows 上目标已存在时 rename 直接失败），改成就地写 + 先备份 + 写后校验长度，没有 tmp 需要清理。回收目录那条仍然成立：`rename` 失败时原文件留在原位，不会留下半移动状态。
- **R5**：所有新工具失败路径必须回带观测文本（`ToolResult.failure`），不得静默 return；`_handleToolAction` 的三条终态路径不变。
- **R6**：路径一律 `p.posix`/`p.windows` 显式选择；本机路径用 `p.join`，禁止把远程路径喂给 `local_*`（判定即拒绝）。
- **R8**：`local_file_read` 必须有字节上限；`local_file_search` 命中数上限；两者都保留"共 N，已显示 M"的截断标注。**补**：`local_file_search` 遍历文件本身也有 5000 上限，之前静默 break —— AI 会把"扫了 5000 个没找到"当成"整个目录里没有"，现在会在结果尾部标注"文件数已达 5000 上限，未继续遍历"。
- **R9**：`ToolArgs` 是唯一取参方式（§3.1.1）；`回答:` 块必须补端到端测试（§3.5-4）。

---

## 5. 分阶段与验收

| 阶段 | 内容 | 验收 | 状态 |
|---|---|---|---|
| **P0 契约与安全** | `ToolArgs` 收口取参；`ToolKind`/`ToolSource`/`mcpDescriptor`；registry 按 scope 过滤；`_fileChangeTools` 改派生；只读模式拦工具（D3）；注册 project 工具 + 提示词与注册集一致（D1/D2） | `flutter analyze` 0 error；`flutter test` 392 通过 / 16 跳过；`test/tool_contract_test.dart` 14 例覆盖 ToolArgs、scope、kind 派生、提示词一致性、只读门禁 | **已完成** |
| **P1 本地文件工具** | `LocalFileOps` + 7 个 `local_*` 工具；`LocalFilePolicy` 白名单与黑名单；符号链接逃逸防护；delete 确认 + 回收；台账与回滚；设置页；提示词工具说明 | 25 例单测覆盖：开关关闭、白名单外、`..` 逃逸、敏感文件、符号链接、备份失败即中止、patch 唯一性、move 覆盖、delete 回收与 hard；`flutter test` 417 通过。**复核更正**：其中"备份失败即中止"当时并无测试，符号链接那条依赖 Windows 特权 —— 见 §5.7.1 | **已完成**（真机 E2E 待补，见 §5.4） |
| **P2 过程时间线** | `AgentProcessTimeline`；结果卡经 `resultBuilder` 复用；失败/多机默认展开；`回答:` 协议块与富文本正文；l10n | 7 例 widget 测试（折行、展开、失败默展、折叠窗口、待执行不折、思考与正文分层、询问不折）+ 5 例 `回答:` 端到端解析；`flutter test` 427 通过 | **已完成**（真机截图对比待补，见 §5.4） |
| **P2-5 回收区治理** | 回收区用量（条目数 + 字节）与"清空回收区"；清理只认 `.ai_terminal_trash` 下一层的路径 | 13 例 `local_file_trash_test.dart` + 1 例设置页空态 widget 测试 + 1 例嵌套回收区保留性；`flutter test` 481 通过 | **已完成**（见 §5.6） |
| **P2-6 文档同步 + 完成度复核** | README（zh/en）补本机文件工具、时间线、富文本、安全与边界；对照 §3.6/§4/规则映射逐条回查代码 | 5 例路径混淆守卫测试；`flutter test` 486 通过；三处文档与实现不一致就地更正 | **已完成**（见 §5.7） |
| **P3（不做）** | MCP stdio/SSE 客户端、外部 server、子 Agent | 见 §6 | — |

### 5.1 P0 交付记录（2026-11-01）

| 交付 | 位置 |
|---|---|
| `ToolArgs` / `ToolArgException` / 方括号与中文逗号兼容 | [tool_args_parser.dart](../ai_terminal/lib/utils/tool_args_parser.dart) |
| `ToolKind` / `ToolSource` / `ToolScope` / `mcpDescriptor` / `recordsChanges` | [agent_tool.dart](../ai_terminal/lib/services/agent_tool.dart) |
| 注册表作用域过滤 + 派生台账判定（`visibleFor` / `isChangeRecordingTool`） | 同上，`AgentToolRegistry` |
| 只读模式拦工具、会话作用域守卫 | [agent_engine.dart](../ai_terminal/lib/services/agent_engine.dart) `_handleToolAction` |
| 台账描述改用 `ToolArgs`，删除工具名清单 | [change_record_service.dart](../ai_terminal/lib/services/change_record_service.dart) |
| 部署工作流提示词改为注册表生成、参数示例改多行 key:value | `agent_engine.dart` `_buildLocalDeployPrompt` |
| 删除 `exec_batch` 硬编码示例 | [prompts.dart](../ai_terminal/lib/core/prompts.dart) |
| 14 例契约/门禁测试 | [test/tool_contract_test.dart](../ai_terminal/test/tool_contract_test.dart) |

一处偏离设计稿的调整：`build_project` / `package_project` 的 `kind` 是 `write`，但显式 `recordsChanges => false`。原因是它们改的是产物目录，不产生可逐文件回滚的变更；若按 kind 直接进台账，会往变更清单里灌一堆无法回滚的条目。这个例外写在工具类里（就近、编译期可见），而不是回到另一个文件的工具名清单。


### 5.2 P1 交付记录（2026-11-01）

| 交付 | 位置 |
|---|---|
| 本地文件原语：`decodeEscapedText` / `backupLocalFile` / `writeLocalFile` / `patchLocalFile` / `countOccurrences` | [lib/utils/local_file_ops.dart](../ai_terminal/lib/utils/local_file_ops.dart) |
| 7 个 `local_*` 工具 + `registerLocalFileTools` | [local_file_tools.dart](../ai_terminal/lib/services/local_file_tools.dart) |
| `LocalFilePolicy`：总开关 + 目录白名单 + 符号链接解析 + 黑名单联动 | [local_file_policy.dart](../ai_terminal/lib/services/local_file_policy.dart) |
| 破坏性工具确认通道（复用 `_confirmCompleter` + 10 分钟超时） | `agent_engine.dart` `_confirmToolExecution` |
| 设置 → Agent → 本地文件访问（开关 + 目录增删 + 黑名单提示） | `agent_settings_page.dart` `_LocalFileAccessSection` |
| **本机文件回滚**：`ChangeRecord.localRestoreFrom/To` + DB v5 迁移 + Dart I/O 还原 | [change_record.dart](../ai_terminal/lib/models/change_record.dart)、[db_init.dart](../ai_terminal/lib/core/db_init.dart)、`change_record_service.dart` `_restoreLocalFile` |
| 回收区列为保留目录：AI 不能读写 `.ai_terminal_trash/` | `local_file_policy.dart` `trashDirName` / `LocalPathVerdict.reserved` |
| 25 例策略与文件语义测试 + 6 例还原测试 | [test/local_file_tools_test.dart](../ai_terminal/test/local_file_tools_test.dart)、`test/change_record_service_test.dart` |

§3.3.3 承诺的"回滚 = 从回收目录移回"是实施中补上的完整链路，不是台账一句话：

- `ToolResult` 新增 `restoreFrom` / `restoreTo`，由 `local_file_delete`（回收区→原路径）、`local_file_write`/`local_file_patch`（备份→原路径）、`local_file_move`（新位置→原位置）填写；新建文件没有可回滚对象，字段留空。
- 引擎把这一对写进 `ChangeRecord`，`OperationChange.localRestore` 让操作单的回滚按钮在**没有 `rollbackCommand`** 时也可用。
- **还原必须走 Dart I/O，不能走 executor**：`executeRollback` 现在接受可空 executor，命中本机还原分支时完全不碰它。若在 SSH 会话里把 `mv` 丢给 executor，命令会打到远端机器而文件在本机 —— 这条由 `expect(executor.lastCommand, isNull)` 钉住。
- 还原前若目标已存在，先另存为 `.displaced.{时间戳}`：还原动作自己也不许悄悄覆盖用户后来改出来的内容。文件用 copy（副本留在回收区，可反复还原），目录用 rename（整体放回）。
- 回收区自身是保留目录。不挡的话 AI `delete` 完再 `delete` 一次回收区，就能把自己刚保护起来的副本抹掉，"可回滚"当场变成假的。


顺带修掉的既有安全缺口（在 `SafetyGuard` 黑名单里，影响所有调用方）：

- `checkPath` 原本只拦 `.env.production` / `.env.prod` / `.env.local`，**普通 `.env` 不拦** —— 而它才是最常见的密钥文件。已补 `^\.env$` 与 `^\.env\..+$`。
- `RegExp(r'^\.pem$')` 只能匹配文件名恰好是 `.pem` 的文件，`server.pem` 漏网。已改为 `\.pem$`。

两处按实际代码收敛的实施决定：

1. **`file_write` / `file_patch` 的本地分支不整体转调 `LocalFileOps`**。共享的是 `decodeEscapedText` 与 `backupLocalFile` 两个原语（原来在 `agent_tool.dart` 里是私有副本，已删除并改为引用共享实现）。没有整体转调的原因：那两个分支带着"直接写失败 → 退回 PTY stdin → 再退回 `sudo tee`"的提权链路，属于本地终端会话的历史能力；`local_*` 工具是**受白名单约束**的，让它悄悄借道 sudo PTY 写 root 文件等于绕过策略边界。因此 `local_*` 只用 Dart I/O，权限不足就报错。
2. **写入用"就地写 + 备份 + 失败回滚 + 写后校验长度"，不是 §3.2 写的 tmp+rename**。rename 在 Unix 上丢属主/ACL，在 Windows 上目标已存在时直接失败；这与既有 `file_write` 的取舍一致，原子性由备份 + 回滚承担。

### 5.3 P2 交付记录（2026-11-01）

| 交付 | 位置 |
|---|---|
| `AgentProcessTimeline`：一行一步、点击展开、折叠窗口 | [agent_process_timeline.dart](../ai_terminal/lib/widgets/agent_process_timeline.dart) |
| 事件分流接线（过程 → 时间线；正文/询问/完成 → 原渲染） | [agent_event_cards.dart](../ai_terminal/lib/widgets/agent_event_cards.dart) `_buildEventsContent` |
| `回答:` 协议块解析 `parseAnswerBlock` + finish 时发 `text` 事件 | [agent_engine.dart](../ai_terminal/lib/services/agent_engine.dart) |
| 提示词放开富文本正文 | [prompts.dart](../ai_terminal/lib/core/prompts.dart) `agentAutoRule` |
| 时间线与授权页文案（zh/en） | [agent_ui_text.dart](../ai_terminal/lib/utils/agent_ui_text.dart) |
| 7 例时间线 widget 测试 / 5 例 `回答:` 端到端测试 | [test/agent_process_timeline_test.dart](../ai_terminal/test/agent_process_timeline_test.dart)、[test/react_parse_e2e_test.dart](../ai_terminal/test/react_parse_e2e_test.dart) |

三处偏离设计稿、两处设计稿没写但必须补的：

1. **不新增 `AgentEvent.intent` 字段**。工具行的第二段不取"思考首句"（会和上一行思考重复），而取**最能定位的那条参数**（`path` / `command` / `query` / `remote` / `url` / `hostIds` / `action`）。省掉一次数据契约变更与 DAO 改动，可读性还更好。
2. **不抽 `EventDetailPanel`**。结果卡带着失败分类、重试/重连按钮、多机矩阵、diff 统计、复制与原始输出尾部，重写一份必然退化。改为 `AgentEventContent` 向时间线注入 `resultBuilder`，复用同一个 `_buildResultCard` —— 与该组件已有的 `markdownBuilder` 注入惯例一致。
3. **`CollapsibleEventStream` 退役删除**。它的职责（"更早 N 个事件已折叠"）被时间线的折叠窗口完全覆盖，留着就是两层折叠互相打架；随之删除其 3 个测试。
4. **默认展开策略（设计稿没写，但必须有）**：失败的结果、多机结果、以及任何还没有结果的命令**默认展开**。把错误和重试按钮藏进一次点击里，用户会以为任务顺利 —— 这比省几行屏幕重要。只有"成功且已收尾"的行才收成一行摘要。
5. **`回答:` 的终止符必须包含操作单四字段**。第一版只把 `动作/思考/计划/工具/参数` 当终止行，结果 `结论:` 等字段被整段吞进回答正文（E2E-8/E2E-11 直接测出来）。同时提示词补了一句：正文里不要出现以这些关键词开头的行，要示范就放进 ``` 代码块。
6. 一处测试断言随有意改动更新：`operation_sheet_widget_test.dart` 的"结果卡元数据不溢出"原断言 `find.text('已运行')`（旧命令块的执行状态标签），现在这一行显示真实结果，改为断言 `失败`。

### 5.4 真机验证发现并修掉的六个缺陷（2026-11-01）

`flutter build windows` 出包、连本地模型跑真实一轮任务、逐张截图核对，抓到六个单测阶段没暴露的问题：

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| V1 | 同一次工具调用在证据层出现两遍：上面一个重量级命令块，下面一个时间线行 | `ReActStreamParser._keywords` 不含 `工具:`/`参数:`，这些行掉进"未知行 → text"分支，于是**一个 text 事件把 command 和它的 result 切到两个时间线批次**；批次内查不到配对结果，命令就按"待执行"渲染成重量级块，result 落在下一批次 | 解析器补 `_FieldType.toolProtocol`：`工具:`/`参数:` 吞掉（引擎本来就会发带参数的 command 事件），缩进参数行一并吞，遇顶格行切回 thought 以保住 `结论:/现状:`；同时 `AgentEventContent` 改为**整段只建一个时间线实例**，配对不再受分批影响（§5.11 起为恢复事件顺序改为按段渲染，配对改由全局结果映射保证，V1 不再复现） |
| V2 | 折叠头部显示"过程已折叠 · 更早 0 步" | 头部渲染条件只看"有没有可折叠行"，没看"实际藏了几行" | 改为 `hidden.isNotEmpty` 才出头部 |
| V3 | 破坏性工具（`local_file_delete`）的确认门**没有批准入口**：提示"需要确认"后任务一直挂到 10 分钟超时被自动拒绝 | `AgentCommandBlock` 里确认按钮的条件是 `dangerous && isWaitingConfirm`，而 `dangerous` 写成 `!isTool && …`、`isWaitingConfirm` 也带 `!isTool`，且整块按钮还嵌在 `canExecute`（要求 `!isTool`）里面 —— 工具调用三重被排除。引擎为工具挂起确认时，UI 永远不出现"确认执行/取消" | `dangerous` 对工具改为"是否在等确认"；确认按钮从 `canExecute` 里提出来（普通"执行"按钮仍只对可执行的 shell 命令出现） |
| V4 | 工具的影响面板把本机操作说成"修改服务器状态"，同时下一行写"回滚：无自动回滚，建议先快照"，而 `local_file_delete` 其实是可还原的 | 确认卡复用 `RiskExplainer.explain(command)`，工具的 `command` 是展示串（`local_file_delete` + 缩进的 `path: x`），`inferType` 按 shell 语义推不出类型落到 `other` → 既说错影响对象，又按"没有 shell 回滚命令"推出"无自动回滚"。用户正是看着这句话按批准的 | 新增 `RiskExplainer.explainTool(toolName)`：一张 `_toolImpacts` 表把**影响范围**与**还原方式**成对写（`RiskExplanation` 加 `restoreHint`，工具不编造 shell 回滚命令）；确认卡按 `isTool` 分流 |

| V5 | 改动记录页点"撤销"，本机文件还原的确认框写"将在服务器 **local** 上执行撤销命令："，而命令框是**空的** | 该页只为远程回滚设计过：提示行固定用 `changeRecordRollbackOnHost(hostName)`，命令框固定显示 `rollbackCommand`（本机还原没有 shell 回滚命令，还原信息在 `localRestoreFrom/To` 里）。§5.5 早前只修了执行路径（不要求主机在线），没动提示文案 | 按 `record.isLocalFileRestore` 分流：提示行换成新键 `changeRecordRestoreLocalFile`（"将在本机还原以下文件，不经过任何服务器："），命令框显示 `rollbackHint`（"还原本机文件 → 原路径"） |

| V6 | 确认卡要**往上滚**才点到"确认执行"：面板自动滚到底，用户看到的是影响/还原行，批准按钮在卡片头部（第 1 行）—— 决策入口和决策依据不在同一屏 | `AgentCommandBlock` 的按钮排在头部 Row，影响面板排在 Column 末尾；短面板（默认高度）里两者必然分居两屏 | 等待确认时把"取消/确认执行"移进影响面板末尾，紧跟在还原行之后；头部只保留普通"执行"按钮。`Column` 里头部永远在面板之上，所以这个顺序是结构性的 |

V3 是真机跑出来的：第一次跑 `local_file_delete` 时确认提示出现但无处可点，用户历史里留下了"❌ 用户拒绝执行此操作"——那是超时自动拒绝，不是用户拒绝。修复后同一场景出现批准入口。

V4 修的时候顺带查出自己表里的两处过度承诺，这比说错机器更危险——文案替用户保证了实现并没有做的事：

- `sftp_upload / sftp_download / upload_to / broadcast_upload / file_sync / collect_file` **不备份**（备份只在 `file_write`/`file_patch`/`local_file_*` 里实现），所以它们的文案改成"同名文件会被覆盖且不备份"，不再写"覆盖前会先备份"。
- 备份可由 `backup: false` 关掉，于是统一写成"**默认**覆盖前自动备份"，还原行也只说"生成的备份可放回原路径"，不保证一定有备份。

兜底分支刻意不提"本机/服务器"任何一台：新增工具漏登记时，宁可说得笼统，也不要替用户猜错改的是哪台机器。

回归测试：`agent_process_timeline_test.dart` 新增"破坏性工具等待确认时必须给出批准入口"（断言"确认执行"存在且点击后回传正确命令）与"工具在没有等待确认时不显示批准按钮"；`risk_explainer_test.dart` 新增 `explainTool` 一组 8 例，含"注册表里的每个工具都有具体影响说明"（遍历 `AgentToolRegistry().all`，新工具漏配文案直接红）与"只有真会备份的工具才承诺备份"。已验证该断言非空转：把分流改回 `explain(command)` 后"本机"一条即失败。

回归测试：`agent_process_timeline_test.dart` 新增"正文夹在命令与结果之间时工具调用不得渲染两遍""没有藏任何行时不出更早 0 步头部"；`react_stream_parser_test.dart` 新增一组 3 例（协议行不产 text 事件、协议块后的 `结论:/现状:` 仍进 thought、`回答:` 不重复出正文）。

### 5.5 真机验证结果（2026-11-01，Windows + 本地模型）

**已确认**：

- **拒绝路径**：白名单默认关闭时 `local_file_read` 被拒，文案准确指向 设置 → Agent → 本地文件；AI 收到观测后改为向用户提问而不是硬闯。
- **成功路径**：在设置页开启开关 + 通过原生目录选择器授权一个目录后，`local_file_read` 读到真实内容，结论给出的值与文件完全一致（`port: 9091`，且指明位于 `app:` 块下）。
- **设置页授权区**：开关、"添加目录"（原生选择器带自定义标题）、目录列表、× 移除，全部在真机可用；移除后回到"尚未授权任何目录"。
- **时间线形态**：思考是紧凑单行（超长省略），工具行是 `✦ local_file_read  <path>  <状态>`；失败行自动展开显示参数、错误原文与"让 AI 重试"。V1 修复在真机生效 —— 不再出现协议行重复。
- **破坏性工具确认门（V3+V4 后重跑）**：`local_file_delete` 挂起等待确认，还原行在真机显示为"还原：移入回收区的文件可在改动记录放回原路径"，引擎提示行是"该操作会改动本机文件，需要确认: local_file_delete" —— 机器说对了，不再有"修改服务器状态"或"无自动回滚，建议先快照"。
  - 首轮真机里卡片被切成两屏：先看到影响/还原行，"取消/确认执行"在卡片头部，要**往上滚一段**才露出来（截图时确认计时已走到 1m27s）。批准入口存在且可点，可它和影响说明不在同一屏 —— 这一条催生了 V6 修复。
  - V6 修完后重跑同一场景，三行同屏可见：`删除本机文件（默认移入回收区，不直接抹掉）` / `还原：移入回收区的文件可在改动记录放回原路径` / `[取消] [确认执行]`。点"取消"后文件仍在磁盘上（34 字节，mtime 未变），AI 收到拒绝观测后转为提问而不是硬闯。
- **回收区落点**：批准后 1ms 完成，文件出现在 `<授权根>/.ai_terminal_trash/<时间戳>/note.txt`，原路径变空 —— 回收区确实在授权根内、且被 `LocalFilePolicy` 预留（AI 无法直接操作它）。
- **台账还原真机走过**：改动记录页对该条记录显示"撤销"，执行后文件回到 `.agent-verify\note.txt`（内容 32 字节与原文一致），记录出现"已撤销"标记并收起按钮，提示条写"撤销成功: 还原本机文件 → <原路径>"（走 `rollbackHint`，机器说对了）。**同一次点击暴露了 V5**：确认框本身仍写"将在服务器 local 上执行"且命令框为空。修完后重跑另一条本机记录，确认框显示"将在本机还原以下文件，不经过任何服务器：" + 框内"还原本机文件 → D:\item\ai_terminal\.agent-verify\note.txt"，点"取消"不产生任何改动（记录仍是可撤销态）。
- **操作单语义**：结论徽标显示"AI 结论"而非"已验证" —— 没有确定性证据时不冒认，符合 §2.3。结论正文的 Markdown 粗体在真机渲染出来（`local_file_delete`、`note.txt` 加粗），P2-3 的富文本路径成立。
- **数据库 v5 迁移**：真机在既有库上启动，`ALTER TABLE` 正常执行，会话读写无异常。
- 验证用的临时目录与授权已在三轮验证结束后撤销（开关回到关闭、授权列表显示"尚未授权任何目录"、`.agent-verify/`（含 `.ai_terminal_trash`）整体删除），未改动用户配置。台账里留下的是第一轮那次真实删除的 `local_file_delete … 已撤销` 记录 —— 它是对确实发生过的一次操作的审计，不是脏数据；第二、三轮只走到确认/取消，没有产生新的变更记录。

**仍未确认**：

| 项 | 状态 | 说明 |
|---|---|---|
| P1 真机 SSH E2E（传输部分） | **已跑，9/9 通过**（2026-11-01，真机 `127.0.0.1:1022`） | 见 §5.8 |
| P1 真机 LLM E2E | **已跑**（2026-11-01，真 key + 真服务器） | 首轮抓出跨行 `content` 静默截断缺陷并已修复，见 §5.9；修后连跑 3 轮 6 例全绿 |
| macOS 分支 | 做不了 | 本机是 Windows |
| 确认卡批准入口与影响说明同屏（V6） | 已修 + 真机复拍 | 按钮移进影响面板末尾；widget 测试断言"确认执行"排在还原行之后（把按钮从面板里摘掉该测试即红，已验证非空转），真机重跑确认三行同屏（见 §5.5） |
| 回收区清理入口 | 已补（见 §5.6） | 设置页显示条目数与占用，并提供"清空回收区"；不做自动过期清理，理由见 §5.6 |

**发布注意**：`_schemaVersion` 4 → 5，`change_records` 增加 `localRestoreFrom` / `localRestoreTo`。老库首次启动走 `_onUpgrade`；降级回旧版本时这两列被忽略（读不到即视为不可回滚，不会崩）。

补做方式（凭据到位后）：

> **更正（2026-11-01）**：这里原写"两个值都必需，没有中间态可先跑"——只对 `local_llm_e2e_test.dart` 成立。`transfer_e2e_test.dart` **只门控 `E2E_SSH_*`**，拿到 SSH 凭据即可单独解锁，实测已跑通 9 例（见 §5.8）。教训：断言"不可部分解锁"前，要按文件逐个查门控条件，不能拿其中一个文件的结论套整条命令。
> 剩余那 2 例确实无中间态：`local_llm_e2e_test.dart` 的用例都是驱动 agent 去服务器上写文件，去掉 SSH 就没有可跑的子集；而占位 key 会被 `/v1/chat/completions` 拒（`400 Invalid or disabled API key`，`/v1/models` 倒是免鉴权）。填错密码会在 3 秒内失败并明说"这是凭据或网络问题"，不会伪装成产品缺陷。

```bash
cd ai_terminal
E2E_LLM_BASE_URL=http://localhost:1994/v1 E2E_LLM_MODEL=agnes E2E_LLM_API_KEY=*** \
E2E_SSH_HOST=127.0.0.1 E2E_SSH_PORT=1022 E2E_SSH_USER=root E2E_SSH_PASSWORD=*** \
  flutter test --no-pub test/local_llm_e2e_test.dart test/transfer_e2e_test.dart
# 视觉验证（先关闭正在运行的 ai_terminal.exe，否则 LNK1168）
flutter build windows
```



### 5.6 P2-5 回收区用量与清理（2026-11-01）

§5.5 记下的一条真实风险：`local_file_delete` 的副本落在 `<所在目录>/.ai_terminal_trash/<时间戳>/`，而还原是**复制**回原位（副本故意留着，好让同一条记录能反复还原）。没有任何用量视图和清理入口，就是往用户磁盘上做无界写入 —— AGENTS.md R8 说的是内存缓冲，同一道理适用于磁盘。

| 交付 | 位置 |
|---|---|
| `TrashUsage` / `isTrashEntryDir` / `trashEntriesFromRestorePaths` / `measureTrashEntries` / `clearTrashEntries` / `countPathsUnderEntries` / `formatByteSize` | [local_file_ops.dart](../ai_terminal/lib/utils/local_file_ops.dart) |
| 设置页"回收区：N 项 · 约 X MB" + 清空按钮 + 后果说明确认框 | [agent_settings_page.dart](../ai_terminal/lib/pages/agent_settings_page.dart) `LocalFileAccessSection` |
| zh/en 文案 | [agent_ui_text.dart](../ai_terminal/lib/utils/agent_ui_text.dart) `localFileTrash*` |
| 13 例单测 + 1 例设置页空态 widget 测试 | [test/local_file_trash_test.dart](../ai_terminal/test/local_file_trash_test.dart)、[test/local_file_tools_test.dart](../ai_terminal/test/local_file_tools_test.dart) |

三个决定：

1. **条目从台账反查，不扫授权目录**。删除时位置已经写进 `change_records.localRestoreFrom`，反查是 O(记录数)；扫目录要在整棵授权树里找 `.ai_terminal_trash`，大仓库上代价高，还会撞上黑名单路径的判定。
2. **只做手动清空，不做自动过期**。自动删等于在用户不在场时销毁他唯一的副本 —— 而"能不能捞回来"正是这条链路的卖点。清空前明确告知"之后 N 条记录无法再还原（记录本身保留）"，判断权留给人。清空后旧记录的还原会返回"副本已不存在（路径），无法还原"，这条已有单测兜着（`change_record_service_test.dart:318`）。
3. **清理函数自己再校验一次路径**。`clearTrashEntries` 对每个入参重跑 `isTrashEntryDir`，不在回收区的直接进 `refused` 列表，绝不删除。判定要求"回收区段的下一层"，所以既删不掉用户的普通目录，也删不掉 `.ai_terminal_trash` 根目录本身（根目录是保留目录，删了后续删除就无处可去）。台账数据被污染、或旧版本写过一个奇怪位置时，这一层是最后的刹车。

`refused` / `failed` 都会拼进结果提示 —— 静默少删会让用户以为已经清干净了。

证据边界：清理逻辑与用量统计有 13 例单测（含"回收区外的目录原样保留"这条安全断言），设置页那一行有 widget 测试覆盖空态与不溢出的布局。

**非空状态的真机复拍已补**（2026-11-01 第四轮真机）。状态是这样造的：不是再跑一次删除，而是把**既有台账记录所指向的那份副本**原样放回磁盘（`.agent-verify/.ai_terminal_trash/1793518737989/note.txt`，32 字节）—— 该记录是第一轮真机删除留下的，路径是真实的，所以这是对"从台账反查条目"这条链路的正当演练，而不是伪造计数。结果：

- 用量行显示"回收区：1 项 · 约 32 B"，字节数与那个文件完全一致（证明量的是真实文件大小，不是条目数×估算）；"清空回收区"按钮只在非空时出现。
- 确认框写"清空会永久删除这 1 项副本（约 32 B）。之后 1 条改动记录将无法再还原（记录本身保留，只是捞不回文件）。" —— 条目数、字节、受影响记录数三个数都对。
- 点"清空回收区"后：提示条"已清空回收区：删除 1 项，释放约 32 B"，用量行**当场**回到"回收区为空"且按钮消失（清空后重新测量，不是只改 UI 文本）。
- 磁盘侧核对：`<时间戳>` 条目目录被删，`.ai_terminal_trash` 根目录**保留为空** —— 正是 `isTrashEntryDir` 那条"根目录不删"的规则。
- 顺带确认一个设计属性：此时开关已关、授权列表为空（前几轮清理后的状态），用量行仍然显示并可清理。回收区里可能留着历史副本，用户关掉访问之后也必须能把空间要回来。

另外核对了一处 §3.6"发布注意"的证据来源：应用数据库是 SQLCipher 加密的（文件头不是 `SQLite format 3`，无法也不该直接读），所以"v4→v5 迁移 + `localRestoreFrom/To` 持久化"不是靠读库文件确认的，而是靠真机重启后改动记录页仍能从数据库算出还原入口（撤销按钮渲染的前提就是 `isRollbackable` 读到该列）确认的。

顺带补了一条与本轮直接相关的安全测试：回收区跟着被删文件的目录走，所以它会出现在授权根的**任意深度**（`<root>/sub/deep/.ai_terminal_trash/…`）。`LocalFilePolicy` 的保留判定是按路径段匹配的，嵌套情形本来就拒得住，但之前只测了根下一层 —— 补了"嵌套一层的回收区同样是保留目录"（读/删/列三种入口都断言被拒，副本内容原样未变），因为 §5.6 的清理逻辑正是要依赖"这些条目只能由删除工具自己写"。

### 5.7 完成度复核与路径混淆守卫（2026-11-01）

按 §3.6 契约清单、§4 结论、规则映射逐条回查代码，查出三类问题：

| # | 问题 | 处置 |
|---|---|---|
| A1 | §4 承诺"写远程失败时观测里回带本机/远程提示"，实际只做了 description 互斥，**守卫根本没写**。后果不是文案不准，是静默错机器写入：SSH 会话里 `file_write path: D:\deploy\app.conf` 会被 SFTP 当成一个文件名写到服务器上并回报成功 | `file_write` / `file_patch` 在 `executor is SSHService` 分支的最前面拦 `^[A-Za-z]:[\\/]` 形态的路径，失败文本指路 `local_file_*`；反向在 `LocalFileTool._resolve` 里给"未获授权"的拒绝附一句"这看起来是远程主机的路径"（只在 Windows 本机生效，POSIX 本机的合法路径就是 `/` 开头，加了就是误伤） |
| A2 | R8 要求截断标注，`local_file_read`（字节上限 + "共 N 行，显示 a-b"）和 `local_file_search` 的命中数上限都有，但**遍历文件数的 5000 上限是静默 `break`** —— AI 会把"扫了 5000 个没找到"当成"整个目录里没有" | 加 `walkCapped` 标记，命中与未命中两条出口都追加"文件数已达 5000 上限，未继续遍历，请用 glob 或更窄的 path 缩小范围" |
| A3 | 三处文档与实现不一致：§3.6 仍列 `AgentEvent.intent` 新字段（§5.3 已决定不采纳）、§4 的"一次性引导 + 跳设置页"实际是"每次拒绝都点名设置路径、无跳转"、规则映射 R2 说 tmp 文件在 `finally` 删除而本机写入根本不用 tmp | 就地更正这三行，并注明理由（一次性状态要么落盘要么内存态，都不值一行引导语；跳转入口该放在拒绝卡片里而不是发给模型的观测文本） |

测试：`本机/远程路径混淆防护` 一组 5 例（远程两个工具各拦一次、`/etc/...` 不被误伤、Windows 本机指路、敏感目录的拒绝不附带指路）。用未连接的 `SSHService(HostConfig.create(...))` 就能测守卫顺序 —— 断言"不出现 SSH 连接未建立"即证明守卫在建连检查之前。

过程中一个真实的自伤：A1 的形状判定最初用 shell heredoc 追加进 `local_file_ops.dart`，`r'^[A-Za-z]:[\\/]'` 里的双反斜杠被吃掉一层，落成 `[\/]` —— 在 Dart 正则里那只是 `/`，于是 `D:\deploy` 匹配不上，测试直接红。改成用编辑工具写入并回读确认字节后通过。教训：带反斜杠的字面量不要经 heredoc 写，写完必须回读。

### 5.7.1 补测：备份失败必须中止（§5.2 的欠账）

§5.2 把"备份失败即中止"列为已覆盖，实际**一条测试都没有** —— 真要触发备份失败只能靠文件锁 / 超长路径 / ACL，都平台相关且不稳。给 `writeLocalFile` 加了一个 `@visibleForTesting` 的备份注入点，换来 4 条确定性断言（[local_file_edit_test.dart](../ai_terminal/test/local_file_edit_test.dart)）：备份抛错时原内容一字节不动、错误里带原因、`backup: false` 是用户的显式选择不走备份、`append` 不做备份所以不会被它挡住。

顺带确认了一处**有意分歧，不是缺陷**，记在这里免得以后被"统一"掉：`local_file_write` 备份失败一律中止；`file_write` 的本地分支只在 Windows 或一般异常时中止，非 Windows 上遇到 `FileSystemException` 会置 `backupUnavailable` 继续写并提示"未能生成备份"。原因是 `file_write` 有 PTY/`sudo tee` 兜底，读不到的文件可能属于 root 而当前 shell 有 sudo；`local_*` 是策略门控工具，**故意不给它任何提权退路**（§3.3 的安全决定）。两条规则不同，各自都对，合并任何一条都会引入提权或静默覆盖。

复核还确认：符号链接逃逸那条测试在本机是**真的跑过并通过**（不是 skip）—— Windows 建符号链接要特权或开发者模式，缺它的机器上这条会静默跳过，所以 §5.2 的"覆盖符号链接"是带平台前提的。

### 5.7.2 复核：「预留 MCP 接口」到底预留住了没有

用户定的范围是"内置 + 预留 MCP 接口"，所以 §3.1.2 的 `mcpDescriptor` 不是装饰。原来只有一条测 `cert_check` 一个工具形状的用例（另一条 `web_search` 的断言写在 `if (web != null)` 里，而它默认未注册 —— 等于永远不执行）。现在改成遍历**全部 26 个工具**（默认注册表 + `enableWebTools()` + `enableOrchestrator(AgentHostRegistry())`；编排工具是 `exec_on`/`exec_batch`/`broadcast_upload` 这批最危险的，不开就等于不验，而 `AgentHostRegistry` 无参可构造，注册它们不需要真连接），逐个断言：`name` 与工具一致、`description` 非空、`inputSchema` 必为 `type: object` 且带 `properties`、三个 hint 与 `kind` 一一对应、`readOnlyHint` 与 `destructiveHint` 不得同时为真；另加一条用 `_NullSchemaTool`（`toJsonSchema()` 返回 null）验证回落路径。

顺带把 §3.1.2 草案里的 `idempotentHint` 与实现对齐：**不发**。按 `kind` 派生它会撒谎（`file_write` 幂等、`file_patch` 不幂等，两者同为 `write`），要提供得加每工具可覆写的 getter，那是接 MCP server 时的事。同时给 `toJsonSchema() == null`（语义是"不参与 OpenAI FC"）补了 schema 回落，否则这类工具一导出就是非法描述符。

### 5.7.3 复核：paramSpec 的调用格式是否统一（D2 的同类病灶）

审计手法上先走了弯路：用一段 node 正则去算"工具读了但 paramSpec 没写的参数"，报出 14 个工具。抽查 3 个**全是误报** —— 正则没匹配单行写法的 paramSpec（`exec_batch` 的 `hostIds`/`stopOnFailure` 其实都写了），也没识别"藏在别的 key 描述里"的别名（`local_file_patch` 的 `old_b64` 写在 `old:` 那行）。启发式不是证据，报得多的时候必须先抽查再下结论。

抽查倒是暴露了一个真问题：**`project_analyze` / `build_project` / `package_project` 三个工具的 paramSpec 仍是 JSON 形状**（`'{"path":"…","command":"…"}'`），而其余 23 个工具都是 `参数列表（多行 key:value 格式）`。`ToolArgsParser` 能兜住 JSON（[tool_args_parser.dart:38](../ai_terminal/lib/utils/tool_args_parser.dart#L38)），所以这不是功能 bug，而是 **D2 只做了一半**：提示词里同时教两种互相冲突的调用格式，模型对着哪个学都不确定。

处置：三个 paramSpec 改成多行 `key: value`（纯描述性改动，不动解析与执行路径），并加一条注册表级守卫 —— 遍历全部 26 个工具，`paramSpec` 必须非空且不得以 `{` 开头（[tool_contract_test.dart](../ai_terminal/test/tool_contract_test.dart) "没有任何工具的 paramSpec 用 JSON 形状"）。


### 5.7.4 复核：操作单的本机还原标记（这次没查出缺陷）

`OperationChange.localRestore` 由 [agent_engine.dart:2322](../ai_terminal/lib/services/agent_engine.dart#L2322) 从 `record.isLocalFileRestore` 得出，进 `toJson/fromJson`，并参与 `canRollback`。操作单是"自包含、渲染时不查数据库"的，所以**还原入口能不能出现全押在这个布尔位上** —— 它在派生或序列化里丢一次，用户重开会话就再也看不到还原，而且不会有任何报错。此前**零测试**。

补 4 例（[operation_report_test.dart](../ai_terminal/test/operation_report_test.dart)）：只有 `localRestore` 也算可还原（本机变更没有 shell 回滚命令）、JSON 往返保住该位、**旧数据缺键时按"不可还原"处理而不是冒认**、空白 `rollbackCommand` 不算可还原。四条一次通过 —— 实现是对的，这一条的价值在于把契约钉住，而不是发现 bug。审计里"查了没问题"和"查出问题"都要记，否则下一轮会重复怀疑同一个点。

### 5.7.5 真挂死缺陷：等确认时暂停再恢复，任务永久卡住

查 R1（"等待中的 Completer 不能只置 null，必须自己 complete"）时命中，是本轮唯一的新代码缺陷，而且就在我为破坏性工具新加的确认路径上。触发只需两步点击，不需要竞态：

1. `local_file_delete` 挂起等待确认（状态 `waitingConfirm`）；
2. 用户点**暂停** —— `pauseTask()` 明确接受 `waitingConfirm`（[agent_engine.dart:693](../ai_terminal/lib/services/agent_engine.dart#L693)），但它不唤醒 `_confirmCompleter`；
3. 点**恢复** —— `resumeTask()` 开头调 `_resetTransientState()`，而它原本对三个等待者只做 `_xxxCompleter = null`，**不 complete**。future 唯一的出口就此丢掉，那一轮的 `await` 永远醒不过来，`result`/`finish` 事件不再发出，任务永久挂死。

修法：`_resetTransientState()` 改成"先 complete 再置 null"，与 `cancelTask` 已有的写法一致；确认按 `false`（未批准）收口，**绝不默认放行破坏性操作**；`_choiceCompleter` 按空选择收口；`_earlyExecutionCompleter` 按 `shouldContinue: false` 收口。回归测试见 [tool_contract_test.dart](../ai_terminal/test/tool_contract_test.dart) 的"暂停/恢复不得丢弃等待中的 awaiter"，测试日志里能看到它确实走的是 `暂停前状态: AgentStatus.waitingConfirm`。

过程里我先猜错了地方：以为 `startTask` 开头那条重置也会丢弃等待者（它的注释写着"不依赖 cancelTask 清理"）。读代码才发现该函数开头是 `if (isRunning) { 拒绝新任务; return; }`，而 `waitingConfirm` 属于 running，那条路根本走不到。据此把已经写好的两版测试连同一次改动全部回滚重做 —— **猜出来的路径不算发现**，这一步比修本身更重要。

修完还得验一件副作用：确认被重置成 `false`，而 `_handleToolAction` 里 `!approved` 的分支会写一句"❌ 用户拒绝执行此操作"。用户只是点了暂停，从没拒绝过 —— 这正是 V3 那类"系统行为冒充用户意图"。实测不会发生：`resumeTask` 里 `_currentTaskGeneration++` 与重置同帧完成，被唤醒的 `await` 续体排在之后的微任务里，所以旧循环先在 [agent_engine.dart:2471](../ai_terminal/lib/services/agent_engine.dart#L2471) 的代际检查处静默退出，走不到那句文案。这个结论依赖语句顺序，顺序一旦被重排就会静默失效，所以测试里直接钉了两条断言：事件流中不得出现"用户拒绝执行此操作"，也不得出现 `error: 用户拒绝执行该操作` 的 result。

### 5.7.6 归因修正：确认超时不是用户拒绝

V3 的记录里写过一句"用户历史里留下了『❌ 用户拒绝执行此操作』—— 那是超时自动拒绝，不是用户拒绝"，但当时只修了"没有批准入口"，**归因这一半一直没修**：两个确认定时器（危险命令、破坏性工具）都是 10 分钟到点 `complete(false)`，而调用方只看 `false` 就写"用户拒绝"。于是每次超时，历史里都会留下一件用户从没做过的事，模型也被误导成"被否决了，别再试"（超时场景下正确建议恰恰是可以重申）。

- 加 `_confirmTimedOut` 标记，两个定时器各自置位，两处等待入口开始时复位（不复位的话，一次超时会把之后的真实拒绝也错标成超时）。
- 面向用户的文案与喂给模型的观测都分流：超时 →"⏱ 确认超时（10 分钟无响应），已自动拒绝"，观测改口为"用户可能只是暂时离开，可以重申一次或改用更保守的方案"；真拒绝仍走原来的"❌ 用户拒绝执行此操作 / 不要重复尝试"。
- 提前执行的 `onSuccess` 上报也跟着分成 `confirm_timeout` 与 `user_rejected`，别让统计把两种性质不同的事件算成一类。
- 测试：真定时器要等 10 分钟，所以把收口逻辑抽成 `expireConfirmTimeoutForTesting` 注入点，断言事件流里出现"超时"且不出现"用户拒绝"、result 的 error 也写超时。

修这条的起因是 R5 的"所有终态路径行为一致"走查 —— 又一次说明**文档里写过的结论不等于已经修完**。

### 5.7.7 复核 R4：配对正确但没有测试；对 E2E 解锁成色的判断（后被 §5.8 部分修正）

R4 走查结果：时间线按 `resultMap[e.commandId]` 逐条配对，不是历史上那种"记住最后一条命令 id"的写法；找不到对应命令的**孤儿 result 也会被渲染**（[agent_process_timeline.dart:183](../ai_terminal/lib/widgets/agent_process_timeline.dart#L183)）。实现是对的 —— 但这条属性**一条测试都没有**，而孤儿 result 通常正是失败（命令被裁剪掉了，错误还在）。哪天有人"优化"成只渲染配对成功的 result，这些失败就静默消失了。补 1 例 widget 测试钉住。

另外把 `local_llm_e2e_test.dart` 那 2 例的解锁成色实测清楚了（结论：这 2 例确实无法部分解锁；但当时顺手把它推广成"整条 P1 E2E 不可部分解锁"是错的，见 §5.8）：

- 本地端点 `GET /v1/models` 不需要鉴权，但 `POST /v1/chat/completions` 返回 `400 Invalid or disabled API key` —— **占位 key 不管用**，`E2E_LLM_API_KEY` 必须来自用户。
- `local_llm_e2e_test.dart` 的两个用例都是驱动 agent 去**服务器上的路径**写文件，没有"只靠 LLM 就能跑"的子集。

所以 `local_llm_e2e_test.dart` 那 2 例同时需要 `E2E_SSH_PASSWORD` 与 `E2E_LLM_API_KEY`，两者都只能由用户提供，没有可绕开的中间态。

### 5.8 SSH 凭据到位后的真机 E2E 实测（2026-11-01）

用户提供了 `root@127.0.0.1:1022` 的密码，并说明该主机已存进应用服务器列表（名 `docker centos8`）。密码只经 `E2E_SSH_PASSWORD` 环境变量传入，未写进任何文件。

```bash
E2E_SSH_HOST=127.0.0.1 E2E_SSH_PORT=1022 E2E_SSH_USER=root E2E_SSH_PASSWORD=*** \
  flutter test --no-pub test/transfer_e2e_test.dart
# → 00:23 +9: All tests passed!
```

9 例全在真实 SFTP 通道上跑通，覆盖：单文件字节/文件名/覆盖安全、二进制与大文件 SHA-256 相符、递归目录（含空目录与 excludes）、特殊字符名不被 shell 解释（`$NAME`、反引号、单双引号、`& ;`、emoji、中文）、失败路径不留半截文件（远程目标是目录、本地路径被占用、写进 `/proc`）、`upload_to`/`broadcast_upload`/`collect_file` 走真 SFTP、远端 `file_patch` 只改 old→new 其余字节不动、SFTP 文本编辑器 refuses 截断风险、显式本地文件路径与尾部分隔符。

这条把 §5.7.7 和 §5.5 里"P1 真机 E2E 整体不可部分解锁"的说法**证伪了**：那个结论只对 `local_llm_e2e_test.dart` 成立，`transfer_e2e_test.dart` 只门控 `E2E_SSH_*`，两处已按证据更正。默认 `flutter test` 在没有环境变量时仍会 skip 这 9 例，所以"16 skipped"里真正被真机解锁的是这 9 例 + LLM 那 2 例仍在等 key，其余是 macOS/平台门控。

**剩余唯一凭据缺口**：`E2E_LLM_API_KEY`（`local_llm_e2e_test.dart` 的 2 例）。按约定不从应用的模型配置或凭据存储里翻这个值。

### 5.9 真机 LLM E2E 跑出第二个缺陷：跨行 content 静默截断（2026-11-01）

用户补上 `E2E_LLM_API_KEY` 后跑 `local_llm_e2e_test.dart`，第一轮 `+1 -1`：`CN_FILE_BYTES: 12`，文件里只剩 `中文测试`，而 `CN_FINISH: success`、结论写「已验证为三行内容」。**agent 报告的完成与真实落盘不一致**，这是 P1 想抓的那类问题，第一次真机就抓到了。

根因不在模型稳定性，重跑 3 次全绿反而掩盖了它：`ToolArgsParser.parse` 对**没有冒号的行 `continue` 跳过**（[tool_args_parser.dart:55](../ai_terminal/lib/utils/tool_args_parser.dart#L55)）。模型把三行正文直接写成

```
参数:
  path: /tmp/ai_terminal_llm_cn.txt
  content: 中文测试
    emoji 😀🚀
    结束
```

时，`content` 只取到第一行，后两行是"无冒号行"被丢弃，`file_write` 拿到 `content=中文测试` 正常执行并回 `success=true`。日志里那条 `工具 file_write 执行结果: success=true` 紧跟着 `AI 未返回有效动作` —— 模型后面还把观测正文当命令执行了一次（`执行命令: 中文测试\nemoji 😀🚀\n结束`，`success=false`），是同一根因的下游噪声，不是第二个缺陷。

**修法**：无冒号的非空行不再静默跳过，**整个参数块判为不可解析返回 null**，与既有的 JSON 拒绝走同一条路（`parse` 的注释里那条设计说明：engine 记 warn，工具因必填校验报错，模型收到反馈后改写）。下游是 `ToolArgs(step.toolArgs ?? const {})`（[agent_engine.dart:2546](../ai_terminal/lib/services/agent_engine.dart#L2546)），`requireString('content')` 抛 `缺少必填参数: content`，工具**根本不会执行**，服务器上不会留下半截文件。

**取舍**：错误提示是通用的"缺少必填参数"，没点名"你换行了"。选择沿用 JSON 拒绝的同一形状而不是新开一条控制流：`参数:` 里出现无冒号行只有两种可能（跨行正文 / 乱入散文），两者都不该被执行；而新开分支要改 `parseToolAction` 的返回形状，按 R9 会波及全部调用方与测试替身。若后续实测模型反复踩同一形状不改写，再考虑专门提示。

**测试**（按 R9 补的是链路测试，不是单测）：
- `test/tool_args_parser_test.dart`：原 `跳过无冒号的行`（钉住旧行为的断言 `result.length == 2`）改写为 `无冒号的行 → 整块判为不可解析`，另加"跨行 content → null"和"一行 `\n` 转义 → 正常"两例。旧测试钉的正是这次要废掉的语义，所以新断言天然非空转。
- `test/react_parse_e2e_test.dart` 新增 E2E-13/E2E-14：从真实 ReAct 文本进 `AgentEngine.parseToolAction`，断言工具名保留、参数为 null；以及正确形状下 `content != '中文测试'`。

**门槛**：`flutter test` **614 通过 / 16 跳过**（改前 610，净 +4：删 1 加 5）；`flutter analyze` 31 issues / 0 error（基线未变）。修好后真机 LLM E2E 连跑 3 轮 6 例全绿，`CN_FILE_BYTES: 34` 三行齐全。

---

### 5.10 真机问题：结论卡片显示自述、真正回答被折进证据（2026-11-04）

用户现场截图：操作单"结论"卡片显示的是一段"我不该在正文里放可被误复制的命令样式文本"的自述，而真正的结论与依据必须展开"过程与证据"才能看到。

**这是三个实现缺口叠出来的，不是模型输出问题：**

1. `_finishTask(summary: step.thought)` 把 finish 的"思考"当报告来源，但新协议里真正的结论是 `结论:` 字段、正文是 `回答:`；思考常是给系统看的推理/自述。
2. `回答:` 正文此前作为 `text` 事件发出去，而 `OperationSheet` 把除 report/finish 外的事件全部塞进"过程与证据"折叠层 —— 正文因此默认不可见。
3. `回答:` 之后的操作单四字段从未被解析：`ReActStreamParser` 把 `回答:` 当思考行，四段又跟在后面，`parseAnswerBlock` 到 `结论:` 就截断，`_emitOperationReport` 只能拿到第一段思考。

**修法**（`回答:` 属于结论层，不是证据）：

| 改动 | 位置 |
|---|---|
| `ReActStep.sections`：用 `parseReportSections` 单独解析 `回答:` 之后的结论/现状/变更/建议 | [agent_engine.dart](../ai_terminal/lib/services/agent_engine.dart) |
| `OperationReport.answerBody`：完整回答正文随 report 持久化；结论取值优先级改为 `结论:` 段 → 回答首段 → 思考首段 | [operation_report.dart](../ai_terminal/lib/models/operation_report.dart) |
| `OperationSheet` 在结论卡片下方直接渲染 `answerBody`（与结论相同时去重），复制按钮一并复制正文 | [operation_sheet.dart](../ai_terminal/lib/widgets/operation_sheet.dart) |
| `ReActStreamParser` 新增 `_FieldType.answer`：回答正文不再作为思考行进入过程时间线，也不再重复发 `text` 事件 | [react_stream_parser.dart](../ai_terminal/lib/utils/react_stream_parser.dart) |
| `_composeFinishSummary`：finish 文本 = 四段字段 + 回答正文。目标模式的完成标记写在 `回答:` 里，此前只拼 summary 检测不到 | [agent_engine.dart](../ai_terminal/lib/services/agent_engine.dart) |

**测试**：`operation_report_test` 新增 3 例（结论优先于回答、回答首段回退、思考回退）；`react_stream_parser_test` 把"回答归入思考"改为"回答不进过程事件"；`react_parse_e2e_test` 新增 E2E-15（回答与四段分别解析、不混进思考）；`agent_engine_resilience_test` 新增 1 例完整链路（模型输出 → 引擎 → report 的 conclusion/answerBody/finish summary）；`operation_sheet_widget_test` 新增 2 例（正文默认可见、与结论同文时不重复）。`flutter test` **727 通过 / 23 跳过**，`flutter analyze` 33 issues / 0 error（无新增 error/warning）。

**已知边界**：修复前持久化的旧 report 没有 `answerBody`，旧会话仍按原样显示（正文留在证据层、结论仍是当时存下的文本）；历史数据无法重建四段字段，不做回填。

---

### 5.11 真机问题：询问卡片永远沉在消息底部（2026-11-04）

用户截图：已经选过的 ask 选项卡片一直留在消息最底部，之后执行的终端命令反而出现在它上面；用户描述为“做完的选择不跟着消息往上走”。

**根因是渲染分组，不是固定悬浮**：`AgentEventContent._buildEventsContent` 先把**所有**过程事件（思考/命令/结果/工具）汇总成一条时间线放在最上面，再把正文、ask、finish 统一接在后面。ask 之后的命令进入顶部时间线，ask 卡片就永远留在底部区块，看起来像被钉住。

**修法**（[agent_event_cards.dart](../ai_terminal/lib/widgets/agent_event_cards.dart)）：

| 改动 | 说明 |
|---|---|
| 按原始顺序分段 | 过程事件攒成一段 → 遇到正文/ask/finish 就切段并渲染该事件；后续过程事件在新段里继续，形成交错顺序 |
| 命令/结果跨段配对 | 先建全局 `resultByCommand`（只登记有对应 command 的结果），命令行渲染时把结果挂进同一段并在原位置跳过；V1 的重复渲染问题不会回来，孤儿结果仍在原地显示 |
| 只有当前询问可点 | `pendingAskId` 只认最后一个 ask；历史 ask 保留问题文本但选项禁用，避免回头误答旧问题 |
| 仅最后一条消息可等待 | 父级改为 `isWaitingChoice: agentState.isWaitingChoice && isLast`，历史消息不会跟着变成可点 |

**测试**：新增 3 例（ask 之后的命令必须在其下方、正文之后的过程事件必须在正文下方、等待时只有最后一个 ask 可点）；`flutter test` **737 通过 / 23 跳过**，`flutter analyze` 33 issues / 0 error。

**取舍**：时间线按正文/ask 切成多段后，长任务可能出现多个“更早 N 步”折叠头；换来的是事件严格的时间顺序。命令与结果的配对由全局映射保证，不依赖“所有过程事件在同一实例里”。

---

## 6. 非目标




- **不实现 MCP 协议客户端**。本轮只把契约对齐到 MCP 形状（§3.1.2），接外部 server 时新增一个 `McpToolProvider implements` 同一契约即可。
- 不做子 Agent / 并行工具调用（截图 2 的"子 Agent 已完成 222s"形态）——当前引擎是单任务串行 ReAct，加并行会撞 R1/R3 的全部前提。
- 不做远程主机的文件树浏览器、不改 SFTP 页面。
- 不做 Windows 卷影副本级别的删除保护（回收目录 + 台账足够）。
- 不放开 14 语言的时间线文案（沿用 zh/en + 其余回落英文的既有约定）。

---

## 7. 交接状态（2026-11-01，目标暂停时读这里）

> **链接时效**：本文的 `文件名#L行号` 锚点是各自交付时抓的快照，此后 `agent_engine.dart`、`terminal_page.dart`、`operation_sheet.dart` 又因[目标模式与运行计量](./agent-goal-mode-metrics-bar-design.md)的 P0–P7 长了数百行，行号一律偏小（那份文档的开头有实测漂移表）。**定位请用符号名 grep，不要信行号。** 文中的事实性结论（F1–F14、V1–V6、§5.x 交付记录）不受影响——它们在最后一轮复拍里是对着当前代码和真机界面重核过的。

**结论**：本设计的 P0 / P1 / P2 与追加的 P2-5…P2-15 全部落地；P3 明确不做。§5.5 的 P1 真机 E2E 已全部在真机跑通：SFTP 9 例（§5.8）+ 真模型 2 例（§5.9），后者首轮就抓出一个静默截断缺陷并已修复。**§5.5 的"仍未确认"表里没有剩余项了**（macOS 分支属平台不可能）。

**当前证据**：`flutter analyze` 31 issues / 0 error（与改动前基线一致）；`flutter test` 500 通过 / 16 跳过（16 个 skip 就是环境未就绪的 E2E）；`flutter build windows` 通过。**未提交任何东西**。

> 更新（2026-11-01，目标模式那一份文档收口时）：本文交付后仓库又长出了 [agent-goal-mode-metrics-bar-design.md](./agent-goal-mode-metrics-bar-design.md) 的 P0–P7，全量测试已从 500 涨到 **604 通过 / 16 跳过**（analyze 仍是 31 issues / 0 error 基线）。上面这行 500 是当时的快照，保留不改，是为了留住"那一轮收口时到底是什么状态"；当前数以另一份文档的 §6.11 为准。

**剩余那一步**：本设计范围内没有了。真机 E2E 已全部跑过（§5.8 SFTP 9 例、§5.9 真模型 2 例）。凭据按约定只经环境变量传入、未写进仓库；`test/support/e2e_ssh.dart` 会在填错密码时 3 秒内失败并明说是凭据问题。默认 `flutter test` 仍会 skip 这 11 例（无环境变量），所以"跳过"不等于"没验过"，也不等于"验过了"——以 §5.8/§5.9 的实跑记录为准。

**若要提交**：只提交本项目文件，必须排除他人并发修改 —— `ai_terminal/lib/pages/settings_page.dart`、`web_search_settings_page.dart`、`web_search_service.dart`、以及两个 `.serena/` 目录。

**审计台账**（§5.4 的 V1–V6 是真机跑出来的；§5.7.x 是逐条复核出来的，每轮都有实质产出，别把"已完成"当证据）：

| 轮次 | 产出 |
|---|---|
| §5.4 V1–V6 | 工具重复渲染、"更早 0 步"、破坏性工具无批准入口、影响文案说错机器、台账还原框说"服务器 local"、批准按钮与影响说明不同屏 |
| §5.7 | 路径混淆守卫从未实现（会静默写错机器）、遍历上限静默、三处文档与实现不符 |
| §5.7.1 | "备份失败即中止"零测试 → 加注入点补 4 例 |
| §5.7.2 | MCP 描述符只测 1 个工具 → 全 26 个形状守卫 + null schema 回落 |
| §5.7.3 | 3 个 project 工具仍教 JSON 参数（D2 半拉子）→ 统一 + 守卫 |
| §5.7.4 | 操作单 `localRestore` 契约零测试 → 补 4 例（实现本身正确） |
| §5.7.5 | 真挂死：等确认时暂停再恢复会永久卡住任务 |
| §5.7.6 | 确认超时被写成"用户拒绝执行"（V3 记录里写过却没修完的归因） |
| §5.7.7 | 孤儿 result 渲染无测试；对 E2E 解锁成色的判断**偏保守**（见下一行） |
| §5.8 | 真机跑通 9 例 SFTP E2E，同时证伪本文两处"不可部分解锁"——按文件查门控才发现 `transfer_e2e_test.dart` 只要 SSH |
| §5.9 | 真模型 E2E 首轮抓到跨行 `content` 静默截断：文件只剩第一行而 `file_write` 报成功、结论自称"已验证三行" → 无冒号行改为整块拒解析 + 2 例链路测试 |
| §5.10 | 用户真机截图：结论卡片显示 finish 思考里的自述，真正回答被折进"过程与证据" → `回答:` 进结论层、四段字段独立解析、finish 文本带上回答（目标模式完成标记） |

**方法教训**（避免下次重犯）：带反斜杠的字面量不要经 heredoc 写，写完回读；文档加章节不要以下一个标题做锚点；启发式扫描报多了先抽查；猜出来的根因不算发现，路径不可达就把投机改动连测试一起回滚。
