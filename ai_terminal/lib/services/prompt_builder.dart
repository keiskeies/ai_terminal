import 'dart:io';

import '../models/agent_permission_mode.dart';
import '../models/plan_step.dart';
import '../services/command_executor.dart';
import '../services/ssh_service.dart';

/// System prompt 中的纯文本段落构建器（R4：纯函数，无引擎实例状态）。
///
/// `_buildSystemPrompt` 主体因深度依赖引擎实例字段（`_tools`/`_memory`/
/// `_modelConfig` 等）暂留在 AgentEngine 内；这里只收拢可显式传参的
/// 纯文本叶子，便于独立测试与后续 ToolOrchestrator 迁移后回看。
class PromptBuilder {
  /// 计划进度段起止标记（幂等替换靠它们定位整段，engine 侧共享同一来源）
  static const String planProgressStartMarker = '【当前计划进度】';
  static const String planProgressEndMarker = '【/当前计划进度】';

  /// 判断命令是否调用了 sudo（作为命令词，避免匹配 sudoers 等单词）
  static final RegExp _sudoCommandPattern =
      RegExp(r'(^|[\s;&|`(])sudo([\s]|$)');

  static bool isSudoCommand(String command) =>
      _sudoCommandPattern.hasMatch(command);

  /// PlanStepStatus → 计划块标记（与 prompts.dart 的协议一致）
  static String planStatusGlyph(PlanStepStatus status) {
    switch (status) {
      case PlanStepStatus.completed:
        return 'x';
      case PlanStepStatus.inProgress:
        return '>';
      case PlanStepStatus.failed:
        return '!';
      case PlanStepStatus.skipped:
        return '-';
      case PlanStepStatus.pending:
        return ' ';
    }
  }

  /// 生成计划进度段：计划各行 + finish 完整性指令
  static String buildPlanProgressBlock(List<PlanStep> plan) {
    final buffer = StringBuffer()..writeln(planProgressStartMarker);
    for (final step in plan) {
      buffer.writeln('- [${planStatusGlyph(step.status)}] ${step.title}');
    }
    buffer
      ..writeln('按实际进度更新计划块；finish 前不得遗留待处理/进行中项，不做的标跳过。')
      ..write(planProgressEndMarker);
    return buffer.toString();
  }

  /// 执行位置段落：把"execute 在远程 / local_exec 在本机"说死。
  ///
  /// 截图故障：远程 Linux 会话里模型生成了 PowerShell，execute 原样发给 bash，
  /// 报 `mkdir: 无效的选项 -- F` / `Select-Object: 未找到命令`。工具描述与
  /// 远程误发拦截是第一道，这里是模型每轮都能看到的长期约束。
  static String executionLocationPrompt(CommandExecutor? executor) {
    final localOs = Platform.isWindows
        ? 'Windows'
        : Platform.isMacOS
            ? 'macOS'
            : Platform.isLinux
                ? 'Linux'
                : Platform.operatingSystem;
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    final buffer = StringBuffer()..writeln('【执行位置】');
    if (executor is SSHService) {
      final remoteFirstLine = executor.osInfo.trim().split('\n').first.trim();
      final remote = remoteFirstLine.isEmpty ? '未知系统' : remoteFirstLine;
      buffer.writeln('- 动作: execute 运行在：远程服务器（$remote）');
      buffer.writeln('- 运行 App 的本机：$localOs，主机名 ${Platform.localHostname}'
          '${home.isEmpty ? '' : '，主目录 $home'}');
      buffer.writeln(
          '- 本机命令（Docker Desktop、盘符路径如 D:\\...、本机文件/服务）必须使用 local_exec 工具；');
      buffer.writeln('  不要把 PowerShell/cmd 语法发给远程 shell。服务器上的普通命令继续用 execute。');
    } else if (executor != null) {
      buffer.writeln('- 动作: execute 运行在：本机终端（$localOs）。本机路径可直接在 execute 中使用。');
    } else {
      buffer.writeln('- 当前未连接执行器；运行 App 的本机为 $localOs。');
    }
    return buffer.toString();
  }

  /// 当前权限档位对应的 system prompt 段落。
  ///
  /// 必须和 decideCommand 的实际行为一致：模型知道哪些命令会等待确认，
  /// 才不会在只读档反复重试，或在全自动档仍声称"等你确认"。
  static String permissionModePrompt(AgentPermissionMode mode) {
    switch (mode) {
      case AgentPermissionMode.readOnly:
        return '''【执行权限：只读】
当前为只读档，你只能执行只读命令（如 ls/cat/ps/grep/systemctl status 等）。
任何可能产生副作用的命令（安装/修改/重启/删除等）都会被系统直接拒绝，不需要询问用户确认。
工具调用同样受限：除只读工具（如 cert_check、multi_grep、project_analyze）外，
写入类工具（file_write/file_patch/sftp_upload 等）会被系统拒绝执行。
若任务必须修改系统才能完成，请用 finish 动作告知用户"当前为只读模式，请切换权限档位后重试"。''';
      case AgentPermissionMode.ask:
        return '''【执行权限：询问】
低风险只读命令自动执行；修改类命令（删除、安装、服务重启等）与安全策略标记的高危命令
会等待用户确认后才执行。不要声称命令已经执行，也不要在确认结果返回前继续下一步。''';
      case AgentPermissionMode.auto:
        return '''【执行权限：自动】
普通修改类命令会自动执行；被安全策略标记为高危的命令（如删除系统配置、关机、
清空防火墙、格式化磁盘等）仍会等待用户确认。执行前仍要说明影响，不要编造执行结果。''';
      case AgentPermissionMode.fullAuto:
        return '''【执行权限：全自动】
所有命令（包括安全策略标记为高危的命令）与破坏性工具都会直接执行，不再询问用户。
封网期与敏感文件访问限制仍会生效，被它们拦下的命令不要反复重试。
执行前仍要说明预期影响；不要声称"等待用户确认"，也不要因为命令危险就跳过用户明确要求的目标。''';
    }
  }
}
