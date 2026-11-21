import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../models/agent_permission_mode.dart';
import 'permission_mode_selector.dart';

/// AI 输入框，支持斜杠命令建议（内置命令 + 运维模板）。
///
/// 键盘约定（与主流 AI 对话平台一致）：
/// - Enter / NumpadEnter：浮层打开时执行高亮项，否则发送
/// - Shift + Enter：换行（优先于浮层操作）
/// - ↑ / ↓：切换高亮项；Tab：选中高亮项（内置命令填入输入框，模板直接执行）
/// - Esc：关闭浮层
class AIPromptInput extends StatefulWidget {
  final bool enabled;
  final bool isRunning;
  final String hintText;
  final String initialText;
  final Function(String) onSend;
  /// O5: 运行中补充指令（steering）回调。提供时运行态输入保持可用，
  /// Enter/补充按钮走这里而不是 onSend；null 时保持旧行为（运行中禁发）。
  final ValueChanged<String>? onSteer;
  final VoidCallback? onStop;
  final ValueChanged<String>? onChanged;
  final ValueChanged<bool>? onFocusChanged;
  final Color accentColor;
  /// 斜杠命令回调：返回 true 表示命令已被处理（不再走 onSend）
  final bool Function(String command)? onSlashCommand;
  /// 额外的建议项（运维模板等）。与 [kSlashCommands] 分开，避免污染
  /// `parseSlashCommand` 的已知命令集合——模板名不是可解析的命令。
  final List<SlashCommand> slashExtras;
  /// 是否处于多机编排模式（只影响边框配色，开关按钮在上方工具栏）
  final bool isOrchestratorMode;
  /// 输入框底部工具行里的附加控件（模型/思考档位胶囊等）。
  /// 放在发送按钮左侧，宽度自适应并允许省略。
  final Widget? footer;

  /// 当前执行权限档位（只读 / 询问 / 自动 / 全自动）
  final AgentPermissionMode permissionMode;

  /// 切换执行权限档位；null 时不显示权限胶囊
  final ValueChanged<AgentPermissionMode>? onPermissionModeChanged;

  const AIPromptInput({
    super.key,
    required this.enabled,
    this.isRunning = false,
    required this.hintText,
    this.initialText = '',
    required this.onSend,
    this.onSteer,
    this.onStop,
    this.onChanged,
    this.onFocusChanged,
    required this.accentColor,
    this.onSlashCommand,
    this.slashExtras = const [],
    this.isOrchestratorMode = false,
    this.footer,
    this.permissionMode = AgentPermissionMode.ask,
    this.onPermissionModeChanged,
  });

  @override
  State<AIPromptInput> createState() => _AIPromptInputState();
}

/// 斜杠建议项定义。
///
/// [isTemplate] 为 true 时表示运维模板：选中后走 [onSelect] 直接执行，
/// 不把文本填进输入框；内置命令则只填入命令名，参数由用户继续输入。
class SlashCommand {
  final String command;
  final String description;

  /// 是否为运维模板（区别于内置斜杠命令）
  final bool isTemplate;

  /// 条目前缀（模板 emoji 图标）
  final String? leading;

  /// 条目右侧类型徽标（如 AI / CMD）
  final String? badge;

  /// 模糊匹配文本；模板默认用 `name + description`，内置命令用命令名
  final String? searchText;

  /// 自定义选中行为（模板用）
  final VoidCallback? onSelect;

  /// 英文文案；只给内置命令用。
  ///
  /// [description] 是 `const` 表里的字面量，编译期就钉成中文了，所以英文界面
  /// 必须在这里带一份对照，渲染时用 [displayDescription] 取。运维模板的文案在
  /// 读取时才本地化，不需要这一份。
  final String? descriptionEn;

  /// 渲染用文案：有英文对照且当前不是中文界面时用英文。
  String get displayDescription =>
      descriptionEn != null && !UiText.zh ? descriptionEn! : description;

  const SlashCommand(
    this.command,
    this.description, {
    this.descriptionEn,
    this.isTemplate = false,
    this.leading,
    this.badge,
    this.searchText,
    this.onSelect,
  });
}

