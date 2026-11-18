import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' as xterm;
// RenderTerminal.getCellOffset 是唯一能把"屏幕坐标"换算成"含滚动偏移的行号"的入口；
// 自己按字号估算行高会差 1~2 行，右键就会读到相邻行。仅此一处用内部实现。
// ignore: implementation_imports
import 'package:xterm/src/ui/render.dart' show RenderTerminal;
import '../core/app_toast.dart';
import '../core/constants.dart';
import '../core/terminal_keybindings.dart';
import '../core/terminal_themes.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../utils/terminal_blocks.dart';import '../utils/terminal_panes.dart';
import '../utils/terminal_search.dart';
import '../utils/terminal_text_actions.dart';
import 'terminal_context_menu.dart';
import '../core/l10n_holder.dart';

class TerminalView extends StatefulWidget {
  final xterm.Terminal? terminal;
  final ValueChanged<String>? onSend;
  final double fontSize;

  /// 本机会话不提供 SFTP / 审计等远程能力
  final bool isLocal;

  /// 右键菜单里的字号调整；为空时隐藏相关项
  final ValueChanged<double>? onFontSizeChanged;

  /// 需要页面能力的菜单动作（Agent / 片段 / SFTP / 审计）
  final Future<void> Function(TerminalMenuIntent intent, String text)? onMenuIntent;

  /// 是否为当前可见 tab。多个 tab 的 TerminalView 会同时挂在树上，
  /// 只有 active 的可以抢焦点/自动聚焦，否则后台 tab 会把键盘焦点抢走。
  final bool active;

  /// 终端配色预设 id（见 core/terminal_themes.dart）；null 或未识别 → 内置配色
  final String? paletteId;

  /// 快捷键映射（见 core/terminal_keybindings.dart）；null → 默认表
  final TerminalKeymap? keymap;

  /// OSC 133 命令块（见 utils/terminal_blocks.dart）；null 或无块 → 不出块菜单
  final TerminalBlockTracker? blockTracker;

  /// 分屏动作（布局与会话都归页面持有）。null = 这个终端不参与分屏。
  final TerminalPaneActions? panes;

  /// Ctrl+K / ⌘K 命令面板。焦点在终端里时 xterm 会先吃掉按键，
  /// 必须在终端按键处理里抢在 keymap/keyInput 之前拦下，页面级
  /// CallbackShortcuts 只能覆盖焦点在终端之外的场景。
  final VoidCallback? onCommandPalette;

