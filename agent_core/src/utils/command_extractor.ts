// command_extractor.ts - extracts shell commands from AI response text
//
// 1:1 port of Dart utils/command_extractor.dart (232 lines).
//
// Supports multiple formats: markdown code blocks, backtick-wrapped,
// command prefix matching, loose extraction. All patterns use
// command_heuristics.looksLikeCommand for validation.

import {looksLikeCommand, isDescriptiveText} from "./command_heuristics.js";
import {agentLogger} from "./agent_logger.js";

/**
 * Extract the first valid command from AI response text.
 */
export function extractCommand(content: string): string | null {
  agentLogger.debug("ExtractCmd", "开始解析，内容长度: " + content.length);

  const codeBlockPatterns = [
    /```\s*(?:bash|sh|shell)\s*\n([\s\S]*?)```/m,
    /```\s*\n([\s\S]*?)```/m,
    /```\s*(?:bash|sh|shell)\s+([^\n]+)```/m,
  ];
  for (const pattern of codeBlockPatterns) {
    const match = pattern.exec(content);
    if (match) {
      const rawBlock = match[1]?.trim();
      if (rawBlock && rawBlock.length > 0) {
        const command = extractFirstCommand(rawBlock);
        if (command !== null) {
          agentLogger.info("ExtractCmd", "模式1匹配成功: " + command);
          return command;
        }
      }
    }
  }

  const singleBacktick = /`([^`\n]+)`/;
  const backtickMatch = singleBacktick.exec(content);
  if (backtickMatch) {
    const cmd = backtickMatch[1].trim();
    if (cmd && looksLikeCommand(cmd)) {
      agentLogger.info("ExtractCmd", "反引号匹配: " + cmd);
      return cmd;
    }
  }

  const commandPrefixes = [
    /^sudo\s+/, /^yum\s+/, /^apt\s+/, /^apt-get\s+/, /^dnf\s+/,
    /^apk\s+/, /^pacman\s+/, /^brew\s+/, /^curl\s+/, /^wget\s+/,
    /^tar\s+/, /^unzip\s+/, /^cat\s+/, /^echo\s+/, /^export\s+/,
    /^source\s+/, /^cd\s+/, /^mkdir\s+/, /^chmod\s+/, /^chown\s+/,
    /^rm\s+/, /^cp\s+/, /^mv\s+/, /^ln\s+/, /^systemctl\s+/,
    /^service\s+/, /^java\s+/, /^javac\s+/, /^python\s+/,
    /^pip\s+/, /^npm\s+/, /^node\s+/, /^git\s+/, /^docker\s+/,
    /^kubectl\s+/, /^ls\s+/, /^grep\s+/, /^find\s+/, /^head\s+/,
    /^tail\s+/, /^which\s+/, /^where\s+/, /^type\s+/,
    /^uname\s+/, /^date\s+/, /^whoami\s+/, /^id\s+/,
    /^pwd\s+/, /^env\s+/, /^printenv\s+/, /^sed\s+/,
    /^awk\s+/, /^sort\s+/, /^uniq\s+/, /^wc\s+/,
    /^chgrp\s+/, /^touch\s+/, /^dd\s+/
  ];

  const lines = content.split("\n");
  for (const rawLine of lines) {
    let trimmed = rawLine.trim();
    if (/^(#|\/\/|请|执行|命令|说明|注意|提示|警告|- |\* )/.test(trimmed)) continue;
    trimmed = trimmed.replace(/^\d+[.)]\s*/, "").replace(/^[-*]\s*/, "");
    for (const prefix of commandPrefixes) {
      if (prefix.test(trimmed) && looksLikeCommand(trimmed)) {
        agentLogger.info("ExtractCmd", "前缀匹配: " + trimmed);
        return trimmed;
      }
    }
  }

  for (const rawLine of lines) {
    const trimmed = rawLine.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#")) continue;
    if (isDescriptiveText(trimmed)) continue;
    const cleaned = trimmed.replace(/^\d+[.)]\s*/, "").replace(/^[-*]\s*/, "");
    if (looksLikeCommand(cleaned) && cleaned.length >= 3) {
      agentLogger.info("ExtractCmd", "宽松匹配: " + cleaned);
      return cleaned;
    }
  }

  agentLogger.warn("ExtractCmd", "所有模式均未匹配到命令");
  return null;
}

/**
 * Extract all executable commands from AI response (batch).
 */
export function extractCommands(content: string): string[] {
  agentLogger.debug("ExtractCmd", "批量解析，内容长度: " + content.length);
  const commands: string[] = [];

  const codeBlockPatterns = [
    /```\s*(?:bash|sh|shell)\s*\n([\s\S]*?)```/m,
    /```\s*\n([\s\S]*?)```/m,
    /```\s*(?:bash|sh|shell)\s+([^\n]+)```/m,
  ];
  for (const pattern of codeBlockPatterns) {
    const match = pattern.exec(content);
    if (match) {
      const rawBlock = match[1]?.trim();
      if (rawBlock && rawBlock.length > 0) {
        const parsed = parseCodeBlock(rawBlock);
        commands.push(...parsed);
        if (commands.length > 0) {
          agentLogger.info("ExtractCmd", "批量提取 " + commands.length + " 条命令");
          return commands;
        }
      }
    }
  }

  const single = extractCommand(content);
  if (single !== null) {
    commands.push(single);
    agentLogger.info("ExtractCmd", "回退单条提取: " + single);
  }
  return commands;
}

/**
 * Parse a code block, recognizing heredoc as one unit.
 */
export function parseCodeBlock(rawBlock: string): string[] {
  const commands: string[] = [];
  const lines = rawBlock.split("\n");
  let i = 0;
  while (i < lines.length) {
    const line = lines[i].trim();
    if (line.length === 0) { i++; continue; }

    const heredocStart = /<<-?\s*["']?(\w+)["']?/;
    const heredocMatch = heredocStart.exec(line);
    if (heredocMatch) {
      const delimiter = heredocMatch[1];
      const heredocLines: string[] = [line];
      i++;
      while (i < lines.length) {
        const heredocLine = lines[i];
        heredocLines.push(heredocLine);
        if (heredocLine.trim() === delimiter) { i++; break; }
        i++;
      }
      const heredocCommand = heredocLines.join("\n");
      commands.push(heredocCommand);
      agentLogger.info("ExtractCmd", "heredoc 命令: " + heredocCommand.length + " 字符");
      continue;
    }

    if (line.startsWith("#") && !line.startsWith("#!")) { i++; continue; }
    if (line.startsWith("```") || line.endsWith("```")) { i++; continue; }
    if (line.length >= 3 && !isDescriptiveText(line) && looksLikeCommand(line)) {
      commands.push(line);
    }
    i++;
  }
  return commands;
}

/**
 * Extract the first valid command from a multi-line code block.
 */
export function extractFirstCommand(block: string): string | null {
  const lines = block.split("\n");
  let i = 0;
  while (i < lines.length) {
    const cmd = lines[i].trim();
    if (cmd.length === 0 || cmd.startsWith("#")) { i++; continue; }
    if (cmd.startsWith("```") || cmd.endsWith("```")) { i++; continue; }

    const heredocStart = /<<-?\s*["']?(\w+)["']?/;
    const heredocMatch = heredocStart.exec(cmd);
    if (heredocMatch) {
      const delimiter = heredocMatch[1];
      const heredocLines: string[] = [cmd];
      i++;
      while (i < lines.length) {
        const heredocLine = lines[i];
        heredocLines.push(heredocLine);
        if (heredocLine.trim() === delimiter) { i++; break; }
        i++;
      }
      return heredocLines.join("\n");
    }

    if (looksLikeCommand(cmd)) return cmd;
    i++;
  }
  for (const line of lines) {
    const cmd = line.trim();
    if (cmd.length === 0 || cmd.startsWith("#") || cmd.startsWith("```")) continue;
    if (cmd.length >= 3 && !isDescriptiveText(cmd)) return cmd;
  }
  return null;
}