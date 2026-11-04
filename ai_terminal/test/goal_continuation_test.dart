import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_goal.dart';
import 'package:ai_terminal/utils/goal_continuation.dart';

/// §3.2.4 终态矩阵逐行验证。
///
/// 自动续跑失控是目标模式最大的风险，而这些分支在真机上很难凑齐
/// （要恰好赶上断连、确认超时、预算耗尽），所以必须在纯函数层面逐条钉住。
void main() {
  AgentGoal goal({
    int roundsUsed = 0,
    int maxRounds = 24,
    int lastRoundCommands = 0,
    int noProgressRounds = 0,
    AgentGoalStatus status = AgentGoalStatus.active,
  }) {
    final now = DateTime(2026, 11, 1);
    return AgentGoal(
      id: 'g1',
      hostId: 'web1',
      objective: '把 nginx 日志轮转配好',
      status: status,
      roundsUsed: roundsUsed,
      maxRounds: maxRounds,
      lastRoundCommands: lastRoundCommands,
      noProgressRounds: noProgressRounds,
      createdAt: now,
      updatedAt: now,
    );
  }

  GoalDecision decide({
    AgentGoal? g,
    AgentFinishState? finishState = AgentFinishState.success,
    int commandsRun = 4,
    bool hadConfirmTimeout = false,
    bool connectionAlive = true,
    bool isForegroundHost = true,
    String? finishSummary,
  }) =>
      decideGoalContinuation(
        goal: g ?? goal(),
        finishState: finishState,
        commandsRun: commandsRun,
        hadConfirmTimeout: hadConfirmTimeout,
        connectionAlive: connectionAlive,
        isForegroundHost: isForegroundHost,
        finishSummary: finishSummary,
      );

  group('达成标记识别', () {
    test('行首声明才算达成', () {
      expect(goalMarkedDone('目标已达成：日志已按天轮转'), isTrue);
      expect(goalMarkedDone('小结\n目标已达成'), isTrue);
      expect(goalMarkedDone('   目标已达成'), isTrue);
    });

    test('句中引述不误判为达成', () {
      expect(goalMarkedDone('我还没有完成，谈不上目标已达成'), isFalse);
      expect(goalMarkedDone(null), isFalse);
      expect(goalMarkedDone(''), isFalse);
    });

    test('声明达成时目标转 finished，且带原因', () {
      final d = decide(finishSummary: '目标已达成');
      expect(d.action, GoalAction.finish);
      expect(d.goal.status, AgentGoalStatus.finished);
      expect(d.reason, 'objective_done');
    });
  });

  group('优先级：用户的意图高于一切自动逻辑', () {
    test('用户取消 → paused，不是 finished', () {
      final d = decide(finishState: AgentFinishState.cancelled);
      expect(d.action, GoalAction.pause);
      expect(d.goal.status, AgentGoalStatus.paused);
      expect(d.reason, 'user_cancelled');
    });

    test('取消排在预算检查之前：预算还剩也不能复活成 finished', () {
      final d = decide(
        g: goal(roundsUsed: 3, maxRounds: 24),
        finishState: AgentFinishState.cancelled,
      );
      expect(d.action, GoalAction.pause);
      expect(d.goal.roundsUsed, 3);
    });

    test('达成声明排在取消之前：模型确实完成了就不算用户取消', () {
      final d = decide(
        finishState: AgentFinishState.cancelled,
        finishSummary: '目标已达成',
      );
      expect(d.action, GoalAction.finish);
    });
  });

  group('无人看管与环境异常一律停', () {
    test('确认超时 → paused（继续跑只会反复超时空转）', () {
      final d = decide(hadConfirmTimeout: true);
      expect(d.action, GoalAction.pause);
      expect(d.reason, 'confirm_timeout');
      expect(d.goal.status, AgentGoalStatus.paused);
    });

    test('断连 → paused，不给引擎发注定失败的任务', () {
      final d = decide(connectionAlive: false);
      expect(d.action, GoalAction.pause);
      expect(d.reason, 'disconnected');
    });

    test('已切走会话 → paused，绝不在后台 host 上替用户执行', () {
      final d = decide(isForegroundHost: false);
      expect(d.action, GoalAction.pause);
      expect(d.reason, 'not_foreground');
    });

    test('任务失败 → paused 而不是继续烧 token', () {
      final d = decide(finishState: AgentFinishState.failed);
      expect(d.action, GoalAction.pause);
      expect(d.reason, 'task_failed');
    });
  });

  group('预算与进展', () {
    test('预算耗尽 → finished 并写明用了几轮', () {
      final d = decide(g: goal(roundsUsed: 24, maxRounds: 24));
      expect(d.action, GoalAction.finish);
      expect(d.reason, 'budget_exhausted');
      expect(d.note, contains('24/24'));
    });

    test('有进展 → 续跑并加一轮，无进展计数归零', () {
      final d = decide(g: goal(noProgressRounds: 1), commandsRun: 4);
      expect(d.action, GoalAction.continueRound);
      expect(d.goal.roundsUsed, 1);
      expect(d.goal.noProgressRounds, 0);
      expect(d.goal.lastRoundCommands, 4);
    });

    test('步数用满（interrupted）算有进展，继续跑', () {
      final d = decide(finishState: AgentFinishState.interrupted);
      expect(d.action, GoalAction.continueRound);
    });

    test('两轮各跑同样多条命令不算无进展（真机误判的回归）', () {
      // 旧实现比较 stepIndex，而它是每个任务各自从 1 计的：
      // 两轮都跑 4 条命令会被判成"连续无进展"，目标两轮就停。
      final first = decide(commandsRun: 4);
      expect(first.action, GoalAction.continueRound);
      final second = decide(
        g: goal(lastRoundCommands: 4, roundsUsed: 1),
        commandsRun: 4,
      );
      expect(second.action, GoalAction.continueRound);
      expect(second.goal.noProgressRounds, 0);
    });

    test('一条命令都没跑才算无进展：第一次仍续跑，第二次才停', () {
      final first = decide(commandsRun: 0);
      expect(first.action, GoalAction.continueRound);
      expect(first.goal.noProgressRounds, 1);

      final second = decide(
        g: goal(noProgressRounds: 1),
        commandsRun: 0,
      );
      expect(second.action, GoalAction.pause);
      expect(second.reason, 'no_progress');
      expect(second.goal.status, AgentGoalStatus.paused);
    });

    test('续跑不越预算：第 23 轮跑完是 24 轮，下一轮判定才结束', () {
      final d = decide(g: goal(roundsUsed: 23, maxRounds: 24));
      expect(d.action, GoalAction.continueRound);
      expect(d.goal.roundsUsed, 24);
      expect(d.goal.budgetExhausted, isTrue);
    });
  });

  group('恢复目标必须真的动起来', () {
    test('前台、已连接、没有任务在跑 → 补起一轮', () {
      expect(
        shouldKickGoalRound(
          goalActive: true,
          isForegroundHost: true,
          engineRunning: false,
          connectionAlive: true,
        ),
        isTrue,
      );
    });

    test('已有任务在跑就不抢（它终局时会自己续跑）', () {
      expect(
        shouldKickGoalRound(
          goalActive: true,
          isForegroundHost: true,
          engineRunning: true,
          connectionAlive: true,
        ),
        isFalse,
      );
    });

    test('断线或不在本会话都不补——否则就是假恢复', () {
      expect(
        shouldKickGoalRound(
          goalActive: true,
          isForegroundHost: true,
          engineRunning: false,
          connectionAlive: false,
        ),
        isFalse,
      );
      expect(
        shouldKickGoalRound(
          goalActive: true,
          isForegroundHost: false,
          engineRunning: false,
          connectionAlive: true,
        ),
        isFalse,
      );
    });

    test('目标不是 active 就不补', () {
      expect(
        shouldKickGoalRound(
          goalActive: false,
          isForegroundHost: true,
          engineRunning: false,
          connectionAlive: true,
        ),
        isFalse,
      );
    });
  });

  group('续跑排队守卫', () {
    test('同一个终局任务只续跑一次（取消+异常会连发两个 finish）', () {
      final first = shouldScheduleGoalRound(
        goal: goal(),
        finishingTaskId: 't1',
        alreadyContinuedTaskId: null,
        engineRunning: false,
      );
      final second = shouldScheduleGoalRound(
        goal: goal(),
        finishingTaskId: 't1',
        alreadyContinuedTaskId: 't1',
        engineRunning: false,
      );

      expect(first, isTrue);
      expect(second, isFalse);
    });

    test('引擎还在跑就不抢跑', () {
      expect(
        shouldScheduleGoalRound(
          goal: goal(),
          finishingTaskId: 't1',
          alreadyContinuedTaskId: null,
          engineRunning: true,
        ),
        isFalse,
      );
    });

    test('目标不再活跃就不续跑（排队期间用户可能已暂停）', () {
      expect(
        shouldScheduleGoalRound(
          goal: goal(status: AgentGoalStatus.paused),
          finishingTaskId: 't1',
          alreadyContinuedTaskId: null,
          engineRunning: false,
        ),
        isFalse,
      );
      expect(
        shouldScheduleGoalRound(
          goal: goal(status: AgentGoalStatus.finished),
          finishingTaskId: 't1',
          alreadyContinuedTaskId: null,
          engineRunning: false,
        ),
        isFalse,
      );
    });

    test('没有任务 id 时不因去重被误拦', () {
      expect(
        shouldScheduleGoalRound(
          goal: goal(),
          finishingTaskId: null,
          alreadyContinuedTaskId: 't1',
          engineRunning: false,
        ),
        isTrue,
      );
    });
  });

  group('达成标记不能被当成命令执行', () {
    test('整条命令只是标记时命中守卫', () {
      expect(isGoalMarkerOnlyCommand('目标已达成'), isTrue);
      expect(isGoalMarkerOnlyCommand('  「目标已达成」  '), isTrue);
      expect(isGoalMarkerOnlyCommand('目标已达成。'), isTrue);
    });

    test('真实命令哪怕含这个词也不命中', () {
      // 只拦"整条就是标记"，否则 echo "目标已达成" 这类正常命令会被误杀
      expect(isGoalMarkerOnlyCommand('echo 目标已达成'), isFalse);
      expect(isGoalMarkerOnlyCommand('ls -la'), isFalse);
      expect(isGoalMarkerOnlyCommand(''), isFalse);
    });

    test('续跑提示词明确禁止把标记放进命令块', () {
      final prompt = buildGoalContinuationPrompt(goal());
      expect(prompt, contains('不是命令'));
      expect(prompt, contains('回答:'));
    });
  });

  group('续跑提示词', () {
    test('带轮次与达成约定，不拼历史', () {
      final prompt = buildGoalContinuationPrompt(goal(roundsUsed: 2));

      expect(prompt, contains('第 3/24 轮'));
      expect(prompt, contains('把 nginx 日志轮转配好'));
      expect(prompt, contains(kGoalDoneMarker));
    });
  });

  group('AgentGoal 自身约束', () {
    test('读盘时预算夹回合法区间，异常状态当 paused', () {
      final json = {
        'id': 'g',
        'hostId': 'local',
        'objective': '做点事',
        'status': 'notAStatus',
        'maxRounds': 9999,
        'createdAt': '2026-11-01T00:00:00.000',
        'updatedAt': '2026-11-01T00:00:00.000',
      };
      final restored = AgentGoal.fromJson(json)!;

      // 未知状态宁可当 paused：凭半个字段就自动续跑是不可接受的
      expect(restored.status, AgentGoalStatus.paused);
      expect(restored.maxRounds, AgentGoal.maxAllowedRounds);
    });

    test('没有 objective 的脏数据不还原', () {
      expect(AgentGoal.fromJson({'objective': '  '}), isNull);
      expect(AgentGoal.fromJson(null), isNull);
    });

    test('edit 改目标不重置已用轮次（防止用编辑刷预算）', () {
      final edited = goal(roundsUsed: 20).copyWith(objective: '换成备份');

      expect(edited.objective, '换成备份');
      expect(edited.roundsUsed, 20);
      expect(edited.maxRounds, 24);
    });

    test('resume 超预算时 roundsLeft 为 0 而非负数', () {
      expect(goal(roundsUsed: 30, maxRounds: 24).roundsLeft, 0);
    });
  });
}
