# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/keiskeies/ai_terminal/releases/tag/v1.0.0
