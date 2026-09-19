import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../settings/folio_settings_scope.dart';

/// A floating bottom sheet with the reference dialog's entrance and backdrop.
/// Pair with FolioSheetContent for the shared Settings-style surface and body.
/// There is no fullscreen or centred-dialog presentation.
abstract final class FolioBottomSheet {
  static const double cornerRadius = 32;

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

  static const _openDuration = Duration(milliseconds: 700);
  static const _closeDuration = Duration(milliseconds: 350);
  static const _backdropRatio = 350 / 700;
  static final _fullBlur = ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12);

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
        return ClipRect(
          child: BackdropFilter(
            key: const ValueKey<String>('folio_sheet_backdrop'),
            enabled: blurEnabled && t > 0,
            filter: blurEnabled && t > 0 && t < 1
                ? ui.ImageFilter.blur(sigmaX: 12 * t, sigmaY: 12 * t)
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

  static const Curve _openingCurve = Cubic(0.24, 1.2, 0.2, 1.0);
  static const Curve _closingCurve = Curves.easeInOutCubic;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _dragCurve != null) {
      setState(() => _dragCurve = null);
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

  double get _positionValue {
    final curve = _dragCurve ??
        (widget.animation.status == AnimationStatus.reverse
            ? _closingCurve
            : _openingCurve);
    return curve.transform(widget.animation.value);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = math.max(media.viewPadding.bottom, media.viewInsets.bottom);
    return Align(
      alignment: Alignment.bottomCenter,
      child: AnimatedPadding(
        duration: widget.disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.fromLTRB(
          16 + media.viewPadding.left,
          16 + media.viewPadding.top,
          16 + media.viewPadding.right,
          16 + bottom,
        ),
        // Keep Folio's existing width cap, without switching to a dialog.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
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
                      : (16 + bottom) * drag,
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
