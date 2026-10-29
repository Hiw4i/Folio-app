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
}
