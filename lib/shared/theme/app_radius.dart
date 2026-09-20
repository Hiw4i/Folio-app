import 'package:flutter/widgets.dart';

class AppRadius {
  AppRadius._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 28;
  static const double pill = 32;

  static BorderRadius circular(double radius) => BorderRadius.circular(radius);

  static BorderRadius get xsRadius => BorderRadius.circular(xs);
  static BorderRadius get smRadius => BorderRadius.circular(sm);
  static BorderRadius get mdRadius => BorderRadius.circular(md);
  static BorderRadius get lgRadius => BorderRadius.circular(lg);
  static BorderRadius get xlRadius => BorderRadius.circular(xl);
  static BorderRadius get xxlRadius => BorderRadius.circular(xxl);
  static BorderRadius get xxxlRadius => BorderRadius.circular(xxxl);
  static BorderRadius get pillRadius => BorderRadius.circular(pill);

  static BorderRadius get cardRadius => BorderRadius.circular(xxl);
  static BorderRadius get sheetRadius => BorderRadius.circular(xxxl);
  static BorderRadius get controlRadius => BorderRadius.circular(lg);
  static BorderRadius get buttonRadius => BorderRadius.circular(lg);
  static BorderRadius get inputRadius => BorderRadius.circular(md);
  static BorderRadius get chipRadius => BorderRadius.circular(pill);
  static BorderRadius get panelRadius => BorderRadius.circular(xl);
}