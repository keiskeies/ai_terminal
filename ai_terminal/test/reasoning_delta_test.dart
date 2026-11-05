import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/services/ai_service.dart';

void main() {
  group('reasoningDeltaOf', () {
    test('识别 reasoning_content（DeepSeek 系）', () {
      expect(
        reasoningDeltaOf({'reasoning_content': '先确认磁盘大小'}),
        '先确认磁盘大小',
      );
    });

    test('识别 reasoning 字段（少数网关）', () {
      expect(reasoningDeltaOf({'reasoning': '正在推演'}), '正在推演');
    });

    test('两个字段同时存在时优先 reasoning_content', () {
      expect(
        reasoningDeltaOf({'reasoning_content': 'A', 'reasoning': 'B'}),
        'A',
      );
    });

    test('没有推理字段 / 空串 / 非字符串都不算推理', () {
      expect(reasoningDeltaOf({'content': '正文'}), isNull);
      expect(reasoningDeltaOf({'reasoning_content': ''}), isNull);
      expect(reasoningDeltaOf({'reasoning_content': 42}), isNull);
      expect(reasoningDeltaOf({'reasoning': <String>[]}), isNull);
      expect(reasoningDeltaOf(null), isNull);
      expect(reasoningDeltaOf('not-a-map'), isNull);
    });
  });
}
