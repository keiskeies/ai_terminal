import '../utils/command_heuristics.dart';
import '../services/agent_logger.dart';

/// 命令提取器 — 从 AI 响应文本中提取 shell 命令
///
/// 渐进式重构：从 AgentEngine 中提取的纯逻辑类，无实例状态依赖。
/// 支持多种格式：markdown 代码块、反引号包裹、命令前缀匹配、宽松提取。
class CommandExtractor {
  /// 从 AI 响应中提取第一条有效命令
  static String? extractCommand(String content) {
    agentLogger.debug('ExtractCmd', '开始解析，内容长度: ${content.length}');

    // ========== 模式 1: markdown 代码块 ==========
    final codeBlockPatterns = [
      RegExp(r'```\s*(?:bash|sh|shell)\s*\n([\s\S]*?)```', multiLine: true),
      RegExp(r'```\s*\n([\s\S]*?)```', multiLine: true),
      RegExp(r'```\s*(?:bash|sh|shell)\s+([^\n]+)```', multiLine: true),
    ];

    for (final pattern in codeBlockPatterns) {
      final match = pattern.firstMatch(content);
      if (match != null) {
        final rawBlock = match.group(1)?.trim();
        if (rawBlock != null && rawBlock.isNotEmpty) {
          final command = _extractFirstCommand(rawBlock);
          if (command != null) {
            agentLogger.info('ExtractCmd', '模式1匹配成功: $command');
            return command;
          }
        }
      }
    }

    // ========== 模式 2: 单个反引号包裹的命令 ==========
    final singleBacktick = RegExp(r'`([^`\n]+)`');
    final backtickMatch = singleBacktick.firstMatch(content);
    if (backtickMatch != null) {
      final cmd = backtickMatch.group(1)?.trim();
      if (cmd != null && looksLikeCommand(cmd)) {
        agentLogger.info('ExtractCmd', '模式2匹配成功(反引号): $cmd');
        return cmd;
      }
    }

    // ========== 模式 3: 独立行的命令（常见命令前缀）==========
    final commandPrefixes = [
      r'^sudo\s+', r'^yum\s+', r'^apt\s+', r'^apt-get\s+', r'^dnf\s+',
      r'^apk\s+', r'^pacman\s+', r'^brew\s+', r'^curl\s+', r'^wget\s+',
      r'^tar\s+', r'^unzip\s+', r'^cat\s+', r'^echo\s+', r'^export\s+',
      r'^source\s+', r'^cd\s+', r'^mkdir\s+', r'^chmod\s+', r'^chown\s+',
      r'^rm\s+', r'^cp\s+', r'^mv\s+', r'^ln\s+', r'^systemctl\s+',
      r'^service\s+', r'^java\s+', r'^javac\s+', r'^python\s+',
      r'^pip\s+', r'^npm\s+', r'^node\s+', r'^git\s+', r'^docker\s+',
      r'^kubectl\s+', r'^ls\s+', r'^grep\s+', r'^find\s+', r'^head\s+',
      r'^tail\s+', r'^which\s+', r'^where\s+', r'^type\s+',
      r'^uname\s+', r'^date\s+', r'^whoami\s+', r'^id\s+',
      r'^pwd\s+', r'^env\s+', r'^printenv\s+', r'^sed\s+',
      r'^awk\s+', r'^sort\s+', r'^uniq\s+', r'^wc\s+',
      r'^chmod\s+', r'^chgrp\s+', r'^touch\s+', r'^dd\s+',
    ];

    final lines = content.split('\n');
    for (final line in lines) {
      var trimmed = line.trim();
      if (trimmed.startsWith('#') || trimmed.startsWith('//') ||
          trimmed.startsWith('请') || trimmed.startsWith('执行') ||
          trimmed.startsWith('命令') || trimmed.startsWith('说明') ||
          trimmed.startsWith('注意') || trimmed.startsWith('提示') ||
          trimmed.startsWith('警告') || trimmed.startsWith('- ') ||
          trimmed.startsWith('* ')) {
        continue;
      }
      trimmed = trimmed.replaceFirst(RegExp(r'^\d+[\.\)]\s*'), '');
      trimmed = trimmed.replaceFirst(RegExp(r'^[-*]\s*'), '');

      for (final prefix in commandPrefixes) {
        if (RegExp(prefix).hasMatch(trimmed) && looksLikeCommand(trimmed)) {
          agentLogger.info('ExtractCmd', '模式3匹配成功(前缀): $trimmed');
          return trimmed;
        }
      }
    }

    // ========== 模式 4: 宽松提取 ==========
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (isDescriptiveText(trimmed)) continue;
      var cleaned = trimmed.replaceFirst(RegExp(r'^\d+[\.\)]\s*'), '');
      cleaned = cleaned.replaceFirst(RegExp(r'^[-*]\s*'), '');
      if (looksLikeCommand(cleaned) && cleaned.length >= 3) {
        agentLogger.info('ExtractCmd', '模式4匹配成功(宽松): $cleaned');
        return cleaned;
      }
    }

