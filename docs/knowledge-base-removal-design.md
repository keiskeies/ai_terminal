# 知识库功能整体剔除

状态：**已实现并验收**（实测见 §7；实现过程中对本文若干预测的更正就地标注为「实测更正」）
范围决策（用户确认）：**官方命令知识库全删**；设置页「内部规范 / House rules」**保留**；已装用户机器上的本地库文件**不动**（只删代码）。
关联：`lib/services/knowledge_service.dart`、`lib/services/agent_engine.dart`、`lib/services/ai_service.dart`、`lib/services/agent_tool.dart`、`lib/core/prompts.dart`、`assets/knowledge/`

---

## 1. 剔除对象与被误认的邻居

官方知识库是「300+ 条软件安装/配置命令卡 + FTS5 全文检索」，运行时形态有三条：

| 形态 | 位置 | 行为 |
|---|---|---|
| 一次性注入 | `agent_engine.startTask` → `buildKnowledgeInjection` → `_cachedKnowledgeInjection` → `_buildSystemPrompt`；聊天侧 `ai_service` 同函数 | 任务开始按关键词 FTS5 检索，命中段拼进 system prompt |
| 按需检索工具 | `KnowledgeSearchTool`（`knowledge_search`），`AgentToolRegistry` 默认层注册 | 任务中途让模型自己再查 |
| 经验回写 | `AgentNotifier._recordLearningFromTask` → `recordLearning` | 任务 `completed` 后把命令写进 `user_learnings.db` |

**必须保留的邻居**：设置页「内部规范」虽然文件名叫 `knowledge_rule*.dart`，数据是用户自填的组织约定（走内网源、只改 conf.d），与官方库无关，按用户决策保留。

## 2. 唯一的硬耦合：内部规范注入链住在要删的文件里

`buildRulesInjection()` 定义在 `knowledge_service.dart:923`，**只被同文件的 `buildKnowledgeInjection()` 调用**（`:855`）。整体删除会把内部规范注入一起切断，而设置页仍显示「N 条 · 注入 AI 上下文」——变成 UI 声称注入、实际不注入的谎。

处置：`buildRulesInjection` 抽到 `lib/services/rules_injection.dart`（顶层函数 `buildRulesInjection({String? hostId})`，它只依赖 `KnowledgeRulesDao`，无状态、无需实例），两个调用点改接它。

## 3. 逐文件改造矩阵

### 3.1 删除

| 文件 | 理由 |
|---|---|
| `lib/services/knowledge_service.dart` | 检索/注入/经验回写全在此（先迁 §2 的函数） |
| `lib/models/software_guide.dart` | 仅被 knowledge_service 使用（已 grep 确认无其他生产调用方） |
| `assets/knowledge/knowledge.csv`、`knowledge.db` | 数据本体；`pubspec.yaml:86` 的 `- assets/knowledge/` 同步删 |
| `tools/csv_to_knowledge.py` | CSV→SQLite 构建脚本，无消费者 |
| `www/knowledge/knowledge-*.db`（7 个） | 官网下载物，随功能下线 |
| `www/VERSION_MANAGEMENT.md`、`www/VERSION_GUIDE.md` | **实测补充**：原矩阵漏列。两份文档全部章节都在讲知识库 `.db` 的版本上传/下载流程，功能下线后整份失效，且无任何入站引用 |
| `test/knowledge_search_service_test.dart`（13 例）、`test/knowledge_search_tool_test.dart`（16 例） | 契约测试随契约消失。**例外见 §4 V9：其中 1 例是引擎层通用覆盖，须迁移后再删文件** |

`KnowledgeRulesPage`、`KnowledgeRule`、`KnowledgeRulesDao`、`knowledgeRulesProvider`、`knowledge_rules` 表、`/settings/knowledge_rules` 路由、`rule_editor_form.dart` 全部保留。

### 3.2 编辑

