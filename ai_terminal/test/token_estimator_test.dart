import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/token_estimator.dart';
import 'package:ai_terminal/models/chat_session.dart';

void main() {
  group('TokenEstimator.estimateText', () {
    test('空字符串返回 0', () {
      expect(TokenEstimator.estimateText(''), 0);
    });

    test('纯 ASCII 估算 ≈ 字符数 / 4', () {
      // "hello world" = 11 chars → 11/4 = 2.75 → ceil to 3
      final result = TokenEstimator.estimateText('hello world');
      expect(result, 3);
    });

    test('纯中文按 1 字符 = 1 token 估算', () {
      // "你好世界" = 4 中文字符 → 4 tokens
      final result = TokenEstimator.estimateText('你好世界');
      expect(result, 4);
    });

    test('混合中英文按权重累计', () {
      // "你好 hello" = 2 中文 + 1 空格 + 5 ascii
      // cjk=2, ascii=6 (含空格), other=0
      // tokens = 2 + (6+3)~/4 + 0 = 2 + 2 = 4
      final result = TokenEstimator.estimateText('你好 hello');
      expect(result, 4);
    });

    test('包含代码块按字数估算', () {
      final code = '```bash\nls -la\n```';
      // 总共 18 ASCII chars → (18+3)~/4 = 5
      expect(TokenEstimator.estimateText(code), 5);
    });

    test('长文本估算合理增长', () {
      final short = TokenEstimator.estimateText('abc');
      const long = TokenEstimator.estimateText;
      final longResult = long('a' * 1000);
      expect(longResult, greaterThan(short));
      expect(longResult, lessThan(300)); // 1000 ascii ≈ 250 tokens
    });

    test('emoji 计入 other（1 字符 = 1 token）', () {
      final result = TokenEstimator.estimateText('🚀');
      // emoji runes 视为 1 个 other 字符 → 1 token
      expect(result, greaterThan(0));
    });
  });

  group('TokenEstimator.estimateHistory', () {
    test('空历史返回 0', () {
      expect(TokenEstimator.estimateHistory([]), 0);
    });

    test('每条消息额外计入 4 token role 开销', () {
      final history = [
        ChatMessage.create(role: 'user', content: 'hello'),     // 5 ascii → (5+3)~/4=2 + 4 = 6
        ChatMessage.create(role: 'assistant', content: 'hi'),    // 2 ascii → (2+3)~/4=1 + 4 = 5
      ];
      // total = 6 + 5 = 11
      expect(TokenEstimator.estimateHistory(history), 11);
    });

    test('多条中文消息估算合理', () {
      final history = [
        ChatMessage.create(role: 'user', content: '你好'),       // 2 + 4 = 6
        ChatMessage.create(role: 'assistant', content: '你好世界'), // 4 + 4 = 8
      ];
      expect(TokenEstimator.estimateHistory(history), 14);
    });
  });

  group('TokenEstimator.estimateMessage', () {
    test('单条消息估算与 estimateHistory 单元素一致', () {
      final msg = ChatMessage.create(role: 'user', content: 'hello');
      expect(TokenEstimator.estimateMessage(msg),
             TokenEstimator.estimateHistory([msg]));
    });
  });
}
