class AppDurations {
  AppDurations._();

  static const Duration fastest = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration medium = Duration(milliseconds: 300);
  static const Duration slow = Duration(milliseconds: 350);
  static const Duration xslow = Duration(milliseconds: 420);
  static const Duration xxslow = Duration(milliseconds: 700);

  static const Duration pageTransition = normal;
  static const Duration pageTransitionReverse = fast;

  static const Duration sheetOpen = xxslow;
  static const Duration sheetClose = slow;

  static const Duration fadeIn = fast;
  static const Duration fadeOut = fast;
  static const Duration crossfade = medium;

  static const Duration press = fastest;
  static const Duration release = fast;
  static const Duration morph = normal;
  static const Duration separation = normal;

  static const Duration bannerHide = Duration(seconds: 3);
  static const Duration tooltipDelay = Duration(milliseconds: 500);
  static const Duration tooltipHide = fast;

  static const Duration searchExpand = normal;
  static const Duration searchCollapse = fast;

  static const Duration preloaderTtl = Duration(seconds: 15);

  // Loading view grace periods
  static const Duration grace = Duration(milliseconds: 350);
  static const Duration textGrace = Duration(milliseconds: 700);
}