# 联网搜索聚合改造设计

> 状态：实现完成（2026-11-04）；目标测试 28 例、全量套件 712 通过/23 跳过
> 目标版本：v1.4
> 参考交互：多后端聚合搜索设置页（状态卡 / 免密钥分组 / 需 Key 分组 / 全局参数 / 立即测试 / 保存-重置）

## 1. 目标与非目标

### 目标

1. 从「单 provider + 顺序降级」改为「多后端并发 fan-out」：一次搜索同时请求多个后端，任一成功即可返回。
2. 结果做 URL 去重与合并：同一 URL 只保留一条，合并标题/摘要，记录命中来源，按「多后端共同命中」优先排序。
3. 设置页重构为截图结构：12 个后端开关、每后端独立 API Key、全局参数（numResults / concurrency / backendTimeoutMs / 出站代理）、立即测试、显式保存与重置。
4. 出站代理仅作用于搜索后端与 `fetch_url`，不改变 AI 模型 API、SSH/PTY 的网络路径。

### 非目标

- 不实现 MCP 客户端。Exa / Parallel 使用官方 HTTP API，和截图里的"MCP 免密钥"不同，UI 文案如实标注「需 Key」。
- 不实现 DeepSeek 网页搜索。DeepSeek 没有公开搜索 API，保留占位行并禁用，文案说明原因。
- 不改变会话级开关语义（终端页底部 toggle 仍可临时覆盖全局开关）。
- 不引入新的第三方依赖；RSS/HTML 继续用正则解析。

## 2. 后端矩阵（12 行）

| # | 后端 | 分组 | 认证 | 接口 | 可用 | 备注 |
|---|---|---|---|---|---|---|
| 1 | Exa | 需 Key | `EXA_API_KEY` | `POST https://api.exa.ai/search` | 是 | 语义搜索，返回 `results[].text` |
| 2 | Parallel | 需 Key | `PARALLEL_API_KEY` | `POST https://api.parallel.ai/v1/search` | 是 | `search_queries` + `results[].excerpts` |
| 3 | Bing RSS | 免密钥 | 无 | `GET https://www.bing.com/search?format=rss` | 是 | 自动跟随 `cn.bing.com` 跳转 |
| 4 | DuckDuckGo | 免密钥 | 无 | `GET https://lite.duckduckgo.com/lite/` | 是 | 国内直连常超时，需代理 |
| 5 | SearXNG | 免密钥 | 可选 Token | `GET {instance}/search?format=json` | 是 | 需自建并开启 `search.formats: [json]` |
| 6 | Brave | 需 Key | `BRAVE_API_KEY` | `GET https://api.search.brave.com/res/v1/web/search` | 是 | 独立索引 |
| 7 | Tavily | 需 Key | `TAVILY_API_KEY` | `POST https://api.tavily.com/search` | 是 | AI 优化摘要 |
| 8 | Serper.dev | 需 Key | `SERPER_API_KEY` | `POST https://google.serper.dev/search` | 是 | Google 结果 |
| 9 | Mojeek | 需 Key | `MOJEEK_API_KEY` | `GET https://api.mojeek.com/search?fmt=json` | 是 | 响应 `response.results[]` |
| 10 | DeepSeek | 占位 | — | — | 否 | 无公开网页搜索 API，开关禁用 |
| 11 | Anthropic | 需 Key | `ANTHROPIC_API_KEY` | `POST https://api.anthropic.com/v1/messages` + `web_search_20250305` | 是 | 读取 `web_search_tool_result` / citations |
| 12 | OpenAI | 需 Key | `OPENAI_API_KEY` | `POST https://api.openai.com/v1/responses` + `web_search` | 是 | 读取 `url_citation` / `action.sources` |

统计口径：

- 「已启用后端」分母 = 12（含 DeepSeek 占位行）。
- 「已配置密钥」分母 = 8（Exa/Parallel/Brave/Tavily/Serper/Mojeek/Anthropic/OpenAI）。SearXNG 的可选 Token 不计入分母。
- 新装默认：总开关关闭，`enabledBackends = [bingRss]`；打开总开关即可用，不依赖 Key。
- DeepSeek 永远不计入已启用数，即使旧配置里出现也会被过滤。

## 3. 配置模型与迁移

### 3.1 持久化

