# AI 端点与多模型配置（无默认模型）— 设计、迁移与验收

参考图：用户提供的 Qoder 模型设置（端点卡片 + 模型目录 + 每模型推理档位）与 Agent 输入框底部胶囊（模型 + 思考档位）。目标是把当前「一行一个模型、每个模型各带一份 Base URL/API Key、必须设默认」的结构，改成「一个端点下挂多个模型，无默认模型，模型与思考档位在 Agent 底部选择」。

本文所有「现状」均对照当前代码（符号名定位），不是推测。行号会漂移，实施与复查以符号名为准。

## 1. 目标与非目标

### 1.1 目标

1. **端点（Endpoint）**：一个 Base URL + 一个 API Key + 一个协议，下面挂多个模型。设置页里一个端点是一张卡片。
2. **模型目录**：每个端点拥有自己的模型列表；模型可单独配置显示名称、模型 ID、上下文窗口、最大输出 token、推理档位、Function Calling、温度、备用模型。
3. **没有默认模型**：删除 `isDefault` 与「设为默认」；启动/首次使用时只存在「当前选择」，不是配置里的默认项。若没有任何选择，运行时选第一个可用模型，并把选择写回，不改配置语义。
4. **Agent 底部选择**：输入框底部显示模型胶囊（`模型名 + 档位`），点开可按端点分组选模型、选该模型的思考档位。选择立即重建 Agent 引擎（沿用现有 `_switchModel` 语义），并持久化。
5. **推理档位**：每个模型可开关「推理等级」，档位形如 `off/low/medium/high`，每档有一个「API 参数值」；选中非空值时请求体带 `reasoning_effort: <值>`，空值表示不发送该字段（off）。
6. **旧数据不丢**：现有 `ai_models` 行迁移成「端点 + 模型」；API Key 从按模型 id 的安全存储复制到按端点 id；旧的 fallback、温度、上下文、Function Calling 全部保留。

### 1.2 非目标

- **不做图片输入**：当前 AI 输入链路没有图片/附件语义（`AIPromptInput` 只收文本），设置里的「输入类型：文本/图片」只是能力声明，App 无法兑现。先不做，避免假开关；等图片输入链路落地后再加。
- **不做协议扩展**：当前只有 OpenAI Chat Completions（`OpenAIProvider`）与文心（`ErnieProvider`）两条真实链路。协议下拉只列这两项，不编造 Responses API。
- **不引入 tier/档位标签体系**：参考图的 `Default/High` 只是模型选择显示，不新增配置字段。思考档位是模型自己的档位列表。
- **不改 Agent 权限/只读语义**：本次不把「工作区内修改/完全权限」搬进输入框，只处理模型与思考档位。

## 2. 数据模型

### 2.1 新模型（`lib/models/ai_endpoint.dart`）

```dart
class AIEndpoint {
  final String id;
  final String providerId;   // 预设 id（agnes/deepseek/...）或 'custom'
  final String name;         // 显示名称
  final String baseUrl;
  final String protocol;     // 'openai' | 'ernie'
  final String apiKey;       // 仅内存，落盘走 CredentialsStore(endpoint.id)
  final List<AIEndpointModel> models;
  final int createdAt;
}

class AIEndpointModel {
  final String id;              // 内部 id（UUID），选择与 fallback 用它
  final String name;            // 显示名称
  final String modelName;       // 发给 API 的模型 ID
  final int contextWindow;      // 0 = 未知，运行时回退 32768
  final int maxTokens;          // 0 = 未知，运行时回退 4096
  final double temperature;
  final bool supportsFunctionCalling;
  final String? fallbackModelId; // 指向任意模型的 id，保留旧能力
  final bool reasoningEnabled;
  final List<AIReasoningTier> reasoningTiers;
}

class AIReasoningTier {
  final String level;    // off/low/medium/high 或用户自定义
  final String apiValue; // '' = 不发送参数
}
```

