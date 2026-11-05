import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../core/safety_guard.dart';
import '../utils/audit_logger.dart';
import '../utils/local_shell.dart';
import '../utils/tool_args_parser.dart';
import 'agent_tool.dart';
import 'command_executor.dart';
import 'local_file_policy.dart';

/// 在运行 App 的本机执行命令 — 只对 SSH 会话暴露。
///
/// 远程会话里 `动作: execute` 固定打到服务器；本机 Docker Desktop、盘符路径、
/// 本机服务必须走这个工具。它不操作远程 executor，路径边界由 [LocalFilePolicy]
/// 与用户确认共同保证，权限档位由 [ToolKind.destructive] 驱动：
/// 只读拒绝、询问/自动确认、全自动直接执行。
class LocalExecTool extends AgentTool {
  static const String localHostId = 'local';

  final LocalFilePolicy Function() _policyLoader;
  final LocalCommandRunner _runner;

  LocalExecTool({
    LocalFilePolicy Function()? policyLoader,
    LocalCommandRunner? runner,
  })  : _policyLoader = policyLoader ?? LocalFilePolicy.load,
        _runner = runner ?? runLocalCommand;

  @override
  String get name => 'local_exec';

  @override
  ToolKind get kind => ToolKind.destructive;

  /// 本机 shell 无法逐文件回滚，不能记进远程变更台账（否则回滚会打到服务器）。
  @override
  bool get recordsChanges => false;

  @override
  String get description => '在**运行 App 的这台电脑**上执行本地命令（不是当前 SSH 服务器）。'
      'Windows 默认 PowerShell，macOS/Linux 默认 bash；用于本机 Docker Desktop、'
      '盘符路径（D:\\...）、本机文件/服务。服务器上的命令请直接用 execute，不要用本工具。'
      'cwd 必须在已授权的本地目录内；未授权时会请求用户确认。'
      '命令需要交互输入（如登录）时请改用终端。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  command: 要执行的本地命令（必填；多行命令 PowerShell/bash 用 ; 连接，cmd 用 &，不要直接换行）\n'
      '  cwd: 工作目录绝对路径（必填，必须在已授权的本地目录内）\n'
      '  timeout: 超时秒数（可选，默认 120，最大 600；大型 docker save/构建可设 300–600）\n'
      '  shell: powershell | cmd | bash | sh（可选，不填按平台默认）';

