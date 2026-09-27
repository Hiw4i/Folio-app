import 'dart:math' as math;

import 'package:flutter/widgets.dart';

@immutable
class LiquidShapeTokens {
  const LiquidShapeTokens({
    this.pressGrowth = 0.0,
    this.pressPadding = 3.0,
    this.travelGrowth = 0.09,
    this.travelStretch = 0.34,
  });

  /// Пропорциональный press-рост (доля от размера). По умолчанию 0:
  /// нажатие расширяет материал равномерно, независимо от длины/ширины.
  /// Оставлен для тонкой настройки, если где-то понадобится масштаб.
  final double pressGrowth;

  /// Равномерный press-рост в px на каждую сторону при press == 1.
  /// Одинаково приподнимает и длинные пилюли, и круглые кнопки.
  final double pressPadding;

  final double travelGrowth;
  final double travelStretch;
}

/// Resolves the material bounds shared by buttons, morphs and moving lenses.
abstract final class LiquidShape {
  static Rect expandedRect(
    Rect rect, {
    double press = 0,
    double travel = 0,
    LiquidShapeTokens tokens = const LiquidShapeTokens(),
  }) {
    final safePress = press.clamp(0.0, 1.08);
    final safeTravel = travel.clamp(0.0, 1.08);
    // Travel остаётся пропорциональным (плюс направленный стретч по оси
    // движения) — это эффект полёта/зума. Press — равномерный абсолютный:
    // одинаковые px со всех сторон для любого размера, чтобы длинные пилюли
    // не росли сильно вширь и слабо ввысь, а круглые — слабо со всех сторон.
    final travelCommon = safeTravel * tokens.travelGrowth;
    final pressPad = safePress * tokens.pressPadding;
    final pressGrowthW = safePress * tokens.pressGrowth * rect.width;
    final pressGrowthH = safePress * tokens.pressGrowth * rect.height;
    return Rect.fromCenter(
      center: rect.center,
      width:
          rect.width *
              (1 + travelCommon + safeTravel * tokens.travelStretch) +
          pressGrowthW +
          pressPad * 2,
      height:
          rect.height * (1 + travelCommon) + pressGrowthH + pressPad * 2,
    );
  }

  /// Keeps arbitrary foreground content visually attached to the material.
  /// The surface deforms more strongly around the pointer, while the content
  /// follows its mass with a smaller inertial overshoot.
  static Offset contentOffset({
    required Offset displacement,
    Offset velocity = Offset.zero,
    double press = 0,
    double follow = 0.26,
    double maximum = 6.5,
  }) {
    final safePress = press.clamp(0.0, 1.0);
    final inertial = _limitOffset(velocity * (0.00020 * safePress), 1.2);
    return _limitOffset(displacement * follow + inertial, maximum);
  }

  static double contentScale(double press) => 1 + press.clamp(0.0, 1.0) * 0.018;

  /// The material leads the animation and keeps a small amount of spring
  /// overshoot. This curve is shared by every morphing liquid control.
  static double visualMorph(double value) {
    if (value < 0) {
      return value * 0.24;
    }
    if (value > 1) {
      return 1 + (value - 1) * 0.24;
    }
    return _smooth(value);
  }

  /// Foreground content has more perceived mass than the glass around it, so
  /// it follows the same destination less eagerly and overshoots less.
  static double contentMorph(double value) {
    if (value < 0) {
      return value * 0.10;
    }
    if (value > 1) {
      return 1 + (value - 1) * 0.10;
    }
    return _smooth(math.pow(value, 1.46).toDouble());
  }

  static double motionBlurSigma({
    required double morphVelocity,
    double separationVelocity = 0,
    bool reducedMotion = false,
  }) {
    final velocity =
        morphVelocity.abs() * 0.22 + separationVelocity.abs() * 0.15;
    return (velocity * (reducedMotion ? 0.32 : 1.0)).clamp(0.0, 2.15);
  }

  static double _smooth(double value) => value * value * (3 - 2 * value);

  static Offset _limitOffset(Offset value, double maximum) {
    if (value == Offset.zero || value.distance <= maximum) {
      return value;
    }
    return value / value.distance * maximum;
  }
}
