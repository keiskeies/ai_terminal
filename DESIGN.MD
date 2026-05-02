# 🚀 AI-Terminal 完整开发指令集（AI Coding专用·最终版）

> **使用说明**：
> 1. 按顺序将每个「Step」单独发送给 AI Coding 工具
> 2. 每个 Step 都是完整可执行的 Prompt，已整合安全/连接池/校验等关键修复
> 3. 技术选型、UI参数、数据模型、验收标准全部锁定，AI 无需猜测
> 4. 每步完成后验证✅验收标准，再进入下一步

---

## 🎨 设计系统规范（所有 Step 共用）

```dart
// lib/core/constants.dart - 直接复制使用

// ===== 颜色 =====
const Color cBg = Color(0xFF0F0F0F);        // 页面背景
const Color cCard = Color(0xFF1A1A1A);      // 卡片/组件背景
const Color cBorder = Color(0xFF2A2A2A);    // 边框/分割线
const Color cTextMain = Color(0xFFE5E5E5);  // 主文字
const Color cTextSub = Color(0xFFA3A3A3);   // 次文字
const Color cPrimary = Color(0xFF6366F1);   // 主题色
const Color cPrimaryDark = Color(0xFF4F46E5);
const Color cSuccess = Color(0xFF22C55E);   // 在线/成功
const Color cDanger = Color(0xFFEF4444);    // 离线/危险/高危
const Color cWarning = Color(0xFFF59E0B);   // 警告
const Color cTerminalBg = Color(0xFF0C0C0C);
const Color cTerminalGreen = Color(0xFF4ADE80);

// ===== 尺寸 =====
const double rCard = 12.0;      // 卡片圆角
const double rButton = 8.0;     // 按钮圆角
const double rInput = 8.0;      // 输入框圆角
const double pStandard = 16.0;  // 标准内边距
const double pCompact = 12.0;   // 紧凑内边距
const double hAppBar = 56.0;    // AppBar 高度
const double hTabBar = 40.0;    // 标签栏高度

// ===== 字体 =====
const double fTitle = 18.0;     // 标题
const double fBody = 14.0;      // 正文
const double fSmall = 12.0;     // 小字
const double fMono = 13.0;      // 等宽字体（终端）

// ===== 动画 =====
const Duration animFast = Duration(milliseconds: 150);
const Duration animNormal = Duration(milliseconds: 300);
```

---

## Step 1：项目骨架 + 安全存储 + 数据模型

```
🎯 任务范围
创建 Flutter 项目，配置主题/路由/本地存储，实现系统级加密的凭据存储方案，定义所有数据模型。

📦 依赖配置（pubspec.yaml）
```yaml
name: ai_terminal
description: AI-Powered Cross-Platform Terminal
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.2.0 <4.0.0'
  flutter: '>=3.16.0'

dependencies:
  flutter:
    sdk: flutter
  # 状态管理
  flutter_riverpod: ^2.4.0
  # 路由
  go_router: ^12.0.0
  # 本地存储
  hive: ^2.2.3
  hive_flutter: ^1.1.0
  # 加密存储（系统级）
  flutter_secure_storage: ^9.0.0
  # 二次加密（可选增强）
  encrypt: ^5.0.1
  # 工具
  uuid: ^4.0.0
  collection: ^1.17.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0
  hive_generator: ^2.0.0
  build_runner: ^2.4.0

flutter:
  uses-material-design: true
  fonts:
    - family: JetBrainsMono
      fonts:
        - asset: assets/fonts/JetBrainsMono-Regular.ttf
        - asset: assets/fonts/JetBrainsMono-Bold.ttf
          weight: 700
```

🗂️ 文件清单（严格按此路径创建）
```
lib/
├── main.dart
├── core/
│   ├── constants.dart          # 设计系统常量（见上文）
│   ├── theme.dart              # ThemeData 配置
│   ├── router.dart             # GoRouter 配置
│   ├── hive_init.dart          # Hive 初始化 + Adapter 注册
│   ├── credentials_store.dart  # ✅ 系统级凭据存储（关键）
│   └── safety_guard.dart       # ✅ 命令安全校验规则
├── models/
│   ├── host_config.dart        # 服务器配置（不含明文密码）
│   ├── ai_model_config.dart    # AI 模型配置
│   ├── chat_session.dart       # 聊天会话
│   └── command_snippet.dart    # 快捷命令模板
└── providers/
    └── app_providers.dart      # Riverpod 根 Provider
```

🔐 核心文件1：lib/core/credentials_store.dart（系统级加密）
```
类名: CredentialsStore
职责: 使用 flutter_secure_storage 存储敏感凭据，密钥永不落地明文

实现要求:
• 使用 FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true))
• 存储 key 格式: "cred:{hostId}:{type}"，type 为 'password' 或 'privateKey'
• 提供静态方法:
  - Future<void> save({required String hostId, required String type, required String value})
  - Future<String?> get({required String hostId, required String type})
  - Future<void> delete({required String hostId, required String type})
• 可选增强: 内部再用 encrypt 包做一层 AES 加密（使用固定 salt + PBKDF2 派生密钥）
• 所有方法加 try-catch，解密失败返回 null，不抛异常
```

🗂️ 核心文件2：lib/models/host_config.dart（元数据 + 凭据引用）
```
@HiveType(typeId: 0)
class HostConfig {
  @HiveField(0) late String id;              // uuid，主键
  @HiveField(1) late String name;            // 显示名称
  @HiveField(2) late String host;            // IP/域名
  @HiveField(3) int port = 22;               // SSH 端口
  @HiveField(4) late String username;        // 登录用户
  
  // ✅ 认证方式（关键：不存明文密码）
  @HiveField(10) late String authType;       // 'password' | 'privateKey'
  @HiveField(11) String? credentialsRef;     // 凭据在 CredentialsStore 的 key（可选，可动态生成）
  
  // ✅ 其他配置
  @HiveField(20) String group = "默认";       // 分组
  @HiveField(21) String? tagColor;           // 标签颜色 hex
  @HiveField(22) String? jumpHost;           // 跳板机 hostId
  @HiveField(23) int timeout = 30;           // 连接超时(秒)
  @HiveField(24) String encoding = "utf-8";  // 字符编码
  
  // ✅ 元数据
  @HiveField(30) late DateTime createdAt;
  @HiveField(31) DateTime? lastConnectedAt;
  @HiveField(32) String? lastStatus;         // 'success' | 'failed' | 'timeout'
  
  // ✅ 便捷方法：生成 credentialsRef
  String get credKey => 'cred:$id';
}
```

🗂️ 其他模型（简要字段，按此定义）
```
// ai_model_config.dart @HiveType(typeId: 1)
{ id, provider('openai'|'qwen'|'ernie'), name, apiKey, baseUrl, modelName, temperature(0.3), maxTokens(4096), isDefault }

