import 'package:flutter/widgets.dart';

abstract class AppColors {
  const AppColors();

  Color get background;
  Color get surface;
  Color get surfaceRaised;
  Color get textPrimary;
  Color get textSecondary;
  Color get textTertiary;
  Color get separator;
  Color get glassFill;
  Color get selection;
  Color get selectionHandle;
  Color get cursor;
  Color get cursorBackground;
  Color get searchMatch;
  Color get activeSearchMatch;
  Color get activeSearchText;
  Color get pdfSearchMatch;
  Color get pdfActiveSearchMatch;
}

class _DarkColors implements AppColors {
  const _DarkColors();

  @override
  Color get background => const Color(0xFF0B0C0E);

  @override
  Color get surface => const Color(0xFF15171A);

  @override
  Color get surfaceRaised => const Color(0xFF1C1E21);

  @override
  Color get textPrimary => const Color(0xFFF4F3EF);

  @override
  Color get textSecondary => const Color(0xFFA7A6A1);

  @override
  Color get textTertiary => const Color(0xFF6F706D);

  @override
  Color get separator => const Color(0x1FFFFFFF);

  @override
  Color get glassFill => const Color(0x16F4F3EF);

  @override
  Color get selection => const Color(0x665F6B7C);

  @override
  Color get selectionHandle => const Color(0xFFC9D1DC);

  @override
  Color get cursor => const Color(0xFFE1E6ED);

  @override
  Color get cursorBackground => const Color(0xFF6E7888);

  @override
  Color get searchMatch => const Color(0x3D8C98A9);

  @override
  Color get activeSearchMatch => const Color(0xFFD7DEE8);

  @override
  Color get activeSearchText => const Color(0xFF161A20);

  @override
  Color get pdfSearchMatch => const Color(0x558C98A9);

  @override
  Color get pdfActiveSearchMatch => const Color(0xB8D7DEE8);
}

const AppColors appColors = _DarkColors();