const List<SlashCommand> kSlashCommands = [
  SlashCommand('/new', '新建会话', descriptionEn: 'New session'),
  SlashCommand('/compact', '压缩记忆（总结早期对话）',
      descriptionEn: 'Compact memory (summarise earlier turns)'),
  SlashCommand('/goal', '目标模式：/goal <目标> 开始；子命令 pause / resume / edit / done / clear',
      descriptionEn:
          'Goal mode: /goal <objective>; subcommands pause / resume / edit / done / clear'),
  SlashCommand('/plan', '只要计划不执行：/plan <目标>（临时只读，结束自动还原）',
      descriptionEn:
          'Plan only, no execution: /plan <objective> (read-only, restored on exit)'),
  SlashCommand('/model', '切换模型：/model <名称>，不带参数则列出可选模型',
      descriptionEn: 'Switch model: /model <name>; no argument lists models'),
  SlashCommand('/permission', '切换执行权限：/permission <只读|询问|自动|全自动>',
      descriptionEn:
          'Change permission: /permission <read-only|ask|auto|full-auto>'),
  SlashCommand('/export', '复制当前会话到剪贴板，并给出执行日志路径',
      descriptionEn: 'Copy the session to the clipboard with its log path'),
  SlashCommand('/help', '列出全部命令', descriptionEn: 'List all commands'),
];

/// 斜杠建议浮层的测试定位键。
const Key kSlashOverlayKey = Key('slash_suggestions_overlay');

class _AIPromptInputState extends State<AIPromptInput> {
  /// 浮层条目固定高度：与键盘导航/虚拟窗口的滚动计算保持一致。
  static const double _kItemHeight = 38.0;
  static const double _kHintHeight = 22.0;
  static const double _kVerticalPadding = 8.0;
  static const double _kMaxOverlayHeight = 500.0;
  static const double _kBorderWidth = 1.0;
  static const double _kGap = 6.0;
  /// 首屏至少能同时看到 8 条内置命令和几条运维模板，避免模板被完全藏住。
  static const int _kMaxVisibleItems = 12;

  /// 输入字符上限
  static const int _maxLength = 50000;

  late TextEditingController _controller;
  final _focusNode = FocusNode();
  String _lastInitialText = '';
  bool _isFocused = false;

  /// 父组件回写 initialText 时抑制建议检测，避免在 build 阶段操作 Overlay。
  bool _suppressDetect = false;

  /// Esc 关闭浮层时的文本：文本不变就不重新弹出。
  String? _escDismissedText;

  /// 已通过 Tab/点击填入的命令名：以其为前缀继续输入参数时不打扰用户。
  String? _acceptedCommand;

  OverlayEntry? _slashOverlay;

  /// 浮层所在的 Overlay 状态。定位必须用它（而不是 OverlayEntry builder 的
  /// context）测量：builder context 首帧还没有子 RenderObject，第二次构建时
  /// 又只会拿到浮层自身的尺寸，两者都不能代表 Overlay 坐标系。
  OverlayState? _overlayState;
  List<SlashCommand> _filteredCommands = [];
  int _highlightedIndex = 0;

  /// 虚拟窗口：只渲染 [_visibleCount] 条，键盘/滚轮移动窗口，
  /// 避免 Overlay 反复插入时复用 ScrollController 引发的重复 attach。
  int _windowStart = 0;
  int _visibleCount = _kMaxVisibleItems;

