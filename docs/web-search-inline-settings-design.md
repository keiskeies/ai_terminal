# 联网搜索设置补齐设计（内联面板）

## 0. 背景

设置 →「联网搜索」在抽屉化重构后被重写成一个极简内联面板，只留下总开关、后端胶囊、「+ 添加」和一行只读的「返回条数」。功能完整的 `lib/pages/web_search_settings_page.dart`（1380 行）从此没有任何生产引用——`/settings/web_search` 走 `SettingsPage(initialGroup: 'web_search')` → `SettingsInlinePanel`（`lib/core/router.dart:83-86`），全项目只剩 `test/web_search_settings_page_test.dart` 还 import 它。

砍掉的字段不是锦上添花，其中一个是实打实的功能性故障：

| 缺口 | 现状 | 后果 |
|---|---|---|
| SearXNG 实例 URL | 无处填 | **SearXNG 加了就必挂** |
| SearXNG 可选 Token | 无处填 | 带鉴权的自建实例连不上 |
| 出站代理 proxy | 无处填 | DuckDuckGo 标着「国内需代理」却无法配代理 |
| numResults | 只读展示 | 用户改不了 |
| concurrency / backendTimeoutMs | 无入口 | 只能吃默认 6 / 30000ms |
| 立即测试 | 无入口 | 配错要回到对话里跑一次搜索才发现 |

SearXNG 这条是 bug，不是简化：`_pickWebBackend` 只在 `requiresApiKey` 时展开输入表单（`settings_inline_panel.dart:1060-1070`），而 SearXNG 免 Key（`web_search_config.dart:75-92`），所以它**直接启用、什么都不问**；胶囊的金锁同样只看 `requiresApiKey`（`_WebBackendChip`，同文件 1473），UI 看起来一切正常。实际请求层 `web_search_backends.dart:345-352` 要求实例 URL，调度层 `web_search_service.dart:86-97` 提前拦成「未配置实例地址」，静默失败、永久错误、不重试。

## 1. 目标与非目标

### 目标

- G1：加完 SearXNG 必然被引导去填实例地址；未填时胶囊上有可见警示，列表副标题也说明「差什么」。
- G2：代理、返回条数、并发、超时四项可在设置里改，校验口径与旧页一致。
- G3：把旧页的「立即测试」搬进来，配置能就地验证。
- G4：删掉孤儿页面 `web_search_settings_page.dart` 与其测试，能力全部收敛进内联面板，不留两套实现。

### 非目标

- 不改后端 HTTP 实现、不动 12 个 provider 的请求逻辑与合并算法（`web_search_backends.dart` / `web_search_merge.dart` 零改动）。
- 不新增后端。
- 不改 `WebSearchConfig` 字段与 JSON：`proxy` / `searxngInstanceUrl` / `concurrency` / `backendTimeoutMs` 早就持久化了（`web_search_config.dart:257-271`，`version: 2`），本次**只补 UI**，无需数据迁移。
- 不支持 SOCKS5 与带账号密码的代理（沿用旧页限制，见 §5.3）。
- 会话级临时开关仍在终端底部栏，不动。

## 2. 交互设计

全部在现有抽屉载体里完成，遵守 `InlineSheet` 的既有约定：**不用 Dialog**，「本组内容换一屏」，顶部一个「返回」。三条新增入口都沿这条线。

### 2.1 SearXNG：加了就问地址

`_pickWebBackend` 的门槛从「要不要 Key」扩成「还缺不缺东西」：

```
选 SearXNG → 实例地址为空 → 展开 _SearxngForm（不启用）
           → 已有地址     → 直接启用（同现在）
选需 Key 的后端 → 无 Key → 展开 _WebKeyForm（同现在）
```

