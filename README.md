<p align="center">
  <img src="./docs/logo.png" width="112" height="112" alt="AI Terminal Logo" />
  <h1 align="center">AI Terminal</h1>
  <p align="center">
    <strong>用自然语言操作服务器，AI 替你执行命令</strong>
  </p>
  <p align="center">
    <a href="https://ai-terminal.keiskei.top">官网</a> ·
    <a href="https://github.com/keiskeies/ai_terminal/releases">下载</a> ·
    <a href="./QUESTION.md">常见问题</a> ·
    <a href="https://github.com/keiskeies/ai_terminal/issues">Issues</a>
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/version-1.3.8-orange?style=flat-square" alt="Version" />
    <img src="https://img.shields.io/badge/Flutter-3.47.8-02569B?style=flat-square&logo=flutter" alt="Flutter" />
    <img src="https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows%20%7C%20Android%20%7C%20iOS-green?style=flat-square" alt="Platforms" />
    <img src="https://img.shields.io/badge/languages-14-blue?style=flat-square" alt="Languages" />
    <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License" />
  </p>
</p>

**语言：**
**中文** | [English](./README_EN.md) | [日本語](./README_JA.md) | [Deutsch](./README_DE.md) | [Français](./README_FR.md) | [Español](./README_ES.md) | [한국어](./README_KO.md) | [Русский](./README_RU.md) | [Português](./README_PT.md) | [Italiano](./README_IT.md)

---

<p align="center">
  <img src="./docs/screenshots/operation-sheet-dark-en.png" width="920" alt="AI Terminal operation sheet" />
  <br />
  <sub>英文界面 · 石墨青深色主题 · 结论优先的 Agent 操作单</sub>
</p>

## AI Terminal 是什么

AI Terminal 是一个把 AI 助手、SSH 远程终端和本地终端放在同一个界面里的跨平台工具。你用自然语言描述目标，Agent 负责规划、执行命令、检查结果并给出结论；危险操作会先经过安全校验和你的确认。

它面向真实的服务器操作场景，而不是只会聊天的终端壳：

- 远程连接可能是慢的、会断的，因此界面要能恢复、重试和继续任务
- 服务器上的文件、权限和编码很容易出错，因此写入、上传、下载和补丁都要可验证、可回滚
- 用户需要知道 AI 做了什么，因此每条命令、退出码、耗时和变更都要能看到

## 核心能力

### Agent 操作单

不再把思考、命令和输出堆成一条长聊天记录，而是分层展示：

- **结论优先**：任务结束先给结论，再展开现状、变更与建议
- **执行清单**：模型声明的计划、完成计数和当前步骤一目了然
- **过程与证据**：命令、输出、耗时、退出码和失败分类按需展开
- **变更台账**：记录文件修改与命令变更，支持回滚和审计
- **失败恢复**：权限不足、断线、超时会给出针对性动作，可重试失败主机或继续任务
- **多主机矩阵**：批量/广播操作按主机展示状态、耗时和输出

### 远程文件操作

- `sftp_upload` / `sftp_download`：本地上传、服务器下载，支持单文件和目录递归
- `file_write` / `file_patch`：绕过 shell 直接写文件或做字符串替换
- 上传/下载使用临时文件 + rename，失败不会截断原文件
- `file_patch` 按字节替换，保留 BOM、CRLF 和非 UTF-8 字节
- 普通文本可直接用 `content` / `old` / `new`，不必让模型手算中文 base64
- SFTP 编辑器会拒绝超大/非 UTF-8 文件，保存失败自动恢复

### 运维工具

- **服务器监控**：CPU、内存、磁盘、网络，多主机并行查看
- **Runbook 工作流**：内置巡检、安全、部署、维护模板，也支持自定义
- **变更记录与审计日志**：操作人、时间、命令、结果、退出码可追溯
- **安全时段**：限制允许修改的时间窗口
- **通知中心**：任务完成、异常告警和安全提醒
- **多机编排**：在单机、指定主机或一组主机上执行任务

### AI 与知识库

- 兼容任何 OpenAI 兼容 API；内置 22 个供应商预设、90+ 个预设模型
- 模型可配置备用模型、上下文长度、最大输出和 Function Calling
- AI 联网搜索支持 7 种引擎：Bing HTML、DuckDuckGo、Brave、SearXNG、Tavily、Bing API、SerpAPI
- 知识库包含 300+ 条软件安装/配置条目，按平台匹配命令
- API Key 只保存在系统安全存储中，不写入日志或明文配置

### 体验

- **石墨青主题**：深色与浅色两套配色；青色用于交互与当前状态，金色用于数据强调
- **中英文 Agent UI**：Agent 操作单和计划面板优先支持英文/中文，其它语言回退英文
- **14 种界面语言**：简体中文、English、日本語、한국어、Deutsch、Français、Русский、Español、Português、العربية、Italiano、हिन्दी、ไทย、Tiếng Việt
- **5 个平台**：macOS、Linux、Windows、Android、iOS
- 本地 PTY 终端 + SSH 终端，多标签共享连接池

