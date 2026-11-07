import 'package:flutter/foundation.dart';

/// Appearance preference. [system] follows the OS brightness; [dark] is the
/// default and the original Folio look.
enum FolioThemeMode { dark, light, system }

/// Persisted appearance and reading preferences. Navigation and document
/// rendering remain independent of the optional liquid-glass motion effect.
@immutable
class FolioSettings {
  const FolioSettings({
    // Off for new users: plain fixed-contrast foregrounds, no backdrop cost.
    // Turning blur on also enables the adaptive black/white glyph foreground,
    // which samples the backdrop behind glass controls on the GPU.
    this.blurEnabled = false,
    this.liquidMotionEnabled = true,
    this.showNavigationOnScrollUp = true,
    this.themeMode = FolioThemeMode.dark,
  });

  final bool blurEnabled;
  final bool liquidMotionEnabled;

  /// Preserve the existing upward-scroll shortcut for older settings files.
  /// PPTX uses centre taps only and never changes controls during a swipe.
  final bool showNavigationOnScrollUp;

  final FolioThemeMode themeMode;

  FolioSettings copyWith({
    bool? blurEnabled,
    bool? liquidMotionEnabled,
    bool? showNavigationOnScrollUp,
    FolioThemeMode? themeMode,
  }) => FolioSettings(
    blurEnabled: blurEnabled ?? this.blurEnabled,
    liquidMotionEnabled: liquidMotionEnabled ?? this.liquidMotionEnabled,
    showNavigationOnScrollUp:
        showNavigationOnScrollUp ?? this.showNavigationOnScrollUp,
    themeMode: themeMode ?? this.themeMode,
  );

  factory FolioSettings.fromJson(Map<String, Object?> json) {
    FolioThemeMode readThemeMode() => switch (json['themeMode']) {
      'light' => FolioThemeMode.light,
      'system' => FolioThemeMode.system,
      'dark' => FolioThemeMode.dark,
      // Settings written before the three-way selector existed: the old
      // boolean migrates once, then the field is dropped on the next save.
      _ =>
        json['lightTheme'] == true ? FolioThemeMode.light : FolioThemeMode.dark,
    };
    return FolioSettings(
      blurEnabled: json['blurEnabled'] is bool
          ? json['blurEnabled']! as bool
          : false,
      liquidMotionEnabled: json['liquidMotionEnabled'] is bool
          ? json['liquidMotionEnabled']! as bool
          : true,
      showNavigationOnScrollUp: json['showNavigationOnScrollUp'] is bool
          ? json['showNavigationOnScrollUp']! as bool
          : true,
      themeMode: readThemeMode(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'blurEnabled': blurEnabled,
    'liquidMotionEnabled': liquidMotionEnabled,
    'showNavigationOnScrollUp': showNavigationOnScrollUp,
    'themeMode': themeMode.name,
  };

  @override
  bool operator ==(Object other) =>
      other is FolioSettings &&
      other.blurEnabled == blurEnabled &&
      other.liquidMotionEnabled == liquidMotionEnabled &&
      other.showNavigationOnScrollUp == showNavigationOnScrollUp &&
      other.themeMode == themeMode;

  @override
  int get hashCode => Object.hash(
    blurEnabled,
    liquidMotionEnabled,
    showNavigationOnScrollUp,
    themeMode,
  );
}
