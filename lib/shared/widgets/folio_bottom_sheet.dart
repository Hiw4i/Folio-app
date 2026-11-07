import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../settings/folio_settings_scope.dart';
import '../theme/folio_theme.dart';

/// A floating bottom sheet with god_mode's reference motion: the panel rides
/// a spring (one soft overshoot in, spring-out past the viewport), and the
/// backdrop fades on its own wall clock instead of riding the spring.
///
/// The sheet surface ([FolioSheetContent]) is always opaque, so the backdrop
/// blur only ever affects the margins around it.
abstract final class FolioBottomSheet {
  static const double cornerRadius = AppRadius.xxxl;

  /// How far the panel travels below the viewport when hidden.
  static const double hiddenTravel = 750;

  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) async {
    if (!context.mounted) return null;

    FocusManager.instance.primaryFocus?.unfocus();

    final route = _FolioBottomSheetRoute<T>(
      builder: builder,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      disableAnimations: MediaQuery.disableAnimationsOf(context),
    );
    final result = await Navigator.of(context).push<T>(route);
    await route.completed;
    return result;
  }
}

/// god_mode's BounceBottomSheetRoute: route progress stays bounded for
/// barrier and lifecycle consumers, while the panel reads the unclipped
/// spring through [_SheetSpringVisual].
class _FolioBottomSheetRoute<T> extends PopupRoute<T> {
  _FolioBottomSheetRoute({
    required this.builder,
    required this.barrierLabel,
    required this.disableAnimations,
  });

  /// Captured at push time: reduced motion opens and closes instantly.
  final bool disableAnimations;

  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  SpringSimulation? _spring;
  _SheetSpringVisual? _visual;

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  Duration get transitionDuration =>
      disableAnimations ? Duration.zero : AppSprings.sheetOpenDuration;

  @override
  Duration get reverseTransitionDuration =>
      disableAnimations ? Duration.zero : AppSprings.sheetCloseDuration;

  @override
  Simulation? createSimulation({required bool forward}) {
    final duration = forward ? transitionDuration : reverseTransitionDuration;
    if (duration == Duration.zero) {
      _spring = null;
      return null;
    }
    final start = _visual?.value ?? controller!.value;
    final velocity = controller!.velocity;
    return _spring = forward
        ? SpringSimulation(
            AppSprings.sheetEntrance(duration),
            start,
            1,
            velocity,
            tolerance: AppSprings.scaleTolerance,
          )
        : FolioSheetExitSimulation(
            AppSprings.sheetExit(duration),
            start,
            velocity,
            duration,
          );
  }

  /// Re-runs the entrance spring from the current value and velocity, e.g.
  /// when a drag released above the dismissal threshold.
  void settleOpen() {
    controller!.animateWith(createSimulation(forward: true)!);
  }

  /// The bounded route progress a drag maps its finger position onto.
  double get dragProgress => controller!.value;

  set dragProgress(double value) {
    controller!.value = value.clamp(0.0, 1.0);
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    if (disableAnimations) {
      controller!
        ..duration = Duration.zero
        ..reverseDuration = Duration.zero;
    }
    if (disableAnimations && controller!.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final controller = this.controller;
        if (controller != null && controller.isAnimating && context.mounted) {
          controller.value = controller.status == AnimationStatus.reverse
              ? 0
              : 1;
        }
      });
    }
    final visual = _visual ??= _SheetSpringVisual(
      animation,
      controller!,
      () => _spring,
    );
    return _SheetTransition(
      route: this,
      visual: visual,
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

/// The route's raw progress is bounded; this channel evaluates the live
/// spring so the panel can overshoot past progress 1 during the entrance.
class _SheetSpringVisual extends Animation<double>
    with AnimationWithParentMixin<double> {
  _SheetSpringVisual(this.parent, this.controller, this.spring);

  @override
  final Animation<double> parent;
  final AnimationController controller;
  final SpringSimulation? Function() spring;

  @override
  double get value {
    final simulation = spring();
    final elapsed = controller.lastElapsedDuration;
    if (!controller.isAnimating || simulation == null || elapsed == null) {
      return parent.value;
    }
    return simulation.x(elapsed.inMicroseconds / 1000000);
  }
}

/// Exits beyond the viewport so the exact route completion never cuts off
/// visible spring motion. Public because the motion tests replicate it.
class FolioSheetExitSimulation extends SpringSimulation {
  FolioSheetExitSimulation(
    SpringDescription spring,
    double start,
    double velocity,
    Duration duration,
  ) : _seconds = duration.inMicroseconds / 1000000,
      super(spring, start, -0.25, velocity);

  final double _seconds;

  @override
  bool isDone(double time) => time >= _seconds && super.x(time) <= 0;

  @override
  double x(double time) => isDone(time) ? 0 : super.x(time);

  @override
  double dx(double time) => isDone(time) ? 0 : super.dx(time);
}

/// Dim + optional backdrop blur, fading on its own wall clock (300 ms both
/// ways) instead of riding the sheet spring: driving the backdrop from the
/// spring made dim + blur jump to near-max in the first frames of the open.
class _SheetBackdrop extends StatelessWidget {
  const _SheetBackdrop({required this.controller});

  final AnimationController controller;

  static const Curve blurCurve = AppCurves.neutral;

  /// Peak backdrop blur: the sheet is opaque, so only its margins reveal
  /// the backdrop — a soft ceiling is enough there.
  static const double blurSigma = 8;

  @override
  Widget build(BuildContext context) {
    final blurEnabled = FolioSettingsScope.blurEnabledOf(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final t = blurCurve.transform(controller.value.clamp(0.0, 1.0));
        return _surface(context, t, blur: blurEnabled && t > 0);
      },
    );
  }

  Widget _surface(BuildContext context, double t, {required bool blur}) {
    final overlay = ColoredBox(
      // Without blur the same 0.3 dim looks washed out, so compensate with a
      // stronger scrim when blur is off.
      color: Colors.black.withValues(
        alpha: (FolioSettingsScope.blurEnabledOf(context) ? 0.3 : 0.6) * t,
      ),
    );
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: BackdropFilter(
          key: const ValueKey<String>('folio_sheet_backdrop'),
          enabled: blur && t > 0,
          filter: ui.ImageFilter.blur(
            sigmaX: blur ? blurSigma * t : blurSigma,
            sigmaY: blur ? blurSigma * t : blurSigma,
          ),
          child: overlay,
        ),
      ),
    );
  }
}

