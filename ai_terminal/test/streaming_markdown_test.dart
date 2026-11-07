import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/streaming_markdown.dart';

void main() {
  group('stableParagraphCut', () {
    test('没有空行时返回 -1', () {
      expect(stableParagraphCut('第一段正在增长'), -1);
      expect(stableParagraphCut('行一\n行二'), -1);
    });

    test('取最后一个代码块外空行之后的位置', () {
      const text = '段落一\n\n段落二\n\n正在增长的尾部';
      final cut = stableParagraphCut(text);
      expect(cut, '段落一\n\n段落二\n\n'.length);
      expect(text.substring(0, cut), '段落一\n\n段落二\n\n');
      expect(text.substring(cut), '正在增长的尾部');
    });

    test('代码块内的空行不是段落边界', () {
      const text = '```\n代码\n\n还在代码里\n```';
      // 唯一空行在围栏内；没有可用边界
      expect(stableParagraphCut(text), -1);
    });

    test('代码块前后的空行可作为边界', () {
      const text = '前文\n\n```dart\ncode\n```\n\n尾部';
      final cut = stableParagraphCut(text);
      expect(text.substring(cut), '尾部');
    });

    test('边界恰在文末（尾部为空）时返回 -1', () {
      expect(stableParagraphCut('段落一\n\n'), -1);
    });

    test('连续空行取最后一个', () {
      const text = '段落\n\n\n尾部';
      final cut = stableParagraphCut(text);
      expect(text.substring(cut), '尾部');
    });
  });

  group('unclosedFenceSplit', () {
    test('没有围栏时返回 null', () {
      expect(unclosedFenceSplit('普通文本\n第二行'), isNull);
    });

    test('已闭合的围栏返回 null', () {
      expect(unclosedFenceSplit('```dart\ncode\n```'), isNull);
      expect(unclosedFenceSplit('前文\n```\ncode\n```\n后文'), isNull);
    });

    test('未闭合围栏：拆出围栏前文本与代码内容', () {
      final result = unclosedFenceSplit('说明文字\n```bash\nls -la\npwd');
      expect(result, isNotNull);
      expect(result!.$1, '说明文字\n');
      expect(result.$2, 'ls -la\npwd');
    });

    test('刚开出围栏还没有换行：代码为空串', () {
      final result = unclosedFenceSplit('```bash');
      expect(result, isNotNull);
      expect(result!.$1, '');
      expect(result.$2, '');
    });

    test('多个围栏只有最后一个未闭合时才拆分', () {
      final result = unclosedFenceSplit('```\n闭合块\n```\n文本\n```sh\n未完');
      expect(result, isNotNull);
      expect(result!.$1, '```\n闭合块\n```\n文本\n');
      expect(result.$2, '未完');
    });
  });

  group('增量切分一致性（模拟流式增长）', () {
    test('前缀只增不改：每次切分后旧前缀是新前缀的起点', () {
      const full = '思考第一段\n\n中间段\n\n```dart\nvar a = 1;\n```\n\n最后一段还在增长';
      var prevHead = '';
      // 模拟逐字符增长，凡是能切出前缀的时刻都必须满足前缀单调增长
      for (var len = 1; len <= full.length; len++) {
        final text = full.substring(0, len);
        final cut = stableParagraphCut(text);
        if (cut <= 0) continue;
        final head = text.substring(0, cut);
        expect(head.startsWith(prevHead), isTrue,
            reason: '前缀必须单调增长: len=$len');
        // 前缀终点必须在代码块外：前缀内围栏成对闭合
        final fences = RegExp(r'^\s*```', multiLine: true).allMatches(head).length;
        expect(fences.isEven, isTrue, reason: '前缀不能切在代码块内: len=$len');
        prevHead = head;
      }
      expect(prevHead, isNotEmpty);
    });
  });
}