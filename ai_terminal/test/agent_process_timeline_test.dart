import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/models/agent_event.dart';
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
    String? pendingConfirmCommand,
    bool isWaitingChoice = false,
    List<String> pendingOptions = const [],
    void Function(String)? onSelectChoice}) => Builder(
      builder: (context) => AgentEventContent(
        events: events,
        tc: ThemeColors.of(context),
        isLoading: isLoading,
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

  testWidgets('失败的结果默认展开，不藏进一次点击里', (tester) async {
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

    expect(find.textContaining('Job for nginx.service failed'), findsWidgets,
        reason: '失败必须一眼可见，否则用户以为任务顺利');
  });

  testWidgets('超过窗口的成功步骤被折叠，点头部展开', (tester) async {
    await tester.pumpWidget(_wrap(_content(_turn(steps: 12), isLoading: true)));
    await tester.pump();

    expect(find.text('local_file_read').evaluate().length, lessThanOrEqualTo(6));
    expect(find.textContaining('更早'), findsOneWidget);

    await tester.tap(find.textContaining('更早'));
    await tester.pump();
    expect(find.text('local_file_read').evaluate().length, greaterThanOrEqualTo(7));
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

  testWidgets('没有藏任何行时不出"更早 0 步"头部', (tester) async {
    await tester.pumpWidget(_wrap(_content(_turn(steps: 2))));
    await tester.pump();

    expect(find.textContaining('更早'), findsNothing);
    expect(find.textContaining('已调用工具'), findsNothing);
  });

  testWidgets('询问之后的过程事件必须渲染在询问下方（按原始顺序交错）',
      (tester) async {
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
    expect(askY, lessThan(laterCommandY),
        reason: '询问卡片不能永远沉在消息底部，后续过程事件应在它下面');
  });

  testWidgets('正文之后的过程事件渲染在正文下方（不把正文统一挪到最后）',
      (tester) async {
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

    await tester.tap(find.text('旧选项'));
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

    expect(find.text('确认执行'), findsOneWidget,
        reason: '没有批准入口的确认门等于把任务挂死');
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('确认执行'));
    expect(confirmed, display);
  });

  testWidgets('工具调用在没有等待确认时不显示批准按钮', (tester) async {
    final events = [
      AgentEvent.command('local_file_read\n  path: /a', id: 'r-1', toolName: 'local_file_read'),
    ];
    await tester.pumpWidget(_wrap(_content(events, isLoading: true)));
    await tester.pump();

    expect(find.text('确认执行'), findsNothing,
        reason: '只读工具不该被标成待确认');
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
    }) =>
        Builder(
          builder: (context) => AgentEventContent(
            events: [ask],
            tc: ThemeColors.of(context),
            isWaitingChoice: isWaitingChoice,
            pendingOptions: isWaitingChoice ? (ask.options ?? const []) : const [],
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
          events: [AgentEvent.ask(question, ['继续'])],
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

    testWidgets('任务已推进/历史回看时选项仍然可见（此前只剩一张空卡片）',
        (tester) async {
      await tester.pumpWidget(_wrap(askContent(
        ask: AgentEvent.ask('选哪个？', ['Java 8', 'Java 17']),
        isWaitingChoice: false,
      )));
      await tester.pump();

      expect(find.text('Java 8'), findsOneWidget);
      expect(find.text('Java 17'), findsOneWidget);
    });

    testWidgets('非等待态点选项不会回调', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(_wrap(askContent(
        ask: AgentEvent.ask('选哪个？', ['Java 8']),
        isWaitingChoice: false,
        onSelectChoice: picked.add,
      )));
      await tester.pump();

      await tester.tap(find.text('Java 8'));
      await tester.pump();
      expect(picked, isEmpty);
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
      await tester.enterText(
          find.byType(TextField), '  用官方脚本安装，但不加组  ');
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

  testWidgets('折叠头带上失败数：故障不能藏在"更早 N 步"里', (tester) async {
    final events = <AgentEvent>[
      ..._turn(steps: 6),
      AgentEvent.command('pm2 restart api', id: 'bad'),
      AgentEvent.result(
        commandId: 'bad',
        success: false,
        error: 'boom',
        toolName: 'exec_command',
      ),
    ];

    await tester.pumpWidget(_wrap(_content(events)));
    await tester.pump();

    expect(find.textContaining('更早'), findsOneWidget);
    expect(find.textContaining('1 失败'), findsOneWidget,
        reason: '收起后的那一行必须带失败数');
  });

  testWidgets('跑完后自动收回最近 5 步', (tester) async {
    await tester.pumpWidget(_wrap(_content(_turn(steps: 12), isLoading: true)));
    await tester.pump();

    await tester.tap(find.textContaining('更早'));
    await tester.pump();
    expect(find.text('local_file_read').evaluate().length, 12);

    // 任务结束：运行中展开的旧步骤自动收回
    await tester.pumpWidget(_wrap(_content(_turn(steps: 12), isLoading: false)));
    await tester.pump();
    expect(find.text('local_file_read').evaluate().length,
        lessThanOrEqualTo(5));
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

    expect(find.textContaining('row-30'), findsWidgets);
    expect(find.textContaining('还有 18 行'), findsOneWidget);
  });
}
