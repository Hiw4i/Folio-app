import 'package:flutter/widgets.dart';

class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double xxxxl = 40;
  static const double xxxxxl = 48;

  static const EdgeInsets cardPadding = EdgeInsets.all(xxl);
  static const EdgeInsets screenPadding = EdgeInsets.symmetric(horizontal: lg);
  static const EdgeInsets screenPaddingVertical = EdgeInsets.symmetric(vertical: lg);
  static const EdgeInsets tilePadding = EdgeInsets.all(lg);
  static const EdgeInsets buttonPadding = EdgeInsets.symmetric(horizontal: xl, vertical: md);
  static const EdgeInsets buttonPaddingSmall = EdgeInsets.symmetric(horizontal: md, vertical: sm);
  static const EdgeInsets inputPadding = EdgeInsets.symmetric(horizontal: lg, vertical: sm);
  static const EdgeInsets chipPadding = EdgeInsets.symmetric(horizontal: md, vertical: xs);
  static const EdgeInsets panelPadding = EdgeInsets.all(xl);
  static const EdgeInsets sheetPadding = EdgeInsets.fromLTRB(xl, xl, xl, md);
  static const EdgeInsets listItemPadding = EdgeInsets.symmetric(horizontal: lg, vertical: md);
  static const EdgeInsets sectionPadding = EdgeInsets.fromLTRB(lg, 0, lg, md);
  static const EdgeInsets headerPadding = EdgeInsets.fromLTRB(lg, xl, lg, md);
  static const EdgeInsets searchPadding = EdgeInsets.fromLTRB(xl, lg, xl, lg);
  static const EdgeInsets documentRowPadding = EdgeInsets.fromLTRB(lg, md, lg, md);
  static const EdgeInsets filterBarPadding = EdgeInsets.symmetric(horizontal: lg);
  static const EdgeInsets settingsRowPadding = EdgeInsets.symmetric(vertical: sm);
  static const EdgeInsets modalPadding = EdgeInsets.fromLTRB(xxl, lg, xxl, xxl);
  static const EdgeInsets overlayPadding = EdgeInsets.symmetric(horizontal: xxl);
  static const EdgeInsets bottomSheetPadding = EdgeInsets.fromLTRB(xxl, md, xxl, xxl);
}