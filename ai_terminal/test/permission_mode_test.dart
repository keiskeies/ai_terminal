import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/permission_policy.dart';
import 'package:ai_terminal/core/safety_guard.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';

void main() {
  group('decideCommand 四档 × 四风险级', () {
    const expected = {
      AgentPermissionMode.readOnly: {
        SafetyLevel.safe: CommandGateDecision.execute,
        SafetyLevel.info: CommandGateDecision.reject,
        SafetyLevel.warn: CommandGateDecision.reject,
        SafetyLevel.blocked: CommandGateDecision.reject,
      },
      AgentPermissionMode.ask: {
        SafetyLevel.safe: CommandGateDecision.execute,
        SafetyLevel.info: CommandGateDecision.execute,
        SafetyLevel.warn: CommandGateDecision.confirm,
        SafetyLevel.blocked: CommandGateDecision.confirm,
      },
      AgentPermissionMode.auto: {
        SafetyLevel.safe: CommandGateDecision.execute,
        SafetyLevel.info: CommandGateDecision.execute,
        SafetyLevel.warn: CommandGateDecision.execute,
        SafetyLevel.blocked: CommandGateDecision.confirm,
      },
      AgentPermissionMode.fullAuto: {
        SafetyLevel.safe: CommandGateDecision.execute,
        SafetyLevel.info: CommandGateDecision.execute,
        SafetyLevel.warn: CommandGateDecision.execute,
        SafetyLevel.blocked: CommandGateDecision.execute,
      },
    };

    for (final mode in AgentPermissionMode.values) {
      for (final level in SafetyLevel.values) {
        test('${mode.name} × ${level.name}', () {
          expect(decideCommand(level, mode), expected[mode]![level]);
        });
      }
    }

    test('blocked 在询问/自动下不是直接拒绝，而是可确认', () {
      expect(
        decideCommand(SafetyLevel.blocked, AgentPermissionMode.ask),
        CommandGateDecision.confirm,
      );
      expect(
        decideCommand(SafetyLevel.blocked, AgentPermissionMode.auto),
        CommandGateDecision.confirm,
      );
      expect(
        decideCommand(SafetyLevel.blocked, AgentPermissionMode.fullAuto),
        CommandGateDecision.execute,
      );
    });

    test('warn 只有在询问档才确认', () {
      expect(
        decideCommand(SafetyLevel.warn, AgentPermissionMode.ask),
        CommandGateDecision.confirm,
      );
      expect(
        decideCommand(SafetyLevel.warn, AgentPermissionMode.auto),
        CommandGateDecision.execute,
      );
      expect(
        decideCommand(SafetyLevel.warn, AgentPermissionMode.fullAuto),
        CommandGateDecision.execute,
      );
    });
  });

  group('破坏性工具确认', () {
    test('只有全自动跳过确认', () {
      expect(destructiveToolNeedsConfirm(AgentPermissionMode.readOnly), isTrue);
      expect(destructiveToolNeedsConfirm(AgentPermissionMode.ask), isTrue);
      expect(destructiveToolNeedsConfirm(AgentPermissionMode.auto), isTrue);
      expect(destructiveToolNeedsConfirm(AgentPermissionMode.fullAuto), isFalse);
    });
  });

  group('parsePermissionMode', () {
    test('中文名', () {
      expect(parsePermissionMode('只读'), AgentPermissionMode.readOnly);
      expect(parsePermissionMode('询问'), AgentPermissionMode.ask);
      expect(parsePermissionMode('自动'), AgentPermissionMode.auto);
      expect(parsePermissionMode('全自动'), AgentPermissionMode.fullAuto);
    });

    test('英文名与别名，大小写不敏感', () {
      expect(parsePermissionMode('READ-ONLY'), AgentPermissionMode.readOnly);
      expect(parsePermissionMode('ask'), AgentPermissionMode.ask);
      expect(parsePermissionMode('Auto'), AgentPermissionMode.auto);
      expect(parsePermissionMode('full-auto'), AgentPermissionMode.fullAuto);
      expect(parsePermissionMode(' full '), AgentPermissionMode.fullAuto);
    });

    test('空值与未知值返回 null，不猜一个默认档', () {
      expect(parsePermissionMode(null), isNull);
      expect(parsePermissionMode('   '), isNull);
      expect(parsePermissionMode('yolo'), isNull);
    });
  });

  group('事件快照字符串', () {
    test('持久化值必须与 CommandGateDecision 的枚举名一致', () {
      expect(kPermissionDecisionExecute, CommandGateDecision.execute.name);
      expect(kPermissionDecisionConfirm, CommandGateDecision.confirm.name);
      expect(kPermissionDecisionReject, CommandGateDecision.reject.name);
    });
  });

  group('模式稳定标识', () {
    test('id 用于日志与参数，不随枚举顺序变化', () {
      expect(AgentPermissionMode.readOnly.id, 'readOnly');
      expect(AgentPermissionMode.ask.id, 'ask');
      expect(AgentPermissionMode.auto.id, 'auto');
      expect(AgentPermissionMode.fullAuto.id, 'fullAuto');
    });
  });
}
