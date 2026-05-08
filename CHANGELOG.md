# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.1.0]: https://github.com/keiskeies/ai_terminal/releases/tag/v1.1.0
[1.0.0]: https://github.com/keiskeies/ai_terminal/releases/tag/v1.0.0