## 截图

| Agent 操作单（英文 / 深色） | 外观设置（英文 / 深色） |
|:---:|:---:|
| <img src="./docs/screenshots/operation-sheet-dark-en.png" width="440" /> | <img src="./docs/screenshots/settings-dark-en.png" width="440" /> |

## 下载安装

从 [GitHub Releases](https://github.com/keiskeies/ai_terminal/releases) 下载最新版本：

| 平台 | 文件 |
|---|---|
| macOS | `AI_Terminal_v1.3.8_macOS.zip` |
| iOS | `AI_Terminal_v1.3.8_iOS.ipa`（未签名） |
| Android | `AI_Terminal_v1.3.8_Android.apk` |
| Windows | `AI_Terminal_v1.3.8_Windows.zip` |
| Linux x64 | `AI_Terminal_v1.3.8_Linux_x64.tar.gz` |

macOS 首次打开如提示“无法验证开发者”，可执行：

```bash
xattr -cr "/Applications/AI Terminal.app"
```

iOS 包未签名，需要自行使用 Xcode/AltStore 等方式安装。

## 从源码运行

要求：Flutter 3.44+（本项目在 3.47.8 / Dart 3.13 上测试），以及对应平台的构建工具。

```bash
git clone https://github.com/keiskeies/ai_terminal.git
cd ai_terminal/ai_terminal

flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

Linux 还需要安装：

```bash
sudo apt-get install -y libgtk-3-dev libblkid-dev liblzma-dev ninja-build \
  libgcrypt20-dev libsecret-1-dev libjsoncpp-dev
```

构建发布包：

```bash
flutter build macos --release
flutter build windows --release
flutter build linux --release
flutter build apk --release
flutter build ios --release
```

## 配置 AI 模型

1. 打开 **设置 → AI Model Config**
2. 新增模型，选择供应商或填写任意 OpenAI 兼容端点
3. 填入 Base URL、模型名和 API Key
4. 保存并设为默认模型

API Key 由系统安全存储保存；应用本地数据库只保存模型配置元数据。

## 安全设计

- **凭据**：系统 Keychain / Keystore + AES 加密数据库，不明文落盘
- **命令分级**：SafetyGuard 将命令分为 blocked / warn / info / safe；危险操作需要用户确认
- **文件安全**：写入前备份，失败回滚；上传/下载原子替换；补丁做唯一性和并发修改校验
- **可追溯**：命令、文件变更、退出码和失败原因记录在变更台账与审计日志中
- **边界**：AI 是执行助手，不是权限提升工具；服务器仍应遵循最小权限、防火墙和备份策略

## 架构

```
Flutter (Dart)
├── Riverpod                 状态管理
├── GoRouter                 路由
├── SQLite3MultipleCiphers   加密本地数据库
├── flutter_secure_storage   凭据存储
├── dartssh2                 SSH / SFTP
├── flutter_pty              本地 PTY
├── xterm.dart               终端渲染
├── Dio                      OpenAI 兼容 API
└── SQLite FTS5              知识库全文搜索
```

仓库根目录是项目文档，Flutter 工程在 `ai_terminal/`。

## 测试

```bash
cd ai_terminal
flutter analyze
flutter test
```

真实 SSH / 真实 LLM 的 E2E 测试通过环境变量启用，不会在默认测试中访问外部服务。测试覆盖：

- 操作单解析与渲染、计划计数、失败恢复、回滚
- SFTP 上传/下载、目录递归、二进制/大文件 SHA-256
- file_write / file_patch 的 UTF-8、CRLF、BOM、非 UTF-8 字节和并发校验
- 本地/远程文件修改、真实模型驱动的上传下载与改文件流程

## 已知边界

- macOS / iOS 发布包未做 Apple 公证/签名；iOS 需要自行签名安装
- 应用不内置模型，需要自备 OpenAI 兼容 API Key
- Agent 会执行真实命令；请在生产环境先阅读确认信息并做好备份
- 14 种语言覆盖核心界面；最新 Agent 操作单文案目前以英文/中文为主，其它语言回退英文
- 目录传输暂不并发，符号链接默认跳过

## 链接

- [官网](https://ai-terminal.keiskei.top)
- [Releases](https://github.com/keiskeies/ai_terminal/releases)
- [常见问题](./QUESTION.md)
- [操作单设计文档](./docs/agent-operation-sheet-design.md)
- [Issue Tracker](https://github.com/keiskeies/ai_terminal/issues)

## 许可证

[MIT License](./LICENSE)

---

<p align="center">
  如果这个项目对你有帮助，欢迎给一个 Star。
</p>
