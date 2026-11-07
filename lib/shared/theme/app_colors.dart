import 'package:flutter/widgets.dart';

/// Semantic color roles, following the god_mode vocabulary: content colors
/// are named by emphasis ([primary] is the bright text/icon color,
/// [secondary] the pale one), surfaces by elevation, hairlines as [border].
///
/// Palettes resolve through [ThemeColors], so widgets read
/// `context.colors.primary` and never the concrete theme.
abstract class AppColors {
  const AppColors();

  // Base roles.
  Color get background;

  /// Slightly raised plane above [background] (cards, code blocks, vignettes).
  Color get surface;

  /// Bright content: primary text, icons, glyphs.
  Color get primary;

  /// Pale content: captions, metadata, inactive labels.
  Color get secondary;

  /// Hairline separators and 1px outlines.
  Color get border;

  /// Full-screen scrim behind modal overlays.
  Color get scrim;

  // Interaction roles.
  Color get selection;
  Color get selectionHandle;
  Color get cursor;
  Color get searchMatch;
  Color get activeSearchMatch;
  Color get activeSearchText;
}

class _DarkColors implements AppColors {
  const _DarkColors();

  @override
  Color get background => const Color(0xFF0B0C0E);

  @override
  Color get surface => const Color(0xFF15171A);

  @override
  Color get primary => const Color(0xFFF4F3EF);

  @override
  Color get secondary => const Color(0xFFA7A6A1);

  @override
  Color get border => const Color(0x1FFFFFFF);

  @override
  Color get scrim => const Color(0xB8000000);

  @override
  Color get selection => const Color(0x665F6B7C);

  @override
  Color get selectionHandle => const Color(0xFFC9D1DC);

  @override
  Color get cursor => const Color(0xFFE1E6ED);

  @override
  Color get searchMatch => const Color(0x558C98A9);

  @override
  Color get activeSearchMatch => const Color(0xFFD7DEE8);

  @override
  Color get activeSearchText => const Color(0xFF161A20);
}

class _LightColors implements AppColors {
  const _LightColors();

  @override
  Color get background => const Color(0xFFF2F1EC);

  @override
  Color get surface => const Color(0xFFE7E5DE);

  @override
  Color get primary => const Color(0xFF1B1C1E);

  @override
  Color get secondary => const Color(0xFF70716E);

  @override
  Color get border => const Color(0x241B1C1E);

  @override
  Color get scrim => const Color(0x8A1B1C1E);

  @override
  Color get selection => const Color(0x598C98A9);

  @override
  Color get selectionHandle => const Color(0xFF4A5560);

  @override
  Color get cursor => const Color(0xFF2A3138);

  @override
  Color get searchMatch => const Color(0x668C98A9);

  @override
  Color get activeSearchMatch => const Color(0xFF2F3944);

  @override
  Color get activeSearchText => const Color(0xFFF2F1EC);
}

const AppColors darkAppColors = _DarkColors();
const AppColors lightAppColors = _LightColors();

/// [lightAppColors] when [light], otherwise [darkAppColors].
AppColors appColorsFor({required bool light}) =>
    light ? lightAppColors : darkAppColors;