/// god_mode's BottomSheetTransition: the backdrop on its own clock, the
/// panel riding the route spring with a fixed 750px travel.
class _SheetTransition extends StatefulWidget {
  const _SheetTransition({
    required this.route,
    required this.visual,
    required this.child,
  });

  final _FolioBottomSheetRoute<void> route;
  final Animation<double> visual;
  final Widget child;

  @override
  State<_SheetTransition> createState() => _SheetTransitionState();
}

class _SheetTransitionState extends State<_SheetTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _backdrop = AnimationController(
    vsync: this,
    duration: AppSprings.sheetCloseDuration,
    reverseDuration: AppSprings.sheetCloseDuration,
  );

  @override
  void initState() {
    super.initState();
    _backdrop.forward();
    widget.visual.addStatusListener(_onVisualStatus);
  }

  @override
  void didUpdateWidget(_SheetTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visual != oldWidget.visual) {
      oldWidget.visual.removeStatusListener(_onVisualStatus);
      widget.visual.addStatusListener(_onVisualStatus);
    }
  }

  void _onVisualStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) {
      _backdrop.reverse();
    } else if (status == AnimationStatus.forward) {
      _backdrop.forward();
    }
  }

  @override
  void dispose() {
    widget.visual.removeStatusListener(_onVisualStatus);
    _backdrop.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final travel = MediaQuery.sizeOf(context).height;
    if (travel <= 0) {
      return;
    }
    widget.route.dragProgress =
        widget.route.dragProgress - details.delta.dy / travel;
  }

  void _onDragEnd(DragEndDetails details) {
    final closing =
        widget.route.dragProgress < 0.6 ||
        details.velocity.pixelsPerSecond.dy > 700;
    if (closing) {
      // The reverse spring picks the value up from the finger position; the
      // pop also covers Back and outside-tap dismissals.
      Navigator.of(context).pop();
    } else {
      widget.route.settleOpen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Wide windows dock the sheet to the bottom-right; phones go full-bleed.
    final docked = media.size.width > 600;
    return Stack(
      children: <Widget>[
        _SheetBackdrop(controller: _backdrop),
        Align(
          alignment: docked ? Alignment.bottomRight : Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg + media.viewPadding.left,
              AppSpacing.lg + media.viewPadding.top,
              AppSpacing.lg + media.viewPadding.right,
              // Outer margin + the taller of the nav bar and the keyboard.
              AppSpacing.lg +
                  math.max(media.viewPadding.bottom, media.viewInsets.bottom),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: docked ? 400 : double.infinity,
              ),
              child: AnimatedBuilder(
                animation: widget.visual,
                child: Material(color: Colors.transparent, child: widget.child),
                builder: (context, content) {
                  return Transform.translate(
                    key: const ValueKey<String>('folio_sheet_position'),
                    offset: Offset(
                      0,
                      FolioBottomSheet.hiddenTravel * (1 - widget.visual.value),
                    ),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: _onDragUpdate,
                      onVerticalDragEnd: _onDragEnd,
                      child: content,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
