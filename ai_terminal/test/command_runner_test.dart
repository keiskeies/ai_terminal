import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/permission_policy.dart';
import 'package:ai_terminal/core/safety_guard.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/command_runner.dart';

/// 既不是 LocalTerminalService 也不是 SSHService 的执行器：
/// 让预检里的两个"按执行器类型分支"的守卫保持不触发。
class _FakeExecutor implements CommandExecutor {
  @override
  bool get isConnected => true;

  @override
  Stream<String> get output => const Stream.empty();

  @override
  void execute(String command) {}

  @override
  Future<CommandResult> executeAndWait(
    String command, {
    Duration timeout = const Duration(seconds: 60),
    Completer<void>? cancelToken,
    String? sudoPassword,
    Future<String?> Function(String prompt)? onInteractivePrompt,
  }) async =>
      CommandResult(
        stdout: '',
        stderr: '',
        exitCode: 0,
        duration: Duration.zero,
      );

  @override
  Future<CommandResult> writeFileViaPty({
    required String path,
    required Uint8List content,
    bool useSudo = false,
    Duration timeout = const Duration(seconds: 30),
    Completer<void>? cancelToken,
  }) async =>
      CommandResult(
        stdout: '',
        stderr: '',
        exitCode: 0,
        duration: Duration.zero,
      );

  @override
  Future<String> runOnce(String command,
          {Duration timeout = const Duration(seconds: 5)}) async =>
      '';

  @override
  void writeToTerminal(String data) {}
}