  /// 浮层在全局坐标系中的矩形，供 TextField.onTapOutside 判断点击落点。
  Rect? _overlayRect;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _lastInitialText = widget.initialText;
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(() {
      final focused = _focusNode.hasFocus;
      if (focused != _isFocused) {
        setState(() => _isFocused = focused);
        widget.onFocusChanged?.call(focused);
      }
      if (!focused) {
        _hideSlashOverlay();
      }
    });
  }

  void _onTextChanged() {
    widget.onChanged?.call(_controller.text);
    if (!_suppressDetect) _detectSlashCommand();
  }

  /// 检测输入框中的斜杠前缀，同步更新建议浮层。
  ///
  /// 内置命令按前缀匹配；运维模板按名称/描述做子串匹配，
  /// 因此输入 `/巡检` 或 `/disk` 都能直接命中模板。
  void _detectSlashCommand() {
    final text = _controller.text;
    if (!text.startsWith('/') || text.contains('\n') || text.contains('\r')) {
      _acceptedCommand = null;
      _escDismissedText = null;
      _hideSlashOverlay();
      return;
    }

    // Esc 关闭后，文本未变化就保持关闭；用户继续输入则立即恢复。
    final esc = _escDismissedText;
    if (esc != null) {
      if (esc == text) return;
      _escDismissedText = null;
    }
    // 已选中命令后继续写参数（如 `/goal 修复磁盘`）不再弹出建议；
    // 用户删改前缀则恢复建议。
    final accepted = _acceptedCommand;
    if (accepted != null) {
      if (text.startsWith(accepted)) return;
      _acceptedCommand = null;
    }

    final raw = text.substring(1);
    final space = raw.indexOf(' ');
    final token = (space < 0 ? raw : raw.substring(0, space)).trim().toLowerCase();
    final hasArgs = space >= 0;

    final builtins = <SlashCommand>[];
    if (!hasArgs) {
      for (final c in kSlashCommands) {
        if (c.command.toLowerCase().startsWith('/$token')) builtins.add(c);
      }
    }
    final templates = <SlashCommand>[];
    for (final c in widget.slashExtras) {
      final haystack = (c.searchText ?? c.command).toLowerCase();
      if (token.isEmpty || haystack.contains(token)) templates.add(c);
    }

    final filtered = <SlashCommand>[...builtins, ...templates];
    if (filtered.isEmpty) {
      _hideSlashOverlay();
      return;
    }
    _filteredCommands = filtered;
    _highlightedIndex = _highlightedIndex.clamp(0, filtered.length - 1);
    _syncWindow();
    _showSlashOverlay();
  }

  void _showSlashOverlay() {
    if (_slashOverlay == null) {
      // 插入根 Overlay：避免被嵌套 Overlay 裁剪；用户输入回调不在 build 阶段，
      // 可以同步插入，浮层在下一帧即可见（不再需要等第二次输入）。
      final state = Overlay.of(context, rootOverlay: true);
      _overlayState = state;
      final entry = OverlayEntry(builder: _buildSlashOverlay);
      _slashOverlay = entry;
      state.insert(entry);
    } else {
      _slashOverlay!.markNeedsBuild();
    }
  }

  void _hideSlashOverlay() {
    _slashOverlay?.remove();
    _slashOverlay = null;
    _overlayState = null;
    _overlayRect = null;
    _filteredCommands = [];
  }

  /// 保持高亮项落在可见窗口内。
  void _syncWindow() {
    final len = _filteredCommands.length;
    if (len == 0) {
      _windowStart = 0;
      return;
    }
    final count = math.max(1, math.min(_visibleCount, len));
    final maxStart = math.max(0, len - count);
    var start = _windowStart.clamp(0, maxStart);
    if (_highlightedIndex < start) start = _highlightedIndex;
    if (_highlightedIndex >= start + count) start = _highlightedIndex - count + 1;
    _windowStart = start.clamp(0, maxStart);
  }

  Widget _buildSlashOverlay(BuildContext overlayContext) {
    if (_filteredCommands.isEmpty) return const SizedBox.shrink();
    // 关键：尺寸与位置必须取「输入框自身」的 RenderBox。
    // 原来用 OverlayEntry builder 的 context 测量，拿到的是整个 Overlay
    // （近全屏）的尺寸，导致浮层宽度铺满屏幕、bottom 被顶到屏幕外。
    final inputBox = context.findRenderObject() as RenderBox?;
    final overlayBox = _overlayState?.context.findRenderObject() as RenderBox?;
    if (inputBox == null ||
        overlayBox == null ||
        !inputBox.attached ||
        !overlayBox.attached) {
      return const SizedBox.shrink();
    }

    final globalTopLeft = inputBox.localToGlobal(Offset.zero);
    final local = overlayBox.globalToLocal(globalTopLeft);
    final overlaySize = overlayBox.size;
    final width = math.min(inputBox.size.width, overlaySize.width);
    final left = local.dx
        .clamp(0.0, math.max(0.0, overlaySize.width - width))
        .toDouble();

    // 浮层向上展开，最高不超过输入框上方可用空间。
    // Container 的 1px 上下边框也占高度，计入约束避免 Column 溢出。
    const borderInset = 2 * _kBorderWidth;
    const minOverlayHeight =
        _kItemHeight + _kHintHeight + _kVerticalPadding + borderInset;
    final available = local.dy - _kGap - 4;
    final maxHeight = math.min(
      _kMaxOverlayHeight,
      math.max(minOverlayHeight, available),
    );
    final maxListHeight = math.max(
      _kItemHeight,
      maxHeight - _kHintHeight - _kVerticalPadding - borderInset,
    );
    var count = math.min(_filteredCommands.length, _kMaxVisibleItems);
    while (count > 1 && count * _kItemHeight > maxListHeight) {
      count--;
    }
    _visibleCount = math.max(1, count);
    _syncWindow();
    final end = math.min(_filteredCommands.length, _windowStart + _visibleCount);
    final shown = math.max(0, end - _windowStart);
    final contentHeight = shown * _kItemHeight + _kHintHeight + _kVerticalPadding;
    final outerHeight = contentHeight + borderInset;

    // 记录全局矩形：点击浮层时不让 TextField 失焦，否则浮层会在
    // GestureDetector.onTap 完成前被移除，点击直接丢失。
    _overlayRect = Rect.fromLTWH(
      globalTopLeft.dx + (left - local.dx),
      globalTopLeft.dy - _kGap - outerHeight,
      width,
      outerHeight,
    );

    final tc = ThemeColors.of(overlayContext);
    return Positioned(
      left: left,
      width: width,
      bottom: overlaySize.height - local.dy + _kGap,
      child: SizedBox(
        height: outerHeight,
        child: Listener(
          onPointerSignal: (signal) {
            if (signal is! PointerScrollEvent) return;
            final delta = signal.scrollDelta.dy > 0 ? 1 : -1;
            _scrollWindow(delta);
          },
          child: Container(
            key: kSlashOverlayKey,
            decoration: BoxDecoration(
              color: tc.cardElevated,
              borderRadius: BorderRadius.circular(rSmall),
              border: Border.all(color: tc.border, width: 1),
              boxShadow: shadowLg,
            ),
            // root Overlay 之上没有 DefaultTextStyle 祖先，缺 Material 时
            // 文字会落到 fallback 样式（黄色双下划线）。
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      height: _kHintHeight,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              UiText.t('↑↓ 切换   Tab 选择   Enter 执行   Esc 关闭',
                                  '↑↓ navigate   Tab select   Enter run   Esc close'),
                              style: TextStyle(color: tc.textSub, fontSize: fMicro),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_filteredCommands.length}',
                            style: TextStyle(color: tc.textMuted, fontSize: fMicro),
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (int i = _windowStart; i < end; i++)
                    SizedBox(
                      height: _kItemHeight,
                      child: _SlashCommandItem(
                        command: _filteredCommands[i],
                        isHighlighted: i == _highlightedIndex,
                        accentColor: widget.accentColor,
                        tc: tc,
                        onHover: () => _setHighlight(i),
                        onTap: () => _activateIndex(i, execute: false),
                      ),
                    ),
                  const SizedBox(height: _kVerticalPadding),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _scrollWindow(int delta) {
    final maxStart = math.max(0, _filteredCommands.length - _visibleCount);
    final next = (_windowStart + delta).clamp(0, maxStart);
    if (next == _windowStart) return;
    _windowStart = next;
    _highlightedIndex = _highlightedIndex.clamp(next, next + _visibleCount - 1);
    _slashOverlay?.markNeedsBuild();
  }

  void _setHighlight(int index) {
    if (_highlightedIndex == index || index >= _filteredCommands.length) return;
    _highlightedIndex = index;
    _syncWindow();
    _slashOverlay?.markNeedsBuild();
  }

  void _moveHighlight(int delta) {
    final len = _filteredCommands.length;
    if (len == 0) return;
    _highlightedIndex = (_highlightedIndex + delta + len) % len;
    _syncWindow();
    _slashOverlay?.markNeedsBuild();
  }

  /// 执行/填入指定项。
  /// [execute] 为 true 时表示 Enter：内置命令直接执行、模板直接运行；
  /// 为 false 时表示 Tab / 点击：内置命令仅填入输入框等待参数。
  void _activateIndex(int index, {required bool execute}) {
    if (index < 0 || index >= _filteredCommands.length) return;
    final cmd = _filteredCommands[index];
    _hideSlashOverlay();
    if (cmd.isTemplate) {
      _clearInput();
      cmd.onSelect?.call();
      return;
    }
    if (execute) {
      _clearInput();
      _executeSlashCommand(cmd);
      return;
    }
    _acceptedCommand = cmd.command;
    _escDismissedText = null;
    _controller.text = cmd.command;
    _controller.selection = TextSelection.collapsed(offset: cmd.command.length);
  }

  void _clearInput() {
    _acceptedCommand = null;
    _escDismissedText = null;
    _controller.clear();
  }

  /// 键盘事件：浮层导航、Enter 发送、Shift+Enter 换行。
  /// 返回 handled 表示消费事件（阻止 TextField 默认行为，如光标移动/换行）。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // 长按方向键会持续发 KeyRepeatEvent，一并处理，否则高亮会时断时续。
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final isEnter = key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;

    // Shift+Enter 始终换行，优先于浮层的 Enter 执行语义。
    if (isEnter && shift) return KeyEventResult.ignored;

    final slashActive = _slashOverlay != null && _filteredCommands.isNotEmpty;
    if (slashActive) {
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveHighlight(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveHighlight(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab) {
        if (shift) {
          _moveHighlight(-1);
        } else {
          _activateIndex(_highlightedIndex, execute: false);
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _escDismissedText = _controller.text;
        _hideSlashOverlay();
        return KeyEventResult.handled;
      }
      if (isEnter) {
        _activateIndex(_highlightedIndex, execute: true);
        return KeyEventResult.handled;
      }
    }

    if (isEnter) {
      // 无论是否发送成功都消费事件，避免空输入按 Enter 也产生换行。
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _executeSlashCommand(SlashCommand cmd) {
    final handled = widget.onSlashCommand?.call(cmd.command) ?? false;
    if (handled) return;
    // 默认行为：作为普通文本发送
    widget.onSend(cmd.command);
  }

  @override
  void didUpdateWidget(covariant AIPromptInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialText != _lastInitialText &&
        widget.initialText != _controller.text) {
      // didUpdateWidget 处在 build 阶段，不能直接插入/移除 Overlay。
      _suppressDetect = true;
      _controller.text = widget.initialText;
      _suppressDetect = false;
      _lastInitialText = widget.initialText;
      if (_slashOverlay != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _hideSlashOverlay();
        });
      }
    }
  }

  @override
  void dispose() {
    _hideSlashOverlay();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled) return;
    if (widget.isRunning) {
      // O5: 运行中发送 = 补充指令（steering），下一轮循环边界注入。
      // 未提供 onSteer 时保持旧行为：运行中不发送（按终止按钮才能中断）。
      final steer = widget.onSteer;
      if (steer == null) return;
      steer(text);
      _clearInput();
      return;
    }
    // 若是斜杠命令，优先走 onSlashCommand
    if (text.startsWith('/') && widget.onSlashCommand != null) {
      final handled = widget.onSlashCommand!(text);
      if (handled) {
        _clearInput();
        return;
      }
    }
    widget.onSend(text);
    _clearInput();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final running = widget.isRunning;
    final accent = widget.accentColor;
    final isOrch = widget.isOrchestratorMode;
    final effectiveAccent = isOrch ? tc.warn : accent;
    final borderColor = _isFocused
        ? effectiveAccent
        : (isOrch ? tc.warn : tc.border);

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: Container(
        decoration: BoxDecoration(
          color: tc.card,
          borderRadius: BorderRadius.circular(rMedium),
          border: Border.all(
            color: widget.enabled
                ? borderColor
                : tc.border.withValues(alpha: 0.5),
            width: 1,
          ),
          // 设计稿 .ai-compose:focus-within 是「1px 品牌色边框 + 0 0 0 1px 光晕」，
          // 只换边框色在深色面板上几乎看不出聚焦，外面再套一圈同色才算亮起来。
          boxShadow: _isFocused
              ? [
                  BoxShadow(
                    color: effectiveAccent.withValues(alpha: 0.55),
                    blurRadius: 0,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              enabled: widget.enabled,
              // 单行太矮：多行需求（命令 + 上下文 + 约束）常被压成一屏看不完
              minLines: 2,
              maxLines: 5,
              maxLength: _maxLength,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              // 点击斜杠浮层本身时保持焦点：否则浮层会在 onTap 完成前被移除。
              onTapOutside: (event) {
                final rect = _overlayRect;
                if (rect != null &&
                    _slashOverlay != null &&
                    rect.contains(event.position)) {
                  return;
                }
                FocusManager.instance.primaryFocus?.unfocus();
              },
              // 过滤控制字符：防止小白粘贴二进制内容导致 JSON 序列化失败或数据污染
              inputFormatters: [
                FilteringTextInputFormatter.deny(
                  RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'),
                ),
              ],
              style: TextStyle(
                color: tc.textMain,
                fontSize: fBody,
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: TextStyle(color: tc.textMuted, fontSize: fBody),
                counterText: '',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                isDense: true,
              ),
              onSubmitted: (_) {},
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 6, 8),
              child: Row(
                children: [
                  if (widget.onPermissionModeChanged != null) ...[
                    PermissionModeSelector(
                      mode: widget.permissionMode,
                      onChanged: widget.onPermissionModeChanged!,
                      tc: tc,
                      compact: MediaQuery.sizeOf(context).width < 520,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: widget.footer ?? const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // O5: 运行中保留终止按钮，旁边加一个补充指令发送按钮
                  if (running && widget.onSteer != null && widget.enabled) ...[
                    _buildSteerButton(),
                    const SizedBox(width: 4),
                  ],
                  _buildSendButton(running),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// O5: 运行中的补充指令发送按钮（终止按钮左侧，样式与发送按钮一致）
  Widget _buildSteerButton() {
    final tc = ThemeColors.of(context);
    final isOrch = widget.isOrchestratorMode;
    return Tooltip(
      message: UiText.t('补充指令（下一轮生效）', 'Steering instruction (applies next turn)'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _send,
          child: AnimatedContainer(
            duration: animFast,
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: isOrch ? tc.warn : tc.brand,
              borderRadius: BorderRadius.circular(rFull),
            ),
            child: Icon(
              Icons.arrow_upward_rounded,
              color: tc.isLight ? Colors.white : cBg,
              size: 16,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSendButton(bool running) {
    final tc = ThemeColors.of(context);
    final canSend = widget.enabled && !running;
    final isOrch = widget.isOrchestratorMode;
    final sendColor = isOrch ? tc.warn : tc.brand;
    final bgColor = running
        ? tc.error
        : canSend
            ? sendColor
            : tc.textMuted.withValues(alpha: 0.5);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: running
            ? widget.onStop
            : (canSend ? _send : null),
        child: AnimatedContainer(
          duration: animFast,
          width: 34,
          height: 34,
          // 圆形：这一排的其他元素（权限胶囊、模型胶囊）都是全圆角胶囊
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(rFull),
          ),
          child: running
              ? Center(
                  child: Container(
                    width: 10,
                    height: 10,
                    color: tc.isLight ? Colors.white : cBg,
                  ),
                )
              : Icon(
                  Icons.arrow_upward_rounded,
                  color: tc.isLight ? Colors.white : cBg,
                  size: 16,
                ),
        ),
      ),
    );
  }
}

class _SlashCommandItem extends StatefulWidget {
  final SlashCommand command;
  final bool isHighlighted;
  final Color accentColor;
  final ThemeColors tc;
  final VoidCallback onHover;
  final VoidCallback onTap;

  const _SlashCommandItem({
    required this.command,
    required this.isHighlighted,
    required this.accentColor,
    required this.tc,
    required this.onHover,
    required this.onTap,
  });

  @override
  State<_SlashCommandItem> createState() => _SlashCommandItemState();
}

class _SlashCommandItemState extends State<_SlashCommandItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.isHighlighted || _isHovered;
    final cmd = widget.command;
    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        widget.onHover();
      },
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: active
              ? widget.accentColor.withValues(alpha: 0.12)
              : Colors.transparent,
          child: Row(
            children: [
              if (cmd.leading != null && cmd.leading!.isNotEmpty) ...[
                Text(cmd.leading!, style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
              ],
              Flexible(
                flex: 0,
                child: Text(
                  cmd.command,
                  style: TextStyle(
                    color: active ? widget.accentColor : widget.tc.textMain,
                    fontSize: fSmall,
                    fontFamily: 'JetBrainsMono', fontFamilyFallback: kMonoFontFallback,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (cmd.badge != null && cmd.badge!.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: widget.accentColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(rXSmall),
                    border: Border.all(
                      color: widget.accentColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    cmd.badge!,
                    style: TextStyle(
                      color: widget.accentColor,
                      fontSize: fMicro,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  cmd.displayDescription,
                  style: TextStyle(
                    color: widget.tc.textSub,
                    fontSize: fMicro,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
