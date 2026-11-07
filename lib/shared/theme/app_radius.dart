import 'package:flutter/widgets.dart';

/// Radius scale — the single source of truth for corner rounding. The double
/// scale feeds the named getters; feature code reads getters, never raw
/// doubles, so a radius change cannot leave a straggler.
abstract final class AppRadius {
  static const double xs = 4;
  static const double md = 12;
  static const double lg = 16;
  static const double xxxl = 28;

  static BorderRadius get xsRadius => BorderRadius.circular(xs);
  static BorderRadius get mdRadius => BorderRadius.circular(md);

  /// Buttons, controls and small cards.
  static BorderRadius get controlRadius => BorderRadius.circular(lg);

  /// Sheets and large floating panels.
  static BorderRadius get sheetRadius => BorderRadius.circular(xxxl);
}