沿用现有两层存储：

- 非敏感配置：`SettingsDao` 的 `webSearchConfig` 键，SQLite 全库加密（`db_init.dart`）。
- API Key：`CredentialsStore`，`hostId = __web_search__`，`type = apiKey_<provider>`；SearXNG 可选 Token 用 `apiKey_searxng`。

新 JSON：

```json
{
  "version": 2,
  "enabled": true,
  "enabledBackends": ["bingRss", "duckduckgo"],
  "numResults": 8,
  "concurrency": 6,
  "backendTimeoutMs": 30000,
  "proxy": "http://127.0.0.1:7890",
  "searxngInstanceUrl": "http://127.0.0.1:8888"
}
```

### 3.2 旧配置迁移（`fromJson` 内完成）

| 旧字段 | 新字段 | 规则 |
|---|---|---|
| `provider` | `enabledBackends` | `bing_html` → `bingRss`；`tavily/brave/duckduckgo/searxng` 同名迁移；`bing`(Azure)/`serpapi` 不再迁移 |
| `timeoutSeconds` | `backendTimeoutMs` | `* 1000`，clamp 3000..120000 |
| `maxResults` | `numResults` | clamp 1..20 |
| `enabled` | `enabled` | 原样 |
| `searxngInstanceUrl` | `searxngInstanceUrl` | 原样 |

旧 `bing`(Azure API) 与 `serpapi` 的 Key 仍留在凭据库，但不再被任何后端引用；这两项旧选择在迁移时回落到免费的 Bing RSS。这是本次布局收敛的已知破坏性变更，文档与提交信息中明示。

### 3.3 Key 解析顺序

1. `CredentialsStore.get(hostId: __web_search__, type: apiKey_<provider>)`
2. 环境变量（`provider.envKeyName`，如 `SERPER_API_KEY`）
3. 空

空 Key 的后端在 fan-out 时直接跳过并记为「未配置」，不发起请求。

### 3.4 枚举

`WebSearchProvider` 新增：`exa, parallel, bingRss, serper, mojeek, deepseek, anthropic, openai`；保留 `tavily, brave, duckduckgo, searxng`。
移除：`bing`(Azure), `bingHtml`, `serpapi`（`fromString` 保留 `bing_html` 映射以兼容旧配置）。
DeepSeek 通过 `isAvailable = false` 暴露给 UI。

## 4. 聚合执行流程

```
WebSearchService.search(query, maxResults?)
  ├─ config = WebSearchConfig.load()
  ├─ backends = config.enabledBackends ∩ available
  ├─ 无启用后端 → 抛 WebSearchTransientError('未启用任何搜索后端')
  ├─ fetchLimit = clamp(ceil(finalLimit * 1.5), finalLimit, 20)
  ├─ Semaphore(config.concurrency)
  └─ Future.wait(backends.map(runOne))         // runOne 内部自行 try/catch，互不中断
       ├─ acquire()
       ├─ timer = Timer(backendTimeoutMs, () => token.cancel('timeout'))
       ├─ token 联动父 CancelToken（任务取消）
       ├─ provider.search(..., timeoutMs, proxy, apiKey)
       ├─ report = {ok, count, elapsedMs, error}
       └─ finally { timer.cancel(); release(); }
  ├─ 全部失败 → 抛聚合错误（列出每个后端原因）
  ├─ 部分成功 → mergeSearchResults(batches, limit)
  └─ 返回 WebSearchResponse(results, reports)
```

- **并发上限**：`concurrency` 默认 6，范围 1..12。
- **每后端超时**：`backendTimeoutMs` 默认 30000，范围 3000..120000；超时后取消该后端请求并记 `timeout`。
- **取消**：父 `CancelToken` 取消 → 所有子请求取消 → 整体抛 `WebSearchCancelledError`，不返回部分结果。
- **代理**：`createSearchDio(proxy: config.proxy)` 统一注入；仅支持 HTTP 代理（HTTPS 目标通过 CONNECT 隧道），不支持 SOCKS5、HTTPS 代理和代理账号密码。代理只用于搜索与 `fetch_url`。

## 5. 合并算法