`_SearxngForm` 字段：实例地址（必填，hint `http://127.0.0.1:8888`）+ Token（可选、掩码）+ 部署文档链接 + 一段如实说明（公共实例通常关掉 `format=json`，必须自建并在 `settings.yml` 启用 `search.formats: [html, json]`）。文案与校验直接沿用旧页 `_buildSearxngPanel`（646-701）。保存 → 写 `searxngInstanceUrl` + `saveApiKey(searxng, token)` → 启用该后端。

**点已启用的 SearXNG 胶囊 = 编辑而不是删除。** 其余胶囊仍是「点一下移除」；只有 `requiresInstanceUrl` 的后端点开后是编辑表单（预填当前地址与掩码 Token，带「移除」动作）。理由：地址填错时用户的第一动作就是点那个胶囊，把它当删除键会让人一次点击就丢掉整个后端。配套地，`requiresInstanceUrl` 的胶囊尾部图标是铅笔（`Icons.edit_outlined`）而不是 `×` —— 画着删除图标却执行「打开编辑」会让人不敢点，正好抵消这条设计的初衷；真删除入口在表单内的「移除该后端」。

**状态警示。** `_WebBackendChip` 的角标不再只看 `requiresApiKey`：

- 缺 Key → 金锁（同现在）
- 缺实例地址 → 橙色 `Icons.error_outline`（优先级高于金锁，两者同时缺时先报地址）
- 缺 Token 但已配地址 → 不警示（Token 可选）

### 2.2 高级参数

后端区下面加一行「高级 · 代理 / 条数 / 并发 / 超时」折叠（`_showAdvanced`，与 `_showWebPicker` 同种展开，不新开子屏）。就地四项：

| 字段 | 控件 | 范围 | 默认 |
|---|---|---|---|
| 出站代理 | `InlineField` | 仅 `http://host:port` | 空 |
| 返回条数 | `_stepperRow` ±1 | 1-20 | 8 |
| 并发后端数 | `_stepperRow` ±1 | 1-12 | 6 |
| 单后端超时 | `_stepperRow` ±5000 | 3000-120000 ms | 30000 |

改动即存（同 `_toggleRow` 的行为：`load().copyWith(...).save()` → `_load()` → `_changed()`），不做「保存」按钮——抽屉里其余设置都是即时生效，加个保存键反而出现两套提交语义。原来的只读 `_kv('返回条数')` 被步进器取代。

### 2.3 立即测试

「高级」区底部：一颗「立即测试」折叠入口（与「高级」同款，默认收起，否则常驻半屏表单把代理和条数顶出视野），展开后是一个 query 输入框 + `InlineButton(测试)`。跑 `WebSearchService.instance.search(q, dioCancelToken: token)`（服务自己读已存配置），逐后端展示 `WebSearchBackendReport`（`ok` / `resultCount` / `elapsedMs` / `summary`），全绿与部分失败用不同色。测试读的是**已保存**配置，不搞旧页那套「草稿 override」——抽屉是即时保存模型，没有草稿态。面板的「返回」= 收起整个面板（顺带 dispose 掉在途请求），不是只清结果留着空表单。

三条生命周期纪律（R1/R2）：

- `_generation` 自增后在 `await` 之后校验（`if (!mounted || myGeneration != _generation) return;`）；`dispose()`、再次点测试都要作废上一次。
- `CancelToken` 由面板持有，`dispose()` 顺序是「代际自增 → `cancel('panel disposed')` → 置空 → `_query.dispose()`」。面板收起时 State 被 dispose，在途请求随之取消。
- `search()` 抛的是 `WebSearchTransientError` / `WebSearchQuotaError`，捕获后落成红字，不 `debugPrint` 吞掉（R8）。

## 3. 代码改动面