// chat_session.dart @HiveType(typeId: 2)
ChatSession { id, hostId?, messages: List<ChatMessage>, createdAt, updatedAt }
ChatMessage { role('user'|'assistant'|'system'), content, timestamp, commandBlocks: List<CommandBlock> }
CommandBlock { command, description?, dangerous(bool), safetyLevel('safe'|'warn'|'blocked') }

// command_snippet.dart @HiveType(typeId: 3)
{ id, name, command, description?, variables: List<String> }
```

🔐 核心文件3：lib/core/safety_guard.dart（命令安全校验）
```
类名: SafetyGuard
职责: 静态校验命令危险等级，拦截高危操作

实现要求:
• 定义三个正则列表:
  - _blockPatterns: 直接拒绝的命令
    [r'^rm\s+-rf\s+/$', r'^dd\s+if=.*of=/dev/', r'^:\(\)\{\s*:\|\:&\s*\};:', r'chmod\s+-R\s+777\s+/']
  - _warnPatterns: 需二次确认 + 输入"CONFIRM" 的命令
    [r'^sudo\s+(reboot|shutdown|mkfs|fdisk)', r'^systemctl\s+(stop|disable)\s+ssh', r'^(iptables|firewall-cmd).*(-F|--flush)']
  - _infoPatterns: 仅高亮提示的命令
    [r'(curl|wget|git clone)', r'(firewall-cmd|ufw|iptables).*port', r'systemctl\s+(start|restart)']

• 枚举: enum SafetyLevel { safe, info, warn, blocked }

• 静态方法:
  - SafetyLevel check(String command): 返回命令等级
  - String getTip(SafetyLevel level): 返回对应提示文案
  - bool requireConfirm(SafetyLevel level): 是否需要二次确认

• 所有正则忽略大小写，匹配命令主体（可先 strip 掉注释和管道符）
```

🎨 主题配置：lib/core/theme.dart
```
AppTheme 类，提供 static ThemeData get darkTheme:
• 基于 ThemeData.dark()
• scaffoldBackgroundColor = cBg
• appBarTheme: backgroundColor=cCard, elevation=0, titleTextStyle=white/18px/500
• cardTheme: color=cCard, elevation=0, shape=RoundedRectangleBorder(borderRadius: rCard)
• inputDecorationTheme: 
  - fillColor=cCard, filled=true
  - border: OutlineInputBorder(borderRadius: rInput, borderSide: cBorder)
  - focusedBorder: same but borderSide=cPrimary/2px
• textTheme: bodyMedium=cTextMain/14px, bodySmall=cTextSub/12px
• elevatedButtonTheme: backgroundColor=cPrimary, foregroundColor=white, shape: rButton
```

🚦 路由配置：lib/core/router.dart
```
使用 GoRouter，定义路由:
• '/' → HostListPage
• '/host/edit' → HostEditPage (新建)
• '/host/edit?id=xxx' → HostEditPage (编辑)
• '/terminal/:hostId' → TerminalPage
• '/chat' → ChatPage (可选 ?hostId= 参数)
• '/settings' → SettingsPage
• '/settings/ai' → AIModelsPage
• '/snippets' → SnippetsPage

所有页面初始为占位空页面（Scaffold + Center + Text），后续步骤实现
```

🗄️ Hive 初始化：lib/core/hive_init.dart
```
Future<void> initHive() async {
  await Hive.initFlutter();
  // 注册 Adapter（用 hive_generator 生成）
  Hive.registerAdapter(HostConfigAdapter());
  Hive.registerAdapter(AIModelConfigAdapter());
  Hive.registerAdapter(ChatSessionAdapter());
  Hive.registerAdapter(ChatMessageAdapter());
  Hive.registerAdapter(CommandBlockAdapter());
  Hive.registerAdapter(CommandSnippetAdapter());
  
  // 打开 boxes
  await Hive.openBox<HostConfig>('hosts');
  await Hive.openBox<AIModelConfig>('aiModels');
  await Hive.openBox<ChatSession>('chatSessions');
  await Hive.openBox<CommandSnippet>('snippets');
}
```

🧪 验收标准（必须全部满足）
- [ ] `flutter run` 启动成功，显示暗色主题，无红色报错
- [ ] Hive 初始化无异常，所有 Adapter 注册成功
- [ ] CredentialsStore.save/get 能正确读写，重启后数据不丢失
- [ ] HostConfig 模型不包含 password/privateKey 明文字段（代码审查确认）
- [ ] SafetyGuard.check() 单元测试通过（覆盖 block/warn/safe 三类命令）
- [ ] 所有模型能正常序列化/反序列化（写 test/models_test.dart）

💡 给 AI 的提示词结尾
```
请严格按上述文件路径、类名、方法签名实现。
关键：密码/密钥必须走 CredentialsStore，Hive 只存元数据。
完成后输出：✅ Step 1 完成，项目骨架 + 安全存储已就绪
```

---

## Step 2：主机管理页面（增删改查 + 分组）

```
🎯 任务范围
实现服务器列表页、新建/编辑表单、分组展示、状态指示。数据持久化到 Hive + CredentialsStore。

🗂️ 文件清单
```
lib/
├── providers/
│   └── host_provider.dart      # StateNotifier 管理主机列表
├── pages/
│   ├── host_list_page.dart     # 主机列表页（首页）
│   └── host_edit_page.dart     # 新建/编辑主机页
├── widgets/
│   ├── host_card.dart          # 主机卡片组件
│   ├── color_picker_row.dart   # 标签颜色选择器
│   └── quick_connect_sheet.dart # 快速连接底部弹窗
└── utils/
    └── form_validators.dart    # 表单验证工具
```

📊 状态管理：lib/providers/host_provider.dart
```
类: HostNotifier extends StateNotifier<AsyncValue<List<HostConfig>>>

方法:
• Future<void> loadHosts() 
  - 从 Hive box 'hosts' 读取，按 createdAt 倒序
  - state = AsyncValue.data(list)

• Future<void> addHost(HostConfig config, {String? password, String? privateKey})
  - 1. 验证必填字段（name/host/username/authType）
  - 2. 如果 authType=='password' 且 password!=null: CredentialsStore.save(hostId: config.id, type: 'password', value: password)
  - 3. 如果 authType=='privateKey' 且 privateKey!=null: CredentialsStore.save(hostId: config.id, type: 'privateKey', value: privateKey)
  - 4. 保存 config 到 Hive box 'hosts'
  - 5. 刷新列表

• Future<void> updateHost(HostConfig config, {String? password, String? privateKey})
  - 类似 addHost，先更新 Hive，再更新凭据（如果传入新值）

• Future<void> deleteHost(String id)
  - 1. 从 Hive 删除 config
  - 2. CredentialsStore.delete(hostId: id, type: 'password')
  - 3. CredentialsStore.delete(hostId: id, type: 'privateKey')
  - 4. 刷新列表

• Map<String, List<HostConfig>> getHostsByGroup()
  - 按 config.group 分组，返回 Map，用于 UI 渲染
```

