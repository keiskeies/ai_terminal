import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 布局回归：AI 面板头部（terminal_page.dart `_buildAiPanelHead`）既不
/// RenderFlex overflow，又保持「左侧内容靠左、操作按钮靠右」的写法。
///
/// 头部原本用 `Spacer()` 把「切换方位 / 收起」推到右边缘。面板拖窄时，标题 +
/// 模型胶囊的自然宽度已经超过可用空间，Spacer 与按钮一起被挤出可视区：整行
/// RenderFlex overflow，收起按钮点不到。
void main() {
  const name = 'qwen3.8-flash-next-gyrx-thinking-high-extended-model-name';

  /// - 'spacer'：原写法（标题/胶囊不可收缩 + Spacer）。
  /// - 'spaceBetween'：左侧整组包 Flexible，行用 spaceBetween 顶开按钮。
  Future<double?> probe(
      WidgetTester tester, String mode, double width) async {
    const title =
        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis);
    const capsule =
        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis);
    const controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(key: Key('c1'), width: 24, height: 24),
        SizedBox(key: Key('c2'), width: 24, height: 24),
      ],
    );
    Widget head() {
      if (mode == 'spacer') {
        return Row(
          children: [
            const SizedBox(width: 16, height: 16),
            title,
            const SizedBox(width: 8),
            capsule,
            const Spacer(),
            controls,
          ],
        );
      }
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 16, height: 16),
                Flexible(child: title),
                const SizedBox(width: 8),
                Flexible(child: capsule),
              ],
            ),
          ),
          controls,
        ],
      );
    }

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: head()),
      ),
    ));
    if (tester.takeException() != null) return null;
    return tester.getRect(find.byKey(const Key('c2'))).right;
  }

  testWidgets('spacer：窄宽度必然溢出（复现原缺陷）', (tester) async {
    expect(await probe(tester, 'spacer', 260), isNull);
  });

  testWidgets('spaceBetween：窄宽度不溢出，按钮留在可视区', (tester) async {
    final right = await probe(tester, 'spaceBetween', 260);
    expect(right, isNotNull);
    expect(right, lessThanOrEqualTo(260));
  });

  testWidgets('spaceBetween：宽宽度按钮仍贴右边缘', (tester) async {
    final right = await probe(tester, 'spaceBetween', 600);
    expect(right, isNotNull);
    expect(right, closeTo(600, 0.5));
  });

  testWidgets('spaceBetween：极窄（120）也不溢出', (tester) async {
    final right = await probe(tester, 'spaceBetween', 120);
    expect(right, isNotNull);
    expect(right, lessThanOrEqualTo(120));
  });

  // ==== AI 面板工具栏行（terminal_page.dart「工具栏」Row）====
  //
  // 左侧是固定宽度的胶囊 + 图标按钮排（合计超过窄面板宽度），右侧是运行状态。
  // 原写法用 Spacer 顶开两侧，左侧又不许收缩 → 窄面板必然溢出。
  // 新写法：左侧 Flexible(SingleChildScrollView)，固定内容滚得出来，行不再炸。
  Future<double?> probeToolbar(WidgetTester tester, String mode, double width) async {
    const left = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(key: Key('b1'), width: 30, height: 30),
        SizedBox(width: 6),
        SizedBox(key: Key('b2'), width: 30, height: 30),
        SizedBox(width: 4),
        SizedBox(key: Key('b3'), width: 30, height: 30),
        SizedBox(width: 4),
        SizedBox(key: Key('b4'), width: 30, height: 30),
        SizedBox(width: 4),
        SizedBox(key: Key('b5'), width: 30, height: 30),
        SizedBox(width: 4),
        SizedBox(key: Key('b6'), width: 30, height: 30),
        SizedBox(width: 4),
        SizedBox(key: Key('b7'), width: 30, height: 30),
      ],
    );
    const status = SizedBox(key: Key('status'), width: 70, height: 22);
    Widget row() {
      if (mode == 'spacer') {
        return Row(children: [left, const Spacer(), status]);
      }
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: left,
            ),
          ),
          status,
        ],
      );
    }

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: row()),
      ),
    ));
    if (tester.takeException() != null) return null;
    return tester.getRect(find.byKey(const Key('status'))).right;
  }

  testWidgets('工具栏 spacer：窄宽度必然溢出（复现原缺陷）', (tester) async {
    expect(await probeToolbar(tester, 'spacer', 240), isNull);
  });

  testWidgets('工具栏 scroll：窄宽度不溢出且状态指示可见', (tester) async {
    final right = await probeToolbar(tester, 'scroll', 240);
    expect(right, isNotNull);
    expect(right, lessThanOrEqualTo(240));
  });

  testWidgets('工具栏 scroll：宽宽度不改变原布局（首按钮贴左、状态贴右）',
      (tester) async {
    final right = await probeToolbar(tester, 'scroll', 600);
    expect(right, isNotNull);
    expect(right, closeTo(600, 0.5));
  });
}
