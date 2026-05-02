# AI Terminal

AI-Powered Cross-Platform Terminal - 一个集成了 AI 助手的安全 SSH 终端应用。

## 功能特性

- **SSH 终端**: 支持多标签 SSH 连接，基于 dartssh2
- **AI 助手**: 自然语言转命令，支持流式响应
- **命令安全**: SafetyGuard 危险命令拦截，需二次确认
- **安全存储**: 凭据使用 flutter_secure_storage 加密存储
- **多平台**: 支持 Android、iOS、macOS、Windows、Linux

## 快速开始

1. 安装依赖:
```bash
cd ai_terminal
flutter pub get
```

2. 运行应用:
```bash
flutter run
```

3. 构建发布:
```bash
flutter build apk --release
flutter build ios --release
flutter build macos --release
```

## 安全设计

- **凭据隔离**: 密码/私钥存储在系统级安全存储，永不明文
- **命令拦截**: 高危命令自动拦截
- **二次确认**: 危险操作需输入 CONFIRM 确认
- **生物识别**: 支持 Face ID / 指纹解锁应用