  const TerminalView({
    super.key,
    this.terminal,
    this.onSend,
    this.fontSize = 13,
    this.isLocal = true,
    this.onFontSizeChanged,
    this.onMenuIntent,
    this.active = true,
    this.paletteId,
    this.keymap,
    this.blockTracker,
    this.panes,
    this.onCommandPalette,
  });

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> with TextInputClient {
  final FocusNode _focusNode = FocusNode();

  // 桌面 IME 自建 TextInput 连接（macOS/Linux）：xterm 的 CustomTextEdit 路径
  // 在 Windows 上收不到 IME 组字（真机实测）。Windows 不 attach（引擎会吞
  // Ctrl+C/V 且 IME 模型损坏），组字/注入/候选窗全走 runner 原生通道。
  TextInputConnection? _imeConnection;
  TextEditingValue _imeState = const TextEditingValue();

  // Windows runner 拦截 WM_IME_* 后把上屏串发到这个 channel（引擎 IME 模型缺陷的绕路）
  static const MethodChannel _nativeImeChannel =
      MethodChannel('com.keiskei.aiterminal/ime');
  static _TerminalViewState? _nativeImeTarget;
  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  // TerminalController 用于管理终端选区，右键复制时读取选中文本
  final xterm.TerminalController _controller = xterm.TerminalController();
  final GlobalKey _terminalContainerKey = GlobalKey();

  // ---- 终端搜索（默认可见 Ctrl+Shift+F / mac ⌘F，可在外观设置里改）----
  // 高亮走 xterm 内置 controller.highlight()（渲染器原生绘制，锚点随 buffer
  // 变动自动跟随），匹配计算遍历 buffer 文本，见 utils/terminal_search.dart。
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchQueryController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  bool _searchOpen = false;
  bool _searchCaseSensitive = false;
  List<TerminalSearchMatch> _searchMatches = [];
  int _searchCurrent = -1;
  final List<xterm.TerminalHighlight> _searchHighlights = [];
  final List<xterm.CellAnchor> _searchAnchors = [];
  // 搜索期间跳转过视图：关闭时回到底部，恢复输出跟随
  bool _searchScrolled = false;
  Timer? _searchDebounce;
  static const int _searchMaxMatches = 5000;

  xterm.TerminalTheme get _theme => resolveTerminalTheme(
      paletteId: widget.paletteId,
      isLight: ThemeColors.of(context).isLight,
    );

  @override
  void initState() {
    super.initState();
    widget.terminal?.onBell = _onBell;
    _focusNode.addListener(_onFocusForIme);
    _nativeImeChannel.setMethodCallHandler(_handleNativeIme);
    if (widget.active) _nativeImeTarget = this;
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) {
      _nativeImeTarget = this;
    } else if (_nativeImeTarget == this) {
      _nativeImeTarget = null;
    }
    final terminalChanged =
        widget.terminal != null && widget.terminal != oldWidget.terminal;
    if (terminalChanged) {
      widget.terminal?.onBell = _onBell;
      if (_searchOpen) {
        oldWidget.terminal?.removeListener(_onTerminalChangedForSearch);
        widget.terminal?.addListener(_onTerminalChangedForSearch);
        _runSearch();
      }
    }
    final becameActive = widget.active && !oldWidget.active;
    if (terminalChanged || becameActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) {
          _focusNode.unfocus();
          _focusNode.requestFocus();
        }
      });
    } else if (!widget.active && oldWidget.active) {
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    if (_nativeImeTarget == this) _nativeImeTarget = null;
    _focusNode.removeListener(_onFocusForIme);
    _closeIme();
    _focusNode.dispose();
    widget.terminal?.removeListener(_onTerminalChangedForSearch);
    _searchDebounce?.cancel();
    _clearSearchHighlights();
    _searchQueryController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusForIme() {
    if (_focusNode.hasFocus && _isDesktop) {
      _openIme();
    } else {
      _closeIme();
    }
    if (Platform.isWindows) {
      _sendNative('focus', _focusNode.hasFocus);
    }
    // 分屏：键盘落到哪一屏，页面就把「活动 pane」记成这一屏（新 pane 插在哪、
    // 焦点往哪移都以它为准）。页面在 pane 未变时不会重建，不会形成回环。
    if (_focusNode.hasFocus) widget.panes?.onFocus();
  }

  void _openIme() {
    if (Platform.isWindows) {
      _updateImeCaret();
      return;
    }
    if (_imeConnection != null && _imeConnection!.attached) {
      _imeConnection!.show();
    } else {
      _imeConnection = TextInput.attach(
        this,
        TextInputConfiguration(
          // Windows 引擎要求 setClient 携带 viewId，否则拒绝建立连接
          viewId: View.of(context).viewId,
          inputType: TextInputType.text,
          inputAction: TextInputAction.newline,
          autocorrect: false,
          enableSuggestions: false,
        ),
      );
      _imeConnection!.show();
      _imeConnection!.setEditingState(const TextEditingValue());
    }
    _updateImeCaret();
  }

  void _closeIme() {
    if (_imeConnection != null && _imeConnection!.attached) {
      _imeConnection!.close();
    }
    _imeConnection = null;
    _imeState = const TextEditingValue();
  }

  void _sendNative(String method, [Object? arguments]) {
    _nativeImeChannel
        .invokeMethod<dynamic>(method, arguments)
        .catchError((Object _) {});
  }

  // 让 IME 候选窗跟着终端光标走，而不是落在窗口左上角
  void _updateImeCaret() {
    final box = _terminalContainerKey.currentContext?.findRenderObject();
    final render = box == null ? null : _findRenderTerminal(box);
    if (render == null || !render.attached) return;
    final rect = render.localToGlobal(render.cursorOffset) & render.cellSize;
    if (Platform.isWindows) {
      _sendNative('setCaretRect', {'x': rect.left, 'y': rect.top});
      return;
    }
    final conn = _imeConnection;
    if (conn == null || !conn.attached) return;
    final origin = render.localToGlobal(Offset.zero);
    conn.setEditableSizeAndTransform(
      render.size,
      Matrix4.translationValues(origin.dx, origin.dy, 0),
    );
    conn.setCaretRect(rect);
  }

  void _scheduleCaretUpdate() {
    if (!Platform.isWindows) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateImeCaret();
    });
  }

  @override
  TextEditingValue? get currentTextEditingValue => _imeState;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _handleImeValue(value);
  }

  void _handleImeValue(TextEditingValue value) {
    _imeState = value;
    // 组字中：不上屏
    if (!value.composing.isCollapsed) {
      return;
    }
    if (value.text.isNotEmpty) {
      widget.terminal?.textInput(value.text);
    }
    _imeState = const TextEditingValue();
    _imeConnection?.setEditingState(_imeState);
  }

  Future<dynamic> _handleNativeIme(MethodCall call) async {
    if (call.method == 'commit' || call.method == 'text') {
      final text = call.arguments as String?;
      if (text != null && text.isNotEmpty) {
        final target = _nativeImeTarget ?? this;
        target.widget.terminal?.textInput(text);
        target._scheduleCaretUpdate();
      }
    }
    return null;
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.done || action == TextInputAction.newline) {
      widget.terminal?.keyInput(xterm.TerminalKey.enter);
    }
  }

  @override
  void connectionClosed() {
    _imeConnection = null;
    _imeState = const TextEditingValue();
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  DateTime? _lastBellAt;

  /// BEL 响应：系统提示音。Tab 补全等场景会连发 BEL，节流防轰炸。
  void _onBell() {
    final now = DateTime.now();
    final last = _lastBellAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastBellAt = now;
    SystemSound.play(SystemSoundType.alert);
  }

  /// 生效的快捷键映射：设置里改过的动作覆盖默认，其余走默认表
  TerminalKeymap get _keymap => widget.keymap ?? TerminalKeymap.defaults;

  /// 当前这条按键组合命中了哪个可重绑动作
  TerminalKeyAction? _matchKeyAction(int keyId) {
    final hw = HardwareKeyboard.instance;
    return _keymap.actionFor(
      keyId: keyId,
      ctrl: hw.isControlPressed,
      shift: hw.isShiftPressed,
      alt: hw.isAltPressed,
      meta: hw.isMetaPressed,
    );
  }

  /// 菜单里某个动作的快捷键文案（跟随用户的自定义，不写死）
  String _shortcutFor(TerminalKeyAction action) {
    final bindings = _keymap.bindingsFor(action);
    if (bindings.isEmpty) return '';
    final preferred = bindings.firstWhere(
      (b) => Platform.isMacOS ? b.meta : b.ctrl,
      orElse: () => bindings.first,
    );
    return preferred.label(isMac: Platform.isMacOS);
  }

  /// 执行一个可重绑的动作。返回是否消费了这个按键。
  bool _runKeyAction(TerminalKeyAction action) {
    switch (action) {
      case TerminalKeyAction.paste:
        _pasteFromClipboard();
        return true;
      case TerminalKeyAction.search:
        _openSearch();
        return true;
      case TerminalKeyAction.commandHistory:
        widget.onMenuIntent?.call(TerminalMenuIntent.showHistory, '');
        return true;
      case TerminalKeyAction.zoomIn:
      case TerminalKeyAction.zoomOut:
      case TerminalKeyAction.zoomReset:
        if (widget.onFontSizeChanged == null) return false;
        final target = action == TerminalKeyAction.zoomIn
            ? widget.fontSize + 1
            : action == TerminalKeyAction.zoomOut
                ? widget.fontSize - 1
                : 14.0;
        // 上下限由页面 clamp，这里照旧消费按键：到了边界再放行 '=' 进 shell
        // 会让用户以为快捷键时好时坏
        widget.onFontSizeChanged!(target);
        return true;
      case TerminalKeyAction.splitVertical:
        final panes = widget.panes;
        if (panes == null || !panes.canSplit) return false;
        panes.onSplit(SplitDirection.vertical);
        return true;
      case TerminalKeyAction.splitHorizontal:
        final panes = widget.panes;
        if (panes == null || !panes.canSplit) return false;
        panes.onSplit(SplitDirection.horizontal);
        return true;
      case TerminalKeyAction.closePane:
        final panes = widget.panes;
        // 没分屏时不吞键：关标签有自己的快捷键，不能让「在单屏里按 ⌘⇧W」
        // 变成一件悄悄发生的事
        if (panes == null || !panes.isSplit) return false;
        panes.onClose();
        return true;
      case TerminalKeyAction.focusNextPane:
      case TerminalKeyAction.focusPrevPane:
        final panes = widget.panes;
        if (panes == null || !panes.isSplit) return false;
        panes.onFocusNeighbor(action == TerminalKeyAction.focusNextPane);
        return true;
    }
  }

  /// Ctrl/Cmd+点击：打开光标处的 URL。cell 列号按宽字符折算成字符串下标。
  void _handleTapUp(TapUpDetails details, xterm.CellOffset cell) {
    final hw = HardwareKeyboard.instance;
    if (!hw.isControlPressed && !hw.isMetaPressed) return;
    final terminal = widget.terminal;
    if (terminal == null) return;
    final buffer = terminal.buffer;
    if (cell.y < 0 || cell.y >= buffer.height) return;
    final line = buffer.lines[cell.y];
    var col = 0;
    for (var i = 0; i < cell.x && i < line.length; i++) {
      if (line.getCodePoint(i) != 0) col++;
    }
    final url = urlAtColumn(line.getText(), col);
    if (url != null) _openUrl(url);
  }

  /// 键盘事件处理：拦截粘贴/缩放/Insert/Ctrl+A 等 app 级快捷键，
  /// 其余交给 xterm keyInput（特殊键）与 CustomKeyboardListener 的
  /// character 兜底（普通字符）；IME 组字/上屏走自建 TextInput 连接。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // KeyUpEvent 不参与任何插入/快捷键逻辑，直接吞掉，避免上层重复处理。
    if (event is KeyUpEvent) {
      return KeyEventResult.handled;
    }

    // 只处理 KeyDownEvent 和 KeyRepeatEvent
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _scheduleCaretUpdate();

    // 命令面板：在 keymap 之前拦。Ctrl+K 在 readline 里是杀行尾（K），
    // 但 app 级导航入口的优先级更高（与 paste=Ctrl+V 同一取舍）。
    if (widget.onCommandPalette != null &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyK &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      widget.onCommandPalette!();
      return KeyEventResult.handled;
    }

    // 可重绑的动作（粘贴/搜索/命令历史/字号缩放）统一走这张表：
    // 设置页改了立刻生效，且默认表与旧的硬编码逐键等价。
    //
    // 表里没有的键一律放行到下面：Ctrl+A 是 readline 行首、Ctrl+C 是中断、
    // Ctrl+H 是退格、Ctrl+D 是 EOF —— 那些是 shell 的键，不是我们的。
    //
    // 按住不放不重复触发（与旧实现一致）：连按 Ctrl+= 会一路放大，但粘贴、
    // 搜索、历史面板重复触发会一次弹一串，索性全部只认 KeyDown。
    if (event is KeyDownEvent) {
      final action = _matchKeyAction(event.logicalKey.keyId);
      if (action != null && _runKeyAction(action)) {
        return KeyEventResult.handled;
      }
    }

    if (_searchOpen && event.logicalKey == LogicalKeyboardKey.escape) {
      _closeSearch();
      return KeyEventResult.handled;
    }

    final hw = HardwareKeyboard.instance;
    // Windows 控制台惯例键位（Windows Terminal / cmd / PowerShell 都是这样）：
    //   Ctrl+Insert   = 复制选中
    //   Shift+Insert  = 粘贴（Shift 无修饰语义 → 不进多行确认；终端粘贴
    //                    惯例是一次全发，逐行执行靠 Ctrl+V 的确认路径）
    //   Ctrl+A        = 行首（readline/bash）
    // 必须拦截：默认走 xterm 的 shortcutManager 时 Ctrl+A 被绑成 SelectAll
    // （xterm shortcuts.dart），Linux 上 SSH 进 shell 就丢了这个键；Insert
    // 两个键任何一张快捷键表里都没有，character 为空，一路掉到 keyInput。
    if (event.logicalKey == LogicalKeyboardKey.insert) {
      final routing =
          resolveInsertRouting(ctrl: hw.isControlPressed, shift: hw.isShiftPressed);
      if (routing == InsertRouting.none) {
        // 裸 Insert：不吞键，交回 xterm（vi 插入模式等）
        return KeyEventResult.ignored;
      }
      final terminal = widget.terminal;
      if (terminal != null) {
        if (routing == InsertRouting.copySelection) {
          _copySelection(terminal);
        } else {
          _pasteFromClipboard(skipConfirm: true);
        }
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyA && hw.isControlPressed) {
      // Ctrl+A = readline 行首（bash/zsh）与 tmux 前缀，三平台都要留给 shell：
      // 非 mac 上 xterm 把它绑成了 SelectAll（_defaultShortcuts），必须抢回来；
      // mac 上苹果那张表只绑 ⌘A，Ctrl+A 本来就没人管，显式发 \x01 也和
      // 系统 Terminal.app 的行为一致（全选走 ⌘A，不受影响）。
      // 不用 keyInput(TerminalKey.keyA, ctrl: true)：xterm 的 keyInput
      // 是纯编码，不查 OSKeyState，Ctrl 修饰的字母查不到映射会丢按键；
      // 字节 \x01 与 keytab 里 C-a 完全等价（shell 的 readline 认的也是字节）。
      final byte = resolveCtrlAByte(ctrl: true);
      if (byte != null) {
        widget.terminal?.textInput(byte);
        return KeyEventResult.handled;
      }
    }

    // 其余交给 xterm：keyInput 处理特殊键（Enter/Tab/方向键/Ctrl+字母），
    // 普通字符由 CustomKeyboardListener 的 character 兜底插入；
    // IME 组字/上屏走本 State 自建的 TextInput 连接（见 _openIme）。
    return KeyEventResult.ignored;
  }

  // ---- 终端搜索 ----

  void _openSearch() {
    if (_searchOpen) {
      _searchFocusNode.requestFocus();
      return;
    }
    setState(() => _searchOpen = true);
    widget.terminal?.addListener(_onTerminalChangedForSearch);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
    if (_searchQueryController.text.isNotEmpty) _runSearch();
  }

  void _closeSearch() {
    if (!_searchOpen) return;
    widget.terminal?.removeListener(_onTerminalChangedForSearch);
    _searchDebounce?.cancel();
    _clearSearchHighlights();
    final restoreBottom = _searchScrolled;
    setState(() {
      _searchOpen = false;
      _searchMatches = [];
      _searchCurrent = -1;
      _searchScrolled = false;
    });
    if (restoreBottom) _scrollToBottom();
    _focusNode.requestFocus();
  }

  /// 输出持续到达时匹配会过期：防抖后重算。锚点本身随 buffer 变动跟随，
  /// 这里重算只是为了把新输出里的命中也纳入。
  void _onTerminalChangedForSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted && _searchOpen) _runSearch(keepCurrent: true);
    });
  }

  void _runSearch({bool keepCurrent = false}) {
    final terminal = widget.terminal;
    final query = _searchQueryController.text;
    if (terminal == null || query.isEmpty) {
      _clearSearchHighlights();
      setState(() {
        _searchMatches = [];
        _searchCurrent = -1;
      });
      return;
    }
    final matches = searchTerminalBuffer(
      terminal.buffer,
      query,
      caseSensitive: _searchCaseSensitive,
      maxMatches: _searchMaxMatches,
    );
    int current;
    if (matches.isEmpty) {
      current = -1;
    } else if (keepCurrent && _searchCurrent >= 0) {
      current = _searchCurrent.clamp(0, matches.length - 1);
    } else {
      current = 0;
    }
    setState(() {
      _searchMatches = matches;
      _searchCurrent = current;
    });
    _applyHighlights();
    if (!keepCurrent && current >= 0) _scrollToMatch(current);
  }

  void _clearSearchHighlights() {
    for (final h in _searchHighlights) {
      h.dispose();
    }
    _searchHighlights.clear();
    // highlight.dispose 不释放锚点，谁创建谁清理
    for (final a in _searchAnchors) {
      a.dispose();
    }
    _searchAnchors.clear();
  }

  void _applyHighlights() {
    _clearSearchHighlights();
    final terminal = widget.terminal;
    if (terminal == null) return;
    final light = ThemeColors.of(context).isLight;
    final hitColor =
        light ? const Color(0x59A66F00) : const Color(0x59F2C276);
    final currentColor =
        light ? const Color(0x80D14343) : const Color(0x99FF9AA2);
    for (var i = 0; i < _searchMatches.length; i++) {
      final m = _searchMatches[i];
      // 回滚区被裁剪后行号可能越界，锚点会脱离，跳过
      if (m.line >= terminal.buffer.height) continue;
      final line = terminal.buffer.lines[m.line];
      final p1 = line.createAnchor(m.start);
      final p2 = line.createAnchor(m.end);
      _searchAnchors.add(p1);
      _searchAnchors.add(p2);
      _searchHighlights.add(_controller.highlight(
        p1: p1,
        p2: p2,
        color: i == _searchCurrent ? currentColor : hitColor,
      ));
    }
  }

  void _nextMatch() => _stepMatch(1);

  void _prevMatch() => _stepMatch(-1);

  void _stepMatch(int delta) {
    if (_searchMatches.isEmpty) return;
    final count = _searchMatches.length;
    final base = _searchCurrent < 0 ? 0 : _searchCurrent;
    final next = (base + delta) % count;
    _setCurrentMatch(next < 0 ? next + count : next);
  }

  void _setCurrentMatch(int index) {
    if (index == _searchCurrent) {
      if (index >= 0) _scrollToMatch(index);
      return;
    }
    setState(() => _searchCurrent = index);
    _applyHighlights();
    if (index >= 0) _scrollToMatch(index);
  }

  RenderTerminal? _renderTerminal() {
    final box = _terminalContainerKey.currentContext?.findRenderObject();
    return box == null ? null : _findRenderTerminal(box);
  }

  /// 滚动到命中行（尽量居中）。xterm 的滚动模型：offset 像素 = 视口顶部
  /// 对应的 buffer 内容 y 坐标，行 i 画在 i*lineHeight - offset 处。
  void _scrollToMatch(int index) {
    if (_scrollToLine(_searchMatches[index].line)) _searchScrolled = true;
  }

  /// 滚动让 [line] 大致居中；渲染器还没就绪（未布局）时什么都不做。
  bool _scrollToLine(int? line) {
    if (line == null || line < 0) return false;
    final render = _renderTerminal();
    final terminal = widget.terminal;
    if (render == null || terminal == null || !_scrollController.hasClients) {
      return false;
    }
    final lineHeight = render.cellSize.height;
    final viewportHeight = render.size.height;
    final maxExtent =
        math.max(0.0, terminal.buffer.height * lineHeight - viewportHeight);
    final target =
        (line * lineHeight - (viewportHeight - lineHeight) / 2)
            .clamp(0.0, maxExtent);
    _scrollController.jumpTo(target);
    return true;
  }

  void _scrollToBottom() {
    final render = _renderTerminal();
    final terminal = widget.terminal;
    if (render == null || terminal == null || !_scrollController.hasClients) {
      return;
    }
    final lineHeight = render.cellSize.height;
    final maxExtent = math.max(
        0.0, terminal.buffer.height * lineHeight - render.size.height);
    _scrollController.jumpTo(maxExtent);
  }

  Widget _buildSearchBar() {
    final tc = ThemeColors.of(context);
    final query = _searchQueryController.text;
    final count = _searchMatches.length;
    final String label;
    if (query.isEmpty) {
      label = '';
    } else if (count == 0) {
      label = UiText.t('无结果', 'No results');
    } else {
      final capped = count >= _searchMaxMatches ? '+' : '';
      label = '${_searchCurrent + 1}/$count$capped';
    }
    final iconColor = tc.textSub;
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          _closeSearch();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter &&
            HardwareKeyboard.instance.isShiftPressed) {
          _prevMatch();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: tc.surface,
        elevation: 4,
        shadowColor: Colors.black54,
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tc.border)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _searchQueryController,
                  focusNode: _searchFocusNode,
                  style: TextStyle(fontSize: fSmall, color: tc.textMain),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    hintText: UiText.t('搜索终端输出', 'Search output'),
                    hintStyle: TextStyle(fontSize: fSmall, color: tc.textMuted),
                    filled: true,
                    fillColor: tc.bg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: tc.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: tc.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: tc.brand),
                    ),
                  ),
                  onChanged: (_) => _runSearch(),
                  onSubmitted: (_) => _nextMatch(),
                  // 默认 done 动作会 unfocus（EditableText._finalizeEditing），
                  // 搜索框按 Enter 跳下一个后必须保持焦点才能继续输入/导航。
                  onEditingComplete: () {},
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: Text(
                  label,
                  style: TextStyle(fontSize: fSmall, color: tc.textSub),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: UiText.t('区分大小写', 'Match case'),
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  setState(() => _searchCaseSensitive = !_searchCaseSensitive);
                  _runSearch();
                },
                icon: Text(
                  'Aa',
                  style: TextStyle(
                    fontSize: fSmall,
                    fontWeight: FontWeight.bold,
                    color: _searchCaseSensitive ? tc.brand : iconColor,
                  ),
                ),
              ),
              IconButton(
                tooltip: UiText.t('上一个 (Shift+Enter)', 'Previous (Shift+Enter)'),
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: _searchMatches.isEmpty ? null : _prevMatch,
                icon: Icon(Icons.keyboard_arrow_up, color: iconColor),
              ),
              IconButton(
                tooltip: UiText.t('下一个 (Enter)', 'Next (Enter)'),
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: _searchMatches.isEmpty ? null : _nextMatch,
                icon: Icon(Icons.keyboard_arrow_down, color: iconColor),
              ),
              IconButton(
                tooltip: UiText.t('关闭 (Esc)', 'Close (Esc)'),
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: _closeSearch,
                icon: Icon(Icons.close, color: iconColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 右键菜单：本地动作（复制/粘贴/清屏/字号/保存）就地完成，
  /// 需要页面能力的动作（Agent/SFTP/片段/审计）通过 [TerminalView.onMenuIntent] 上抛。
  void _showContextMenu(Offset globalPosition) {
    final terminal = widget.terminal;
    if (terminal == null) return;

    final tc = ThemeColors.of(context);
    final selection = _controller.selection;
    String? selectedText;
    if (selection != null) {
      final text = terminal.buffer.getText(selection);
      if (text.trim().isNotEmpty) selectedText = text;
    }
    final lineTexts = _lineTextsAt(globalPosition);
    final lineY = _bufferLineAt(globalPosition);

    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    var dismissed = false;
    void dismiss() {
      if (dismissed) return;
      dismissed = true;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (ctx) => TerminalContextMenu(
        position: globalPosition,
        items: _buildMenuItems(
          terminal: terminal,
          selectedText: selectedText,
          lineTexts: lineTexts,
          lineY: lineY,
        ),
        onDismiss: dismiss,
        tc: tc,
      ),
    );
    overlay.insert(entry);
  }

  /// 命中行 + 上下各一行：客户端坐标与截图坐标可能差半个行高，
  /// 取并集既不会漏识别，也不会把隔了几行的内容算进来。
  List<String> _lineTextsAt(Offset globalPosition) {
    final terminal = widget.terminal;
    final y = _bufferLineAt(globalPosition);
    if (terminal == null || y == null) return const [];
    final buffer = terminal.buffer;
    final texts = <String>[];
    for (final delta in const [0, -1, 1]) {
      final line = y + delta;
      if (line < 0 || line >= buffer.height) continue;
      final text = buffer.lines[line].getText();
      if (text.trim().isNotEmpty && !texts.contains(text)) texts.add(text);
    }
    return texts;
  }

  /// 右键位置对应的 buffer 行号（含回滚区）。拿不到渲染器时返回 null。
  int? _bufferLineAt(Offset globalPosition) {
    final box = _terminalContainerKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return null;
    final render = _findRenderTerminal(box);
    if (render == null) return null;
    final cell = render.getCellOffset(render.globalToLocal(globalPosition));
    return cell.y;
  }

  RenderTerminal? _findRenderTerminal(RenderObject node) {
    if (node is RenderTerminal) return node;
    RenderTerminal? found;
    node.visitChildren((child) {
      found ??= _findRenderTerminal(child);
    });
    return found;
  }

  List<TerminalMenuItem> _buildMenuItems({
    required xterm.Terminal terminal,
    required String? selectedText,
    required List<String> lineTexts,
    required int? lineY,
  }) {
    final items = <TerminalMenuItem>[];
    final onIntent = widget.onMenuIntent;
    final text = selectedText?.trimRight();
    // 右键位置的链接/路径/报错只用于"没选中内容"时的上下文菜单
    String? url;
    String? path;
    String? errorLine;
    if (text == null) {
      for (final line in lineTexts) {
        url ??= detectUrl(line);
        path ??= detectPath(line);
        if (errorLine == null && looksLikeError(line)) errorLine = line;
      }
    }

    // —— 编辑 ——
    // 快捷键文案按平台取：mac 上 xterm 绑的是 ⌘ 系列，写 Ctrl 等于骗用户
    final isMac = Platform.isMacOS;
    if (text != null && text.trim().isNotEmpty) {
      items.add(TerminalMenuItem(
        label: UiText.t('复制', 'Copy'),
        icon: Icons.copy_rounded,
        shortcut: terminalShortcutLabel(TerminalMenuAction.copy, isMac: isMac),
        onTap: () {
          // 走同一入口：右键菜单的 selectedText 与选区必然一致（菜单仅在有选区时显示此项）
          _copySelection(terminal);
        },
      ));
    } else {
      items.add(TerminalMenuItem(
        label: UiText.t('全选', 'Select all'),
        icon: Icons.select_all_rounded,
        shortcut:
            terminalShortcutLabel(TerminalMenuAction.selectAll, isMac: isMac),
        onTap: _selectAll,
      ));
    }
    items.add(TerminalMenuItem(
      label: UiText.t('粘贴', 'Paste'),
      icon: Icons.paste_rounded,
      shortcut: terminalShortcutLabel(TerminalMenuAction.paste, isMac: isMac),
      onTap: _pasteFromClipboard,
    ));

    // —— 视图与导出 ——
    items.add(TerminalMenuItem(
      label: UiText.t('清屏', 'Clear screen'),
      icon: Icons.cleaning_services_outlined,
      separatorBefore: true,
      onTap: terminal.buffer.clear,
    ));
    items.add(TerminalMenuItem(
      label: UiText.t('清空回滚缓冲', 'Clear scrollback'),
      icon: Icons.layers_clear_outlined,
      danger: true,
      onTap: terminal.buffer.clearScrollback,
    ));
    items.add(TerminalMenuItem(
      label: UiText.t('复制全部输出', 'Copy all output'),
      icon: Icons.copy_all_outlined,
      onTap: _copyAllOutput,
    ));
    items.add(TerminalMenuItem(
      label: UiText.t('保存输出到文件…', 'Save output to file…'),
      icon: Icons.save_alt_rounded,
      onTap: _saveOutputToFile,
    ));
    if (onIntent != null) {
      items.add(TerminalMenuItem(
        label: UiText.t('命令历史', 'Command history'),
        icon: Icons.history_rounded,
        shortcut: _shortcutFor(TerminalKeyAction.commandHistory),
        onTap: () => onIntent(TerminalMenuIntent.showHistory, ''),
      ));
    }
    if (widget.onFontSizeChanged != null) {
      items.add(TerminalMenuItem(
        label: UiText.t('放大字号', 'Increase font size'),
        icon: Icons.text_increase_rounded,
        separatorBefore: true,
        shortcut: _shortcutFor(TerminalKeyAction.zoomIn),
        enabled: widget.fontSize < 24,
        onTap: () => widget.onFontSizeChanged!(widget.fontSize + 1),
      ));
      items.add(TerminalMenuItem(
        label: UiText.t('缩小字号', 'Decrease font size'),
        icon: Icons.text_decrease_rounded,
        shortcut: _shortcutFor(TerminalKeyAction.zoomOut),
        enabled: widget.fontSize > 10,
        onTap: () => widget.onFontSizeChanged!(widget.fontSize - 1),
      ));
      items.add(TerminalMenuItem(
        label: UiText.t('重置字号', 'Reset font size'),
        icon: Icons.text_fields_rounded,
        shortcut: _shortcutFor(TerminalKeyAction.zoomReset),
        onTap: () => widget.onFontSizeChanged!(14),
      ));
    }

    // —— 选中内容（Agent / 片段 / 执行）——
    if (text != null && text.trim().isNotEmpty && onIntent != null) {
      items.add(TerminalMenuItem(
        label: UiText.t('发给 Agent 解释', 'Send to Agent for explanation'),
        icon: Icons.auto_awesome_outlined,
        separatorBefore: true,
        onTap: () => onIntent(TerminalMenuIntent.sendToAgent, text),
      ));
      items.add(TerminalMenuItem(
        label: UiText.t('存为命令片段', 'Save as snippet'),
        icon: Icons.bookmark_add_outlined,
        onTap: () => onIntent(
            TerminalMenuIntent.saveSnippet, stripPromptPrefix(text)),
      ));
      final command = stripPromptPrefix(text);
      if (looksLikeCommand(command)) {
        items.add(TerminalMenuItem(
          label: UiText.t('在终端执行这条命令', 'Run this command in the terminal'),
          icon: Icons.play_arrow_rounded,
          danger: true,
          onTap: () => _confirmRunCommand(command),
        ));
      }
    }

    // —— 分屏（首屏就是 AI 绑定的那一屏，额外屏是纯用户终端）——
    final paneActions = widget.panes;
    if (paneActions != null) {
      items.add(TerminalMenuItem(
        label: UiText.t('左右分屏', 'Split left/right'),
        icon: Icons.view_week_outlined,
        separatorBefore: true,
        shortcut: _shortcutFor(TerminalKeyAction.splitVertical),
        enabled: paneActions.canSplit,
        onTap: () => paneActions.onSplit(SplitDirection.vertical),
      ));
      items.add(TerminalMenuItem(
        label: UiText.t('上下分屏', 'Split top/bottom'),
        icon: Icons.view_agenda_outlined,
        shortcut: _shortcutFor(TerminalKeyAction.splitHorizontal),
        enabled: paneActions.canSplit,
        onTap: () => paneActions.onSplit(SplitDirection.horizontal),
      ));
      if (paneActions.isSplit) {
        items.add(TerminalMenuItem(
          label: paneActions.isPrimary
              ? UiText.t('关掉此分屏（AI 在这屏）',
                  'Close this pane (AI is bound here)')
              : UiText.t('关掉此分屏', 'Close this pane'),
          icon: Icons.close_fullscreen_outlined,
          shortcut: _shortcutFor(TerminalKeyAction.closePane),
          // 首屏关掉 = AI 正在用的会话没了，必须显式确认，不能一个右键误点就断任务
          danger: paneActions.isPrimary,
          onTap: paneActions.onClose,
        ));
      }
    }

    // —— 命令块（shell 打了 OSC 133 才出现）——
    final blockItems = _buildBlockItems(lineY: lineY, onIntent: onIntent);
    items.addAll(blockItems);

    // —— 远程会话能力 ——
    if (!widget.isLocal && onIntent != null) {
      items.add(TerminalMenuItem(
        label: path != null
            ? UiText.t('在 SFTP 中定位', 'Reveal in SFTP')
            : UiText.t('打开 SFTP 面板', 'Open SFTP panel'),
        icon: Icons.folder_open_outlined,
        separatorBefore: true,
        onTap: () => onIntent(
          TerminalMenuIntent.openSftp,
          path == null ? '' : directoryOfPath(path),
        ),
      ));
      items.add(TerminalMenuItem(
        label: UiText.t('查看审计记录', 'View audit log'),
        icon: Icons.receipt_long_outlined,
        onTap: () => onIntent(TerminalMenuIntent.openAudit, ''),
      ));
      items.add(TerminalMenuItem(
        label: UiText.t('查看变更记录', 'View change records'),
        icon: Icons.history_edu_outlined,
        onTap: () => onIntent(TerminalMenuIntent.viewChanges, ''),
      ));
    }

    // —— 右键位置的行内对象（链接 / 路径 / 报错）——
    if (text == null && lineTexts.isNotEmpty) {
      final isError = errorLine != null && onIntent != null;
      final link = url;
      if (link != null) {
        items.add(TerminalMenuItem(
          label: UiText.t('打开链接', 'Open link'),
          icon: Icons.open_in_new_rounded,
          separatorBefore: true,
          shortcut: link.length > 30 ? '${link.substring(0, 30)}…' : link,
          onTap: () => _openUrl(link),
        ));
        items.add(TerminalMenuItem(
          label: UiText.t('复制链接', 'Copy link'),
          icon: Icons.link_rounded,
          onTap: () => Clipboard.setData(ClipboardData(text: link)),
        ));
      }
      final pathValue = path;
      if (pathValue != null) {
        items.add(TerminalMenuItem(
          label: UiText.t('复制路径', 'Copy path'),
          icon: Icons.route_outlined,
          separatorBefore: link == null,
          shortcut: pathValue.length > 30
              ? '${pathValue.substring(0, 30)}…'
              : pathValue,
          onTap: () => Clipboard.setData(ClipboardData(text: pathValue)),
        ));
      }
      if (isError) {
        items.add(TerminalMenuItem(
          label: UiText.t('问 Agent 这个错误', 'Ask the Agent about this error'),
          icon: Icons.help_outline_rounded,
          onTap: () => onIntent(TerminalMenuIntent.askError, errorLine!),
        ));
      }
    }

    return items;
  }

  /// 命令块菜单项。shell 没装 OSC 133 集成时块列表恒为空 → 一项都不加，
  /// 用户看不到跟自己无关的东西。
  List<TerminalMenuItem> _buildBlockItems({
    required int? lineY,
    required Future<void> Function(TerminalMenuIntent, String)? onIntent,
  }) {
    final tracker = widget.blockTracker;
    final terminal = widget.terminal;
    if (tracker == null || terminal == null || onIntent == null) return const [];
    if (lineY == null || tracker.isEmpty) return const [];
    final height = terminal.buffer.height;
    final lineAt = blockLineReader(terminal);
    final index = blockIndexAtLine(tracker.blocks, lineY, height);
    final items = <TerminalMenuItem>[];
    if (index != null) {
      final blocks = tracker.blocks;
      final text = blockTextOf(blocks, index, height, lineAt);
      final exit = blocks[index].exitCode;
      if (text.trim().isNotEmpty) {
        items.add(TerminalMenuItem(
          label: UiText.t('让 Agent 解释这一整块', 'Ask Agent about this block'),
          icon: Icons.auto_awesome_outlined,
          shortcut: exit == null ? null : 'exit $exit',
          separatorBefore: true,
          onTap: () => onIntent(
            TerminalMenuIntent.askBlock,
            clipBlockForAgent(text),
          ),
        ));
        items.add(TerminalMenuItem(
          label: UiText.t('复制这一整块', 'Copy this block'),
          icon: Icons.copy_all_outlined,
          onTap: () => Clipboard.setData(ClipboardData(text: text)),
        ));
      }
    }
    final next = blockIndexNearLine(tracker.blocks, lineY,
        forward: true, bufferHeight: height);
    final prev = blockIndexNearLine(tracker.blocks, lineY,
        forward: false, bufferHeight: height);
    if (next != null || prev != null) {
      items.add(TerminalMenuItem(
        label: UiText.t('上一块命令', 'Previous command'),
        icon: Icons.arrow_upward_rounded,
        separatorBefore: items.isEmpty,
        enabled: prev != null,
        onTap: () {
          if (prev != null) _scrollToLine(blockStartLine(tracker.blocks, prev));
        },
      ));
      items.add(TerminalMenuItem(
        label: UiText.t('下一块命令', 'Next command'),
        icon: Icons.arrow_downward_rounded,
        enabled: next != null,
        onTap: () {
          if (next != null) _scrollToLine(blockStartLine(tracker.blocks, next));
        },
      ));
    }
    return items;
  }

  void _selectAll() {
    final terminal = widget.terminal;
    if (terminal == null) return;
    final buffer = terminal.buffer;
    if (buffer.height == 0) return;
    final first = buffer.lines[0];
    final last = buffer.lines[buffer.height - 1];
    _controller.setSelection(
      xterm.CellAnchor(0, owner: first),
      xterm.CellAnchor(last.length, owner: last),
      mode: xterm.SelectionMode.line,
    );
  }

  Future<void> _pasteFromClipboard({bool skipConfirm = false}) async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text ?? '';
    // Shift+Insert / 中键（skipConfirm）例外：终端粘贴惯例是一次全发，
    // 逐行执行的保护留给走多行确认的 Ctrl/Cmd+V 路径。
    var route = routePaste(text, skipConfirm: skipConfirm, confirmed: false);
    if (route.confirmNeeded) {
      route = routePaste(text,
          skipConfirm: skipConfirm,
          confirmed: await _confirmMultiLinePaste(text));
    }
    final pasted = route.pasted;
    if (pasted == null) return;
    if (!mounted) return;
    widget.terminal?.paste(pasted);
  }


  /// 复制选区到系统剪贴板，并弹「已复制」提示。
  /// 右键菜单的「复制」项走同一入口，避免两处各拼一遍。
  void _copySelection(xterm.Terminal terminal) {
    final sel = _controller.selection;
    if (sel == null) {
      _showToast(UiText.t('没有选中的内容', 'Nothing selected'));
      return;
    }
    final text = terminal.buffer.getText(sel);
    Clipboard.setData(ClipboardData(text: text));
    _controller.clearSelection();
    _showToast(L10n.str.ut_1dd514c792(text.length));
  }

  /// 轻提示：复用全局顶部 toast，不弹 AlertDialog、不遮挡终端
  void _showToast(String message) {
    showTopSnackBar(
      context,
      SnackBar(
        content: Text(message, style: TextStyle(fontSize: fSmall)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<bool> _confirmMultiLinePaste(String text) async {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final preview = lines.take(8).join('\n');
    final more = lines.length - 8;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final tc = ThemeColors.of(context);
        return AlertDialog(
          backgroundColor: tc.cardElevated,
          title: Text(L10n.str.ut_218046bbfd(lines.length),
              style: TextStyle(color: tc.textMain, fontSize: fBody)),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(UiText.t('多行内容会被依次执行，请确认没有误粘贴：', 'Multi-line content will run sequentially. Check that nothing was pasted by mistake:'),
                    style: TextStyle(color: tc.textSub, fontSize: fSmall)),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: tc.terminalBg,
                    borderRadius: BorderRadius.circular(rXSmall),
                    border: Border.all(color: tc.border),
                  ),
                  child: Text(
                    more > 0
                        ? L10n.str.ut_c40c983842(preview, more)
                        : preview,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontFamilyFallback: kMonoFontFallback,
                      fontSize: fMono,
                      color: tc.textBody,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(UiText.t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(UiText.t('粘贴', 'Paste')),
            ),
          ],
        );
      },
    );
    return ok ?? false;
  }

  Future<void> _confirmRunCommand(String command) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final tc = ThemeColors.of(context);
        return AlertDialog(
          backgroundColor: tc.cardElevated,
          title: Text(UiText.t('在终端执行这条命令？', 'Run this command in the terminal?'),
              style: TextStyle(color: tc.textMain, fontSize: fBody)),
          content: Container(
            width: 460,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: tc.terminalBg,
              borderRadius: BorderRadius.circular(rXSmall),
              border: Border.all(color: tc.border),
            ),
            child: Text(
              command,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontFamilyFallback: kMonoFontFallback,
                fontSize: fMono,
                color: tc.textMain,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(UiText.t('取消', 'Cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: tc.error),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(UiText.t('执行', 'Run')),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    widget.onSend?.call(command);
  }

  /// 用系统默认处理程序打开链接。argv 传参、不经 shell，避免 URL 里的字符被解释成命令
  Future<void> _openUrl(String url) async {
    if (!url.startsWith('http://') && !url.startsWith('https://')) return;
    try {
      if (Platform.isWindows) {
        await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      showTopSnackBar(context,
        SnackBar(
          content: Text(UiText.t('打开链接失败，已复制到剪贴板', 'Failed to open the link; copied to clipboard'),
              style: const TextStyle(fontSize: fSmall)),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }

  Future<void> _copyAllOutput() async {
    final text = widget.terminal?.buffer.getText() ?? '';
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showTopSnackBar(context,
      SnackBar(
        content: Text(L10n.str.ut_1dd514c792(text.length), style: const TextStyle(fontSize: fSmall)),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<void> _saveOutputToFile() async {
    final text = widget.terminal?.buffer.getText() ?? '';
    if (text.trim().isEmpty) return;
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final path = await FilePicker.platform.saveFile(
      dialogTitle: UiText.t('保存终端输出', 'Save terminal output'),
      fileName: 'terminal-$stamp.log',
      type: FileType.custom,
      allowedExtensions: const ['log', 'txt'],
    );
    if (path == null) return;
    await File(path).writeAsString(text);
    if (!mounted) return;
    showTopSnackBar(context,
      SnackBar(
        content: Text(L10n.str.ut_3482231651(path), style: const TextStyle(fontSize: fSmall)),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.terminal == null) {
      final tc = ThemeColors.of(context);
      return Container(
        // 用配色预设的背景，否则换了配色后「等待连接」这块和终端本体两个颜色
        color: _theme.background,
        child: Center(
          child: Text(UiText.t('等待连接...', 'Waiting for connection...'), style: TextStyle(color: tc.textSub)),
        ),
      );
    }

    // 全平台走 CustomTextEdit（TextInput）路径。桌面中文 IME 的组字/上屏经
    // updateEditingValue 送达：hardwareKeyboardOnly=true 不建 TextInput 连接，
    // IME 组字永远进不来，只能靠 keyLabel 兜底出英文字母（旧实现的硬伤）。
    // 普通字符同样经 TextInput → onInsert 插入，特殊键仍走 xterm keyInput。

    // 用 Listener 在外层直接监听原始指针事件，不依赖 xterm 内部的
    // 手势处理器。Listener 不参与手势竞技，不会干扰 xterm 的左键选区
    // 和键盘焦点，但能在手势竞技之前接收到所有指针事件。
    //
    // 事件分发顺序：Listener → xterm.TerminalView 内部手势 → xterm.TerminalView
    // 所以右侧也能收到。
    // xterm 的 RenderTerminal.paint 不做裁剪：滚动偏移不在行高整数倍时
    // （视口高度一般不是行高整数倍，底部对齐必然如此），顶部那一行会被
    // 画到视口上边界之外。终端上方紧挨着标签栏，多出来的行就会盖到 tab 上。
    final terminalArea = Listener(
      onPointerDown: (event) {
        // Alt+左键拖拽 = 块（矩形）选择，iTerm2 / Windows Terminal 惯例。
        // 拖拽结束后不能立刻恢复 line：selection getter 按读取时的模式重建
        // 范围，提前恢复会把块选区按行解释。下次普通左键按下才恢复。
        if (event.buttons == PointerButtons.primary) {
          if (HardwareKeyboard.instance.isAltPressed) {
            _controller.setSelectionMode(xterm.SelectionMode.block);
          } else if (_controller.selectionMode == xterm.SelectionMode.block) {
            _controller.setSelectionMode(xterm.SelectionMode.line);
          }
        }
        // onPointerDown 会收到所有鼠标按钮按下+触摸。
        // kSecondaryButton = 2，对应右键（Mac 双指点击 / Windows 右键）
        if (event.buttons == kSecondaryButton) {
          // event.position 是相对 Listener 的局部坐标，转换为全局坐标
          final renderBox =
              _terminalContainerKey.currentContext?.findRenderObject();
          if (renderBox is RenderBox) {
            _showContextMenu(renderBox.localToGlobal(event.position));
          }
        } else if (isMiddleClick(event.buttons) && !Platform.isMacOS) {
          // 中键粘贴（X11 惯例，Windows Terminal 也支持）。与 Shift+Insert
          // 同口径：单发全量、不做多行确认。
          // mac 上不启用：系统 Terminal.app / iTerm2 默认都不做中键粘贴，
          // 而它偏偏绕过确认弹窗——mac 用户用 ⌘V 走带确认的路径。
          _pasteFromClipboard(skipConfirm: true);
        }
      },
      child: ClipRect(
        child: Container(
          key: _terminalContainerKey,
          child: xterm.TerminalView(
            widget.terminal!,
            controller: _controller,
            scrollController: _scrollController,
            focusNode: _focusNode,
            autofocus: widget.active,
            hardwareKeyboardOnly: _isDesktop,
            onKeyEvent: _handleKeyEvent,
            onTapUp: _handleTapUp,
            textStyle: xterm.TerminalStyle(
              fontSize: widget.fontSize,
              fontFamily: 'JetBrainsMono',
              fontFamilyFallback: kMonoFontFallback,
            ),
            theme: _theme,
          ),
        ),
      ),
    );

    if (!_searchOpen) return terminalArea;
    return Stack(
      children: [
        terminalArea,
        Positioned(top: 0, left: 0, right: 0, child: _buildSearchBar()),
      ],
    );
  }
}

/// 中键判定：必须**只有**中键按下。
///
/// 鼠标事件里的 buttons 是位掩码（1=左 2=右 4=中），而 Flutter 没有导出
/// 对应的常量类（只有 kSecondaryButton/kTertiaryButton 这类单值常量），
/// 所以这里自带一个最小的命名常量集，避免代码里散落 1/2/4 字面量。
/// 组合按下（如中键+左键、拖动中同时按别的键）不算中键粘贴。
class PointerButtons {
  static const int none = 0;
  static const int primary = 1;
  static const int secondary = 2;
  static const int middle = 4;

  const PointerButtons._();
}

bool isMiddleClick(int buttons) => buttons == PointerButtons.middle;

/// Insert 键的路由结果（Windows 控制台惯例）
enum InsertRouting { none, copySelection, pasteSkipConfirm }

/// Ctrl+Insert = 复制选区，Shift+Insert = 粘贴（跳过多行确认）。
/// 两者同时按下时优先复制——与已有的 Ctrl+Shift+C 语义保持一致。
/// 裸 Insert 返回 [InsertRouting.none]：不吞键，交回 xterm 的 keyInput
/// （vi 的插入模式等场景需要它）。
InsertRouting resolveInsertRouting({required bool ctrl, required bool shift}) {
  if (ctrl) return InsertRouting.copySelection;
  if (shift) return InsertRouting.pasteSkipConfirm;
  return InsertRouting.none;
}

/// Ctrl+A 要发给 shell 的字节：readline 的行首。
/// 无 Ctrl 时返回 null —— 绝不能把裸的 A 变成控制字符。
String? resolveCtrlAByte({required bool ctrl}) => ctrl ? '\x01' : null;

/// 一次粘贴的分发结果。[pasted] 为 null 表示什么都不做。
class PasteRoute {
  const PasteRoute._({this.pasted, required this.confirmNeeded});

  final String? pasted;

  /// 内容多行、且还没确认过 → 调用方需要先弹多行确认
  final bool confirmNeeded;
}

/// 粘贴分发口径：
/// - 空串 → 不粘贴；
/// - skipConfirm（Shift+Insert / 中键）→ 原样粘贴，终端惯例是一次全发；
/// - 多行且未确认 → 只标出 confirmNeeded，由调用方去问用户；
/// - 其余（单行、或已确认）→ 原样粘贴。
PasteRoute routePaste(String text,
    {required bool skipConfirm, required bool confirmed}) {
  if (text.isEmpty) {
    return const PasteRoute._(pasted: null, confirmNeeded: false);
  }
  if (skipConfirm) {
    return PasteRoute._(pasted: text, confirmNeeded: false);
  }
  if (isMultiLine(text) && !confirmed) {
    return const PasteRoute._(pasted: null, confirmNeeded: true);
  }
  return PasteRoute._(pasted: text, confirmNeeded: false);
}

/// 右键菜单里那几个「复制/粘贴/全选」项的快捷键文案，按平台取修饰键。
///
/// 必须分开：xterm 在苹果平台上用的是另一张快捷键表
/// （shortcuts.dart 的 `_defaultAppleShortcuts` → Cmd+C / Cmd+V / Cmd+A），
/// Ctrl+Shift+C、Ctrl+V、Ctrl+A 在 mac 上**没有任何绑定**。菜单照抄
/// Windows 的写法，就是在告诉 mac 用户去按一组按了没反应的键。
enum TerminalMenuAction { copy, paste, selectAll }

String terminalShortcutLabel(TerminalMenuAction action, {required bool isMac}) {
  switch (action) {
    case TerminalMenuAction.copy:
      // mac 走系统惯例 ⌘C；非 mac 要带 Shift，否则 Ctrl+C 是发中断信号
      return isMac ? '⌘C' : 'Ctrl+Shift+C';
    case TerminalMenuAction.paste:
      return isMac ? '⌘V' : 'Ctrl+V';
    case TerminalMenuAction.selectAll:
      return isMac ? '⌘A' : 'Ctrl+A';
  }
}