🖼️ 主机列表页：lib/pages/host_list_page.dart
```
UI 结构:
• AppBar: 
  - title: "服务器" (18px/white/500)
  - actions: [IconButton(Icons.add, onTap: → /host/edit)]

• 搜索栏 (padding: 16):
  - TextField: height=48, decoration: fillColor=cCard, borderRadius=rInput, prefixIcon: Icons.search, hintText: "搜索服务器..."

• 分组列表 (ListView.builder):
  - 每组一个 ExpansionTile (默认展开):
    • title: Row[Icon(Icons.folder, color=cPrimary), Text(groupName, 16px/white), Spacer, Container(徽章: 背景 cPrimary, 圆角 12, padding: 4/8, Text(数量, 12px/white))]
    • children: 该组主机卡片列表

• 主机卡片 (lib/widgets/host_card.dart):
  - Container: height=72, margin: 16/8, decoration: color=cCard, borderRadius=rCard
  - Row:
    • 左侧: 状态圆点 (Container: size=10, 圆形, 颜色: 在线=cSuccess/离线=cDanger/未连接=cTextSub)
    • 中间 (Expanded):
      - Text(host.name, 16px/white/500)
      - Text("${host.host}:${host.port} · ${host.username}", 13px/cTextSub)
      - 如果 host.tagColor!=null: Padding(top:4, child: Container(高度 4, 宽度 32, 圆角 2, 背景=host.tagColor))
    • 右侧: PopupMenuButton(图标: Icons.more_vert, 颜色: cTextSub):
      [编辑 → /host/edit?id=xxx]
      [删除 → 弹出确认对话框]
      [复制配置]
      [SFTP (占位，显示"开发中")]

• 空状态 (当列表为空时):
  - Center: Column[Icon(Icons.storage, 64px, cTextSub), Text("暂无服务器", 14px, cTextSub), ElevatedButton("添加服务器", onTap: → /host/edit)]

交互:
• 点击卡片: 导航到 /terminal/${host.id}
• 长按卡片 (移动端) / 右键 (桌面端): 弹出编辑/删除菜单
• 下拉刷新: 调用 hostProvider.loadHosts()
```

📝 编辑主机页：lib/pages/host_edit_page.dart
```
路由: /host/edit (新建) 或 /host/edit?id=xxx (编辑)

表单字段 (ListView + Padding(16), 间距 16):
1. 名称*: TextFormField (验证: 非空, 最大 20 字)
2. 主机地址*: TextFormField (验证: 非空, 支持 IP/域名)
3. 端口: TextFormField (默认"22", keyboardType: numberOnly)
4. 用户名: TextFormField (默认"root")
5. 认证方式*: DropdownButtonFormField<String>(
     选项: ['密码', '私钥'],
     onChanged: 切换显示下方条件字段
   )
6. 条件字段:
   • 选"密码": 
     - TextFormField (obscureText: true, decoration: suffixIcon: IconButton(Icons.visibility))
     - CheckboxListTile("保存到安全存储", 默认勾选, 禁用状态)
   • 选"私钥":
     - ListTile(标题: "私钥内容", trailing: TextButton("📁 选择文件" / "📋 粘贴"))
     - 如果选"粘贴": 显示 TextFormField (maxLines: 6, hintText: "-----BEGIN OPENSSH PRIVATE KEY-----\n...")
     - 可选: TextFormField (obscureText: true, labelText: "私钥密码 (passphrase, 可选)")
7. 分组: TextFormField (默认"默认", 支持输入或从历史选择)
8. 标签颜色: lib/widgets/color_picker_row.dart
   - 一行 6 个圆形按钮 (直径 32), 颜色: [红, 橙, 黄, 绿, 蓝, 紫]
   - 选中状态: 外圈 2px 白色描边 + 中心对勾图标
9. 高级设置 (ExpansionTile, 默认折叠):
   - 连接超时: Slider (10-120 秒, 默认 30, divisions: 11)
   - 字符编码: DropdownButton (选项: utf-8, gbk, big5)
   - 跳板机: DropdownButton (从已有主机选择, 排除自身)

底部操作栏 (固定底部, height=64, padding: 16):
• Row:
  - Expanded: OutlinedButton("取消", 边框: cBorder, 文字: cTextSub, onTap: Navigator.pop)
  - SizedBox(width: 12)
  - Expanded(2): ElevatedButton(
      "💾 保存", 
      backgroundColor: cPrimary,
      enabled: 表单验证通过,
      onTap: 保存逻辑
    )

保存逻辑:
• 收集表单数据 → 构建 HostConfig (id 用 uuid.v4() 新建或从路由参数获取)
• 如果密码/私钥字段有值且"保存"勾选: 调用 CredentialsStore.save()
• 调用 hostProvider.addHost() 或 updateHost()
• 成功: Navigator.pop() + SnackBar("保存成功")
• 失败: 显示错误 SnackBar
```

🧪 验收标准
- [ ] 能新建/编辑/删除主机，数据持久化到 Hive + CredentialsStore
- [ ] 删除主机时，凭据同步从 CredentialsStore 清理
- [ ] 分组展示正确，ExpansionTile 展开/收起流畅
- [ ] 认证方式切换时，密码/私钥字段条件渲染正常
- [ ] 表单验证: 必填项空时保存按钮禁用，错误提示清晰
- [ ] 空状态显示正常，点击"添加服务器"跳转编辑页

💡 给 AI 的提示词结尾
```
请严格按上述 UI 参数和交互逻辑实现。
关键：保存主机时，密码/私钥走 CredentialsStore，元数据走 Hive。
完成后输出：✅ Step 2 完成，主机管理功能已就绪
```

---

## Step 3：SSH 终端页面（连接池 + 流式输出）

```
🎯 任务范围
实现基于 dartssh2 的 SSH 连接，支持连接池复用、流式命令输出、多标签管理。

📦 新增依赖（pubspec.yaml）
```yaml
dependencies:
  dartssh2: ^2.8.2          # SSH 客户端
  xterm: ^3.0.0             # 终端组件
  google_fonts: ^6.1.0      # 等宽字体
