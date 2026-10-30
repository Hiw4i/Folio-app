import 'package:flutter/foundation.dart';

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
  });

  final bool blurEnabled;
  final bool liquidMotionEnabled;

  /// Preserve the existing upward-scroll shortcut for older settings files.
  /// PPTX uses centre taps only and never changes controls during a swipe.
  final bool showNavigationOnScrollUp;

  FolioSettings copyWith({
    bool? blurEnabled,
    bool? liquidMotionEnabled,
    bool? showNavigationOnScrollUp,
  }) => FolioSettings(
    blurEnabled: blurEnabled ?? this.blurEnabled,
    liquidMotionEnabled: liquidMotionEnabled ?? this.liquidMotionEnabled,
    showNavigationOnScrollUp:
        showNavigationOnScrollUp ?? this.showNavigationOnScrollUp,
  );

  factory FolioSettings.fromJson(Map<String, Object?> json) => FolioSettings(
    blurEnabled: json['blurEnabled'] is bool
        ? json['blurEnabled']! as bool
        : false,
    liquidMotionEnabled: json['liquidMotionEnabled'] is bool
        ? json['liquidMotionEnabled']! as bool
        : true,
    showNavigationOnScrollUp: json['showNavigationOnScrollUp'] is bool
        ? json['showNavigationOnScrollUp']! as bool
        : true,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'blurEnabled': blurEnabled,
    'liquidMotionEnabled': liquidMotionEnabled,
    'showNavigationOnScrollUp': showNavigationOnScrollUp,
  };

  @override
  bool operator ==(Object other) =>
      other is FolioSettings &&
      other.blurEnabled == blurEnabled &&
      other.liquidMotionEnabled == liquidMotionEnabled &&
      other.showNavigationOnScrollUp == showNavigationOnScrollUp;

  @override
  int get hashCode => Object.hash(
    blurEnabled,
    liquidMotionEnabled,
    showNavigationOnScrollUp,
  );
}
