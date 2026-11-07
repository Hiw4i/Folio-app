import 'dart:math' as math;

import 'package:flutter/physics.dart';

import 'app_durations.dart';

/// Motion tokens shared by transient controls. Duration is perceptual: spring
/// settlement depends on tolerance, not a hard timeout.
abstract final class AppSprings {
  static SpringDescription reveal({required bool visible}) =>
      SpringDescription.withDurationAndBounce(
        duration: AppDurations.normal,
        bounce: visible ? 0.22 : 0,
      );

  /// Sheet open/close budgets, matching god_mode's reference motion.
  static const sheetOpenDuration = AppDurations.sheetOpen;
  static const sheetCloseDuration = AppDurations.medium;

  /// The open direction enters with one soft overshoot near 54% of the run.
  static SpringDescription sheetEntrance(Duration duration) =>
      SpringDescription.withDurationAndBounce(
        duration: Duration(
          milliseconds: math.max(1, (duration.inMilliseconds * 0.63).round()),
        ),
        bounce: 0.19,
      );

  /// The exit keeps travelling past the viewport so the exact route
  /// completion never cuts off visible spring motion.
  static SpringDescription sheetExit(Duration duration) =>
      SpringDescription.withDurationAndBounce(duration: duration * 2);

  /// Settlement tolerances shared by every sheet spring.
  static const scaleTolerance = Tolerance(distance: 0.0001, velocity: 0.001);
}
