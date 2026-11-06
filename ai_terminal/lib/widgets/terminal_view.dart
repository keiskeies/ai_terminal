import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
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
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../services/agent_logger.dart';
import '../utils/terminal_text_actions.dart';
import 'terminal_context_menu.dart';

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

  const TerminalView({
    super.key,
    this.terminal,
    this.onSend,
    this.fontSize = 13,
    this.isLocal = true,
    this.onFontSizeChanged,
    this.onMenuIntent,
    this.active = true,
  });

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  final FocusNode _focusNode = FocusNode();
  // TerminalController 用于管理终端选区，右键复制时读取选中文本
  final xterm.TerminalController _controller = xterm.TerminalController();
  final GlobalKey _terminalContainerKey = GlobalKey();

  static const _darkTheme = xterm.TerminalTheme(
    cursor: cBrand,
    selection: Color(0x4D45C8C3),
    foreground: Color(0xFFE6ECE8),
    background: cTerminalBg,
    black: Color(0xFF1A1D1C),
    red: cStatusError,
    green: cStatusOk,
    yellow: cStatusWarn,
    blue: Color(0xFF6AA9FF),
    magenta: Color(0xFFD98AD9),
    cyan: cBrand,
    white: Color(0xFFE6ECE8),
    brightBlack: Color(0xFF6F7671),
    brightRed: Color(0xFFFF9AA2),
    brightGreen: Color(0xFF8FE7B4),
    brightYellow: Color(0xFFF2C276),
    brightBlue: Color(0xFF8CC0FF),
    brightMagenta: Color(0xFFE9A8E9),
    brightCyan: cBrandHover,
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFF1A2423),
    searchHitBackgroundCurrent: Color(0xFF243331),
    searchHitForeground: Color(0xFFF1F3F1),
  );

  static const _lightTheme = xterm.TerminalTheme(
    cursor: cBrandLight,
    selection: Color(0x330B7A75),
    foreground: Color(0xFF1A1F1D),
    background: cTerminalOutputLight,
    black: Color(0xFF2A2F2C),
    red: cStatusErrorLight,
    green: cStatusOkLight,
    yellow: cGoldLight,
    blue: Color(0xFF1F5FA8),
    magenta: Color(0xFF8A3A8A),
    cyan: cBrandLight,
    white: Color(0xFF6F7872),
    brightBlack: cTextMutedLight,
    brightRed: Color(0xFFD14343),
    brightGreen: Color(0xFF2E9B63),
    brightYellow: Color(0xFFA66F00),
    brightBlue: Color(0xFF2E7BC4),
    brightMagenta: Color(0xFFA94FA9),
    brightCyan: Color(0xFF159792),
    brightWhite: cTextMainLight,
    searchHitBackground: Color(0xFFDFF3F1),
    searchHitBackgroundCurrent: Color(0xFFC9EAE7),
    searchHitForeground: Color(0xFF171B19),
  );

  xterm.TerminalTheme get _theme =>
      ThemeColors.of(context).isLight ? _lightTheme : _darkTheme;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final terminalChanged =
        widget.terminal != null && widget.terminal != oldWidget.terminal;
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
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 键盘事件处理：
  /// - KeyUpEvent 拦截（防止 CustomKeyboardListener 重复插入字符）
  /// - character 为 null 时（Windows IME 问题）从 keyLabel fallback
  /// - 其他情况返回 ignored，让 xterm keyInput + CustomKeyboardListener 处理
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // KeyUpEvent 拦截：CustomKeyboardListener._onKeyEvent 对所有事件类型
    // 都尝试 onInsert，而 xterm _handleKeyEvent 对 KeyUpEvent 返回 ignored，
    // 导致字符被插入两次。
    if (event is KeyUpEvent) {
      return KeyEventResult.handled;
    }

    // 只处理 KeyDownEvent 和 KeyRepeatEvent
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // 粘贴统一走自己的路径：多行内容要先确认，避免一次落进多条命令。
    // （xterm 默认把 Ctrl/Cmd+V 直接交给 terminal.paste，绕过了确认）
    final hw = HardwareKeyboard.instance;
    if (event is KeyDownEvent &&
        (hw.isControlPressed || hw.isMetaPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyV) {
      _pasteFromClipboard();
      return KeyEventResult.handled;
    }

    final terminal = widget.terminal;
    if (terminal == null) {
      return KeyEventResult.ignored;
    }

    final hardware = HardwareKeyboard.instance;
    final hasCtrl = hardware.isControlPressed;
    final hasAlt = hardware.isAltPressed;
    final hasMeta = hardware.isMetaPressed;

    // 只在没有 ctrl/alt/meta 修饰键且 character 为 null 时提供 fallback。
    // 有修饰键时交给 xterm keyInput 处理（如 Ctrl+C → \x03）。
    // character 不为 null 时交给 CustomKeyboardListener 的 character 路径处理。
    if (!hasCtrl && !hasAlt && !hasMeta &&
        (event.character == null || event.character!.isEmpty)) {
      final char = _charFromKeyEvent(event, hardware.isShiftPressed);
      if (char != null && char.isNotEmpty) {
        terminal.textInput(char);
        return KeyEventResult.handled;
      }
    }

    // 返回 ignored，让 xterm 继续处理：
    // 1. _handleKeyEvent → keyInput（处理特殊键如 Enter/Tab/方向键/Ctrl+字母）
    // 2. CustomKeyboardListener 检查 character（如果不为 null）
    return KeyEventResult.ignored;
  }

  /// 当 KeyEvent.character 为 null 时（Windows IME 问题），
  /// 从 LogicalKeyboardKey.keyLabel 生成字符。
  String? _charFromKeyEvent(KeyEvent event, bool shift) {
    final key = event.logicalKey;

    // Space 键
    if (key == LogicalKeyboardKey.space) {
      return ' ';
    }

    final label = key.keyLabel;
    if (label.length != 1) {
      return null;
    }

    // 字母键：keyLabel 返回大写，根据 shift 决定大小写
    if (RegExp(r'[a-zA-Z]').hasMatch(label)) {
      return shift ? label.toUpperCase() : label.toLowerCase();
    }

    // 数字键和符号键：keyLabel 直接是字符
    // 注意：Shift+数字键的符号（如 Shift+1=!）无法通过 keyLabel 获取，
    // 但这只在 character 为 null 时作为 fallback，覆盖大多数场景。
    return label;
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
    final box = _terminalContainerKey.currentContext?.findRenderObject();
    if (terminal == null || box is! RenderBox) return const [];
    final render = _findRenderTerminal(box);
    if (render == null) return const [];
    final cell = render.getCellOffset(render.globalToLocal(globalPosition));
    final buffer = terminal.buffer;
    final texts = <String>[];
    for (final delta in const [0, -1, 1]) {
      final y = cell.y + delta;
      if (y < 0 || y >= buffer.height) continue;
      final text = buffer.lines[y].getText();
      if (text.trim().isNotEmpty && !texts.contains(text)) texts.add(text);
    }
    agentLogger.debug(
        'Terminal', '右键行: cell=(${cell.x},${cell.y}) 命中=${texts.length}');
    return texts;
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
    if (text != null && text.trim().isNotEmpty) {
      items.add(TerminalMenuItem(
        label: UiText.t('复制', 'Copy'),
        icon: Icons.copy_rounded,
        shortcut: 'Ctrl+Shift+C',
        onTap: () {
          Clipboard.setData(ClipboardData(text: text));
          _controller.clearSelection();
        },
      ));
    } else {
      items.add(TerminalMenuItem(
        label: UiText.t('全选', 'Select all'),
        icon: Icons.select_all_rounded,
        shortcut: 'Ctrl+A',
        onTap: _selectAll,
      ));
    }
    items.add(TerminalMenuItem(
      label: UiText.t('粘贴', 'Paste'),
      icon: Icons.paste_rounded,
      shortcut: 'Ctrl+V',
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
    if (widget.onFontSizeChanged != null) {
      items.add(TerminalMenuItem(
        label: UiText.t('放大字号', 'Increase font size'),
        icon: Icons.text_increase_rounded,
        separatorBefore: true,
        enabled: widget.fontSize < 24,
        onTap: () => widget.onFontSizeChanged!(widget.fontSize + 1),
      ));
      items.add(TerminalMenuItem(
        label: UiText.t('缩小字号', 'Decrease font size'),
        icon: Icons.text_decrease_rounded,
        enabled: widget.fontSize > 10,
        onTap: () => widget.onFontSizeChanged!(widget.fontSize - 1),
      ));
      items.add(TerminalMenuItem(
        label: UiText.t('重置字号', 'Reset font size'),
        icon: Icons.text_fields_rounded,
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
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    // 多行粘贴等于批量执行：先给用户看一眼再落进去
    if (isMultiLine(text) && !await _confirmMultiLinePaste(text)) return;
    if (!mounted) return;
    widget.terminal?.paste(text);
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
          title: Text(UiText.t('粘贴 ${lines.length} 行内容？', 'Paste ${lines.length} lines?'),
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
                        ? UiText.t('$preview\n… 还有 $more 行', '$preview\n… and $more more lines')
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
        content: Text(UiText.t('已复制 ${text.length} 字符', 'Copied ${text.length} characters'), style: const TextStyle(fontSize: fSmall)),
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
        content: Text(UiText.t('已保存到 $path', 'Saved to $path'), style: const TextStyle(fontSize: fSmall)),
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
        color: tc.terminalBg,
        child: Center(
          child: Text(UiText.t('等待连接...', 'Waiting for connection...'), style: TextStyle(color: tc.textSub)),
        ),
      );
    }

    // 桌面平台使用 hardwareKeyboardOnly=true（CustomKeyboardListener 路径）。
    //
    // 为什么不用默认的 CustomTextEdit 路径：
    // CustomTextEdit 通过 TextInput.attach 建立连接，期望通过
    // updateEditingValue 回调获取字符。但 Windows 桌面的 TextInput
    // 实现不通过 updateEditingValue 发送普通键盘字符（只用于 IME）。
    // 结果：keyInput 对字母键返回 false → ignored → 传递给 TextInput →
    // TextInput 不处理 → 字符丢失。只有 keytab 中有映射的特殊键
    // （Enter/Tab/Backspace/方向键等）能正常工作。
    //
    // hardwareKeyboardOnly=true 的 CustomKeyboardListener 路径：
    // keyInput 失败后从 KeyEvent.character 插入字符。但 Windows 上
    // IME 激活时 character 可能为 null，所以通过 onKeyEvent 回调
    // 提供 fallback：从 LogicalKeyboardKey.keyLabel 生成字符。
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);

    // 用 Listener 在外层直接监听原始指针事件，不依赖 xterm 内部的
    // 手势处理器。Listener 不参与手势竞技，不会干扰 xterm 的左键选区
    // 和键盘焦点，但能在手势竞技之前接收到所有指针事件。
    //
    // 事件分发顺序：Listener → xterm.TerminalView 内部手势 → xterm.TerminalView
    // 所以右侧也能收到。
    // xterm 的 RenderTerminal.paint 不做裁剪：滚动偏移不在行高整数倍时
    // （视口高度一般不是行高整数倍，底部对齐必然如此），顶部那一行会被
    // 画到视口上边界之外。终端上方紧挨着标签栏，多出来的行就会盖到 tab 上。
    return Listener(
      onPointerDown: (event) {
        // onPointerDown 会收到所有鼠标按钮按下+触摸。
        // kSecondaryButton = 2，对应右键（Mac 双指点击 / Windows 右键）
        if (event.buttons == kSecondaryButton) {
          // event.position 是相对 Listener 的局部坐标，转换为全局坐标
          final renderBox =
              _terminalContainerKey.currentContext?.findRenderObject();
          if (renderBox is RenderBox) {
            _showContextMenu(renderBox.localToGlobal(event.position));
          }
        }
      },
      child: ClipRect(
        child: Container(
          key: _terminalContainerKey,
          child: xterm.TerminalView(
            widget.terminal!,
            controller: _controller,
            focusNode: _focusNode,
            autofocus: widget.active,
            hardwareKeyboardOnly: isDesktop,
            onKeyEvent: _handleKeyEvent,
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
  }
}