1. **URL 规范化**（`normalizeSearchUrl`）：
   - 小写 scheme/host，去 `www.`，去默认端口，去 fragment；
   - 删除跟踪参数：`utm_*`、`gclid`、`fbclid`、`msclkid`、`yclid`、`spm`、`ref`、`ref_src`、`source`、`igshid`、`si`；
   - 剩余 query 按 key 排序，去尾 `/`；规范化结果不含 scheme（http/https 视为同一条）。
2. **去重**：以规范化 URL 为 key；第一次出现的原始 URL 作为展示 URL。
3. **合并**：
   - 标题取第一个非空；摘要取最长非空（截断到 400 字符）；
   - `sources` 取所有命中的 provider 并集；
   - `bestRank` 取各后端内最小序号。
4. **排序**：`sources.length` 降序 → `bestRank` 升序 → 首次出现顺序。
5. **截断**：最终结果数 = 工具参数 `max_results`（1..20）优先，否则 `numResults`。

排序理由：多后端同时命中的 URL 更可能是权威结果；来源数相同时，保留各引擎原始排名靠前的。

## 6. 结果与错误语义

- `WebSearchResponse`：
  - `results: List<WebSearchResult>`（已合并）
  - `reports: List<WebSearchBackendReport>`（每个被尝试后端的成功/失败、耗时、错误）
- `WebSearchResult` 新增 `sources` 与 `bestRank`；`toDisplayString` 在来源 >1 时输出「来源: Bing RSS / Brave」。
- 工具输出：首行「聚合 N/M 个后端，去重后 K 条」；部分失败追加「失败: DDG(超时), …」；全部失败返回 failure 并列出原因。
- 错误分类沿用 `WebSearchQuotaError` / `WebSearchTransientError` / `WebSearchCancelledError`：
  - 401/403 → permanent（AI 不应重试同一后端）；
  - 429/超时/网络 → transient；
  - 全部失败且所有失败均为 permanent → 抛 permanent 聚合错误；混合失败（含超时/网络）→ transient，允许 AI 重试。

## 7. 设置页 UI

### 7.1 结构

1. **状态卡**：`已启用后端: X/12`、`已配置密钥: Y/8`、`刷新状态`；下方一行总开关（保留原全局 `enabled` 语义）。
2. **说明**：`聚合网络搜索：12 个后端并发 fan-out、URL 去重合并。开关后端、填 API Key、调参数，保存即生效。`
3. **免密钥（开箱即用）**：Bing RSS / DuckDuckGo / SearXNG，双列。
4. **需要 API Key**：Exa / Parallel / Brave / Tavily / Serper / Mojeek / OpenAI / Anthropic，双列；每行可展开。
5. **Key 输入区**：双列字段，标签 + `获取 Key ↗` + 已配置/未配置徽标 + 环境变量占位符 + 说明「留空表示不修改」。已配置时可「清除」。
6. **私有实例可选 Key**：SearXNG 实例地址、Docker 提示、可选 Token。
7. **全局参数**：numResults / concurrency / backendTimeoutMs / 出站代理（双列）。
8. **立即测试**：输入框 + 搜索按钮；结果先展示每个后端的状态与耗时，再展示合并后的结果。
9. **底部操作栏**：重置状态（回到上次保存）、保存。

### 7.2 交互

- 行状态：复选框（禁用=灰）+ 状态点（绿=可用/已就绪，灰=关闭，橙=启用但缺 Key/实例地址）。
- 总开关关闭时后端仍可编辑；勾选任意后端会自动打开总开关，取消最后一个后端会自动关闭总开关。
- 总开关关闭时状态卡显示「已选后端」，打开后显示「已启用后端」，避免把"已勾选"误称为"已启用"。
- `保存`：校验数字与代理格式 → 写配置 → 写/删 Key → 刷新徽标与统计 → SnackBar。
- `重置状态`：重新读取已保存配置与 Key，清空测试结果。
- `立即测试`：使用当前草稿（未保存的开关、Key、参数）构造临时配置与 Key 覆盖，不落盘。
- 窄屏：双列降为单列；底部操作栏 `SafeArea` 包底，避免被系统手势区遮挡。

> 实现记录：底部操作栏最初使用 `Center > ConstrainedBox`，在 `bottomNavigationBar`
> 的松约束下 `Center` 撑满全高，正文 `ListView` 被压成 0 高度（release 表现为空白页）。
> 已改为直接右对齐的 `Row`；`web_search_settings_page_test.dart` 的 360px 用例同时兜住
> 窄屏溢出。

