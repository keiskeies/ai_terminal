# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.1] - 2025-05-26

### Added
- 🌐 **20+ AI 供应商预设**：内置 20+ AI 供应商配置（国内 12 家 + 国际 8 家 + Ollama 本地 + 自定义）
  - 国内：DeepSeek / 通义千问 / 智谱GLM / Kimi / 豆包 / 小米MiMo / MiniMax / 硅基流动 / 阶跃星辰 / 百川 / 讯飞星火 / 腾讯混元
  - 国际：OpenAI / Claude / Gemini / xAI Grok / Mistral / OpenRouter / Groq
  - 本地：Ollama（无需 API Key，完全免费）
- 🔄 **远程供应商配置更新**：从服务器拉取最新供应商列表和模型信息，无需发版即可更新
- 🏷️ **供应商描述与定价**：选择供应商时显示简介和定价信息
- 🤖 **预设模型快捷选择**：每个供应商内置推荐模型列表，点击 Chip 一键选择，免费模型带 🆓 标识
- 🦙 **Ollama 本地部署支持**：显式支持 Ollama 供应商，修正 API 端点路径
- 📐 **添加模型弹窗优化**：
  - 宽屏（≥600px）双列布局，窄屏保持单列
  - 字段顺序调整：提供商 → 名称 → Base URL → API Key → 模型名称
  - 选择供应商自动填充 Base URL
  - 供应商下拉框旁增加刷新按钮

### Changed
- 供应商配置从硬编码改为 JSON 配置文件驱动（assets/config/ai_providers.json）
- AIModelConfig 的 providerIcon/providerColorValue 改为从 ProviderConfigService 动态获取
- 模型配置弹窗从 AlertDialog 改为 Dialog，支持自定义宽度

## [1.3.0] - 2025-05-08

### Added
- 🧠 **Agent 知识库系统**：基于 SQLite FTS5 全文搜索的软件安装知识库
  - 支持 strict（强制执行）和 suggest（推荐参考）两种模式
  - 知识库命中时自动注入 LLM 提示词，确保使用正确的包管理器
  - 知识库未命中时禁止使用搜索类命令（如 apt search），防止猜测
  - 本地检索响应 < 50ms，支持 10,000+ 条目
- 🔄 **远程知识库同步**：启动时自动从 GitHub Releases 下载最新 knowledge.db
  - 支持离线使用：下载失败时使用内置版本
  - 只更新数据、不升级代码的长期维护模式
- 🛡️ **LLM 安全规则**：系统提示词新增知识库安全规则
  - 知识库 strict 模式必须原样执行
  - 禁止搜索类命令防止猜测安装方式
  - 无法确定安装方式时必须拒绝并提示
- 🔧 **知识库构建工具**：提供 CSV → SQLite 转换脚本（tools/csv_to_knowledge.py）

## [1.2.1] - 2025-05-08

### Added
- 📁 SFTP 面板：桌面端嵌入终端右侧，支持拖拽调整宽度
- 📝 远程文件编辑：支持预览和编辑服务器文本文件，保存后回写
- 📤 文件上传功能
- 🔀 文件排序：按名称/大小/修改时间排序，支持升序/降序
- 🏠 路径导航：可点击面包屑 + 路径输入框，快速跳转目录

### Changed
- 📊 文件条目信息顺序调整：大小 → 修改时间 → 权限
- 🔧 SFTP 面板 per-tab 独立，切换服务器不再重连
- 🔧 路径面包屑去掉双斜杠，紧贴返回按钮

### Fixed
- 🐛 修复 SFTP 按钮点击无反应（从首页进入终端时 hostId 为 null）
- 🐛 修复 tab 切换时 SFTP 面板重建导致重连
- 🐛 修复 Offstage 子组件抢焦点导致 AI 输入框无法打字
- 🐛 修复文件上传按钮点击无反应

## [1.2.0] - 2025-05-07

### Changed
- 🧠 Agent 对话历史持久化：跨任务保留上下文，多轮对话不再丢失关联
- 📋 查询类命令（grep/find/cat 等）输出不再截断，Agent 可定位完整问题
- 🔄 最大执行步骤数默认无限制，复杂任务不会被中断
- 🔧 Agent 对话历史轮数提升至 10 轮，消息截断上限 1500 字符

### Fixed
- 🐛 修复 Agent 多轮对话上下文丢失问题（每次 startTask 重建消息列表）
- 🐛 修复流式输出缓冲区竞态条件导致消息消失

## [1.1.0] - 2025-05-06

### Added
- 🎨 AI panel layout redesign: Chrome DevTools-style divider with gradient line
- 📱 Mobile auto-orientation: landscape → AI right, portrait → AI bottom
- 🟢 Agent mode green accent color across UI (input border, send button, divider)
- 🔤 Input box focus border color follows AI/Agent mode accent color
- 🎯 AI panel position restricted to bottom/right only, always visible

### Changed
- Divider background color differentiated from AI panel background
- Improved divider gradient line brightness and visibility
- Mobile: hidden position buttons and drag handle for cleaner UI
- "下" button uses rotated "右" button icon for consistency

## [1.0.0] - 2025-05-02

### Added
- 🎉 Initial release of AI Terminal
- 🤖 Dual-mode AI Agent (Auto Mode + Assistant Mode)
- 🛡️ SafetyGuard 3-level command safety check (blocked/warn/info)
- 🔐 Zero-plaintext credential storage via flutter_secure_storage
- 📡 SSH remote terminal with connection pooling and reference counting
- 💻 Local PTY terminal support (macOS/Linux/Windows)
- 🌊 Streaming AI response with real-time rendering
- 🎨 Dark theme with JetBrains Mono font
- 📱 Cross-platform support: macOS, Linux, Windows, Android, iOS
- 🔄 Multi-tab terminal with shared SSH connections
- 🧠 OpenAI-compatible API support (DeepSeek, Qwen, GPT, etc.)
- 📋 Quick command snippets with variable substitution
- 🔒 Optional app lock with biometric authentication
- 📊 Operation audit logging
- 🎯 Agent behavior boundary constraints

### Security
- Passwords and private keys stored in system Keychain/Keystore only
- Dangerous commands (rm -rf /, dd, fork bombs) are blocked by default
- Warning-level commands require explicit CONFIRM input
- AES secondary encryption available for enhanced security

[1.3.1]: https://github.com/keiskeies/ai_terminal/releases/tag/v1.3.1
[1.3.0]: https://github.com/keiskeies/ai_terminal/releases/tag/v1.3.0
[1.2.1]: https://github.com/keiskeies/ai_terminal/releases/tag/v1.2.1
[1.2.0]: https://github.com/keiskeies/ai_terminal/releases/tag/v1.2.0
[1.1.0]: https://github.com/keiskeies/ai_terminal/releases/tag/v1.1.0
[1.0.0]: https://github.com/keiskeies/ai_terminal/releases/tag/v1.0.0
