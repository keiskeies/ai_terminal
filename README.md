<p align="center">
  <img src="./docs/logo.png" width="128" height="128" alt="AI Terminal Logo" />
  <h1 align="center">⚡ AI Terminal</h1>
  <p align="center">
    <strong>用自然语言操控服务器，AI 替你敲命令</strong>
  </p>
  <p align="center">
    <a href="https://ai-terminal.keiskei.top" target="_blank">🌐 官网</a> · 
    <a href="https://github.com/keiskeies/ai_terminal/releases" target="_blank">📦 下载</a> · 
    <a href="./QUESTION.md">❓ 常见问题</a>
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/Flutter-3.16+-02569B?style=flat-square&logo=flutter" alt="Flutter" />
    <img src="https://img.shields.io/badge/平台-macOS%20%7C%20Linux%20%7C%20Windows%20%7C%20Android%20%7C%20iOS-green?style=flat-square" alt="Platform" />
    <img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="License" />
    <img src="https://img.shields.io/badge/version-1.3.4-orange?style=flat-square" alt="Version" />
  </p>
</p>

---

**中文** | [English](./README_EN.md)

## 一句话说清楚

> **不会命令行？没关系。** 打开 AI Terminal，用中文告诉它你要干什么，它帮你连服务器、跑命令、装软件、查问题——全程安全可控。

## 🎯 你是不是遇到过这些情况？

### 😫 小白 / 非技术人员

- 买了云服务器，打开终端一脸懵——**这黑框框怎么用？**
- 朋友说"装个 Nginx"，你搜了一堆教程，每篇都不一样
- 想配个 JDK 环境，`PATH` 改错了，整个终端都废了
- 服务器被人警告有漏洞，你连怎么检查都不知道
- 折腾一下午，服务没跑起来，心态先崩了

### 👨‍💻 开发者

- 每次部署都在百度/Google 同样的命令
- SSH 连上服务器，半天想不起来 `systemctl` 怎么拼
- 想快速看个日志，还得翻笔记找 `grep` 的参数
- 多台服务器来回切换，Tab 开了十几个

### 🔧 运维 / DevOps

- 重复劳动：10 台机器装同一个软件，一台台 SSH 过去
- 操作记录全靠脑子记，出了事回溯不了
- 新人问"怎么配环境"，你每次都得手把手教
- 想做个批量巡检，写脚本比手动还慢

### 🧑‍💼 产品经理 / 一人公司

- 技术合伙人离职了，服务器成了黑箱
- 想看个数据得求人，自己又不会写 SQL
- 部署新功能要等排期，其实就改个配置的事
- 一个人干三个人的活，没时间学命令行

**以上所有场景，AI Terminal 一句话搞定。**

## 💡 它能帮你做什么？

### 装软件？一句话的事

> 💬 "帮我装个 Docker"

AI 自动检测系统版本，匹配官方文档，执行安装命令，装完自动验证。不需要你记任何命令。

### 配环境？不用背 PATH

> 💬 "帮我装 Python 3.12 并配好环境变量"

AI 知道 Debian 用 `apt`、CentOS 用 `yum`、macOS 用 `brew`。它不瞎编，严格按官方文档来。

### 查漏洞？比你还紧张

> 💬 "帮我检查服务器有没有安全漏洞"

AI 自动运行系统更新检查、端口扫描、进程审计，生成完整报告告诉你哪些要修。

### 看日志？不用翻笔记

> 💬 "看看 nginx 最近的错误日志"

AI 知道日志在哪、怎么过滤、怎么看。直接给你关键信息，不用你拼 `tail -f`。

### 管服务器？多台也从容

支持 SSH 远程连接，一个界面管多台服务器。连接池复用，切换零延迟。

## 🛡️ 安全？这是最该关心的事

把服务器交给 AI 管，你肯定担心：**密码会不会泄露？AI 会不会把系统搞崩？会不会偷偷装后门？**

AI Terminal 从架构层面回答这三个问题：

### 🔐 密码怎么存的？

```
你的密码 → 系统级安全存储（macOS Keychain / Android Keystore）
                ↓
         本地数据库只存"用了哪个密钥"，不存密码本身
                ↓
         永远不会以明文形式出现在日志、配置文件或磁盘上
```

即使有人拿到你的设备，没有系统级认证（指纹/密码），读出来的也只是一堆加密数据。

### 🤖 AI 能乱来吗？

**不能。** 三道安全关卡层层拦截：

