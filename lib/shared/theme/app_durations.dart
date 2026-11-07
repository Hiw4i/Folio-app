/// Motion duration scale.
///
/// Every value below is motion — never a timer, delay or timeout. Feature
/// code must resolve durations through [AppMotion.resolve] so the platform
/// reduced-motion preference collapses them to zero.
///
/// Durations intentionally stay off-token (audited 2026-11-07): loading
/// grace thresholds are delays, not motion, and stay local to the loading
/// view; one-off motion values tuned per widget (e.g. the office staged-view
/// crossfade) remain local as well.
abstract final class AppDurations {
  static const Duration fastest = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration medium = Duration(milliseconds: 300);

  /// Chrome reveals that deserve a slower, unhurried entrance.
  static const Duration xslow = Duration(milliseconds: 420);

  static const Duration sheetOpen = Duration(milliseconds: 700);

  /// Hint threshold for opening a morphing control by press-and-hold. Faster
  /// than the platform kLongPressTimeout (500 ms) so the menu feels immediate.
  static const Duration longPressOpen = Duration(milliseconds: 280);
}