| 文件 | 改动 |
|---|---|
| `lib/main.dart` | 删 import 与 `KnowledgeService().init()` 启动调用 |
| `lib/services/agent_engine.dart` | 删 import、`_cachedKnowledgeInjection` 字段、startTask 的整段 try/catch（含两处 R1 代际检查）、`_buildSystemPrompt` 的注入段；`knowledgeSafetyRule` 调用改 `rulesInjection` |
| `lib/services/ai_service.dart` | 删 import、`knowledgeSafetyRule` 追加、`buildKnowledgeInjection` try/catch；改接 `buildRulesInjection` |
| `lib/services/agent_tool.dart` | 删 import、`KnowledgeSearchTool` 类、注册行及其注释。**实测更正**：类体是 `2684–2806`（原写 2673–2812），连前置文档注释与注册行共删 **139 行** |
| `lib/providers/agent_provider.dart` | 删 import、`_recordLearningFromTask` 方法、`shouldRecordLearning` 局部量与 `if (shouldRecordLearning) {...}` 分支。**`onCompleted` 内的 `_flushStreamingToContent` 与 `_persistAssistantCompletion` 必须原样保留**（R2：flush 是 onCompleted 的既有职责，摘错即丢用户正在看的流式内容） |
| `lib/core/prompts.dart` | 删 `knowledgeSafetyRule` 常量与插值；`:281` 工具示例 `knowledge_search` → `local_file_read`。**实测更正**：插值是 **2 处**（HEAD 的 `:408`、`:434`），原写「3 处」把常量定义本身也算进去了；净改动 +1 −15 行 |
| `lib/utils/risk_explainer.dart` | 删 `'knowledge_search': _readOnly` |
| `lib/models/knowledge_rule.dart`、`lib/pages/knowledge_rules_page.dart` | **实测补充**：功能本体一行未动，只改类文档注释——原注释拿「官方知识库（`software_guides` 结构化命令卡）」作对比来解释为什么用自然语言，对比对象已不存在，改成不依赖它的表述（共 +4 −5 行）。原矩阵把这两个文件只列在 §3.1 的「保留」里，漏记了注释改动 |
| `lib/services/agent_host_registry.dart`、`test/widget_test.dart` | **实测补充**：两处陈旧注释仍把知识库列为现存消费者（`供知识库、审计、多机编排…` / `完整启动流程（DbInit/凭据/知识库）`），删掉该词，其余不动。各 1 行 |
| `lib/core/ui_text_index.dart` | 删 `ut_47e5e5365c`、`ut_11e4b8176f`、`ut_00cd1c4300` 的 index + pair 双条目（实测 −6 行，1922 → 1916） |
| `lib/l10n/app_*.arb`（14 个） | 删上述 3 键及其 `@` 元数据。**实测更正**：每文件删 **10 行**（3 个键值行 + `ut_00cd1c4300` 的 7 行 `@placeholders` 块），不是「4 处匹配」那么简单；14 文件共 −146 行、0 新增，删后逐个 `json.load` 校验结构合法 |
| `test/fc_first_e2e_test.dart` | 两处 `knowledge_search` 改指向存活目标。**实测做法**：schema 断言改 `cert_check`（默认层恒注册）；嵌套参数解包用例改用测试内 `_NestedArgsProbeTool`（回显 `query`），因为存活内置工具要么打真实文件系统/网络、要么自行 catch 参数缺失，断言会随环境漂移。新断言不止「没报错」，还要求 `result.output` 含 `docker`，证明解包后的值真到了工具手里 |
| `test/knowledge_rules_test.dart`、`test/tool_contract_test.dart` | **实测补充**：V1 的注入链迁移原本只有 grep 佐证，补 4 例守卫（见 §7） |
| `README.md`、`README_ZH.md` | 徽标（删 `300+ knowledge entries`、`28 built-in tools` → `27`）、`### AI & knowledge` → `### AI` 并删知识库条目、技术栈 FTS5 行删除后把 `├── Dio` 收成末枝 `└──`。**实测**：FTS5 在 lib 下已无任何使用方（grep `fts5\|fts4\|MATCH ?` 零命中），故删行而非改指向 |
| `AGENTS.md` | 删 Key command 行的 `Rebuild knowledge DB`、Architecture 的知识库行、`## Knowledge base workflow` 全节。**实测补充**：R5 两条规则的举例原引用已删除的 `recordLearning()`/知识库污染，规则本身仍成立，故把例子换成现存的持久化副作用；举例用通用占位写法而非虚构函数名，避免暗示存在 `persistCompletion()` 这种 API |
| `.github/workflows/build-release.yml` | 删 `🧠 Knowledge-Driven: 300+…` 新特性条。**实测更正**：中英**两条**都要删（zh `:251`、en `:344`），原矩阵只记了英文条；`:231`/`:324` 的 v1.4.1 历史段落按 §6 保留 |
| `www/index.html` | 删特性卡 11、`knowledgeVersions` JS 数组与渲染函数、下载区 DOM、`knowledge_*`/`f11_*` i18n 键。**实测更正与补充**：重排的是 `code-num` **12–15 → 11–14**（共 4 张卡，原写「12/13」漏了 14/15）；另删 `.feature-icon.knowledge` 与整块 `.version-*` CSS（67 行，13 处选择器全部只服务已删的下载列表）、`renderKnowledgeVersions()` 调用点、以及无 DOM 引用的孤儿截图文案 `ss_kb1..4`；i18n 共删 92 行，净 +3 −245 |
| `www/demo.html` | 删 `settings_knowledge` 设置项与各语言词条。**实测补充**：该项无 `onclick`（纯营销静态行），且 demo 里根本没有内部规范入口，故确认它指官方库而非保留的邻居；删后 Agent 项成为该组末项，按站点既有约定（每组末项不带分隔线）一并去掉它的 `settings-item-divider`；净 −24 行 |

