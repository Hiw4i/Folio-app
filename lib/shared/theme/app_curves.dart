import 'package:flutter/animation.dart';

/// Curve tokens shared by transient controls. Only curves that appear across
/// feature code are tokenized; one-off curves inside a single widget stay
/// there.
abstract final class AppCurves {
  /// The standard deceleration for entrances and reveals.
  static const Curve emphasized = Curves.easeOutCubic;

  /// The standard acceleration for exits and collapses.
  static const Curve exit = Curves.easeInCubic;

  /// Symmetric movement where neither end dominates (scrubbing, panning).
  static const Curve neutral = Curves.easeInOutCubic;

  static const Curve linear = Curves.linear;

  static const Curve easeOut = Curves.easeOut;
}
