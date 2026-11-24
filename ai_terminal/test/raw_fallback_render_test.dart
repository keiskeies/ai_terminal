import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/utils/conversation_export.dart';
import 'package:ai_terminal/widgets/agent_event_cards.dart';

/// D1 raw fallback 结构化渲染：老会话的持久化正文是原始 ReAct 协议文本
/// （思考:/动作:/命令: 行），展示层与导出必须先解析成事件再渲染/导出，
/// 协议行不再当正文显示。
///
/// 说明：terminal_page 的 _buildAIContent 是页面私有方法，整页渲染需要完整
/// app 状态（数据库/终端会话），widget 级不可行；但复用路径是
/// parse → 同一 buildEventContent（AgentEventContent），所以 widget 断言在
/// AgentEventContent 层做：喂给它 raw fallback 解析出的事件，等价于页面渲染
/// 出来的结果——find 不到「动作:」协议行。
void main() {
  group('parseRawReactFallbackEvents（raw fallback 解析前置纯函数）', () {
    test('协议文本解析为事件序列，动作行不产出可见内容', () {
      const raw = '思考: 先看磁盘占用\n'
          '动作: execute\n'
          '命令: df -h\n'
          '说明: 检查各分区剩余空间';
      final events = parseRawReactFallbackEvents(raw);

      expect(events.any((e) => e.isThought), isTrue);
      expect(events.any((e) => e.isCommand && e.command == 'df -h'), isTrue,
          reason: '命令必须解析为命令事件，交给命令卡渲染');
      expect(hasVisibleReactEvents(events), isTrue);
      // 没有任何事件把「动作:」协议行当正文携带
      for (final e in events) {
        expect(e.text ?? '', isNot(contains('动作:')));
      }
    });

    test('非协议纯文本不解析（返回空 → 调用方原样渲染）', () {
      const plain = '这是一段没有任何协议词的回答。\n第二行也保持原样。';
      expect(parseRawReactFallbackEvents(plain), isEmpty,
          reason: '无协议行的正文绝不进解析器，渲染路径保持原文');
    });

    test('普通 Markdown 回答的围栏不得变成可执行命令事件', () {
      // 解析器把任意 ``` 围栏产出为 command 事件——若对普通回答动刀，
      // 代码示例会挂上执行按钮、引用行会被重排（D1 过度解析回归）。
      const markdown = '可以这样重启服务：\n'
          '```\nsystemctl restart nginx\n```\n'
          '> 注意：配置改完必须 reload。\n'
          '详细说明见文档。';
      expect(parseRawReactFallbackEvents(markdown), isEmpty,
          reason: '围栏与引用块保持原样渲染，不生成命令卡');
    });

    test('空白内容解析为空', () {
      expect(parseRawReactFallbackEvents(''), isEmpty);
      expect(parseRawReactFallbackEvents('   \n  \n'), isEmpty);
    });

    test('纯动作协议行解析后无可见事件（调用方保留原文兜底）', () {
      final events = parseRawReactFallbackEvents('动作: finish');
      expect(hasVisibleReactEvents(events), isFalse,
          reason: '无正文事件的协议内容不得渲染成空白，调用方须回落原文');
    });
  });

  group('formatAnswerForCopy raw fallback（导出侧）', () {
    test('协议文本导出为分节可读文本，不含协议行', () {
      const raw = '思考: 先看磁盘占用\n'
          '动作: execute\n'
          '命令: df -h\n'
          '这是一段总结正文。';
      final text = formatAnswerForCopy(events: const [], content: raw);

      expect(text, contains('先看磁盘占用'));
      expect(text, contains(r'$ df -h'), reason: '命令导出为 \$ 命令 形态');
      expect(text, contains('这是一段总结正文。'));
      expect(text, isNot(contains('动作:')), reason: '协议行不再原样导出');
    });

    test('纯文本导出与原文一致', () {
      const plain = '磁盘剩余 40G，没有异常。';
      expect(
        formatAnswerForCopy(events: const [], content: plain),
        plain,
      );
    });

    test('解析不出可见事件时保留原文', () {
      const protocolOnly = '动作: finish';
      final text = formatAnswerForCopy(events: const [], content: protocolOnly);
      expect(text, protocolOnly, reason: '空事件兜底不得吞掉内容');
    });

    test('有事件路径的导出格式不变', () {
      final text = formatAnswerForCopy(events: [
        AgentEvent.thought('检查服务状态'),
        AgentEvent.command('systemctl status nginx', id: 'c1'),
      ]);
      expect(text, contains('检查服务状态'));
      expect(text, contains(r'$ systemctl status nginx'));
    });
  });

  group('widget：raw fallback 事件经既有事件渲染路径不再露出协议行', () {
    Widget wrap(Widget child) => MaterialApp(
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

    Widget content(List<AgentEvent> events) => Builder(
          builder: (context) => AgentEventContent(
            events: events,
            tc: ThemeColors.of(context),
            isLoading: false,
            markdownBuilder: (text, tc) => Text(text),
          ),
        );

    testWidgets('无事件老会话：协议正文渲染后 find 不到「动作:」协议行', (tester) async {
      const raw = '思考: 先看磁盘占用\n'
          '动作: execute\n'
          '命令: df -h\n'
          '这是最终回答正文。';
      final events = parseRawReactFallbackEvents(raw);
      await tester.pumpWidget(wrap(content(events)));
      await tester.pump();

      expect(find.textContaining('动作:'), findsNothing, reason: 'D1：协议行不得当正文渲染');
      expect(find.textContaining('先看磁盘占用'), findsWidgets);
      expect(find.textContaining('df -h'), findsWidgets);
      expect(find.textContaining('这是最终回答正文。'), findsWidgets);
    });
  });
}
