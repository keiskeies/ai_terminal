# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
