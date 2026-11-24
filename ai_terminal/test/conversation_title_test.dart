import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/conversation.dart';
import 'package:ai_terminal/services/conversation_title_service.dart';

Conversation _conv({
  String title = '会话 11/4 02:34',
  String titleSource = Conversation.titleSourceAuto,
}) =>
    Conversation.create(
      id: 'conv-1',
      hostId: 'web-01',
      title: title,
      titleSource: titleSource,
    );

void main() {
  group('占位标题推导（首条用户消息截断，上限 50 字）', () {
    test('日期默认标题回退到首条用户消息片段（50 字内不截断）', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(
            role: 'user',
            content: '请检查本机 gdm 和 systemd-logind 两个服务是否正在运行，然后总结'))
        ..addMessage(ConvMessage.create(role: 'assistant', content: '...'));

      // 42 个 rune，未超 50，完整保留
      expect(conv.displayTitle, '请检查本机 gdm 和 systemd-logind 两个服务是否正在运行，然后总结');
    });

    test('超过 50 字按 rune 截断并加省略号', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(role: 'user', content: 'A' * 80));

      final title = conv.displayTitle;
      expect(title.runes.length, 51); // 50 个 A + 省略号
      expect(title.endsWith('…'), isTrue);
    });

    test('只取首行，并把连续空白折叠成一个空格', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(
          role: 'user',
          content: '  第一行   有空格\n第二行不应该出现  ',
        ));

      expect(conv.displayTitle, '第一行 有空格');
    });

    test('按 rune 截断，不劈开 emoji', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(
          role: 'user',
          content: '😀' * 80,
        ));

      final title = conv.displayTitle;
      expect(title.runes.length, 51); // 50 个 emoji + 省略号
      expect(title.endsWith('…'), isTrue);
    });

    test('没有用户消息时保留日期标题', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(role: 'assistant', content: '占位'));

      expect(conv.displayTitle, '会话 11/4 02:34');
    });

    test('首条用户消息到达时替换占位标题（仍是 auto，可被 AI 继续改写）', () {
      final conv = _conv();
      conv.adoptTitleFromFirstMessage('排查服务器自动关机的原因');
      expect(conv.title, '排查服务器自动关机的原因');
      expect(conv.hasAutoTitle, isFalse); // 不再匹配日期正则
      expect(conv.titleSource, Conversation.titleSourceAuto);
      expect(conv.canAdoptAiTitle, isTrue);
    });
  });

  group('标题来源门控（AI/用户命名后不被自动覆盖）', () {
    test('用户手动命名后，占位逻辑不再改写', () {
      final conv =
          _conv(title: '生产环境巡检', titleSource: Conversation.titleSourceUser);
      conv.adoptTitleFromFirstMessage('另一个任务');
      expect(conv.title, '生产环境巡检');
      expect(conv.canAdoptAiTitle, isFalse);
    });

    test('AI 命名后不可再被自动覆盖', () {
      final conv =
          _conv(title: 'AI 起的名字', titleSource: Conversation.titleSourceAi);
      expect(conv.canAdoptAiTitle, isFalse);
      conv.adoptTitleFromFirstMessage('另一个任务');
      expect(conv.title, 'AI 起的名字');
    });

    test('列表展示标题按 60 字截断', () {
      final conv =
          _conv(title: 'A' * 80, titleSource: Conversation.titleSourceUser);
      final list = conv.listDisplayTitle;
      expect(list.runes.length, 61); // 60 + 省略号
      expect(list.endsWith('…'), isTrue);
    });

    test('60 字内的用户标题完整展示', () {
      final conv = _conv(
          title: 'Metersphere 部署与磁盘排查',
          titleSource: Conversation.titleSourceUser);
      expect(conv.listDisplayTitle, 'Metersphere 部署与磁盘排查');
    });
  });

  group('命名取材（selectFirstRoundTexts）', () {
    test('首轮报错、次轮完成时跳过 ⚠️ 占位，用真正完成的结论', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(role: 'user', content: '排查服务器自动关机原因'))
        ..addMessage(
            ConvMessage.create(role: 'assistant', content: '⚠️ 连接超时，请检查网络'))
        ..addMessage(ConvMessage.create(role: 'user', content: '重试'))
        ..addMessage(ConvMessage.create(
            role: 'assistant', content: '由定时任务 poweroff 触发，已禁用该任务'));

      final texts = ConversationTitleService.selectFirstRoundTexts(conv);
      // 用户诉求仍是第一条（原始目标），不因重试而变成「重试」
      expect(texts.userText, '排查服务器自动关机原因');
      expect(texts.assistantText, '由定时任务 poweroff 触发，已禁用该任务');
    });

    test('所有 assistant 都是错误/空占位时不带结论（仅按诉求命名）', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(role: 'user', content: '看下 nginx 日志'))
        ..addMessage(
            ConvMessage.create(role: 'assistant', content: '⚠️ API Key 无效或已过期'))
        ..addMessage(ConvMessage.create(role: 'assistant', content: '   '));

      final texts = ConversationTitleService.selectFirstRoundTexts(conv);
      expect(texts.userText, '看下 nginx 日志');
      expect(texts.assistantText, isEmpty);
    });

    test('system 消息不参与取材', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(role: 'system', content: '你是运维助手'))
        ..addMessage(ConvMessage.create(role: 'user', content: '重启 docker'))
        ..addMessage(
            ConvMessage.create(role: 'assistant', content: '已重启并确认自启'));

      final texts = ConversationTitleService.selectFirstRoundTexts(conv);
      expect(texts.userText, '重启 docker');
      expect(texts.assistantText, '已重启并确认自启');
    });

    test('已压缩的消息按 summary 取材（effectiveContent 口径）', () {
      final conv = _conv()
        ..addMessage(ConvMessage.create(
            role: 'user', content: '一大段原始诉求' * 50, summary: '在 web-01 扩容磁盘'))
        ..addMessage(ConvMessage.create(role: 'assistant', content: '扩容完成'));

      final texts = ConversationTitleService.selectFirstRoundTexts(conv);
      expect(texts.userText, '在 web-01 扩容磁盘');
    });
  });

  group('sanitizeTitle（清洗模型输出的纯函数）', () {
    test('去掉 markdown 代码块、首尾引号与结尾标点', () {
      expect(
          ConversationTitleService.sanitizeTitle('```\n排查 Nginx 502 错误\n```'),
          '排查 Nginx 502 错误');
      expect(ConversationTitleService.sanitizeTitle('“定位 /var/log 磁盘占用”'),
          '定位 /var/log 磁盘占用');
      expect(ConversationTitleService.sanitizeTitle('分析磁盘占用情况。'), '分析磁盘占用情况');
    });

    test('多行输出只取首行并折叠空白', () {
      expect(
          ConversationTitleService.sanitizeTitle('检查服务状态\n第二行不该出现'), '检查服务状态');
      expect(ConversationTitleService.sanitizeTitle('  排查   nginx 重启  原因 '),
          '排查 nginx 重启 原因');
    });

    test('去掉「标题：」类前缀', () {
      expect(ConversationTitleService.sanitizeTitle('标题：排查服务器自动关机原因'),
          '排查服务器自动关机原因');
    });

    test('超过 60 字按 rune 截断加省略号', () {
      final out = ConversationTitleService.sanitizeTitle('B' * 80);
      expect(out.runes.length, 61);
      expect(out.endsWith('…'), isTrue);
    });

    test('空/纯标点输出返回空串', () {
      expect(ConversationTitleService.sanitizeTitle(''), isEmpty);
      expect(ConversationTitleService.sanitizeTitle('。。。'), isEmpty);
      expect(ConversationTitleService.sanitizeTitle('   '), isEmpty);
    });
  });
}
