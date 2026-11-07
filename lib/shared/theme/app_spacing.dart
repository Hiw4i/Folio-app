import 'package:flutter/widgets.dart';

/// Spacing scale — the single source of truth for gaps and insets. Only
/// presets with real, current call sites live here; ad-hoc values stay local
/// to their widget instead of accumulating speculative tokens.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double xxxxl = 40;
  static const double xxxxxl = 48;

  static const EdgeInsets sheetPadding = EdgeInsets.fromLTRB(xl, xl, xl, md);
  static const EdgeInsets documentRowPadding = EdgeInsets.fromLTRB(
    lg,
    md,
    lg,
    md,
  );
  static const EdgeInsets settingsRowPadding = EdgeInsets.symmetric(
    vertical: sm,
  );
}