```
┌─────────────────────────────────────────────────────┐
│ 第一关：行为边界提示词                                │
│ AI 系统指令明确禁止：                                  │
│   ✗ 不能擅自安装/卸载软件                              │
│   ✗ 不能修改环境变量或系统配置                          │
│   ✗ 不能执行破坏性操作                                 │
│   ✓ 用户说"检查/查看"时，只执行只读命令                  │
│   ✓ 发现问题先报告，不自作主张修复                      │
└─────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────┐
│ 第二关：SafetyGuard 命令分级                           │
│ 每条命令在执行前都会被安全守卫审查：                      │
│   🔴 blocked → 直接拦截，禁止执行                      │
│      （rm -rf /、chmod 777、格式化磁盘等）              │
│   🟡 warn → 弹窗提示，需手动输入 CONFIRM 确认          │
│      （apt install、systemctl stop、修改防火墙等）      │
│   🔵 info → 低风险提示，正常执行                       │
│      （curl、wget、ls、cat 等）                        │
└─────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────┐
│ 第三关：用户确认                                      │
│ 你始终是最后一道防线。                                  │
│ 任何 warn 级别的操作，不输入 CONFIRM 就不会执行。        │
│ 随时可以中断、取消、查看执行历史。                       │
└─────────────────────────────────────────────────────┘
```

### 📋 Agent 行为白皮书

| 你能做的 | AI 能做的 | AI 不能做的 |
|:---|:---|:---|
| 让 AI 安装软件 | 生成官方安装命令并执行 | 擅自决定装什么版本 |
| 让 AI 检查安全 | 运行审计命令并报告 | 发现问题后自行修复 |
| 让 AI 配置环境 | 按官方文档配置 | 修改你没要求的系统参数 |
| 让 AI 查看日志 | 过滤并展示关键信息 | 删除或修改日志文件 |
| 让 AI 管理服务 | 启停指定服务 | 启动你没提到的其他服务 |

**一句话总结：AI 是你的助手，不是你的老板。你让它做什么，它就做什么。你没让它做的，它绝对不会碰。**

## ✨ 核心特性

| 特性 | 描述 |
|:---|:---|
| 🤖 **Agent 智能执行** | AI 自动生成命令并循环执行，直到任务完成 |
| 🛡️ **三重安全防护** | 行为边界提示词 → SafetyGuard 命令分级 → 危险操作需 CONFIRM 确认 |
| 🔐 **零明文凭据** | 密码/私钥存储在系统 Keychain / Keystore，永不明文落盘 |
| 🖥️ **5 平台原生** | macOS / Linux / Windows / Android / iOS 全平台支持 |
| 📡 **本地 + 远程** | SSH 远程连接 + 本地 PTY 终端，Agent 两种模式均可工作 |
| 🔄 **连接池复用** | 多标签共享同一 SSH 连接，切换零延迟 |
| 🌊 **流式输出** | AI 响应实时渲染，终端命令即时回显 |
| 🧠 **知识库驱动** | 内置 150+ 软件安装/配置指南，严格按官方文档执行，杜绝 AI 编造命令 |
| 🌐 **20+ 供应商** | DeepSeek / Qwen / Claude / Gemini / Ollama 等，支持远程配置更新 |

## 🏗️ 技术架构

```
Flutter 3.16+ (Dart 3.2+)
├── 状态管理: Riverpod
├── 路由: GoRouter
├── 本地存储: Hive + flutter_secure_storage
├── SSH: dartssh2
├── 本地终端: flutter_pty
├── 终端 UI: xterm.dart
├── AI 接口: OpenAI 兼容 (20+ 供应商)
└── Markdown: flutter_markdown
```

## 🚀 快速开始

### 环境要求

- Flutter 3.16.0+
- Dart 3.2.0+
- 对应平台开发工具（Xcode / Android Studio / VS Code 等）

### 安装运行

```bash
# 克隆仓库
git clone https://github.com/keiskeies/ai_terminal.git
cd ai_terminal/ai_terminal

# 安装依赖
flutter pub get

# 生成 Hive Adapter（首次需要）
dart run build_runner build --delete-conflicting-outputs

# 运行
flutter run
```

### 构建发布

```bash
# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Linux
flutter build linux --release

# Android APK
flutter build apk --release

# iOS (需要 macOS + 开发者证书)
flutter build ios --release
```

