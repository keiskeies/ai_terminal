这次它**说对了**，而且这三个都是真坑。我直接给你**可落地的修复方案**，融进之前的 Step 里。

---

## 坑 1：链式命令解析（最严重）

**问题**：AI 输出 `yum install docker && systemctl start docker`，你按行拆分后只执行了前半句，或者拆成两句破坏了逻辑。

**修复**（Step 5 改两处）：

### ① prompts.dart 加硬规则

```dart
const String commandFormatRule = """
【输出规则 - 严格执行】
1. 所有可执行命令必须放在 ```bash 代码块中
2. 代码块内禁止写注释、禁止写说明文字
3. 每条命令必须是单行、可独立执行的命令
4. 禁止使用 &&、||、;、| 等链式/管道符号
5. 如果需要多步操作，分多条命令输出，每条一个代码块
6. 解释性文字写在代码块外
""";
```

### ② ai_parser.dart 加校验

```dart
static List<CommandBlock> extractCommands(String aiContent) {
  final regex = RegExp(r'```bash\s*\n([\s\S]*?)\n```');
  final matches = regex.allMatches(aiContent);
  final commands = <CommandBlock>[];
  
  for (final match in matches) {
    final block = match.group(1)?.trim() ?? '';
    for (final line in block.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      
      // 检测链式命令
      final forbidden = RegExp(r'[;&|]{2,}|\|');
      final isDangerous = forbidden.hasMatch(trimmed);
      
      commands.add(CommandBlock(
        command: trimmed,
        description: '',
        dangerous: isDangerous || _isDangerousCommand(trimmed),
      ));
    }
  }
  return commands;
}
```

### ③ UI 层处理（CommandBlock 组件）

```dart
// 如果检测到链式符号，强制显示警告，不允许直接执行
if (block.dangerous) {
  return Column(
    children: [
      Text('⚠️ 复杂命令，请手动复制到终端执行', style: TextStyle(color: cDanger)),
      Text(block.command, style: TextStyle(color: cTerminalGreen)),
      ElevatedButton(onPressed: onCopy, child: Text('复制')),
    ],
  );
}
```

---

## 坑 2：执行完成判定（waitForPrompt）

**问题**：你 `await Future.delayed(500ms)` 后读输出，可能命令还没跑完（比如 `yum install` 要几十秒），导致拿到半截结果。

**修复**（Step 3 改 SSHService）：

```dart
class SSHService {
  final _outputBuffer = StringBuffer();
  final _promptRegex = RegExp(r'[\]\$#]\s*$'); // 匹配 $ # 结尾
  final _completers = <Completer<String>>[];
  
  void onShellData(String data) {
    _outputBuffer.write(data);
    
    // 检测是否出现 prompt（表示命令执行完毕）
    if (_promptRegex.hasMatch(data)) {
      for (final c in _completers) {
        if (!c.isCompleted) {
          c.complete(_outputBuffer.toString());
        }
      }
      _completers.clear();
      _outputBuffer.clear();
    }
  }
  
  Future<String> executeAndWait(String command, {int timeoutSec = 30}) async {
    final completer = Completer<String>();
    _completers.add(completer);
    
    // 发送命令
    session?.write('$command\n'.toUtf8());
    
    // 超时处理
    return completer.future.timeout(
      Duration(seconds: timeoutSec),
      onTimeout: () {
        _completers.remove(completer);
        throw TimeoutException('命令执行超时');
      },
    );
  }
}
```

**注意**：这个方案对 `top`、`vim` 这种交互式命令会失效（因为不会返回 prompt）。MVP 阶段遇到这种命令直接超时，Phase 2 再处理。

---

## 坑 3：上下文污染

**问题**：Recent Output 里残留了之前的错误信息，AI 会误判。

**修复**（Step 5 改 chat_provider）：

```dart
// 不要传"最近50行终端输出"
// 改为：只传"上一条 AI 命令的执行结果"

class ChatProvider extends StateNotifier<ChatState> {
  String _lastCommandOutput = '';
  
  Future<void> sendMessage(String content, {String? hostId}) async {
    // ...
    
    final systemPrompt = """
[System Info]
OS: ${context.osName} ${context.osVersion}
架构: ${context.architecture}

[上一条命令执行结果]
${_lastCommandOutput.isEmpty ? '无' : _lastCommandOutput.substring(0, min(_lastCommandOutput.length, 500))}

[用户当前请求]
$content
""";
    
    // 发送给 AI...
  }
  
  // 执行完命令后，更新上下文
  void updateLastOutput(String output) {
    _lastCommandOutput = output;
  }
}
```

**关键**：`lastCommandOutput` 只在用户点击"执行"后更新，而不是持续读取终端。避免把无关日志带进去。

---

## 关于"状态机"（Running/Success/Failed/Timeout）

他说的状态机确实有用，但**属于 Phase 2**。MVP 阶段你先把上面的三个坑填了，产品就能用。状态机是锦上添花，不是救命稻草。

Phase 2 再加：

```dart
enum CommandStatus { idle, running, success, failed, timeout }
```

---

## 最终执行清单

按我原来的 6 个 Step，只改这 **3 个文件**：

| 步骤 | 文件 | 修改内容 |
|------|------|---------|
| Step 3 | `ssh_service.dart` | 加 `executeAndWait()` + prompt 检测 |
| Step 5 | `prompts.dart` | 加"禁止链式命令"规则 |
| Step 5 | `ai_parser.dart` | 加链式命令检测，标记 dangerous |
| Step 5 | `chat_provider.dart` | 上下文只传 `lastCommandOutput` |

**不改整体架构，不新增 Step，不推迟进度。**

这三个修复加起来大概 50 行代码，半天就能做完。