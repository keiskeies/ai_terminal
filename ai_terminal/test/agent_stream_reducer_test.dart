import 'package:ai_terminal/services/agent_stream_reducer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('流式正文截断不会留下孤立代理项', () {
    final reducer = AgentStreamReducer();
    addTearDown(reducer.dispose);

    reducer.append('host', 'xx😀${'a' * 199999}');
    final content = reducer.getContent('host')!;

    expect(content.length, 199999);
    expect(RegExp(r'^a+$').hasMatch(content), isTrue);
    expect(
        content.codeUnits.any((unit) =>
            (unit >= 0xD800 && unit <= 0xDBFF) ||
            (unit >= 0xDC00 && unit <= 0xDFFF)),
        isFalse);
  });

  test('普通超限正文仍保留规定长度的尾部', () {
    final reducer = AgentStreamReducer();
    addTearDown(reducer.dispose);

    reducer.append('host', '${'x' * 1000}${'a' * 200000}');

    expect(reducer.getContent('host'), 'a' * 200000);
  });
}