| 文件 | 改动 |
|---|---|
| `lib/widgets/settings_inline_panel.dart` | 主战场：状态位 + `_load()` 读数 + `_webSearch()` 重写 + `_WebSearxngForm` / `_WebTestPanel` 两个私有 widget + `_WebBackendChip` 角标 + `_WebKeyForm` 掩码切换 |
| `lib/services/web_search_config.dart` | 只加纯函数（§4）：`missingInstanceUrl`、`backendsMissingInstanceUrl` 及代理/地址归一化 |
| `lib/pages/web_search_settings_page.dart` | **删除** |
| `test/web_search_settings_page_test.dart` | **删除**，用例迁进 `test/settings_inline_panel_test.dart` + 新建 `test/web_search_settings_inline_test.dart` |
| `lib/core/settings_catalog.dart` | `_webSearchSubtitle()` 增加「N 个后端待配置」（§4） |
| `lib/l10n/app_*.arb`（×14）+ `lib/core/ui_text_index.dart` | 新增文案（§7） |

`web_search_backends.dart`、`web_search_service.dart`、`web_search_merge.dart`、`web_search_models.dart`、`router.dart`、`daos.dart`、`credentials_store.dart` 均不改。

## 4. 配置层新增（`web_search_config.dart`）

缺实例地址的判断原来散在服务层（`requiresInstanceUrl` + `url.isEmpty`），UI 再手写一遍必然漂移——这正是 R5「改一处副作用要枚举所有路径」在数据层的翻版。收成一个纯函数：

```dart
// WebSearchProvider 上
bool missingInstanceUrl(String searxngInstanceUrl) =>
    requiresInstanceUrl && searxngInstanceUrl.trim().isEmpty;

// WebSearchConfig 上：胶囊角标与目录副标题共用一个口径
List<WebSearchProvider> backendsMissingInstanceUrl();
```

**落地时砍掉了原计划的 Key 维度。** 初稿想做一个 `WebSearchSetupGap { none, missingApiKey, missingInstanceUrl }` 枚举 + `gapOf()` + 面板 `_refreshGaps()`（异步读 `CredentialsStore`，带 `_statusGeneration` 代际守卫），与旧页 `_refreshKeyStatus()` 同构。实现后否决：

- Key 是否已配要 `await` 凭据库，而角标本已有 `requiresApiKey` 这个同步口径（金锁=「这个后端要 Key」），异步刷新只是把它换成「这个后端还缺 Key」——收益是一条角标语义，代价是一次启动期异步 + 一套代际守卫。
- 异步刷新在 `testWidgets` 的 FakeAsync 下不推进（`CredentialsStore` 走 platform channel），角标断言永远拿不到数据，测试只能绕。
- 真正「每次搜索必定被跳过」的是缺地址（服务层 `web_search_backends.dart` 直接 skip），缺 Key 至少会在搜索时给出可读报错。**界面只警示静默失效的那一类。**

最终 `WebSearchSetupGap` / `gapOf` / `backendsWithGaps` / `gapsFor` 全部不存在，缺口判定纯同步。

代理与地址归一化从旧页 `_normalizeProxy`（1188-1196）原样搬成 `static String? normalizeProxy(String raw)`：无 scheme 补 `http://`、只允许 `http`、拒绝 `userInfo`（防把 `user:pass@host` 当合法代理存下来）、`Uri.host` 为空即非法；空串表示「不设代理」，`null` 表示非法。实例地址另加 `normalizeInstanceUrl`：必须是 `http`/`https` 且带 host，去尾斜杠。

副标题：`已开启 · N 个后端可用`，当 `backendsMissingInstanceUrl()` 非空时追加 `· M 个待配置`。用户不展开抽屉也能看出「加了 3 个但有个不能用」。

## 5. 校验与边界

