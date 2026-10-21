import 'package:flutter/widgets.dart';

import '../../../shared/glass/surface/liquid_surface.dart';

/// Shared show/hide spec for every reader control.
///
/// One [AnimationController] (owned by `ReaderScreen`) drives all six
/// controls as a single whole: top bar, exit control, progress pill, bottom
/// search, morphing menu and search navigator. Pixel offsets keep the travel short
/// (iOS-style nudge + fade) so hidden controls leave the screen fast and,
/// once dismissed, are fully unmounted — no `BackdropFilter` cost while
/// reading.
abstract final class ReaderChromeSpec {
  static const Duration showDuration = Duration(milliseconds: 420);
  static const Duration hideDuration = Duration(milliseconds: 420);

  static const Curve showCurve = Curves.easeOutCubic;
  static const Curve hideCurve = Curves.easeInCubic;

  /// A short intentional drag is required before chrome changes direction.
  /// This filters touch jitter, bounce-back and tiny reading corrections.
  static const double scrollIntentDistance = 12;

  /// Top controls slide up, bottom controls slide down, pills nudge.
  static const double topHiddenDy = -56;
  static const double bottomHiddenDy = 56;
  static const double pillHiddenDy = 56;
}

/// Slide/fade driven by the common chrome animation. Geometry, timing, hit
/// testing and unmounting at the hidden endpoint are unchanged. The fade is
/// consumed by glass paint/foreground below backdrop filters: an Opacity above
/// them would replace the real document with a transparent offscreen input.
/// Keep the same subtree at every visible progress value, including exactly 1.
class ReaderChromeShell extends StatelessWidget {
  const ReaderChromeShell({
    required this.progress,
    required this.hiddenDy,
    required this.child,
    super.key,
  });

  final Animation<double> progress;
  final double hiddenDy;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, child) {
        final t = progress.value;
        if (t <= 0.001) {
          return const SizedBox.shrink();
        }
        final dy = hiddenDy * (1 - t);
        final inactive = t < 0.5;
        return RepaintBoundary(
          child: IgnorePointer(
            ignoring: inactive,
            child: ExcludeSemantics(
              excluding: inactive,
              child: Transform.translate(
                offset: Offset(0, dy),
                child: LiquidFade(opacity: t, child: child!),
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}
