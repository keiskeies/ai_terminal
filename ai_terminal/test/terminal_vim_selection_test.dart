// 全屏程序（vi/vim/less/htop 等）里的鼠标选区与复制。
//
// 根因：xterm 的选区是挂在 BufferLine 上的锚点。全屏程序滚动窗口会发
// DL(ESC[M)、IL(ESC[L) 以及边缘自动滚屏，Buffer 平移行用的是
// lines[i] = lines[i + n]；而 IndexAwareCircularBuffer._adoptChild 会先
// _detach() 掉目标槽里原有的行——那一行恰恰是上一轮刚挂到新槽的同一个
// 对象。于是整段被平移的行仍留在 buffer 里、内容也对，却丢了宿主引用，
// 挂在其上的锚点 attached 变成 false，controller.selection 变 null，
// 右键菜单就没有「复制」项，Ctrl+Insert 也只弹「没有选中的内容」。
// 修复：终端视图在每次输出后把这些「在位但失联」的行原地重新挂载
// （见 widgets/terminal_view.dart 的「全屏程序选区保活」）。
//
// 判据用右键菜单里有没有「复制」项 + 剪贴板实际写入内容，端到端覆盖
// 「拖选 - 程序刷新 - 右键复制」，而不是只测 controller 内部状态。
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/widgets/terminal_view.dart';

/// 拖选的起止像素：800x600 视口里第 3 到 9 行左右
const dragFrom = Offset(100, 110);
const dragTo = Offset(150, 300);

/// 右键菜单落点
const menuAt = Offset(300, 300);

/// 往副屏画 20 行可辨识文本（vim 打开文件后的样子）
void paintScreen(xterm.Terminal term) {
  final screen = StringBuffer();
  for (var i = 1; i <= 20; i++) {
    screen.write('\x1b[$i;1Hvim line $i ---- hello world ----\x1b[K\r\n');
  }
  term.write(screen.toString());
}

/// 进入副屏并打开鼠标上报（vim 的 set mouse=a 会发这几个模式）
void enterAltScreen(xterm.Terminal term) {
  term.write('\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h');
}

Future<xterm.Terminal> pumpAltTerminal(WidgetTester tester) async {
  final term = xterm.Terminal();
  term.onOutput = (_) {};
  enterAltScreen(term);
  paintScreen(term);
  await pumpTerminalWidget(tester, term);
  return term;
}

Future<void> pumpTerminalWidget(WidgetTester tester, xterm.Terminal term) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.darkTheme,
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: TerminalView(terminal: term),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 捕获写入系统剪贴板的文本
List<String> captureClipboard(WidgetTester tester) {
  final writes = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        writes.add(((call.arguments as Map)['text'] ?? '') as String);
      }
      return null;
    },
  );
  return writes;
}

/// 拖选一段文本。手势用完必须 removePointer，否则下一次 addPointer 会触发
/// MouseTracker 的一致性断言。
Future<void> dragSelect(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: dragFrom);
  await gesture.down(dragFrom);
  await tester.pump();
  for (var y = dragFrom.dy + 10; y <= dragTo.dy; y += 10) {
    await gesture.moveTo(Offset(dragTo.dx, y));
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
  await gesture.removePointer();
  // xterm 双击判定用的 kDoubleTapTimeout，等过它避免后续点击被当成双击
  await tester.pump(const Duration(seconds: 1));
}