1. **代理**：`_normalizeProxy` 失败 → 红字「仅支持 http://host:port，不支持 SOCKS5/代理账号密码」，输入不落库。
2. **SearXNG 地址**：必填；`Uri.tryParse` 为 null / 无 host / scheme 非 http(s) → 就地红字，不启用后端。
3. **数字**：越界不保存，步进器在边界禁用按钮（`_StepButton` 传 `onTap: null`，`InlineButton` 已支持 null 即禁用）。
4. **Token 清空**：`_WebSearxngForm` 里地址非空但 Token 框被清空 → 调 `deleteApiKey(searxng)`。掩码框无法区分「没改」和「清空」，所以表单内记 `_touched` 标志，仅在用户真的编辑过时才写/删（避免每次打开表单都误删已存 Token）。
5. **总开关关掉**：仍显示已选后端与高级参数，只是测试按钮禁用并提示「先开总开关」——用户常是先关搜索再回来清配置。
6. **一个后端都没启用**：保留现有提示，优先级高于待配置提示。另在 SearXNG 缺地址且表单尚未打开时给「SearXNG 还差实例地址：点它的胶囊补上」——表单已经摊在眼前时不再重复这句话。

## 6. 风险

- **R-1 即时保存的写放大**：步进器每点一次都 `save()`。`SettingsDao.set` 是 SQLite 单行 KV，且 `_webNumResults` 等读的是 `SettingsDao.getCached` 内存缓存，连续点击不产生读放大；但每次写都会触发 `onChanged` → 目录副标题重算。缓解：步进器 `onChanged` 里 `_changed()` 照常调用（读数要更新），实测副标题重算是同步纯计算，无 IO。**不做防抖**，等真出现卡顿再加。
- **R-2 删除旧页丢失能力**：旧页还有「Key 清除」「获取 Key 链接」「360px 窄屏」这些细节。逐条核对后落到新面板：获取 Key 链接 → `_WebKeyForm` 与 `_WebSearxngForm` 行内「复制获取 Key 的地址」；窄屏 → 新测试断言 360px。「Key 清除」不复刻——`_WebKeyForm` 只在**尚未配 Key** 时才会打开（有 Key 时点胶囊是直接移除后端），清除分支永远走不到，属于旧页的死代码。旧页测试的 5 条用例必须逐条在新面板复刻后才允许删除旧页（§8）。
- **R-3 l10n 回退**：新文案若未进 `ui_text_index.dart`，`UiText.t` 会退回 zh/en 二元组——14 语种里 12 个直接显示英文。**本仓库不可跑 `tools/i18n_arb_merge.py`**：它的 `UiText.t` 扫描看不到只经生成的 `L10n.str.ut_*` getter 使用的 key，而合并步骤会先删光全部 `ut_*` 再重建，实测一把跑完 14 个 arb 从 945 个 key 掉到 711（−234，约 2.6 万行）。改用手写增量脚本，按工具自己的 key 规则（`ut_ + sha1(zh+"\x1f"+en)[:10]`）与 `dart_quote` 转义，只追加新条目，然后 `flutter gen-l10n`。
- **R-4 `_webKeyFor` 与 `_webSearxngFor` 抢占**：两个子视图同时只能存在一个，否则一个展开 Key 一个展开地址会叠出半屏表单。进入任一表单时清空另一个；`_showWebPicker` 一并收起。

## 7. 文案与 i18n

沿用 `UiText.t('<zh>', '<en>')`。旧页已有的字符串大多已在索引里（`SearXNG 实例地址`、`出站代理（可选）`、`代理仅支持 http://host:port` 等已核实存在），复用原文省掉大部分新增。

实际新增 16 条（`ut_` key 从 945 → 961）：`高级 · 代理 / 条数 / 并发 / 超时`、`并发后端数`、`单后端超时`、`测试关键词`、`Token（可选）`、`移除该后端`、`收起高级`、`SearXNG 还差实例地址：…` 等。落地方式见 R-3：按 key 规则增量写入 14 个 arb + `ui_text_index.dart`，再 `flutter gen-l10n`；短标签人工补 12 语种，长句按工具既有规则回退英文。

## 8. 验收计划

自动化：

