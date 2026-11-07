import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../settings/folio_settings_scope.dart';

import '../../theme/folio_theme.dart';
import '../core/glass_tokens.dart';
import 'liquid_surface_style.dart';

/// Canonical liquid surfaces: one blur, one shadow language, one rim.
///
/// Interactive (deformed) surfaces keep using `GlassShell` directly — it
/// already shares [LiquidBlur.filter]. Static surfaces (panels, segmented
/// tracks) use [LiquidCase] so they stop drifting apart with their own
/// blur sigmas (11 vs 13.5 vs 16) and border colors.
abstract final class LiquidBlur {
  /// Single shared backdrop filter for every liquid surface.
  ///
  /// Previously `GlassShell` used 13.5, the segmented track 11 and
  /// `GlassPanel` 16 — now all resolve to [GlassTokens.blurSigma].
  static final ui.ImageFilter filter = ui.ImageFilter.blur(
    sigmaX: const GlassTokens().blurSigma,
    sigmaY: const GlassTokens().blurSigma,
    tileMode: ui.TileMode.mirror,
  );

  /// Blur filters are quantized so animated consumers can change sigma
  /// without allocating a new native filter for every animation frame.
  static final Map<double, ui.ImageFilter> _animatedFilters =
      <double, ui.ImageFilter>{};

  static ui.ImageFilter filterFor(double sigma) {
    final rest = const GlassTokens().blurSigma;
    sigma = sigma.isFinite ? sigma.clamp(0.0, rest) : rest;
    if (sigma >= rest - 0.001) {
      return filter;
    }
    final quantized = (sigma * 2).round() / 2;
    var animated = _animatedFilters[quantized];
    if (animated == null) {
      if (_animatedFilters.length >= 32) {
        _animatedFilters.clear();
      }
      animated = ui.ImageFilter.blur(
        sigmaX: quantized,
        sigmaY: quantized,
        tileMode: ui.TileMode.mirror,
      );
      _animatedFilters[quantized] = animated;
    }
    return animated;
  }
}

/// Provides transition blur and foreground opacity for liquid surfaces in a
/// subtree.
///
/// The scope is optional: normal glass remains at [GlassTokens.blurSigma].
/// Opacity is consumed below each [BackdropFilter], never around it.
class LiquidBlurScope extends InheritedWidget {
  const LiquidBlurScope({
    this.sigma,
    required this.opacity,
    required super.child,
    super.key,
  });

  final double? sigma;
  final double opacity;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiquidBlurScope>()?.sigma;

  static double? maybeOpacityOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiquidBlurScope>()?.opacity;

  @override
  bool updateShouldNotify(LiquidBlurScope oldWidget) =>
      sigma != oldWidget.sigma || opacity != oldWidget.opacity;
}

/// Fades glass paint and foreground separately, below backdrop filters.
/// An outer Opacity would isolate the backdrop and make its luminance black.
/// Nested fades multiply without resetting the child's physics/editable state.
class LiquidFade extends StatelessWidget {
  const LiquidFade({required this.opacity, required this.child, super.key});

  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final combined = ((LiquidBlurScope.maybeOpacityOf(context) ?? 1) * opacity)
        .clamp(0.0, 1.0);
    return LiquidBlurScope(
      sigma: LiquidBlurScope.maybeOf(context),
      opacity: combined,
      // Keep state, but do not leave a fully blurred invisible button behind
      // when the search navigator reaches its hidden endpoint.
      child: Offstage(offstage: combined <= 0, child: child),
    );
  }
}

/// Static (non-deforming) liquid shell: the `GlassPanel` look as a mode of
/// the same library instead of a separate implementation.
///
/// [fill] varies by use case (translucent track vs opaque panel with text)
/// but blur, shadow, rim and gradient overlay are shared.
class LiquidCase extends StatelessWidget {
  const LiquidCase({
    required this.child,
    this.borderRadius = 24,
    this.padding = EdgeInsets.zero,
    this.fill,
    super.key,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  /// Explicit fill override; null resolves to the theme's translucent
  /// surface fill.
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final blurEnabled = FolioSettingsScope.blurEnabledOf(context);
    final glass = context.glass;
    final resolvedFill = fill ?? glass.surfaceFill;
    final effectiveFill = blurEnabled ? resolvedFill : glass.opaqueFill;
    // Whether the backdrop pipeline exists at all is decided by the USE-CASE
    // fill, not by the blur setting: an opaque surface (the settings sheet)
    // never mounts a filter — nothing can show through and a mounted one
    // would sample the backdrop — while translucent surfaces keep theirs
    // mounted across blur toggles so their content never remounts.
    final opaque = resolvedFill.a >= 1.0;
    final radius = BorderRadius.circular(borderRadius);
    final transitionBlur = LiquidBlurScope.maybeOf(context);
    final transitionOpacity = LiquidBlurScope.maybeOpacityOf(context) ?? 1.0;

    Widget body = Opacity(
      opacity: transitionOpacity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: effectiveFill,
          borderRadius: radius,
          gradient: blurEnabled && !opaque
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: glass.overlayColors,
                )
              : null,
        ),
        child: CustomPaint(
          foregroundPainter: LiquidCaseRimPainter(
            radius: radius,
            rimColors: glass.rimColors,
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    // Opaque fills mount no backdrop filter at all: nothing can show through,
    // and a mounted filter would sample the backdrop underneath (the sheet
    // would read as translucent). Translucent fills keep the filter mounted
    // across blur toggles so panel content never remounts; `enabled: false`
    // makes it a zero-cost passthrough while blur is off.
    if (!opaque) {
      body = BackdropFilter.grouped(
        enabled: blurEnabled,
        filter: transitionBlur == null
            ? LiquidBlur.filter
            : LiquidBlur.filterFor(transitionBlur),
        child: body,
      );
    }
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          // Same shadow language as GlassShell (offset y=7-8, soft black).
          boxShadow: !blurEnabled
              ? const <BoxShadow>[]
              : transitionOpacity >= 0.999
              ? <BoxShadow>[
                  BoxShadow(
                    color: LiquidShadows.color.withValues(
                      alpha: LiquidShadows.opacity,
                    ),
                    blurRadius: 22,
                    offset: const Offset(0, 8),
                  ),
                ]
              : <BoxShadow>[
                  BoxShadow(
                    color: LiquidShadows.color.withValues(
                      alpha: LiquidShadows.opacity * transitionOpacity,
                    ),
                    blurRadius: 22,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: ClipRRect(borderRadius: radius, child: body),
      ),
    );
  }
}
