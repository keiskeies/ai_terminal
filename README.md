<p align="center">
  <img src="./docs/logo.png" width="128" height="128" alt="AI Terminal Logo" />
  <h1 align="center">⚡ AI Terminal</h1>
  <p align="center">
    <strong>AI 驱动的跨平台安全终端</strong>
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
    <img src="https://img.shields.io/badge/version-1.2.0-orange?style=flat-square" alt="Version" />
  </p>
</p>

---

**中文** | [English](./README_EN.md)

## 🎯 这是什么？

AI Terminal 是一个将 **AI 助手** 与 **SSH / 本地终端** 深度集成的跨平台应用。用自然语言告诉 AI 你想做什么，它会生成命令、自动执行、分析结果——全程在安全的沙箱内完成。

> 💬 *"帮我检查一下 JDK 安装情况"* → AI 自动执行 `java -version` 并分析结果
>
> 💬 *"查看磁盘占用"* → AI 自动执行 `df -h` 并给出清理建议

## ✨ 核心亮点

| 特性 | 描述 |
|:---|:---|
| 🤖 **双模式 Agent** | **自动模式**：AI 生成命令并自动执行，循环到任务完成；**辅助模式**：AI 生成命令供你确认后执行 |
| 🛡️ **三重安全防护** | 行为边界提示词 → SafetyGuard 命令分级（safe/warn/blocked）→ 危险操作需输入 CONFIRM 确认 |
| 🔐 **零明文凭据** | 密码/私钥使用系统级安全存储（Keychain / Keystore），永不明文落盘 |
| 🖥️ **5 平台原生** | macOS / Linux / Windows / Android / iOS 全平台原生支持 |
| 📡 **本地 + 远程** | 既支持 SSH 远程连接，也支持本地 PTY 终端，Agent 在两种模式下均可工作 |
| 🔄 **连接池复用** | SSH 连接池 + 引用计数，多标签共享同一连接，切换标签零延迟 |
| 🌊 **流式输出** | AI 响应流式渲染，终端命令实时回显，无卡顿等待 |
| 🎨 **暗色极简** | 精心调校的暗色主题，JetBrains Mono 等宽字体，终端体验原生级 |

## 🏗️ 技术架构

```
Flutter 3.16+ (Dart 3.2+)
├── 状态管理: Riverpod
├── 路由: GoRouter
├── 本地存储: Hive + flutter_secure_storage
├── SSH: dartssh2
├── 本地终端: flutter_pty
├── 终端 UI: xterm.dart
├── AI 接口: OpenAI 兼容 (支持 DeepSeek / Qwen / GPT / 任何 OpenAI 兼容模型)
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

应用支持任何 **OpenAI 兼容 API**，配置步骤：

1. 打开应用 → 设置 → AI 模型配置
2. 点击 `+` 添加模型
3. 填写：
   - **API Key**: 你的密钥
   - **Base URL**: API 地址（如 `https://api.deepseek.com/v1`、`https://api.openai.com/v1`）
   - **模型名**: `deepseek-chat`、`gpt-4o`、`qwen-plus` 等
4. 设为默认模型

> 💡 推荐使用 小米 mino-v2.5-pro，命令生成准确率优秀

## 🛡️ 安全设计

安全是 AI Terminal 的第一优先级：

### 凭据安全
- 密码/私钥使用 `flutter_secure_storage` 存储到系统 Keychain / Keystore
- 本地数据库（Hive）只存元数据，永不存储明文凭据
- 支持 AES 二次加密增强（可选）

### 命令安全
```
SafetyGuard 三级拦截：
├── 🔴 blocked → 直接拦截，禁止执行（如 rm -rf /）
├── 🟡 warn   → 需输入 CONFIRM 确认（如 apt install, systemctl stop）
└── 🔵 info   → 低风险提示（如 curl, wget）
```

### Agent 行为边界
- 用户说"查看/检查/确认"时，仅执行只读命令
- 禁止擅自安装/升级/替换/卸载软件
- 禁止擅自修改环境变量和系统配置
- 发现问题时先报告，不自作主张修改

## 📱 截图

<table>
  <tr>
    <td align="center"><b>服务器管理</b></td>
    <td align="center"><b>SSH 终端</b></td>
  </tr>
  <tr>
    <td><img src="./ai_terminal/doc/ai-t1.png" width="400" /></td>
    <td><img src="./ai_terminal/doc/ai-t2.png" width="400" /></td>
  </tr>
  <tr>
    <td align="center"><b>AI 对话助手</b></td>
    <td align="center"><b>Agent 自动执行</b></td>
  </tr>
  <tr>
    <td><img src="./ai_terminal/doc/ai-t3.png" width="400" /></td>
    <td><img src="./ai_terminal/doc/ai-t4.png" width="400" /></td>
  </tr>
</table>

<p align="center">
  <img src="./ai_terminal/doc/ai-t5.png" width="400" />
  <br /><b>AI 模型配置</b>
</p>

> 🤖 以上截图中的 AI 功能由 <b>小米 mino-v2.5-pro</b> 大模型驱动

## 📂 项目结构

```
ai_terminal/
├── lib/
│   ├── main.dart                    # 应用入口
│   ├── core/                        # 核心模块
│   │   ├── theme.dart               # 暗色主题
│   │   ├── router.dart              # 路由配置
│   │   ├── prompts.dart             # AI 系统提示词
│   │   ├── safety_guard.dart        # 命令安全守卫
│   │   ├── credentials_store.dart   # 凭据加密存储
│   │   └── hive_init.dart           # 本地存储初始化
│   ├── models/                      # 数据模型
│   ├── providers/                   # Riverpod 状态管理
│   ├── services/                    # 服务层
│   │   ├── ai_service.dart          # AI 接口
│   │   ├── ssh_service.dart         # SSH 连接
│   │   ├── local_terminal_service.dart  # 本地终端
│   │   ├── command_executor.dart    # 统一执行接口
│   │   └── agent_engine.dart        # Agent 自动执行引擎
│   ├── pages/                       # 页面
│   ├── widgets/                     # 组件
│   └── utils/                       # 工具
├── assets/                          # 资源文件
│   ├── fonts/                       # JetBrains Mono 字体
│   └── icons/                       # 应用图标
└── pubspec.yaml
```

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
- [ ] v1.3.0 — 增强功能
  - [ ] SFTP 文件传输
  - [ ] 命令执行状态机 (Running/Success/Failed/Timeout)
  - [ ] 终端分屏
  - [ ] 主题自定义
- [ ] v1.2.0 — 生态拓展
  - [ ] 插件系统
  - [ ] 团队协作
  - [ ] 命令录制与回放

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

<p align="center">
  如果这个项目对你有帮助，请给个 ⭐ Star 支持一下！
</p>