## 4. 二次逻辑校验（对代码复核，非断言）

| # | 检查项 | 结论 |
|---|---|---|
| V1 | 内部规范注入链是否会断 | **会断**，故 §2 迁移为前置必做项。`buildRulesInjection` 生产调用点只有 `knowledge_service.dart:855` 一处 |
| V2 | 内置工具数是否变 | 变。默认层 13 个 `register()` + 7 个本地文件工具 = 20，编排层 8，合计 28 → **27**（另有 2 个联网工具条件注册 = 29）。README 徽标须从 `28 built-in tools` 改 `27`。**实测复核通过**：剔除后 `agent_tool.dart` 非编排非条件注册剩 **12** 处（`2693/2694/2695/2696/2697/2700/2701/2703/2706/2707/2708/2715`）+ `local_file_tools.dart:862–868` 的 7 处 + 编排 8 处 = **27**，与预测一致；MCP 动态注册不计入 |
| V3 | `knowledgeSafetyRule` 删除后「禁止 apt search」是否失效 | **会静默失效**。该约束原挂在知识库规则第 2 条，与知识库无关但寄居其中。本次不新增替代规则（避免超出「剔除」范围），但记录为已知取舍：删除后模型可能自行发起 `apt search` 类探测命令 |
| V4 | 删除 `recordLearning` 是否影响 AGENTS.md R5 的终态门控 | 不影响。**实测更正**：原写「白名单门在 `agent_provider:773` 一带、删链后该门控不再有知识库副作用」不准确——那个 `status == completed` 白名单门（`shouldRecordLearning`）是**随副作用一起整条删掉**的，不是留着一个空门。现存的 `agent_provider:750` `isTerminal` 是「终态清 error」用的三态 whitelist，性质不同、与副作用门控无关。`onCompleted` 的 flush + 持久化职责独立且原样保留（净 +1 −75 行，`fullMessage` 形参因不再使用改名 `_`） |
| V5 | 是否有 `implements`/`extends` 形式的隐藏实现者（R9） | `KnowledgeService` 是单例类、非抽象接口，无 `implements` 实现者；`KnowledgeSearchTool` 仅 `extends AgentTool`，删类即删。测试替身只存在于两份待删测试中 |
| V6 | 3 个 i18n 键是否被生成代码硬引用 | 只有 `agent_tool.dart:2755` 引用 `ut_00cd1c4300`（随工具删除）。`app_localizations*.dart` 是 gitignore 的生成物，删 arb 键后需重跑 gen-l10n |
| V7 | `ui_text_index_test` 的「index size consistent」是否会因漏删而红 | 会。它断言 `kUiTextIndex.length == kUiTextPairToKey.length` 且每条 14 语言齐全，index 与 pair 两处必须同删 |
| V8 | 装机目录残留 | 按用户决策**不处理**：无迁移、不 DROP。已装用户 `%APPDATA%\keiskei\AI Terminal\` 下的 `knowledge.db` / `user_learnings.db` 原地保留，只是不再被读写 |
| V9 | 两份测试全删是否丢真实覆盖 | **会丢 1 例，须迁移**。`knowledge_search_tool_test.dart:321`「query 缺失时引擎把 ToolArgException 转成失败观测」是 `agent_engine.dart:4473` 通用 `catch (e) → '观测: 工具 X 执行异常 — $e'` 分支的**唯一引擎层覆盖**（`tool_contract_test:136` 只测 `requireString` 抛错本身，不到引擎）。且**无法改用存活内置工具**：`SftpFileReadTool:669` 与 `mcp_tool_adapter:331` 都自行 catch 了 `ToolArgException`，`local_file_read` 走 `getString`+策略判定返回 `ToolResult.failure`——删除后没有任何注册工具会把该异常抛到引擎。处置：迁到 `tool_contract_test.dart`，用测试内自定义抛异常工具（`toolsForTesting.register` 公开可用，参照既有 `_NullSchemaTool` 形状）断言同一条观测入历史链路。同组另 2 例可删：只读放行已由 `tool_contract_test:433`（cert_check）覆盖，文本协议解析已由 `react_parse_e2e_test` 覆盖。**实测已迁移并验证非空转**：新例用 `_ThrowingProbeTool`（`args.requireString('path')` 不自行 catch），单跑 `--plain-name` 得 +1 绿；断言 `events.firstWhere(isResult && toolName=='throwing_probe')` 找不到即抛错，且校验第二轮请求历史里含 `观测: 工具 throwing_probe 执行异常` |
| V10 | prompts 里的工具名是否有守卫 | **有**。`tool_contract_test:311`「提示词里出现的每个工具名都已注册」用 `RegExp(r'工具: ([a-z_]+)')` 扫 `buildSystemPromptForTesting` 输出并逐个 `registry.has(name)`。故 `prompts.dart:281` 的 `knowledge_search` 示例必须同批改掉，否则该守卫红 |

### 4.1 顺带发现（与本次剔除无关，未修）

`ut_cf4b2fdeb1` 真值是「已创建本机工作目录: $resolvedCwd」（`local_exec_tool.dart:160` 使用），但 `app_ar/de/es/fr/hi/it.arb`（**6 个语言**，ja/ko/pt/ru/th/vi 是对的）与 `ui_text_index.dart:759`（删 6 行后由 `:762` 位移）里填的是「正在检索知识库: {resolvedCwd}」——批量机翻串行污染。本次只删知识库三个键，此键**保留并单独报告**，不在剔除 PR 里顺手改翻译。

剔除后全仓 grep `knowledge` 时，这条误译是 app 代码里**唯一**残留的知识库字样（`app_it.arb` 用英文 "knowledge base" 故被命中，其余 5 个语言用各自母语所以 grep 不到）。它属于一个存活键的翻译 bug，不是知识库功能本体，按范围纪律不在此 PR 修；**但它意味着 ar/de/es/fr/hi/it 用户在创建本机工作目录时仍会看到「检索知识库」文案**，建议单独开一条翻译修复。**后续**：复核时用户授权修复，已闭环于 §8.2。

### 4.2 V6 / V7 / V10 的实测确认

- **V6**：删键后 `grep` 三个键在 `lib/`+`test/`（排除生成物与 index）**零命中**；`flutter gen-l10n` 退出 0；生成目录里三个键**零残留**。另外顺带查出 `ut_4d2a25adb6`（「参数缺失: query 必填」）在 HEAD 就已无任何 dart 调用方，属**既有孤儿键**、文案不含知识库字样，不在本次范围，未删。
- **V7**：`ui_text_index_test` 的 index/pair 数量一致性与 14 语言齐全断言**绿**（index 与 pair 各删 3 条，1922 → 1916 行）。
- **V10**：`prompts.dart:281` 示例改成 `local_file_read` 后，「提示词里出现的每个工具名都已注册」守卫**绿**，证实该守卫确实会因漏改而红。

## 5. 验收

| 项 | 手段 | 判据 |
|---|---|---|
| 编译 | `flutter analyze --no-pub` | 0 errors；issues 不高于基线 81。**实测：0 errors / 81 issues，持平基线；本次改动与新增的文件零告警** |
| 测试 | `flutter test --no-pub` | 0 failed；预期通过数 1704 − 29（两份文件 13+16 例）+ 1（V9 迁移例）= **1676**。**实测：1676 通过 / 25 跳过 / 0 失败，与预测逐个吻合**；补 §7 的 4 例注入守卫后终值 **1680 通过 / 25 跳过 / 0 失败** |
| 通用覆盖未丢 | `flutter test --no-pub test/tool_contract_test.dart` | V9 迁移例存在且绿；`:311` 提示词-注册表守卫绿；`:433` 只读放行绿。**实测：该文件 30 例全绿（原 29 + 迁移 1），迁移例单跑 `--plain-name` 亦 +1 绿；与 `knowledge_rules_test` 合跑 48 例全绿** |
| 注入链未误伤 | `flutter test --no-pub test/settings_catalog_test.dart` + 真机设置页看「N 条 · 注入 AI 上下文」 | **实测**：`ui_text_index_test` + `settings_catalog_test` + `settings_inline_panel_test` + `knowledge_rules_test` 四文件合跑 **44 例全绿**（补 3 例函数守卫前为 41）；文案产出点 `settings_catalog.dart:167` 与面板 `ref.watch(knowledgeRulesProvider)` 接线未动；注入真实性由 §7.2 的提示词守卫证明（比 grep 强）。**真机设置页视觉复核未做**——该 UI 代码路径本次未改动且已被 widget 测试覆盖，故以测试 + 接线核对代替，不声称已肉眼验收 |
| 包体 | `flutter build windows --release --no-pub` 后 `find build/windows/x64/runner/Release/data/flutter_assets -iname '*knowledge*'` | 无输出。**实测：构建成功产出 exe，该 find 零命中；扩到整个 `build/` 亦零命中** |
| 仓库残留 | 全仓 grep `knowledge`（排除 `.qoder/` worktree 副本、`docs/` 历史记录、本文件） | 仅剩内部规范（`knowledge_rule*` / `knowledge_rules`）命中。**实测：app 代码里另有 2 处非内部规范命中，均为有意保留——§4.1 的 `ut_cf4b2fdeb1` 误译（index + `app_it.arb`）与本次写的迁移说明注释；逐条分类见 §7.4** |

## 6. 不做

- 不删内部规范及其表、页面、DAO、provider、路由、设置项。
- 不给已装用户写 DROP/清理迁移。
- 不改 `docs/` 下历史设计与 `README` 的 1.4.1/1.4.2 历史发布段落（那是当时的真实记录，`knowledge_search` 当时确实发布过）。
- 不动 `www/` 的 git 历史，只删当前文件内容。

## 7. 验收实测记录

### 7.1 门禁

| 项 | 命令 | 实测 |
|---|---|---|
| 静态分析 | `flutter analyze --no-pub` | **0 errors / 81 issues**，与剔除前基线 81 持平。唯一落在被改文件的 info 是 `agent_engine.dart:4988` 的 `curly_braces_in_flow_control_structures`，位于 `_isCancellationError`，属未触碰的既有代码 |
| 全量测试（迁移后） | `flutter test --no-pub` | **1676 通过 / 25 跳过 / 0 失败** —— 与 §5 预测 1704−29+1 完全一致 |
| 全量测试（补守卫后） | `flutter test --no-pub` | **1680 通过 / 25 跳过 / 0 失败** |
| 包体 | `flutter build windows --release --no-pub` | 43.5s 构建成功，产出 `build/windows/x64/runner/Release/ai_terminal.exe`；`find build -iname '*knowledge*'` **零命中**（含 Release/Debug/flutter_assets 全部目录） |
| 构建残留 | 清理前 `find` | 命中 9 项（3 个 `assets/knowledge` 目录各含 csv+db），已删；这些是 gitignore 的可再生产物 |
| 注释补修后复跑 | `flutter analyze --no-pub` + 四文件合跑 | 修完 §7.4 漏报的 2 处陈旧注释后复验：**0 errors / 81 issues**（两个被改文件零告警）；`widget_test` + `tool_contract_test` + `knowledge_rules_test` + `ui_text_index_test` **58 例全绿** |

### 7.2 补的 4 例注入守卫（V1 的实测闭环）

原设计对 V1 只有「grep 到调用点存在」这一条弱佐证。`buildRulesInjection` 迁到新文件后本身无测试，而它的失败模式恰恰是静默的（设置页照旧显示「N 条 · 注入 AI 上下文」），故按 R9 补：

| 位置 | 用例 | 守住什么 |
|---|---|---|
| `knowledge_rules_test.dart` | 无启用条目 → 返回 null（含「只有禁用条目」） | 不往提示词塞空壳抬头 |
| 同上 | 有启用条目 → 含 `【内部规范 · 必须遵守】` + `- [严格] 标题` + 缩进正文 | 函数输出契约 |
| 同上 | 主机作用域条目只对匹配 hostId 注入，其它 hostId 与无 hostId 均 null | 作用域不因迁移放大 |
| `tool_contract_test.dart` | 先断言无规范时提示词**不含**抬头，再 upsert 一条全局规范、断言 `buildSystemPromptForTesting` 输出含抬头与正文，`addTearDown` 清理 | **接线真的通**：不是 grep 到调用点，而是组装后的 system prompt 里真有规范 |

非空转佐证：单跑该例时日志输出 `[RulesInjection] 内部规范注入: 1 条 (hostId=test-host)`，证明走的是真实函数与真实 hostId；正反两向断言意味着接线被切断即红。

`ai_service.sendMessage` 侧的同一处接线是静态方法 + 真实 provider，不宜单测，按 grep + 与引擎侧同构的 3 行模式确认（`ai_service.dart:582`）。

### 7.3 官网实机验证（本地 HTTP + 浏览器）

`file:` 协议被浏览器工具拦截，故用 `python -m http.server 8765` 起本地服务后验证，验完停服务。

| 页面 | 检查 | 实测 |
|---|---|---|
| `index.html` | 特性卡数量与编号 | **14 张，`01…14` 连续无跳号** |
| | 知识库下载区 / 链接 / 渲染函数 | `getElementById('knowledgeVersions')` → null；`a[href*="knowledge"]` → **0**；`typeof renderKnowledgeVersions` → **undefined** |
| | i18n 完整性 | 10 语言 × 118 个 DOM 键，**无任何键引用已删的 `knowledge_*`/`f11_*`/`ss_kb*`**；各语言字典里这三类键 **0 残留** |
| | 逐语言切换 | `setLang` 跑遍 10 语言全部 ok，每次 14 张卡、0 个空标题、正文无 knowledge/知识库字样 |
| | 控制台 | **0 errors / 0 warnings** |
| `demo.html` | 设置项 | **13 项，无知识库行**，正文无 knowledge/知识库字样 |
| | i18n 完整性 | 10 语言 × 137 个 DOM 键，**missingKeys 为空、孤儿 knowledge 键为空** |
| | 逐语言切换 | `applyDemoLang` 跑遍 10 语言全部 ok，13 项、0 空标题 |
| | 控制台 | **0 errors / 0 warnings** |

`index.html` 检出的 `missingKeys`（`hero_demo_*`/`fh*`/`gal*`/`f13`–`f15` 在 ja/de/fr/ru/es/ko/pt/it 缺失）经与 HEAD 对比确认为**既有缺口**（`f13_title:`、`hero_demo_tab:` 在 HEAD 与现在都只有 en/zh 两处），非本次回归，不在范围内。

### 7.4 全仓残留审计（§8 追加修复前的快照）

`git grep -in "knowledge\|知识库" -- ai_terminal/lib ai_terminal/test` 再排除内部规范命名后逐条分类，app 代码里非内部规范的命中只剩 **4 处 / 3 个文件**：

1. `ui_text_index.dart:759` 与 `app_it.arb:3078` 的 `ut_cf4b2fdeb1` 误译 —— §4.1 已记录，明确不修（其余 5 个错译语言用各自母语，grep 不到）
2. `tool_contract_test.dart:358` 本次补的提示词守卫注释 —— 有意保留，说明为何要守组装后的提示词
3. `tool_contract_test.dart:499` 本次写的 V9 迁移说明注释 —— 有意保留，解释为何用测试内工具

**实测更正**：首轮审计漏报了 2 处陈旧注释（`agent_host_registry.dart:12` 把知识库列为 scope→hostId 的消费者、`widget_test.dart:3` 把知识库列为 main() 启动步骤），已在 §3.2 补记并删词；原写「只剩 3 处」也因此不准。

其余命中全部属于：内部规范链路（`knowledge_rule*` / `knowledge_rules` / `KnowledgeRule*`，共 **15 个文件**，含本次补守卫的 `tool_contract_test.dart`）、历史文档（`docs/agent-capability-optimization-plan.md`、`docs/agent-command-pipeline-fix-design.md`、`findings.md:34` 的旧审计条目、`ai_terminal/doc/` 旧需求设计）、README 与 CI 的 v1.4.1/1.4.2 历史发布段落（§6 保留）、以及 `docs/ui-color-style-proposal-v3.html` 里指 Qoder 插件名的 `knowledge-center`（与本功能无关）。

`git grep csv_to_knowledge\|assets/knowledge\|knowledge\.db\|knowledge\.csv\|user_learnings` 在脚本/CI/pubspec 中**零命中**，确认无悬空构建引用。磁盘上 knowledge 命名的文件只剩内部规范 4 个 + 本设计文档。

### 7.5 共享 worktree 纪律

全程用普通 `rm` 而非 `git rm`，未执行任何 `git add`/`stash`/`commit`。`git status` 确认全部改动停留在工作区、索引未被触碰，其它会话的未跟踪文件（`tools/i18n_*`、`_shots/`、`agent_ui_*`）原样保留。本次新增的未跟踪文件只有 `lib/services/rules_injection.dart` 与本设计文档。

## 8. 复核后的追加修复（用户授权，超出原剔除范围）

剔除验收后按「有没有引入新 bug / 流程逻辑 / 前端展示问题」复核：资源、启动、终态、UI 接线均无回归（核对项见 §8.4），但发现 3 项问题，用户选定全修。

### 8.1 安装失败防自救循环规则独立回补

- **问题**：删 `knowledgeSafetyRule` 带走的不止 V3 记录的「禁 apt search」。原第 3 条（无法确定安装方式时拒绝执行）与第 5 条（失败不进入自救循环）与知识库无关；`behaviorBoundaryRule` 第 9 条只覆盖「擅自发现缺软件」，**用户明确要求安装而失败**的路径失去防循环约束，模型可能转源码编译/第三方脚本兜底。
- **处置**：新增 `prompts.installSafetyRule`（2 条，措辞沿用原第 3/5 条、不含知识库字样），接回 **3 条组装路径**：`agent_engine._buildSystemPrompt`（手工拼装、不走模板常量，漏接则 Agent 主路径拿不到）、`buildDefaultSystemPrompt(isWindows: true)`、`defaultSystemPrompt`。
- **守卫**：`tool_contract_test`「安装安全规则在引擎与两个平台模板里都在」，对三条组装产物断言含 `【安装安全规则` / `不进入自救循环` / `该软件暂无已知安装方式`；单跑 `--plain-name` +1 绿。
- **仍不恢复**：原第 2 条「禁 apt search」维持 V3 的已知取舍。

### 8.2 ut_cf4b2fdeb1 六语言误译修复

- ar/de/es/fr/hi/it 的 arb 值与 `ui_text_index.dart` 同键 6 语言改为「已创建本机工作目录」语义；占位符 `{resolvedCwd}` 与 `@placeholders` 元数据不动。
- **校验**：6 个 arb `json.load` 通过且断言不含知识库字样；`flutter gen-l10n` 退出 0；生成物 `app_localizations_it.dart:5308` 为新译文、该文件 `knowledge base` 零命中。§4.1「建议单独开一条翻译修复」就此闭环。

### 8.3 注入日志收敛

注入改为每轮重建后 `debugPrint` 随之每 AI 轮一条；加 `kDebugMode` 门，release 静默、debug/测试保留作接线佐证。

### 8.4 复核确认无回归的核对项

- **启动**：`DbInit.init()`（main 先 await）含同样的 `sqfliteFfiInit()` + `databaseFactory` 赋值与自建目录；知识库用独立 `knowledge/` 子目录，删 init 不连带打死桌面端数据库。
- **startTask**：被删块只带走 await 与代际检查，代际捕获到 `_executeAutomatic` 之间不再有任何 await 间隙，取消窗口变小而非变大。
- **终态**：`onCompleted` 的 flush + 持久化原样；白名单门随其唯一副作用整条删除；全仓仅 2 个赋值点，`fullMessage` 无其他消费者。
- **提示词示例**：`local_file_read` 为 `ToolScope.all`（`agent_tool.dart:2711` 无条件注册），SSH 与本地会话均可见，无作用域错配。
- **悬空引用**：`KnowledgeService/recordLearning/SoftwareGuide/software_guides/user_learnings` 在 lib+test 零命中；脚本/CI 对已删 www 产物零命中。
- **视觉实测**：官网特性区 14 张卡编号 01–14、网格无塌；demo「AI 与智能」组 2 项、末项无分隔线。部分卡片英意混排为 it 语言既有缺口，非本次回归。

### 8.5 追加修复后的门禁与残留复审

| 项 | 命令 | 实测 |
|---|---|---|
| 静态分析 | `flutter analyze --no-pub` | **0 errors / 81 issues**，持平基线。`ui_text_index.dart:6/:962` 两条 `unnecessary_const` 与 `agent_engine.dart:4988` 一条 info 在修复前的输出里同样存在，属既有；`prompts.dart` / `rules_injection.dart` / `tool_contract_test.dart` 零告警 |
| 全量测试 | `flutter test --no-pub` | **1681 通过 / 25 跳过 / 0 失败**（1680 + §8.1 新守卫 1） |
| 新守卫非空转 | `--plain-name "安装安全规则在引擎与两个平台模板里都在"` | +1 绿；断言是三条组装产物上的正向 contains，漏接任一路径即红 |
| 残留复审 | `git grep -in "knowledge\|知识库" -- ai_terminal/lib ai_terminal/test` 排除内部规范命名 | **用户可见文案零命中**。仅剩 5 处解释性注释：`prompts.dart:339`（说明规则来历）、`tool_contract_test.dart:359/392/393/523`（说明守卫与迁移缘由）。§7.4 快照里的 `ut_cf4b2fdeb1` 误译已消失 |
| 包体（最终状态） | `flutter build windows --release --no-pub` 后 `find build -iname '*knowledge*'` | 39.7s 构建成功；`data/app.so` 为修复后新产物（exe 时间戳不变属正常，原生 runner 未改）；find **零命中** |