```

🗂️ 文件清单
```
lib/
├── services/
│   ├── ssh_service.dart        # 单连接封装
│   └── ssh_connection_pool.dart # ✅ 连接池管理（关键）
├── providers/
│   └── terminal_provider.dart  # 管理多标签状态
├── pages/
│   └── terminal_page.dart      # 终端主页面
├── widgets/
│   ├── terminal_view.dart      # xterm 封装组件
│   ├── tab_bar_widget.dart     # 多标签栏 (桌面端)
│   └── terminal_input_bar.dart # 底部命令输入栏
└── utils/
    └── terminal_encoder.dart   # 字符编码转换工具
```

🔗 核心文件1：lib/services/ssh_service.dart（单连接封装）
```
类: SSHService
职责: 封装单个 SSH 连接的生命周期

构造函数: SSHService(HostConfig config)

属性:
• StreamController<String> outputController = StreamController.broadcast()  // 输出流
• bool get isConnected → 当前连接状态
• String get osInfo → 连接后获取的系统信息 (如 "CentOS 7 x86_64")

方法:
• Future<void> connect({String? password, String? privateKeyContent})
  - 使用 dartssh2.SSHClient.connect(config.host, config.port)
  - 认证: 
    • password != null → SSHPasswordAuthenticator((String user) => password)
    • privateKeyContent != null → SSHKeyPair.fromPem(privateKeyContent)
  - 连接成功后: 
    • 执行 `echo "AI-Terminal-OK"` 验证连通性
    • 执行 `uname -s -m; whoami; pwd` 获取 osInfo
    • 打开 Shell: session.shell()，监听 stdout → outputController.add()
  - 错误处理: 捕获 SocketException/SSHException，抛友好异常

• void execute(String command)
  - 通过 session.run(command) 执行
  - 输出实时写入 outputController

• void resize(int columns, int rows)
  - 调用 session.resizeTerminal(columns, rows) 适配终端大小

• Future<void> disconnect()
  - 关闭 session + socket，清理资源
```

🔗 核心文件2：lib/services/ssh_connection_pool.dart（✅ 连接池，关键修复）
```
类: SSHConnectionPool
职责: 按 hostId 管理 SSH 连接，支持多标签复用 + 引用计数

实现要求:
• 内部缓存: static final Map<String, _PoolEntry> _pool = {}

• _PoolEntry 类: { SSHService service, int refCount, DateTime lastActive }

• 静态方法:
  - Future<SSHService> acquire(String hostId, HostConfig config, {String? password, String? privateKey})
    • 如果 _pool 中有该 hostId: refCount++, 更新 lastActive, 返回已有 service
    • 否则: 新建 SSHService, 调用 connect(), 存入 _pool, refCount=1, 返回
  
  - void release(String hostId)
    • 如果 _pool 中有: refCount--, 如果<=0: 调用 service.disconnect() 并移除缓存
  
  - void startIdleCleanup(Duration timeout)  // 可选增强
    • 定时任务: 每 5 分钟检查 _pool, 如果 refCount==0 且 lastActive 超过 timeout, 自动 disconnect + 移除

• 注意: 所有方法线程安全 (用 synchronized 或 compute 隔离)
```

📊 状态管理：lib/providers/terminal_provider.dart
```
类: TerminalNotifier extends StateNotifier<TerminalState>

TerminalState 类: { List<TerminalTab> tabs, String? activeTabId }

TerminalTab 类: { String id, String hostId, String title, bool isConnected, SSHService? service }

方法:
• void openTab(String hostId, HostConfig config)
  - 调用 SSHConnectionPool.acquire(hostId, config, ...) 获取 service
  - 创建新 TerminalTab, 加入 tabs, 设为 active
  - 监听 service.outputController → 更新对应 tab 的输出缓冲

• void closeTab(String tabId)
  - 找到 tab, 调用 SSHConnectionPool.release(tab.hostId)
  - 从 tabs 移除, 如果关闭的是 active: 激活最后一个或置空

• void sendCommand(String tabId, String command)
  - 找到 tab.service?.execute(command)

• void resizeTab(String tabId, int columns, int rows)
  - 找到 tab.service?.resize(columns, rows)

• void setActiveTab(String tabId) → 切换激活标签
```

🖥️ 终端页面：lib/pages/terminal_page.dart
```
路由: /terminal/:hostId (从主机列表进入时自动打开新标签)

UI 结构:
• AppBar (height=56, background=cCard):
  - 左侧: 返回箭头 (移动端) / 主机下拉选择 (桌面端)
  - 中间: 
    • Text(host.name, 16px/white/500)
    • Text("${config.username}@${config.host}", 12px/cTextSub, below)
  - 右侧: 
    • 连接状态圆点 (8px, 在线绿/离线红)
    • PopupMenuButton: [重连] [关闭标签] [清空屏幕] [SFTP(占位)]

• 主体 (Expanded):
  - 桌面端: Column[TabBarWidget, Expanded(TerminalView)]
  - 移动端: 直接 TerminalView (标签管理放 Drawer 或底部弹窗)

• TerminalView (lib/widgets/terminal_view.dart):
  - 使用 xterm.Terminal 组件
  - 配置: 
    • theme: { background: cTerminalBg, foreground: cTerminalGreen, cursor: cPrimary }
    • fontSize: fMono, fontFamily: 'JetBrainsMono'
    • cursorBlink: true, scrollback: 10000
  - 绑定: terminal.onData → terminalProvider.sendCommand()
  - 输出: 监听 terminalProvider 的输出流 → terminal.write()

• 底部输入栏 (lib/widgets/terminal_input_bar.dart, height=56):
  - Row:
    • Expanded: TextField(
        decoration: InputDecoration(
          hintText: "输入命令...",
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 16)
        ),
        style: TextStyle(color: cTextMain, fontSize: fBody),
        onSubmitted: (cmd) → send + clear
      )
    • IconButton(Icons.send, color: cPrimary, onPressed: send)

交互:
• 支持触摸滚动 (移动端) / 鼠标滚轮 (桌面端)
• 支持文本选择 + 复制 (长按/鼠标拖拽)
• 支持粘贴 (Ctrl+V / 长按粘贴菜单)
• 连接断开时: 显示红色状态点 + 顶部横幅"连接中断 [重连]"
```

🧪 验收标准
- [ ] 能成功连接测试服务器 (密码 + 私钥两种方式)
- [ ] 终端实时显示命令输出，中文不乱码 (测试: echo "中文测试")
- [ ] 底部输入栏能发送命令，支持回车/点击发送
- [ ] 多标签打开不同主机，输出隔离不串扰
- [ ] 关闭标签时连接正确释放 (连接池引用计数生效)
- [ ] 网络断开后，状态点变红，点击重连能恢复

💡 给 AI 的提示词结尾
```
请严格按上述连接池设计实现，避免多标签重复建立连接。
关键：SSHConnectionPool.acquire/release 必须配对调用。
完成后输出：✅ Step 3 完成，SSH 终端功能已就绪
```

---

## Step 4：AI 聊天面板（流式响应 + 多模型）

```
🎯 任务范围
实现 AI 对话 UI、OpenAI 兼容接口、流式响应、多模型配置管理。