- 模型 `id` 与 `modelName` 分离：同一端点可以同时配置 `agnes` 与 `agnes-3.0-flash`，显示名可改，API 调用始终用 `modelName`。
- 推理档位的 `level` 是稳定标识（用于持久化选择）；显示文案：`off/low/medium/high` 走本地化映射，其他原样显示。
- 默认档位集合固定为 `off(''), low('low'), medium('medium'), high('high')`，与参考图一致。
- 默认 token 预算：上下文窗口未知时按 **262144（256K）**，最大输出未填写时按 **32768（32K）**；模型里显式保存的值优先（旧迁移数据里的 4096 不会被静默改写）。

### 2.2 运行时配置 `AIModelConfig`

保留 `AIModelConfig` 作为「端点 + 模型 + 当前档位」拍平后的运行时快照，避免改 `AgentEngine`/`AIProvider`/测试的签名：

新增/调整字段：

| 字段 | 用途 |
|---|---|
| `endpointId` / `endpointName` | 选择器分组、诊断 |
| `reasoningEffort` | 非空时写进请求体 `reasoning_effort` |
| `reasoningLabel` | 胶囊显示当前档位（`High`/`Off`/自定义） |
| 删除 `isDefault` | 「没有默认模型」 |

`AIModelConfig.fromEndpoint(endpoint, model, tier)` 负责拍平：`id = model.id`、`provider = endpoint.protocol`、`apiKey/baseUrl` 来自端点、`temperature/maxTokens/contextWindow/supportsFunctionCalling/fallbackModelId` 来自模型。

### 2.3 档位解析规则

`resolveReasoningTier(model, savedLevel)`：

1. 模型未启用推理或档位为空 → 返回 null（胶囊不显示档位，请求不带参数）。
2. 有已保存档位且匹配 → 用保存的。
3. 否则优先 `level == 'medium'`。
4. 否则第一个 `apiValue` 非空的档位。
5. 否则第一档。

选择档位后按模型持久化（同一模型在 A/B 端点间不共享），存 `settings.aiSelectedReasoningTiers = {"<modelId>":"high"}`。

## 3. 持久化与迁移

### 3.1 表结构（schema v6）

```sql
CREATE TABLE ai_endpoints (
  id TEXT PRIMARY KEY,
  providerId TEXT NOT NULL,
  name TEXT NOT NULL,
  baseUrl TEXT NOT NULL,
  protocol TEXT NOT NULL DEFAULT 'openai',
  models TEXT NOT NULL DEFAULT '[]',
  createdAt INTEGER NOT NULL
)
```

- `models` 存模型数组 JSON（端点整体保存/读取；模型数量小，无需关系表）。
- API Key **不进 DB**，仍走 `CredentialsStore`（R7），key 为 `cred:<endpointId>:apiKey`。
- 旧 `ai_models` 表保留不删，作为回滚/审计数据；新代码不再读写它。

### 3.2 迁移（`AIEndpointsMigration.migrateIfNeeded()`）

执行时机：`main` 中 `CredentialsStore.init()` 之后、`DbInit.reloadCaches()` 之后（迁移要读旧 DAO 缓存与安全存储）。

步骤：

1. 若 `settings.aiEndpointsMigrationV1 == 'done'` → 直接返回。
2. 读取 `AIModelsDao.getAll()`。
3. 按 `provider|baseUrl` 分组（同一端点下多模型）。
   - `providerId`：旧 `provider` 命中 `ProviderConfigService.getProviderById` 则沿用，否则 `custom`。
   - `protocol`：旧 `provider == 'ernie'` → `ernie`，其余 → `openai`（Qwen 本来就委托 OpenAIProvider）。
   - 端点显示名：预设名；重名追加 ` (2)`。
   - 模型：保留旧 `id/name/modelName/temperature/maxTokens/contextWindow/supportsFunctionCalling/fallbackModelId`；`reasoningEnabled=false`，档位为空。
4. API Key：对每个旧模型读 `CredentialsStore.get(hostId: model.id, type: 'apiKey')`，组内第一个非空值保存到 `CredentialsStore.save(hostId: endpoint.id, type: 'apiKey')`。旧 key 不删除（迁移失败可回滚）。
5. 初始选择：旧的 `isDefault` 模型优先，否则第一个模型；仅在 `settings.aiSelectedModelId` 为空时写入。
6. 写 `settings.aiEndpointsMigrationV1 = 'done'`，`AIEndpointsDao.loadCache()`。