    agentLogger.warn('ExtractCmd', '所有模式均未匹配到命令');
    return null;
  }

  /// 从 AI 响应中提取所有可执行命令（支持批量）
  static List<String> extractCommands(String content) {
    agentLogger.debug('ExtractCmd', '开始批量解析，内容长度: ${content.length}');

    final commands = <String>[];

    // ========== 模式 1: markdown 代码块 ==========
    final codeBlockPatterns = [
      RegExp(r'```\s*(?:bash|sh|shell)\s*\n([\s\S]*?)```', multiLine: true),
      RegExp(r'```\s*\n([\s\S]*?)```', multiLine: true),
      RegExp(r'```\s*(?:bash|sh|shell)\s+([^\n]+)```', multiLine: true),
    ];

    for (final pattern in codeBlockPatterns) {
      final match = pattern.firstMatch(content);
      if (match != null) {
        final rawBlock = match.group(1)?.trim();
        if (rawBlock != null && rawBlock.isNotEmpty) {
          commands.addAll(_parseCodeBlock(rawBlock));
          if (commands.isNotEmpty) {
            agentLogger.info('ExtractCmd', '批量模式1提取 ${commands.length} 条命令');
            return commands;
          }
        }
      }
    }

    // 回退到单条命令提取
    final single = extractCommand(content);
    if (single != null) {
      commands.add(single);
      agentLogger.info('ExtractCmd', '回退单条提取: $single');
    }
    return commands;
  }

  /// 解析代码块，识别 heredoc 并将其作为整体提取
  static List<String> _parseCodeBlock(String rawBlock) {
    final commands = <String>[];
    final lines = rawBlock.split('\n');

    int i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();

      if (line.isEmpty) {
        i++;
        continue;
      }

      // 检测 heredoc 开始（支持 << 和 <<- 形式）
      final heredocStart = RegExp(r'''<<-?\s*['"]?(\w+)['"]?''');
      final heredocMatch = heredocStart.firstMatch(line);

      if (heredocMatch != null) {
        final delimiter = heredocMatch.group(1)!;
        final heredocLines = <String>[line];

        i++;
        while (i < lines.length) {
          final heredocLine = lines[i];
          heredocLines.add(heredocLine);
          if (heredocLine.trim() == delimiter) {
            i++;
            break;
          }
          i++;
        }

        final heredocCommand = heredocLines.join('\n');
        commands.add(heredocCommand);
        agentLogger.info('ExtractCmd', 'heredoc 命令提取: ${heredocCommand.length} 字符');
        continue;
      }

      if (line.startsWith('#') && !line.startsWith('#!')) {
        i++;
        continue;
      }
      if (line.startsWith('```') || line.endsWith('```')) {
        i++;
        continue;
      }
      // 过滤描述性文字：代码块中的 prose 行不应被当作命令执行
      if (line.length >= 3 && !isDescriptiveText(line) && looksLikeCommand(line)) {
        commands.add(line);
      }
      i++;
    }

    return commands;
  }

  /// 从多行代码块中提取第一条有效命令
  /// 支持 heredoc：遇到 << 时将后续行直到定界符作为整体返回
  static String? _extractFirstCommand(String block) {
    final lines = block.split('\n');
    int i = 0;
    while (i < lines.length) {
      final cmd = lines[i].trim();
      if (cmd.isEmpty || cmd.startsWith('#')) { i++; continue; }
      if (cmd.startsWith('```') || cmd.endsWith('```')) { i++; continue; }

      // 检测 heredoc：将后续行直到定界符合并为一条命令
      final heredocStart = RegExp(r'''<<-?\s*['"]?(\w+)['"]?''');
      final heredocMatch = heredocStart.firstMatch(cmd);
      if (heredocMatch != null) {
        final delimiter = heredocMatch.group(1)!;
        final heredocLines = <String>[cmd];
        i++;
        while (i < lines.length) {
          final heredocLine = lines[i];
          heredocLines.add(heredocLine);
          if (heredocLine.trim() == delimiter) { i++; break; }
          i++;
        }
        return heredocLines.join('\n');
      }

      if (looksLikeCommand(cmd)) return cmd;
      i++;
    }
    // 宽松回退
    for (final line in lines) {
      final cmd = line.trim();
      if (cmd.isEmpty || cmd.startsWith('#') || cmd.startsWith('```')) continue;
      if (cmd.length >= 3 && !isDescriptiveText(cmd)) return cmd;
    }
    return null;
  }
}
