import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../settings/folio_settings_scope.dart';
import '../theme/folio_theme.dart';

/// A floating bottom sheet with the reference dialog's entrance and backdrop.
/// Pair with FolioSheetContent for the shared Settings-style surface and body.
/// There is no fullscreen or centred-dialog presentation.
abstract final class FolioBottomSheet {
  static const double cornerRadius = AppRadius.xxxl;

  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    double backdropOpacity = 0.25,
  }) async {
    if (!context.mounted) return null;

    FocusManager.instance.primaryFocus?.unfocus();

    final route = _FolioBottomSheetRoute<T>(
      builder: builder,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      disableAnimations: MediaQuery.disableAnimationsOf(context),
      backdropOpacity: backdropOpacity,
    );
    final result = await Navigator.of(context).push<T>(route);
    await route.completed;
    return result;
  }
}

class _FolioBottomSheetRoute<T> extends PopupRoute<T> {
  _FolioBottomSheetRoute({
    required this.builder,
    required this.barrierLabel,
    required this.disableAnimations,
    required this.backdropOpacity,
  });

  static const _openDuration = AppDurations.sheetOpen;
  static const _closeDuration = AppDurations.sheetClose;
  static const _backdropRatio = 350 / 700;
  static final _fullBlur = ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12);

  /// Quantized backdrop blurs (0.05 steps → 20 entries): `ImageFilter.blur`
  /// allocated per animation tick forces a backdrop re-raster; sharing one
  /// filter per step keeps the animation pixel-identical but allocation-free.
  static final Map<int, ui.ImageFilter> _blurCache = <int, ui.ImageFilter>{};

  static ui.ImageFilter _blurFor(double t) {
    final step = (t * 20).round().clamp(0, 20);
    return _blurCache.putIfAbsent(
      step,
      () => ui.ImageFilter.blur(
        sigmaX: 12 * step / 20,
        sigmaY: 12 * step / 20,
      ),
    );
  }

  final WidgetBuilder builder;
  final bool disableAnimations;
  final double backdropOpacity;

  @override
  final String barrierLabel;

  @override
  bool get barrierDismissible => true;

  @override
  Color get barrierColor => Colors.transparent;

  @override
  Duration get transitionDuration =>
      disableAnimations ? Duration.zero : _openDuration;

  @override
  Duration get reverseTransitionDuration =>
      disableAnimations ? Duration.zero : _closeDuration;

  @override
  Widget buildModalBarrier() {
    return AnimatedBuilder(
      animation: animation!,
      // Retain Flutter's barrier hit testing, dismissal and accessibility.
      child: super.buildModalBarrier(),
      builder: (context, child) {
        final t = offstage
            ? 0.0
            : Curves.easeOut.transform(
                (animation!.value / _backdropRatio).clamp(0.0, 1.0),
              );
        final blurEnabled = FolioSettingsScope.blurEnabledOf(context);
        // Without blur the same 0.3 dim looks washed out, so compensate
        // with a stronger scrim when blur is off.
        final dimAlpha = (blurEnabled ? 0.3 : 0.6) * t;
        // Quantize `t` to the blur cache steps so nearby animation ticks
        // share the same ImageFilter instead of allocating a new one. The
        // first step is a zero-sigma filter, not the full blur: rounding
        // `t` down to zero must not flash a fully blurred backdrop.
        final quantizedT = (t * 20).round() / 20;
        final blurActive = blurEnabled && t > 0;
        return ClipRect(
          child: BackdropFilter(
            key: const ValueKey<String>('folio_sheet_backdrop'),
            enabled: blurActive,
            filter: blurActive && quantizedT < 1
                ? _blurFor(quantizedT)
                : _fullBlur,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: dimAlpha),
              child: child,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _BottomSheetPosition(
      animation: animation,
      controller: controller!,
      onClosing: () {
        if (isCurrent) navigator?.pop();
      },
      disableAnimations: disableAnimations,
      child: builder(context),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

class _BottomSheetPosition extends StatefulWidget {
  const _BottomSheetPosition({
    required this.animation,
    required this.controller,
    required this.onClosing,
    required this.disableAnimations,
    required this.child,
  });

  final Animation<double> animation;
  final AnimationController controller;
  final VoidCallback onClosing;
  final bool disableAnimations;
  final Widget child;

  @override
  State<_BottomSheetPosition> createState() => _BottomSheetPositionState();
}

class _BottomSheetPositionState extends State<_BottomSheetPosition> {
  Curve? _dragCurve;
  Curve _transitionCurve = _openingCurve;

  static const Curve _openingCurve = Cubic(0.24, 1.2, 0.2, 1.0);
  static const Curve _closingCurve = Curves.easeInOutCubic;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      if (_dragCurve != null) {
        setState(() => _dragCurve = null);
      }
      return;
    }
    if (status == AnimationStatus.reverse) {
      // A close that starts from the fully open sheet keeps the reference
      // closing motion. A close that interrupts the opening keeps the
      // opening mapping: picking the closing curve mid-flight would assign
      // a different offset to the same animation value and teleport the
      // surface instead of continuing from where the finger last saw it.
      final closingFromRest = widget.animation.value >= 1;
      final next = closingFromRest ? _closingCurve : _openingCurve;
      if (next != _transitionCurve) {
        setState(() => _transitionCurve = next);
      }
    }
  }

  void _onDragStart(DragStartDetails details) {
    setState(() => _dragCurve = Curves.linear);
  }

  void _onDragEnd(DragEndDetails details, {required bool isClosing}) {
    final start = widget.animation.value;
    setState(() {
      _dragCurve = start >= 1
          ? null
          : isClosing
          ? Curves.linear
          : _DragReleaseCurve(start);
    });
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    super.dispose();
  }

  double get _positionValue =>
      (_dragCurve ?? _transitionCurve).transform(widget.animation.value);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = math.max(media.viewPadding.bottom, media.viewInsets.bottom);
    // Широкий/горизонтальный экран: диалог открывается компактным справа,
    // а не по центру. Портрет: вся ширина минус отступы.
    const widthThreshold = 600.0;
    const compactMargin = AppSpacing.lg;
    const compactSheetWidth = 400.0;
    final alignRight = media.size.width > widthThreshold;
    return Align(
      alignment: alignRight ? Alignment.bottomRight : Alignment.bottomCenter,
      child: AnimatedPadding(
        duration: widget.disableAnimations
            ? Duration.zero
            : AppDurations.fast,
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.fromLTRB(
          compactMargin + media.viewPadding.left,
          compactMargin + media.viewPadding.top,
          // Правый отступ: системная панель справа + запас.
          compactMargin + media.viewPadding.right,
          // Нижний отступ + обход клавиатуры.
          compactMargin + bottom,
        ),
        // В правом углу — фиксированные 400, в портрете — вся ширина минус 32.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: alignRight
                ? compactSheetWidth
                : media.size.width - compactMargin * 2,
          ),
          child: AnimatedBuilder(
            animation: widget.animation,
            child: SizedBox(width: double.infinity, child: widget.child),
            builder: (context, child) {
              // Retain Folio's ordinary drag-to-dismiss. Only a user gesture
              // follows the sheet's height; route transitions use the exact
              // 750px reference travel and are not made screen-adaptive.
              final drag = _dragCurve == null
                  ? 0.0
                  : 1 - _dragCurve!.transform(widget.animation.value);
              return Transform.translate(
                key: const ValueKey<String>('folio_sheet_position'),
                offset: Offset(
                  0,
                  _dragCurve == null
                      ? 750 * (1 - _positionValue)
                      : (AppSpacing.lg + bottom) * drag,
                ),
                child: FractionalTranslation(
                  translation: Offset(0, drag),
                  child: BottomSheet(
                    animationController: widget.controller,
                    enableDrag:
                        widget.animation.status == AnimationStatus.completed ||
                        (_dragCurve != null &&
                            widget.animation.status != AnimationStatus.reverse),
                    showDragHandle: false,
                    onDragStart: _onDragStart,
                    onDragEnd: _onDragEnd,
                    onClosing: widget.onClosing,
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    clipBehavior: Clip.none,
                    constraints: const BoxConstraints(),
                    builder: (context) => child!,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Continue a cancelled dismissal from the release position without a jump.
class _DragReleaseCurve extends Curve {
  const _DragReleaseCurve(this.start);

  final double start;

  @override
  double transformInternal(double t) {
    if (t <= start || start >= 1) return t;
    final remaining = (t - start) / (1 - start);
    return start + (1 - start) * Curves.easeOutCubic.transform(remaining);
  }
}
