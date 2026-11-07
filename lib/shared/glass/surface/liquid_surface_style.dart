import 'package:flutter/widgets.dart';

/// Paint shared by deforming buttons, static panels and segmented tracks.
/// Optical detail is independent of the optional backdrop blur. Glass colors
/// come from the caller's [GlassColors] — this class owns only the painting
/// mechanics (rim shaders and their cache).
abstract final class LiquidSurfaceStyle {
  // Bounds, not the optical canvas (which includes large transparent
  // margins), determine the reflection. Limit native shaders during morphs.
  static const int _maxCachedRims = 32;
  static final Map<(Rect, List<Color>), _RimPaint> _rimPaints =
      <(Rect, List<Color>), _RimPaint>{};

  static Paint _rimPaintFor(Rect bounds, List<Color> rimColors, double width) {
    final key = (bounds, rimColors);
    final cached = _rimPaints[key];
    if (cached != null && cached.width == width) return cached.paint;
    if (_rimPaints.length >= _maxCachedRims) {
      _rimPaints.remove(_rimPaints.keys.first);
    }
    // Equal first/last colours make the angular seam invisible; the light
    // follows the surface geometry without a ticker or extra backdrop pass.
    final shader = SweepGradient(
      colors: rimColors,
      stops: const <double>[0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1],
    ).createShader(bounds);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..shader = shader;
    _rimPaints[key] = _RimPaint(paint, width);
    return paint;
  }

  static void paintRim(
    Canvas canvas,
    Path path, {
    required Rect bounds,
    required List<Color> rimColors,
    double width = 0.82,
  }) {
    if (bounds.isEmpty || !bounds.isFinite) return;
    canvas.drawPath(path, _rimPaintFor(bounds, rimColors, width));
  }
}

/// Cached stroke [paint] plus the [width] it was built for, so a focused
/// rim (different width) rebuilds instead of reusing a stale stroke.
class _RimPaint {
  const _RimPaint(this.paint, this.width);

  final Paint paint;
  final double width;
}

/// Static cases use the same rim as GlassShell, without a uniform border
/// underneath. Inset by half the stroke so ClipRRect cannot cut it in half.
class LiquidCaseRimPainter extends CustomPainter {
  const LiquidCaseRimPainter({required this.radius, required this.rimColors});

  final BorderRadius radius;

  /// Resolved from the current theme where the painter is created. The
  /// per-theme const lists keep the shader cache identity-stable.
  final List<Color> rimColors;
  static const double _width = 0.8;

  @override
  void paint(Canvas canvas, Size size) {
    if (!size.isFinite || size.shortestSide <= _width) return;
    final rect = Offset.zero & size;
    final rim = radius.toRRect(rect).deflate(_width / 2);
    LiquidSurfaceStyle.paintRim(
      canvas,
      Path()..addRRect(rim),
      bounds: rect,
      rimColors: rimColors,
      width: _width,
    );
  }

  @override
  bool shouldRepaint(covariant LiquidCaseRimPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      !identical(oldDelegate.rimColors, rimColors);

  @override
  bool? hitTest(Offset position) => false;
}