📦 新增依赖（pubspec.yaml）
```yaml
dependencies:
  dio: ^5.4.0              # HTTP 客户端
  flutter_markdown: ^0.6.18 # 渲染 AI 回复 (支持代码块)
```

🗂️ 文件清单
```
lib/
├── services/
│   └── ai_service.dart         # AI 提供商统一接口 + OpenAI 实现
├── providers/
│   └── chat_provider.dart      # 管理聊天状态 + 消息持久化
├── pages/
│   ├── chat_page.dart          # AI 聊天主页面
│   └── ai_models_page.dart     # AI 模型配置页
├── widgets/
│   ├── message_bubble.dart     # 消息气泡组件
│   ├── code_block.dart         # 代码块高亮组件
│   └── typing_indicator.dart   # AI 思考中动画
├── core/
│   └── prompts.dart            # ✅ 系统提示词模板 (关键)
└── utils/
    └── markdown_parser.dart    # 解析 AI 回复中的代码块
```

🧠 核心文件：lib/core/prompts.dart（✅ 系统提示词，关键）
```
const String systemPrompt = """
你是一个专业的 Linux 运维助手，负责将用户自然语言转换为安全的 shell 命令。

【输出格式要求】
1. 先简要分析用户意图和当前环境 (1-2 句话)
2. 生成命令列表，每条命令用 ```bash 代码块包裹，附带中文注释
3. 标注潜在风险 (如: 修改系统配置、网络下载、端口开放)
4. 提供验证步骤和回滚方案 (如适用)

【安全约束】
• 优先使用包管理器 (apt/yum/dnf)，避免源码编译
• 对于已停止维护的系统 (如 CentOS7)，必须提示风险并提供替代方案
• 涉及网络操作时，自动检测并建议国内镜像源 (如服务器在中国)
• 修改系统配置前，必须生成备份命令
• 禁止生成: rm -rf /, dd, chmod 777, :(){:|:&};: 等高危命令