幂等性：每步按「同 providerId+baseUrl 的端点已存在则合并模型、不重复建端点」处理；中途失败重跑不会产生重复端点。

## 4. 设置页（`ai_models_page.dart` 重写）

页面结构：

- AppBar：`AI 模型配置`。
- 端点卡片列表：图标/颜色取预设，标题为端点显示名，副标题 `预设名 · N 个模型 · Base URL`；右侧编辑/删除。
- FAB/空态按钮：`添加端点`。

端点编辑对话框：

1. `AI 服务商` 预设下拉（含「自定义」）。选择预设时回填显示名/Base URL/默认模型（仅当对应字段为空）。
2. `API 密钥`：新端点可空（本地 Ollama）；编辑时 placeholder `留空使用已保存凭据`，留空不覆盖已保存 key。
3. `自定义设置`（ExpansionTile，默认展开）：显示名称、API 地址、API 协议（OpenAI Chat Completions / 百度文心 ERNIE）。
4. `模型目录`：
   - 操作行：`恢复默认模型`（仅预设且预设带模型时可用）、`获取可用模型`、`添加模型`。
   - 模型行：显示名称 + 模型 ID + `上下文/最大输出/思考档位` 摘要；编辑、删除。
   - 恢复默认：确认后用预设 `ProviderInfo.models` 重建目录（模型 ID 相同的行保留用户参数）。
   - 获取可用模型：`GET {baseUrl}/models`，Bearer key；解析 `data[].id`（兼容字符串数组）；多选后只补缺失模型。
5. 保存：校验端点名称/Base URL/至少一个模型；模型 ID 与显示名称非空；推理档位不重复。

模型编辑对话框：

- 基础：显示名称、模型 ID。
- 参数：上下文窗口、最大输出 token（`0 = 未知，运行时回退`）。
- 推理等级：开关；开启后档位行（档位 + API 参数值 + 删除）+ `添加档位`。空 API 值 = 不发送。
- 高级（折叠）：Function Calling、温度、备用模型（候选为所有端点模型，排除自身）。

## 5. Agent 底部选择

### 5.1 布局

`AIPromptInput` 改为「输入框 + 底部工具行」的一体容器（仅 terminal_page 使用，无其他调用方）：

```
┌─────────────────────────────────────────────┐
│ 发消息或创建任务…                            │
│ 123/50000                    [模型胶囊] [编排] [发送] │
└─────────────────────────────────────────────┘
```

- 模型胶囊文案：`模型显示名` + 若启用推理则 ` 档位`（如 `Deepseek-V4.1-Flash High`）；超长省略，最大宽度 180。
- 无模型时胶囊显示 `配置模型`（警示色），点击跳 `/settings/ai`。

### 5.2 选择弹层

用 `MenuAnchor` 在胶囊上方展开自定义面板：

- 模型列表按端点分组；当前模型打勾。
- 点击模型：切换模型（保留该模型上次档位；无记录按 §2.3 解析），面板**保持打开**。
- 当前模型启用推理时，下方显示 `思考程度` 档位 chips（Off/Low/Medium/High/自定义），点击立即生效。
- 底部 `管理模型…` 跳设置页；`完成` 关闭面板。

选择即调用终端页 `_switchModel` / `_applyReasoningTier`：更新 `_currentModelConfig`、持久化、`agentProvider.init(...)` 重建引擎（现有语义；`init` 会安全取消旧任务并恢复历史）。

### 5.3 当前选择的归属

- 每个 host 的 Agent 引擎仍按 host 保存自己的 `AIModelConfig`（`AgentHostRegistry.setModelConfig`，R3）。
- 输入框胶囊显示**当前活跃 host 实际使用的**配置：`AgentNotifier` 暴露 `modelConfig` getter，`terminal_page` 优先读它，避免切 tab 后显示全局值而引擎用另一个。
- `settings.aiSelectedModelId` 是「新 host / 重启后的初始选择」，不是配置里的默认模型。

## 6. 推理参数映射

`OpenAIProvider` 请求体：

