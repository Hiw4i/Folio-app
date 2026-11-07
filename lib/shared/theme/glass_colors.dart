import 'package:flutter/widgets.dart';

/// Glass-material optics, deliberately separate from the content palette in
/// `app_colors.dart`: translucent fills, rims and sheens are tuned per theme
/// as a set, not per role. Widgets resolve them through `context.glass`.
abstract class GlassColors {
  const GlassColors();

  /// True for the light optic set; painters use it to pick static caches.
  bool get isLight;

  /// Opaque fill when backdrop blur is off (panels, sheets).
  Color get opaqueFill;

  /// Default translucent glass fill (deforming buttons, blur-on panels).
  Color get surfaceFill;

  /// Quiet wash behind a moving segmented-control lens.
  Color get trackFill;

  /// Sweep-gradient rim catching the surface edge; first and last colors are
  /// equal so the angular seam stays invisible.
  List<Color> get rimColors;

  /// Diagonal sheen over blurred glass (top-left towards bottom-right).
  List<Color> get overlayColors;
}

class _DarkGlass implements GlassColors {
  const _DarkGlass();

  @override
  bool get isLight => false;

  @override
  Color get opaqueFill => const Color(0xFF292A2D);

  @override
  Color get surfaceFill => const Color(0xB31A1B1E);

  @override
  Color get trackFill => const Color(0x161A1B1D);

  @override
  List<Color> get rimColors => const <Color>[
    Color(0x26FFFFFF),
    Color(0x66FFFFFF),
    Color(0x20FFFFFF),
    Color(0x0DFFFFFF),
    Color(0x33FFFFFF),
    Color(0x99FFFFFF),
    Color(0x4DFFFFFF),
    Color(0x14FFFFFF),
    Color(0x26FFFFFF),
  ];

  @override
  List<Color> get overlayColors => const <Color>[
    Color(0x1FFFFFFF),
    Color(0x08FFFFFF),
  ];
}

class _LightGlass implements GlassColors {
  const _LightGlass();

  @override
  bool get isLight => true;

  @override
  Color get opaqueFill => const Color(0xFFFBFAF6);

  @override
  Color get surfaceFill => const Color(0xB8F7F6F1);

  @override
  Color get trackFill => const Color(0x121B1C1E);

  @override
  List<Color> get rimColors => const <Color>[
    Color(0x14000000),
    Color(0x33000000),
    Color(0x14000000),
    Color(0x08000000),
    Color(0x1A000000),
    Color(0x4D000000),
    Color(0x26000000),
    Color(0x0D000000),
    Color(0x14000000),
  ];

  @override
  List<Color> get overlayColors => const <Color>[
    Color(0x141B1C1E),
    Color(0x061B1C1E),
  ];
}

const GlassColors darkGlassColors = _DarkGlass();
const GlassColors lightGlassColors = _LightGlass();

/// [lightGlassColors] when [light], otherwise [darkGlassColors].
GlassColors glassColorsFor({required bool light}) =>
    light ? lightGlassColors : darkGlassColors;
