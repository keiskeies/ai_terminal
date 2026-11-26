import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/widgets/agent_command_block.dart';
import 'package:ai_terminal/widgets/agent_event_cards.dart';

/// 过程时间线渲染测试
///
/// 通过 AgentEventContent 走真实装配路径 —— 它决定"哪些事件进时间线、
/// 哪些仍是正文/询问/完成卡片"，这条分流本身就是最容易出错的地方。
Widget _wrap(Widget child) => MaterialApp(
      theme: AppTheme.darkTheme,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Builder(builder: (context) => child),
        ),
      ),
    );

Widget _content(List<AgentEvent> events,
        {bool isLoading = false,
        String? executingCommand,
        bool agentExecuting = false,
        String? pendingConfirmCommand,
        bool isWaitingChoice = false,
        List<String> pendingOptions = const [],
        void Function(String)? onSelectChoice}) =>
    Builder(
      builder: (context) => AgentEventContent(
        events: events,
        tc: ThemeColors.of(context),
        isLoading: isLoading,
        executingCommand: executingCommand,
        agentExecuting: agentExecuting,
        pendingConfirmCommand: pendingConfirmCommand,
        isWaitingChoice: isWaitingChoice,
        pendingOptions: pendingOptions,
        onSelectChoice: onSelectChoice,
        markdownBuilder: (text, tc) => Text(text),
      ),
    );

List<AgentEvent> _turn({required int steps}) {
  final events = <AgentEvent>[];
  for (var i = 0; i < steps; i++) {
    final cmd = AgentEvent.command(
      'local_file_read\n  path: /etc/file$i.conf',
      id: 'cmd-$i',
      toolName: 'local_file_read',
    );
    events.add(AgentEvent.thought('思考 $i：需要确认第 $i 项配置'));
    events.add(cmd);
    events.add(AgentEvent.result(
      commandId: 'cmd-$i',
      success: true,
      output: '输出内容$i',
      toolName: 'local_file_read',
      durationMs: 100 + i,
    ));
  }
  return events;
}