/// 右键并点「复制」；返回菜单里是否有「复制」项
Future<bool> copyViaContextMenu(WidgetTester tester) async {
  final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
  await gesture.addPointer(location: menuAt);
  await gesture.down(menuAt);
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pump();
  await gesture.removePointer();
  final hasCopy = find.text('复制').evaluate().isNotEmpty;
  if (hasCopy) {
    await tester.tap(find.text('复制'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
  return hasCopy;
}

/// 灌入字节后让渲染跑一帧。副屏是无限滚动视图，pumpAndSettle 永不 settle，
/// 只能定长 pump。
Future<void> settleWrite(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('vim 拖选后立刻右键可以复制', (tester) async {
    await pumpAltTerminal(tester);
    final clip = captureClipboard(tester);

    await dragSelect(tester);
    expect(await copyViaContextMenu(tester), isTrue);

    expect(clip, hasLength(1));
    expect(clip.single, contains('hello world'));
  });

  // 核心回归：DL(ESC[M) 把整段行往上平移，选区锚点会丢掉宿主引用而失效。
  // 这是 vim 向下滚动一格的序列。
  testWidgets('vim 滚动一格（DL）后仍能复制', (tester) async {
    final term = await pumpAltTerminal(tester);
    final clip = captureClipboard(tester);

    await dragSelect(tester);
    term.write('\x1b[1;1H\x1b[1M');
    await settleWrite(tester);

    expect(await copyViaContextMenu(tester), isTrue,
        reason: 'DL 平移后选区锚点应随重新挂载的行一起复活');
    expect(clip, hasLength(1));
    expect(clip.single.trim(), isNotEmpty);
  });

  // IL(ESC[L) 同样平移行对象（vim 向上滚动一格）
  testWidgets('vim 反向滚动一格（IL）后仍能复制', (tester) async {
    final term = await pumpAltTerminal(tester);
    final clip = captureClipboard(tester);

    await dragSelect(tester);
    term.write('\x1b[1;1H\x1b[1L');
    await settleWrite(tester);

    expect(await copyViaContextMenu(tester), isTrue);
    expect(clip, hasLength(1));
    expect(clip.single.trim(), isNotEmpty);
  });

  // 光标到底行再换行会触发 Buffer.scrollUp，走的也是同一套平移
  testWidgets('vim 触底自动滚屏后仍能复制', (tester) async {
    final term = await pumpAltTerminal(tester);
    final clip = captureClipboard(tester);

    await dragSelect(tester);
    term.write('\x1b[${term.viewHeight};1HX\r\n');
    await settleWrite(tester);

    expect(await copyViaContextMenu(tester), isTrue);
    expect(clip, hasLength(1));
    expect(clip.single.trim(), isNotEmpty);
  });

  // vim 连续滚动多格：多次 DL 后依然可复制，且复制到的仍是选区所在内容
  testWidgets('vim 连续滚动多格后仍能复制', (tester) async {
    final term = await pumpAltTerminal(tester);
    final clip = captureClipboard(tester);

    await dragSelect(tester);
    for (var i = 0; i < 5; i++) {
      term.write('\x1b[1;1H\x1b[1M');
      await settleWrite(tester);
    }

    expect(await copyViaContextMenu(tester), isTrue);
    expect(clip, hasLength(1));
    expect(clip.single, contains('hello world'));
  });

  /// 反向断言：真正被删掉的行不能凭空造出选区。DL 20 行把选区所在行换成
  /// 新的空行，原行对象已不在 lines 里，锚点按 xterm 语义正常失效。
  testWidgets('选区所在行被真正删除时不伪造选区', (tester) async {
    final term = await pumpAltTerminal(tester);

    await dragSelect(tester);
    term.write('\x1b[4;1H\x1b[20M');
    await settleWrite(tester);

    final text = term.buffer.getText(xterm.BufferRangeLine(
      const xterm.CellOffset(0, 3),
      const xterm.CellOffset(40, 8),
    ));
    expect(text.trim(), isEmpty, reason: '前置条件：选区内的行已被清空');
    expect(await copyViaContextMenu(tester), isFalse,
        reason: '内容真的没了，菜单应退回「全选」而不是给出空选区');
  });

  /// 主屏（普通 shell）：追加输出不替换行对象，选区必须跟着锚点走，
  /// 滚出屏幕后复制到的仍是当初选中的那几行。
  testWidgets('主屏输出滚动后复制的是锚定内容', (tester) async {
    final term = xterm.Terminal();
    term.onOutput = (_) {};
    term.write(List.generate(20, (i) => 'shell line ${i + 1} ---- mark${i + 1} ----\r\n')
        .join());
    await pumpTerminalWidget(tester, term);
    final clip = captureClipboard(tester);

    await dragSelect(tester);
    // 再灌 30 行，把选中的行推回滚动区
    term.write(List.generate(30, (i) => 'more $i\r\n').join());
    await settleWrite(tester);

    expect(await copyViaContextMenu(tester), isTrue);
    expect(clip, hasLength(1));
    expect(clip.single, contains('mark'));
    expect(clip.single, isNot(contains('more')),
        reason: '选区应按锚点跟随，不能按屏幕坐标重算');
  });

  /// 复制一次就结束：选区清空后不该被后续输出「救」回来
  testWidgets('复制后新输出不会复活选区', (tester) async {
    final term = await pumpAltTerminal(tester);
    final clip = captureClipboard(tester);

    await dragSelect(tester);
    expect(await copyViaContextMenu(tester), isTrue);
    expect(clip, hasLength(1));

    term.write('\x1b[1;1H\x1b[1M');
    await settleWrite(tester);

    expect(await copyViaContextMenu(tester), isFalse,
        reason: '复制完成即结束，菜单应退回「全选」');
    expect(clip, hasLength(1), reason: '不应发生第二次剪贴板写入');
  });

  /// 退出全屏（ESC[?1049l）：副屏内容整体作废，旧选区不能残留
  testWidgets('退出全屏后不保留旧选区', (tester) async {
    final term = await pumpAltTerminal(tester);
    final clip = captureClipboard(tester);

    await dragSelect(tester);
    term.write('\x1b[?1049l');
    await settleWrite(tester);

    expect(term.isUsingAltBuffer, isFalse);
    expect(await copyViaContextMenu(tester), isFalse);
    expect(clip, isEmpty);
  });
}
