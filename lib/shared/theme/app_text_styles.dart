import 'package:flutter/widgets.dart';

import 'app_colors.dart';

class AppTextStyles {
  AppTextStyles._();

  static const String _fontFamily = 'Inter';

  static TextStyle heading(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 34,
        fontWeight: FontWeight.w600,
        color: appColors.textPrimary,
        height: 1.08,
        letterSpacing: -1.1,
      );

  static TextStyle subheading(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: appColors.textPrimary,
        height: 1.2,
        letterSpacing: -0.3,
      );

  static TextStyle section(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: appColors.textSecondary,
        height: 1.2,
        letterSpacing: 0.8,
      );

  static TextStyle title(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: appColors.textPrimary,
        height: 1.25,
      );

  static TextStyle filename(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 15.5,
        fontWeight: FontWeight.w500,
        color: appColors.textPrimary,
        height: 1.25,
        letterSpacing: -0.1,
      );

  static TextStyle body(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: appColors.textPrimary,
        height: 1.35,
      );

  static TextStyle bodyDim(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: appColors.textSecondary,
        height: 1.35,
      );

  static TextStyle bodyStrong(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: appColors.textPrimary,
        height: 1.35,
      );

  static TextStyle metadata(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 12.5,
        fontWeight: FontWeight.w400,
        color: appColors.textSecondary,
        height: 1.2,
      );

  static TextStyle small(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: appColors.textPrimary,
        height: 1.3,
      );

  static TextStyle smallDim(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: appColors.textSecondary,
        height: 1.3,
      );

  static TextStyle button(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: appColors.textPrimary,
        height: 1.2,
      );

  static TextStyle buttonSmall(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: appColors.textSecondary,
        height: 1.2,
      );

  static TextStyle overlayTitle(BuildContext context) => TextStyle(
        fontFamily: _fontFamily,
        fontSize: 19,
        fontWeight: FontWeight.w600,
        color: appColors.textPrimary,
        height: 1.2,
      );
}