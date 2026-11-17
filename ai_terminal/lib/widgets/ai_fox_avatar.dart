import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 经典狐狸 + 青围巾 AI 助手头像。
///
/// 纯 [CustomPainter] 绘制，不依赖 SVG 资源，天然支持任意尺寸与深浅主题。
/// 眼睛以 Y 轴压缩的方式周期性眨动，默认约 3.2s 一次、每次 160ms，
/// 且入口自带随机相位，多个实例不会齐刷刷同时闭眼。
///
/// 用法：
/// ```dart
/// AiFoxAvatar(size: 14)                       // 模型胶囊小图标
/// AiFoxAvatar(size: 48)                       // App 标识 / 侧边栏头像
/// AiFoxAvatar(size: 24, animate: false)       // 静态场合（列表、表格）
/// AiFoxAvatar(size: 14, showScarf: false)     // 极小尺寸去掉围巾细节
/// ```
class AiFoxAvatar extends StatefulWidget {
  /// 渲染边长（正方形）。建议 14–64。
  final double size;

  /// 是否眨眼。关闭后眼睛保持睁开，省一个 ticker。
  final bool animate;

  /// 是否显示青色围巾。16px 以下建议关闭，细节会糊。
  final bool showScarf;

  /// 眨眼周期。默认 3.2 秒。
  final Duration blinkInterval;

  const AiFoxAvatar({
    super.key,
    required this.size,
    this.animate = true,
    this.showScarf = true,
    this.blinkInterval = const Duration(milliseconds: 3200),
  }) : assert(size > 0);

  @override
  State<AiFoxAvatar> createState() => _AiFoxAvatarState();
}

class _AiFoxAvatarState extends State<AiFoxAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink;

  /// 每次重启循环自增，让异步链上的旧循环自然失效。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    if (widget.animate) _startLoop();
  }

  void _startLoop() {
    final gen = ++_generation;
    // 随机相位：每个实例启动时间不同，避免整屏同步眨眼。
    final phaseMs =
        math.Random().nextDouble() * widget.blinkInterval.inMilliseconds;
    Future<void>.delayed(Duration(milliseconds: phaseMs.round()), () {
      if (mounted && widget.animate && gen == _generation) _tick(gen);
    });
  }

  Future<void> _tick(int gen) async {
    if (!mounted || gen != _generation) return;
    await _blink.forward();
    if (!mounted || gen != _generation) return;
    await _blink.reverse();
    if (!mounted || !widget.animate || gen != _generation) return;
    await Future<void>.delayed(widget.blinkInterval);
    if (mounted && gen == _generation) _tick(gen);
  }

  @override
  void didUpdateWidget(covariant AiFoxAvatar old) {
    super.didUpdateWidget(old);
    if (widget.animate != old.animate ||
        widget.blinkInterval != old.blinkInterval) {
      _generation++;
      _blink.stop();
      _blink.reset();
      if (widget.animate) _startLoop();
    }
  }

  @override
  void dispose() {
    _generation++;
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _blink,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _FoxPainter(
          eyeOpen: 1 - _blink.value,
          showScarf: widget.showScarf,
        ),
      ),
    );
  }
}

class _FoxPainter extends CustomPainter {
  _FoxPainter({required this.eyeOpen, required this.showScarf});

  /// 1 = 全睁，0 = 全闭。
  final double eyeOpen;
  final bool showScarf;

  static const _fur = Color(0xFFF0997B);
  static const _furEdge = Color(0xFFD85A30);
  static const _muzzle = Color(0xFFFAECE7);
  static const _ink = Color(0xFF4A1B0C);
  static const _scarf = Color(0xFF1D9E75);
  static const _scarfEdge = Color(0xFF0F6E56);

  @override
  void paint(Canvas canvas, Size size) {
    // 与 ai_fox.svg 完全同一套坐标：设计稿 64×64，绘制坐标以中心为原点，
    // 脸 rx=25 ry=24，耳尖到 y=-34，围巾底到 y=+32。
    // SVG 用 translate(32,34) scale(0.9) 收进画布，这里等价处理：
    // 先按 0.9 缩放，再把 (32,34) 对准画布中心稍下的位置。
    final unit = size.width / 64.0;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2 + 2 * unit);
    canvas.scale(0.9 * unit);

    final furPaint = Paint()
      ..color = _fur
      ..style = PaintingStyle.fill;
    final edgePaint = Paint()
      ..color = _furEdge
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round;
    final inkPaint = Paint()..color = _ink;

    // 左耳、右耳（圆润 Q 曲线三角）。
    final leftEar = Path()
      ..moveTo(-22, -12)
      ..quadraticBezierTo(-27, -34, -13, -29)
      ..quadraticBezierTo(-5, -26, -7, -14)
      ..close();
    final rightEar = Path()
      ..moveTo(22, -12)
      ..quadraticBezierTo(27, -34, 13, -29)
      ..quadraticBezierTo(5, -26, 7, -14)
      ..close();
    for (final ear in [leftEar, rightEar]) {
      canvas.drawPath(ear, furPaint);
      canvas.drawPath(ear, edgePaint);
    }

    // 脸。
    const face = Rect.fromLTWH(-25, -24, 50, 48);
    canvas.drawOval(face, furPaint);
    canvas.drawOval(face, edgePaint);

    // 浅色口鼻，压在脸下方。
    canvas.drawOval(const Rect.fromLTWH(-12, 3, 24, 16), Paint()..color = _muzzle);

    // 眼睛：Y 轴随 eyeOpen 压缩，X 轴保持不变 —— 眨眼而非眯眼。
    final eyeRy = 3.4 * eyeOpen;
    for (final cx in [-9.0, 9.0]) {
      if (eyeRy > 0.25) {
        canvas.drawOval(
          Rect.fromCenter(center: Offset(cx, -3), width: 5.2, height: eyeRy * 2),
          inkPaint,
        );
      } else {
        // 闭到极限时画一条短弧，比一个点更像闭眼。
        canvas.drawLine(
          Offset(cx - 2.4, -3),
          Offset(cx + 2.4, -3),
          Paint()
            ..color = _ink
            ..strokeWidth = 1.8
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    // 鼻子。
    canvas.drawCircle(const Offset(0, 8), 2.6, inkPaint);

    // 青围巾：底部弧形 + 深一档描边，最后画以盖住下巴接缝。
    if (showScarf) {
      final scarf = Path()
        ..moveTo(-20, 18)
        ..quadraticBezierTo(0, 32, 20, 18)
        ..quadraticBezierTo(0, 25, -20, 18)
        ..close();
      canvas.drawPath(scarf, Paint()..color = _scarf);
      canvas.drawPath(
        scarf,
        Paint()
          ..color = _scarfEdge
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeJoin = StrokeJoin.round,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FoxPainter old) =>
      old.eyeOpen != eyeOpen || old.showScarf != showScarf;
}