```dart
{
  'model': config.modelName,
  'messages': messages,
  'stream': true,
  'temperature': config.temperature,
  'max_tokens': config.maxTokens,
  if (config.reasoningEffort != null && config.reasoningEffort!.trim().isNotEmpty)
    'reasoning_effort': config.reasoningEffort!.trim(),
}
```

- 键名固定 `reasoning_effort`（OpenAI 兼容网关的通用字段；参考图里「API 参数值」就是它的值）。
- `off` 档的 API 值为空 → 不发送；想显式关闭思考的网关，把 off 档值填成它要求的值（如 `none`）即可，配置层不写死。
- 文心（`ErnieProvider`）走自己的 body，不注入该字段。
- 提取 `OpenAIProvider.buildChatRequestBody(...)` 纯函数供单测。

## 7. 代码影响面

| 位置 | 动作 |
|---|---|
| `models/ai_endpoint.dart` | 新增端点/模型/档位模型与 JSON、`toRuntimeConfig` |
| `models/ai_model_config.dart` | 增 `endpointId/endpointName/reasoningEffort/reasoningLabel`；删 `isDefault`；增工厂 |
| `core/db_init.dart` | schema v6 + `ai_endpoints` 建表/升级；reloadCaches 加 DAO |
| `core/router.dart` | GoRouter 注册 `observers: [appRouteObserver]` |
| `core/route_observer.dart` | 新增全局 RouteObserver，驱动设置页返回后的配置刷新 |
| `services/daos.dart` | 新增 `AIEndpointsDao`；`AIModelsDao` 保留但不再被新代码使用 |
| `services/ai_endpoint_migration.dart` | 新迁移 |
| `services/ai_model_selection_service.dart` | 选择持久化、档位解析、解析当前配置 |
| `providers/app_providers.dart` | `aiModelsProvider` → `aiEndpointsProvider`（含 key 注入、CRUD） |
| `pages/ai_models_page.dart` | 重写为端点 + 模型目录 |
| `widgets/ai_prompt_input.dart` | 输入框底部工具行 + `footer` 插槽 |
| `pages/terminal_page.dart` | 底部模型/档位胶囊、选择弹层、初始化与 `/model` 改用端点数据、配置变更同步 |
| `providers/agent_provider.dart` | 暴露 `modelConfig` getter |
| `providers/chat_provider.dart` | `_getDefaultModel` → 选择服务解析 |
| `services/ai_service.dart` | 请求体加 `reasoning_effort`；提取纯函数 |
| `l10n/app_*.arb` | 新文案；zh 中文、en 英文、其余 locale 用英文兜底 |
| `test/*` | 新增端点序列化/迁移分组/档位解析/请求体测试 |

## 8. 分期与验收

| 期 | 内容 | 验收 |
|---|---|---|
| P0 | 数据层 + 迁移 + 选择服务 + 请求体推理参数 | 单测：JSON 往返、旧数据分组、档位解析、`reasoning_effort` 有无；启动迁移幂等 |
| P1 | 设置页重写（端点/模型目录/恢复默认/获取可用） | `flutter analyze` 无新增 error；页面可增删改端点与模型 |
| P2 | 底部模型+档位胶囊、弹层、终端页与 `/model`/ChatProvider 接入 | 单测：档位选择解析；真机：切模型/档位后下一次请求用新值 |
| P3 | l10n 全 locale、全量测试、analyze、真机复拍 | `flutter test` 基线不降；设置页与底部栏截图确认无溢出、无重复信息 |

## 9. 二次逻辑验证（对照代码）