【当前环境】
{context}  // 调用时动态替换: 操作系统/用户/当前目录/Shell 类型
""";
```

🤖 AI 服务：lib/services/ai_service.dart
```
抽象类: AIProvider
• Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,  // 默认用 prompts.systemPrompt
  })

OpenAIProvider 实现:
• 请求: POST ${config.baseUrl}/chat/completions
• Headers: { 'Authorization': 'Bearer ${config.apiKey}', 'Content-Type': 'application/json' }
• Body: {
    "model": config.modelName,
    "messages": [
      {"role": "system", "content": systemPrompt},
      ...history.map((m) => {"role": m.role, "content": m.content}),
      {"role": "user", "content": prompt}
    ],
    "stream": true,
    "temperature": config.temperature,
    "max_tokens": config.maxTokens
  }
• 响应: 解析 SSE 流 (data: {...}), 提取 choices[0].delta.content
• 错误处理: 
  - 401: 抛 "API Key 无效"
  - 429: 抛 "请求限流，请稍后重试"
  - 网络错误: 抛 "连接失败，请检查网络"

工厂方法: AIProvider create(AIModelConfig config) → 根据 provider 字段返回对应实现
```

💬 聊天页面：lib/pages/chat_page.dart
```
路由: /chat (可选 ?hostId=xxx 关联主机)

UI 结构:
• AppBar:
  - title: "AI 助手"
  - actions: [IconButton(Icons.settings, onTap: → /settings/ai)]

• 消息列表 (ListView.builder, reverse: true, padding: 16):
  - 用户消息 (右对齐):
    • Container: maxWidth=80%, background=cPrimary, borderRadius: 12(左上 0), padding: 12/16
    • Text(content, 14px/white)
  
  - AI 消息 (左对齐):
    • Container: maxWidth=85%, background=cCard, borderRadius: 12(右上 0), padding: 12/16
    • 如果 content 含 ```bash: 用 flutter_markdown 渲染，代码块用 lib/widgets/code_block.dart 样式
    • 代码块样式: background=#2D2D2D, borderRadius=8, font=JetBrainsMono/13px/cTerminalGreen
  
  - AI 思考中: lib/widgets/typing_indicator.dart
    • 三个圆点 (cPrimary) 依次放大缩小动画

• 输入区 (固定在底部):
  - Container: background=cCard, borderRadius: rCard(上两角), padding: 8/16
  - TextField: 
    • maxLines: 5, minLines: 1, expands: false
    • decoration: border=none, hintText: "输入指令或问题..."
    • style: cTextMain/14px
  - 右侧: IconButton(Icons.send, color: enabled?cPrimary:cTextSub, onPressed: send)
  - 发送逻辑:
    • 如果输入空: 禁用发送按钮
    • 否则: 清空输入框 → 添加用户消息 → 调用 chatProvider.sendMessage() → 显示思考中

交互:
• 消息列表自动滚动到底部 (新增消息时)
• 长按消息: 弹出 [复制] 菜单
• 代码块: 点击右上角"复制"按钮复制命令
• 下拉刷新: 清空当前会话 (可选)
```

📊 状态管理：lib/providers/chat_provider.dart
```
类: ChatNotifier extends StateNotifier<ChatState>

ChatState: { List<ChatMessage> messages, bool isLoading, String? error, String? currentHostId }

方法:
• Future<void> sendMessage(String content, {String? hostId})
  - 1. 构建 messages: 最近 10 条 + systemPrompt (含 host 上下文)
  - 2. 调用 aiService.chatStream()
  - 3. 流式更新: 每次收到 chunk → 追加到当前 AI 消息 → state = state.copyWith(messages: updated)
  - 4. 完成后: 保存到 Hive box 'chatSessions'
  - 5. 错误: state = state.copyWith(error: errorMsg)

• void loadSession(String? hostId) 
  - 从 Hive 加载最近会话，或新建空会话

• void clearSession() → 清空当前消息列表 (不删 Hive)

• 上下文增强: 如果 hostId != null:
  - 在 systemPrompt 后追加: "当前主机: ${osInfo}, 用户: ${username}, 目录: ${pwd}"
  - 可选: 追加终端最近 20 行输出 (截断到 2000 字符)
```

⚙️ 模型配置页：lib/pages/ai_models_page.dart
```
UI:
• ListView: 显示所有 AIModelConfig (从 Hive 加载)
• 每项: ListTile(
    leading: Icon(根据 provider 选颜色: openai=green, qwen=blue, ernie=purple),
    title: Text(config.name),
    subtitle: Text("${config.provider} / ${config.modelName}"),
    trailing: Radio(value: config.isDefault, onChanged: 设为默认),
    onTap: → 展开编辑面板
  )
• 编辑面板 (ExpansionTile 或 Dialog):
  - API Key: TextFormField(obscureText: true)
  - Base URL: TextFormField(hint: "https://api.openai.com/v1")
  - 模型名: TextFormField(hint: "gpt-4o")
  - 温度: Slider(0.0-1.0, divisions: 10)
  - Max Tokens: TextFormField(numberOnly)
• FAB: IconButton(Icons.add, onTap: 添加新模型)
• 左滑删除: Dismissible(关键: 如果删除的是 default, 自动设下一个为 default)
```

🧪 验收标准
- [ ] 能配置多个 AI 模型，切换默认模型生效
- [ ] 聊天能正常发送，AI 流式响应逐字显示 (无卡顿)
- [ ] 消息持久化到 Hive，重启后历史记录保留
- [ ] 代码块有独立样式，支持复制按钮
- [ ] 空输入时发送按钮禁用，错误时有友好提示
- [ ] 关联主机时，AI 回复能引用当前系统信息

💡 给 AI 的提示词结尾
```
请严格按 systemPrompt 模板实现，安全约束不可省略。
关键：流式响应必须用 Stream<String>，避免整段返回卡顿。
完成后输出：✅ Step 4 完成，AI 聊天功能已就绪
```

---

## Step 5：AI 命令执行闭环（核心功能）

```
🎯 任务范围
实现"自然语言 → AI 生成命令 → 安全校验 → 用户确认 → 执行 → 反馈"的完整闭环。

🗂️ 文件清单
```
lib/
├── widgets/
│   ├── command_block.dart      # ✅ 命令块组件 (带安全等级样式)
│   └── confirm_dialog.dart     # ✅ 分级确认对话框
├── utils/
│   ├── ai_parser.dart          # 解析 AI 回复中的命令块
│   └── audit_logger.dart       # 操作审计日志 (可选但推荐)
├── pages/
│   └── snippets_page.dart      # 快捷命令模板页
└── (修改) pages/terminal_page.dart  # 集成 AI 悬浮按钮 + ChatSheet
```

⚠️ 核心文件1：lib/widgets/command_block.dart（✅ 安全等级样式）
```
组件: CommandBlock
参数: { required CommandBlock data, required VoidCallback onExecute, required VoidCallback onCopy }

UI 结构:
• Container: 
  - decoration: BoxDecoration(
      color: Color(0xFF1E1E1E),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: cBorder)
    )
  - padding: EdgeInsets.all(12)

• 顶部栏 (Row):
  - Text("命令", 12px, cTextSub)
  - Spacer
  - 如果 data.safetyLevel == 'blocked': 
      Row[Icon(Icons.block, color: cDanger, size: 16), SizedBox(4), Text("高危操作已拦截", 12px, cDanger)]
    else if data.safetyLevel == 'warn':
      Row[Icon(Icons.warning, color: cWarning, size: 16), SizedBox(4), Text("需确认", 12px, cWarning)]

• 命令文本:
  - SelectableText(data.command, style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: fMono, color: cTerminalGreen))

• 底部按钮 (Row, spacing: 8):
  - OutlinedButton("复制", 
      style: OutlinedButton.styleFrom(foregroundColor: cTextSub, side: BorderSide(color: cBorder)),
      onPressed: onCopy + SnackBar("已复制")
    )
  - ElevatedButton(
      "执行",
      style: ElevatedButton.styleFrom(
        backgroundColor: data.safetyLevel == 'blocked' ? cTextSub : 
                        data.safetyLevel == 'warn' ? cWarning : cPrimary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: rButton)
      ),
      enabled: data.safetyLevel != 'blocked',
      onPressed: onExecute  // 内部会再弹确认框
    )
```

🔐 核心文件2：lib/widgets/confirm_dialog.dart（✅ 分级确认）
```
函数: Future<bool> showConfirmDialog(BuildContext context, CommandBlock cmd)

逻辑:
• 如果 cmd.safetyLevel == 'blocked': 
    直接返回 false + SnackBar("此命令被安全策略拦截")
  
• 如果 cmd.safetyLevel == 'warn':
    显示 AlertDialog:
      title: "⚠️ 危险操作确认"
      content: Column[
        Text("即将执行:", cTextSub),
        SelectableText(cmd.command, style: mono/cTerminalGreen),
        SizedBox(16),
        Text("请输入 CONFIRM 继续", 12px, cWarning),
        TextField(controller: _confirmController, decoration: hintText: "输入 CONFIRM")
      ]
      actions: [
        TextButton("取消", onTap: Navigator.pop(false)),
        ElevatedButton(
          "确认执行",
          enabled: _confirmController.text == "CONFIRM",
          style: ElevatedButton.styleFrom(backgroundColor: cDanger),
          onTap: Navigator.pop(true)
        )
      ]
    返回用户选择
  
• 如果 cmd.safetyLevel == 'safe' or 'info':
    显示简化版 AlertDialog:
      title: "确认执行命令"
      content: SelectableText(cmd.command)
      actions: [取消 / 确认]
    返回用户选择

• 可选增强 (移动端): 如果 SafetyGuard.requireConfirm(level) 且设备支持生物识别:
    在确认按钮点击后，先调用 local_auth 验证，通过才执行
```

🔍 命令解析：lib/utils/ai_parser.dart
```
类: AIParser
静态方法: List<CommandBlock> extractCommands(String aiContent)

解析规则:
• 用正则匹配 ```bash 代码块: RegExp(r'```bash\s*\n([\s\S]*?)\n```', multiLine: true)
• 对每个匹配:
  - 提取命令文本 (去掉首尾空白)
  - 按行分割，过滤空行和纯注释行
  - 对每行命令:
    • 调用 SafetyGuard.check(command) 获取 safetyLevel
    • 构建 CommandBlock(command: line, description: 从上下文提取?, dangerous: level!=safe, safetyLevel: level.name)
• 返回 CommandBlock 列表

增强: 如果 AI 回复含"验证:"或"回滚:"，单独提取到 CommandBlock.description
```

🔗 终端集成：修改 lib/pages/terminal_page.dart
```
• 右下角悬浮按钮 (仅当连接成功时显示):
  - FloatingActionButton(
      mini: true,
      backgroundColor: cPrimary,
      child: Icon(Icons.auto_fix_high),
      onPressed: _showAIChatSheet
    )

• _showAIChatSheet() 方法:
  - 显示底部弹窗 (height: 60% 屏幕, borderRadius: 16, background: cCard)
  - 内嵌简化版 ChatPage (复用 Step 4 组件，但: 
      • 自动传入当前 hostId 作为上下文
      • AI 回复中的命令块显示为 CommandBlock 组件
      • 点击 CommandBlock.onExecute: 
          1. showConfirmDialog() 获取用户确认
          2. 如果确认: terminalProvider.sendCommand(activeTabId, command)
          3. 执行后: 读取终端最近 20 行输出，追加到 AI 回复下方作为反馈
    )

• 执行反馈样式:
  - Container: margin-top: 8, padding: 8/12, background: Color(0xFF1A1A2E)
  - Text("执行结果:", 12px, cTextSub)
  - SelectableText(output, style: mono/cTextMain, maxLines: 10, overflow: ellipsis)
```

📝 快捷命令：lib/pages/snippets_page.dart
```
路由: /snippets

UI:
• ListView: 显示 CommandSnippet 列表
• 每项: ListTile(
    title: Text(snippet.name),
    subtitle: Text(snippet.command, maxLines: 1, overflow: ellipsis, style: mono),
    trailing: IconButton(Icons.play_arrow, onTap: → 执行),
    onTap: → 显示详情对话框
  )

• 详情对话框:
  - 标题: snippet.name
  - 命令预览: SelectableText(snippet.command, style: mono)
  - 如果 snippet.variables 非空: 
      为每个变量显示 TextFormField (label: "{{var}}", hint: "替换值")
  - 按钮: [复制到剪贴板] [发送到当前终端] [取消]

• 执行逻辑:
  - 替换变量: command.replaceAll("{{var}}", inputValue)
  - 如果"发送到终端": 调用 terminalProvider.sendCommand()
  - 记录到审计日志 (如果启用)
```

🧪 验收标准
- [ ] 在终端页点击悬浮按钮，能打开关联当前主机的 AI 聊天
- [ ] 输入"安装 docker"，AI 返回带 ```bash 代码块的回复
- [ ] 命令块正确显示安全等级样式 (blocked=灰/禁用, warn=黄, safe=蓝)
- [ ] 点击执行: blocked 直接拦截, warn 需输入 CONFIRM, safe 普通确认
- [ ] 确认后命令在终端执行，输出实时显示
- [ ] 危险命令 (如 rm -rf /) 被 SafetyGuard 拦截，无法执行
- [ ] 快捷命令支持变量替换，替换后能发送到终端

💡 给 AI 的提示词结尾
```
请严格按安全等级流程实现，blocked 命令必须禁用执行按钮。
关键：CommandBlock → showConfirmDialog → terminalProvider.sendCommand 链路必须完整。
完成后输出：✅ Step 5 完成，AI 命令执行闭环已就绪
```

---

## Step 6：设置页面 + 多平台发布配置

```
🎯 任务范围
完成设置页、外观配置、安全锁、多平台编译配置，达到可发布状态。

📦 新增依赖（pubspec.yaml）
```yaml
dependencies:
  local_auth: ^2.1.6        # 生物识别 (移动端)
  package_info_plus: ^5.0.1 # 获取应用版本
  # 桌面端快捷键 (可选)
  hotkey_manager: ^0.1.7    # 仅 windows/macOS/linux
```

🗂️ 文件清单
```
lib/
├── pages/
│   ├── settings_page.dart      # 设置主页
│   ├── appearance_page.dart    # 外观设置
│   ├── security_page.dart      # 安全设置 (生物识别)
│   └── sftp_placeholder.dart   # SFTP 占位页
├── core/
│   └── app_lock.dart           # 应用锁逻辑 (生物识别 + 密码)
└── (修改) main.dart            # 添加启动页 + 平台适配
```

⚙️ 设置主页：lib/pages/settings_page.dart
```
路由: /settings

UI: ListView (padding: 16, spacing: 8)

分组 1: 功能配置
• ListTile(
    leading: Icon(Icons.smart_toy, color: cPrimary),
    title: Text("AI 模型配置"),
    subtitle: Text("管理 API Key 和模型参数"),
    trailing: Icon(Icons.chevron_right, color: cTextSub),
    onTap: → /settings/ai
  )
• ListTile(
    leading: Icon(Icons.code, color: cPrimary),
    title: Text("快捷命令"),
    subtitle: Text("自定义常用命令模板"),
    trailing: Icon(Icons.chevron_right),
    onTap: → /snippets
  )

分组 2: 外观与安全
• ListTile(
    leading: Icon(Icons.palette, color: cPrimary),
    title: Text("外观设置"),
    trailing: Icon(Icons.chevron_right),
    onTap: → /settings/appearance
  )
• ListTile(
    leading: Icon(Icons.security, color: cPrimary),
    title: Text("安全设置"),
    trailing: Icon(Icons.chevron_right),
    onTap: → /settings/security
  )

分组 3: 关于
• ListTile(
    leading: Icon(Icons.info, color: cPrimary),
    title: Text("关于 AI Terminal"),
    subtitle: Text("版本 1.0.0"),
    trailing: TextButton("检查更新", onPressed: 占位)
  )

分隔线: 每组之间加 Divider(color: cBorder, height: 24)
```

🎨 外观设置：lib/pages/appearance_page.dart
```
路由: /settings/appearance

表单:
• 主题模式: RadioListTile<String>(
    title: Text("深色模式"),
    value: "dark", groupValue: currentTheme,
    onChanged: (val) → 保存偏好 + 通知 Theme 变更
  )
  // 后续可扩展: "light", "system"

• 字体大小: 
  - Text("终端字体大小: ${fontSize}px")
  - Slider(value: fontSize, min: 12, max: 18, divisions: 6, onChanged: 实时预览)

• 终端配色方案: DropdownButtonFormField(
    value: currentScheme,
    items: ["Monokai", "Dracula", "Solarized Dark"].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
    onChanged: 切换预设颜色 (前景/背景/高亮)
  )

• 实时预览区: Container(
    height: 120,
    decoration: BoxDecoration(color: previewBg, borderRadius: rCard),
    padding: 12,
    child: SelectableText("$ echo 'Hello'\nHello\n$ ", style: previewStyle)
  )
```

🔐 安全设置：lib/pages/security_page.dart
```
路由: /settings/security

表单:
• 应用锁: SwitchListTile(
    title: Text("启用应用锁"),
    subtitle: Text("启动时需要生物识别或密码"),
    value: appLockEnabled,
    onChanged: (val) → 
      if val: 调用 local_auth.authenticate() 验证 → 成功则保存偏好
      else: 直接关闭
  )

• 生物识别状态: 
  - FutureBuilder(
      future: LocalAuthentication().canCheckBiometrics,
      builder: (ctx, snapshot) → 
        if snapshot.data==true: Text("✅ 支持指纹/面容", cSuccess)
        else: Text("⚠️ 设备不支持生物识别", cWarning)
    )

• 清除数据: ListTile(
    title: Text("清除所有数据", style: TextStyle(color: cDanger)),
    subtitle: Text("删除服务器配置、聊天记录、凭据 (不可恢复)"),
    trailing: Icon(Icons.delete_forever, color: cDanger),
    onTap: → 显示二次确认对话框 → 用户输入"DELETE" → 调用 Hive.deleteFromDisk() + CredentialsStore 清理
  )
```

🔒 应用锁逻辑：lib/core/app_lock.dart
```
类: AppLock
静态方法:
• Future<bool> init() 
  - 读取偏好: 是否启用锁
  - 如果启用: 在 app 启动时 (main 函数) 调用 requireAuth()

• Future<bool> requireAuth()
  - 调用 LocalAuthentication().authenticate(
      localizedReason: "验证身份以访问 AI Terminal",
      options: AuthenticationOptions(biometricOnly: false) // 允许密码 fallback
    )
  - 返回认证结果

• 在 lib/main.dart 集成:
  - 在 runApp 前: if (await AppLock.init()) { runApp(...) } else { exit(0) }
```

🌐 多平台配置（关键！按平台修改）

【Android】android/app/build.gradle
```gradle
android {
  defaultConfig {
    minSdkVersion 21  // flutter_secure_storage 要求
    targetSdkVersion 34
  }
}
// 权限: android/app/src/main/AndroidManifest.xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.USE_BIOMETRIC"/>
```

【iOS】ios/Podfile + Info.plist
```ruby
# Podfile
platform :ios, '13.0'  # Keychain 要求
```
```xml
<!-- Info.plist -->
<key>NSFaceIDUsageDescription</key>
<string>使用面容 ID 保护服务器凭据和设置</string>
```

【macOS】macos/Podfile + entitlements
```ruby
# Podfile
platform :osx, '10.15'
```
```xml
<!-- macos/Runner/DebugProfile.entitlements (和 Release 一样) -->
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

【Windows】无特殊配置，确保:
- windows/runner/utils.cpp 使用 UTF-8 编码
- 如果打包: flutter build windows --release

🚀 启动页 + 全局快捷键

【启动页】修改 lib/main.dart
```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initHive();  // Step 1
  await AppLock.init();  // Step 6
  
  runApp(const SplashScreen());  // 2 秒启动页
}

class SplashScreen extends StatefulWidget {
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(seconds: 2), () {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => const ProviderScope(child: App()),
      ));
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: cBg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.terminal, size: 48, color: cPrimary),
            SizedBox(height: 16),
            Text("AI Terminal", style: TextStyle(color: cTextMain, fontSize: 18, fontWeight: FontWeight.w500)),
            SizedBox(height: 8),
            Text("v1.0.0", style: TextStyle(color: cTextSub, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
```

【全局快捷键】(桌面端可选) 修改 lib/main.dart
```dart
// 仅桌面端注册
if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
  HotkeyManager.instance.register(HotKey(Key.keyT, modifiers: [KeyModifier.control]), () {
    // 新建终端标签: terminalProvider.openTab(...)
  });
  HotkeyManager.instance.register(HotKey(Key.keyW, modifiers: [KeyModifier.control]), () {
    // 关闭当前标签: terminalProvider.closeTab(activeTabId)
  });
  HotkeyManager.instance.register(HotKey(Key.keyJ, modifiers: [KeyModifier.control]), () {
    // 切换 AI 面板: 显示/隐藏 ChatSheet
  });
}
```

🧪 验收标准
- [ ] 设置页所有入口可点击跳转，无 404
- [ ] 外观设置切换主题/字体，终端实时预览生效
- [ ] 安全设置能开启/关闭应用锁 (移动端测试生物识别)
- [ ] 四平台编译通过: 
  • flutter build apk --release
  • flutter build ios --release (需 macOS + 证书)
  • flutter build macos --release
  • flutter build windows --release
- [ ] 启动页正常显示 2 秒后进入主界面
- [ ] 桌面端快捷键 (Ctrl+T/W/J) 生效 (如果启用)

💡 给 AI 的提示词结尾
```
请严格按平台配置修改，特别是 Android minSdk=21 和 iOS platform:13.0。
关键：AppLock 必须在 runApp 前初始化，避免未授权访问。
完成后输出：✅ Step 6 完成，AI Terminal v1.0 可发布
```

---

## 🗓️ 执行计划 + 验证清单

```
✅ 推荐执行顺序 (3 周)

Week 1: 基础搭建
  → Step 1 (骨架 + 安全存储) → 验证: CredentialsStore + Hive 联动
  → Step 2 (主机管理) → 验证: 增删改查 + 凭据同步清理

Week 2: 核心功能
  → Step 3 (SSH 终端) → 验证: 连接池复用 + 多标签隔离
  → Step 4 (AI 聊天) → 验证: 流式响应 + 代码块解析

Week 3: 闭环 + 发布
  → Step 5 (执行闭环) → 验证: SafetyGuard 拦截 + 确认流程
  → Step 6 (设置 + 发布) → 验证: 四平台编译 + 生物识别

🔍 每步完成后必做验证
1. 手动测试核心流程 (如: 添加主机→连接→执行命令)
2. 运行单元测试: flutter test
3. 搜索代码确认无明文凭据: grep -r "password\|privateKey\|api_key" lib/
4. 模拟异常: 断网/SSH 拒绝/AI 超时，检查错误处理

🚨 三条红线 (不可妥协)
1. 任何凭据/密钥永不明文出现在: 日志 / UI / Hive / 网络请求
2. 危险命令执行必须经过: SafetyGuard 校验 + 用户显式确认
3. 生产环境默认开启: SafetyLevel.medium (warn 级需二次确认)

📦 发布前检查清单
- [ ] 所有 TODO/FIXME 已处理
- ` flutter analyze` 无 warning
- [ ] 敏感字符串已混淆 (可选: 用 flutter build --obfuscate)
- [ ] 隐私政策/用户协议链接已配置 (应用商店要求)
- [ ] 版本号已更新 (pubspec.yaml + UI 显示)
```

---

> 💡 **最后建议**：  
> 1. 每个 Step 单独复制给 AI Coding，不要合并发送  
> 2. 遇到模糊点，要求 AI"按上述规范输出，不要自行发挥"  
> 3. 优先保证安全流程 (Step 1/5)，功能可迭代  
> 4. 保留所有 Prompt 记录，便于后续回溯和审计  

