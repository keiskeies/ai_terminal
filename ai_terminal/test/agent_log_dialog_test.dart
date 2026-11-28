// Agent 日志查看器在手机上的两个缺陷回归测试。
//
// 1) 表头读数停在满仓那一刻：刷新只用「条数变了没」判定，而日志是 1000 条的
//    环形缓冲，满了之后长度恒定 —— 于是一屏旧内容配一个不再动的读数。
// 2) 表头在窄屏溢出：对话框宽度按屏宽 0.78 折算，手机上只有约 300 逻辑像素，
//    标题与条数两个 Text 没有约束就会报 RenderFlex overflow。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/services/agent_logger.dart';
import 'package:ai_terminal/widgets/agent_log_dialog.dart';

const _ringCapacity = 1000;

Widget wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      home: Scaffold(body: child),
    );

/// 填满环形缓冲：条数从此不再变化，正好造出「看不出有新日志」的条件
void fillRingBuffer() {
  for (var i = 0; i < _ringCapacity + 5; i++) {
    agentLogger.info('Winsize', 'fill-$i');
  }
  expect(agentLogger.getLogs().length, _ringCapacity);
}

/// 卸载对话框（取消它的周期定时器）并放掉 logger 的落盘定时器，
/// 否则 fake async 会因 pending timer 判定失败
Future<void> settleAndUnmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 600));
}

/// 日志行是 `Text.rich`，`find.textContaining` 只看 `Text` 因而永远匹配不到，
/// 这里直接比对 RichText 拼出来的纯文本
Finder findsRichTextContaining(String needle) => find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText().contains(needle));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  testWidgets('缓冲满仓后仍然跟着新日志刷新', (tester) async {
    fillRingBuffer();

    await tester.pumpWidget(wrap(const AgentLogDialog()));
    await tester.pump(const Duration(milliseconds: 100));

    // 缓冲里全是 INFO，先按 WARN 过滤 → 当前一条都没有。新日志进来后只有
    // 真正触发刷新，这一行才会出现在列表里（1000 行的列表是懒构建的，
    // 不隔离级别就没法断言末行到底建出来没有）。
    await tester.tap(find.text('WARN'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(findsRichTextContaining('tail-marker-after-full'), findsNothing);

    // 长度不变、只有内容变新：只看条数的判定会当成「没有新日志」
    agentLogger.warn('Winsize', 'tail-marker-after-full');
    expect(agentLogger.getLogs().length, _ringCapacity);

    // 周期定时器 5s 触发一次刷新，再加自动滚动动画的时间
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 500));

    expect(findsRichTextContaining('tail-marker-after-full'), findsOneWidget,
        reason: '末行必须被拉进来，不能停在满仓那一刻');

    await settleAndUnmount(tester);
  });

  testWidgets('窄屏打开日志不溢出', (tester) async {
    fillRingBuffer();
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(const AgentLogDialog()));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull, reason: '表头不得 RenderFlex overflow');
    expect(find.text('Agent 日志'), findsOneWidget);

    await settleAndUnmount(tester);
  });
}
