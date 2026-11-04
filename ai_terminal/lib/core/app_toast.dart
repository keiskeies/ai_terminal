import 'dart:async';

import 'package:flutter/material.dart';

import 'constants.dart';

OverlayEntry? _currentToastEntry;

/// 顶部居中的全局提示
///
/// 替代底部 SnackBar：不遮挡底部操作栏，多个提示只保留最新一个。
void showTopSnackBar(BuildContext context, SnackBar snackBar) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) {
    // 没有 Overlay 的极端场景（测试/特殊宿主）退回原生 SnackBar
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(snackBar);
    return;
  }
  showTopSnackBarInOverlay(overlay, snackBar);
}

/// 供跨 await 的调用方预先捕获 root Overlay，避免使用已销毁的 context
void showTopSnackBarInOverlay(OverlayState overlay, SnackBar snackBar) {
  if (!overlay.mounted) return;
  final previous = _currentToastEntry;
  if (previous != null && previous.mounted) {
    previous.remove();
  }
  _currentToastEntry = null;

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _TopToast(
      snackBar: snackBar,
      onDismiss: () {
        if (entry.mounted) entry.remove();
        if (identical(_currentToastEntry, entry)) {
          _currentToastEntry = null;
        }
      },
    ),
  );
  _currentToastEntry = entry;
  overlay.insert(entry);
}

/// 清除当前顶部提示
void clearTopToast() {
  final entry = _currentToastEntry;
  if (entry != null && entry.mounted) {
    entry.remove();
  }
  _currentToastEntry = null;
}

class _TopToast extends StatefulWidget {
  const _TopToast({required this.snackBar, required this.onDismiss});

  final SnackBar snackBar;
  final VoidCallback onDismiss;

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _slide = Tween(
    begin: const Offset(0, -0.12),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  Timer? _timer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    final duration = widget.snackBar.duration;
    _timer = Timer(
      duration <= Duration.zero ? const Duration(seconds: 4) : duration,
      _dismiss,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    _timer?.cancel();
    try {
      await _controller.reverse();
    } catch (_) {
      // 页面/Overlay 已销毁
    }
    if (mounted) widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final snackBar = widget.snackBar;
    final accent = snackBar.backgroundColor ?? cBrand;
    final action = snackBar.action;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 12,
      left: 0,
      right: 0,
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: pStandard),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: SlideTransition(
              position: _slide,
              child: FadeTransition(
                opacity: _opacity,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: cCardElevated,
                      borderRadius: BorderRadius.circular(rLarge),
                      border: Border.all(color: cBorderHover),
                      boxShadow: shadowMd,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        pCompact,
                        pCompact,
                        pSmall,
                        pCompact,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 18,
                            color: accent,
                          ),
                          const SizedBox(width: pSmall),
                          Expanded(
                            child: DefaultTextStyle(
                              style: const TextStyle(
                                color: cTextMain,
                                fontSize: fSmall,
                                height: 1.4,
                              ),
                              child: snackBar.content,
                            ),
                          ),
                          if (action != null) ...[
                            const SizedBox(width: pSmall),
                            TextButton(
                              onPressed: () {
                                action.onPressed();
                                _dismiss();
                              },
                              style: TextButton.styleFrom(
                                foregroundColor: accent,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                minimumSize: const Size(0, 30),
                              ),
                              child: Text(action.label),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