> 📥 也可以直接从 [Releases](https://github.com/keiskeies/ai_terminal/releases) 下载预编译版本。

## 🔧 配置 AI 模型

应用内置 **20+ AI 供应商预设**，支持任何 **OpenAI 兼容 API**：

| 分类 | 供应商 |
|:---|:---|
| 🏠 本地部署 | Ollama（完全免费，无需 API Key） |
| 🇨🇳 国内云服务 | DeepSeek / 通义千问 / 智谱GLM / Kimi / 豆包 / 小米MiMo / MiniMax / 硅基流动 / 阶跃星辰 / 百川 / 讯飞星火 / 腾讯混元 |
| 🌍 国际云服务 | OpenAI / Claude / Gemini / xAI Grok / Mistral / OpenRouter / Groq |
| 🔧 自定义 | 任何 OpenAI 兼容 API 端点 |

配置步骤：

1. 打开应用 → 设置 → AI 模型配置
2. 点击 `+` 添加模型
3. 选择供应商（自动填充 Base URL 和推荐模型）
4. 填写 API Key，选择模型
5. 设为默认模型

> 💡 供应商列表支持远程更新：点击提供商旁的 🔄 按钮即可从服务器获取最新供应商和模型列表，无需更新应用

## 📱 截图

| 服务器管理 | SSH 终端 |
|:---:|:---:|
| <img src="./ai_terminal/doc/ai-t1.png" width="400" /> | <img src="./ai_terminal/doc/ai-t2.png" width="400" /> |

| AI 对话助手 | Agent 自动执行 |
|:---:|:---:|
| <img src="./ai_terminal/doc/ai-t3.png" width="400" /> | <img src="./ai_terminal/doc/ai-t4.png" width="400" /> |

<p align="center">
  <img src="./ai_terminal/doc/ai-t5.png" width="400" />
  <br /><b>AI 模型配置</b>
</p>

> 🤖 以上截图中的 AI 功能由 <b>小米 MiMo</b> 大模型驱动

## 📖 实战演示：知识库驱动的自动安装

v1.3.0 新增**命令手册知识库**——内置 150+ 常用软件的官方安装/卸载/更新指南，Agent 会自动匹配知识库，严格按官方推荐方式执行，**杜绝 AI 编造命令**。

以下演示在 SSH 连接到 Ubuntu 服务器后，输入"安装 openclaw"的完整流程：

| ① 输入指令 | ② 知识库命中，生成命令 |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_1.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_2.webp" width="400" /> |

| ③ 自动执行安装 | ④ 安装完成验证 |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_3.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_4.webp" width="400" /> |

**流程解析：**

1. 用户输入"安装 openclaw" → Agent 提取操作类型（install）和目标平台（linux）
2. 知识库命中 `openclaw` 的 `linux-debian` 条目（strict 模式），注入官方安装命令到系统提示词
3. Agent 严格按照知识库命令执行：先安装 Node.js 22，再 `npm install -g openclaw`
4. 安装完成后自动验证，运行 `openclaw --version` 确认成功

> 💡 知识库支持按平台精确匹配（如 `linux-debian` vs `linux-rhel` 给出不同包管理器命令），支持从远程服务器一键更新

## 🗺️ 路线图

- [x] v1.0.0 — 核心功能发布
  - [x] SSH 远程终端 + 本地 PTY 终端
  - [x] AI 对话 + 命令生成 + 自动执行
  - [x] SafetyGuard 命令安全校验
  - [x] 凭据加密存储
  - [x] 多模型配置
- [x] v1.1.0 — UI 增强
  - [x] AI 面板布局重设计
  - [x] 移动端自动横竖屏适配
  - [x] Agent 模式绿色主题
- [x] v1.2.0 — Agent 智能增强
  - [x] 对话历史持久化，多轮上下文不丢失
  - [x] 查询类命令输出不截断
  - [x] 执行步骤数默认无限制
  - [x] SFTP 文件管理 + 远程编辑
- [x] v1.3.0 — 知识库驱动
  - [x] 🧠 SQLite FTS5 全文搜索知识库（150+ 软件安装/卸载/更新指南）
  - [x] 🔄 远程知识库自动同步（启动时从 GitHub 更新，离线可用）
  - [x] 🎯 平台精确匹配（linux-debian / linux-rhel / macos 等细粒度分发）
  - [x] 🛡️ LLM 安全规则（strict 强制执行 + 禁止搜索类命令防猜测）
  - [x] 🔧 知识库构建工具（CSV → SQLite 转换脚本）
  - [x] 💬 友好的 API 错误提示（401/429/超时等）
- [x] v1.3.1 — 供应商生态
  - [x] 🌐 内置 20+ AI 供应商预设（国内 12 家 + 国际 8 家 + Ollama 本地 + 自定义）
  - [x] 🔄 远程供应商配置更新（从服务器拉取最新供应商列表，无需发版）
  - [x] 🏷️ 供应商描述与定价信息（选择供应商时显示简介和定价）
  - [x] 🤖 预设模型快捷选择（每个供应商内置推荐模型列表，一键选择）
  - [x] 🦙 Ollama 本地部署支持（无需 API Key，完全免费）
  - [x] 📐 添加模型弹窗优化（宽屏双列布局、字段顺序优化）

## 🤝 贡献

欢迎贡献！无论是 Bug 报告、功能建议还是代码提交。

1. Fork 本仓库
2. 创建功能分支 (`git checkout -b feature/amazing-feature`)
3. 提交修改 (`git commit -m 'Add amazing feature'`)
4. 推送分支 (`git push origin feature/amazing-feature`)
5. 发起 Pull Request

## 📄 许可证

[MIT License](./LICENSE)

---

## ⭐ Star History

[![Star History Chart](https://api.star-history.com/svg?repos=keiskeies/ai_terminal&type=Date)](https://star-history.com/#keiskeies/ai_terminal&Date)

---

<p align="center">
  如果这个项目对你有帮助，请给个 ⭐ Star 支持一下！
</p>