| # | 本文假设 | 查证结果 |
|---|---|---|
| V1 | 模型配置只被 `ai_models_page`/`terminal_page`/`chat_provider`/`app_providers`/`agent_engine`/`ai_service` 使用 | **成立**（GitNexus impact：51 个受影响符号，直接 12 个；`AIModelConfig` 仅这些路径消费）。删 `isDefault` 不影响测试构造。 |
| V2 | 旧数据每个模型都有一份 key，可按端点合并 | **成立但需容错**。`AIModelsNotifier._injectApiKeys` 确认 key 按模型 id 存 `CredentialsStore`；同组内若 key 不同，迁移取第一个非空并在文档记录（罕见）。 |
| V3 | 新增表只改 `_schemaVersion` 即可 | **成立**。`DbInit._onCreate` 建全表、`_onUpgrade` 按版本 ALTER；加密库在 `reloadCaches()` 前已打开。迁移服务需在 `CredentialsStore.init()` 之后调用。 |
| V4 | `init()` 可安全用于切模型/档位 | **成立**。`AgentNotifier.init` 会先 flush 流式 → 清回调 → cancelTask → disposeTools，再建新引擎并恢复历史；R2/R3 语义保持。 |
| V5 | 底部模型选择器可以只改文案 | **不成立**。当前模型选择在工具栏 Row 的末尾（`_buildModelSelector`），不在输入框内；要像参考图必须改 `AIPromptInput` 结构。本文按 §5.1 重排；`AIPromptInput` 只有 terminal_page 一个调用方，改造面可控。 |
| V6 | 档位可以直接复用模型选择器 | **不成立**。`PopupMenuButton` 单选即关闭，无法先选模型再选档位。改用 `MenuAnchor` + 自定义面板（模型列表与档位 chips 同面板）。 |
| V7 | 切 tab 后胶囊显示全局选择即可 | **不成立**。`AgentHostRegistry` 按 host 保存 modelConfig，`terminal_page._currentModelConfig` 不会随 `switchTab` 更新；显示全局值会与引擎实际使用的模型不一致。§5.3 改为读 `AgentNotifier.modelConfig`。 |
| V8 | 设置页改完模型，终端页立即生效 | **不成立**。终端页只在 `_initAgent`/`_switchModel` 读取配置；设置页保存后需要刷新。实现时监听 `aiEndpointsProvider`：非运行态下重建；运行态延后到任务结束，避免配置保存顺手杀掉任务。 |
| V9 | 可以照搬参考图的「输入类型」 | **不成立**。运行时没有图片/附件链路，勾选无法兑现。按 §1.2 不做。 |
| V10 | 旧 `fallbackModelId` 迁移后仍可用 | **成立**。模型 id 原样保留，`AgentNotifier._loadFallbackFor` 改为从新端点数据查找即可；备用模型关系不因分组丢失。 |

## 10. 交付记录

### 10.1 已完成（2026-11-04）

| 期 | 内容 | 结果 |
|---|---|---|
| P0 | 端点/模型/档位模型、`ai_endpoints` 表（schema v6）、旧 `ai_models` 迁移、API Key 复制、选择持久化与解析、`reasoning_effort` 请求参数 | 完成 |
| P1 | 设置页重写：端点卡片、端点编辑、模型目录、模型编辑、恢复默认模型、获取可用模型、删除确认 | 完成 |
| P2 | 输入框底部模型/档位胶囊、`MenuAnchor` 选择面板、`/model` 与 ChatProvider 接入、当前 host 配置显示 | 完成 |
| P3 | 配置页保存后返回自动刷新（路由观察者 + `didPopNext`）、l10n 全 locale、测试与真机复拍 | 完成（见 10.3 未验证项） |

### 10.2 实施中修正的设计假设

1. **V5 成立**：`AIPromptInput` 改为「输入区 + 底部工具行」一体容器，模型胶囊放在发送按钮左侧；只有 terminal_page 一个调用方。
2. **V7 成立**：胶囊读取 `AgentNotifier.modelConfig`，切 tab 后显示当前 host 实际配置。
3. **V8 的修法升级**：仅监听 `aiEndpointsProvider` 不够——设置页在子路由时终端页不会及时重建。新增 `core/route_observer.dart`，`GoRouter` 注册 `observers`，`TerminalPage` 实现 `RouteAware.didPopNext`：从设置页返回时强制 `loadEndpoints()` + `_syncModelWithEndpoints()`。
4. **默认选择**：没有配置默认模型，但运行时必须有当前值。首次/选择失效时取第一个模型并写回 `aiSelectedModelId`；这是「当前选择」，不是配置里的默认项。
5. **推理默认档**：启用推理且未保存档位时优先 `medium`；`off` 档 API 值为空表示不发送参数。键名固定 `reasoning_effort`。
6. **未做输入类型**：理由见 §1.2，避免无法兑现的假开关。
7. **FAB**：主题把所有 FAB 设为 `CircleBorder`，`FloatingActionButton.extended` 的文字会被裁成圆形；改为圆形 `+` 按钮 + tooltip。
8. **默认 token 预算**：新增常量 `kDefaultContextWindow = 262144`（256K）与 `kDefaultMaxOutputTokens = 32768`（32K）。新模型对话框预填这两个值；`contextWindow=0` 的运行时回退从 32768 改为 262144；`maxTokens=0/未填` 的回退从 4096 改为 32768。已有模型显式保存的 4096 保留。

