import 'package:flutter/widgets.dart';

import 'app_durations.dart';

/// Motion resolution honoring the platform reduced-motion preference.
///
/// Every animated duration in feature code must pass through [resolve] so a
/// user with "remove animations" enabled never sees a transition; sprinkle
/// `MediaQuery.disableAnimationsOf` checks instead and one widget will forget.
abstract final class AppMotion {
  /// [base], or [Duration.zero] when the platform requests reduced motion.
  static Duration resolve(BuildContext context, Duration base) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : base;

  /// [AppDurations.fast] resolved for the current motion preference — the
  /// common case of a standard-speed reveal that must collapse to instant.
  static Duration fast(BuildContext context) => resolve(context, AppDurations.fast);
}
