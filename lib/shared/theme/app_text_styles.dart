import 'package:flutter/widgets.dart';

import 'theme_colors.dart';

/// Semantic text styles, god_mode-style: a serif display face for the
/// heading level, Inter for everything else. Each style is built directly
/// through [_style] — no derived `copyWith` chains — so the set stays
/// enumerable: heading, subheading, body, metadata and the long-form
/// [reading] style used by the text reader surface.
abstract final class AppTextStyles {
  static const String _headingFont = 'PlayfairDisplay';
  static const String _bodyFont = 'Inter';
  static const List<String> _headingFallback = <String>[_bodyFont];

  static TextStyle _style(
    BuildContext context, {
    String fontFamily = _bodyFont,
    List<String>? fontFamilyFallback,
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color ?? context.colors.primary,
    height: height,
    letterSpacing: letterSpacing,
  );

  /// App-level display title (serif).
  static TextStyle heading(BuildContext context) => _style(
    context,
    fontFamily: _headingFont,
    fontFamilyFallback: _headingFallback,
    fontSize: 34,
    fontWeight: FontWeight.w600,
    height: 1.08,
    letterSpacing: -1.1,
  );

  /// Sheet and overlay titles.
  static TextStyle subheading(BuildContext context) => _style(
    context,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: -0.3,
  );

  /// Default UI text; also the WidgetsApp fallback style.
  static TextStyle body(BuildContext context) =>
      _style(context, fontSize: 15, height: 1.35);

  /// Long-form reading text for the text/markdown reader surface.
  static TextStyle reading(BuildContext context) =>
      _style(context, fontSize: 15, height: 1.62, letterSpacing: -0.05);

  /// Pale small text: metadata rows, captions, quiet labels.
  static TextStyle metadata(BuildContext context) => _style(
    context,
    fontSize: 12.5,
    color: context.colors.secondary,
    height: 1.2,
  );
}
