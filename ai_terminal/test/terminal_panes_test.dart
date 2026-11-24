import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/terminal_panes.dart';

/// 造一个已分屏的布局：首项永远是 tabId 本身。
PaneLayout split(String tabId, int extra,
    {SplitDirection direction = SplitDirection.vertical}) {
  var layout = PaneLayout.single(tabId);
  for (var i = 0; i < extra; i++) {
    layout = splitAfter(layout)!.layout;
  }
  return layout.copyWith(direction: direction);
}

void main() {
  group('首屏约定（AI 路由的地基）', () {
    test('第一个 pane 的 id 就是 tabId', () {
      final layout = split('tab1', 2);
      expect(layout.paneIds.first, 'tab1');
      expect(layout.primaryPaneId, 'tab1');
    });

    test('关掉首屏后首屏位置补上，仍指向某个真实 pane', () {
      final layout = closePane(split('tab1', 1), 'tab1');
      expect(layout.paneIds, isNotEmpty);
      expect(layout.paneIds.first, isNotEmpty);
      // 剩下的那个是额外 pane：tab 关掉时它也要一起被关
      expect(layout.paneIds.single, startsWith('tab1#p'));
    });

    test('额外 pane 的 id 带 tabId 前缀，不同标签不会撞车', () {
      final a = splitAfter(PaneLayout.single('tabA'))!;
      final b = splitAfter(PaneLayout.single('tabB'))!;
      expect(a.newPaneId, 'tabA#p1');
      expect(b.newPaneId, 'tabB#p1');
      expect(a.newPaneId, isNot(b.newPaneId));
    });
  });

  group('splitAfter', () {
    test('分屏后 pane 数 +1、比例均分且总和为 1', () {
      final r = splitAfter(PaneLayout.single('t'))!;
      expect(r.layout.count, 2);
      expect(r.layout.ratios.length, 2);
      expect(r.layout.ratios.reduce((a, b) => a + b), closeTo(1, 1e-9));
      expect(r.layout.isSplit, isTrue);
    });

    test('新 pane 成为活动 pane（用户注意力就在它上面）', () {
      final r = splitAfter(PaneLayout.single('t'))!;
      expect(r.layout.activeOrPrimary, r.newPaneId);
    });

    test('到上限就拒绝：返回 null，调用方据此禁用入口', () {
      var layout = PaneLayout.single('t');
      for (var i = 0; i < PaneLayout.maxPanes - 1; i++) {
        final r = splitAfter(layout);
        expect(r, isNotNull);
        layout = r!.layout;
      }
      expect(layout.count, PaneLayout.maxPanes);
      expect(layout.canSplit, isFalse);
      expect(splitAfter(layout), isNull);
    });

    test('在指定 pane 之后插入（不是永远追加到末尾）', () {
      final layout = split('t', 1);
      final extra = layout.paneIds[1];
      final r = splitAfter(layout, afterPaneId: extra)!;
      expect(r.layout.paneIds.indexOf(extra) + 1,
          r.layout.paneIds.indexOf(r.newPaneId));
    });

    test('指定不存在的 pane 时不崩，按活动 pane 处理', () {
      final layout = split('t', 1);
      final r = splitAfter(layout, afterPaneId: 'nope')!;
      expect(r.layout.count, 3);
    });

    test('序号不复用：关掉中间一个后，新 pane 不会拿到刚释放的 id', () {
      var layout = split('t', 2);
      final mid = layout.paneIds[1];
      layout = closePane(layout, mid);
      final r = splitAfter(layout)!;
      expect(r.newPaneId, isNot(mid));
      expect(layout.indexOf(r.newPaneId), -1);
    });
  });

  group('closePane', () {
    test('关到只剩一个即回到未分屏', () {
      var layout = split('t', 2);
      layout = closePane(layout, layout.paneIds[1]);
      layout = closePane(layout, layout.paneIds[1]);
      expect(layout.count, 1);
      expect(layout.isSplit, isFalse);
      expect(layout.ratios.single, 1);
    });

    test('焦点回退到相邻 pane，不悬空', () {
      final layout = split('t', 2);
      final closed = closePane(layout, layout.paneIds.last);
      expect(closed.paneIds.contains(closed.activeOrPrimary), isTrue);
      // 关的是最后一个 → 焦点落在新的最后一个
      expect(closed.activeOrPrimary, layout.paneIds[layout.paneIds.length - 2]);
    });

    test('关掉最后一个之外的 pane，焦点落在左边邻居', () {
      final layout = split('t', 2);
      final mid = layout.paneIds[1];
      final closed = closePane(layout, mid);
      expect(closed.activeOrPrimary, layout.paneIds[0]);
    });

    test('关掉唯一 pane 不把自己关掉', () {
      final single = PaneLayout.single('t');
      expect(closePane(single, 't').count, 1);
    });

    test('关不存在的 pane 原样返回', () {
      final layout = split('t', 1);
      expect(closePane(layout, 'ghost').count, layout.count);
    });

    test('关闭后比例重新归一为 1', () {
      final layout = split('t', 2);
      final closed = closePane(layout, layout.paneIds[1]);
      expect(closed.ratios.reduce((a, b) => a + b), closeTo(1, 1e-9));
    });
  });

  group('拖动分隔条', () {
    test('一侧变大另一侧等量变小，总和不变', () {
      final layout = split('t', 1);
      final dragged = dragDivider(layout, 0, 0.1);
      expect(dragged.ratios[0], greaterThan(layout.ratios[0]));
      expect(dragged.ratios[1], lessThan(layout.ratios[1]));
      expect(dragged.ratios.reduce((a, b) => a + b), closeTo(1, 1e-9));
    });

    test('拖到底也不会把 pane 拖成 0 宽（有最小占比）', () {
      final layout = split('t', 1);
      final dragged = dragDivider(layout, 0, 9);
      expect(dragged.ratios[0], lessThan(1));
      expect(dragged.ratios[1], greaterThanOrEqualTo(minPaneRatio / 2));
      // 用户还看得见、点得回来 = 不能是 0
      expect(dragged.ratios.every((r) => r > 0), isTrue);
    });

    test('分隔条索引越界不动布局', () {
      final layout = split('t', 1);
      expect(dragDivider(layout, 5, 0.2).ratios, layout.ratios);
      expect(dragDivider(layout, -1, 0.2).ratios, layout.ratios);
    });

    test('多次连拖不会累积误差让总宽变胖', () {
      var layout = split('t', 2);
      for (var i = 0; i < 200; i++) {
        layout = dragDivider(layout, i % 2, i.isEven ? 0.02 : -0.02);
      }
      expect(layout.ratios.reduce((a, b) => a + b), closeTo(1, 1e-6));
      expect(layout.ratios.every((r) => r > 0), isTrue);
    });
  });

  group('方向与焦点', () {
    test('换方向不改 pane 顺序', () {
      final layout = split('t', 2);
      final flipped = setDirection(layout, SplitDirection.horizontal);
      expect(flipped.paneIds, layout.paneIds);
      expect(flipped.direction, SplitDirection.horizontal);
      expect(flipped.ratios, layout.ratios);
    });

    test('焦点移动不绕圈', () {
      final layout = split('t', 2);
      expect(neighborPane(layout, layout.paneIds[0], forward: true),
          layout.paneIds[1]);
      expect(neighborPane(layout, layout.paneIds.last, forward: true), isNull);
      expect(neighborPane(layout, layout.paneIds[0], forward: false), isNull);
    });

    test('没分屏时焦点不移动', () {
      final single = PaneLayout.single('t');
      expect(neighborPane(single, 't', forward: true), isNull);
      expect(neighborPane(single, 't', forward: false), isNull);
    });

    test('setActive 拒绝不存在的 pane', () {
      final layout = split('t', 1);
      expect(
          setActive(layout, 'ghost').activeOrPrimary, layout.activeOrPrimary);
    });

    test('方向 id 往返一致，未知值回落左右并排', () {
      for (final d in SplitDirection.values) {
        expect(SplitDirection.byId(d.id), d);
      }
      expect(SplitDirection.byId('diagonal'), SplitDirection.vertical);
      expect(SplitDirection.byId(null), SplitDirection.vertical);
    });
  });

  group('flex 换算', () {
    test('全是正整数（Expanded 不接受 0 或负数）', () {
      final flex = ratiosToFlex([0.5, 0.5]);
      expect(flex, everyElement(greaterThan(0)));
    });

    test('极端比例也至少给 1 格（不能把 pane 压没）', () {
      final flex = ratiosToFlex([0.999, 0.001]);
      expect(flex.every((f) => f >= 1), isTrue);
      expect(flex.length, 2);
    });

    test('比例之和被 clamp 打乱后仍归一到同一基数', () {
      final flex = ratiosToFlex([0.9, 0.9]);
      expect(flex.reduce((a, b) => a + b), 1000);
    });

    test('空列表返回空', () {
      expect(ratiosToFlex(const []), isEmpty);
    });
  });
}