void main() {
  group('CommandRunner 纯叶子', () {
    group('logCommand', () {
      test('多行命令只取首行', () {
        expect(CommandRunner.logCommand('ls -la\necho hi'), 'ls -la');
      });

      test('首行前后空白被裁掉', () {
        expect(CommandRunner.logCommand('   whoami   \nnext'), 'whoami');
      });

      test('超长首行截断到 80 并加省略号', () {
        final long = 'a' * 200;
        final out = CommandRunner.logCommand(long);
        expect(out, '${'a' * 80}…');
      });

      test('空命令给占位符', () {
        expect(CommandRunner.logCommand(''), '(空命令)');
        expect(CommandRunner.logCommand('  \n  '), '(空命令)');
      });
    });

    group('truncateForAudit', () {
      test('不超过 500 字符原样返回', () {
        final s = 'x' * 500;
        expect(CommandRunner.truncateForAudit(s), s);
      });

      test('超过 500 字符截断并标注原始长度', () {
        final out = CommandRunner.truncateForAudit('x' * 600);
        expect(out.startsWith('x' * 500), isTrue);
        expect(out, contains('...'));
        expect(out, contains('600 chars'));
      });
    });

    group('remainingAnnouncedCommands', () {
      test('null 事件列表返回空', () {
        expect(CommandRunner.remainingAnnouncedCommands(null), isEmpty);
      });

      test('跳过第一条命令，保留其余命令的事件 id', () {
        final events = <AgentEvent>[
          AgentEvent.command('cmd1', id: 'e1'),
          AgentEvent.thought('思考'),
          AgentEvent.command('cmd2', id: 'e2'),
          AgentEvent.command('cmd3', id: 'e3'),
        ];
        final out = CommandRunner.remainingAnnouncedCommands(events);
        expect(out.length, 2);
        expect(out[0].eventId, 'e2');
        expect(out[0].command, 'cmd2');
        expect(out[1].eventId, 'e3');
      });

      test('空命令被忽略，不影响"第一条"的判定', () {
        final events = <AgentEvent>[
          AgentEvent.command('   ', id: 'e0'),
          AgentEvent.command('cmd1', id: 'e1'),
          AgentEvent.command('cmd2', id: 'e2'),
        ];
        final out = CommandRunner.remainingAnnouncedCommands(events);
        expect(out.length, 1);
        expect(out.single.command, 'cmd2');
      });
    });

    group('phaseForCommand', () {
      test('只读查询命令 → 检查环境', () {
        expect(CommandRunner.phaseForCommand('ls -la', SafetyLevel.safe), '检查环境');
      });

      test('warn/blocked 的修改命令 → 执行变更', () {
        expect(CommandRunner.phaseForCommand('mycmd', SafetyLevel.warn), '执行变更');
        expect(
            CommandRunner.phaseForCommand('mycmd', SafetyLevel.blocked), '执行变更');
      });

      test('safe 的非查询命令 → 执行命令', () {
        expect(
            CommandRunner.phaseForCommand('mycmd', SafetyLevel.safe), '执行命令');
      });

      test('查询命令优先于风险等级', () {
        // isQueryCommand 先判：即使是 warn 级也只读展示
        expect(CommandRunner.phaseForCommand('cat a', SafetyLevel.warn), '检查环境');
      });
    });

    group('enrichCommandEvent', () {
      test('补上 hostId / toolName / riskLevel / permissionDecision', () {
        final e = AgentEvent.command('ls');
        CommandRunner.enrichCommandEvent(
          e,
          hostId: 'h1',
          permissionMode: AgentPermissionMode.ask,
        );
        expect(e.hostId, 'h1');
        expect(e.toolName, 'exec_command');
        expect(e.riskLevel, SafetyGuard.check('ls').name);
        expect(e.permissionDecision, isNotNull);
      });

      test('已有值不被覆盖', () {
        final e = AgentEvent.command('ls',
            hostId: 'original',
            toolName: 'custom_tool',
            riskLevel: 'custom');
        CommandRunner.enrichCommandEvent(
          e,
          hostId: 'h1',
          permissionMode: AgentPermissionMode.ask,
        );
        expect(e.hostId, 'original');
        expect(e.toolName, 'custom_tool');
        expect(e.riskLevel, 'custom');
      });

      test('非命令事件不做任何改写', () {
        final e = AgentEvent.thought('纯粹思考');
        CommandRunner.enrichCommandEvent(
          e,
          hostId: 'h1',
          permissionMode: AgentPermissionMode.ask,
        );
        expect(e.hostId, isNull);
        expect(e.toolName, isNull);
        expect(e.riskLevel, isNull);
      });
    });

    test('blockedCommandReasons 覆盖全部拦截 reason', () {
      expect(
        CommandRunner.blockedCommandReasons,
        containsAll([
          'window_blocked',
          'read_only_blocked',
          'safety_blocked',
          'chained_modification_blocked',
          'user_rejected',
          'confirm_timeout',
          'permission_changed_during_confirm',
        ]),
      );
    });
  });

  group('CommandPreflight', () {
    final executor = _FakeExecutor();
    final emitted = <AgentEvent>[];

    setUp(emitted.clear);

    CommandBlock? evaluate({
      required String command,
      required SafetyLevel safetyLevel,
      required AgentPermissionMode permissionMode,
      required CommandGateDecision decision,
    }) =>
        CommandPreflight.evaluate(
          command: command,
          safetyLevel: safetyLevel,
          executor: executor,
          permissionMode: permissionMode,
          decision: decision,
          emitInfo: emitted.add,
        );

    test('链式修改命令被拦截，reason 落在 blocked 集合内', () {
      final block = evaluate(
        command: 'cat a && rm b',
        safetyLevel: SafetyLevel.warn,
        permissionMode: AgentPermissionMode.fullAuto,
        decision: CommandGateDecision.execute,
      );

      expect(block, isNotNull);
      expect(block!.reasonCode, 'chained_modification_blocked');
      expect(CommandRunner.blockedCommandReasons, contains(block.reasonCode));
      expect(block.observation, contains('链式命令包含修改类操作'));
      expect(block.auditOutput, isNull, reason: 'warn 级不追加 blocked 审计');
      expect(emitted.single.isInfo, isTrue);
    });

    test('链式 blocked 命令额外要求写审计', () {
      final block = evaluate(
        command: 'ls && rm -rf /',
        safetyLevel: SafetyLevel.blocked,
        permissionMode: AgentPermissionMode.fullAuto,
        decision: CommandGateDecision.execute,
      );

      expect(block, isNotNull);
      expect(block!.auditOutput, isNotNull);
      expect(block.auditTag, isNotNull);
    });

    test('只读命令直接放行', () {
      final block = evaluate(
        command: 'ls -la',
        safetyLevel: SafetyLevel.safe,
        permissionMode: AgentPermissionMode.ask,
        decision: CommandGateDecision.execute,
      );
      expect(block, isNull);
      expect(emitted, isEmpty);
    });

    test('只读档拒绝非只读命令 → read_only_blocked', () {
      final block = evaluate(
        command: 'mycmd --write',
        safetyLevel: SafetyLevel.warn,
        permissionMode: AgentPermissionMode.readOnly,
        decision: CommandGateDecision.reject,
      );

      expect(block, isNotNull);
      expect(block!.reasonCode, 'read_only_blocked');
      expect(block.observation, contains('只读模式'));
    });

    test('询问档拒绝 → safety_blocked', () {
      final block = evaluate(
        command: 'mycmd --write',
        safetyLevel: SafetyLevel.warn,
        permissionMode: AgentPermissionMode.ask,
        decision: CommandGateDecision.reject,
      );

      expect(block, isNotNull);
      expect(block!.reasonCode, 'safety_blocked');
      expect(block.auditOutput, isNull);
    });

    test('blocked 级拒绝时附带审计正文与分支标记', () {
      final block = evaluate(
        command: 'mycmd --write',
        safetyLevel: SafetyLevel.blocked,
        permissionMode: AgentPermissionMode.ask,
        decision: CommandGateDecision.reject,
      );

      expect(block, isNotNull);
      expect(block!.reasonCode, 'safety_blocked');
      expect(block.auditOutput, isNotNull);
      expect(block.auditTag, '拦截分支');
    });

    test('confirm 决策不拦截（交给引擎的确认握手）', () {
      final block = evaluate(
        command: 'mycmd --write',
        safetyLevel: SafetyLevel.warn,
        permissionMode: AgentPermissionMode.ask,
        decision: CommandGateDecision.confirm,
      );
      expect(block, isNull);
    });
  });
}
