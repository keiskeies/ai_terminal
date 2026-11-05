import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/utils/slash_command.dart';
import 'package:ai_terminal/widgets/ai_prompt_input.dart';

/// P1：斜杠命令解析。
///
/// 改造前的两处硬伤都在这里锁住：
/// 1. 整串 `toLowerCase()` 会把用户的目标原文毁掉，且带参数的输入匹配不到任何
///    case，最终被当成任务发给模型；
/// 2. 反过来也不能把「以 / 开头」都当命令——远程路径就是从这里开头的。
void main() {
  const known = ['/new', '/compact', '/goal'];

  group('parseSlashCommand', () {
    test('命令名与参数分离，参数保留原始大小写', () {
      final parsed = parseSlashCommand('/goal FixNginx-Bug 并验证 200',
          knownNames: known);

      expect(parsed?.name, '/goal');
      expect(parsed?.rest, 'FixNginx-Bug 并验证 200');
      expect(parsed?.hasRest, isTrue);
    });

    test('命令名大小写不敏感，参数不受影响', () {
      final parsed =
          parseSlashCommand('/GOAL KeepThisCase', knownNames: known);

      expect(parsed?.name, '/goal');
      expect(parsed?.rest, 'KeepThisCase');
    });

    test('裸命令没有参数', () {
      final parsed = parseSlashCommand('/goal', knownNames: known);

      expect(parsed?.name, '/goal');
      expect(parsed?.rest, isNull);
      expect(parsed?.hasRest, isFalse);
    });

    test('只有尾随空格不算有参数', () {
      final parsed = parseSlashCommand('/goal   ', knownNames: known);

      expect(parsed?.name, '/goal');
      expect(parsed?.rest, isNull);
    });

    test('命令与正文之间的空白折叠，正文内部空白保留', () {
      final parsed =
          parseSlashCommand('/goal    清理 /var/log 并 归档', knownNames: known);

      expect(parsed?.rest, '清理 /var/log 并 归档');
    });

    test('以 / 开头的远程路径不是命令', () {
      // 这是"首个 / 就当命令"的失效场景：用户要 agent 处理绝对路径
      expect(parseSlashCommand('/etc/nginx 目录权限', knownNames: known), isNull);
      expect(parseSlashCommand('/var/log/syslog 里的报错', knownNames: known),
          isNull);
    });

    test('非命令前缀不误判为命令', () {
      // /goalx 不是注册过的命令；前缀匹配会把打错的输入静默当成命令
      expect(parseSlashCommand('/goalx 清理日志', knownNames: known), isNull);
      expect(parseSlashCommand('/goals 清理日志', knownNames: known), isNull);
    });

    test('不以 / 开头的普通文本不是命令', () {
      expect(parseSlashCommand('帮我看看磁盘', knownNames: known), isNull);
      expect(parseSlashCommand('  帮我看看磁盘', knownNames: known), isNull);
    });

    test('既有命令 /new 与 /compact 仍能解析（改造未回退）', () {
      expect(parseSlashCommand('/new', knownNames: kSlashCommands.map((c) => c.command))?.name,
          '/new');
      expect(
          parseSlashCommand('/compact',
              knownNames: kSlashCommands.map((c) => c.command))
              ?.name,
          '/compact');
      // 注册表里的命令名必须带前导斜杠，否则匹配不上输入
      for (final cmd in kSlashCommands) {
        expect(cmd.command.startsWith('/'), isTrue, reason: cmd.command);
      }
    });

    test('/goal 已注册为候选命令', () {
      expect(kSlashCommands.map((c) => c.command), contains('/goal'));
    });
  });

  group('parseGoalCommand 子命令消歧', () {
    test('独占整句的子命令词才认，edit 收整句参数', () {
      final pause = parseGoalCommand('pause');
      expect(pause.sub, 'pause');
      expect(pause.objective, isEmpty);

      final edit = parseGoalCommand('edit 换成备份 nginx');
      expect(edit.sub, 'edit');
      expect(edit.objective, '换成备份 nginx');
    });

    test('子命令大小写不敏感，但目标文本原样保留', () {
      expect(parseGoalCommand('PAUSE').sub, 'pause');

      final objective = parseGoalCommand('PauseTheService 并回滚');
      // "PauseTheService" 不等于 pause → 整句是目标
      expect(objective.sub, isNull);
      expect(objective.objective, 'PauseTheService 并回滚');
    });

    test('无参子命令后面还有正文时退回成目标', () {
      final g = parseGoalCommand('pause the server 卡住了');
      // 用户其实在描述问题；把输入吞成指令比建出一个可见的目标危险得多
      expect(g.sub, isNull);
      expect(g.objective, 'pause the server 卡住了');

      // 独占整句才是指令
      expect(parseGoalCommand('pause').sub, 'pause');
      expect(parseGoalCommand('done').sub, 'done');

      // 近似词永远不是指令
      final near = parseGoalCommand('paused 队列堆积了');
      expect(near.sub, isNull);
      expect(near.objective, 'paused 队列堆积了');
    });

    test('裸 /goal 与空参数', () {
      final bare = parseGoalCommand(null);
      expect(bare.sub, isNull);
      expect(bare.objective, isEmpty);

      final spaces = parseGoalCommand('   ');
      expect(spaces.objective, isEmpty);
    });

    test('edit 后面的整句都是新目标，哪怕它像句子', () {
      final g = parseGoalCommand('edit 把 /var/log/nginx 按天切割并保留 14 天');
      expect(g.sub, 'edit');
      expect(g.objective, '把 /var/log/nginx 按天切割并保留 14 天');
    });
  });

  group('matchModelNames', () {
    const names = ['GPT-4o', 'gpt-4o-mini', 'DeepSeek-V3', 'agnes-local'];

    test('精确匹配优先于子串，且忽略大小写', () {
      expect(matchModelNames(names, 'GPT-4O'), ['GPT-4o']);
    });

    test('没有精确命中时退回子串', () {
      expect(matchModelNames(names, 'deepseek'), ['DeepSeek-V3']);
    });

    test('子串命中多个时全部返回，交给用户选', () {
      // 没有精确命中才会走子串分支；'gpt-4o' 有精确命中所以不该用在这里
      const twins = ['agnes-local', 'agnes-local-v2', 'DeepSeek-V3'];
      final hits = matchModelNames(twins, 'agnes');
      expect(hits, ['agnes-local', 'agnes-local-v2']);
    });

    test('有精确命中时不再做子串扩散', () {
      const twins = ['agnes-local', 'agnes-local-v2'];
      expect(matchModelNames(twins, 'agnes-local'), ['agnes-local']);
    });

    test('空输入不匹配任何东西', () {
      expect(matchModelNames(names, ''), isEmpty);
      expect(matchModelNames(names, '   '), isEmpty);
    });

    test('没命中返回空列表，不回退成第一个模型', () {
      expect(matchModelNames(names, 'qwen'), isEmpty);
    });
  });

  group('shouldRestorePermissionMode', () {
    test('/plan 进入前不是只读、结束时仍只读 → 要还原原档位', () {
      expect(
        shouldRestorePermissionMode(
            before: AgentPermissionMode.auto, now: AgentPermissionMode.readOnly),
        isTrue,
      );
      expect(
        shouldRestorePermissionMode(
            before: AgentPermissionMode.fullAuto,
            now: AgentPermissionMode.readOnly),
        isTrue,
      );
    });

    test('进入前就是只读 → 结束后保持只读，不重复设置', () {
      // 这是"恢复原值而不是恢复询问"的核心用例：写成询问就会把用户的边界改掉
      expect(
        shouldRestorePermissionMode(
            before: AgentPermissionMode.readOnly,
            now: AgentPermissionMode.readOnly),
        isFalse,
      );
    });

    test('用户在任务期间自己改过档位 → 不覆盖他的选择', () {
      expect(
        shouldRestorePermissionMode(
            before: AgentPermissionMode.ask, now: AgentPermissionMode.auto),
        isFalse,
      );
      expect(
        shouldRestorePermissionMode(
            before: AgentPermissionMode.ask,
            now: AgentPermissionMode.fullAuto),
        isFalse,
      );
      expect(
        shouldRestorePermissionMode(
            before: AgentPermissionMode.ask, now: AgentPermissionMode.ask),
        isFalse,
      );
    });
  });
}