1. `flutter analyze` 零 issue（本机 SDK：`/d/tools/flutter_sdk/flutter/bin`，3.47.8；见项目环境记录，别用 344 那个）。
2. `flutter test`：新增 `test/web_search_settings_inline_test.dart`
   - 选 SearXNG → 出现实例地址表单，**且后端未被启用**（盯本次的核心 bug）
   - 空地址点「保存并启用」被拦下并出红字；填非法地址同样被拦
   - 填 `http://127.0.0.1:8888` → 保存后胶囊出现且无缺口警示；`WebSearchConfig.load().searxngInstanceUrl` 等于输入值
   - 点已启用的 SearXNG 胶囊 → 打开编辑表单且预填地址
   - 缺 Key 的后端仍显示金锁；缺地址的 SearXNG 显示警示角标
   - 返回条数步进器到 20 后加号失效，落库为 20
   - 代理填 `socks5://x:1` → 报错且不落库；填 `127.0.0.1:7890` → 落库为 `http://127.0.0.1:7890`
   - 立即测试：替换 `webSearchProviders[bingRss]` 为 fake provider，断言报告里出现该后端与条数
   - 360×800 无溢出断言
3. 复刻旧页 5 条用例后删除 `test/web_search_settings_page_test.dart` 与页面文件；`grep -rn "web_search_settings_page" ai_terminal/` 为空。
4. `test/settings_inline_panel_test.dart` 既有的 `联网搜索面板列出后端胶囊` 用例保持通过。

真机（Windows dev 实例）：抽屉里加 SearXNG → 填 `http://127.0.0.1:8888`（未启实例）→ 立即测试应给出可读的失败原因而不是静默；启一个本地 SearXNG 后复测应回结果。这一步不能跳：`flutter analyze`/`test` 只证明代码正确，不证明用户点得到。

### 8.1 验收结果（2026-11-19）

自动化全部通过：`flutter analyze` 触及文件零 issue；`flutter test` 1640 通过 / 25 跳过（跳过项均为仓库既有 `skip:`）；`grep -rn "web_search_settings_page"` 为空。

真机走查（`flutter run -d windows` 调试实例，非安装版）逐条通过：

- SearXNG 胶囊点开 = 编辑表单，地址预填 `http://127.0.0.1:8888`，含自建说明、复制部署文档地址、Token 掩码框带显隐、「移除该后端」。
- 高级区展开：返回条数 20（上界，加号已禁用）/ 并发后端数 6 / 单后端超时 30000 ms 三行步进器 + 出站代理输入框 + 立即测试。
- 代理填 `socks5://127.0.0.1:7890` 点保存 → 红字「仅支持 http://host:port，不支持 SOCKS5/代理账号密码」，收起重开后字段回空（未落库）。
- 立即测试 `flutter` → 「共 10 条结果 · 1 个后端成功 · 2 个失败」，逐后端一行：Bing RSS 绿勾 10 条 · 357ms；DuckDuckGo / SearXNG 红叉带网络错误原文与「请在设置页配置出站代理」提示。
- 本机无可用 SearXNG 实例，SearXNG 一行的实际表现即「未启实例给出可读失败原因」；「启本地实例后复测回结果」未做（需要额外部署 Docker，判断为可由用户按红字提示自行验证）。
- 走查全程未写入用户配置：代理未落库、总开关与后端胶囊未动，退出前收起子视图与高级区；调试实例已关闭，用户自己的安装版实例未受影响。

## 9. 已知取舍

- SearXNG 地址只有一份全局配置（`searxngInstanceUrl` 是单值），不做多实例列表。多实例的意义是让同一次 fan-out 打多个 SearXNG，收益低于「配置模型 v3 迁移 + 每实例独立地址」的成本。
- 不做 `llmBackends` 的模型选择（`defaultModel` 仍写死 `claude-sonnet-4-5` / `gpt-4.1-mini`，`web_search_config.dart:212-222`）。
- 不引入旧页的「草稿 + 保存」两段式。抽屉里其余设置都是即时生效，两套提交语义会让用户怀疑自己刚才是不是没保存。