### 10.3 测试与真机证据

- `flutter analyze --no-pub`：**32 issues / 0 errors**（快照；其中包含工作区其他会话的既有 lint，本次新增文件无 error/warning）。
- `flutter test --no-pub`：**713 通过 / 23 跳过 / 0 失败**（快照；跳过为环境门控 E2E，数字包含工作区其他会话的测试）。
- 新增测试：
  - `test/ai_endpoint_test.dart`：端点/模型/档位 JSON 往返、档位解析规则、运行时配置拍平、`maxTokens=0`/`contextWindow=0` 回退。
  - `test/openai_reasoning_request_test.dart`：`reasoning_effort` 有值/空值/空白值、tools、基础字段。
  - `test/ai_endpoint_migration_test.dart`：旧模型按 `provider + Base URL` 分组。
  - `test/ai_model_selection_test.dart`：按端点拍平、保存档位优先、默认 medium、未启用推理不发送、找不到模型返回 null。
  - `test/model_picker_panel_test.dart`：面板分组、模型选择回调、档位 chips、未启用推理提示。

真机（Windows Release，`flutter build windows --no-pub`）已确认：

| 场景 | 结果 |
|---|---|
| 旧配置迁移 | 旧 `ai-gateway` 模型迁移为端点「OpenAI 1」+ 模型 `ai-gateway / agnes`，上下文 262144、最大 4096 保留 |
| 设置页 | 端点卡片、编辑对话框、API 密钥占位、显示名称/API 地址/协议、模型目录、恢复默认/获取可用/添加模型均可见；FAB 裁字已修 |
| 模型编辑 | 显示名称/模型 ID/上下文窗口/最大输出；推理等级开关后出现 off/low/medium/high 四档与「留空表示不发送该参数」 |
| 底部选择 | 胶囊显示 `ai-gateway Medium`；点开面板按端点分组，档位 chips 选中 Medium；点 High 后胶囊立即变 `ai-gateway High` |
| 返回同步（端点） | 设置页把端点显示名改为「OpenAI Gateway」并保存，返回终端后模型面板分组标题立即更新，无需重启 |
| 返回同步（模型参数） | 设置里关闭推理并保存，返回终端后胶囊立即从 `ai-gateway High` 变为 `ai-gateway`，面板显示「该模型未启用思考档位」 |
| 持久化 | 开启推理并保存后重启应用，胶囊显示 `ai-gateway Medium`，说明档位与模型配置已落库 |

### 10.4 仍未验证 / 已知限制

1. **推理参数键名**固定 `reasoning_effort`。若某个网关要求 `thinking` / `enable_thinking` 等不同字段，当前配置无法改键名；需要时再加「参数名」字段。
2. **API Key 合并**：旧数据同 `provider + Base URL` 但不同 key 的极端情况，迁移取第一个非空 key；未做多 key 拆分。
3. **输入图片**未支持（§1.2）。
4. **工作区并发**：`web_search_*`/`router.dart` 等文件有其他会话的未提交改动；`router.dart` 曾出现 `initialLocation: '/settings/web_search'` 的临时调试值，本次已恢复为 `'/'` 以保持启动页与 `widget_test` 正确。若其他会话还需要该调试值，请自行改回。
5. **真机当前状态**：验证过程中曾把端点改名为「OpenAI Gateway」、开启过推理档位；结束前已把端点名恢复为「OpenAI」，推理档位关闭（保持迁移后的原始状态），并把迁移出来的模型最大输出从 4096 更新为 32768，与新的 32K 默认值对齐。

