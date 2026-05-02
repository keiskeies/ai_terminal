import '../models/chat_session.dart';
import '../core/safety_guard.dart';

/// 检测链式/管道命令操作符
bool hasChainOperator(String command) {
  // 匹配 &&、||、; 以及管道符 |
  final forbidden = RegExp(r'&&|\|\||;|\|');
  return forbidden.hasMatch(command);
}

class AIParser {
  /// 从 AI 回复中提取命令块
  static List<CommandBlock> extractCommands(String aiContent) {
    final commands = <CommandBlock>[];

    // 清理 markdown 内容：移除内联代码块（单行 `code`）
    final cleanedContent = aiContent.replaceAll(RegExp(r'`([^`]+)`'), r'$1');

    // 匹配 ```bash 代码块（更宽松的匹配）
    final bashRegex = RegExp(r'```bash\s*\n([\s\S]*?)```', multiLine: true);
    final matches = bashRegex.allMatches(cleanedContent);

    for (final match in matches) {
      final codeBlock = match.group(1);
      if (codeBlock == null) continue;

      // 按行分割，过滤空行和纯注释行
      final lines = codeBlock.split('\n').where((line) {
        final trimmed = line.trim();
        return trimmed.isNotEmpty && !trimmed.startsWith('#');
      }).toList();

      for (final line in lines) {
        final command = line.trim();
        if (command.isEmpty) continue;

        // 跳过可能残留的 markdown 标记
        if (command.startsWith('```') || command.endsWith('```')) continue;

        // 检测链式命令（&&、||、;、|）
        final hasChainOp = hasChainOperator(command);

        // 检查安全等级
        final safetyLevel = SafetyGuard.check(command);
        // 如果有链式操作符，直接标记为危险
        final dangerous = hasChainOp || safetyLevel != SafetyLevel.safe;

        // 尝试从上下文提取描述
        String? description;
        if (hasChainOp) {
          description = '⚠️ 复杂命令（包含链式操作符），建议手动执行';
        } else {
          final beforeMatch = cleanedContent.substring(0, match.start);
          final descRegex = RegExp(r'说明[：:]\s*([^\n`]+)');
          final descMatch = descRegex.firstMatch(beforeMatch);
          if (descMatch != null) {
            description = descMatch.group(1)?.trim();
          }
        }

        commands.add(CommandBlock.create(
          command: command,
          description: description,
          dangerous: dangerous,
          safetyLevel: dangerous ? 'warn' : safetyLevel.name,
        ));
      }
    }

    // 也检查 ```shell 和 ``` 的代码块
    final shellRegex = RegExp(r'```\s*\n([\s\S]*?)```', multiLine: true);
    for (final match in shellRegex.allMatches(cleanedContent)) {
      final codeBlock = match.group(1);
      if (codeBlock == null) continue;

      // 检查是否是 shell 命令
      final lines = codeBlock.split('\n').where((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) return false;
        // 检查是否像命令（不以特殊字符开头）
        return !trimmed.startsWith('*') && !trimmed.startsWith('-') && !trimmed.contains(':');
      }).toList();

      for (final line in lines) {
        final command = line.trim();
        if (command.isEmpty) continue;

        // 跳过可能残留的 markdown 标记
        if (command.startsWith('```') || command.endsWith('```')) continue;

        // 检查是否已存在
        if (commands.any((c) => c.command == command)) continue;

        // 检测链式命令
        final hasChainOp2 = hasChainOperator(command);
        final safetyLevel = SafetyGuard.check(command);
        final dangerous = hasChainOp2 || safetyLevel != SafetyLevel.safe;

        commands.add(CommandBlock.create(
          command: command,
          description: hasChainOp2 ? '⚠️ 复杂命令（包含链式操作符），建议手动执行' : null,
          dangerous: dangerous,
          safetyLevel: dangerous ? 'warn' : safetyLevel.name,
        ));
      }
    }

    return commands;
  }
}