  @override
  Map<String, dynamic>? toJsonSchema() => {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': '要在本机执行的命令，多行命令用 ; 连接成一行',
          },
          'cwd': {
            'type': 'string',
            'description': '本机工作目录绝对路径，必须在已授权目录内',
          },
          'timeout': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 600,
            'description': '超时秒数，默认 120；大型导出/构建可设 300-600',
          },
          'shell': {
            'type': 'string',
            'enum': ['powershell', 'cmd', 'bash', 'sh'],
            'description': '可选；不填按平台默认（Windows=PowerShell，Unix=bash）',
          },
        },
        'required': ['command', 'cwd'],
        'additionalProperties': false,
      };

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    if (!isLocalExecPlatformSupported()) {
      return ToolResult.failure(
          '当前平台不支持本机命令执行（仅支持 Windows / macOS / Linux 桌面端）。');
    }

    final command = args.getString('command').trim();
    if (command.isEmpty) {
      return ToolResult.failure('参数缺失: command 为必填项');
    }
    final rawCwd = args.getString('cwd').trim();
    if (rawCwd.isEmpty) {
      return ToolResult.failure(
          '参数缺失: cwd 为必填项。请提供本机工作目录的绝对路径，例如 D:\\docker\\images 或 /Users/me/project。');
    }
    final cwd = _expandHome(rawCwd);
    if (!p.isAbsolute(cwd)) {
      return ToolResult.failure('cwd 必须是绝对路径（收到: $rawCwd）。不要使用 . 或相对路径。');
    }

    // ── 1. 目录白名单 + 敏感黑名单 ──────────────────────────────
    var policy = _policyLoader();
    var decision = policy.decide(cwd);
    switch (decision.verdict) {
      case LocalPathVerdict.sensitive:
      case LocalPathVerdict.reserved:
      case LocalPathVerdict.escape:
        return ToolResult.failure(
            '本机目录被安全策略拒绝: ${decision.resolved}\n原因: ${decision.reason ?? '敏感路径'}');
      case LocalPathVerdict.allowed:
        break;
      case LocalPathVerdict.notInAllowlist:
        final request = localDirAuthorizationRequest;
        if (request == null) {
          return ToolResult.failure('本机目录未授权: ${decision.resolved}\n'
              '原因: ${decision.reason ?? '不在授权目录内'}\n'
              '请让用户在 设置 → Agent → 本地文件 中添加该目录，或改用远程 execute。');
        }
        final willCreate = !Directory(decision.resolved).existsSync();
        final approved = await request(
          decision.resolved,
          'local_exec 需要在该目录执行本机命令：${_clipForProgress(command)}'
          '${willCreate ? '（目录不存在，允许后将创建）' : ''}',
        );
        if (!approved) {
          return ToolResult.failure('用户拒绝授权本机目录: ${decision.resolved}，命令未执行。'
              '请用 ask 询问用户是否授权，或改用远程 execute；不要反复重试同一目录。');
        }
        // 弹窗确认后页面已写回 LocalFilePolicy，重新读取再判定
        policy = _policyLoader();
        decision = policy.decide(cwd);
        if (!decision.isAllowed) {
          return ToolResult.failure('授权后仍无法访问本机目录: ${decision.resolved}\n'
              '原因: ${decision.reason ?? '未通过白名单判定'}');
        }
        break;
    }

    final resolvedCwd = decision.resolved;

    // 目录授权弹窗可能停留很久；用户期间取消任务时，不能再创建目录/执行命令。
    if (isTaskActive?.call() == false) {
      return ToolResult.failure('任务已取消，本机命令未执行。');
    }

    final dir = Directory(resolvedCwd);
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
        onProgress?.call('已创建本机工作目录: $resolvedCwd');
      } catch (e) {
        return ToolResult.failure('无法创建工作目录 $resolvedCwd: $e');
      }
    }

    // ── 2. Shell / 超时 ────────────────────────────────────────
    final rawShell = args.getString('shell').trim();
    final parsedShell = parseLocalShell(rawShell);
    if (rawShell.isNotEmpty && parsedShell == null) {
      return ToolResult.failure(
          '未知 shell: $rawShell。可选 powershell / cmd / bash / sh。');
    }
    final shell = parsedShell ?? resolveDefaultLocalShell();
    if (shell == null) {
      return ToolResult.failure('当前平台没有可用的本机 shell。');
    }
    if (!isShellCompatibleWithPlatform(shell)) {
      return ToolResult.failure(
          '当前平台 ${Platform.operatingSystem} 不支持 shell=${shell.id}。'
          'Windows 请用 powershell/cmd，macOS/Linux 请用 bash/sh。');
    }
    final timeoutSeconds =
        args.getInt('timeout', defaultValue: 120).clamp(1, 600).toInt();

    // ── 3. 审计（执行前）──────────────────────────────────────
    final safetyLevel = SafetyGuard.check(command);
    await AuditLogger.log(
      hostId: localHostId,
      command: command,
      safetyLevel: safetyLevel.name,
      executed: false,
    );

    onProgress?.call(
        '本机执行 (${localShellLabel(shell)}): ${_clipForProgress(command)}');

    // ── 4. 执行 ───────────────────────────────────────────────
    LocalCommandResult result;
    try {
      result = await _runner(
        command: command,
        cwd: resolvedCwd,
        shell: shell,
        timeout: Duration(seconds: timeoutSeconds),
        cancelToken: cancelToken,
      );
    } catch (e) {
      return ToolResult.failure(
          '本机命令启动失败: $e\n命令: $command\ncwd: $resolvedCwd');
    }

    // 执行后审计：与执行前的 executed=false 形成完整链路
    final auditOutput = [
      if (result.stdout.isNotEmpty) result.stdout,
      if (result.stderr.isNotEmpty) result.stderr,
    ].join('\n');
    await AuditLogger.log(
      hostId: localHostId,
      command: command,
      safetyLevel: safetyLevel.name,
      output: _clipForAudit(auditOutput),
      executed: true,
    );

    // ── 5. 结果反馈 ───────────────────────────────────────────
    final buffer = StringBuffer()
      ..writeln(result.success ? '本机命令执行成功' : '本机命令执行失败')
      ..writeln('平台: ${Platform.operatingSystem} / ${localShellLabel(shell)}')
      ..writeln('cwd: $resolvedCwd')
      ..writeln('退出码: ${result.exitCode}')
      ..writeln('耗时: ${result.duration.inMilliseconds}ms');
    if (result.timedOut) {
      buffer.writeln('状态: 超时（已尝试终止进程；可能有子进程残留，请检查半成品文件）');
    } else if (result.cancelled) {
      buffer.writeln('状态: 已取消');
    }

    final stdoutText = _tailOutput(
        result.stdout, result.stdoutTotalChars, result.stdoutTruncated);
    final stderrText = _tailOutput(
        result.stderr, result.stderrTotalChars, result.stderrTruncated);
    if (stdoutText.isNotEmpty) {
      buffer
        ..writeln('--- stdout ---')
        ..writeln(stdoutText);
    }
    if (stderrText.isNotEmpty) {
      buffer
        ..writeln('--- stderr ---')
        ..writeln(stderrText);
    }
    if (!result.success) {
      buffer.writeln('请检查命令语法、cwd 与 shell 选择；需要交互输入的命令请改用终端。');
    }

    if (result.success) {
      return ToolResult.success(buffer.toString());
    }
    return ToolResult.failure(buffer.toString(), output: result.stdout);
  }

  String _expandHome(String path) {
    if (path == '~' || path.startsWith('~/') || path.startsWith(r'~\')) {
      final home =
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        final rest = path.substring(1).replaceFirst(RegExp(r'^[/\\]'), '');
        return p.normalize(p.join(home, rest));
      }
    }
    return p.normalize(path);
  }

  String _tailOutput(String text, int totalChars, bool truncated) {
    if (text.isEmpty) return '';
    const cap = 20000;
    final clipped =
        text.length <= cap ? text : text.substring(text.length - cap);
    final wasClipped = truncated || text.length > cap;
    if (!wasClipped) return clipped;
    final original = totalChars > 0 ? totalChars : text.length;
    return '...(输出过长，仅保留最后 ${clipped.length} 字符，原 $original 字符)\n$clipped';
  }

  String _clipForAudit(String text) {
    if (text.length <= 2000) return text;
    return '...(输出过长，仅保留最后 2000 字符)\n'
        '${text.substring(text.length - 2000)}';
  }

  String _clipForProgress(String command) {
    final oneLine = command.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 160 ? oneLine : '${oneLine.substring(0, 160)}…';
  }
}
