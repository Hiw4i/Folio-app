import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:folio/shared/glass/core/glass_geometry.dart';
import 'package:folio/shared/glass/core/liquid_shape.dart';
import 'package:folio/shared/glass/motion/glass_motion_controller.dart';

void main() {
  test('pressed liquid material grows and springs back after release', () {
    final motion = GlassMotionController(morphEnabled: false);
    addTearDown(motion.dispose);
    const base = Rect.fromLTWH(20, 20, 120, 56);

    motion.beginPointer(
      position: base.center,
      timestamp: Duration.zero,
      target: GlassPointerTarget.main,
    );
    motion.stepForTest(0.12);
    final pressed = LiquidShape.expandedRect(base, press: motion.press);

    expect(motion.press, greaterThan(0.8));
    expect(pressed.width, greaterThan(base.width));
    expect(pressed.height, greaterThan(base.height));
    // Rect.fromCenter → center does not round-trip exactly in floating point
    // (e.g. 80.00000000000001), so compare with an FP epsilon.
    expect(pressed.center.dx, moreOrLessEquals(base.center.dx));
    expect(pressed.center.dy, moreOrLessEquals(base.center.dy));
    final pressedPath = GlassGeometryFrame.deformedCapsule(
      rect: pressed,
      origin: base.center,
      press: motion.press,
    );
    expect(pressedPath.getBounds().width, greaterThan(base.width));
    expect(pressedPath.getBounds().height, greaterThan(base.height));

    motion.endPointer(
      position: base.center,
      timestamp: const Duration(milliseconds: 120),
    );
    motion.stepForTest(1);
    final settled = LiquidShape.expandedRect(base, press: motion.press);
    expect(settled.width, closeTo(base.width, 0.01));
    expect(settled.height, closeTo(base.height, 0.01));
  });

  test(
    'moving material grows in both axes while stretching in travel axis',
    () {
      const base = Rect.fromLTWH(0, 0, 80, 48);

      final moving = LiquidShape.expandedRect(base, travel: 1);

      expect(moving.width, greaterThan(base.width * 1.4));
      expect(moving.height, greaterThan(base.height * 1.08));
      expect(moving.center.dx, moreOrLessEquals(base.center.dx));
      expect(moving.center.dy, moreOrLessEquals(base.center.dy));
    },
  );

  test('foreground inertia follows the material but stays bounded', () {
    final offset = LiquidShape.contentOffset(
      displacement: const Offset(300, 180),
      velocity: const Offset(12000, 9000),
      press: 1,
    );

    expect(offset.distance, greaterThan(0));
    expect(offset.distance, lessThanOrEqualTo(6.501));
  });

  test('foreground morph lags the liquid material', () {
    expect(
      LiquidShape.contentMorph(0.5),
      lessThan(LiquidShape.visualMorph(0.5)),
    );
    expect(LiquidShape.contentMorph(1), 1);
  });
}