void main() {
  testWidgets('工具调用折成一行：显示工具名与关键参数，不显示输出', (tester) async {
    await tester.pumpWidget(_wrap(_content(_turn(steps: 1))));
    await tester.pump();

    expect(find.text('local_file_read'), findsOneWidget);
    expect(find.textContaining('/etc/file0.conf'), findsOneWidget);
    expect(find.textContaining('输出内容0'), findsNothing,
        reason: '输出属于展开后的详情，不该在摘要行里');
  });

  testWidgets('点击行展开后看到结果详情', (tester) async {
    await tester.pumpWidget(_wrap(_content(_turn(steps: 1))));
    await tester.pump();

    await tester.tap(find.text('local_file_read'));
    await tester.pump();

    expect(find.textContaining('输出内容0'), findsWidgets);
  });

  testWidgets('失败的命令默认收起：状态一行可见，点开才铺错误', (tester) async {
    final cmd = AgentEvent.command('systemctl restart nginx', id: 'c1');
    final events = [
      cmd,
      AgentEvent.result(
        commandId: 'c1',
        success: false,
        error: 'Job for nginx.service failed',
        toolName: 'exec_command',
      ),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    expect(find.textContaining('systemctl restart nginx'), findsWidgets);
    expect(find.textContaining('失败'), findsWidgets, reason: '失败状态必须一眼可见');
    expect(find.textContaining('Job for nginx.service failed'), findsNothing,
        reason: '十几条失败同时摊开会把真正的流程挤出屏幕');

    await tester.tap(find.textContaining('systemctl restart nginx').first);
    await tester.pump();
    expect(find.textContaining('Job for nginx.service failed'), findsWidgets,
        reason: '点开后错误原文必须完整可见');
  });

  testWidgets('步骤不做「更早 N 步」折叠，12 步全部留在原位', (tester) async {
    await tester.pumpWidget(_wrap(_content(_turn(steps: 12), isLoading: true)));
    await tester.pump();

    expect(find.text('local_file_read').evaluate().length, 12,
        reason: '每个步骤都要在，不能收成一条摘要');
    expect(find.textContaining('更早'), findsNothing);
  });

  testWidgets('两步全部展示，没有折叠头', (tester) async {
    await tester.pumpWidget(_wrap(_content(_turn(steps: 2))));
    await tester.pump();

    expect(find.text('local_file_read').evaluate().length, 2);
    expect(find.text('全部完成'), findsNothing, reason: '不做批次折叠：无论几条命令都不会冒出折叠头');
  });

  testWidgets('命令之间夹着日志与思考：各自留在原位，不折叠', (tester) async {
    // 真机会话形态：说明文字与日志夹在命令之间。批次折叠在这里只会
    // 产生"前两条成组、后面全单条"的随机结构（2026-11-22 用户反馈），
    // 所以过程行一律留在原位，各占一行。
    final events = <AgentEvent>[
      AgentEvent.command('echo c1', id: 'n1'),
      AgentEvent.result(commandId: 'n1', success: true, output: 'a'),
      AgentEvent.command('echo c2', id: 'n2'),
      AgentEvent.result(commandId: 'n2', success: true, output: 'b'),
      AgentEvent.thought('开头的统计行被截断了，再补一条短命令'),
      AgentEvent.info('The current directory is C:\\Users\\Administrator'),
      AgentEvent.command('echo c3', id: 'n3'),
      AgentEvent.result(commandId: 'n3', success: true, output: 'c'),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    expect(find.text('终端命令'), findsNWidgets(3));
    expect(find.textContaining('开头的统计行被截断了'), findsOneWidget);
    expect(find.textContaining('C:\\Users\\Administrator'), findsOneWidget);
    expect(find.text('全部完成'), findsNothing);
  });

  testWidgets('运行中的命令留在原位并切到「执行中」（相邻命令不折叠）', (tester) async {
    final events = <AgentEvent>[];
    for (var i = 0; i < 3; i++) {
      events.add(AgentEvent.command('echo done$i', id: 'd$i'));
      events.add(
          AgentEvent.result(commandId: 'd$i', success: true, output: 'ok$i'));
    }
    events.add(AgentEvent.command('sleep 300', id: 'running'));
    await tester.pumpWidget(_wrap(_content(
      events,
      isLoading: true,
      executingCommand: 'sleep 300',
    )));
    await tester.pump();

    expect(find.text('终端命令'), findsNWidgets(3), reason: '已完成的命令照常各占一行');
    expect(find.textContaining('sleep 300'), findsWidgets,
        reason: '运行中的行必须直接可见');
    expect(find.text('执行中'), findsOneWidget);
  });

  testWidgets('浅色主题下过程行可读', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: _content(_turn(steps: 3)),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('local_file_read'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('引擎执行阶段用 agentExecuting 标记运行中（executingCommand 为空）',
      (tester) async {
    // 引擎执行从不设置 executingCommand（那是手动播放的 800ms 状态），
    // 真机回归：只有命令串相等判断时，运行中的卡片一直显示「可执行」。
    final events = <AgentEvent>[
      AgentEvent.command('echo done', id: 'e1'),
      AgentEvent.result(commandId: 'e1', success: true, output: 'ok'),
      AgentEvent.command('tail -f /var/log/syslog', id: 'e2'),
    ];
    await tester.pumpWidget(_wrap(_content(
      events,
      isLoading: true,
      agentExecuting: true,
    )));
    await tester.pump();

    expect(find.text('执行中'), findsOneWidget,
        reason: 'phase 已进入执行阶段，最后一条无结果命令就是运行中的那条');
    expect(find.text('可执行'), findsNothing);
  });

  testWidgets('引擎思考阶段不误标运行中', (tester) async {
    final events = <AgentEvent>[
      AgentEvent.command('echo done', id: 't1'),
      AgentEvent.result(commandId: 't1', success: true, output: 'ok'),
      AgentEvent.command('tail -f /var/log/syslog', id: 't2'),
    ];
    await tester.pumpWidget(_wrap(_content(
      events,
      isLoading: true,
      agentExecuting: false,
    )));
    await tester.pump();

    expect(find.text('执行中'), findsNothing);
    expect(find.text('可执行'), findsOneWidget);
  });

  testWidgets('运行中的命令块显示已用时间（秒级）', (tester) async {
    await tester.pumpWidget(_wrap(Builder(
      builder: (context) => AgentCommandBlock(
        command: 'tail -f /var/log/syslog',
        tc: ThemeColors.of(context),
        executingCommand: 'tail -f /var/log/syslog',
        runningSince:
            DateTime.now().subtract(const Duration(minutes: 1, seconds: 5)),
      ),
    )));
    await tester.pump();

    expect(find.text('执行中'), findsOneWidget);
    expect(find.text('1m05s'), findsOneWidget);
  });

  testWidgets('还没结果的可执行命令不被折叠', (tester) async {
    final pending = AgentEvent.command('apt install nginx', id: 'p1');
    await tester.pumpWidget(_wrap(_content([pending], isLoading: true)));
    await tester.pump();

    expect(find.textContaining('更早'), findsNothing);
    expect(find.textContaining('apt install nginx'), findsWidgets);
  });

  testWidgets('思考独立成行，正文仍走 Markdown', (tester) async {
    final events = [
      AgentEvent.thought('先看端口占用'),
      AgentEvent.text('这是面向用户的回答正文'),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    expect(find.textContaining('先看端口占用'), findsOneWidget);
    expect(find.textContaining('这是面向用户的回答正文'), findsOneWidget);
  });

  testWidgets('询问行不参与折叠', (tester) async {
    final events = [
      ..._turn(steps: 12),
      AgentEvent.ask('要重启服务吗？', ['重启', '不重启']),
    ];
    await tester.pumpWidget(_wrap(_content(events, isLoading: true)));
    await tester.pump();

    expect(find.textContaining('要重启服务吗'), findsOneWidget);
  });

  testWidgets('正文夹在命令与结果之间时，工具调用不得渲染两遍', (tester) async {
    // 回归：早期按"连续过程段"分段，一个 text 事件就会把 command 和它的 result
    // 切到两个批次，批次内查不到结果 → 同一个调用既出重量级命令块又出时间线行
    final cmd = AgentEvent.command(
      'local_file_read\n  path: /etc/a.conf',
      id: 'dup-1',
      toolName: 'local_file_read',
    );
    final events = [
      AgentEvent.thought('先读配置'),
      cmd,
      AgentEvent.text('这是夹在中间的回答正文'),
      AgentEvent.result(
        commandId: 'dup-1',
        success: true,
        output: '内容A',
        toolName: 'local_file_read',
      ),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    expect(find.text('local_file_read'), findsOneWidget,
        reason: '同一个工具调用只能有一行');
    expect(find.textContaining('这是夹在中间的回答正文'), findsOneWidget);
  });

  testWidgets('单步与两连跑都保持原卡，不折叠', (tester) async {
    await tester.pumpWidget(_wrap(_content(_turn(steps: 2))));
    await tester.pump();

    expect(find.text('local_file_read'), findsNWidgets(2));
    expect(find.text('全部完成'), findsNothing);
  });

  testWidgets('询问之后的过程事件必须渲染在询问下方（按原始顺序交错）', (tester) async {
    final events = [
      AgentEvent.command('echo first', id: 'c1'),
      AgentEvent.result(commandId: 'c1', success: true, output: 'ok'),
      AgentEvent.ask('要不要继续？', ['继续']),
      AgentEvent.thought('继续检查'),
      AgentEvent.command('echo second', id: 'c2'),
      AgentEvent.result(commandId: 'c2', success: true, output: 'ok2'),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    final askY = tester.getTopLeft(find.text('要不要继续？')).dy;
    final laterCommandY =
        tester.getTopLeft(find.textContaining('echo second')).dy;
    expect(askY, lessThan(laterCommandY), reason: '询问卡片不能永远沉在消息底部，后续过程事件应在它下面');
  });

  testWidgets('正文之后的过程事件渲染在正文下方（不把正文统一挪到最后）', (tester) async {
    final events = [
      AgentEvent.command('echo one', id: 'a1'),
      AgentEvent.result(commandId: 'a1', success: true, output: 'ok'),
      AgentEvent.text('这是一段中间说明'),
      AgentEvent.command('echo two', id: 'a2'),
      AgentEvent.result(commandId: 'a2', success: true, output: 'ok2'),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    final firstY = tester.getTopLeft(find.textContaining('echo one')).dy;
    final textY = tester.getTopLeft(find.text('这是一段中间说明')).dy;
    final secondY = tester.getTopLeft(find.textContaining('echo two')).dy;
    expect(firstY, lessThan(textY));
    expect(textY, lessThan(secondY));
  });

  testWidgets('等待选择时只有最后一个询问可点', (tester) async {
    final picked = <String>[];
    final events = [
      AgentEvent.ask('旧问题', ['旧选项']),
      AgentEvent.ask('新问题', ['新选项']),
    ];
    await tester.pumpWidget(_wrap(_content(
      events,
      isWaitingChoice: true,
      pendingOptions: const ['新选项'],
      onSelectChoice: picked.add,
    )));
    await tester.pump();

    // 历史询问收成一行（问题 + 无答案胶囊），展开才见选项；点它不触发作答
    expect(find.text('旧选项'), findsNothing, reason: '已回答的询问默认收起，不占步骤流');
    await tester.tap(find.text('旧问题'));
    await tester.pump();
    expect(picked, isEmpty, reason: '历史询问不能再被当成当前问题作答');

    await tester.tap(find.text('新选项'));
    await tester.pump();
    expect(picked, ['新选项']);
  });

  testWidgets('破坏性工具等待确认时必须给出批准入口', (tester) async {
    // 回归：AgentCommandBlock 的确认按钮条件是 dangerous && isWaitingConfirm，
    // 而 dangerous 早期写成 !isTool && ... —— 工具调用永远不 dangerous，
    // 于是 local_file_delete 的确认界面根本不出现，任务只能挂到超时被自动拒绝。
    const display = 'local_file_delete\n  path: D:\\x\\note.txt\n  hard: false';
    final events = [
      AgentEvent.command(display, id: 'del-1', toolName: 'local_file_delete'),
    ];
    String? confirmed;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => AgentEventContent(
            events: events,
            tc: ThemeColors.of(context),
            isLoading: true,
            pendingConfirmCommand: display,
            markdownBuilder: (text, tc) => Text(text),
            onConfirmCommand: (c) => confirmed = c,
            onRejectCommand: () {},
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('确认执行'), findsOneWidget, reason: '没有批准入口的确认门等于把任务挂死');
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('确认执行'));
    expect(confirmed, display);
  });

  testWidgets('工具调用在没有等待确认时不显示批准按钮', (tester) async {
    final events = [
      AgentEvent.command('local_file_read\n  path: /a',
          id: 'r-1', toolName: 'local_file_read'),
    ];
    await tester.pumpWidget(_wrap(_content(events, isLoading: true)));
    await tester.pump();

    expect(find.text('确认执行'), findsNothing, reason: '只读工具不该被标成待确认');
  });

  testWidgets('找不到对应命令的结果仍要露出来', (tester) async {
    // 孤儿 result 通常就是失败：命令被裁剪/旧数据里没有，但错误必须见得到。
    // 哪天有人"优化"成只渲染配对成功的 result，这些失败就会静默消失。
    final events = [
      AgentEvent.command('local_file_read\n  path: /etc/a.conf',
          id: 'cmd-known', toolName: 'local_file_read'),
      AgentEvent.result(
        commandId: 'cmd-vanished',
        success: false,
        error: 'Permission denied reading /etc/shadow',
        toolName: 'local_file_read',
      ),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    expect(find.textContaining('Permission denied reading /etc/shadow'),
        findsWidgets,
        reason: '没有对应命令的结果也要渲染，否则失败被吞掉');
  });

  testWidgets('预检拦截的结果卡显示拦截原因，不写「(无输出)」', (tester) async {
    // 未闭合/交互式命令从未进 shell，引擎把占位串留在 output、原因放在 error。
    // 卡片若只读 output，用户看到的就是一句「(无输出)」，不知道为什么被拦下。
    final events = [
      AgentEvent.command('top', id: 'blk-1'),
      AgentEvent.result(
        commandId: 'blk-1',
        success: false,
        output: '(无输出)',
        error: '交互式命令会持续运行不返回',
        toolName: 'exec_command',
      ),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    await tester.tap(find.text('终端命令').first);
    await tester.pump();

    expect(find.textContaining('交互式命令会持续运行不返回'), findsWidgets,
        reason: '拦截原因就是卡片正文');
    expect(find.text('(无输出)'), findsNothing);
  });

  testWidgets('预检拦截的孤儿结果行取 error 作摘要', (tester) async {
    final events = [
      AgentEvent.result(
        commandId: 'blk-vanished',
        success: false,
        output: '(无输出)',
        error: '命令未闭合：双引号未闭合',
        toolName: 'exec_command',
      ),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    expect(find.textContaining('命令未闭合：双引号未闭合'), findsWidgets);
    expect(find.text('(无输出)'), findsNothing);
  });

  testWidgets('本机文件工具的确认框说"本机"，不说"服务器"', (tester) async {
    // 回归：影响面板曾用 RiskExplainer.explain(展示串)，工具的展示串按
    // shell 语义推不出类型 → other 分支输出"修改服务器状态，请确认影响范围"。
    // 用户就是看着这句话按批准的，说错影响对象比不说更糟。
    const display = 'local_file_delete\n  path: D:\\x\\note.txt\n  hard: false';
    await tester.pumpWidget(_wrap(_content(
      [AgentEvent.command(display, id: 'del-2', toolName: 'local_file_delete')],
      isLoading: true,
      pendingConfirmCommand: display,
    )));
    await tester.pump();

    expect(find.text('确认执行'), findsOneWidget);
    expect(find.textContaining('本机'), findsWidgets);
    expect(find.textContaining('修改服务器状态'), findsNothing);
    expect(find.textContaining('建议先快照'), findsNothing,
        reason: '删除走回收区、可还原，再说"无自动回滚"自相矛盾，会劝用户放弃本该安全的操作');
    expect(find.textContaining('回收区'), findsWidgets);
    // 批准按钮必须排在影响/还原行之后：面板滚到底时两者同屏。
    // 曾放在卡片头部，用户看到"删除本机文件"时还得往上滚才能点批准。
    final impactBottom = tester.getBottomLeft(find.textContaining('回收区').last);
    final confirmTop = tester.getTopLeft(find.text('确认执行'));
    expect(confirmTop.dy, greaterThan(impactBottom.dy),
        reason: '确认按钮要紧跟在影响说明下面，不能回到卡片头部');
  });

  group('询问卡片', () {
    Widget askContent({
      required AgentEvent ask,
      required bool isWaitingChoice,
      void Function(String)? onSelectChoice,
      List<AgentEvent> extraEvents = const [],
    }) =>
        Builder(
          builder: (context) => AgentEventContent(
            events: [ask, ...extraEvents],
            tc: ThemeColors.of(context),
            isWaitingChoice: isWaitingChoice,
            pendingOptions:
                isWaitingChoice ? (ask.options ?? const []) : const [],
            markdownBuilder: (text, tc) => Text(text),
            onSelectChoice: onSelectChoice,
          ),
        );

    testWidgets('提问文字来自 ask 事件，不再固定显示"请选择"', (tester) async {
      await tester.pumpWidget(_wrap(askContent(
        ask: AgentEvent.ask('有多个 Java 版本可装，选哪个？', ['Java 8', 'Java 17']),
        isWaitingChoice: true,
      )));
      await tester.pump();

      expect(find.text('有多个 Java 版本可装，选哪个？'), findsOneWidget);
    });

    testWidgets('提问正文走 Markdown 渲染（表格不再显示成竖线文本）', (tester) async {
      const question = '**重点**\n\n| 方案 | 代价 |\n|---|---|\n| A | 低 |';
      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => AgentEventContent(
          events: [
            AgentEvent.ask(question, ['继续'])
          ],
          tc: ThemeColors.of(context),
          isWaitingChoice: true,
          pendingOptions: const ['继续'],
          markdownBuilder: (text, tc) => Text('MD:$text'),
          onSelectChoice: (_) {},
        ),
      )));
      await tester.pump();

      expect(find.text('MD:$question'), findsOneWidget);
    });

    testWidgets('等待选择时渲染选项且可点击', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(_wrap(askContent(
        ask: AgentEvent.ask('选哪个？', ['Java 8', 'Java 17']),
        isWaitingChoice: true,
        onSelectChoice: picked.add,
      )));
      await tester.pump();

      expect(find.text('Java 17'), findsOneWidget);
      await tester.tap(find.text('Java 17'));
      expect(picked, ['Java 17']);
    });

    testWidgets('任务已推进/历史回看：收成一行问题+答案，点开选项仍在', (tester) async {
      await tester.pumpWidget(_wrap(askContent(
        ask: AgentEvent.ask('选哪个？', ['Java 8', 'Java 17']),
        isWaitingChoice: false,
        extraEvents: [AgentEvent.info('👉 你选择了: Java 17')],
      )));
      await tester.pump();

      // 收起态：一行问题 + 绿色答案胶囊，选项不铺开
      expect(find.text('选哪个？'), findsOneWidget);
      expect(find.text('Java 17'), findsOneWidget, reason: '用户选了什么必须一直可见');
      expect(find.text('Java 8'), findsNothing);

      // 点开：完整问题与当时的选项仍可回看
      await tester.tap(find.text('选哪个？'));
      await tester.pump();
      expect(find.text('Java 8'), findsOneWidget);
      expect(find.text('Java 17'), findsWidgets);
    });

    testWidgets('非等待态点选项不会回调', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(_wrap(askContent(
        ask: AgentEvent.ask('选哪个？', ['Java 8']),
        isWaitingChoice: false,
        onSelectChoice: picked.add,
      )));
      await tester.pump();

      await tester.tap(find.text('选哪个？')); // 先展开历史询问
      await tester.pump();
      await tester.tap(find.text('Java 8'));
      await tester.pump();
      expect(picked, isEmpty);
    });

    testWidgets('答完后提问步骤仍在，且答案来自事件本身（不靠事后扫描）', (tester) async {
      final ask = AgentEvent.ask('选哪个？', ['Java 8', 'Java 17'])
        ..chosenAnswer = 'Java 17';
      await tester.pumpWidget(_wrap(askContent(
        ask: ask,
        isWaitingChoice: false,
      )));
      await tester.pump();

      // 问题与答案都必须还在（引擎回写 chosenAnswer，不依赖后面的 info 事件）
      expect(find.text('选哪个？'), findsOneWidget);
      expect(find.text('Java 17'), findsOneWidget);
    });

    testWidgets('两轮内容相同的提问都留档，不会因 id 相同互相顶掉', (tester) async {
      // 复现真实 bug：两轮 AI 调用里选项完全相同，若事件 id 撞车，
      // Flutter 同层重复 key 会让整块提问步骤渲染失败（"问完就没"）。
      final a1 = AgentEvent.ask('选哪个？', ['Java 8', 'Java 17'], id: 'evt_1_aaa')
        ..chosenAnswer = 'Java 8';
      final a2 = AgentEvent.ask('选哪个？', ['Java 8', 'Java 17'], id: 'evt_1_aaa')
        ..chosenAnswer = 'Java 17';

      await tester.pumpWidget(_wrap(Builder(
        builder: (context) => AgentEventContent(
          events: [a1, a2],
          tc: ThemeColors.of(context),
          isWaitingChoice: false,
          markdownBuilder: (text, tc) => Text(text),
        ),
      )));
      await tester.pump();

      // 两个提问都要在（至少各出现一次）
      expect(find.text('选哪个？'), findsNWidgets(2));
      expect(tester.takeException(), isNull, reason: '重复 key 会让整块提问渲染失败');
    });

    testWidgets('完整流程：提问出现 → 用户作答 → 提问仍在，可展开看选项', (tester) async {
      // 复现用户描述的场景："输出过程中出现提问，等提问结束后提问就不见了"。
      // 这里模拟真实的状态迁移：同一批事件，先等待作答，答完后再渲染。
      final ask = AgentEvent.ask('有多个 Java 版本可装，选哪个？', ['Java 8', 'Java 17']);

      // 阶段一：等待作答 —— 完整卡片 + 可点选项
      await tester.pumpWidget(_wrap(askContent(
        ask: ask,
        isWaitingChoice: true,
        onSelectChoice: (_) {},
      )));
      await tester.pump();
      expect(find.text('有多个 Java 版本可装，选哪个？'), findsOneWidget);
      expect(find.text('Java 17'), findsOneWidget);

      // 阶段二：用户选了 Java 17（引擎把答案回写到事件上）
      ask.chosenAnswer = 'Java 17';
      await tester.pumpWidget(_wrap(askContent(
        ask: ask,
        isWaitingChoice: false,
      )));
      await tester.pump();

      // 提问必须还在，且答案可见
      expect(find.text('有多个 Java 版本可装，选哪个？'), findsOneWidget,
          reason: '答完问题就消失 = 步骤流断档');
      expect(find.text('Java 17'), findsOneWidget, reason: '用户选了什么必须留在提问步骤里');

      // 点开：完整问题与当时的选项仍可回看
      await tester.tap(find.text('有多个 Java 版本可装，选哪个？'));
      await tester.pump();
      expect(find.text('Java 8'), findsOneWidget);
      expect(find.text('你的选择：Java 17'), findsOneWidget);
    });

    testWidgets('等待选择时可以输入自定义回答', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(_wrap(askContent(
        ask: AgentEvent.ask('怎么处理？', ['加入 docker 组', '不加组']),
        isWaitingChoice: true,
        onSelectChoice: picked.add,
      )));
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '  用官方脚本安装，但不加组  ');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(picked, ['用官方脚本安装，但不加组']);
    });

    testWidgets('自定义回答为空时不提交', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(_wrap(askContent(
        ask: AgentEvent.ask('怎么处理？', ['加入 docker 组']),
        isWaitingChoice: true,
        onSelectChoice: picked.add,
      )));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(picked, isEmpty);
    });

    testWidgets('历史询问不再显示自定义输入框', (tester) async {
      await tester.pumpWidget(_wrap(askContent(
        ask: AgentEvent.ask('怎么处理？', ['加入 docker 组']),
        isWaitingChoice: false,
        onSelectChoice: (_) {},
      )));
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('无提问文字时回落到占位文案', (tester) async {
      await tester.pumpWidget(_wrap(askContent(
        ask: AgentEvent.ask(null, ['继续', '取消']),
        isWaitingChoice: true,
      )));
      await tester.pump();

      expect(find.text('请选择'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });
  });

  testWidgets('连续进度流合并成一行，点开才逐条铺开', (tester) async {
    // 一次上传会产生 100 条 `上传进度: n/100 文件`；逐条铺开等于用日志把
    // 推理和失败挤出屏幕。合并后只留一行，点开才看采样点。
    final events = <AgentEvent>[
      AgentEvent.thought('先上传文件'),
      for (var i = 1; i <= 100; i++) AgentEvent.info('上传进度: $i/100 文件'),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    expect(find.text('上传进度'), findsOneWidget);
    expect(find.text('100/100 文件'), findsOneWidget);
    expect(find.text('100 条'), findsOneWidget);
    expect(find.textContaining('上传进度: 1/100'), findsNothing,
        reason: '未展开时只占一行，不铺开 100 条采样点');

    await tester.tap(find.text('上传进度'));
    await tester.pump();
    expect(find.textContaining('上传进度: 1/100'), findsOneWidget,
        reason: '展开后逐条可见');
  });

  testWidgets('不同前缀的进度不合并', (tester) async {
    final events = <AgentEvent>[
      AgentEvent.info('上传进度: 1/10 文件'),
      AgentEvent.info('上传进度: 2/10 文件'),
      AgentEvent.info('校验进度: 1/3 目录'),
      AgentEvent.info('校验进度: 3/3 目录'),
    ];
    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    expect(find.text('上传进度'), findsOneWidget);
    expect(find.text('校验进度'), findsOneWidget);
  });

  testWidgets('长思考默认收成一行，点开展开全文', (tester) async {
    final long = [
      '第一行推理',
      '第二行推理',
      '第三行推理',
      '第四行推理',
      '第五行推理',
      '第六行推理',
    ].join('\n');
    await tester.pumpWidget(_wrap(_content([AgentEvent.thought(long)])));
    await tester.pump();

    Text text() => tester.widget<Text>(find.textContaining('第六行推理'));
    expect(text().maxLines, 1, reason: '默认收成一行，思考不挤占步骤流');
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    await tester.tap(find.textContaining('第一行推理'));
    await tester.pump();
    expect(text().maxLines, isNull, reason: '点开后必须能看到完整思考');
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
  });

  testWidgets('跑完后步骤仍然全部保留', (tester) async {
    await tester.pumpWidget(_wrap(_content(_turn(steps: 12), isLoading: true)));
    await tester.pump();
    expect(find.text('local_file_read').evaluate().length, 12);

    await tester
        .pumpWidget(_wrap(_content(_turn(steps: 12), isLoading: false)));
    await tester.pump();
    expect(find.text('local_file_read').evaluate().length, 12,
        reason: '结果页也要能看到完整过程');
  });

  testWidgets('成功结果只预览前 12 行，其余进查看完整输出', (tester) async {
    final output = [for (var i = 1; i <= 30; i++) 'row-$i'].join('\n');
    final events = [
      AgentEvent.command('dir', id: 'c-long'),
      AgentEvent.result(
        commandId: 'c-long',
        success: true,
        output: output,
        toolName: 'exec_command',
      ),
    ];

    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();
    await tester.tap(find.text('终端命令'));
    await tester.pump();

    expect(find.textContaining('row-1'), findsWidgets);
    expect(find.textContaining('row-30'), findsNothing);
    expect(find.textContaining('还有 18 行'), findsOneWidget);
    expect(find.textContaining('查看完整输出'), findsOneWidget);
  });

  testWidgets('失败结果预览尾部 12 行，错误不被截在前面', (tester) async {
    final output = [for (var i = 1; i <= 30; i++) 'row-$i'].join('\n');
    final events = [
      AgentEvent.command('dir', id: 'c-bad'),
      AgentEvent.result(
        commandId: 'c-bad',
        success: false,
        output: output,
        toolName: 'exec_command',
      ),
    ];

    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    // 失败行现在默认收起，先点开再看输出预览
    await tester.tap(find.text('终端命令'));
    await tester.pump();

    expect(find.textContaining('row-30'), findsWidgets);
    expect(find.textContaining('还有 18 行'), findsOneWidget);
  });
}
