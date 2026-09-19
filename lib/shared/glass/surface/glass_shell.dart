import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../settings/folio_settings_scope.dart';

import 'liquid_surface.dart';
import 'liquid_surface_style.dart';

class GlassShell extends StatelessWidget {
  const GlassShell({
    required this.path,
    required this.glowCenter,
    required this.press,
    required this.focused,
    this.blurSigma,
    this.fill,
    super.key,
  });

  final Path path;
  final Offset glowCenter;
  final double press;
  final bool focused;

  /// Adaptive backdrop sigma. Null (or rest value) reuses the single shared
  /// [LiquidBlur.filter]; reduced sigmas resolve through a small quantized
  /// cache (0.5 steps) so no filter object is allocated per frame.
  final double? blurSigma;

  /// Optional fill override. When null uses the shared default [_ShellPainter]
  /// glass tint; panels/sheets pass their own opaque surface color.
  final Color? fill;

  static ui.ImageFilter get backdropBlur => LiquidBlur.filter;

  @override
  Widget build(BuildContext context) {
    final blurEnabled = FolioSettingsScope.blurEnabledOf(context);
    final motionSigma = blurSigma;
    final transitionSigma = LiquidBlurScope.maybeOf(context);
    final transitionOpacity = LiquidBlurScope.maybeOpacityOf(context) ?? 1.0;
    final double? sigma;
    if (transitionSigma == null) {
      sigma = motionSigma;
    } else if (motionSigma == null) {
      sigma = transitionSigma;
    } else {
      sigma = motionSigma < transitionSigma ? motionSigma : transitionSigma;
    }
    return RepaintBoundary(
      child: CustomPaint(
        painter: blurEnabled
            ? _ShellShadowPainter(path, opacity: transitionOpacity)
            : null,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ClipPath(
              clipper: _ShellClipper(path),
              child: BackdropFilter.grouped(
                enabled: blurEnabled,
                filter: !blurEnabled || sigma == null
                    ? backdropBlur
                    : LiquidBlur.filterFor(sigma),
                child: CustomPaint(
                  painter: const _CoveragePainter(),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Opacity(
              opacity: transitionOpacity,
              child: CustomPaint(
                painter: _ShellPainter(
                  path: path,
                  glowCenter: glowCenter,
                  press: press,
                  focused: focused,
                  blurEnabled: blurEnabled,
                  fill: fill,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoveragePainter extends CustomPainter {
  const _CoveragePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color.fromARGB(1, 0, 0, 0);
    canvas.drawPoints(ui.PointMode.points, <Offset>[
      Offset.zero,
      Offset(size.width - 1, 0),
      Offset(0, size.height - 1),
      Offset(size.width - 1, size.height - 1),
    ], paint);
  }

  @override
  bool shouldRepaint(covariant _CoveragePainter oldDelegate) => false;
}

class _ShellClipper extends CustomClipper<Path> {
  const _ShellClipper(this.path);

  final Path path;

  @override
  Path getClip(Size size) => path;

  @override
  bool shouldReclip(covariant _ShellClipper oldClipper) =>
      oldClipper.path != path;
}

class _ShellShadowPainter extends CustomPainter {
  const _ShellShadowPainter(this.path, {required this.opacity});

  final Path path;
  final double opacity;

  /// Fully static config: shared across frames/canvases instead of being
  /// reallocated on every repaint. Pixel-identical output.
  static final Paint _shadowPaint = Paint()
    ..color = const Color(0xFF020809).withValues(alpha: 0.30)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect((Offset.zero & size).inflate(32)),
      path,
    );
    final shadowPaint = opacity >= 0.999 ? _shadowPaint : Paint()
      ..color = const Color(0xFF020809).withValues(alpha: 0.30 * opacity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.save();
    canvas.clipPath(outside);
    canvas.drawPath(path.shift(const Offset(0, 7)), shadowPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ShellShadowPainter oldDelegate) =>
      oldDelegate.path != path || oldDelegate.opacity != opacity;
}

class _ShellPainter extends CustomPainter {
  const _ShellPainter({
    required this.path,
    required this.glowCenter,
    required this.press,
    required this.focused,
    required this.blurEnabled,
    this.fill,
  });

  final Path path;
  final Offset glowCenter;
  final double press;
  final bool focused;

  final bool blurEnabled;
  final Color? fill;

  /// Fully static paint configs: shared instead of reallocated per repaint.
  /// Balanced mid-gray tint: everything lighter than the fill darkens
  /// (white -> light gray), everything darker lightens (black -> dark gray).
  /// Alpha controls the strength of the pull.
  static final Paint _fillPaint = Paint()..color = const Color(0x33868683);
  static final Paint _opaqueFillPaint = Paint()
    ..color = LiquidSurfaceStyle.opaqueFill;
  static final Paint _innerWidePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 11
    ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.05)
    ..maskFilter = const MaskFilter.blur(BlurStyle.inner, 6);
  static final Paint _innerNarrowPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5
    ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.10)
    ..maskFilter = const MaskFilter.blur(BlurStyle.inner, 3);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint fillPaint;
    if (blurEnabled) {
      fillPaint = fill == null
          ? _fillPaint
          : (Paint()..color = fill!);
    } else {
      fillPaint = _opaqueFillPaint;
    }
    canvas.drawPath(path, fillPaint);
    // The inset edge belongs to the material, not to the backdrop filter.
    // Keep its original depth when the user turns background blur off.
    canvas.save();
    canvas.clipPath(path);
    canvas.drawPath(path, _innerWidePaint);
    canvas.drawPath(path, _innerNarrowPaint);
    canvas.restore();
    final pressAmount = press.clamp(0.0, 1.0);
    if (pressAmount > 0.01) {
      canvas.save();
      canvas.clipPath(path);
      canvas.drawCircle(
        glowCenter,
        132,
        Paint()
          ..shader = ui.Gradient.radial(
            glowCenter,
            132,
            <Color>[
              const Color(0xFFFFFFFF).withValues(alpha: pressAmount * 0.175),
              const Color(0x28F3F3F0).withValues(alpha: 0.157 * pressAmount),
              const Color(0x00FFFFFF),
            ],
            <double>[0, 0.42, 1],
          ),
      );
      canvas.restore();
    }

    LiquidSurfaceStyle.paintRim(
      canvas,
      path,
      bounds: path.getBounds(),
      width: focused ? 1.15 : 0.82,
    );

    if (pressAmount > 0.01) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = focused ? 1.32 : 0.92
          ..shader = ui.Gradient.radial(
            glowCenter,
            156,
            <Color>[
              const Color(0xFFFFFFFF).withValues(alpha: pressAmount * 0.32),
              const Color(0x18E2E2E0).withValues(alpha: 0.094 * pressAmount),
              const Color(0x00FFFFFF),
            ],
            <double>[0, 0.46, 1],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ShellPainter oldDelegate) =>
      oldDelegate.path != path ||
      oldDelegate.glowCenter != glowCenter ||
      oldDelegate.press != press ||
      oldDelegate.focused != focused ||
      oldDelegate.blurEnabled != blurEnabled ||
      oldDelegate.fill != fill;
}