## 8. 安全

- Key 只经 `CredentialsStore`（系统 Keychain，失败时 AES 加密 SQLite），不写入 `SettingsDao`、不写日志。
- 环境变量兜底只读，不回显。
- 代理只接受 `http://host:port`（界面拒绝 `user:pass`、SOCKS5 与 HTTPS 代理），保存在全库加密的 `SettingsDao`，不打印。
- 测试结果中的 URL 照常展示；不发往第三方。

## 9. 代码影响面（核对结果）

| 符号 | 现状 | 改动 |
|---|---|---|
| `WebSearchConfig` | 单 provider + maxResults + timeoutSeconds | 扩展字段与迁移；保留 `enabled` |
| `WebSearchService.search` | `Future<List<WebSearchResult>>`，顺序 fallback | 改为 `Future<WebSearchResponse>`；新增 fan-out/merge |
| `WebSearchService.currentProvider` | 已声明但无调用方 | 删除 |
| `WebSearchTool.execute` | 只消费 `List` | 消费 `WebSearchResponse`，输出聚合摘要 |
| `FetchUrlTool` | 自建 Dio，读 `timeoutSeconds` | 改用 `createSearchDio` + `backendTimeoutMs`，应用代理 |
| `AgentEngine._syncWebToolsRegistration` | 只看 `WebSearchConfig.enabled` | 改为 `enabled && 有可用后端`（通过 `WebSearchService.isEnabled`） |
| `web_search_settings_page.dart` | 单 provider 下拉 + 自动保存 | 全量重写为 12 后端聚合设置页 |
| `settings_page.dart` / `router.dart` | 入口与路由已存在 | 不改 |

核对命令：`grep -rn "WebSearchConfig\|WebSearchResult\|WebSearchService" ai_terminal/lib` 确认 `search()` 只有 `web_tools.dart` 一个调用方，`WebSearchResult` 只在服务/工具内使用，页面仅用 `WebSearchConfig`。

## 10. 验收计划

- 单元/组件测试（已通过，28 例）：
  - `web_search_merge_test.dart`：`normalizeSearchUrl` 与 `mergeSearchResults`；
  - `web_search_config_test.dart`：旧配置迁移、空后端列表、非法值过滤、clamp、元数据；
  - `web_search_service_test.dart`：并发 fan-out、去重合并、部分失败、全部失败、超时、并发上限、缺 Key 不发请求；
  - `web_search_settings_page_test.dart`：关键区域渲染、立即测试、勾选后端自动开总开关、保存提示、360px 窄屏不溢出。
- 静态检查：`dart analyze` 对改动文件与测试返回 `No issues found`。
- 真实网络：Bing RSS 搜索 `flutter web search` 在测试进程中返回 8 条、耗时约 356ms；
  应用内的「立即测试」未完成（验证期间窗口被另一会话重建/重启），该路径由组件测试用假后端覆盖。
- 设备验证：Windows release 预览构建截图确认状态卡、免密钥双列、Key 输入、SearXNG、
  全局参数、立即测试与底部操作栏正常（预览构建使用临时初始路由；验证后已恢复）。
  随后对状态文案、勾选后端自动开总开关、代理提示做了小改动，均由组件测试覆盖；
  因验证期间另一会话重建并重启了应用，未再次截图。
- 全量测试：`flutter test --no-pub` → 712 passed / 23 skipped。
- 共享工作区注意：验证期间另一会话重建并重启了应用，预览构建被覆盖；后续以当前源码
  重新构建截图。

## 11. 已知取舍

1. Exa/Parallel 不是 MCP 免密钥；UI 如实标注需 Key。若后续接入 MCP 客户端，再补独立的 MCP 传输层。
2. DeepSeek 占位但不可用；保留它是为了与参考布局一致，避免用户误以为漏配。
3. Azure Bing API 与 SerpAPI 从 UI 移除；旧 Key 保留在凭据库但不再使用。
4. LLM 型后端（OpenAI/Anthropic）返回的是「模型引用来源」而非完整结果列表，条数通常少于传统搜索引擎；默认模型 `gpt-4.1-mini` / `claude-sonnet-4-5`，不在此次 UI 中暴露。
